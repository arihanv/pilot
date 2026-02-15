import SwiftUI

struct ContentView: View {
    @Bindable var manager: LiveModeManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusHeader

                    if manager.isActive, manager.isBroadcastActive {
                        infoCard {
                            HStack(spacing: 8) {
                                Image(systemName: "record.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Screen Broadcast Active")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                    }

                    if manager.isActive, !manager.speechText.isEmpty {
                        infoCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("You", systemImage: "person.wave.2")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(manager.speechText)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }

                    if !manager.cuaStatus.isEmpty {
                        infoCard {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.9)
                                Text(manager.cuaStatus)
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !manager.lastResponse.isEmpty {
                        infoCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Assistant", systemImage: "sparkles")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.blue)
                                Text(manager.lastResponse)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }

                    if manager.isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Processing…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if manager.isSpeaking {
                        HStack(spacing: 6) {
                            Image(systemName: "speaker.wave.2.fill")
                                .symbolEffect(.variableColor.iterative, isActive: true)
                            Text("Speaking…")
                        }
                        .font(.footnote)
                        .foregroundStyle(.blue)
                    }

                    deviceSection

                    if let error = manager.errorMessage {
                        infoCard {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Sotos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(.systemGroupedBackground), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .preferredColorScheme(.light)
            .animation(.default, value: manager.isActive)
            .animation(.default, value: manager.isRecording)
            .animation(.default, value: manager.isProcessing)
            .animation(.default, value: manager.isSpeaking)
            .animation(.default, value: manager.cuaStatus)
            .task { await manager.deviceDetector.refresh() }
            .safeAreaInset(edge: .bottom) {
                actionButtons
                    .frame(maxWidth: 430)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(Color(.systemGroupedBackground))
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    private var statusHeader: some View {
        infoCard {
            VStack(spacing: 10) {
                Image(systemName: manager.isActive ? "waveform.circle.fill" : "mic.circle")
                    .font(.system(size: 52))
                    .foregroundStyle(manager.isActive ? .blue : .secondary)
                    .symbolEffect(.pulse, isActive: manager.isActive && !manager.isProcessing)
                    .contentTransition(.symbolEffect(.replace))

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        if manager.deviceDetector.availableDevices.count > 1 {
            infoCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Device")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Picker("Device", selection: Binding(
                        get: { manager.deviceDetector.selectedDevice ?? "" },
                        set: { manager.deviceDetector.selectedDevice = $0 }
                    )) {
                        ForEach(manager.deviceDetector.availableDevices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        } else if let device = manager.connectedDevice {
            infoCard {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text(device)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if manager.isActive {
                pttButton
            } else {
                Button {
                    Task { await manager.startLiveMode() }
                } label: {
                    Label("Start Live Mode", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ProminentActionButtonStyle(color: .blue))
            }

            if manager.isActive {
                Button {
                    Task { await manager.stopLiveMode() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var pttButton: some View {
        let isHeld = manager.isRecording
        return Circle()
            .fill(isHeld ? Color.red : Color.blue)
            .frame(width: 88, height: 88)
            .overlay(
                Image(systemName: isHeld ? "mic.fill" : "mic")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: isHeld)
            )
            .shadow(color: (isHeld ? Color.red : Color.blue).opacity(0.4), radius: isHeld ? 16 : 8, y: 4)
            .scaleEffect(isHeld ? 1.12 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHeld)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !manager.isRecording {
                            manager.beginRecording()
                        }
                    }
                    .onEnded { _ in
                        manager.endRecording()
                    }
            )
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private var statusText: String {
        if !manager.isActive { return "Tap below to start Live Mode" }
        if manager.isProcessing { return "Processing…" }
        if manager.isRecording { return "Listening…" }
        return "Hold mic to talk"
    }
}

private struct ProminentActionButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 16)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

