#if canImport(ActivityKit)
import ActivityKit

class LiveActivityManager {
    private var activity: Activity<VoiceActivityAttributes>?

    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        end()

        let attributes = VoiceActivityAttributes()
        let state = VoiceActivityAttributes.ContentState(agentText: "", isSpeaking: false)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    func update(text: String, isSpeaking: Bool) {
        guard let activity else { return }

        let state = VoiceActivityAttributes.ContentState(
            agentText: text,
            isSpeaking: isSpeaking
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
    }
}
#endif
