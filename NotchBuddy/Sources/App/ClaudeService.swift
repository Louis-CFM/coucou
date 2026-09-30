import Foundation
import Security

// MARK: - Keychain helpers

enum Keychain {
    static let service = "fr.louisraille.NotchBuddy"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete existing item first (update pattern)
        let lookup: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(lookup as CFDictionary)
        // Add with strictest access control:
        // WhenUnlockedThisDeviceOnly = accessible only while Mac is unlocked,
        // never synced to iCloud, never migrated to another device.
        let item: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain cache (reads each key ONCE at launch; all subsequent access via dict)

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let allKeys = [
        "anthropic-api-key",
        "custom-api-key",
        "resend-api-key", "resend-from",
        "n8n-url", "n8n-api-key",
        "vercel-token",
        "github-token",
        "stripe-api-key",
        "calcom-api-key",
        "notion-api-key",
    ]

    private init() {
        // Called once, on main thread (AppDelegate triggers shared at launch).
        for key in Self.allKeys {
            if let v = Keychain.load(key: key) { cache[key] = v }
        }
    }

    /// Thread-safe read — never touches the Keychain.
    func get(_ key: String) -> String? {
        lock.withLock { cache[key] }
    }

    /// Updates cache + persists to Keychain.
    func set(_ key: String, value: String) {
        lock.withLock { cache[key] = value }
        Keychain.save(key: key, value: value)
    }

    /// Removes from cache + Keychain only if the key was previously set.
    func remove(_ key: String) {
        let had = lock.withLock { () -> Bool in
            let exists = cache[key] != nil
            cache[key] = nil
            return exists
        }
        if had { Keychain.delete(key: key) }
    }
}

// MARK: - Claude API

