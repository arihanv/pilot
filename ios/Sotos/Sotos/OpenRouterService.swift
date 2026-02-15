import Foundation

class OpenRouterService {
    private let apiKey: String
    // private let model = "anthropic/claude-opus-4.6"
    private let model = "google/gemini-3-flash-preview"
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let maxConversationMessages = 40

    /// Conversation history — [String: Any] to support multimodal & tool messages.
    private var conversationHistory: [[String: Any]] = []

    // MARK: - CUA Tool Definitions

    private let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "get_screenshot",
                "description": "Capture a screenshot of the phone screen and detect UI elements using vision AI. Provide a specific detection prompt describing what to look for. The screenshot will be annotated with numbered colored bounding boxes.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "detect": [
                            "type": "string",
                            "description": "What to detect on screen. Be specific: 'app icons', 'the Uber request ride button', 'text input fields', 'all buttons and links'. Sent to a vision model for element detection."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["detect"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "tap_element",
                "description": "Tap on a UI element detected in the last screenshot. Use the element's numbered ID from the annotated screenshot.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "element_id": [
                            "type": "integer",
                            "description": "The numbered element ID from the annotated screenshot."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["element_id"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "type_text",
                "description": "Type text using the keyboard. Text is typed character by character. Make sure a text field is focused first.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The text to type."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["text"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "swipe_screen",
                "description": "Swipe gesture on the phone screen. Use for scrolling content, navigating pages, or dismissing views.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "direction": [
                            "type": "string",
                            "enum": ["up", "down", "left", "right"],
                            "description": "Swipe direction. 'up' scrolls content down, 'down' scrolls content up."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["direction"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "press_key",
                "description": "Press a special key or iOS shortcut on the phone.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "key": [
                            "type": "string",
                            "enum": ["HOME", "ENTER", "BACKSPACE", "SPOTLIGHT", "APPSWITCHER", "LOCK", "ESC", "TAB", "SPACE"],
                            "description": "Key to press. HOME = home screen, SPOTLIGHT = search, APPSWITCHER = app switcher."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["key"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "wait_seconds",
                "description": "Wait for a duration. Use after tapping to let animations complete or pages load before taking the next screenshot.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "seconds": [
                            "type": "number",
                            "description": "Seconds to wait (0.5 to 5)."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["seconds"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    ]

    // MARK: - Response Types

    enum ChatResponse {
        case text(String)
        case toolCall(id: String, name: String, arguments: [String: Any])
    }

    enum ToolResultContent {
        case text(String)
        case textWithImage(text: String, imageBase64: String)
    }

    // MARK: - Init

    init(apiKey: String) {
        self.apiKey = apiKey
        print("[OpenRouter] Initialized with model: \(model)")
    }

    // MARK: - Public API

    /// Send a user text message.
    func sendMessage(_ text: String) async throws -> ChatResponse {
        print("[OpenRouter] User: \"\(text.prefix(80))\"")
        conversationHistory.append(["role": "user", "content": text])
        trimConversationHistory()
        return try await callAPI()
    }

    /// Send a tool execution result back to the model.
    func sendToolResult(toolCallId: String, content: ToolResultContent) async throws -> ChatResponse {
        switch content {
        case .text(let text):
            conversationHistory.append([
                "role": "tool",
                "tool_call_id": toolCallId,
                "content": text
            ])

        case .textWithImage(let text, let imageBase64):
            // Strip old images to keep payload size manageable
            stripOldImages()

            conversationHistory.append([
                "role": "tool",
                "tool_call_id": toolCallId,
                "content": text
            ])
            conversationHistory.append([
                "role": "user",
                "content": [
                    [
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(imageBase64)"]
                    ] as [String: Any],
                    [
                        "type": "text",
                        "text": "Above is the annotated screenshot with numbered element bounding boxes. Refer to elements by their number when using tap_element."
                    ] as [String: Any]
                ] as [[String: Any]]
            ])
        }
        trimConversationHistory()

        return try await callAPI()
    }

    func clearHistory() {
        conversationHistory.removeAll()
        print("[OpenRouter] History cleared")
    }

    // MARK: - Private

    /// Replace older image messages with a text placeholder to keep payloads small.
    private func stripOldImages() {
        for i in 0..<conversationHistory.count {
            if let content = conversationHistory[i]["content"] as? [[String: Any]],
               content.contains(where: { ($0["type"] as? String) == "image_url" }) {
                conversationHistory[i] = [
                    "role": conversationHistory[i]["role"] as? String ?? "user",
                    "content": "[Previous screenshot removed — see latest screenshot for current state]"
                ]
            }
        }
    }

    private func trimConversationHistory() {
        guard conversationHistory.count > maxConversationMessages else { return }
        conversationHistory = Array(conversationHistory.suffix(maxConversationMessages))
        // Don't start with orphaned tool results — drop until we hit a user or assistant message
        while let first = conversationHistory.first,
              (first["role"] as? String) == "tool" {
            conversationHistory.removeFirst()
        }
    }

    private func callAPI() async throws -> ChatResponse {
        let systemMessage: [String: Any] = [
            "role": "system",
            "content": """
            You are a phone automation agent that controls an iPhone through screen vision and touch actions. \
            You accomplish tasks by repeatedly taking screenshots with element detection, deciding what to \
            interact with, and executing actions.

            WORKFLOW:
            1. Call get_screenshot with a specific detection prompt to see the current screen
            2. Examine the annotated screenshot — elements have numbered colored bounding boxes
            3. Call tap_element with the element number, or use type_text, swipe_screen, press_key
            4. Use wait_seconds(1) after actions for animations/loading
            5. Call get_screenshot again to verify the result and see the new state
            6. Repeat until the task is complete

            RULES:
            - ALWAYS start by taking a screenshot to see the current screen state
            - Write SPECIFIC detection prompts (e.g. "the Uber app icon" not just "icons")
            - If no elements detected, try a different/broader detection prompt
            - To open an app: press_key HOME → press_key SPOTLIGHT → type_text "AppName" → press_key ENTER
            - After completing the task, briefly tell the user what you accomplished (1-2 sentences)
            - If stuck after 3 attempts, explain what's happening and ask for help
            """
        ]

        var messages: [[String: Any]] = [systemMessage]
        messages.append(contentsOf: conversationHistory)

        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": 4096,
            "temperature": 0.2,
            "tools": tools
        ]

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        print("[OpenRouter] POST (\(conversationHistory.count) msgs)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parse
        }

        print("[OpenRouter] \(http.statusCode), \(data.count) bytes")

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown"
            print("[OpenRouter] ❌ HTTP \(http.statusCode) Error body:\n\(errorBody.prefix(800))")
            throw ServiceError.api(errorBody)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else {
            throw ServiceError.parse
        }

        // ── Tool call ──
        if let toolCalls = message["tool_calls"] as? [[String: Any]],
           let firstCall = toolCalls.first,
           let function = firstCall["function"] as? [String: Any],
           let name = function["name"] as? String,
           let id = firstCall["id"] as? String {

            print("[OpenRouter] Tool: \(name) (id: \(id))")

            var args: [String: Any] = [:]
            if let argsStr = function["arguments"] as? String,
               let argsData = argsStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                args = parsed
            }

            // Record assistant tool-call in history
            var assistantMsg: [String: Any] = ["role": "assistant", "tool_calls": toolCalls]
            if let content = message["content"] as? String {
                assistantMsg["content"] = content
            }
            conversationHistory.append(assistantMsg)
            trimConversationHistory()

            return .toolCall(id: id, name: name, arguments: args)
        }

        // ── Text response ──
        guard let content = message["content"] as? String else {
            throw ServiceError.parse
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        conversationHistory.append(["role": "assistant", "content": trimmed])
        trimConversationHistory()

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
