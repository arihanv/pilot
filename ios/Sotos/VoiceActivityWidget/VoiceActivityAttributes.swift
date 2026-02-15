import ActivityKit

struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var agentText: String
        var isSpeaking: Bool
        /// Incremented on every update so iOS never deduplicates the state.
        var nonce: Int = 0
    }
}
