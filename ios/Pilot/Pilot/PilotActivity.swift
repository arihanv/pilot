import ActivityKit
import Foundation

// Duplicate of VoiceActivityAttributes for the main app target.
// Must stay in sync with VoiceActivityWidget/VoiceActivityAttributes.swift.
struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var phase: Phase
        var statusText: String
        var nonce: Int = 0

        enum Phase: String, Codable, Hashable {
            case thinking
            case executing
            case detecting
            case waiting
            case listening
            case speaking
        }
    }
}

/// Manages the Live Activity lifecycle for the CUA loop Dynamic Island.
@MainActor
final class PilotActivityManager {
    static let shared = PilotActivityManager()

    private var activity: Activity<VoiceActivityAttributes>?
    private var nonce = 0

    private init() {}

    func start(phase: VoiceActivityAttributes.ContentState.Phase, status: String = "") {
        // End any existing activity first
        endSync()

        let state = VoiceActivityAttributes.ContentState(phase: phase, statusText: status, nonce: nonce)
        do {
            activity = try Activity.request(
                attributes: VoiceActivityAttributes(),
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            print("[Activity] Started: \(phase.rawValue)")
        } catch {
            print("[Activity] Failed to start: \(error)")
        }
    }

    func update(phase: VoiceActivityAttributes.ContentState.Phase, status: String = "") {
        guard let activity else { return }
        nonce += 1
        let state = VoiceActivityAttributes.ContentState(phase: phase, statusText: status, nonce: nonce)
        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        nonce = 0
        let finalState = VoiceActivityAttributes.ContentState(phase: .thinking, statusText: "Done", nonce: -1)
        Task {
            await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            self.activity = nil
            print("[Activity] Ended")
        }
    }

    /// Synchronous end for use before starting a new activity.
    private func endSync() {
        guard let activity else { return }
        nonce = 0
        let finalState = VoiceActivityAttributes.ContentState(phase: .thinking, statusText: "", nonce: -1)
        Task { await activity.end(.init(state: finalState, staleDate: nil), dismissalPolicy: .immediate) }
        self.activity = nil
    }
}
