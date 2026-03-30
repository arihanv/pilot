import ActivityKit
import SwiftUI
import WidgetKit

@main
struct VoiceActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        VoiceActivityLiveActivity()
    }
}

struct VoiceActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VoiceActivityAttributes.self) { context in
            lockScreenView(context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isSpeaking ? "waveform" : "ear.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 28, height: 28)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Sotos")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(displayText(context.state))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.state.isSpeaking ? "waveform" : "ear.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.cyan)
                    .contentTransition(.symbolEffect(.replace))
            } compactTrailing: {
                Text(displayText(context.state))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120)
            } minimal: {
                Image(systemName: context.state.isSpeaking ? "waveform" : "ear.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.cyan)
            }
        }
    }

    private func displayText(_ state: VoiceActivityAttributes.ContentState) -> String {
        state.agentText.isEmpty ? "Listening…" : state.agentText
    }

    private func lockScreenView(_ state: VoiceActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: state.isSpeaking ? "waveform" : "ear.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .contentTransition(.symbolEffect(.replace))

                Text("Sotos")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(displayText(state))
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .activityBackgroundTint(.black.opacity(0.75))
    }
}
