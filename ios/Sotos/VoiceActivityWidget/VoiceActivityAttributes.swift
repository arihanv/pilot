import ActivityKit

struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var agentText: String
        var isSpeaking: Bool
        /// Current state for Dynamic Island icon rendering.
        var phase: String = "listening"
        /// Incremented on every update so iOS never deduplicates the state.
        var nonce: Int = 0
    }
}
