enum Config {
    /// OpenRouter API key — https://openrouter.ai/keys
    static let openRouterAPIKey = "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"

    /// Moondream API key — https://moondream.ai
    static let moondreamAPIKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXlfaWQiOiJmYjI3YTUwYi03OTY3LTRjZjMtYTNkNC0xMjZkM2Y0YjMyMTMiLCJvcmdfaWQiOiJQMU9Ubnp4SUNpU0YwRGNZYURTWVl5S2dHTXQ5WXBjYyIsImlhdCI6MTc3MTE1MzMyMywidmVyIjoxfQ.CoEWsqUC8xZoHCSHiaPo48dSlupvB6G9i5EAzTk3LFI"

    /// Full screenshot resolution of the target iPhone (3x Retina).
    /// Moondream returns normalized coords (0-1); we multiply by these to get pixel coords
    /// before applying HID calibration.
    static let screenshotWidth: Double = 1206
    static let screenshotHeight: Double = 2622

    /// Calibrated pixel-to-HID conversion coefficients.
    /// Derived from: MuniMobile (184,399)→(115,330), Slack (1017,1597)→(900,1400), Phone (207,2417)→(140,2225)
    /// X is linear: HID_X = pixel_x * hidScaleX + hidOffsetX
    static let hidScaleX: Double = 0.9404
    static let hidOffsetX: Double = -56.0
    /// Y is quadratic (iOS pointer acceleration): HID_Y = pixel_y² * hidQuadY + pixel_y * hidLinearY + hidConstY
    static let hidQuadY: Double = 0.00005597
    static let hidLinearY: Double = 0.7814
    static let hidConstY: Double = 9.0
}
