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

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    // Optional + recreated per session so stopping the recording fully releases the mic hardware.
    // Keeping a long-lived AVAudioEngine instance caused the mic to re-activate on system audio
    // events (YouTube play, spacebar media keys) even though our app was "idle".
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapBufferCount: Int = 0
    private var configChangeObserver: NSObjectProtocol?
    private var bufferWatchdog: DispatchWorkItem?

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

    private func startRecognition(retriesLeft: Int = 0, forceBuiltInMic: Bool = false) {
        Log.log("engine", "startRecognition retriesLeft=\(retriesLeft) forceBuiltInMic=\(forceBuiltInMic) isAvailable=\(recognizer?.isAvailable ?? false)")
        guard let recognizer else {
            errorMessage = "Speech recognizer unavailable."
            return
        }
        if !recognizer.isAvailable {
            if retriesLeft > 0 {
                Log.log("engine", "recognizer not yet available, retrying in 300ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startRecognition(retriesLeft: retriesLeft - 1, forceBuiltInMic: forceBuiltInMic)
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

        // If the default input device isn't delivering audio (e.g. Bluetooth headphones in A2DP
        // mode), force the engine to use the built-in microphone instead.
        if forceBuiltInMic, let builtIn = builtInMicDeviceID() {
            let name = deviceName(builtIn)
            if setInputDevice(builtIn, on: audioEngine) {
                Log.log("audio", "forced input to built-in mic: \(name) (id=\(builtIn))")
            } else {
                Log.log("audio", "failed to force built-in mic: \(name) (id=\(builtIn))")
            }
        }

        // Watch for audio route changes (headphones plugged/unplugged, Bluetooth device
        // connected, etc.). When the hardware config changes mid-recording the existing tap
        // format is stale and audio silently stops flowing — restart the pipeline.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.log("audio", "AVAudioEngineConfigurationChange — audio route changed")
            Task { @MainActor in
                guard self.state == .recording else { return }
                Log.log("audio", "restarting recognition after route change")
                self.committedPrefix = self.transcript
                self.stopAudio()
                // Brief delay so the new audio device settles before we re-tap.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.state == .recording else { return }
                    self.startRecognition(retriesLeft: 3)
                }
            }
        }

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
        let tapFormat = inputNode.outputFormat(forBus: 0)
        Log.log("audio", "tap format (native) sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")

        tapBufferCount = 0
        inputNode.removeTap(onBus: 0)
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

        // Watchdog: if no tap buffers arrive within 2 seconds, the default input device is
        // probably dead (common with Bluetooth headphones in A2DP output-only mode). Restart
        // with the built-in microphone forced as input.
        if !forceBuiltInMic {
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    guard self.state == .recording, self.tapBufferCount == 0 else { return }
                    Log.log("audio", "watchdog: zero buffers after 2s — forcing built-in mic")
                    self.committedPrefix = self.transcript
                    self.stopAudio()
                    self.startRecognition(retriesLeft: 3, forceBuiltInMic: true)
                }
            }
            self.bufferWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: watchdog)
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
        // Cancel the watchdog so it doesn't fire after teardown.
        bufferWatchdog?.cancel()
        bufferWatchdog = nil

        // Remove the config-change observer before tearing down the engine so we don't
        // re-enter during teardown.
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
            configChangeObserver = nil
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

    // MARK: - CoreAudio device helpers

    /// Returns the AudioDeviceID of the built-in microphone, or nil if not found.
    private nonisolated func builtInMicDeviceID() -> AudioDeviceID? {
        var propSize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize) == noErr else { return nil }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propSize, &devices) == noErr else { return nil }

        for id in devices {
            // Check if device has input channels.
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufListSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &bufListSize) == noErr, bufListSize > 0 else { continue }
            let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufListPtr.deallocate() }
            guard AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &bufListSize, bufListPtr) == noErr else { continue }
            let channelCount = (0..<Int(bufListPtr.pointee.mNumberBuffers)).reduce(0) { total, i in
                total + Int(UnsafeMutableAudioBufferListPointer(bufListPtr)[i].mNumberChannels)
            }
            guard channelCount > 0 else { continue }

            // Check transport type — built-in is kAudioDeviceTransportTypeBuiltIn.
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr else { continue }
            if transport == kAudioDeviceTransportTypeBuiltIn {
                return id
            }
        }
        return nil
    }

    /// Returns a human-readable name for a CoreAudio device.
    private nonisolated func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let cfName = name?.takeUnretainedValue() else { return "unknown" }
        return cfName as String
    }

    /// Sets the AVAudioEngine's input device to the given CoreAudio device ID.
    private func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> Bool {
        let audioUnit = engine.inputNode.audioUnit!
        var devID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }
}
