import LiveKitComponents
import SwiftUI

/// A Dynamic Island-style overlay that displays the agent's speech transcription
/// at the top of the screen during voice interactions.
struct DynamicIslandOverlay: View {
    @EnvironmentObject private var session: Session

    @State private var displayedText: String = ""
    @State private var isExpanded: Bool = false
    @State private var dismissTask: Task<Void, Never>?

    /// The most recent agent transcript from the message history.
    private var latestAgentText: String? {
        for message in session.messages.reversed() {
            if case let .agentTranscript(text) = message.content {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private var isSpeaking: Bool {
        session.agent.agentState == .speaking
    }

    var body: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                capsuleView
                    .padding(.top, 4)
//                    .transition(
//                        .asymmetric(
//                            insertion: .blurReplace
//                                .combined(with: .scale(scale: 0.5, anchor: .top)),
//                            removal: .blurReplace
//                                .combined(with: .scale(scale: 0.8, anchor: .top))
//                        )
//                    )
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: displayedText)
        .onChange(of: latestAgentText) { _, newValue in
            guard let text = newValue else { return }
            displayedText = text
            expand()
        }
        .onChange(of: isSpeaking) { _, speaking in
            if speaking {
                dismissTask?.cancel()
            } else if isExpanded {
                scheduleDismiss()
            }
        }
    }

    // MARK: - Capsule Content

    private var capsuleView: some View {
        HStack(spacing: 10) {
            AudioBarsIndicator()
                .frame(width: 16, height: 20)

            Text(visibleText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 16)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 340)
        .background {
            Capsule()
                .fill(.black)
                .overlay {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.1), .white.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
    }

    /// Shows the tail of the text so the most recent speech is always visible.
    private var visibleText: String {
        let limit = 120
        if displayedText.count > limit {
            return "…" + String(displayedText.suffix(limit))
        }
        return displayedText
    }

    // MARK: - State Management

    private func expand() {
        dismissTask?.cancel()
        isExpanded = true
        if !isSpeaking {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            isExpanded = false
        }
    }
}

// MARK: - Audio Bars Animation

private struct AudioBarsIndicator: View {
    @State private var animating = false

    private let bars: [(minH: CGFloat, maxH: CGFloat, dur: Double, delay: Double)] = [
        (4, 10, 0.38, 0.0),
        (4, 16, 0.46, 0.12),
        (4, 12, 0.42, 0.06),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< bars.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.white.opacity(0.8))
                    .frame(width: 3, height: animating ? bars[i].maxH : bars[i].minH)
                    .animation(
                        .easeInOut(duration: bars[i].dur)
                            .repeatForever(autoreverses: true)
                            .delay(bars[i].delay),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
