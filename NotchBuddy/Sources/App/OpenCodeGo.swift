import Foundation

// MARK: - OpenCode Go transport helpers (pure, no network)

/// The three API shapes OpenCode Go exposes, chosen per model family.
enum OpenCodeGoEndpoint: Equatable, Sendable {
    case messages, chatCompletions, responses
}

enum OpenCodeGo {
    /// Keychain account; must match `ChatProvider.opencodeGo.keychainKey`.
    static let apiKeyKey = "opencode-go-api-key"
    /// UserDefaults key for the selected Go model.
    static let modelPreferenceKey = "opencodeGoModel"
    /// Must match `ChatProvider.opencodeGo.defaultModel`.
    static let defaultModel = "kimi-k3"

    private static let baseURL = URL(string: "https://opencode.ai/zen/go/v1")!
    static let modelsURL = baseURL.appendingPathComponent("models")

    // ponytail: prefix table mirrors https://opencode.ai/docs/go/ by hand; the model catalog
    // carries no endpoint metadata, so new model families need this table updated.
    static func endpoint(forModel modelID: String) -> OpenCodeGoEndpoint {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.hasPrefix("minimax-") || id.hasPrefix("qwen") { return .messages }
        if id.hasPrefix("grok-") || id.hasPrefix("gpt-") || id.hasPrefix("muse-") { return .responses }
        return .chatCompletions
    }

    static func url(for endpoint: OpenCodeGoEndpoint) -> URL {
        switch endpoint {
        case .messages:        return baseURL.appendingPathComponent("messages")
        case .chatCompletions: return baseURL.appendingPathComponent("chat/completions")
        case .responses:       return baseURL.appendingPathComponent("responses")
        }
    }

    /// Go routes by session and rejects requests without one; its docs also ask for a custom
    /// user agent. The docs do not pin one auth header per endpoint, so both forms are sent.
    static func headers(endpoint: OpenCodeGoEndpoint, key: String,
                        sessionID: String, appVersion: String) -> [String: String] {
        var headers = [
            "authorization": "Bearer \(key)",
            "x-api-key": key,
            "content-type": "application/json",
            "x-opencode-session": sessionID,
            "user-agent": "coucou/\(appVersion)",
        ]
        if endpoint == .messages { headers["anthropic-version"] = "2023-06-01" }
        return headers
    }

    /// History flattened to plain text turns. The chat history mixes Anthropic block arrays and
    /// plain strings; tool blocks (web search) are skipped, but images and documents make it
    /// return nil so callers fail explicitly instead of silently dropping an attachment.
    static func textOnlyMessages(_ conversation: [[String: Any]]) -> [[String: String]]? {
        var result: [[String: String]] = []
        for message in conversation {
            guard let role = message["role"] as? String else { return nil }
            if let text = message["content"] as? String {
                if !text.isEmpty { result.append(["role": role, "content": text]) }
                continue
            }
            guard let blocks = message["content"] as? [[String: Any]] else { return nil }
            var texts: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String { texts.append(text) }
                case "image", "document":
                    return nil
                default:
                    continue  // server_tool_use, web_search_tool_result, …
                }
            }
            if !texts.isEmpty { result.append(["role": role, "content": texts.joined(separator: "\n\n")]) }
        }
        return result
    }

    static func body(endpoint: OpenCodeGoEndpoint, model: String, system: String,
                     messages: [[String: String]], maxTokens: Int) -> [String: Any] {
        if endpoint == .messages {
            return ["model": model, "max_tokens": maxTokens, "system": system, "messages": messages]
        }
        return [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "system", "content": system]] + messages,
        ]
    }

    /// Assistant text from a `/chat/completions` or `/messages` response; nil when malformed.
    static func responseText(from data: Data, endpoint: OpenCodeGoEndpoint) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if endpoint == .messages {
            guard let blocks = json["content"] as? [[String: Any]] else { return nil }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined()
            return text.isEmpty ? nil : text
        }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else { return nil }
        return text
    }

    /// Error text from either an OpenAI-style or Anthropic-style error body.
    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }

    /// Chat-capable models from the `/models` catalog. Responses-API models are hidden
    /// because that transport is not implemented yet.
    static func chatModels(from data: Data) -> [(id: String, label: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }
            .filter { endpoint(forModel: $0) != .responses }
            .sorted()
            .map { (id: $0, label: $0) }
    }
}
