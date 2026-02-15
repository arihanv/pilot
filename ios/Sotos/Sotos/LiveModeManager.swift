import Foundation
import AVFoundation
import UIKit
import ReplayKit

/// Singleton that holds a hidden RPSystemBroadcastPickerView and can
/// programmatically trigger its internal button.
final class BroadcastPicker {
    static let shared = BroadcastPicker()

    private let picker: RPSystemBroadcastPickerView = {
        let p = RPSystemBroadcastPickerView()
        p.preferredExtension = "dev.ethan.Sotos.BroadcastExtension"
        p.showsMicrophoneButton = false
        return p
    }()

    @MainActor
    func tap() {
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .allTouchEvents)
                return
            }
        }
    }
}

@MainActor
@Observable
class LiveModeManager {
    var isActive = false
    var isProcessing = false
    var isSpeaking = false
    var currentTranscription = ""
    var lastResponse = ""
    var errorMessage: String?

    /// Status text shown during CUA execution (e.g. "Analyzing screen: app icons").
    var cuaStatus: String = ""

    var speechText: String { speechManager.transcribedText }
    var isBroadcastActive: Bool { screenCapture.isBroadcastActive }
    var connectedDevice: String? { deviceDetector.selectedDevice }

    private let speechManager = SpeechManager()
    private let openRouter: OpenRouterService
    private let screenCapture = ScreenCaptureManager()
    private let moondream = MoondreamService(apiKey: Config.moondreamAPIKey)
    let deviceDetector = DeviceDetector()
    private var requestId = 0

    // CUA state
    private var lastElements: [DetectedElement] = []
    private var lastScreenshotData: Data?
    private let maxCUASteps = 25

    // Cartesia TTS
    private let cartesiaAPIKey = "sk_car_bx91c6sUzBR4z6gfzF49UF" // sk_car_LX13WDzurrLVVk3k2GU8hk
    private let cartesiaVoiceId = "e8e5fffb-252c-436d-b842-8879b84445b6"
    private let cartesiaModelId = "sonic-3"

    init(apiKey: String) {
        openRouter = OpenRouterService(apiKey: apiKey)
        // Clear any stale broadcast flag from a previous session
        screenCapture.clearBroadcastFlag()
    }

    // MARK: - Phone Control (via WiFi relay)

    private let phoneBaseURL = "https://claire.ariv.sh"

