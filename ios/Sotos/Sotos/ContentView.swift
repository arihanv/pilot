import SwiftUI
import ReplayKit

struct ContentView: View {
    @State private var manager = LiveModeManager(apiKey: Config.openRouterAPIKey)

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Status icon
                Image(systemName: manager.isActive ? "waveform.circle.fill" : "mic.circle")
                    .font(.system(size: 72))
                    .foregroundStyle(manager.isActive ? .cyan : .secondary)
                    .symbolEffect(.pulse, isActive: manager.isActive && !manager.isProcessing)
                    .contentTransition(.symbolEffect(.replace))

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Broadcast picker – visible when live mode is on
                if manager.isActive {
                    BroadcastButton(isBroadcastActive: manager.isBroadcastActive)
                }

                // Live partial transcription
                if manager.isActive {
                    let text = manager.speechText
                    if !text.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("You", systemImage: "person.wave.2")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(text)
                                .font(.body)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal)
                    }
                }

                // Last assistant response
                if !manager.lastResponse.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Assistant", systemImage: "sparkles")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                        Text(manager.lastResponse)
                            .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.cyan.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal)
                }

                if manager.isProcessing {
                    ProgressView()
                        .padding(.top, 4)
                }

                Spacer()

                // Error message
                if let error = manager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Phone actions
                Button {
                    manager.sendPhoneCommands([
                        "HOME", "SPOTLIGHT", "TYPE Messages", "ENTER"
                    ])
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "message.fill")
                        Text("Open Messages")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 24)

                // Live Mode toggle button
                Button {
                    Task {
                        if manager.isActive {
                            await manager.stopLiveMode()
                        } else {
                            await manager.startLiveMode()
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: manager.isActive ? "stop.fill" : "play.fill")
                        Text(manager.isActive ? "Stop Live Mode" : "Start Live Mode")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(manager.isActive ? .red : .cyan)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .navigationTitle("Sotos")
            .animation(.default, value: manager.isActive)
            .animation(.default, value: manager.isProcessing)
        }
    }

    private var statusText: String {
        if !manager.isActive { return "Tap below to start Live Mode" }
        if manager.isProcessing { return "Processing…" }
        return "Listening…"
    }
}

// MARK: - Broadcast Button

/// Programmatically triggers the system broadcast picker by finding the
/// internal UIButton inside RPSystemBroadcastPickerView and sending a tap.
struct BroadcastButton: View {
    var isBroadcastActive: Bool

    var body: some View {
        Button {
            BroadcastPicker.shared.tap()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isBroadcastActive
                      ? "record.circle.fill"
                      : "screenrecording")
                Text(isBroadcastActive
                     ? "Screen Broadcast Active"
                     : "Start Screen Broadcast")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(isBroadcastActive ? .green.opacity(0.15) : .cyan.opacity(0.15))
            .foregroundStyle(isBroadcastActive ? .green : .cyan)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Singleton that holds a hidden RPSystemBroadcastPickerView and can
/// programmatically trigger its internal button.
final class BroadcastPicker {
    static let shared = BroadcastPicker()

    private let picker: RPSystemBroadcastPickerView = {
        let p = RPSystemBroadcastPickerView()
        p.preferredExtension = "dev.ethan.Sotos.BroadcastExtension"
        p.showsMicrophoneButton = false
        return p
    }()

    func tap() {
        for subview in picker.subviews {
            if let button = subview as? UIButton {
                button.sendActions(for: .allTouchEvents)
                return
            }
        }
    }
}
