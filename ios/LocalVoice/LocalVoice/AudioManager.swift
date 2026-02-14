import FluidAudio
import AVFoundation

@Observable
final class AudioManager {
    var confirmedText = ""
    var volatileText = ""
    var isListening = false
    var isSpeaking = false
    var statusMessage = "Tap to start"
    var isLoading = false
    var vadProbability: Float = 0

    var displayText: String { confirmedText + volatileText }

    private var streamingAsr: StreamingAsrManager?
    private var vadManager: VadManager?
    private var vadState: VadStreamState?
    private let audioEngine = AVAudioEngine()
    private var vadContinuation: AsyncStream<[Float]>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var vadTask: Task<Void, Never>?

    // MARK: - Public

    func startListening() async {
        guard !isListening else { return }
        isLoading = true
        confirmedText = ""
        volatileText = ""

        do {
            // 1. Mic permission
            statusMessage = "Requesting mic access…"
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else {
                statusMessage = "Microphone permission denied"
                isLoading = false
                return
            }

            // 2. ASR
            statusMessage = "Loading ASR model…"
            let asrConfig = StreamingAsrConfig.streaming
            streamingAsr = StreamingAsrManager(config: asrConfig)
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            try await streamingAsr?.start(models: models, source: .microphone)

            // 3. VAD
            statusMessage = "Loading VAD model…"
            vadManager = try await VadManager()
            vadState = await vadManager?.makeStreamState()

            // 4. VAD async stream for serialised chunk processing
            let (vadStream, continuation) = AsyncStream<[Float]>.makeStream()
            vadContinuation = continuation
            startVadProcessing(stream: vadStream)

            // 5. Transcription update listener
            startTranscriptionListener()

            // 6. Audio engine
            let inputNode = audioEngine.inputNode
            let nativeFormat = inputNode.outputFormat(forBus: 0)
            let asrRef = streamingAsr
            let vadCont = vadContinuation

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
                // Resample to 16 kHz mono for VAD
                let samples = AudioManager.resampleToMono16kHz(buffer)
                vadCont?.yield(samples)

                // Feed raw buffer to ASR (handles conversion internally)
                Task.detached { await asrRef?.streamAudio(buffer) }
            }

            audioEngine.prepare()
            try audioEngine.start()

            isListening = true
            isLoading = false
            statusMessage = "Listening…"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            isLoading = false
        }
    }

    func stopListening() async {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        vadContinuation?.finish()
        vadTask?.cancel()
        transcriptionTask?.cancel()

        if let finalText = try? await streamingAsr?.finish(), !finalText.isEmpty {
            confirmedText = finalText
            volatileText = ""
        }

        streamingAsr = nil
        vadManager = nil
        vadState = nil
        vadContinuation = nil
        transcriptionTask = nil
        vadTask = nil
        isListening = false
        isSpeaking = false
        vadProbability = 0
        statusMessage = "Tap to start"
    }

    // MARK: - Private helpers

    private func startVadProcessing(stream: AsyncStream<[Float]>) {
        vadTask = Task { [weak self] in
            var sampleBuffer: [Float] = []
            let chunkSize = 4096 // VadManager.chunkSize – 256 ms at 16 kHz

            for await samples in stream {
                guard let self else { break }
                sampleBuffer.append(contentsOf: samples)

                while sampleBuffer.count >= chunkSize {
                    let chunk = Array(sampleBuffer.prefix(chunkSize))
                    sampleBuffer.removeFirst(chunkSize)

                    guard let vad = self.vadManager,
                          let state = self.vadState else { continue }

                    do {
                        let result = try await vad.processStreamingChunk(
                            chunk, state: state, returnSeconds: true
                        )
                        self.vadState = result.state
                        self.vadProbability = result.probability

                        if let event = result.event {
                            self.isSpeaking = event.kind == .speechStart
                        }
                    } catch {
                        print("VAD error: \(error)")
                    }
                }
            }
        }
    }

    private func startTranscriptionListener() {
        transcriptionTask = Task { [weak self] in
            guard let asr = self?.streamingAsr else { return }
            for await update in await asr.transcriptionUpdates {
                guard let self else { break }
                if update.isConfirmed {
                    self.confirmedText = update.text
                    self.volatileText = ""
                } else {
                    self.volatileText = update.text
                }
            }
        }
    }

    // MARK: - Audio conversion

    /// Downmix to mono and resample to 16 kHz using linear interpolation.
    nonisolated private static func resampleToMono16kHz(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }

        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate

        // Mix to mono
        var mono = [Float](repeating: 0, count: frameCount)
        for ch in 0..<channelCount {
            let channel = channelData[ch]
            for i in 0..<frameCount {
                mono[i] += channel[i]
            }
        }
        if channelCount > 1 {
            let scale = 1.0 / Float(channelCount)
            for i in 0..<frameCount { mono[i] *= scale }
        }

        guard sampleRate != 16000 else { return mono }

        // Linear-interpolation resample
        let ratio = 16000.0 / sampleRate
        let outputCount = Int(Double(frameCount) * ratio)
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcPos = Double(i) / ratio
            let srcIdx = Int(srcPos)
            let frac = Float(srcPos - Double(srcIdx))
            if srcIdx + 1 < frameCount {
                output[i] = mono[srcIdx] * (1.0 - frac) + mono[srcIdx + 1] * frac
            } else if srcIdx < frameCount {
                output[i] = mono[srcIdx]
            }
        }

        return output
    }
}
