import Speech
import AVFoundation
import Foundation

@Observable
final class AudioManager {
    var transcription = ""
    var response = ""
    var isRecording = false
    var isThinking = false
    var statusMessage = "Tap to record"

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Recording

    func startRecording() async {
        guard !isRecording else { return }

        let speechAuth = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechAuth == .authorized else {
            statusMessage = "Speech recognition permission denied"
            return
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            statusMessage = "Microphone permission denied"
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable"
            return
        }

        transcription = ""
        response = ""

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    self.transcription = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.cleanupRecognition()
                }
            }

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            statusMessage = "Recording…"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
            cleanupRecognition()
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

        // Wait a moment for final transcription to settle
        try? await Task.sleep(for: .milliseconds(500))

        let text = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = "Didn't catch that — try again"
            return
        }

        await fetchResponse(for: text)
    }

    private func cleanupRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    // MARK: - OpenRouter

    private let openRouterKey = "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"
    private let openRouterEndpoint = "https://openrouter.ai/api/v1/chat/completions"
    private let model = "google/gemini-3-flash-preview"

    private func fetchResponse(for userText: String) async {
        isThinking = true
        statusMessage = "Thinking…"

        let messages: [[String: String]] = [
            ["role": "system", "content": "You are a helpful assistant. Respond concisely in 1-3 sentences."],
            ["role": "user", "content": userText]
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.7,
            "max_tokens": 256
        ]

        do {
            var request = URLRequest(url: URL(string: openRouterEndpoint)!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(openRouterKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, httpResponse) = try await URLSession.shared.data(for: request)

            guard let status = (httpResponse as? HTTPURLResponse)?.statusCode, status == 200 else {
                statusMessage = "API error"
                isThinking = false
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            let content = message?["content"] as? String ?? ""

            response = content.trimmingCharacters(in: .whitespacesAndNewlines)
            statusMessage = "Done — tap to record again"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }

        isThinking = false
    }
}
