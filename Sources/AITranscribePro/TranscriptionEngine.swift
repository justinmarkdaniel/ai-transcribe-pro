import Foundation
import Speech
import AVFoundation
import CoreAudio
import Combine

enum TranscriptionState {
    case idle       // no transcript, nothing to show
    case recording  // actively capturing audio
    case paused     // mid-session, audio halted but transcript kept
    case stopped    // finished session, transcript preserved for copy/review
}

@MainActor
final class TranscriptionEngine: ObservableObject {
    @Published var state: TranscriptionState = .idle {
        didSet {
            if oldValue != state {
                Log.log("engine", "state: \(oldValue) → \(state)")
            }
        }
    }
    @Published var transcript: String = ""
    @Published var errorMessage: String?

    // ONE recognizer, exactly like every build that has ever streamed results reliably here.
    // (A two-instance alternating scheme was tried to isolate rotation overlap — it delivered a
    // single partial and went silent. Whatever the cause, multiple SFSpeechRecognizer instances
    // are not safe on this machine; the stall watchdog now covers the overlap concern instead.)
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    // OPT-IN ONLY, and off by default. On-device recognition looks attractive (lower partial-result
    // latency) and `supportsOnDeviceRecognition` reports true on this machine — but in testing it
    // delivered a couple of partials and then went permanently silent: no further results, no
    // `isFinal`, no error, while audio kept flowing into the request. The server path is what has
    // actually produced continuous results in this app. Flip with:
    //     defaults write com.justindaniel.AITranscribePro UseOnDeviceRecognition -bool YES
    private lazy var useOnDeviceRecognition: Bool = {
        guard UserDefaults.standard.bool(forKey: "UseOnDeviceRecognition") else { return false }
        return recognizer?.supportsOnDeviceRecognition ?? false
    }()

    // Optional + recreated per session so stopping the recording fully releases the mic hardware.
    // Keeping a long-lived AVAudioEngine instance caused the mic to re-activate on system audio
    // events (YouTube play, spacebar media keys) even though our app was "idle".
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapBufferCount: Int = 0

    // --- Rolling-window recognition ---------------------------------------------------------
    // A single SFSpeechAudioBufferRecognitionRequest accumulates the entire session's audio and
    // re-scores an ever-growing hypothesis on every partial result, so per-update latency climbs
    // with total recording length (measured: ~300ms early → ~750ms past 14k chars). We keep ONE
    // audio engine + tap alive for the whole recording and periodically rotate the lightweight
    // recognition request underneath it — bounding how much any single request accumulates keeps
    // latency flat regardless of how long the recording runs.
    //
    // Rotation is a HANDOFF, not a cut. The previous implementation froze the on-screen text as the
    // new prefix and immediately `cancel()`ed the outgoing task — but partial results lag the audio
    // by 300–750ms, and `cancel()` throws away everything still in flight, so every rotation ate
    // the last fraction of a second of speech. Instead we now keep the outgoing segment alive as
    // `pendingText` until its FINAL result arrives, and only then fold it into `committedPrefix`.
    //
    // Text is assembled from three parts so the live view stays correct while a segment finalizes:
    //     transcript = committedPrefix + pendingText + liveText
    private var rotationTimer: Timer?
    private var requestGeneration = 0          // monotonic id used to route callbacks
    private var rollScheduled = false          // debounce guard against silence spinning the roll
    private var lastRollAt = Date.distantPast
    private let rotationInterval: TimeInterval = 45

    private var liveGeneration = 0             // segment currently receiving audio (0 = none)
    private var liveText = ""
    private var pendingGeneration = 0          // segment that has been flushed and is finalizing
    private var pendingText = ""
    private var pendingSettleWork: DispatchWorkItem?
    // If a flushed segment never delivers its final result we must not strand its text forever.
    private let pendingSettleTimeout: TimeInterval = 4.0

