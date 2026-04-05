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
    private let audioEngine = AVAudioEngine()
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
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        Log.log("audio", "input node native format sampleRate=\(nativeFormat.sampleRate) channels=\(nativeFormat.channelCount)")

        // Ask AVAudioEngine to deliver buffers at 16 kHz mono Float32 — what the speech recognizer
        // expects. On macOS 10.15+ installTap auto-converts when the requested format differs from
        // the node's output format. This is the fix for the "tap never fires at 44.1 kHz" bug.
        let tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) ?? nativeFormat
        Log.log("audio", "tap requested format sampleRate=\(tapFormat.sampleRate) channels=\(tapFormat.channelCount)")

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
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }
}
