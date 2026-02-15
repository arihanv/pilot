import AppIntents

struct SendPromptToSotosIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Prompt to Sotos"
    static var description = IntentDescription("Sends a text prompt to Sotos so it can run without dictation.")
    static var openAppWhenRun = true

    @Parameter(title: "Prompt")
    var prompt: String

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$prompt) to Sotos")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var components = URLComponents()
        components.scheme = "sotos"
        components.host = "shortcut"
        components.queryItems = [URLQueryItem(name: "text", value: prompt)]

        guard let url = components.url else {
            throw NSError(domain: "SotosShortcuts", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not create Sotos shortcut URL."
            ])
        }

        return .result(
            opensIntent: OpenURLIntent(url),
            dialog: IntentDialog("Sent your prompt to Sotos.")
        )
    }
}

struct SotosAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendPromptToSotosIntent(),
            phrases: [
                "Ask \(.applicationName) \(\.$prompt)",
                "Send to \(.applicationName) \(\.$prompt)"
            ],
            shortTitle: "Send Prompt",
            systemImageName: "text.bubble"
        )
    }
}
