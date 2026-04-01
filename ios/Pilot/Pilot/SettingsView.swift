import SwiftUI

struct SettingsView: View {
    @Bindable var manager: LiveModeManager
    @Environment(\.dismiss) private var dismiss
    @State private var commandScript = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    deviceCard
                    commandCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .task { await manager.refreshBLEDevices() }
        }
    }

    // MARK: - Device Card

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("Bluetooth Device")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(bleStatusColor)
                        .frame(width: 8, height: 8)
                    Text(bleStatusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // GATT cache warning
            if let forgetMsg = manager.bleNeedsForget {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(forgetMsg)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Status / device picker
            if !manager.isBluetoothPoweredOn {
                Label("Turn on Bluetooth in Settings", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if manager.deviceDetector.availableDevices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Scanning for devices...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Device picker row
                HStack {
                    Text("Device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { manager.deviceDetector.selectedDevice ?? "" },
                        set: { manager.deviceDetector.selectedDevice = $0 }
                    )) {
                        ForEach(manager.deviceDetector.availableDevices, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let connected = manager.connectedDevice {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.subheadline)
                        Text("Connected to \(connected)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                ActionButton(title: "Scan", icon: "arrow.clockwise", style: .secondary) {
                    Task { await manager.refreshBLEDevices() }
                }

                ActionButton(title: "Connect", icon: "link", style: .secondary) {
                    manager.connectSelectedBLEDevice()
                }
                .disabled(manager.deviceDetector.selectedDevice == nil || manager.isBLEBusy)

                ActionButton(title: "Disconnect", icon: "xmark", style: .destructive) {
                    manager.disconnectBLEDevice()
                }
                .disabled(!manager.isBLEConnected)
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Command Card

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("BLE Commands")
                    .font(.subheadline.weight(.semibold))
            }

            Divider()

            // Editor
            ZStack(alignment: .topLeading) {
                if commandScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("spotlight\ntype hello world\nkey enter\nWAIT 0.5\nclick 50 50")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                }
                TextEditor(text: $commandScript)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 110)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text("One command per line. Supports WAIT / DELAY in seconds.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // Action buttons
            HStack(spacing: 8) {
                ActionButton(title: "Run", icon: "play.fill", style: .primary) {
                    manager.runCommandScriptFireAndForget(commandScript)
                }
                .disabled(commandScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isBLEBusy)

                ActionButton(title: "Clear", icon: "trash", style: .secondary) {
                    commandScript = ""
                }
                .disabled(commandScript.isEmpty)

                Spacer()
            }
        }
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Helpers

    private var bleStatusColor: Color {
        if !manager.isBluetoothPoweredOn { return .gray }
        if manager.isBLEConnected { return .green }
        if manager.isBLEBusy { return .orange }
        return .red
    }

    private var bleStatusLabel: String {
        if !manager.isBluetoothPoweredOn { return "Off" }
        if manager.isBLEConnected { return "Connected" }
        if manager.isBLEBusy { return "Busy" }
        return "Disconnected"
    }
}

// MARK: - Action Button

private struct ActionButton: View {
    enum Style { case primary, secondary, destructive }

    let title: String
    let icon: String
    let style: Style
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary: return .white
        case .secondary: return .primary
        case .destructive: return .red
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary: return .blue
        case .secondary: return Color(.systemGray5)
        case .destructive: return Color(.systemGray5)
        }
    }
}
