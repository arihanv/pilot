#if canImport(ActivityKit)
import ActivityKit
import Foundation

class LiveActivityManager {
    private var activity: Activity<VoiceActivityAttributes>?
    private var nonce = 0

    func start() {
        let authInfo = ActivityAuthorizationInfo()
        guard authInfo.areActivitiesEnabled else {
            print("[LiveActivity] Activities not enabled on this device")
            return
        }
        end()

        nonce = 0
        let attributes = VoiceActivityAttributes()
        let state = VoiceActivityAttributes.ContentState(agentText: "", isSpeaking: false, nonce: nonce)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            print("[LiveActivity] Started (id: \(activity?.id ?? "nil"))")
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    func update(text: String, isSpeaking: Bool, alert: Bool = true) {
        guard let activity else {
            print("[LiveActivity] Update skipped — no active activity")
            return
        }

        nonce += 1
        let state = VoiceActivityAttributes.ContentState(
            agentText: text,
            isSpeaking: isSpeaking,
            nonce: nonce
        )

        print("[LiveActivity] Updating: speaking=\(isSpeaking), alert=\(alert), nonce=\(nonce), text=\"\(text.prefix(60))\"")

        Task {
            let content = ActivityContent(state: state, staleDate: nil)
            if alert && !text.isEmpty {
                let bodyText = String(text.prefix(100))
                await activity.update(
                    content,
                    alertConfiguration: AlertConfiguration(
                        title: "Sotos",
                        body: LocalizedStringResource(stringLiteral: bodyText),
                        sound: .default
                    )
                )
            } else {
                await activity.update(content)
            }
        }
    }

    func end() {
        guard let activity else { return }

        print("[LiveActivity] Ending (id: \(activity.id))")

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
#endif