    /// Send commands to ESP32 via the WiFi relay server. Awaits completion.
    private func sendPhoneCommands(_ commands: [String], delay: Double = 0) async {
        print("[Phone] Commands: \(commands)")
        do {
            let url = URL(string: "\(phoneBaseURL)/commands")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 30
            var body: [String: Any] = ["commands": commands, "delay": delay]
            if let device = deviceDetector.selectedDevice {
                body["device"] = device
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            print("[Phone] HTTP \(status): \(bodyStr.prefix(100))")
        } catch {
            print("[Phone] Error: \(error)")
        }
    }

    /// Fire-and-forget variant for UI buttons.
    func sendPhoneCommandsFireAndForget(_ commands: [String], delay: Double = 0) {
        Task { await sendPhoneCommands(commands, delay: delay) }
    }

    // MARK: - Start / Stop

    func startLiveMode() async {
        guard !isActive else { return }

        let granted = await speechManager.requestPermissions()
        guard granted else {
            errorMessage = "Microphone & speech recognition permissions required."
            return
        }

        isActive = true
        errorMessage = nil
        lastResponse = ""
        cuaStatus = ""
        currentTranscription = ""
        requestId = 0
        lastElements = []
        lastScreenshotData = nil
        openRouter.clearHistory()

        // Auto-start screen broadcast
        if !screenCapture.isBroadcastActive {
            BroadcastPicker.shared.tap()
        }

        do {
            try speechManager.startListening { [weak self] utterance in
                print("[LiveMode] Utterance: \(utterance.prefix(60))...")
                self?.handleUtterance(utterance)
            }
            print("[LiveMode] Speech recognition started")
        } catch {
            errorMessage = "Speech recognition failed: \(error.localizedDescription)"
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
        cuaStatus = ""
        currentTranscription = ""
        lastElements = []
        lastScreenshotData = nil
    }

    // MARK: - Utterance → CUA Loop

    private func handleUtterance(_ text: String) {
        if isSpeaking {
            speechManager.stopAudio()
            isSpeaking = false
        }

        currentTranscription = text
        isProcessing = true
        requestId += 1
        let myId = requestId

        Task {
            await runCUALoop(userMessage: text, requestId: myId)
        }
    }

    /// Main CUA loop: sends user message, then keeps executing tool calls until
    /// the model responds with plain text (the final answer).
    private func runCUALoop(userMessage: String, requestId myId: Int) async {
        print("[CUA] === Starting CUA loop (reqId=\(myId)) for: \"\(userMessage)\" ===")
        do {
            var response = try await openRouter.sendMessage(userMessage)

            for step in 0..<maxCUASteps {
                guard self.requestId == myId else { return }

                switch response {
                case .text(let text):
                    cuaStatus = ""
                    showResponse(text)
                    return

                case .toolCall(let id, let name, let args):
                    print("[CUA] Step \(step + 1)/\(maxCUASteps): \(name) args=\(args)")
                    cuaStatus = statusLabel(tool: name, args: args)

                    let result = await executeTool(name: name, args: args)
                    guard self.requestId == myId else { return }

                    switch result {
                    case .text(let t):
                        print("[CUA] Tool result (text): \(t.prefix(120))")
                    case .textWithImage(let t, let img):
                        print("[CUA] Tool result (image, \(img.count) b64 chars): \(t.prefix(120))")
                    }

                    response = try await openRouter.sendToolResult(
                        toolCallId: id,
                        content: result
                    )
                }
            }

            // Exceeded max steps
            guard self.requestId == myId else { return }
            cuaStatus = ""
            showResponse("I've taken too many steps. Please try a more specific request.")
        } catch {
            guard self.requestId == myId else { return }
            cuaStatus = ""
            showError(error)
        }
    }

    // MARK: - Tool Execution

    private func executeTool(name: String, args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        switch name {
        case "get_screenshot":   return await toolGetScreenshot(args)
        case "tap_element":      return await toolTapElement(args)
        case "type_text":        return await toolTypeText(args)
        case "swipe_screen":     return await toolSwipeScreen(args)
        case "press_key":        return await toolPressKey(args)
        case "wait_seconds":     return await toolWait(args)
        default:                 return .text("Unknown tool: \(name)")
        }
    }

    // MARK: get_screenshot

    private func toolGetScreenshot(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard screenCapture.isBroadcastActive else {
            return .text("ERROR: Screen broadcast is not active. Ask the user to start the broadcast first.")
        }

        guard let screenshotData = screenCapture.takeScreenshot() else {
            return .text("ERROR: Could not capture screenshot. Broadcast may not be running.")
        }

        let imageSize = UIImage(data: screenshotData)?.size ?? .zero
        print("[CUA] Screenshot captured: \(screenshotData.count) bytes, \(Int(imageSize.width))x\(Int(imageSize.height))")

        let detectPrompt = args["detect"] as? String ?? "all interactive elements"

        do {
            let elements = try await moondream.detect(imageData: screenshotData, prompt: detectPrompt)
            lastElements = elements
            lastScreenshotData = screenshotData

            if elements.isEmpty {
                // No detection — send raw screenshot
                let base64 = screenshotData.base64EncodedString()
                return .textWithImage(
                    text: "Screenshot captured. No elements matching '\(detectPrompt)' were detected. Try a different detection prompt. Raw screenshot attached.",
                    imageBase64: base64
                )
            }

            // Annotate
            guard let annotatedData = moondream.annotateImage(imageData: screenshotData, elements: elements) else {
                let base64 = screenshotData.base64EncodedString()
                return .textWithImage(
                    text: "Screenshot captured but annotation failed. \(elements.count) elements detected. Raw screenshot attached.",
                    imageBase64: base64
                )
            }

            // Build description
            let imageSize = UIImage(data: screenshotData)?.size ?? CGSize(width: 1, height: 1)
            var desc = "Screenshot captured. \(elements.count) elements matching '\(detectPrompt)':\n"
            for el in elements {
                let center = el.pixelCenter(imageWidth: imageSize.width, imageHeight: imageSize.height)
                desc += "  [\(el.id)] center pixel (\(center.x), \(center.y))\n"
            }
            desc += "Annotated screenshot with numbered bounding boxes attached. Use tap_element(element_id) to interact."

            return .textWithImage(text: desc, imageBase64: annotatedData.base64EncodedString())

        } catch {
            print("[CUA] Moondream error: \(error)")
            // Fallback: send raw screenshot
            let base64 = screenshotData.base64EncodedString()
            return .textWithImage(
                text: "Screenshot captured but element detection failed: \(error.localizedDescription). Raw screenshot attached — you can still describe what you see and try press_key/type_text.",
                imageBase64: base64
            )
        }
    }

    // MARK: tap_element

    private func toolTapElement(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let elementId = args["element_id"] as? Int else {
            return .text("ERROR: element_id is required (integer)")
        }

        guard let element = lastElements.first(where: { $0.id == elementId }) else {
            let validIds = lastElements.map { "\($0.id)" }.joined(separator: ", ")
            return .text("ERROR: Element \(elementId) not found. Valid IDs: [\(validIds)]. Take a new screenshot if needed.")
        }

        guard let imageData = lastScreenshotData,
              let image = UIImage(data: imageData) else {
            return .text("ERROR: No screenshot data. Call get_screenshot first.")
        }

        let center = element.pixelCenter(imageWidth: image.size.width, imageHeight: image.size.height)

        // Convert from screenshot pixels to logical points for the HID cursor
        let tapX = Int(Float(center.x) / Config.screenScale)
        let tapY = Int(Float(center.y) / Config.screenScale)

        print("[CUA] Tap element \(elementId) → pixel (\(center.x),\(center.y)) → logical (\(tapX),\(tapY))")

        // Use the ESP32 TAP command for absolute positioning
        await sendPhoneCommands(["TAP \(tapX) \(tapY)"])

        return .text("Tapped element \(elementId) at logical point (\(tapX), \(tapY)). Use wait_seconds then get_screenshot to verify.")
    }

    // MARK: type_text

    private func toolTypeText(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return .text("ERROR: text is required")
        }
        await sendPhoneCommands(["TYPE \(text)"])
        return .text("Typed: \"\(text)\"")
    }

    // MARK: swipe_screen

    private func toolSwipeScreen(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let direction = args["direction"] as? String else {
            return .text("ERROR: direction is required (up/down/left/right)")
        }

        // SWIPE x1 y1 x2 y2 steps — all relative to current cursor
        let cmd: String
        switch direction {
        case "up":    cmd = "SWIPE 0 40 0 -80 20"
        case "down":  cmd = "SWIPE 0 -40 0 80 20"
        case "left":  cmd = "SWIPE 40 0 -80 0 20"
        case "right": cmd = "SWIPE -40 0 80 0 20"
        default:      return .text("ERROR: Invalid direction '\(direction)'")
        }

        await sendPhoneCommands([cmd])
        return .text("Swiped \(direction).")
    }

    // MARK: press_key

    private func toolPressKey(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let key = args["key"] as? String, !key.isEmpty else {
            return .text("ERROR: key is required")
        }
        await sendPhoneCommands([key])
        return .text("Pressed \(key).")
    }

    // MARK: wait_seconds

    private func toolWait(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        let seconds = min(max(args["seconds"] as? Double ?? 1.0, 0.5), 5.0)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return .text("Waited \(seconds) seconds.")
    }

    // MARK: - Status Labels

    private func statusLabel(tool: String, args: [String: Any]) -> String {
        switch tool {
        case "get_screenshot":
            let p = args["detect"] as? String ?? ""
            return "Analyzing screen: \(p.prefix(40))"
        case "tap_element":
            let id = args["element_id"] as? Int ?? 0
            return "Tapping element #\(id)"
        case "type_text":
            let t = (args["text"] as? String ?? "").prefix(30)
            return "Typing: \(t)"
        case "swipe_screen":
            return "Swiping \(args["direction"] as? String ?? "")"
        case "press_key":
            return "Pressing \(args["key"] as? String ?? "")"
        case "wait_seconds":
            return "Waiting..."
        default:
            return tool
        }
    }

    // MARK: - Cartesia TTS

    private func speak(_ text: String) {
        speechManager.stopAudio()
        isSpeaking = true

        Task {
            do {
                let audioData = try await fetchCartesiaTTS(text: text)
                guard self.isSpeaking else { return }
                speechManager.playAudio(data: audioData) { [weak self] in
                    Task { @MainActor in
                        self?.isSpeaking = false
                    }
                }
            } catch {
                print("[TTS] Error: \(error)")
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
            "voice": ["mode": "id", "id": cartesiaVoiceId],
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
            throw NSError(domain: "TTS", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "TTS failed (\(status)): \(detail)"])
        }
        return data
    }

    // MARK: - UI Helpers

    private func showResponse(_ text: String) {
        print("[CUA] Done: \(text.prefix(80))")
        lastResponse = text
        isProcessing = false
        speak(text)
    }

    private func showError(_ error: Error) {
        print("[CUA] ❌ Error: \(error)")
        print("[CUA] ❌ Localized: \(error.localizedDescription)")
        lastResponse = "Error: \(error.localizedDescription)"
        isProcessing = false
    }
}
