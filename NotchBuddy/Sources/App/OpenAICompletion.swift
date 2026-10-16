import Foundation

// MARK: - OpenAICompletion
//
// One question, one answer, from an OpenAI-compatible chat provider: the request
// and the reading of the reply, without the network. OneShotAI sends it.

enum OpenAICompletion {

    /// `…/chat/completions` under a provider's base URL. A cloud base already ends
    /// with its version (`https://api.openai.com/v1`); a local server's address does
    /// not (`http://127.0.0.1:11434`), so `/v1` is added.
    static func url(base: String, local: Bool) -> URL? {
        var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        return URL(string: base + (local ? "/v1/chat/completions" : "/chat/completions"))
    }

    /// A POST with the system and user messages. `key` nil: no Authorization header
    /// (the local servers ask for none).
    static func request(url: URL, key: String?, model: String, system: String, user: String,
                        timeout: TimeInterval, temperature: Double? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if let temperature { body["temperature"] = temperature }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The answer's text, reasoning (`<think>…</think>`) left out. nil when the reply
    /// is not a chat completion or holds no text.
    static func text(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let text = LocalChat.filterThinkingBlocks(content)
        return text.isEmpty ? nil : text
    }
}
