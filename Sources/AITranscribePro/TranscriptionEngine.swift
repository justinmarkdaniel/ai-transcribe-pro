import Foundation
import Speech
import AVFoundation
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

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    // Optional + recreated per session so stopping the recording fully releases the mic hardware.
    // Keeping a long-lived AVAudioEngine instance caused the mic to re-activate on system audio
    // events (YouTube play, spacebar media keys) even though our app was "idle".
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapBufferCount: Int = 0

    // Anything finalized in previous recording segments (survives pause/resume).
    private var committedPrefix: String = ""

    var onCommit: ((String) -> Void)?

    /// Proactively asks for Speech + Microphone access so the first record press
    /// doesn't get swallowed by permission prompts.
    func prewarmAuthorization() {
        Log.log("engine", "prewarm auth")
        requestAuthorization { _ in }
    }

    /// Called by the global hotkey: start a fresh recording, or stop an in-progress one.
    /// Paused counts as "in progress" — the hotkey finalises it.
    func hotKeyTriggered() {
        Log.log("engine", "hotKeyTriggered state=\(state)")
        switch state {
        case .recording, .paused:
            stop()
        case .idle, .stopped:
            start()
        }
    }

    func toggleRecord() {
        switch state {
        case .idle:      start()
        case .recording: pause()
        case .paused:    resume()
        case .stopped:   start() // clear previous transcript and begin a fresh session
        }
    }

    func reset() {
        stopAudio()
        transcript = ""
        committedPrefix = ""
        state = .idle
        errorMessage = nil
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
        committedPrefix = transcript
        stopAudio()
        state = .paused
    }

    private func resume() {
        guard state == .paused else { return }
        startRecognition()
    }

    private func start() {
        Log.log("engine", "start()")
        committedPrefix = ""
        transcript = ""
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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.addsPunctuation = true
        }
        self.request = request

        // State must be set before the task is installed so the callback's state-guard passes.
        state = .recording
        errorMessage = nil
        let prefix = committedPrefix

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Log.log("engine", "recognition callback result=\(result?.bestTranscription.formattedString.count ?? -1) chars final=\(result?.isFinal ?? false) error=\(error?.localizedDescription ?? "nil")")
            Task { @MainActor in
                guard self.state == .recording else { return }
                if let result {
                    let segment = result.bestTranscription.formattedString
                    if prefix.isEmpty {
                        self.transcript = segment
                    } else {
                        self.transcript = prefix + " " + segment
                    }
                }
                if let error {
                    Log.log("engine", "recognition error: \(error.localizedDescription) — restarting transparently")
                    self.restartRecognitionAfterError()
                }
            }
        }

        let inputNode = audioEngine.inputNode
        // IMPORTANT: on an AVAudioEngine input node you MUST pass the node's native output
        // format to installTap — Apple's docs say it does not auto-convert for input nodes and
        // passing a mismatched format throws an unrecoverable Objective-C exception (hard crash).
        // SFSpeechAudioBufferRecognitionRequest.append() accepts PCM at any sample rate; the
        // recognizer handles resampling internally. This matches Apple's SpokenWord sample.
        let tapFormat = inputNode.outputFormat(forBus: 0)
        Log.log("audio", "tap format (native) sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")

        tapBufferCount = 0
        inputNode.removeTap(onBus: 0)
        // bufferSize 4096 is safer across macOS versions than 1024 for input node taps.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.request?.append(buffer)
            self.tapBufferCount += 1
            if self.tapBufferCount == 1 || self.tapBufferCount % 50 == 0 {
                Log.log("audio", "tap buffer #\(self.tapBufferCount) frames=\(buffer.frameLength) sampleRate=\(buffer.format.sampleRate)")
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            Log.log("audio", "audio engine started")
        } catch {
            Log.log("audio", "audio engine failed: \(error.localizedDescription)")
            errorMessage = "Audio engine failed: \(error.localizedDescription)"
            return
        }

        Log.log("engine", "recognition task installed, audio engine running")
    }

    private func restartRecognitionAfterError() {
        guard state == .recording else { return }
        committedPrefix = transcript
        stopAudio()
        // Brief delay so the audio unit can reset cleanly before we re-tap it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.state == .recording else { return }
            self.startRecognition(retriesLeft: 3)
        }
    }

    private func stopAudio() {
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
