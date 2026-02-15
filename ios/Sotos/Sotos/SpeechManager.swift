import Speech
import AVFoundation

@Observable
class SpeechManager {
    var transcribedText: String = ""
    var isListening: Bool = false

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var onUtteranceCallback: ((String) -> Void)?
    private var generation: Int = 0
    private var silenceTimer: Timer?
    private var lastPartialText: String = ""

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        let micStatus = await AVAudioApplication.requestRecordPermission()
        return speechStatus == .authorized && micStatus
    }

    func startListening(onUtterance: @escaping (String) -> Void) throws {
        stopListening()
        onUtteranceCallback = onUtterance
        try beginRecognition()
    }

    private func beginRecognition() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw SpeechError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        recognitionRequest = request

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isListening = true
        lastPartialText = ""

        generation += 1
        let currentGen = generation

        print("[Speech] Recognition started (gen \(currentGen))")

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isListening, self.generation == currentGen else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    self.transcribedText = text
                    self.lastPartialText = text

                    // Reset silence timer on each partial result
                    self.resetSilenceTimer()

                    if result.isFinal {
                        print("[Speech] Final result: \(text.prefix(50))...")
                        self.silenceTimer?.invalidate()
                        self.silenceTimer = nil
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            self.onUtteranceCallback?(trimmed)
                        }
                        self.restart()
                        return
                    }
                }

                if let error {
                    print("[Speech] Error: \(error.localizedDescription)")
                    self.silenceTimer?.invalidate()
                    self.silenceTimer = nil
                    let text = self.transcribedText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self.onUtteranceCallback?(text)
                    }
                    self.restart()
                }
            }
        }
    }

    /// After 1.5s of no new partial results, treat current text as a complete utterance
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                let text = self.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    print("[Speech] Silence timer fired, submitting: \(text.prefix(50))...")
                    self.onUtteranceCallback?(text)
                }
                self.restart()
            }
        }
    }

    private func restart() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopInternal()
        transcribedText = ""
        lastPartialText = ""
        guard onUtteranceCallback != nil else { return }
        do {
            try beginRecognition()
        } catch {
            print("[Speech] Restart failed: \(error)")
            isListening = false
        }
    }

    private func stopInternal() {
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        onUtteranceCallback = nil
        stopInternal()
        isListening = false
        transcribedText = ""
        generation += 1
    }

    enum SpeechError: LocalizedError {
        case recognizerUnavailable

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable: return "Speech recognizer unavailable"
            }
        }
    }
}
