import Foundation
import AVFoundation
import UIKit

@MainActor
@Observable
class LiveModeManager {
    var isActive = false
    var isProcessing = false
    var isSpeaking = false
    var currentTranscription = ""
    var lastResponse = ""
    var errorMessage: String?

    /// Live partial speech text from the recognizer
    var speechText: String { speechManager.transcribedText }

    /// Whether the broadcast extension is currently streaming the device screen.
    var isBroadcastActive: Bool { screenCapture.isBroadcastActive }
    /// Current detected target device for phone commands.
    var connectedDevice: String? { deviceDetector.detectedDevice }

    private let speechManager = SpeechManager()
    private let openRouter: OpenRouterService
    private let screenCapture = ScreenCaptureManager()
    private let deviceDetector = DeviceDetector()
    #if canImport(ActivityKit)
    #endif
    private var requestId = 0

    // Cartesia TTS
    private let cartesiaAPIKey = "sk_car_LX13WDzurrLVVk3k2GU8hk"
    private let cartesiaVoiceId = "e8e5fffb-252c-436d-b842-8879b84445b6"
    private let cartesiaModelId = "sonic-3"

    init(apiKey: String) {
        openRouter = OpenRouterService(apiKey: apiKey)
    }

    // MARK: - Phone Control (via WiFi relay)

    private let phoneBaseURL = "https://claire.ariv.sh"

