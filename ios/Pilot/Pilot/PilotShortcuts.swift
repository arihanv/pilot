import AppIntents
import Foundation

private enum ShortcutBridge {
    static let appGroup = "group.dev.ethan.Pilot"
    static let queueKey = "shortcut_prompt_queue"
}

struct SendPromptToPilotIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Prompt to Pilot"
    static var description = IntentDescription("Sends a text prompt to Pilot so it can run without dictation.")
    static var openAppWhenRun = true

    @Parameter(title: "Prompt")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$prompt) to Pilot")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        if let defaults = UserDefaults(suiteName: ShortcutBridge.appGroup) {
            var queue = defaults.stringArray(forKey: ShortcutBridge.queueKey) ?? []
            queue.append(prompt)
            defaults.set(queue, forKey: ShortcutBridge.queueKey)
        }

        var components = URLComponents()
        components.scheme = "pilot"
        components.host = "shortcut"

        guard let url = components.url else {
            throw NSError(domain: "PilotShortcuts", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create Pilot shortcut URL."
            ])
        }

        return .result(
            opensIntent: OpenURLIntent(url),
            dialog: IntentDialog("Sent your prompt to Pilot.")
        )
    }
}

struct PilotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendPromptToPilotIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Send to \(.applicationName)"
            ],
            shortTitle: "Send Prompt",
            systemImageName: "text.bubble"
        )
    }
}
