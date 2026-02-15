import CoreBluetooth

/// Lightweight detector that finds connected BLE HID devices named "sotos-*".
/// Uses retrieveConnectedPeripherals — no scanning required.
@Observable
final class DeviceDetector: NSObject, CBCentralManagerDelegate {
    var detectedDevice: String?
    private var central: CBCentralManager?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        refresh()
    }

    func refresh() {
        guard let central, central.state == .poweredOn else { return }
        // HID service UUID — iOS knows about this for paired BLE keyboards
        let hid = CBUUID(string: "1812")
        let peripherals = central.retrieveConnectedPeripherals(withServices: [hid])
        detectedDevice = peripherals.first(where: { ($0.name ?? "").hasPrefix("sotos-") })?.name
    }
}
