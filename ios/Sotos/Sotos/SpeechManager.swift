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
    private var playerNode: AVAudioPlayerNode?
    private var onUtteranceCallback: ((String) -> Void)?
    private var generation: Int = 0
    private var silenceTimer: Timer?
    private var lastDeliveredText: String = ""
    private var lastDeliveredAt: Date = .distantPast
    private var audioSessionConfigured = false
    private var tapBufferCounter: Int = 0

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        let micStatus = await AVAudioApplication.requestRecordPermission()
        print("[Speech] Permission status - speech: \(speechStatus.rawValue), mic: \(micStatus)")
        return speechStatus == .authorized && micStatus
    }

    // MARK: - Audio session (one-shot, never deactivated)

    private func configureAudioSessionIfNeeded() throws {
        guard !audioSessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
        } catch {
            print("[Speech] Audio setCategory failed: \(error)")
            throw error
        }
        do {
            try session.setActive(true)
        } catch {
            print("[Speech] Audio setActive failed: \(error)")
            throw error
        }
        audioSessionConfigured = true
    }

    // MARK: - Engine lifecycle

    /// Creates the AVAudioEngine with VPIO + player node but does NOT start it.
    /// Call startEngineIfNeeded() after installing taps / before playback.
    private func ensureEngineCreated() throws {
        guard audioEngine == nil else { return }

        try configureAudioSessionIfNeeded()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)

        engine.connect(player, to: engine.mainMixerNode, format: nil)

        audioEngine = engine
        playerNode = player
    }

    /// Prepare + start the engine if it isn't already running.
    private func startEngineIfNeeded() throws {
        guard let engine = audioEngine, !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
        print("[Speech] Engine started with voice processing")
    }

    private func teardownEngine() {
        playerNode?.stop()
        playerNode = nil
        audioEngine?.stop()
        audioEngine = nil
    }

    // MARK: - TTS playback through the engine

    func playAudio(data: Data, completion: @escaping () -> Void) {
        playerNode?.stop()

        do {
            try ensureEngineCreated()
            try startEngineIfNeeded()
            guard let player = playerNode else {
                completion()
                return
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tts_\(UUID().uuidString).wav")
            try data.write(to: tempURL)

            let audioFile = try AVAudioFile(forReading: tempURL)
            let format = audioFile.processingFormat
            let frameCount = UInt32(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                try? FileManager.default.removeItem(at: tempURL)
                completion()
                return
            }
            try audioFile.read(into: buffer)
            try? FileManager.default.removeItem(at: tempURL)

            // Reconnect player with the buffer's format so channel counts match.
            // The engine handles any conversion to the VPIO output format.
            if let engine = audioEngine {
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }

            player.scheduleBuffer(buffer) {
                DispatchQueue.main.async { completion() }
            }
            player.play()
            print("[Speech] Playing TTS through engine (\(data.count) bytes)")
        } catch {
            print("[Speech] playAudio failed: \(error)")
            completion()
        }
    }

    func stopAudio() {
        playerNode?.stop()
    }

    // MARK: - Recognition

    func startListening(onUtterance: @escaping (String) -> Void) throws {
        stopRecognition()
        isListening = false
        onUtteranceCallback = onUtterance
        try beginRecognition()
    }

    private func beginRecognition() throws {
        do {
            try ensureEngineCreated()
            guard let engine = audioEngine else { throw SpeechError.recognizerUnavailable }

            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            guard let speechRecognizer, speechRecognizer.isAvailable else {
                throw SpeechError.recognizerUnavailable
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            recognitionRequest = request

            let inputNode = engine.inputNode

            // Start the engine FIRST so the VPIO audio unit fully initialises
            // and the hardware sample rate / channel count are settled.
            try startEngineIfNeeded()

            let recordingFormat = inputNode.outputFormat(forBus: 0)
            print("[Speech] Recording format: \(recordingFormat)")
            tapBufferCounter = 0

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
                self.tapBufferCounter += 1
                if self.tapBufferCounter % 60 == 0 {
                    if let channelData = buffer.floatChannelData {
                        let frameLength = Int(buffer.frameLength)
                        if frameLength > 0 {
                            let samples = channelData[0]
                            var sum: Float = 0
                            for i in 0..<frameLength {
                                let s = samples[i]
                                sum += s * s
                            }
                            let rms = sqrt(sum / Float(frameLength))
                            print(String(format: "[Speech] Mic RMS: %.5f", rms))
                        }
                    }
                }
            }

            isListening = true
            generation += 1
            let currentGen = generation

            print("[Speech] Recognition started (gen \(currentGen))")

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.isListening, self.generation == currentGen else { return }

                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.transcribedText = text
                        self.resetSilenceTimer()
                        print("[Speech] Partial: \(text.prefix(50))...")

                        if result.isFinal {
                            print("[Speech] Final result: \(text.prefix(50))...")
                            self.silenceTimer?.invalidate()
                            self.silenceTimer = nil
                            self.submitUtteranceIfNeeded()
                            self.restart()
                            return
                        }
                    }

                    if let error {
                        print("[Speech] Error: \(error.localizedDescription)")
                        self.silenceTimer?.invalidate()
                        self.silenceTimer = nil
                        self.submitUtteranceIfNeeded()
                        self.restart()
                    }
                }
            }
        } catch {
            stopRecognition()
            isListening = false
            let session = AVAudioSession.sharedInstance()
            let route = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: ",")
            print("[Speech] beginRecognition failed, route inputs: \(route)")
            throw error
        }
    }

    /// Stop only recognition (tap + task). Engine stays alive for playback.
    private func stopRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    // MARK: - Silence timer

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                let text = self.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    print("[Speech] Silence timer fired, submitting: \(text.prefix(50))...")
                    self.submitUtteranceIfNeeded()
                    self.restart()
                }
            }
        }
    }

    // MARK: - Utterance delivery

    @discardableResult
    private func submitUtteranceIfNeeded() -> Bool {
        let text = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let now = Date()
        if text == lastDeliveredText, now.timeIntervalSince(lastDeliveredAt) < 1.0 {
            transcribedText = ""
            return false
        }

        lastDeliveredText = text
        lastDeliveredAt = now
        onUtteranceCallback?(text)
        transcribedText = ""
        return true
    }

    // MARK: - Restart / pause / resume

    private func restart() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopRecognition()
        transcribedText = ""
        guard onUtteranceCallback != nil else { return }
        do {
            try beginRecognition()
        } catch {
            print("[Speech] Restart failed: \(error)")
            isListening = false
        }
    }

    func pauseListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopRecognition()
        isListening = false
        transcribedText = ""
    }

    func resumeListening() {
        resumeListening(retryCount: 0)
    }

    private func resumeListening(retryCount: Int) {
        guard onUtteranceCallback != nil, !isListening else { return }
        do {
            try beginRecognition()
        } catch {
            print("[Speech] Resume failed: \(error)")
            guard retryCount < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.resumeListening(retryCount: retryCount + 1)
            }
        }
    }

    func stopListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        onUtteranceCallback = nil
        stopRecognition()
        teardownEngine()
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
