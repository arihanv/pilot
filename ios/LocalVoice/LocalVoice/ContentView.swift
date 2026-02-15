import SwiftUI

struct ContentView: View {
    @State private var audioManager = AudioManager()

    var body: some View {
        VStack(spacing: 0) {
            Text(audioManager.statusMessage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !audioManager.transcription.isEmpty {
                        Label {
                            Text(audioManager.transcription)
                                .font(.body)
                        } icon: {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.blue)
                        }
                    }

                    if !audioManager.response.isEmpty {
                        Label {
                            Text(audioManager.response)
                                .font(.body)
                        } icon: {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.purple)
                        }
                    }

                    if audioManager.transcription.isEmpty && audioManager.response.isEmpty {
                        Text("Tap the mic and ask something")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal)

            // Record button
            Button {
                Task {
                    if audioManager.isRecording {
                        await audioManager.stopRecording()
                    } else {
                        await audioManager.startRecording()
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(audioManager.isRecording
                              ? Color.red.opacity(0.15)
                              : Color.blue.opacity(0.15))
                        .frame(width: 80, height: 80)

                    if audioManager.isThinking {
                        ProgressView()
                            .tint(.purple)
                    } else {
                        Image(systemName: audioManager.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(audioManager.isRecording ? .red : .blue)
                    }
                }
            }
            .disabled(audioManager.isThinking)
            .padding(.vertical, 24)
        }
    }
}

#Preview {
    ContentView()
}