@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let anthropicVersion = "2023-06-01"
    private let officialModel = "claude-sonnet-4-6"

    // MARK: Provider configuration (UserDefaults, edited in Settings)

    /// Custom mode = any endpoint the user configured; otherwise the official API.
    var isCustom: Bool { UserDefaults.standard.string(forKey: "providerMode") == "custom" }

    private var customBase: String {
        (UserDefaults.standard.string(forKey: "customBaseUrl") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// true = OpenAI Chat Completions dialect, false = Anthropic Messages.
    private var customOpenAI: Bool {
        UserDefaults.standard.string(forKey: "customApiStyle") == "openai"
    }

    /// Web search is an Anthropic server-side tool — official API only.
    private var webSearchEnabled: Bool { !isCustom }

    private var activeModel: String {
        guard isCustom else { return officialModel }
        let m = (UserDefaults.standard.string(forKey: "customModel") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? officialModel : m
    }

    /// The official API requires a key; local gateways often need none.
    var activeKey: String? {
        isCustom ? KeychainStore.shared.get("custom-api-key")
                 : KeychainStore.shared.get("anthropic-api-key")
    }

    private var endpoint: URL {
        guard isCustom else {
            return URL(string: "https://api.anthropic.com/v1/messages")!
        }
        return Self.customEndpoint(from: customBase, openai: customOpenAI)
    }

    /// Root or "/v1" base → full endpoint; a complete path is used as-is.
    static func customEndpoint(from base: String, openai: Bool) -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        let full: String
        if openai {
            full = b.hasSuffix("/chat/completions") ? b
                 : b.hasSuffix("/v1") ? b + "/chat/completions"
                 : b + "/v1/chat/completions"
        } else {
            full = b.hasSuffix("/messages") ? b
                 : b.hasSuffix("/v1") ? b + "/messages"
                 : b + "/v1/messages"
        }
        // chat()/search() call providerError() first, so base is never empty here.
        return URL(string: full) ?? URL(string: "https://api.anthropic.com/v1/messages")!
    }

    /// Non-nil when the provider cannot be called; nil when ready.
    func providerError() -> String? {
        if isCustom {
            if customBase.isEmpty { return "Custom base URL missing. Open settings." }
        } else {
            let key = KeychainStore.shared.get("anthropic-api-key") ?? ""
            if key.isEmpty { return "API key missing. Open settings." }
        }
        return nil
    }

    // Multi-turn conversation messages (for API)
    private var conversationMessages: [[String: Any]] = []

    func clearConversation() {
        conversationMessages = []
    }

    private let systemPromptSearch = """
    You are Mochi, Louis's personal AI assistant embedded in the notch of his Mac. \
    You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
    Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
    No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.
    """

    private let systemPromptPlain = """
    You are Mochi, Louis's personal AI assistant embedded in the notch of his Mac. \
    You can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
    Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
    No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.
    """

    private let webSearchTools: [[String: Any]] = [
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 5]
    ]

    // MARK: - Chat (multi-turn, natural text + web search)

    func chat(query: String, context: PromptContext?, state: AppState) async {
        if let err = providerError() {
            await showError(err, state: state)
            return
        }

        // Build user content for this turn
        var userContent: [[String: Any]] = []

        // Add file/window context on first message only
        if conversationMessages.isEmpty, let context = context {
            switch context {
            case .window(let app, let title, let url):
                var text = "Context — App: \(app), Window: \(title)"
                if let url = url { text += ", URL: \(url)" }
                userContent.append(["type": "text", "text": text])
            case .file(let name, let fileURL):
                if let fileURL = fileURL, let block = readFileAsBlock(url: fileURL) {
                    userContent.append(block)
                }
                userContent.append(["type": "text", "text": "File: \(name)"])
            }
        }
        userContent.append(["type": "text", "text": query])

        conversationMessages.append(["role": "user", "content": userContent])

        let body: [String: Any]
        if isCustom && customOpenAI {
            body = [
                "model": activeModel,
                "max_tokens": 4096,
                "messages": openaiMessages(from: conversationMessages, system: systemPromptPlain),
            ]
        } else {
            var b: [String: Any] = [
                "model": activeModel,
                "max_tokens": 4096,
                "system": webSearchEnabled ? systemPromptSearch : systemPromptPlain,
                "messages": conversationMessages,
            ]
            if webSearchEnabled { b["tools"] = webSearchTools }
            body = b
        }

        do {
            let data = try await callAPI(
                body: body,
                key: activeKey,
                beta: webSearchEnabled ? "web-search-2025-03-05" : nil
            )
            await handleChatResult(data, state: state)
        } catch {
            conversationMessages.removeLast()
            await showError("Network error: \(error.localizedDescription)", state: state)
        }
    }

    // MARK: - Structured search (M8 — window attach + web search)

    func search(query: String, context: PromptContext?, state: AppState) async {
        if let err = providerError() {
            await showError(err, state: state)
            return
        }

        var userContent: [[String: Any]] = []
        switch context {
        case .window(let appName, let title, let url):
            var text = "App: \(appName)\nWindow title: \(title)"
            if let url = url { text += "\nURL: \(url)" }
            text += "\n\nRequest: \(query)"
            userContent.append(["type": "text", "text": text])
        case .file(let name, let fileURL):
            if let fileURL = fileURL, let fileBlock = readFileAsBlock(url: fileURL) {
                userContent.append(fileBlock)
            }
            userContent.append(["type": "text", "text": "File: \(name)\n\nRequest: \(query)"])
        case nil:
            userContent.append(["type": "text", "text": query])
        }

        let system = """
        You are an assistant built into the notch of a Mac. Reply in English, short and precise.
        Reply ONLY with valid JSON in this exact format:
        {"title":"...","items":[{"label":"...","detail":"...","url":"..."}],"note":"..."}
        Maximum 3 items. "url" is optional. "note" is optional.
        """

        let tools: [[String: Any]] = [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
        ]

        let body: [String: Any]
        if isCustom && customOpenAI {
            body = [
                "model": activeModel,
                "max_tokens": 1024,
                "messages": openaiMessages(
                    from: [["role": "user", "content": userContent]],
                    system: system
                ),
            ]
        } else {
            var b: [String: Any] = [
                "model": activeModel,
                "max_tokens": 1024,
                "system": system,
                "messages": [["role": "user", "content": userContent]],
            ]
            if webSearchEnabled { b["tools"] = tools }
            body = b
        }

        do {
            let result = try await callAPI(
                body: body,
                key: activeKey,
                beta: webSearchEnabled ? "web-search-2025-03-05" : nil
            )
            await handleResult(result, state: state)
        } catch {
            await showError("Network error: \(error.localizedDescription)", state: state)
        }
    }

    // MARK: - API call

    private func callAPI(body: [String: Any], key: String?, beta: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if isCustom && customOpenAI {
            // OpenAI dialect: one Bearer header, and only when a key exists —
            // local gateways often authenticate nothing.
            if let key, !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        } else {
            if let key, !key.isEmpty {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
            }
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
            if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    // MARK: - Chat result handler

    private func handleChatResult(_ data: Data, state: AppState) async {
        if isCustom && customOpenAI {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let raw = message["content"] as? String else {
                await showError("Unexpected API response.", state: state)
                return
            }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Stored Anthropic-shaped so a later style switch keeps working.
            conversationMessages.append(["role": "assistant", "content": [["type": "text", "text": text]]])
            guard !text.isEmpty else {
                await showError("No response text.", state: state)
                return
            }
            state.chatHistory.append(ChatMessage(role: .assistant, content: text))
            state.stateOverride = nil
            state.view = .prompt
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            await showError("Unexpected API response.", state: state)
            return
        }

        // Store full content (includes tool_use/tool_result blocks) for correct multi-turn context
        conversationMessages.append(["role": "assistant", "content": content])

        guard let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String, !text.isEmpty else {
            await showError("No response text.", state: state)
            return
        }

        // Add to display history
        state.chatHistory.append(ChatMessage(role: .assistant, content: text.trimmingCharacters(in: .whitespacesAndNewlines)))

        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: - Structured result handler

    private func handleResult(_ data: Data, state: AppState) async {
        // Text from either dialect (the Anthropic one may carry tool blocks).
        guard let text = responseText(from: data) else {
            await showError("Unexpected API response.", state: state)
            return
        }

        // Strip markdown code fences if present, then extract JSON object
        let cleanText: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleanText = String(text[start...end])
        } else {
            cleanText = text
        }

        // Try to parse as our JSON format
        if let resultData = cleanText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            let title  = parsed["title"] as? String ?? "Result"
            let note   = parsed["note"] as? String
            var items: [ResultItem] = []
            if let rawItems = parsed["items"] as? [[String: Any]] {
                for item in rawItems.prefix(3) {
                    items.append(ResultItem(
                        label:  item["label"]  as? String ?? "",
                        detail: item["detail"] as? String ?? "",
                        url:    item["url"]    as? String
                    ))
                }
            }
            state.searchResult = SearchResult(title: title, items: items, note: note)
        } else {
            // Fallback: show raw text in 3-line chunks
            let lines = cleanText.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(3)
            state.searchResult = SearchResult(
                title: "Claude's response",
                items: lines.map { ResultItem(label: $0, detail: "", url: nil) },
                note: nil
            )
        }

        state.stateOverride = nil
        state.view = .result
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
    }

    // MARK: - Dialect helpers

    /// The stored Anthropic-shaped history → OpenAI Chat Completions messages.
    /// Images become data URIs; PDF blocks are skipped (no portable equivalent).
    private func openaiMessages(from messages: [[String: Any]], system: String) -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            let role = m["role"] as? String ?? "user"
            if let text = m["content"] as? String {
                out.append(["role": role, "content": text])
                continue
            }
            guard let blocks = m["content"] as? [[String: Any]] else { continue }
            if role == "assistant" {
                let text = blocks
                    .filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }
                    .joined(separator: "\n")
                out.append(["role": role, "content": text])
            } else {
                var parts: [[String: Any]] = []
                for b in blocks {
                    switch b["type"] as? String {
                    case .some("text"):
                        if let t = b["text"] as? String {
                            parts.append(["type": "text", "text": t])
                        }
                    case .some("image"):
                        if let src = b["source"] as? [String: Any],
                           let media = src["media_type"] as? String,
                           let data = src["data"] as? String {
                            parts.append(["type": "image_url",
                                          "image_url": ["url": "data:\(media);base64,\(data)"]])
                        }
                    default:
                        break // PDFs have no portable OpenAI-shaped equivalent
                    }
                }
                if !parts.isEmpty {
                    out.append(["role": role, "content": parts])
                }
            }
        }
        return out
    }

    /// Plain response text from either dialect.
    private func responseText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if isCustom && customOpenAI {
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else { return nil }
            return content
        }
        guard let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String else { return nil }
        return text
    }

    private func showError(_ message: String, state: AppState) async {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }

    // MARK: - File content block builder

    private func readFileAsBlock(url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let base64 = data.base64EncodedString()

        if ext == "pdf" {
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": base64]]
        } else if ["jpg", "jpeg"].contains(ext) {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]
        } else if ext == "png" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]]
        } else if ext == "gif" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/gif", "data": base64]]
        } else if ext == "webp" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/webp", "data": base64]]
        } else {
            // Text/code — inline as text if <= 200 KB
            guard data.count <= 200_000,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return ["type": "text", "text": "File contents:\n\(text)"]
        }
    }
}
