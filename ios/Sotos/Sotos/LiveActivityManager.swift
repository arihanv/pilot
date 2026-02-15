import ActivityKit
import Foundation

@MainActor
class LiveActivityManager {
    private var activity: Activity<VoiceActivityAttributes>?
    private var nonce = 0

    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = VoiceActivityAttributes()
        let state = VoiceActivityAttributes.ContentState(agentText: "", isSpeaking: false, nonce: 0)
        do {
            activity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    func update(agentText: String, isSpeaking: Bool) {
        nonce += 1
        let state = VoiceActivityAttributes.ContentState(agentText: agentText, isSpeaking: isSpeaking, nonce: nonce)
        Task {
            await activity?.update(.init(state: state, staleDate: nil))
        }
    }

    func stop() {
        let state = VoiceActivityAttributes.ContentState(agentText: "", isSpeaking: false, nonce: nonce + 1)
        Task {
            await activity?.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        activity = nil
    }
}
