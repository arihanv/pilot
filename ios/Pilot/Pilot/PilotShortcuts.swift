import AppIntents
import Foundation

private enum ShortcutBridge {
    static let appGroup = "group.dev.ethan.Pilot"
    static let queueKey = "shortcut_prompt_queue"
    static let dictateKey = "shortcut_dictate_requested"
}

// MARK: - Send Prompt

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
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let defaults = UserDefaults(suiteName: ShortcutBridge.appGroup) {
            var queue = defaults.stringArray(forKey: ShortcutBridge.queueKey) ?? []
            queue.append(prompt)
            defaults.set(queue, forKey: ShortcutBridge.queueKey)
        }

        return .result(dialog: "Sent your prompt to Pilot.")
    }
}

// MARK: - Dictate

struct PilotDictateIntent: AppIntent {
    static var title: LocalizedStringResource = "Pilot Dictate"
    static var description = IntentDescription("Opens Pilot and starts listening for your voice command.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let defaults = UserDefaults(suiteName: ShortcutBridge.appGroup) {
            defaults.set(true, forKey: ShortcutBridge.dictateKey)
        }

        return .result(dialog: "Pilot is listening.")
    }
}

// MARK: - App Shortcuts

struct PilotAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PilotDictateIntent(),
            phrases: [
                "Dictate to \(.applicationName)",
                "\(.applicationName) dictate",
                "Start \(.applicationName)"
            ],
            shortTitle: "Dictate",
            systemImageName: "mic"
        )
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
