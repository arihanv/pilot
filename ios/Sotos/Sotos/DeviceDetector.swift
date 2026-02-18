import Foundation

/// Tracks available ESP32 BLE devices and persists the user's selection.
@MainActor
@Observable
final class DeviceDetector {
    var availableDevices: [String] = []
    var selectedDevice: String? {
        didSet { UserDefaults.standard.set(selectedDevice, forKey: "selectedESP32Device") }
    }

    init() {
        selectedDevice = UserDefaults.standard.string(forKey: "selectedESP32Device")
    }

    func refresh() async { }

    func updateFromBLE(names: [String], connected: String?) {
        availableDevices = names

        if let connected {
            selectedDevice = connected
            return
        }

        if let selected = selectedDevice, names.contains(selected) {
            return
        }

        if names.count == 1 {
            selectedDevice = names[0]
        } else if names.isEmpty {
            selectedDevice = nil
        }
    }
}
