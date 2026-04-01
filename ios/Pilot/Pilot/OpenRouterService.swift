import Foundation

class OpenRouterService {
    private let apiKey: String
    var model = "google/gemini-3-flash-preview"
    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let maxConversationMessages = 40
    private var outboundMessageCount = 0

    /// Conversation history — [String: Any] to support multimodal & tool messages.
    private var conversationHistory: [[String: Any]] = []

    // MARK: - CUA Tool Definitions

    private let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "execute_actions",
                "description": """
                Execute a sequence of actions on the phone. Actions run in order. \
                ALWAYS use this tool — batch multiple actions when you know the sequence ahead of time. \
                For example, to open an app: [press_key HOME, press_key SPOTLIGHT, type_text "AppName", press_key ENTER, wait_seconds 1, get_screenshot]. \
                Use get_screenshot as the last action when you need to see the result. \
                A sequence can be length 1 if only one action is needed.
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "actions": [
                            "type": "array",
                            "description": "Ordered list of actions to execute.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "action": [
                                        "type": "string",
                                        "enum": ["get_screenshot", "tap_element", "type_text", "swipe_screen", "scroll_screen", "press_key", "wait_seconds"],
                                        "description": "get_screenshot: capture screen & detect elements (requires 'detect'). tap_element: tap a detected element (requires 'element_id'). type_text: type characters (requires 'text'). swipe_screen: swipe in a direction (requires 'direction': up/down/left/right). scroll_screen: scroll vertically (requires 'direction': up/down, optional 'amount'). press_key: press a key (requires 'key': HOME/ENTER/BACKSPACE/SPOTLIGHT/APPSWITCHER/LOCK/ESC/TAB/SPACE). wait_seconds: pause (requires 'seconds': 0.5-5)."
                                    ] as [String: Any],
                                    "detect": [
                                        "type": "string",
                                        "description": "For get_screenshot: what to detect. Be specific: 'the send button', 'text input fields', 'all buttons and links'."
                                    ] as [String: Any],
                                    "element_id": [
                                        "type": "integer",
                                        "description": "For tap_element: element number from the last annotated screenshot."
                                    ] as [String: Any],
                                    "text": [
                                        "type": "string",
                                        "description": "For type_text: the text to type."
                                    ] as [String: Any],
                                    "direction": [
                                        "type": "string",
                                        "enum": ["up", "down", "left", "right"],
                                        "description": "For swipe_screen/scroll_screen."
                                    ] as [String: Any],
                                    "key": [
                                        "type": "string",
                                        "enum": ["HOME", "ENTER", "BACKSPACE", "SPOTLIGHT", "APPSWITCHER", "LOCK", "ESC", "TAB", "SPACE"],
                                        "description": "For press_key."
                                    ] as [String: Any],
                                    "seconds": [
                                        "type": "number",
                                        "description": "For wait_seconds (0.5-5)."
                                    ] as [String: Any],
                                    "amount": [
                                        "type": "integer",
                                        "description": "For scroll_screen: intensity (default 5)."
                                    ] as [String: Any]
                                ] as [String: Any],
                                "required": ["action"]
                            ] as [String: Any]
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["actions"]
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
        logOutboundMessage(role: "user", details: "\"\(text.prefix(80))\"")
        conversationHistory.append(["role": "user", "content": text])
        trimConversationHistory()
        return try await callAPI()
    }

    /// Send a tool execution result back to the model.
    func sendToolResult(toolCallId: String, content: ToolResultContent) async throws -> ChatResponse {
        switch content {
        case .text(let text):
            logOutboundMessage(role: "tool", details: "tool_call_id=\(toolCallId), text=\"\(text.prefix(80))\"")
            conversationHistory.append([
                "role": "tool",
                "tool_call_id": toolCallId,
                "content": text
            ])

        case .textWithImage(let text, let imageBase64):
            // Strip old images to keep payload size manageable
            stripOldImages()

            logOutboundMessage(role: "tool", details: "tool_call_id=\(toolCallId), text+image (\(imageBase64.count) b64 chars)")
            conversationHistory.append([
                "role": "tool",
                "tool_call_id": toolCallId,
                "content": text
            ])
            logOutboundMessage(role: "user", details: "annotated screenshot payload (\(imageBase64.count) b64 chars)")
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

    private func logOutboundMessage(role: String, details: String) {
        outboundMessageCount += 1
        print("[LLM][OUT #\(outboundMessageCount)] \(role): \(details)")
    }

    private func elapsed(_ start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    private func callAPI() async throws -> ChatResponse {
        let apiStart = Date()
        let systemMessage: [String: Any] = [
            "role": "system",
            "content": """
            You are a phone automation agent that controls an iPhone through screen vision and touch actions. \
            You accomplish tasks by executing sequences of actions, taking screenshots to see results, then deciding next steps.

            You ALWAYS use the execute_actions tool with a list of actions. Batch multiple actions into one call \
            when you know the sequence ahead of time — this is faster than one action at a time.

            OPENING AN APP (do this first for most tasks):
            [press_key HOME, press_key SPOTLIGHT, type_text "AppName", press_key ENTER, wait_seconds 1, get_screenshot "..."]
            This is the standard sequence: go home, open Spotlight search, type the app name, press enter to launch, wait, then screenshot.

            WORKFLOW:
            1. Execute a sequence of actions ending with get_screenshot to see the result
            2. Examine the annotated screenshot — elements have numbered colored bounding boxes
            3. Execute the next sequence (tap, type, scroll, etc.) ending with get_screenshot
            4. Repeat until the task is complete

            SCROLLING:
            - You can ONLY see what's currently visible. Content may extend below or above.
            - PREFER scroll_screen over swipe_screen for vertical scrolling.
            - Use swipe_screen only for horizontal scrolling (left/right).
            - If you can't find an element, scroll to reveal it, then screenshot.

            RULES:
            - Batch actions you know ahead of time into one execute_actions call
            - End your sequence with get_screenshot when you need to see the screen state
            - Write SPECIFIC detection prompts (e.g. "the send button" not just "buttons")
            - If no elements detected, try a different/broader detection prompt
            - After completing the task, briefly tell the user what you accomplished (1-2 sentences)
            - If stuck after 3 attempts, try scrolling or a different approach before asking for help
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

        print("[LLM][REQ] POST (\(conversationHistory.count) msgs), t+\(elapsed(apiStart))")

        let networkStart = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        print("[LLM][NET] Completed in \(elapsed(networkStart))")

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parse
        }

        print("[LLM][RES] \(http.statusCode), \(data.count) bytes, total t+\(elapsed(apiStart))")

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

            print("[LLM][PARSE] Tool call parsed in total t+\(elapsed(apiStart))")
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
        print("[LLM][PARSE] Text response parsed in total t+\(elapsed(apiStart))")
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
