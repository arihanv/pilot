import Foundation

/// Reads the latest full-device screenshot from the App Group shared container,
/// written by the BroadcastExtension's SampleHandler.
class ScreenCaptureManager {
    static let appGroupID = "group.dev.ethan.Sotos"

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        )
    }

    private var screenshotURL: URL? {
        sharedContainerURL?.appendingPathComponent("latest_screenshot.jpg")
    }

    /// Whether the broadcast extension is currently running.
    var isBroadcastActive: Bool {
        guard let containerURL = sharedContainerURL else { return false }
        let flagURL = containerURL.appendingPathComponent("broadcast_active")
        return FileManager.default.fileExists(atPath: flagURL.path)
    }

    /// Returns the latest JPEG screenshot from the broadcast, or nil.
    func takeScreenshot() -> Data? {
        guard let url = screenshotURL,
              FileManager.default.fileExists(atPath: url.path) else {
            print("[ScreenCapture] No screenshot file available")
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            print("[ScreenCapture] Read screenshot: \(data.count) bytes")
            return data
        } catch {
            print("[ScreenCapture] Failed to read screenshot: \(error)")
            return nil
        }
    }
}
