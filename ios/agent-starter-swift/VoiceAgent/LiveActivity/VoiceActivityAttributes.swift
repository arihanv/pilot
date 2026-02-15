#if canImport(ActivityKit)
import ActivityKit

struct VoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable & Hashable {
        var agentText: String
        var isSpeaking: Bool
    }
}
#endif
