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
                "name": "get_screenshot",
                "description": "Capture a screenshot of the phone screen and detect UI elements using vision AI. Provide a specific detection prompt describing what to look for. The screenshot will be annotated with numbered colored bounding boxes. IMPORTANT: This only shows what's currently visible on screen — if the element you need isn't visible, use swipe_screen to scroll first, then take another screenshot.",
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
                "description": "Tap on a UI element detected in the last screenshot. Use the element's numbered ID from the annotated screenshot. Always call get_screenshot first to get fresh element IDs. After tapping, use wait_seconds then get_screenshot to verify the tap registered.",
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
                "description": "Type text using the keyboard. Text is typed character by character. Make sure a text field is focused/tapped first. If the keyboard isn't visible, tap the text field first.",
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
                "description": "Scroll/swipe on the phone screen. Use this to reveal content that is off-screen. If you can't find a button, link, or element — it's probably below the fold, so swipe up to scroll down and reveal it. Use 'up' to scroll content DOWN (reveal more below), 'down' to scroll content UP (reveal more above), 'left'/'right' for horizontal scrolling (e.g. carousels, pages). You can call this multiple times to scroll further. Always take a screenshot after scrolling to see the new content.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "direction": [
                            "type": "string",
                            "enum": ["up", "down", "left", "right"],
                            "description": "Swipe direction. 'up' = scroll content downward (see more below). 'down' = scroll content upward (see more above). 'left' = scroll content rightward. 'right' = scroll content leftward."
                        ] as [String: Any]
                    ] as [String: Any],
                    "required": ["direction"]
                ] as [String: Any]
            ] as [String: Any]
        ],
        [
            "type": "function",
            "function": [
                "name": "scroll_screen",
                "description": "Scroll the screen up or down using the scroll wheel. Preferred over swipe_screen for vertical scrolling. Default amount is 5. Positive = scroll down, negative = scroll up.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "direction": [
                            "type": "string",
                            "enum": ["up", "down"],
                            "description": "'up' = scroll content upward (reveal above). 'down' = scroll content downward (reveal below)."
                        ] as [String: Any],
                        "amount": [
                            "type": "integer",
                            "description": "Scroll intensity (default 5). Higher = more scrolling."
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
                "description": "Press a special key or iOS system shortcut. Use HOME to go to home screen, SPOTLIGHT to open search (then type_text to search), APPSWITCHER to see open apps, ENTER to confirm/submit, BACKSPACE to delete text, ESC to dismiss/cancel.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "key": [
                            "type": "string",
                            "enum": ["HOME", "ENTER", "BACKSPACE", "SPOTLIGHT", "APPSWITCHER", "LOCK", "ESC", "TAB", "SPACE"],
                            "description": "HOME = go to home screen. SPOTLIGHT = open iOS search. APPSWITCHER = show app switcher. ENTER = confirm/submit. BACKSPACE = delete character. ESC = dismiss/go back. TAB = next field. SPACE = space key."
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
            You accomplish tasks by repeatedly taking screenshots with element detection, deciding what to \
            interact with, and executing actions.

            You will start off in the calling app that spawns you where the user asks a question. the first thing you need to do
            is to leave this app and go to the home screen. then complete the user's task.

            WORKFLOW:
            1. Call get_screenshot with a specific detection prompt to see the current screen
            2. Examine the annotated screenshot — elements have numbered colored bounding boxes
            3. Call tap_element with the element number, or use type_text, swipe_screen, press_key
            4. Use wait_seconds(1) after actions for animations/loading
            5. Call get_screenshot again to verify the result and see the new state
            6. Repeat until the task is complete

            SCROLLING — VERY IMPORTANT:
            - You can ONLY see what's currently visible on screen. Content may extend below or above the viewport.
            - If you can't find a button, link, or element you expect to exist, SCROLL to reveal it.
            - PREFER scroll_screen over swipe_screen for vertical scrolling — it's more reliable.
            - Use scroll_screen(direction: "down") to scroll DOWN and reveal content below the fold.
            - Use scroll_screen(direction: "up") to scroll UP and reveal content above.
            - Use swipe_screen only for horizontal scrolling (left/right).
            - After scrolling, ALWAYS take a new get_screenshot to see the newly visible content.
            - You may need to scroll multiple times to find what you're looking for.
            - Common cases: confirmation buttons at bottom of forms, items in long lists, settings deeper in a page.

            RULES:
            - Write SPECIFIC detection prompts (e.g. "the Uber app icon" not just "icons")
            - If no elements detected, try a different/broader detection prompt
            - If the element you need isn't visible, SCROLL before giving up
            - To open an app: press_key HOME → press_key SPOTLIGHT → type_text "AppName" → press_key ENTER
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
