import Foundation
import UIKit

// MARK: - Detected Element

struct DetectedElement {
    let id: Int
    let xMin: CGFloat
    let yMin: CGFloat
    let xMax: CGFloat
    let yMax: CGFloat

    var centerX: CGFloat { (xMin + xMax) / 2 }
    var centerY: CGFloat { (yMin + yMax) / 2 }

    /// Center in pixel coordinates for a given image size.
    func pixelCenter(imageWidth: CGFloat, imageHeight: CGFloat) -> (x: Int, y: Int) {
        (x: Int(centerX * imageWidth), y: Int(centerY * imageHeight))
    }
}

// MARK: - Moondream Service

class MoondreamService {
    private let apiKey: String
    private let endpoint = URL(string: "https://api.moondream.ai/v1/detect")!

    init(apiKey: String) {
        self.apiKey = apiKey
        print("[Moondream] Initialized")
    }

    private func elapsed(_ start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    /// Detect objects in an image matching the given prompt.
    /// Returns normalized bounding boxes (0–1) wrapped in DetectedElement.
    func detect(imageData: Data, prompt: String) async throws -> [DetectedElement] {
        let detectStart = Date()
        let base64 = imageData.base64EncodedString()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Moondream-Auth")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "image_url": "data:image/jpeg;base64,\(base64)",
            "object": prompt
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[Moondream] Detecting: \"\(prompt)\"")
        let networkStart = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        print("[Moondream][Timing] Network \(elapsed(networkStart))")

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw MoondreamError.apiError("HTTP \(status): \(errBody.prefix(200))")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let objects = json["objects"] as? [[String: Any]] else {
            throw MoondreamError.parseError
        }

        let elements = objects.enumerated().map { index, obj in
            DetectedElement(
                id: index + 1,
                xMin: CGFloat(obj["x_min"] as? Double ?? 0),
                yMin: CGFloat(obj["y_min"] as? Double ?? 0),
                xMax: CGFloat(obj["x_max"] as? Double ?? 0),
                yMax: CGFloat(obj["y_max"] as? Double ?? 0)
            )
        }

        print("[Moondream] Found \(elements.count) elements in \(elapsed(detectStart))")
        return elements
    }

    /// Draw numbered, colored bounding boxes on the image and return JPEG data.
    func annotateImage(imageData: Data, elements: [DetectedElement]) -> Data? {
        guard let image = UIImage(data: imageData) else { return nil }
        let size = image.size

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: fmt)
        let annotated = renderer.image { context in
            image.draw(at: .zero)
            let ctx = context.cgContext

            let colors: [UIColor] = [
                UIColor(red: 0.60, green: 0.20, blue: 1.00, alpha: 1), // purple
                UIColor(red: 0.00, green: 0.50, blue: 1.00, alpha: 1), // blue
                UIColor(red: 0.00, green: 0.80, blue: 0.40, alpha: 1), // green
                UIColor(red: 1.00, green: 0.60, blue: 0.00, alpha: 1), // orange
                UIColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 1), // red
                UIColor(red: 0.00, green: 0.80, blue: 0.80, alpha: 1), // teal
                UIColor(red: 1.00, green: 0.40, blue: 0.70, alpha: 1), // pink
                UIColor(red: 0.90, green: 0.90, blue: 0.00, alpha: 1), // yellow
            ]

            for element in elements {
                let color = colors[(element.id - 1) % colors.count]
                let rect = CGRect(
                    x: element.xMin * size.width,
                    y: element.yMin * size.height,
                    width: (element.xMax - element.xMin) * size.width,
                    height: (element.yMax - element.yMin) * size.height
                )

                // Bounding box
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(5)
                ctx.stroke(rect)

                // Numbered label
                let label = "\(element.id)"
                let font = UIFont.boldSystemFont(ofSize: 36)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.white
                ]
                let textSize = (label as NSString).size(withAttributes: attrs)
                let pad: CGFloat = 6
                let bgRect = CGRect(
                    x: rect.minX, y: rect.minY,
                    width: textSize.width + pad * 2,
                    height: textSize.height + pad * 2
                )
                ctx.setFillColor(color.cgColor)
                ctx.fill(bgRect)
                (label as NSString).draw(
                    at: CGPoint(x: bgRect.minX + pad, y: bgRect.minY + pad),
                    withAttributes: attrs
                )
            }
        }

        return annotated.jpegData(compressionQuality: 0.85)
    }

    // MARK: - Errors

    enum MoondreamError: LocalizedError {
        case apiError(String)
        case parseError

        var errorDescription: String? {
            switch self {
            case .apiError(let msg): return "Moondream: \(msg)"
            case .parseError: return "Moondream: failed to parse response"
            }
        }
    }
}
