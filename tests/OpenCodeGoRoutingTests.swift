import Foundation

@main
enum OpenCodeGoRoutingTests {
    static func main() {
        var assertions = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            assertions += 1
        }

        // Stable contract values: Keychain account, preference key, default model.
        check(OpenCodeGo.apiKeyKey == "opencode-go-api-key", "Keychain account name")
        check(OpenCodeGo.modelPreferenceKey == "opencodeGoModel", "Model preference key")
        check(OpenCodeGo.defaultModel == "kimi-k3", "Default model")

        // Routing mirrors the official model/endpoint table.
        for id in ["minimax-m2.5", "minimax-m3", "qwen3-coder", "qwen3.5-plus"] {
            check(OpenCodeGo.endpoint(forModel: id) == .messages, "\(id) uses /messages")
        }
        for id in ["grok-code-fast-1", "gpt-5.1-codex", "muse-1"] {
            check(OpenCodeGo.endpoint(forModel: id) == .responses, "\(id) uses /responses")
        }
        for id in ["kimi-k3", "glm-5", "deepseek-v4", "unknown-model"] {
            check(OpenCodeGo.endpoint(forModel: id) == .chatCompletions, "\(id) uses /chat/completions")
        }
        check(OpenCodeGo.endpoint(forModel: " MiniMax-M3 ") == .messages, "Routing ignores case and spaces")
        check(OpenCodeGo.url(for: .messages).absoluteString == "https://opencode.ai/zen/go/v1/messages",
              "Messages URL")
        check(OpenCodeGo.url(for: .chatCompletions).absoluteString
              == "https://opencode.ai/zen/go/v1/chat/completions", "Chat completions URL")
        check(OpenCodeGo.url(for: .responses).absoluteString == "https://opencode.ai/zen/go/v1/responses",
              "Responses URL")
        check(OpenCodeGo.modelsURL.absoluteString == "https://opencode.ai/zen/go/v1/models", "Models URL")

        // Required headers: session ID and a custom user agent; auth sent in both forms.
        let headers = OpenCodeGo.headers(endpoint: .messages, key: "k", sessionID: "s-1", appVersion: "0.3.0")
        check(headers["authorization"] == "Bearer k" && headers["x-api-key"] == "k", "Auth headers")
        check(headers["x-opencode-session"] == "s-1", "Session header")
        check(headers["user-agent"] == "coucou/0.3.0", "User agent")
        check(headers["anthropic-version"] == "2023-06-01", "Messages endpoint sends anthropic-version")
        let chatHeaders = OpenCodeGo.headers(endpoint: .chatCompletions, key: "k", sessionID: "s", appVersion: "1")
        check(chatHeaders["anthropic-version"] == nil, "Chat completions does not send anthropic-version")

        // History mixes Anthropic blocks and plain strings (upstream keeps both shapes).
        let conversation: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "Context"], ["type": "text", "text": "Hi"]]],
            ["role": "assistant", "content": [["type": "server_tool_use", "name": "web_search"],
                                              ["type": "text", "text": "Hello"]]],
            ["role": "user", "content": "Plain"],
        ]
        let flattened = OpenCodeGo.textOnlyMessages(conversation)
        check(flattened == [["role": "user", "content": "Context\n\nHi"],
                            ["role": "assistant", "content": "Hello"],
                            ["role": "user", "content": "Plain"]],
              "Text blocks flatten per message; tool blocks are skipped")
        let withImage: [[String: Any]] = [
            ["role": "user", "content": [["type": "image", "source": ["type": "base64"]],
                                         ["type": "text", "text": "Look"]]],
        ]
        check(OpenCodeGo.textOnlyMessages(withImage) == nil, "Images are rejected, never dropped")
        let withDoc: [[String: Any]] = [["role": "user", "content": [["type": "document"]]]]
        check(OpenCodeGo.textOnlyMessages(withDoc) == nil, "Documents are rejected, never dropped")
        let toolOnly: [[String: Any]] = [["role": "assistant", "content": [["type": "server_tool_use"]]]]
        check(OpenCodeGo.textOnlyMessages(toolOnly) == [], "Messages left empty are dropped")

        let msgs = flattened ?? []
        let chatBody = OpenCodeGo.body(endpoint: .chatCompletions, model: "kimi-k3", system: "Be brief",
                                       messages: msgs, maxTokens: 4096)
        check(chatBody["model"] as? String == "kimi-k3", "Body model")
        check(chatBody["max_tokens"] as? Int == 4096, "Body max tokens")
        check(chatBody["tools"] == nil && chatBody["system"] == nil, "No tools or top-level system")
        let sent = chatBody["messages"] as? [[String: String]] ?? []
        check(sent.first == ["role": "system", "content": "Be brief"], "System prompt is the first message")
        check(Array(sent.dropFirst()) == msgs, "Conversation follows the system message")

        let messagesBody = OpenCodeGo.body(endpoint: .messages, model: "minimax-m3", system: "Be brief",
                                           messages: msgs, maxTokens: 4096)
        check(messagesBody["system"] as? String == "Be brief", "Messages body uses top-level system")
        check(messagesBody["messages"] as? [[String: String]] == msgs, "Messages body has no system turn")

        // Response parsing per endpoint.
        let ok = Data(#"{"choices":[{"message":{"role":"assistant","content":" Bonjour "}}]}"#.utf8)
        check(OpenCodeGo.responseText(from: ok, endpoint: .chatCompletions) == " Bonjour ",
              "Parse choices[0].message.content")
        let anth = Data(#"{"content":[{"type":"thinking","thinking":"x"},{"type":"text","text":"A"},{"type":"text","text":"B"}]}"#.utf8)
        check(OpenCodeGo.responseText(from: anth, endpoint: .messages) == "AB", "Parse Anthropic text blocks")
        for bad in [#"{"choices":[]}"#, #"{"choices":[{"message":{"content":null}}]}"#, "not json", #"{"error":{}}"#] {
            check(OpenCodeGo.responseText(from: Data(bad.utf8), endpoint: .chatCompletions) == nil,
                  "Malformed response is rejected")
        }
        check(OpenCodeGo.responseText(from: Data(#"{"content":[]}"#.utf8), endpoint: .messages) == nil,
              "Empty Anthropic content is rejected")

        let err = Data(#"{"error":{"message":"Invalid API key","type":"auth"}}"#.utf8)
        check(OpenCodeGo.errorMessage(from: err) == "Invalid API key", "OpenAI error message is surfaced")
        let anthropicErr = Data(#"{"type":"error","error":{"type":"x","message":"Overloaded"}}"#.utf8)
        check(OpenCodeGo.errorMessage(from: anthropicErr) == "Overloaded", "Anthropic error message is surfaced")
        check(OpenCodeGo.errorMessage(from: Data("oops".utf8)) == nil, "Unknown errors have no message")

        // Model catalog: Responses-API models are hidden (no transport yet), sorted by ID.
        let catalog = Data(#"{"data":[{"id":"kimi-k3"},{"id":"gpt-5.1-codex"},{"id":"glm-5"},{"id":"minimax-m3"}]}"#.utf8)
        check(OpenCodeGo.chatModels(from: catalog).map(\.id) == ["glm-5", "kimi-k3", "minimax-m3"],
              "Model list hides Responses models")
        check(OpenCodeGo.chatModels(from: Data("x".utf8)).isEmpty, "Bad catalog yields no models")

        print("OpenCode Go routing: \(assertions) assertions passed")
    }
}
