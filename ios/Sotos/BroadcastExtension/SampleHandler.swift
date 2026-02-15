//
//  SampleHandler.swift
//  BroadcastExtension
//
//  Created by Ethan Goodhart on 2/14/26.
//

import ReplayKit
import CoreMedia
import UIKit
import CoreImage

/// Broadcast Upload Extension handler. Receives full-device screen frames and
/// writes the latest one as a JPEG to the App Group shared container so the
/// main Sotos app can read it on demand.
class SampleHandler: RPBroadcastSampleHandler {
    static let appGroupID = "group.dev.ethan.Sotos"

    private let ciContext = CIContext()
    private var frameCount = 0

    /// Process every Nth video frame to save CPU (~2 fps at 30 fps input).
    private let captureInterval = 15

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        )
    }

    // MARK: - Lifecycle

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let containerURL = sharedContainerURL else { return }

        // Write a flag so the main app knows the broadcast is live.
        let flagURL = containerURL.appendingPathComponent("broadcast_active")
        try? Data().write(to: flagURL)

        // Clear stale screenshot.
        let screenshotURL = containerURL.appendingPathComponent("latest_screenshot.jpg")
        try? FileManager.default.removeItem(at: screenshotURL)
    }

    override func broadcastFinished() {
        guard let containerURL = sharedContainerURL else { return }
        let flagURL = containerURL.appendingPathComponent("broadcast_active")
        try? FileManager.default.removeItem(at: flagURL)
    }

    // MARK: - Frame processing

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video else { return }

        frameCount += 1
        guard frameCount % captureInterval == 0 else { return }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let containerURL = sharedContainerURL else { return }

        let screenshotURL = containerURL.appendingPathComponent("latest_screenshot.jpg")

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let uiImage = UIImage(cgImage: cgImage)
        
        // Scale down for API efficiency (max 1024px on longest side).
        let maxDim: CGFloat = 1024
        let scale = min(maxDim / uiImage.size.width, maxDim / uiImage.size.height, 1.0)
        let newSize = CGSize(
            width: floor(uiImage.size.width * scale),
            height: floor(uiImage.size.height * scale)
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let scaled = renderer.image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: newSize))
        }

        if let jpegData = scaled.jpegData(compressionQuality: 0.7) {
            try? jpegData.write(to: screenshotURL, options: .atomic)
        }
    }
}
