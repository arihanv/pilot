//
//  SotosApp.swift
//  Sotos
//
//  Created by Ethan Goodhart on 2/14/26.
//

import SwiftUI
import Foundation

private enum ShortcutBridge {
    static let appGroup = "group.dev.ethan.Sotos"
    static let queueKey = "shortcut_prompt_queue"
}

@main
struct SotosApp: App {
    @State private var manager = LiveModeManager(apiKey: Config.openRouterAPIKey)
    @Environment(\.scenePhase) private var scenePhase

    private func dequeueShortcutPrompts() -> [String] {
        guard let defaults = UserDefaults(suiteName: ShortcutBridge.appGroup) else { return [] }
        let queue = defaults.stringArray(forKey: ShortcutBridge.queueKey) ?? []
        if !queue.isEmpty {
            defaults.removeObject(forKey: ShortcutBridge.queueKey)
        }
        return queue
    }

    private func processQueuedShortcutPrompts() {
        let prompts = dequeueShortcutPrompts()
        for prompt in prompts {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            print("[ShortcutBridge] Received queued prompt: \(text.prefix(80))")
            manager.submitShortcutPrompt(text)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(manager: manager)
                .onAppear {
                    processQueuedShortcutPrompts()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        processQueuedShortcutPrompts()
                    }
                }
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "sotos" else { return }
                    print("[ShortcutBridge] Opened via URL: \(url.absoluteString)")

                    // Prefer App Group queue for reliable delivery across process boundaries.
                    processQueuedShortcutPrompts()

                    // Backward-compatible fallback if a text query item is present.
                    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                    let text = components.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        manager.submitShortcutPrompt(text)
                    }
                }
        }
    }
}
