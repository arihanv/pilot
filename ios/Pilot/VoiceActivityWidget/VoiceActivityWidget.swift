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
                    phaseIcon(context.state.phase, size: 16)
                        .frame(width: 28, height: 28)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Pilot")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.statusText.isEmpty ? phaseLabel(context.state.phase) : context.state.statusText)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            } compactLeading: {
                phaseIcon(context.state.phase, size: 12)
            } compactTrailing: {
                Text(context.state.statusText.isEmpty ? phaseLabel(context.state.phase) : context.state.statusText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120)
            } minimal: {
                phaseIcon(context.state.phase, size: 12)
            }
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: VoiceActivityAttributes.ContentState.Phase, size: CGFloat) -> some View {
        let config = phaseConfig(phase)
        Image(systemName: config.icon)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(config.color)
            .symbolEffect(.variableColor.iterative, isActive: phase == .thinking || phase == .executing)
            .contentTransition(.symbolEffect(.replace))
    }

    private struct PhaseConfig {
        let icon: String
        let color: Color
    }

    private func phaseConfig(_ phase: VoiceActivityAttributes.ContentState.Phase) -> PhaseConfig {
        switch phase {
        case .thinking:  return PhaseConfig(icon: "sparkles", color: .purple)
        case .executing: return PhaseConfig(icon: "bolt.fill", color: .cyan)
        case .waiting:   return PhaseConfig(icon: "clock.fill", color: .orange)
        case .listening: return PhaseConfig(icon: "ear.fill", color: .green)
        case .speaking:  return PhaseConfig(icon: "waveform", color: .cyan)
        }
    }

    private func phaseLabel(_ phase: VoiceActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .thinking:  return "Thinking…"
        case .executing: return "Executing…"
        case .waiting:   return "Waiting…"
        case .listening: return "Listening…"
        case .speaking:  return "Speaking…"
        }
    }

    private func lockScreenView(_ state: VoiceActivityAttributes.ContentState) -> some View {
        let config = phaseConfig(state.phase)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: config.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(config.color)
                    .symbolEffect(.variableColor.iterative, isActive: state.phase == .thinking || state.phase == .executing)
                    .contentTransition(.symbolEffect(.replace))

                Text("Pilot")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Spacer()
            }

            Text(state.statusText.isEmpty ? phaseLabel(state.phase) : state.statusText)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .activityBackgroundTint(.black.opacity(0.75))
    }
}
