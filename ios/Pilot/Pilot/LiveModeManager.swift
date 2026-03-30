import Foundation
import AVFoundation
import UIKit
import ReplayKit
import CoreBluetooth

/// Singleton that holds a hidden RPSystemBroadcastPickerView and can
/// programmatically trigger its internal button.
final class BroadcastPicker {
    static let shared = BroadcastPicker()

    private let picker: RPSystemBroadcastPickerView = {
        let p = RPSystemBroadcastPickerView()
        p.preferredExtension = "dev.ethan.Pilot.BroadcastExtension"
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
    var isRecording = false
    var isSpeaking = false
    var currentTranscription = ""
    var lastResponse = ""
    var errorMessage: String?
    private var bleStateTick = 0

    /// Status text shown during CUA execution (e.g. "Analyzing screen: app icons").
    var cuaStatus: String = ""

    var speechText: String { speechManager.transcribedText }
    var isBroadcastActive: Bool { screenCapture.isBroadcastActive }
    var selectedDevice: String? {
        _ = bleStateTick
        return deviceDetector.selectedDevice
    }
    var connectedDevice: String? {
        _ = bleStateTick
        return bleBridge.connectedDeviceName
    }
    var bleStatusText: String {
        _ = bleStateTick
        return bleBridge.statusText
    }
    var isBLEConnected: Bool {
        _ = bleStateTick
        return bleBridge.connectionState == .connected
    }
    var isBLEBusy: Bool {
        _ = bleStateTick
        let state = bleBridge.connectionState
        return state == .scanning || state == .connecting
    }
    var isBluetoothPoweredOn: Bool {
        _ = bleStateTick
        return bleBridge.bluetoothPoweredOn
    }
    var bleNeedsForget: String? {
        _ = bleStateTick
        return bleBridge.nusUnavailableMessage
    }

    var selectedModel: String {
        get { openRouter.model }
        set { openRouter.model = newValue }
    }

    private let speechManager = SpeechManager()
    private let openRouter: OpenRouterService
    private let screenCapture = ScreenCaptureManager()
    private let moondream = MoondreamService(apiKey: Config.moondreamAPIKey)
    let deviceDetector = DeviceDetector()
    private var requestId = 0

    // CUA state
    private var lastElements: [DetectedElement] = []
    private var lastScreenshotData: Data?
    private var cuaStep = 0

    // Cartesia TTS
    private let cartesiaAPIKey = "sk_car_NbH5v8KK7dJ9rB8udKqp3Q" // sk_car_LX13WDzurrLVVk3k2GU8hk
    private let cartesiaVoiceId = "e8e5fffb-252c-436d-b842-8879b84445b6"
    private let cartesiaModelId = "sonic-3"

    private func elapsed(_ start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    /// Downsample a UIImage to half-res JPEG at 0.5 quality for sending to the LLM.
    private func downsampleForLLM(_ image: UIImage) -> Data {
        let scale: CGFloat = 0.5
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: newSize, format: fmt)
        let small = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return small.jpegData(compressionQuality: 0.5) ?? Data()
    }

    init(apiKey: String) {
        openRouter = OpenRouterService(apiKey: apiKey)
        bleBridge.onStateChanged = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bleStateTick += 1
                self.syncBLEDeviceState()
            }
        }
        // Clear any stale broadcast flag from a previous session
        screenCapture.clearBroadcastFlag()
    }

    // MARK: - Phone Control (via direct BLE)

    private let bleBridge = BLECommandBridge()

    private func syncBLEDeviceState() {
        deviceDetector.updateFromBLE(
            names: bleBridge.discoveredDeviceNames,
            connected: bleBridge.connectedDeviceName
        )
    }

    /// Send commands directly to ESP32 via BLE GATT. Awaits completion.
    private func sendPhoneCommands(_ commands: [String], delay: Double = 0) async {
        let sendStart = Date()
        print("[Phone] Commands: \(commands)")
        bleBridge.setTargetDeviceName(deviceDetector.selectedDevice)

        do {
            try await bleBridge.connectIfNeeded(timeout: 10)
            syncBLEDeviceState()

            for (index, command) in commands.enumerated() {
                let response = try await bleBridge.sendCommand(command, responseTimeout: 5)
                print("[Phone] BLE \(command) -> \(response)")

                let isLast = index == commands.count - 1
                if !isLast && delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        } catch {
            print("[Phone] Error after \(elapsed(sendStart)): \(error)")
            errorMessage = "BLE command failed: \(error.localizedDescription)"
        }
    }

    func refreshBLEDevices() async {
        await bleBridge.refreshDevices(scanSeconds: 2.0)
        syncBLEDeviceState()
    }

    func connectSelectedBLEDevice() {
        Task {
            do {
                try await bleBridge.connect(toDeviceNamed: deviceDetector.selectedDevice, timeout: 10)
                syncBLEDeviceState()
                errorMessage = nil
            } catch {
                syncBLEDeviceState()
                errorMessage = "BLE connect failed: \(error.localizedDescription)"
            }
        }
    }

    func disconnectBLEDevice() {
        bleBridge.disconnect()
        syncBLEDeviceState()
    }

    func sendBLEStatusTest() {
        Task {
            do {
                bleBridge.setTargetDeviceName(deviceDetector.selectedDevice)
                try await bleBridge.connectIfNeeded(timeout: 10)
                syncBLEDeviceState()
                let response = try await bleBridge.sendCommand("STATUS", responseTimeout: 5)
                lastResponse = "ESP32 STATUS: \(response)"
                errorMessage = nil
            } catch {
                errorMessage = "BLE test failed: \(error.localizedDescription)"
            }
        }
    }

    /// Fire-and-forget variant for UI buttons.
    func sendPhoneCommandsFireAndForget(_ commands: [String], delay: Double = 0) {
        Task { await sendPhoneCommands(commands, delay: delay) }
    }

    /// Run typed command script. Supports newline or ';' separated commands.
    /// Also supports WAIT/DELAY commands, e.g. "WAIT 0.5".
    func runCommandScriptFireAndForget(_ script: String) {
        Task {
            await runCommandScript(script)
        }
    }

    private func runCommandScript(_ script: String) async {
        enum Step {
            case wait(Double)
            case command(String)
        }

        let normalized = script.replacingOccurrences(of: ";", with: "\n")
        let lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !lines.isEmpty else { return }

        var steps: [Step] = []
        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("WAIT ") || upper.hasPrefix("DELAY ") {
                let value = line
                    .split(separator: " ", omittingEmptySubsequences: true)
                    .dropFirst()
                    .joined(separator: " ")
                    .replacingOccurrences(of: "s", with: "")
                    .replacingOccurrences(of: "S", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let seconds = Double(value), seconds >= 0 {
                    steps.append(.wait(seconds))
                    continue
                }
            }
            steps.append(.command(line))
        }

        bleBridge.setTargetDeviceName(deviceDetector.selectedDevice)
        do {
            try await bleBridge.connectIfNeeded(timeout: 10)
            syncBLEDeviceState()

            for step in steps {
                switch step {
                case .wait(let seconds):
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                case .command(let command):
                    let response = try await bleBridge.sendCommand(command, responseTimeout: 5)
                    print("[Phone] BLE \(command) -> \(response)")
                    lastResponse = "\(command) -> \(response)"
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = "BLE command failed: \(error.localizedDescription)"
        }
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

        // PTT mode: prepare speech but start paused — user holds button to talk
        do {
            speechManager.isPTTMode = true
            try speechManager.startListening { _ in }
            speechManager.pauseListening()
            print("[LiveMode] PTT mode ready — hold button to talk")
        } catch {
            errorMessage = "Speech recognition failed: \(error.localizedDescription)"
            await stopLiveMode()
        }
    }

    // MARK: - Push-to-Talk

    func beginRecording() {
        guard isActive, !isRecording else { return }
        if isSpeaking {
            speechManager.stopAudio()
            isSpeaking = false
        }
        isRecording = true
        speechManager.resumeListening()
        print("[PTT] Recording started")
    }

    func endRecording() {
        guard isRecording else { return }
        isRecording = false
        let text = speechManager.transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        speechManager.pauseListening()
        print("[PTT] Recording ended, text: \(text.prefix(60))")
        processIncomingUtterance(text)
    }

    /// Handles text prompts from external sources like Apple Shortcuts.
    /// This bypasses dictation and sends the provided text directly to the CUA loop.
    func submitShortcutPrompt(_ prompt: String) {
        processIncomingUtterance(prompt)
    }

    /// Unified text ingestion path used by both dictation and external prompts.
    private func processIncomingUtterance(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        print("[LiveMode] Processing utterance: \(text.prefix(80))")

        if isSpeaking {
            speechManager.stopAudio()
            isSpeaking = false
        }

        // Keep mic idle while processing a complete utterance.
        speechManager.pauseListening()
        isRecording = false

        if !isActive {
            isActive = true
            errorMessage = nil
            lastResponse = ""
            cuaStatus = ""
            requestId = 0
            lastElements = []
            lastScreenshotData = nil
            openRouter.clearHistory()

            if !screenCapture.isBroadcastActive {
                BroadcastPicker.shared.tap()
            }
        }

        currentTranscription = text
        speechManager.transcribedText = text
        isProcessing = true
        requestId += 1
        let myId = requestId

        Task {
            await runCUALoop(userMessage: text, requestId: myId)
        }
    }

    func stopLiveMode() async {
        guard isActive else { return }
        speechManager.stopAudio()
        speechManager.stopListening()
        speechManager.isPTTMode = false
        isSpeaking = false
        isActive = false
        isRecording = false
        isProcessing = false
        cuaStatus = ""
        currentTranscription = ""
        lastElements = []
        lastScreenshotData = nil
    }

    /// Main CUA loop: sends user message, then keeps executing tool calls until
    /// the model responds with plain text (the final answer).
    private func runCUALoop(userMessage: String, requestId myId: Int) async {
        let loopStart = Date()
        var lastCheckpoint = loopStart
        print("[CUA] === Starting CUA loop (reqId=\(myId)) for: \"\(userMessage)\" ===")
        do {
            cuaStep = 0
            var response = try await openRouter.sendMessage(userMessage)
            print("[Timing][CUA] Initial LLM response in \(elapsed(lastCheckpoint)) (total \(elapsed(loopStart)))")
            lastCheckpoint = Date()

            while true {
                guard self.requestId == myId else { return }

                switch response {
                case .text(let text):
                    cuaStatus = ""
                    print("[Timing][CUA] Final text returned after \(elapsed(lastCheckpoint)) (total \(elapsed(loopStart)))")
                    showResponse(text)
                    return

                case .toolCall(let id, let name, let args):
                    cuaStep += 1
                    print("[CUA] Step \(cuaStep): \(name) args=\(args)")
                    print("[Timing][CUA] Step \(cuaStep) started after \(elapsed(lastCheckpoint)) (total \(elapsed(loopStart)))")
                    cuaStatus = statusLabel(tool: name, args: args)

                    let toolStart = Date()
                    let result = await executeTool(name: name, args: args)
                    guard self.requestId == myId else { return }
                    print("[Timing][CUA] Step \(cuaStep) tool '\(name)' executed in \(elapsed(toolStart))")

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
                    print("[Timing][CUA] Step \(cuaStep) next LLM response in \(elapsed(lastCheckpoint)) (total \(elapsed(loopStart)))")
                    lastCheckpoint = Date()
                }
            }
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
        case "scroll_screen":    return await toolScrollScreen(args)
        case "press_key":        return await toolPressKey(args)
        case "wait_seconds":     return await toolWait(args)
        default:                 return .text("Unknown tool: \(name)")
        }
    }

    // MARK: get_screenshot

    private func toolGetScreenshot(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        let toolStart = Date()
        defer { print("[Timing][CUA] get_screenshot total \(elapsed(toolStart))") }
        guard screenCapture.isBroadcastActive else {
            return .text("ERROR: Screen broadcast is not active. Ask the user to start the broadcast first.")
        }

        guard let screenshotData = screenCapture.takeScreenshot() else {
            return .text("ERROR: Could not capture screenshot. Broadcast may not be running.")
        }

        guard let screenshotImage = UIImage(data: screenshotData) else {
            return .text("ERROR: Could not decode screenshot image.")
        }
        let imageSize = screenshotImage.size
        print("[CUA] Screenshot captured: \(screenshotData.count) bytes, \(Int(imageSize.width))x\(Int(imageSize.height))")

        let detectPrompt = args["detect"] as? String ?? "all interactive elements"

        do {
            let detectStart = Date()
            let elements = try await moondream.detect(imageData: screenshotData, prompt: detectPrompt)
            print("[Timing][CUA] Moondream detect in \(elapsed(detectStart))")
            lastElements = elements
            lastScreenshotData = screenshotData

            if elements.isEmpty {
                // No detection — send smaller raw screenshot to LLM
                let smallData = downsampleForLLM(screenshotImage)
                return .textWithImage(
                    text: "Screenshot captured. No elements matching '\(detectPrompt)' were detected. Try a different detection prompt or swipe_screen to scroll. Raw screenshot attached.",
                    imageBase64: smallData.base64EncodedString()
                )
            }

            // Annotate at half-res + lower quality for LLM
            guard let llmAnnotated = moondream.annotateImageForLLM(imageData: screenshotData, elements: elements) else {
                let smallData = downsampleForLLM(screenshotImage)
                return .textWithImage(
                    text: "Screenshot captured but annotation failed. \(elements.count) elements detected. Raw screenshot attached.",
                    imageBase64: smallData.base64EncodedString()
                )
            }

            // Build description
            var desc = "Screenshot captured. \(elements.count) elements matching '\(detectPrompt)':\n"
            for el in elements {
                let center = el.pixelCenter(imageWidth: imageSize.width, imageHeight: imageSize.height)
                desc += "  [\(el.id)] center pixel (\(center.x), \(center.y))\n"
            }
            desc += "Annotated screenshot with numbered bounding boxes attached. Use tap_element(element_id) to interact."

            return .textWithImage(text: desc, imageBase64: llmAnnotated.base64EncodedString())

        } catch {
            print("[CUA] Moondream error: \(error)")
            // Fallback: send smaller raw screenshot
            let smallData = downsampleForLLM(screenshotImage)
            return .textWithImage(
                text: "Screenshot captured but element detection failed: \(error.localizedDescription). Raw screenshot attached — you can still describe what you see and try press_key/type_text.",
                imageBase64: smallData.base64EncodedString()
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

        // Convert pixel center to percentage coordinates (0-100) for ESP32 absolute mouse
        let imageSize = image.size
        let pixel = element.pixelCenter(imageWidth: imageSize.width, imageHeight: imageSize.height)
        let pctX = Int(Double(pixel.x) / Double(imageSize.width) * 100.0 + 0.5)
        let pctY = Int(Double(pixel.y) / Double(imageSize.height) * 100.0 + 0.5)

        print("[CUA] Tap element \(elementId) → pixel (\(pixel.x),\(pixel.y)) → pct (\(pctX),\(pctY))")

        await sendPhoneCommands(["click \(pctX) \(pctY)"])

        return .text("Tapped element \(elementId) at pixel (\(pixel.x), \(pixel.y)), click \(pctX) \(pctY). Use wait_seconds then get_screenshot to verify.")
    }

    // MARK: type_text

    private func toolTypeText(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let text = args["text"] as? String, !text.isEmpty else {
            return .text("ERROR: text is required")
        }
        await sendPhoneCommands(["type \(text)"])
        return .text("Typed: \"\(text)\"")
    }

    // MARK: swipe_screen

    private func toolSwipeScreen(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let direction = args["direction"] as? String else {
            return .text("ERROR: direction is required (up/down/left/right)")
        }

        // Simulate swipe using press → move → release with absolute coordinates (percentages 0-100)
        let (startX, startY, endX, endY): (Int, Int, Int, Int)
        switch direction {
        case "up":    (startX, startY, endX, endY) = (50, 70, 50, 30)
        case "down":  (startX, startY, endX, endY) = (50, 30, 50, 70)
        case "left":  (startX, startY, endX, endY) = (70, 50, 30, 50)
        case "right": (startX, startY, endX, endY) = (30, 50, 70, 50)
        default:      return .text("ERROR: Invalid direction '\(direction)'")
        }

        await sendPhoneCommands(["press \(startX) \(startY)"], delay: 0.05)
        // Intermediate points for smooth swipe
        let midX = (startX + endX) / 2
        let midY = (startY + endY) / 2
        await sendPhoneCommands(["move \(midX) \(midY)"], delay: 0.05)
        await sendPhoneCommands(["move \(endX) \(endY)"], delay: 0.05)
        await sendPhoneCommands(["release"])
        return .text("Swiped \(direction).")
    }

    // MARK: scroll_screen

    private func toolScrollScreen(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let direction = args["direction"] as? String else {
            return .text("ERROR: direction is required (up/down)")
        }

        // Simulate scroll via swipe gesture (same as swipe but shorter distance)
        let (startX, startY, endX, endY): (Int, Int, Int, Int)
        switch direction {
        case "up":    (startX, startY, endX, endY) = (50, 60, 50, 40)
        case "down":  (startX, startY, endX, endY) = (50, 40, 50, 60)
        default:      return .text("ERROR: Invalid direction '\(direction)', use up/down")
        }

        await sendPhoneCommands(["press \(startX) \(startY)"], delay: 0.05)
        await sendPhoneCommands(["move \(endX) \(endY)"], delay: 0.05)
        await sendPhoneCommands(["release"])
        return .text("Scrolled \(direction).")
    }

    // MARK: press_key

    private func toolPressKey(_ args: [String: Any]) async -> OpenRouterService.ToolResultContent {
        guard let key = args["key"] as? String, !key.isEmpty else {
            return .text("ERROR: key is required")
        }
        // Map to ESP32 command format
        let cmd: String
        switch key.lowercased() {
        case "home":           cmd = "home"
        case "enter", "return": cmd = "key enter"
        case "backspace":      cmd = "key backspace"
        case "tab":            cmd = "key tab"
        case "escape", "esc":  cmd = "key esc"
        case "space":          cmd = "key space"
        case "delete":         cmd = "key delete"
        case "up":             cmd = "key up"
        case "down":           cmd = "key down"
        case "left":           cmd = "key left"
        case "right":          cmd = "key right"
        case "spotlight":      cmd = "spotlight"
        case "appswitcher":    cmd = "appswitcher"
        case "screenshot":     cmd = "screenshot"
        case "undo":           cmd = "undo"
        case "redo":           cmd = "redo"
        case "copy":           cmd = "copy"
        case "paste":          cmd = "paste"
        case "cut":            cmd = "cut"
        case "selectall":      cmd = "selectall"
        case "find":           cmd = "find"
        case "play", "pause":  cmd = "play"
        case "volup":          cmd = "volup"
        case "voldown":        cmd = "voldown"
        case "mute":           cmd = "mute"
        default:               cmd = "key \(key.lowercased())"
        }
        await sendPhoneCommands([cmd])
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
        speechManager.pauseListening()
        isSpeaking = true

        Task {
            do {
                let audioData = try await fetchCartesiaTTS(text: text)
                guard self.isSpeaking else { return }
                speechManager.playAudio(data: audioData) { [weak self] in
                    Task { @MainActor in
                        self?.isSpeaking = false
                        // PTT: don't resume mic — wait for next button press
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

private enum BLECommandError: LocalizedError {
    case bluetoothUnavailable
    case peripheralNotFound
    case serviceNotReady
    case responseTimeout

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: return "Bluetooth is not powered on."
        case .peripheralNotFound: return "Could not find the ESP32 BLE command service."
        case .serviceNotReady: return "ESP32 BLE command characteristic is not ready."
        case .responseTimeout: return "ESP32 command response timed out."
        }
    }
}

private final class BLECommandBridge: NSObject {
    enum ConnectionState {
        case idle
        case scanning
        case connecting
        case connected
    }

    // NUS (Nordic UART Service) for command channel
    private let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    private let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
    private let hidServiceUUID = CBUUID(string: "1812")
    private let pilotPrefix = "pilot-"

    private var central: CBCentralManager!
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private(set) var discoveredDeviceNames: [String] = []
    private(set) var connectedDeviceName: String?
    private(set) var connectionState: ConnectionState = .idle
    private(set) var bluetoothPoweredOn: Bool = false
    var onStateChanged: (() -> Void)?

    private var targetDeviceName: String?
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var lastResponseText: String = ""
    private var lastResponseAt: Date = .distantPast

    private var pollTimer: Timer?
    private var reconnectTimer: Timer?
    private var userDisconnected = false
    var nusUnavailableMessage: String?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Helpers

    private func isPilotDevice(_ peripheral: CBPeripheral) -> Bool {
        peripheral.name?.lowercased().hasPrefix(pilotPrefix) == true
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    var isReady: Bool {
        peripheral?.state == .connected && rxCharacteristic != nil
    }

    var statusText: String {
        if !bluetoothPoweredOn { return "Bluetooth off" }
        switch connectionState {
        case .idle:       return "Not connected"
        case .scanning:   return "Scanning..."
        case .connecting:
            if let t = targetDeviceName, !t.isEmpty { return "Connecting to \(t)..." }
            return "Connecting..."
        case .connected:
            if let n = connectedDeviceName { return "Connected to \(n)" }
            return "Connected"
        }
    }

    func setTargetDeviceName(_ name: String?) {
        targetDeviceName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Polling for system-connected HID devices

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkForPilotDevices()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Check for pilot devices that are already system-connected (paired via iOS Settings as HID)
    /// or advertising on BLE. This is the primary discovery mechanism.
    private func checkForPilotDevices() {
        guard central.state == .poweredOn else { return }

        // Retrieve peripherals already connected at the system level via ANY known service
        // HID (1812) is what iOS Settings connects to; NUS is what we use for commands
        let hidPeripherals = central.retrieveConnectedPeripherals(withServices: [hidServiceUUID])
        let nusPeripherals = central.retrieveConnectedPeripherals(withServices: [nusServiceUUID])

        // Deduplicate
        var seen = Set<UUID>()
        let unique = (hidPeripherals + nusPeripherals).filter { seen.insert($0.identifier).inserted }

        print("[BLE] System check: HID=\(hidPeripherals.count) NUS=\(nusPeripherals.count) unique=\(unique.count) \(unique.map { "\($0.name ?? "nil")" })")

        for p in unique {
            if isPilotDevice(p) {
                discoveredPeripherals[p.identifier] = p
                tryConnect(p)
            } else if p.name == nil || p.name?.isEmpty == true {
                // Name unknown — try connecting to check if it's our pilot device
                tryConnect(p)
            }
            // If name is known but NOT pilot-, skip it
        }

        rebuildDeviceNames()

        if peripheral?.state == .connected && rxCharacteristic != nil {
            connectionState = .connected
            notifyStateChanged()
        }
    }

    private func tryConnect(_ p: CBPeripheral) {
        guard !isReady else { return }
        guard !userDisconnected else { return }
        guard peripheral == nil || peripheral?.state == .disconnected else { return }
        peripheral = p
        p.delegate = self
        connectionState = .connecting
        notifyStateChanged()
        central.connect(p, options: nil)
        print("[BLE] Attempting connection to \(p.name ?? "unknown") (\(p.identifier.uuidString.prefix(8)))")
    }

    /// Use stored peripheral identifier to reconnect to a previously-known device
    private func tryRetrieveKnownPeripheral() {
        guard let storedID = UserDefaults.standard.string(forKey: "pilot_peripheral_id"),
              let uuid = UUID(uuidString: storedID) else {
            print("[BLE] No stored peripheral ID")
            return
        }
        let peripherals = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = peripherals.first {
            print("[BLE] Retrieved known peripheral: \(p.name ?? "nil") state=\(p.state.rawValue) (\(p.identifier.uuidString.prefix(8)))")
            discoveredPeripherals[p.identifier] = p
            if isPilotDevice(p) || p.name == nil {
                tryConnect(p)
            }
            rebuildDeviceNames()
        } else {
            print("[BLE] Stored peripheral \(storedID.prefix(8)) not retrievable")
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self, self.central.state == .poweredOn else {
                timer.invalidate()
                return
            }

            // Check if device reappeared at system level
            self.checkForPilotDevices()

            // Try reconnecting the last-known peripheral
            if let p = self.peripheral, p.state == .disconnected {
                self.connectionState = .connecting
                self.notifyStateChanged()
                self.central.connect(p, options: nil)
            }

            // Stop once connected
            if self.isReady {
                timer.invalidate()
                self.reconnectTimer = nil
            }
        }
    }

    // MARK: - Public API

    func refreshDevices(scanSeconds: Double = 3.0) async {
        guard central.state == .poweredOn else { return }
        connectionState = .scanning
        notifyStateChanged()

        // Try stored peripheral, then system-connected, then scan
        tryRetrieveKnownPeripheral()
        checkForPilotDevices()
        if isReady { return }

        // Scan broadly — nil finds all advertising devices, didDiscover filters by pilot- prefix
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        try? await Task.sleep(nanoseconds: UInt64(scanSeconds * 1_000_000_000))
        central.stopScan()

        // Final check
        tryRetrieveKnownPeripheral()
        checkForPilotDevices()

        connectionState = isReady ? .connected : .idle
        rebuildDeviceNames()
        notifyStateChanged()
    }

    func connectIfNeeded(timeout: Double = 10.0) async throws {
        userDisconnected = false
        guard central.state == .poweredOn else {
            throw BLECommandError.bluetoothUnavailable
        }
        if isReady { return }

        // Try stored peripheral, then system-connected
        tryRetrieveKnownPeripheral()
        checkForPilotDevices()
        if isReady { return }

        connectBestPeripheralIfPossible()

        // Scan broadly + poll system-connected devices
        let start = Date()
        connectionState = .scanning
        notifyStateChanged()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        while Date().timeIntervalSince(start) < timeout {
            if isReady {
                central.stopScan()
                connectionState = .connected
                notifyStateChanged()
                return
            }

            // Re-check system-connected devices every ~1 second
            checkForPilotDevices()

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        central.stopScan()
        connectionState = .idle
        notifyStateChanged()
        throw BLECommandError.peripheralNotFound
    }

    func connect(toDeviceNamed name: String?, timeout: Double = 10.0) async throws {
        userDisconnected = false
        targetDeviceName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = peripheral, p.state == .connected {
            if targetDeviceName == nil || p.name?.caseInsensitiveCompare(targetDeviceName ?? "") == .orderedSame {
                connectionState = .connected
                connectedDeviceName = p.name
                notifyStateChanged()
                return
            }
            central.cancelPeripheralConnection(p)
        }
        try await connectIfNeeded(timeout: timeout)
    }

    func disconnect() {
        userDisconnected = true
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        if let p = peripheral, p.state == .connected || p.state == .connecting {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        connectedDeviceName = nil
        connectionState = .idle
        notifyStateChanged()
    }

    func sendCommand(_ command: String, responseTimeout: Double = 5.0) async throws -> String {
        guard isReady, let peripheral, let rx = rxCharacteristic else {
            throw BLECommandError.serviceNotReady
        }

        if let tx = txCharacteristic, !tx.isNotifying {
            peripheral.setNotifyValue(true, for: tx)
        }

        let start = Date()
        let payload = Data(command.utf8)
        peripheral.writeValue(payload, for: rx, type: .withResponse)

        while Date().timeIntervalSince(start) < responseTimeout {
            if lastResponseAt > start {
                return lastResponseText
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }

        throw BLECommandError.responseTimeout
    }

    private func connectBestPeripheralIfPossible() {
        if let p = peripheral, p.state == .connecting || p.state == .connected { return }

        let target = targetDeviceName?.lowercased()

        // Prefer exact name match
        let byName = discoveredPeripherals.values.first { p in
            guard let name = p.name?.lowercased(), let target else { return false }
            return name == target
        }

        // Fall back to any pilot device
        let chosen = byName ?? discoveredPeripherals.values.first(where: { isPilotDevice($0) })
        guard let chosen else { return }

        peripheral = chosen
        chosen.delegate = self
        connectionState = .connecting
        notifyStateChanged()
        central.connect(chosen, options: nil)
    }

    private func rebuildDeviceNames() {
        let names = discoveredPeripherals.values
            .filter { isPilotDevice($0) }
            .compactMap(\.name)
        discoveredDeviceNames = Array(Set(names)).sorted()
        notifyStateChanged()
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECommandBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothPoweredOn = central.state == .poweredOn
        print("[BLE] Central state: \(central.state.rawValue) poweredOn=\(central.state == .poweredOn)")
        if central.state == .poweredOn {
            // Try reconnecting to a previously-known pilot device by stored UUID
            tryRetrieveKnownPeripheral()

            // Check for system-connected pilot devices
            checkForPilotDevices()

            // Scan for devices — allow duplicates so we keep seeing the device
            // even after iOS has already reported it once
            print("[BLE] Starting BLE scan...")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])

            // Start background polling (catches devices paired via iOS Settings)
            startPolling()
        } else {
            stopPolling()
            reconnectTimer?.invalidate()
            reconnectTimer = nil
            rxCharacteristic = nil
            txCharacteristic = nil
            connectedDeviceName = nil
            connectionState = .idle
        }
        notifyStateChanged()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName
        guard let name, name.lowercased().hasPrefix(pilotPrefix) else { return }

        print("[BLE] Discovered pilot device: \(name) (\(peripheral.identifier.uuidString.prefix(8))) RSSI=\(RSSI)")
        discoveredPeripherals[peripheral.identifier] = peripheral
        rebuildDeviceNames()
        connectBestPeripheralIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLE] Connected to \(peripheral.name ?? "unknown") (\(peripheral.identifier.uuidString.prefix(8)))")

        // If name is now known and it's NOT a pilot device, disconnect
        if let name = peripheral.name, !name.isEmpty, !name.lowercased().hasPrefix(pilotPrefix) {
            print("[BLE] Not a pilot device, disconnecting: \(name)")
            central.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            connectionState = .idle
            notifyStateChanged()
            return
        }

        // It's a pilot device (or name still unknown — discover services to find out)
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        connectedDeviceName = peripheral.name ?? "pilot device"
        connectionState = .connected
        reconnectTimer?.invalidate()
        reconnectTimer = nil

        // Remember this peripheral for future reconnects
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "pilot_peripheral_id")

        if isPilotDevice(peripheral) {
            discoveredPeripherals[peripheral.identifier] = peripheral
            rebuildDeviceNames()
        }

        notifyStateChanged()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if self.peripheral?.identifier == peripheral.identifier {
            rxCharacteristic = nil
            txCharacteristic = nil
            connectedDeviceName = nil
            connectionState = .idle
            notifyStateChanged()
            scheduleReconnect()
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if self.peripheral?.identifier == peripheral.identifier {
            rxCharacteristic = nil
            txCharacteristic = nil
            connectedDeviceName = nil
            connectionState = .idle
            notifyStateChanged()
            print("[BLE] Disconnected from \(peripheral.name ?? "unknown"). userDisconnected=\(userDisconnected)")
            // Only auto-reconnect if this wasn't user-initiated
            if !userDisconnected && central.state == .poweredOn {
                scheduleReconnect()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLECommandBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            print("[BLE] Service discovery error: \(error?.localizedDescription ?? "no services")")
            return
        }
        print("[BLE] Discovered services: \(services.map(\.uuid.uuidString))")

        var foundNUS = false
        for service in services where service.uuid == nusServiceUUID {
            print("[BLE] Found NUS service, discovering characteristics...")
            peripheral.discoverCharacteristics([rxUUID, txUUID], for: service)
            foundNUS = true
        }

        if !foundNUS {
            // iOS cached old GATT table without NUS service.
            // This happens when the device was previously paired with older firmware.
            // User must "Forget This Device" in iOS Settings to clear the GATT cache.
            print("[BLE] ⚠️ NUS not found (cached services: \(services.map(\.uuid.uuidString))). Device needs to be forgotten and re-paired.")
            connectedDeviceName = peripheral.name
            connectionState = .connected
            notifyStateChanged()
            // Don't disconnect — stay connected but flag the issue
            DispatchQueue.main.async { [weak self] in
                self?.nusUnavailableMessage = "Forget \"\(peripheral.name ?? "pilot-1")\" in iOS Settings > Bluetooth, then reconnect. iOS cached old services."
                self?.notifyStateChanged()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else { return }
        print("[BLE] Discovered characteristics for \(service.uuid): \(characteristics.map(\.uuid.uuidString))")
        for c in characteristics {
            if c.uuid == rxUUID {
                rxCharacteristic = c
                print("[BLE] Found RX characteristic")
            }
            if c.uuid == txUUID {
                txCharacteristic = c
                peripheral.setNotifyValue(true, for: c)
                print("[BLE] Found TX characteristic, enabled notifications")
            }
        }
        if rxCharacteristic != nil {
            print("[BLE] ✅ NUS ready — commands can be sent")
            nusUnavailableMessage = nil
            connectionState = .connected
            notifyStateChanged()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == txUUID else { return }
        guard let data = characteristic.value, !data.isEmpty else { return }
        lastResponseText = String(decoding: data, as: UTF8.self)
        lastResponseAt = Date()
    }
}
