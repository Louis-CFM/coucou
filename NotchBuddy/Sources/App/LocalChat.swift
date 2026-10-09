import Foundation

// MARK: - Typed error for local model calls

enum LocalChatError: Error {
    /// The server is not reachable (wrong URL, not running, network error).
    case serverUnreachable(String)
    /// The model was requested but is not installed on the server.
    case modelNotFound(String)
    /// The server replied with an error message.
    case serverError(String)

    var localizedDescription: String {
        switch self {
        case .serverUnreachable(let url):
            return String(format: String(localized: "error.local.server-unreachable %@"), url)
        case .modelNotFound(let model):
            return String(format: String(localized: "error.local.model-not-found %@"), model)
        case .serverError(let msg):       return msg
        }
    }
}

// MARK: - Local model helpers (Foundation only)

enum LocalChat {

    // MARK: URL normalisation

    /// Removes trailing slashes and common documentation sub-paths (/api, /v1).
    static func normaliseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        for suffix in ["/api", "/v1"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s
    }

    // MARK: SSE parsing

    /// Parses `delta.content` from one OpenAI-SSE event line.
    /// Returns nil for non-data lines, `[DONE]`, missing or null content.
    static func parseSSEDelta(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }

    // MARK: Think-block filtering

    /// Removes completed `<think>…</think>` blocks (reasoning models like DeepSeek-R1).
    static func filterThinkingBlocks(_ text: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// For streaming: removes closed think blocks AND hides content inside an
    /// open (unclosed) `<think>` block that hasn't received its closing tag yet.
    static func progressiveFilter(_ text: String) -> String {
        let cleaned = filterThinkingBlocks(text)
        if let range = cleaned.range(of: "<think>") {
            return String(cleaned[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    // MARK: Model list

    /// Fetches models, returning `.success([])` when the server responds but has no chat models,
    /// vs `.failure(.serverUnreachable)` when the server is not reachable.
    static func fetchModelsResult(baseURL: String) async -> Result<[(id: String, label: String)], LocalChatError> {
        guard let url = URL(string: "\(baseURL)/v1/models") else {
            return .failure(.serverUnreachable(baseURL))
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Bearer ollama", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["data"] as? [[String: Any]] else {
                return .failure(.serverUnreachable(baseURL))
            }
            let excluded = ["embed", "bge-", "all-minilm", "clip", "rerank"]
            let models = items.compactMap { item -> (id: String, label: String)? in
                guard let id = item["id"] as? String else { return nil }
                let lower = id.lowercased()
                guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
                return (id: id, label: id)
            }
            return .success(models)
        } catch {
            return .failure(.serverUnreachable(baseURL))
        }
    }

    /// Fetches models from a local OpenAI-compatible server (`GET /v1/models`).
    /// Filters out embedding and non-chat models (nomic-embed, bge, clip, rerank…).
    static func fetchModels(baseURL: String) async -> [(id: String, label: String)] {
        if case .success(let models) = await fetchModelsResult(baseURL: baseURL) { return models }
        return []
    }

    // MARK: Streaming chat

    /// Sends a conversation to a local OpenAI-compatible server and streams the reply.
    ///
    /// - Parameters:
    ///   - baseURL: Base URL of the server (e.g. `http://localhost:11434`).
    ///   - model: Model identifier.
    ///   - messages: OpenAI-format message array (`[{"role":…,"content":…}]`).
    ///   - onToken: Called on the **main actor** with the current visible text after
    ///     each new token. Think-block content is hidden while the block is open.
    /// - Returns: The complete final response with thinking blocks removed.
    /// - Throws: `LocalChatError`
    /// Convenience overload that accepts messages as `[[String: Any]]`.
    /// Serialises the body on the caller's actor before crossing the isolation boundary.
    static func streamChat(
        baseURL: String,
        model: String,
        messages: [[String: Any]],
        onToken: @MainActor @escaping (String) -> Void
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "max_tokens": 4096,
        ]
        let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return try await streamChat(baseURL: baseURL, encodedBody: bodyData, model: model, onToken: onToken)
    }

    static func streamChat(
        baseURL: String,
        encodedBody: Data,
        model: String,
        onToken: @MainActor @escaping (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else {
            throw LocalChatError.serverUnreachable(baseURL)
        }

        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer ollama", forHTTPHeaderField: "Authorization")
        req.httpBody = encodedBody

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: req)
        } catch {
            throw LocalChatError.serverUnreachable(baseURL)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 404 {
            throw LocalChatError.modelNotFound(model)
        }

        if status != 200 {
            var raw = ""
            do { for try await byte in bytes { raw.append(Character(UnicodeScalar(byte))); if raw.count > 4096 { break } } } catch {}
            if let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = ((json["error"] as? [String: Any])?["message"] as? String) {
                throw LocalChatError.serverError(msg)
            }
            throw LocalChatError.serverError("HTTP \(status)")
        }

        var accumulated = ""
        var lastUpdate = Date.distantPast
        let minInterval: TimeInterval = 1.0 / 15.0
        do {
            for try await line in bytes.lines {
                guard let delta = parseSSEDelta(line) else { continue }
                accumulated += delta
                let now = Date()
                if now.timeIntervalSince(lastUpdate) >= minInterval {
                    lastUpdate = now
                    let visible = progressiveFilter(accumulated)
                    await MainActor.run { onToken(visible) }
                }
            }
        } catch {
            throw LocalChatError.serverUnreachable(baseURL)
        }
        // Always send the final filtered state
        let visible = progressiveFilter(accumulated)
        await MainActor.run { onToken(visible) }

        return filterThinkingBlocks(accumulated)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
