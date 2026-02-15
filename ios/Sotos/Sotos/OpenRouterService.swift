import Foundation

class OpenRouterService {
    private let apiKey: String
    private let model = "google/gemini-3-flash-preview"
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// Conversation history – uses [String: Any] to support multimodal & tool messages.
    private var conversationHistory: [[String: Any]] = []

    // MARK: - Tool definitions

    private let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "get_screenshot",
                "description": "Capture a screenshot of the user's current screen. Use this when the user asks about what's on their screen, what they're looking at, needs help with something visible, or references anything visual.",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [String]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "send_phone_commands",
                "description": """
                Send HID commands to control the user's iPhone via an ESP32 BLE device. \
                Commands are executed sequentially. Use this to type text, press keys, \
                navigate the phone, tap/swipe, scroll, and use iOS shortcuts. \
                Available commands: \
                Keyboard: TYPE <text>, KEY <char>, KEYDOWN <char>, KEYUP <char>, RELEASEALL, \
                ENTER, BACKSPACE, TAB, ESC, SPACE, UP, DOWN, LEFT, RIGHT. \
                Mouse: MOVE <x> <y>, CLICK, CLICK_RIGHT, SCROLL <amount>, \
                SWIPE <x1> <y1> <x2> <y2> <steps>. \
                iOS shortcuts: VOL_UP, VOL_DOWN, HOME, LOCK, APPSWITCHER, SPOTLIGHT. \
                Example: to open Messages, send ["HOME", "SPOTLIGHT", "TYPE Messages", "ENTER"].
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "commands": [
                            "type": "array",
                            "items": ["type": "string"] as [String: Any],
                            "description": "Array of command strings to execute sequentially on the phone."
                        ] as [String: Any],
                        "delay": [
                            "type": "number",
                            "description": "Delay in seconds between commands. Defaults to 0."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["commands"] as [String]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    // MARK: - Response type

    enum ChatResponse {
        case text(String)
        case toolCall(id: String, name: String, arguments: [String: Any])
    }

    // MARK: - Init

    init(apiKey: String) {
        self.apiKey = apiKey
        print("[OpenRouter] Initialized with model: \(model)")
    }

    // MARK: - Public API

    /// Send a user text message. Returns either a text response or a tool-call request.
    func sendMessage(_ text: String) async throws -> ChatResponse {
        print("[OpenRouter] Sending message: \"\(text.prefix(80))\"")
        conversationHistory.append(["role": "user", "content": text])
        return try await callAPI()
    }

    /// Complete a get_screenshot tool call by providing the captured image.
    /// Returns the model's final text description.
    func sendScreenshotResult(toolCallId: String, imageBase64: String) async throws -> String {
        // Tool result (text-only, per OpenAI spec)
        conversationHistory.append([
            "role": "tool",
            "tool_call_id": toolCallId,
            "content": "Screenshot captured successfully."
        ])

        // Follow-up user message carrying the actual image
        conversationHistory.append([
            "role": "user",
            "content": [
                [
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(imageBase64)"]
                ] as [String: Any],
                [
                    "type": "text",
                    "text": "Here is the screenshot from my screen. Describe what you see and answer my question."
                ] as [String: Any]
            ] as [[String: Any]]
        ])

        let response = try await callAPI()
        switch response {
        case .text(let text):
            return text
        case .toolCall(_, _, _):
            // Shouldn't happen right after a screenshot, but handle gracefully
            return "I captured your screen but couldn't process it. Please try again."
        }
    }

    /// Complete a generic tool call by providing a text result.
    /// Returns the model's follow-up response.
    func sendToolResult(toolCallId: String, result: String) async throws -> ChatResponse {
        conversationHistory.append([
            "role": "tool",
            "tool_call_id": toolCallId,
            "content": result
        ])
        return try await callAPI()
    }

    func clearHistory() {
        conversationHistory.removeAll()
        print("[OpenRouter] History cleared")
    }

    // MARK: - Private

    private func callAPI() async throws -> ChatResponse {
        let systemMessage: [String: Any] = [
            "role": "system",
            "content": """
            You are a helpful voice assistant displayed in an iPhone's Dynamic Island. \
            Keep responses very concise (1-2 sentences max). Be direct and helpful. \
            You can see the user's screen using the get_screenshot tool, and you can \
            control the user's iPhone using the send_phone_commands tool. \
            When the user asks you to open apps, type text, navigate, scroll, swipe, \
            or perform any action on their phone, use send_phone_commands. \
            You can chain multiple commands in one call for complex actions. \
            For example, to open an app: ["HOME", "SPOTLIGHT", "TYPE AppName", "ENTER"]. \
            After executing commands, briefly confirm what you did.
            """
        ]

        var messages: [[String: Any]] = [systemMessage]
        messages.append(contentsOf: conversationHistory)

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 4000,
            "temperature": 1.0,
            "tools": tools
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        print("[OpenRouter] POST \(endpoint) (\(conversationHistory.count) msgs in history)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            print("[OpenRouter] Non-HTTP response received")
            throw ServiceError.parse
        }

        print("[OpenRouter] Response status: \(http.statusCode), bytes: \(data.count)")

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("[OpenRouter] Error body: \(errorBody.prefix(200))")
            throw ServiceError.api(errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[OpenRouter] Parse failed. Raw: \(raw.prefix(300))")
            throw ServiceError.parse
        }

        // ── Tool call response ──
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let firstCall = toolCalls.first,
           let function = firstCall["function"] as? [String: Any],
           let name = function["name"] as? String,
           let id = firstCall["id"] as? String {

            print("[OpenRouter] Tool call: \(name) (id: \(id))")

            // Parse arguments JSON string
            var args: [String: Any] = [:]
            if let argsString = function["arguments"] as? String,
               let argsData = argsString.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                args = parsed
            }

            // Record the assistant's tool-call message in history
            var assistantMsg: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            if let content = message["content"] as? String {
                assistantMsg["content"] = content
            }
            conversationHistory.append(assistantMsg)

            return .toolCall(id: id, name: name, arguments: args)
        }

        // ── Regular text response ──
        guard let content = message["content"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            print("[OpenRouter] No content in message. Raw: \(raw.prefix(300))")
            throw ServiceError.parse
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        conversationHistory.append(["role": "assistant", "content": trimmed])

        // Keep history manageable
        if conversationHistory.count > 20 {
            conversationHistory = Array(conversationHistory.suffix(16))
        }

        print("[OpenRouter] Response: \"\(trimmed.prefix(80))\"")
        return .text(trimmed)
    }

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case api(String)
        case parse

        var errorDescription: String? {
            switch self {
            case .api(let msg): return "API error: \(msg)"
            case .parse: return "Failed to parse response"
            }
        }
    }
}
