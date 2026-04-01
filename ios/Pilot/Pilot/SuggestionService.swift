import UIKit

// MARK: - Installed App Info

struct InstalledApp: Identifiable {
    let id: String            // URL scheme or bundle ID
    let name: String
    var iconURL: URL? = nil   // fetched from iTunes Search API
}

// MARK: - Suggestion

struct Suggestion: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let app: InstalledApp
}

// MARK: - App Icon Fetcher (iTunes Search API)

actor AppIconFetcher {
    static let shared = AppIconFetcher()
    private var cache: [String: URL] = [:]

    func fetchIconURLs(for apps: [InstalledApp]) async -> [String: URL] {
        // Only fetch ones we haven't cached yet
        let needed = apps.filter { cache[$0.name] == nil }
        if needed.isEmpty {
            print("[Icons] All \(apps.count) icons cached")
            return cache
        }

        print("[Icons] Fetching icons for \(needed.count) apps...")

        await withTaskGroup(of: (String, URL?).self) { group in
            for app in needed {
                group.addTask {
                    let url = await self.searchiTunes(appName: app.name)
                    return (app.name, url)
                }
            }
            for await (name, url) in group {
                if let url { cache[name] = url }
            }
        }

        print("[Icons] Cached \(cache.count) icon URLs")
        return cache
    }

    private func searchiTunes(appName: String) async -> URL? {
        let query = appName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appName
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(query)&entity=software&limit=1&country=US") else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first,
                  let artworkString = first["artworkUrl512"] as? String ?? first["artworkUrl100"] as? String,
                  let artworkURL = URL(string: artworkString)
            else { return nil }
            return artworkURL
        } catch {
            return nil
        }
    }
}

// MARK: - Installed Apps Discovery (URL Scheme probing)

final class InstalledAppsProvider {
    static let shared = InstalledAppsProvider()

    // Apps we can detect via URL schemes. Name must match what the user would say to Spotlight.
    private static let knownApps: [(name: String, scheme: String)] = [
        // Social
        ("Instagram", "instagram://"),
        ("Twitter", "twitter://"),
        ("TikTok", "snssdk1233://"),
        ("Snapchat", "snapchat://"),
        ("Facebook", "fb://"),
        ("Reddit", "reddit://"),
        ("Threads", "barcelona://"),
        ("LinkedIn", "linkedin://"),
        ("Discord", "discord://"),
        ("Telegram", "tg://"),
        ("WhatsApp", "whatsapp://"),
        ("Signal", "sgnl://"),
        ("BeReal", "bereal://"),
        // Media
        ("Spotify", "spotify://"),
        ("YouTube", "youtube://"),
        ("Netflix", "nflx://"),
        ("Twitch", "twitch://"),
        ("SoundCloud", "soundcloud://"),
        ("Apple Music", "music://"),
        ("Podcasts", "podcasts://"),
        ("Apple TV", "videos://"),
        // Productivity
        ("Slack", "slack://"),
        ("Notion", "notion://"),
        ("Google Docs", "googledocs://"),
        ("Google Maps", "comgooglemaps://"),
        ("Zoom", "zoomus://"),
        ("Microsoft Teams", "msteams://"),
        ("Outlook", "ms-outlook://"),
        ("Gmail", "googlegmail://"),
        ("Google Calendar", "googlecalendar://"),
        // Shopping / Food
        ("Amazon", "com.amazon.mobile.shopping://"),
        ("Uber", "uber://"),
        ("Uber Eats", "ubereats://"),
        ("DoorDash", "doordash://"),
        ("Instacart", "instacart://"),
        ("Venmo", "venmo://"),
        ("Cash App", "cashme://"),
        ("PayPal", "paypal://"),
        // Travel
        ("Airbnb", "airbnb://"),
        ("Google Flights", "googleflights://"),
        // Fitness / Health
        ("Strava", "strava://"),
        ("Nike Run Club", "nikerunclub://"),
        // Utilities
        ("Google Chrome", "googlechrome://"),
        ("Firefox", "firefox://"),
        // Apple built-in (always present)
        ("Safari", "x-web-search://"),
        ("Messages", "sms://"),
        ("Phone", "tel://"),
        ("Mail", "mailto:"),
        ("Calendar", "calshow://"),
        ("Notes", "mobilenotes://"),
        ("Reminders", "x-apple-reminderkit://"),
        ("Maps", "maps://"),
        ("Camera", "camera://"),
        ("Photos", "photos-redirect://"),
        ("Clock", "clock-alarm://"),
        ("Weather", "weather://"),
        ("Settings", "App-prefs://"),
        ("Files", "shareddocuments://"),
        ("Shortcuts", "shortcuts://"),
        ("FaceTime", "facetime://"),
    ]

