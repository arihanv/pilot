enum Config {
    /// OpenRouter API key — https://openrouter.ai/keys
    static let openRouterAPIKey = "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"

    /// Moondream API key — https://moondream.ai
    static let moondreamAPIKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJrZXlfaWQiOiJmYjI3YTUwYi03OTY3LTRjZjMtYTNkNC0xMjZkM2Y0YjMyMTMiLCJvcmdfaWQiOiJQMU9Ubnp4SUNpU0YwRGNZYURTWVl5S2dHTXQ5WXBjYyIsImlhdCI6MTc3MTE1MzMyMywidmVyIjoxfQ.CoEWsqUC8xZoHCSHiaPo48dSlupvB6G9i5EAzTk3LFI"

    /// Screen scale factor of the target iPhone (2.0 for older, 3.0 for modern).
    /// Used to convert screenshot pixel coordinates to logical points for HID taps.
    static let screenScale: Float = 3.0
}
