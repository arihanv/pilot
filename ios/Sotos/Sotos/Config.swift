import Foundation
import UIKit

// MARK: - Dynamic calibration data (persisted to UserDefaults)

struct CalibrationData: Codable, Equatable {
    var screenWidthPt: Double
    var screenHeightPt: Double
    var retinaScale: Double
    var date: Date

    /// Screen points (already mapped natively by HID absolute positioning)
    func hidForPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        return (x, y)
    }

    /// Screenshot pixels (Retina) → HID coordinates (points)
    func hidForScreenshot(px: Double, py: Double) -> (x: Double, y: Double) {
        return hidForPoint(x: px / retinaScale, y: py / retinaScale)
    }

    // MARK: Persistence

    private static let key = "pilot_calibration_data"

    static func load() -> CalibrationData? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CalibrationData.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: CalibrationData.key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Static config

enum Config {
    static let openRouterAPIKey = "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"
    static let moondreamAPIKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXlfaWQiOiJmYjI3YTUwYi03OTY3LTRjZjMtYTNkNC0xMjZkM2Y0YjMyMTMiLCJvcmdfaWQiOiJQMU9Ubnp4SUNpU0YwRGNZYURTWVl5S2dHTXQ5WXBjYyIsImlhdCI6MTc3MTE1MzMyMywidmVyIjoxfQ.CoEWsqUC8xZoHCSHiaPo48dSlupvB6G9i5EAzTk3LFI"

    static let screenshotWidth: Double = 1206
    static let screenshotHeight: Double = 2622

    // Hardcoded fallback calibration (iPhone 16 Pro specific).
    static let hidScaleX: Double = 0.9404
    static let hidOffsetX: Double = -56.0
    static let hidQuadY: Double = 0.00005597
    static let hidLinearY: Double = 0.7814
    static let hidConstY: Double = 9.0

    /// Returns saved calibration or nil if not yet calibrated.
    static var calibration: CalibrationData? { CalibrationData.load() }

    static func hidForCalibratedPixel(px: Double, py: Double) -> (x: Int, y: Int) {
        if let cal = calibration {
            let hid = cal.hidForScreenshot(px: px, py: py)
            return (Int(hid.x + 0.5), Int(hid.y + 0.5))
        }
        // Fallback to basic math assuming typical iPhone scale
        let scale = UIScreen.main.scale
        return (Int(px / scale + 0.5), Int(py / scale + 0.5))
    }
}