    @MainActor
    func getInstalledApps() -> [InstalledApp] {
        print("[Apps] Probing \(Self.knownApps.count) URL schemes...")
        var apps: [InstalledApp] = []
        for entry in Self.knownApps {
            guard let url = URL(string: entry.scheme),
                  UIApplication.shared.canOpenURL(url)
            else { continue }
            apps.append(InstalledApp(id: entry.scheme, name: entry.name))
        }
        print("[Apps] Found \(apps.count) installed: \(apps.map(\.name))")
        return apps
    }
}

// MARK: - Suggestion Generator

actor SuggestionGenerator {
    private let apiKey: String
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func generateSuggestions(apps: [InstalledApp], count: Int = 3) async -> [Suggestion] {
        print("[Suggestions] Starting generation with \(apps.count) installed apps")
        let appNames = apps.map(\.name)
        let appLookup = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })

        let shuffled = appNames.shuffled().prefix(25)
        let appList = shuffled.joined(separator: ", ")
        print("[Suggestions] Using apps: \(appList)")

        let prompt = """
        The user has these apps installed: \(appList).

        Generate exactly \(count) short, practical task suggestions that use these specific apps. Each suggestion should be something a phone automation agent can do.

        Respond ONLY with a JSON array, no markdown, no explanation:
        [{"app": "exact app name", "title": "short action (3-5 words)", "subtitle": "brief detail (3-6 words)"}]

        Examples of good suggestions:
        - {"app": "Messages", "title": "Text back Sarah", "subtitle": "\\"Running 10 min late\\""}
        - {"app": "Spotify", "title": "Play focus playlist", "subtitle": "lo-fi beats station"}
        - {"app": "Calendar", "title": "Check tomorrow's schedule", "subtitle": "morning meetings"}

        Keep titles punchy and actionable. Subtitles add context. Use ONLY apps from the list.
        """

        do {
            let body: [String: Any] = [
                "model": "google/gemini-3-flash-preview",
                "messages": [["role": "user", "content": prompt]],
                "max_tokens": 512,
                "temperature": 0.9
            ]

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            print("[Suggestions] Calling OpenRouter API...")
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("[Suggestions] API response status: \(statusCode)")

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[Suggestions] Failed to parse response as JSON")
                let raw = String(data: data, encoding: .utf8) ?? "nil"
                print("[Suggestions] Raw response: \(raw.prefix(500))")
                return []
            }

            if let error = json["error"] as? [String: Any] {
                print("[Suggestions] API error: \(error)")
                return []
            }

            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String
            else {
                print("[Suggestions] Missing choices/message/content in response")
                print("[Suggestions] Keys: \(json.keys.sorted())")
                return []
            }

            print("[Suggestions] LLM response: \(content.prefix(300))")

            // Parse the JSON array from the response
            let cleaned = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let arrayData = cleaned.data(using: .utf8),
                  let items = try JSONSerialization.jsonObject(with: arrayData) as? [[String: String]]
            else {
                print("[Suggestions] Failed to parse LLM JSON: \(cleaned.prefix(300))")
                return []
            }

            print("[Suggestions] Parsed \(items.count) items from LLM")

            let results = items.compactMap { item -> Suggestion? in
                guard let appName = item["app"],
                      let title = item["title"],
                      let subtitle = item["subtitle"]
                else {
                    print("[Suggestions] Skipping malformed item: \(item)")
                    return nil
                }
                guard let app = appLookup[appName] else {
                    print("[Suggestions] App not found in lookup: '\(appName)'")
                    return nil
                }
                return Suggestion(title: title, subtitle: subtitle, app: app)
            }.prefix(count).map { $0 }

            print("[Suggestions] Final results: \(results.count) suggestions")
            return results

        } catch {
            print("[Suggestions] Error: \(error)")
            return []
        }
    }
}
