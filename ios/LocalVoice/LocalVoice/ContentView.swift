import SwiftUI

struct ContentView: View {
    @State private var audioManager = AudioManager()

    var body: some View {
        VStack(spacing: 0) {
            // Status header
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .shadow(color: statusColor.opacity(0.6),
                                radius: audioManager.isSpeaking ? 6 : 0)
                        .animation(.easeInOut(duration: 0.3), value: audioManager.isSpeaking)

                    Text(audioManager.statusMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if audioManager.isListening {
                    Text(audioManager.isSpeaking ? "Speaking" : "Silent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(audioManager.isSpeaking ? .green : .orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill((audioManager.isSpeaking ? Color.green : Color.orange)
                                    .opacity(0.15))
                        )
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: audioManager.isSpeaking)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Transcription area
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if audioManager.displayText.isEmpty {
                            Text(audioManager.isListening
                                 ? "Listening for speech…"
                                 : "Tap the microphone to begin")
                                .foregroundStyle(.tertiary)
                                .italic()
                        } else {
                            (Text(audioManager.confirmedText)
                                .foregroundColor(.primary)
                             + Text(audioManager.volatileText)
                                .foregroundColor(.secondary))
                        }

                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .font(.title3.leading(.relaxed))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .onChange(of: audioManager.displayText) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal)

            // Mic button
            VStack(spacing: 12) {
                Button {
                    Task {
                        if audioManager.isListening {
                            await audioManager.stopListening()
                        } else {
                            await audioManager.startListening()
                        }
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(audioManager.isListening
                                  ? Color.red.opacity(0.15)
                                  : Color.blue.opacity(0.15))
                            .frame(width: 80, height: 80)

                        // Pulsing ring while speaking
                        if audioManager.isSpeaking {
                            Circle()
                                .stroke(Color.green.opacity(0.4), lineWidth: 2)
                                .frame(width: 92, height: 92)
                                .phaseAnimator([false, true]) { content, phase in
                                    content
                                        .scaleEffect(phase ? 1.15 : 1.0)
                                        .opacity(phase ? 0.3 : 0.7)
                                } animation: { _ in .easeInOut(duration: 0.8) }
                        }

                        Image(systemName: audioManager.isListening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(audioManager.isListening ? .red : .blue)
                    }
                }
                .disabled(audioManager.isLoading)
                .opacity(audioManager.isLoading ? 0.5 : 1.0)

                if audioManager.isLoading {
                    ProgressView()
                        .tint(.secondary)
                }
            }
            .padding(.vertical, 24)
        }
    }

    private var statusColor: Color {
        if audioManager.isSpeaking { return .green }
        if audioManager.isListening { return .orange }
        return .gray
    }
}

#Preview {
    ContentView()
}