    // Stall detection. The recurring failure in this app is the recognizer going quiet mid-recording
    // while audio keeps flowing — no error, no isFinal, just silence, so nothing ever triggers a
    // roll and the rest of the recording is lost. One timer ticks every `watchdogInterval` and
    // handles both jobs: rotate when the window is up, and force a roll when results have stopped
    // but the tap is still delivering buffers.
    // Input-device pinning (see startRecognition). Chosen at session start, kept across rebuilds.
    private var pinnedInputDevice: AudioDeviceID?
    // Setting the device on the engine fires AVAudioEngineConfigurationChange itself; without a
    // settling window that notification triggers a rebuild, which pins again, which fires again —
    // an infinite rebuild loop (observed: 45 generations in under 10 seconds).
    private var engineStartedAt = Date.distantPast
    private let configChangeSettleWindow: TimeInterval = 2.0

    private var windowStartedAt = Date.distantPast
    private var lastResultAt = Date.distantPast
    private var lastSeenTapCount = 0
    private var resultCount = 0
    private let watchdogInterval: TimeInterval = 3.0
    private let stallTimeout: TimeInterval = 8.0
    // Fires when the audio route/format changes mid-recording (Bluetooth/AirPods switching profile,
    // plugging in headphones, sample-rate flips). The tap is bound to the old format and goes deaf
    // when this happens, so we must rebuild the engine — otherwise recording silently "cuts off".
    private var configObserver: NSObjectProtocol?

    // Anything finalized in previous recording segments (survives pause/resume).
    private var committedPrefix: String = ""

    var onCommit: ((String) -> Void)?

    /// Proactively asks for Speech + Microphone access so the first record press
    /// doesn't get swallowed by permission prompts.
    func prewarmAuthorization() {
        Log.log("engine", "prewarm auth")
        requestAuthorization { _ in }
    }

    /// Global hotkey mirrors the primary mic button: idle/stopped → start, recording → pause,
    /// paused → resume. The earlier "hotkey stops recording" behaviour was replaced so pause is
    /// reachable without the mouse; the auto-copy on pause/stop is handled at the view layer.
    func hotKeyTriggered() {
        Log.log("engine", "hotKeyTriggered state=\(state)")
        toggleRecord()
    }

    func toggleRecord() {
        switch state {
        case .idle:      start()
        case .recording: pause()
        case .paused:    resume()
        case .stopped:   start() // clear previous transcript and begin a fresh session
        }
    }

    /// Reset/restart: commit whatever's currently on-screen to history, then start a fresh
    /// recording session. Works from any state — if we were recording, the session is swapped
    /// out for a new one (brief tear-down + restart); if idle/paused/stopped, recording begins.
    /// The reset icon therefore always lands the user in an active recording.
    func reset() {
        Log.log("engine", "reset() from state=\(state)")
        let currentText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentText.isEmpty {
            onCommit?(currentText)
        }
        stopAudio()
        errorMessage = nil
        state = .idle
        start()
    }

