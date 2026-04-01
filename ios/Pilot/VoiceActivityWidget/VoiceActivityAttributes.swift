import ActivityKit

struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var phase: Phase
        var statusText: String
        /// Incremented on every update so iOS never deduplicates the state.
        var nonce: Int = 0

        enum Phase: String, Codable, Hashable {
            case thinking   // LLM is deciding next action
            case executing  // running actions on phone
            case waiting    // explicit wait
            case listening  // PTT recording
            case speaking   // TTS playback
        }
    }
}
