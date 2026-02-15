import Foundation

/// Fetches available ESP32 devices from the relay server and persists the user's selection.
@MainActor
@Observable
final class DeviceDetector {
    var availableDevices: [String] = []
    var selectedDevice: String? {
        didSet { UserDefaults.standard.set(selectedDevice, forKey: "selectedESP32Device") }
    }

    private let baseURL = "https://claire.ariv.sh"

    init() {
        selectedDevice = UserDefaults.standard.string(forKey: "selectedESP32Device")
    }

    func refresh() async {
        guard let url = URL(string: "\(baseURL)/status") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devices = json["devices"] as? [String] {
                availableDevices = devices
                // Auto-select if saved device is still available
                if let saved = selectedDevice, devices.contains(saved) { return }
                // Auto-select if only one device
                if devices.count == 1 { selectedDevice = devices[0] }
            }
        } catch {
            print("[DeviceDetector] Error: \(error)")
        }
    }
}