    func stop() {
        guard state == .recording || state == .paused else { return }
        stopAudio()
        let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            onCommit?(finalText)
            state = .stopped
        } else {
            state = .idle
        }
    }

    /// Force-tear-down for when the window closes or the app is about to terminate.
    /// Releases the microphone immediately, no matter what state we're in.
    func shutdown() {
        Log.log("engine", "shutdown() — releasing mic")
        if state == .recording || state == .paused {
            let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !finalText.isEmpty { onCommit?(finalText) }
        }
        stopAudio()
        state = .idle
    }

    private func pause() {
        guard state == .recording else { return }
        // Freeze current transcript as committed prefix, then stop the audio pipeline.
        flattenIntoPrefix()
        stopAudio()
        state = .paused
    }

    private func resume() {
        guard state == .paused else { return }
        startRecognition()
    }

    private func start() {
        Log.log("engine", "start()")
        // Each session re-reads the user's current default input (AirPods if connected).
        pinnedInputDevice = nil
        committedPrefix = ""
        pendingText = ""
        liveText = ""
        pendingGeneration = 0
        liveGeneration = 0
        pendingSettleWork?.cancel()
        pendingSettleWork = nil
        transcript = ""
        draftURL = nil   // new session => new draft file
        requestAuthorization { [weak self] granted in
            guard let self else { return }
            if granted {
                self.startRecognition(retriesLeft: 3)
            } else {
                self.errorMessage = "Microphone / Speech permission denied. Enable in System Settings → Privacy."
            }
        }
    }

    private func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                Log.log("engine", "auth speech=\(speechStatus.rawValue) mic=\(micGranted)")
                DispatchQueue.main.async {
                    completion(speechStatus == .authorized && micGranted)
                }
            }
        }
    }

    private func startRecognition(retriesLeft: Int = 0) {
        Log.log("engine", "startRecognition retriesLeft=\(retriesLeft) isAvailable=\(recognizer?.isAvailable ?? false)")
        guard let recognizer else {
            errorMessage = "Speech recognizer unavailable."
            return
        }
        if !recognizer.isAvailable {
            if retriesLeft > 0 {
                Log.log("engine", "recognizer not yet available, retrying in 300ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startRecognition(retriesLeft: retriesLeft - 1)
                }
                return
            }
            errorMessage = "Speech recognizer unavailable."
            return
        }

        // Tear down any prior session cleanly before starting a new one.
        stopAudio()

        // Fresh engine every session so the mic is only ever hot while we're actively recording.
        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine

        let inputNode = audioEngine.inputNode

        // PIN the engine to the microphone the user chose for THIS session: whatever is the system
        // default input at the moment recording starts (AirPods if they're active, built-in mic
        // otherwise). Left unpinned, AVAudioEngine follows the default device, and macOS flips that
        // mid-recording (observed: the iPhone Continuity mic "LV223" grabbing input ~4s in) — the
        // engine then records dead air (rms ~0.008 → ~0.0005) while recognition transcribes
        // silence. The pin is re-applied to the SAME device on route-change rebuilds; if that
        // device has vanished (e.g. AirPods disconnected mid-recording), we refresh to the
        // then-current default rather than going deaf.
        if let pinned = pinnedInputDevice, Self.inputDeviceExists(pinned) {
            // keep the session's device across rebuilds
        } else {
            pinnedInputDevice = Self.defaultInputDeviceID()
        }
        if var deviceID = pinnedInputDevice, let unit = inputNode.audioUnit {
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            Log.log("audio", "pinned input to \"\(Self.deviceName(deviceID))\" (device \(deviceID), status=\(status))")
        } else {
            Log.log("audio", "no pinnable input device — using system default input")
        }
        // IMPORTANT: on an AVAudioEngine input node you MUST pass the node's native output
        // format to installTap — Apple's docs say it does not auto-convert for input nodes and
        // passing a mismatched format throws an unrecoverable Objective-C exception (hard crash).
        // SFSpeechAudioBufferRecognitionRequest.append() accepts PCM at any sample rate; the
        // recognizer handles resampling internally. This matches Apple's SpokenWord sample.
        // Bluetooth inputs (AirPods) renegotiate their hardware format when first opened — the node
        // can report a stale 48kHz for a moment before the real HFP format (16–24kHz) lands.
        // Installing the tap against the stale format either fails engine start (-10868) or yields
        // a tap that never fires. Wait briefly until the node's input and output formats agree on a
        // real sample rate before trusting it.
        var tapFormat = inputNode.outputFormat(forBus: 0)
        for attempt in 0..<20 {
            let hw = inputNode.inputFormat(forBus: 0)
            tapFormat = inputNode.outputFormat(forBus: 0)
            if hw.sampleRate > 0, hw.sampleRate == tapFormat.sampleRate {
                if attempt > 0 { Log.log("audio", "input format settled after \(attempt * 50)ms") }
                break
            }
            usleep(50_000)
        }
        // If the formats never settled, do NOT install the tap — a mismatched tap format makes
        // installTap throw an Objective-C exception, which is an uncatchable hard crash (SIGABRT,
        // seen in the wild on this exact path). Bail out and retry like a failed engine start.
        let hwFormat = inputNode.inputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0, hwFormat.sampleRate == tapFormat.sampleRate else {
            Log.log("audio", "input format never settled (hw=\(hwFormat.sampleRate) tap=\(tapFormat.sampleRate)) — not installing tap")
            stopAudio()
            if retriesLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.state == .recording || self.state == .idle else { return }
                    self.startRecognition(retriesLeft: retriesLeft - 1)
                }
            } else {
                errorMessage = "Microphone is busy switching modes — try again."
            }
            return
        }
        Log.log("audio", "tap format (native) sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")

        tapBufferCount = 0
        inputNode.removeTap(onBus: 0)
        // The tap feeds whatever request is current (`self.request`). We keep this ONE engine + tap
        // alive for the whole recording and only rotate the request underneath it, so audio is
        // never interrupted and the CoreAudio graph is never torn down/rebuilt mid-recording — the
        // rapid teardown/rebuild loop was what raced the HAL and aborted in AVFAudio previously.
        // bufferSize 4096 is safer across macOS versions than 1024 for input node taps.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.tapBufferCount += 1
            // Log signal level (RMS) every ~2s: distinguishes "recognition stopped responding"
            // from "the microphone went silent" — the two look identical from the results side.
            if self.tapBufferCount == 1 || self.tapBufferCount % 20 == 0 {
                var rms: Float = 0
                if let data = buffer.floatChannelData?.pointee {
                    let n = Int(buffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<n { sum += data[i] * data[i] }
                    if n > 0 { rms = (sum / Float(n)).squareRoot() }
                }
                Log.log("audio", "tap buffer #\(self.tapBufferCount) frames=\(buffer.frameLength) rms=\(String(format: "%.4f", rms))")
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            engineStartedAt = Date()
            Log.log("audio", "audio engine started")
        } catch {
            Log.log("audio", "audio engine failed: \(error.localizedDescription)")
            // A Bluetooth input that is still switching profiles can refuse the first start
            // (-10868). A fresh engine a beat later almost always succeeds — retry before failing.
            if retriesLeft > 0 {
                stopAudio()
                Log.log("audio", "retrying engine start in 350ms (retriesLeft=\(retriesLeft - 1))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.state == .recording || self.state == .idle else { return }
                    self.startRecognition(retriesLeft: retriesLeft - 1)
                }
                return
            }
            errorMessage = "Audio engine failed: \(error.localizedDescription)"
            return
        }

        // Recover from audio route/format changes (walking away with AirPods, plugging in a headset,
        // a device sample-rate flip). The tap is bound to `tapFormat`; when the hardware format
        // changes it stops delivering buffers and recognition goes silent. Rebuild on that signal so
        // the recording keeps running instead of quietly dying.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                // Our own device pin fires this notification too; ignore the echo while the
                // engine is settling or we rebuild in an infinite loop.
                let age = Date().timeIntervalSince(self.engineStartedAt)
                guard age > self.configChangeSettleWindow else {
                    Log.log("audio", "config change \(String(format: "%.2f", age))s after engine start — settling echo, ignored")
                    return
                }
                Log.log("audio", "engine configuration changed (route/format) — rebuilding to keep recording alive")
                self.restartAudioAfterRouteChange()
            }
        }

        // State must be set before the request/task is installed so the callback's guard passes.
        state = .recording
        errorMessage = nil

        startRequestSoon(retriesLeft: 3)
        scheduleRotationTimer()
        Log.log("engine", "recognition task installed, audio engine running")
    }

    /// Full engine rebuild triggered by an audio route/format change. Preserves the transcript by
    /// committing it to the prefix first, then stands the engine back up against the new format.
    /// State stays `.recording` throughout — the session is never dropped.
    private func restartAudioAfterRouteChange() {
        guard state == .recording else { return }
        flattenIntoPrefix()
        stopAudio()
        // Brief delay so the audio unit settles on the new route before we re-tap it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.state == .recording else { return }
            self.startRecognition(retriesLeft: 3)
        }
    }

    /// Rebuilds `transcript` from its three parts. Called on every result so the view stays live
    /// while a rotated-out segment is still finalizing behind the scenes.
    private func composeTranscript() {
        transcript = [committedPrefix, pendingText, liveText]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        saveDraft()
    }

    // Safety net: the live transcript is mirrored to disk on every update, one file per session, in
    // ~/Library/Application Support/AITranscribePro/Drafts/. Nothing the recognizer has produced
    // can be lost to a logic bug again — worst case you open the draft file.
    private var draftURL: URL?
    private func saveDraft() {
        guard !transcript.isEmpty else { return }
        if draftURL == nil {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AITranscribePro/Drafts", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            draftURL = dir.appendingPathComponent("draft-\(f.string(from: Date())).txt")
        }
        if let url = draftURL { try? transcript.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Folds the finalizing segment into the committed prefix. `finalText`, when present, is the
    /// segment's authoritative final transcription and supersedes the last partial we held — this
    /// is the text the old implementation threw away on every rotation.
    private func settlePending(finalText: String?) {
        pendingSettleWork?.cancel()
        pendingSettleWork = nil
        guard pendingGeneration != 0 else { return }

        if let finalText, !finalText.isEmpty { pendingText = finalText }
        let segment = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !segment.isEmpty {
            committedPrefix = committedPrefix.isEmpty ? segment : committedPrefix + " " + segment
        }
        Log.log("engine", "segment gen=\(pendingGeneration) settled (+\(segment.count) chars, total=\(committedPrefix.count))")
        pendingText = ""
        pendingGeneration = 0
        composeTranscript()
    }

    /// Collapses everything on screen into `committedPrefix` and clears both segment slots. Used
    /// when the audio pipeline is about to be torn down (pause, route change) — at that point no
    /// further results are coming, so whatever we have is final.
    private func flattenIntoPrefix() {
        pendingSettleWork?.cancel()
        pendingSettleWork = nil
        composeTranscript()
        committedPrefix = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        liveText = ""
        pendingGeneration = 0
        liveGeneration = 0
    }

    /// Creates a fresh recognition request + task on the already-running audio engine and points
    /// the live tap at it. Returns false if no recognizer is ready right now, so the caller can
    /// decide whether to retry or leave the existing request running untouched.
    @discardableResult
    private func startRequest() -> Bool {
        guard state == .recording else { return false }

        guard let recognizer, recognizer.isAvailable else {
            Log.log("engine", "recognizer unavailable — cannot start request")
            return false
        }
        requestGeneration += 1
        let generation = requestGeneration

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Only touch this flag when opting in — the default (server) configuration is the one
        // that has always streamed results here, and we leave it exactly as-is.
        if useOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        // Repoint the live tap at the new request; the tap starts feeding it immediately.
        self.request = request
        liveGeneration = generation
        liveText = ""
        // Reset both watchdog clocks so a fresh segment gets a full grace period.
        windowStartedAt = Date()
        lastResultAt = Date()
        resultCount = 0

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard self.state == .recording else { return }
                if generation == self.liveGeneration {
                    if let text, !text.isEmpty { self.liveText = text }
                    self.lastResultAt = Date()
                    self.resultCount += 1
                    self.composeTranscript()
                    // Every result, on purpose: the last debugging round throttled this and made
                    // "results stopped" indistinguishable from "results 2–24 arrived silently".
                    Log.log("engine", "result gen=\(generation) #\(self.resultCount) chars=\(text?.count ?? -1) final=\(isFinal) transcriptChars=\(self.transcript.count)")
                    if error != nil || isFinal {
                        self.handleSegmentEnd(generation: generation, error: error as NSError?)
                    }
                } else if generation == self.pendingGeneration {
                    // The rotated-out segment is still reporting. Keep showing its latest text, and
                    // when its FINAL lands, fold it in — this is the tail the old code discarded.
                    // NEVER let an empty result blank the held text: after a long silence the old
                    // request's final result is "", which used to wipe the whole segment (lost a
                    // 4-minute recording). Only a non-empty transcription may replace it.
                    Log.log("engine", "late result gen=\(generation) chars=\(text?.count ?? -1) final=\(isFinal) held=\(self.pendingText.count)")
                    if let text, !text.isEmpty { self.pendingText = text }
                    self.composeTranscript()
                    if error != nil || isFinal {
                        self.settlePending(finalText: text)
                    }
                }
                // Anything from an older generation is genuinely stale and ignored.
            }
        }
        Log.log("engine", "request started generation=\(generation) onDevice=\(useOnDeviceRecognition) prefixChars=\(committedPrefix.count)")
        return true
    }

    /// Retry wrapper for the one place that has nothing to fall back on: the start of a session.
    private func startRequestSoon(retriesLeft: Int) {
        if startRequest() { return }
        guard retriesLeft > 0 else {
            errorMessage = "Speech recognizer unavailable."
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.state == .recording else { return }
            self.startRequestSoon(retriesLeft: retriesLeft - 1)
        }
    }

    /// A live segment finished on its own. That is normal — end-of-utterance ("No speech detected")
    /// or the recognizer's own 1-minute ceiling — and just means this request will emit no more, so
    /// we roll to a fresh one. The one case worth reacting to is a missing on-device model, which
    /// would otherwise make every subsequent request fail the same way.
    private func handleSegmentEnd(generation: Int, error: NSError?) {
        if let error {
            Log.log("engine", "segment ended [\(error.domain) \(error.code)] \(error.localizedDescription) — rolling")
            // kLSRErrorDomain 102 = on-device assets not installed/available. Drop to the server
            // path for the rest of the session instead of failing every roll from here on.
            if error.domain == "kLSRErrorDomain", error.code == 102, useOnDeviceRecognition {
                useOnDeviceRecognition = false
                Log.log("engine", "on-device assets unavailable — falling back to server recognition")
            }
        } else {
            Log.log("engine", "segment ended (isFinal) — rolling")
        }
        // This segment is done, so its text is final; promote it directly rather than waiting on a
        // flush that will never come.
        liveGeneration = 0
        pendingSettleWork?.cancel()
        pendingSettleWork = nil
        if pendingGeneration != 0 { settlePending(finalText: nil) }
        pendingGeneration = generation
        pendingText = liveText
        liveText = ""
        settlePending(finalText: nil)
        rollRequest(reason: "segment-end")
    }

    /// Single ticking timer with two jobs: rotate the request once `rotationInterval` has elapsed
    /// (bounding how much audio one request accumulates, keeping per-update latency flat), and
    /// force a roll if the recognizer has gone silent while the tap is still delivering audio.
    private func scheduleRotationTimer() {
        rotationTimer?.invalidate()
        lastSeenTapCount = tapBufferCount
        rotationTimer = Timer.scheduledTimer(withTimeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }

                // Is audio actually still arriving? If the tap has stalled too, this is an audio
                // problem, not a recognition one — the route-change observer owns that case.
                let taps = self.tapBufferCount
                let audioFlowing = taps > self.lastSeenTapCount
                self.lastSeenTapCount = taps

                let now = Date()
                if !audioFlowing, now.timeIntervalSince(self.engineStartedAt) > 3.0 {
                    // The tap has stopped delivering buffers entirely (distinct from silence, which
                    // still produces buffers) — the engine is wedged, e.g. a tap installed against
                    // a stale Bluetooth format. Only a full engine rebuild recovers this.
                    Log.log("audio", "tap delivering no buffers — rebuilding audio engine")
                    self.restartAudioAfterRouteChange()
                } else if now.timeIntervalSince(self.windowStartedAt) >= self.rotationInterval {
                    Log.log("engine", "rotation window elapsed — rolling request to keep latency flat")
                    self.rollRequest(reason: "window")
                } else if audioFlowing, self.liveGeneration != 0,
                          now.timeIntervalSince(self.lastResultAt) >= self.stallTimeout {
                    let quiet = Int(now.timeIntervalSince(self.lastResultAt))
                    Log.log("engine", "STALL: no results for \(quiet)s on gen=\(self.liveGeneration) while audio flows (\(self.resultCount) results so far) — rolling")
                    self.rollRequest(reason: "stall")
                }
            }
        }
    }

    /// Rotate the recognition request WITHOUT touching the audio engine. The replacement is stood
    /// up and `self.request` repointed first, so the tap never sees a nil request and no audio is
    /// dropped across the boundary. The outgoing request is then flushed with `endAudio()` and left
    /// running until it delivers its final result — it is NOT cancelled, because cancelling
    /// discards everything the recognizer has not yet reported (300–750ms of speech every time).
    /// A short debounce stops sustained silence (which ends utterances immediately) from spinning
    /// this in a tight loop.
    private func rollRequest(reason: String) {
        guard state == .recording else { return }

        let sinceLast = Date().timeIntervalSince(lastRollAt)
        if sinceLast < 0.6 {
            guard !rollScheduled else { return }
            rollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.6 - sinceLast)) { [weak self] in
                guard let self else { return }
                self.rollScheduled = false
                self.rollRequest(reason: reason)
            }
            return
        }
        lastRollAt = Date()

        // Only one segment may be finalizing at a time; settle any earlier one first.
        if pendingGeneration != 0 { settlePending(finalText: nil) }

        let outgoingRequest = request
        let outgoingTask = task
        let outgoingGeneration = liveGeneration
        let outgoingText = liveText

        // Stand up the replacement (bumps generation, repoints self.request → zero audio gap).
        guard startRequest() else {
            // No recognizer free right now — leave the current request running rather than
            // tearing down a working segment for nothing.
            liveGeneration = outgoingGeneration
            liveText = outgoingText
            Log.log("engine", "roll (\(reason)) aborted — no recognizer available, keeping current request")
            return
        }

        guard outgoingGeneration != 0 else { return }
        pendingGeneration = outgoingGeneration
        pendingText = outgoingText

        // Flush the outgoing request and let its final result land.
        outgoingRequest?.endAudio()

        // Safety net: if that final never arrives, settle with the last partial we hold so the
        // text is never stranded and the next rotation isn't blocked.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingGeneration == outgoingGeneration else { return }
            Log.log("engine", "segment gen=\(outgoingGeneration) never finalized — settling with last partial")
            outgoingTask?.finish()
            self.settlePending(finalText: nil)
        }
        pendingSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingSettleTimeout, execute: work)
    }

    /// The system's current default input device — i.e. whatever the user has selected in
    /// System Settings → Sound → Input (AirPods when connected and chosen).
    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// True while the device is still present with input streams (false once AirPods disconnect).
    private static func inputDeviceExists(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let cf = name?.takeRetainedValue() else { return "unknown" }
        return cf as String
    }

    private func stopAudio() {
        // Stop the rollover timer first so no rotation fires mid-teardown.
        rotationTimer?.invalidate()
        rotationTimer = nil
        rollScheduled = false
        // No further results are coming once the tap is gone, so drop the settle timer too.
        pendingSettleWork?.cancel()
        pendingSettleWork = nil
        liveGeneration = 0
        pendingGeneration = 0

        // Detach the route/format-change observer bound to the engine we're about to release.
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }

        // End the recognition task & request first so the recognizer stops pulling audio.
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil

        if let engine = audioEngine {
            if engine.isRunning { engine.stop() }
            engine.inputNode.removeTap(onBus: 0)
            // Explicitly sever graph connections to the input node before releasing the engine.
            // Without these disconnects, the underlying CoreAudio HAL connection to the microphone
            // hardware is held warm and can re-light the mic indicator when the system audio
            // subsystem is probed by unrelated apps (e.g. YouTube play, media keys).
            engine.disconnectNodeInput(engine.inputNode)
            engine.disconnectNodeOutput(engine.inputNode)
            engine.reset()
        }
        audioEngine = nil
        Log.log("audio", "stopAudio → engine released + input disconnected")
    }
}