    /// Send commands to ESP32 via the WiFi relay server.
    func sendPhoneCommands(_ commands: [String], delay: Double = 0) {
        print("[Phone] Sending commands: \(commands) to \(phoneBaseURL)/commands")
        Task {
            do {
                let url = URL(string: "\(phoneBaseURL)/commands")!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var body: [String: Any] = ["commands": commands, "delay": delay]
                if let device = deviceDetector.detectedDevice {
                    body["device"] = device
                    print("[Phone] Targeting device: \(device)")
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                print("[Phone] Request ready, sending...")

                let (data, response) = try await URLSession.shared.data(for: request)
                let httpResponse = response as? HTTPURLResponse
                print("[Phone] HTTP \(httpResponse?.statusCode ?? -1)")
                let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
                print("[Phone] Body: \(bodyStr)")
            } catch {
                print("[Phone] Error: \(error)")
            }
        }
    }

    // MARK: - Start / Stop

    func startLiveMode() async {
        guard !isActive else { return }

        let granted = await speechManager.requestPermissions()
        guard granted else {
            errorMessage = "Microphone & speech recognition permissions are required."
            return
        }

        isActive = true
        errorMessage = nil
        lastResponse = ""
        currentTranscription = ""
        requestId = 0
        openRouter.clearHistory()

        // Speech recognition
        do {
            try speechManager.startListening { [weak self] utterance in
                print("[LiveMode] Got utterance: \(utterance.prefix(60))...")
                self?.handleUtterance(utterance)
            }
            print("[LiveMode] Speech recognition started")
        } catch {
            errorMessage = "Speech recognition failed: \(error.localizedDescription)"
            print("[LiveMode] Speech failed: \(error)")
            await stopLiveMode()
        }
    }

    func stopLiveMode() async {
        guard isActive else { return }

        speechManager.stopAudio()
        speechManager.stopListening()
        isSpeaking = false

        isActive = false
        isProcessing = false
        currentTranscription = ""
    }

    // MARK: - Utterance handling

    private func handleUtterance(_ text: String) {
        // Interrupt: if currently speaking, stop TTS and process the new utterance
        if isSpeaking {
            print("[LiveMode] Interrupting TTS for new utterance")
            speechManager.stopAudio()
            isSpeaking = false
        }

        currentTranscription = text
        isProcessing = true
        // Bump requestId so any in-flight response from the old request is discarded
        requestId += 1
        let myId = requestId

        print("[LiveMode] Sending to OpenRouter...")

        Task {
            do {
                let response = try await openRouter.sendMessage(text)
                guard self.requestId == myId else { return }

                switch response {
                case .text(let responseText):
                    showResponse(responseText)

                case .toolCall(let id, let name, let arguments):
                    print("[LiveMode] Tool call requested: \(name)")
                    if name == "get_screenshot" {
                        await handleScreenshotTool(toolCallId: id, requestId: myId)
                    } else if name == "send_phone_commands" {
                        await handlePhoneCommandsTool(toolCallId: id, arguments: arguments, requestId: myId)
                    }
                }
            } catch {
                guard self.requestId == myId else { return }
                showError(error)
            }
        }
    }

    // MARK: - Tool execution

    private func handleScreenshotTool(toolCallId: String, requestId myId: Int) async {
        guard screenCapture.isBroadcastActive else {
            showResponse("Screen broadcast is not active. Please start the broadcast from the Sotos app first.")
            return
        }

        guard let screenshotData = screenCapture.takeScreenshot() else {
            showResponse("Couldn't read the screen. Please make sure the broadcast is running.")
            return
        }

        let base64 = screenshotData.base64EncodedString()
        print("[LiveMode] Screenshot captured, \(base64.count) base64 chars")

        do {
            let response = try await openRouter.sendScreenshotResult(
                toolCallId: toolCallId,
                imageBase64: base64
            )
            guard self.requestId == myId else { return }
            showResponse(response)
        } catch {
            guard self.requestId == myId else { return }
            showError(error)
        }
    }

    private func handlePhoneCommandsTool(toolCallId: String, arguments: [String: Any], requestId myId: Int) async {
        guard let commands = arguments["commands"] as? [String], !commands.isEmpty else {
            showResponse("No commands provided.")
            return
        }
        let delay = arguments["delay"] as? Double ?? 0

        print("[LiveMode] Executing phone commands: \(commands), delay: \(delay)")
        sendPhoneCommands(commands, delay: delay)

        // Send tool result back to LLM so it can confirm the action
        do {
            let response = try await openRouter.sendToolResult(
                toolCallId: toolCallId,
                result: "Commands sent successfully: \(commands.joined(separator: ", "))"
            )
            guard self.requestId == myId else { return }

            switch response {
            case .text(let text):
                showResponse(text)
            case .toolCall(let id, let name, let args):
                // Handle chained tool calls
                if name == "get_screenshot" {
                    await handleScreenshotTool(toolCallId: id, requestId: myId)
                } else if name == "send_phone_commands" {
                    await handlePhoneCommandsTool(toolCallId: id, arguments: args, requestId: myId)
                }
            }
        } catch {
            guard self.requestId == myId else { return }
            showError(error)
        }
    }

    // MARK: - Cartesia TTS

    private func speak(_ text: String) {
        speechManager.stopAudio()
        isSpeaking = true

        Task {
            do {
                let audioData = try await fetchCartesiaTTS(text: text)
                guard self.isSpeaking else { return } // interrupted while fetching

                speechManager.playAudio(data: audioData) { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        self.isSpeaking = false
                        print("[TTS] Playback finished")
                    }
                }
            } catch {
                print("[TTS] Cartesia error: \(error)")
                self.isSpeaking = false
            }
        }
    }

    private func fetchCartesiaTTS(text: String) async throws -> Data {
        let url = URL(string: "https://api.cartesia.ai/tts/bytes")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("2025-04-16", forHTTPHeaderField: "Cartesia-Version")
        request.setValue("Bearer \(cartesiaAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue(cartesiaAPIKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model_id": cartesiaModelId,
            "transcript": text,
            "voice": [
                "mode": "id",
                "id": cartesiaVoiceId
            ],
            "language": "en",
            "output_format": [
                "container": "wav",
                "encoding": "pcm_s16le",
                "sample_rate": 44100
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw NSError(domain: "CartesiaTTS", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Cartesia TTS failed (\(status)): \(detail)"
            ])
        }
        return data
    }

    // MARK: - UI helpers

    private func showResponse(_ text: String) {
        print("[LiveMode] Got response: \(text.prefix(60))...")
        lastResponse = text
        isProcessing = false
        speak(text)
    }

    private func showError(_ error: Error) {
        print("[LiveMode] API error: \(error)")
        lastResponse = "Error: \(error.localizedDescription)"
        isProcessing = false
    }

}
