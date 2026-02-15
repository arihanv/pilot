import Foundation
#if canImport(ActivityKit)
import ActivityKit
import UIKit
#endif

@Observable
class LiveModeManager {
    var isActive = false
    var isProcessing = false
    var currentTranscription = ""
    var lastResponse = ""
    var errorMessage: String?

    /// Live partial speech text from the recognizer
    var speechText: String { speechManager.transcribedText }

    /// Whether the broadcast extension is currently streaming the device screen.
    var isBroadcastActive: Bool { screenCapture.isBroadcastActive }

    private let speechManager = SpeechManager()
    private let openRouter: OpenRouterService
    private let screenCapture = ScreenCaptureManager()
    #if canImport(ActivityKit)
    private let liveActivity = LiveActivityManager()
    #endif
    private var requestId = 0

    init(apiKey: String) {
        openRouter = OpenRouterService(apiKey: apiKey)
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

        #if canImport(ActivityKit)
        liveActivity.start()
        liveActivity.update(text: "", isSpeaking: false, phase: "listening", alert: false)
        print("[LiveMode] LiveActivity started")
        #endif

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

        speechManager.stopListening()

        #if canImport(ActivityKit)
        liveActivity.end()
        #endif

        isActive = false
        isProcessing = false
        currentTranscription = ""
    }

    // MARK: - Utterance handling

    private func handleUtterance(_ text: String) {
        currentTranscription = text
        isProcessing = true
        requestId += 1
        let myId = requestId

        #if canImport(ActivityKit)
        liveActivity.update(text: "Thinking…", isSpeaking: true, phase: "thinking", alert: false)
        #endif

        print("[LiveMode] Sending to OpenRouter...")

        Task {
            do {
                let response = try await openRouter.sendMessage(text)
                guard self.requestId == myId else { return }

                switch response {
                case .text(let responseText):
                    showResponse(responseText)

                case .toolCall(let id, let name):
                    print("[LiveMode] Tool call requested: \(name)")
                    if name == "get_screenshot" {
                        await handleScreenshotTool(toolCallId: id, requestId: myId)
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
        #if canImport(ActivityKit)
        liveActivity.update(text: "Capturing screen…", isSpeaking: true, phase: "thinking", alert: false)
        #endif

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
        let uiImage = UIImage(data: screenshotData)
        
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

    // MARK: - UI helpers

    private func showResponse(_ text: String) {
        print("[LiveMode] Got response: \(text.prefix(60))...")
        lastResponse = text
        isProcessing = false
        #if canImport(ActivityKit)
        // Initial alert update to expand the Dynamic Island
        liveActivity.update(text: text, isSpeaking: false, phase: "responding", alert: true)
        #endif
    }

    private func showError(_ error: Error) {
        print("[LiveMode] API error: \(error)")
        lastResponse = "Error: \(error.localizedDescription)"
        isProcessing = false
        #if canImport(ActivityKit)
        liveActivity.update(text: "Error: \(error.localizedDescription)", isSpeaking: false, phase: "responding")
        #endif
    }
}
