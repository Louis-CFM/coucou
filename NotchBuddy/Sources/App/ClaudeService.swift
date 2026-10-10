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
        "google-api-key",
        "openai-api-key",
        "openrouter-api-key",
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

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"

    // MARK: - Model list

    /// Fetches available models from the Anthropic API in the order the API returns them
    /// (newest first). Returns an empty array on any error — callers fall back to a static list.
    static func fetchModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["display_name"] as? String else { return nil }
            return (id: id, label: name)
        }
    }

    /// Fetches Gemini models via the OpenAI-compatible endpoint.
    /// Strips the "models/" prefix that the API sometimes returns and filters non-chat models.
    static func fetchGoogleModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        let excluded = ["embed", "imagen", "veo", "aqa", "tts", "audio", "live"]
        return items.compactMap { item in
            guard let raw = item["id"] as? String else { return nil }
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            let lower = id.lowercased()
            guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
            return (id: id, label: id)
        }
    }

    /// Fetches chat models from the OpenAI API, sorted newest-first by creation date.
    /// Excludes non-chat model families.
    static func fetchOpenAIModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        let excluded = ["embed", "tts", "whisper", "dall-e", "audio", "realtime", "moderat",
                        "codex", "computer-use", "transcribe", "image", "sora",
                        "babbage", "davinci", "instruct"]
        return items
            .compactMap { item -> (id: String, created: Int)? in
                guard let id = item["id"] as? String else { return nil }
                let lower = id.lowercased()
                guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
                return (id: id, created: item["created"] as? Int ?? 0)
            }
            .sorted { $0.created > $1.created }
            .map { (id: $0.id, label: $0.id) }
    }

    /// Chosen in Settings; falls back to the default when the field is left empty.
    private var model: String {
        let m = AppState.shared.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? AppState.defaultClaudeModel : m
    }

    var apiKey: String? { KeychainStore.shared.get("anthropic-api-key") }

    // Multi-turn conversation messages (for API)
    private var conversationMessages: [[String: Any]] = []

    func clearConversation() {
        conversationMessages = []
    }

    /// Resolved once: NSFullUserName() is a system call, and the name cannot change under us
    /// while the app runs.
    private let systemPrompt = ClaudeService.makeSystemPrompt()

    /// Greets the user by their macOS first name when there is one worth using, and stays
    /// neutral otherwise — same wording as the Windows build.
    private nonisolated static func makeSystemPrompt() -> String {
        let opening = if let firstName = resolveUserFirstName() {
            "You are Mochi, \(firstName)'s personal AI assistant embedded in the notch of their Mac."
        } else {
            "You are Mochi, a personal AI assistant embedded in the notch of the user's Mac."
        }
        return """
        \(opening) \
        You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
        Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
        Use light Markdown when it helps: short paragraphs, bullet lists, **bold**, `inline code` and fenced code blocks. Avoid tables and big headings: the chat window is small.
        """
    }

    private let webSearchTools: [[String: Any]] = [
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 5]
    ]

    // MARK: - Chat (multi-turn, natural text + web search)

    func chat(query: String, context: PromptContext?, state: AppState) async {
        if DemoEngine.shared.isActive {
            state.stateOverride = .thinking
            await DemoEngine.shared.streamChatResponse(for: query)
            state.stateOverride = nil
            return
        }
        guard state.chatProvider == .anthropic else {
            await chatOpenAICompatible(query: query, context: context, state: state)
            return
        }
        guard let key = apiKey, !key.isEmpty else {
            await showError("API key missing. Open settings.", state: state)
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

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "tools": webSearchTools,
            "system": systemPrompt,
            "messages": conversationMessages,
        ]

        do {
            let data = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleChatResult(data, state: state)
        } catch {
            conversationMessages.removeLast()
            await showError(error.localizedDescription, state: state)
        }
    }

    // MARK: - OpenAI-compatible chat (Google Gemini / OpenAI / Ollama / LM Studio)

    func chatOpenAICompatible(query: String, context: PromptContext?, state: AppState) async {
        let provider = state.chatProvider
        guard provider != .anthropic else { return }

        let baseURL: String
        if provider == .ollama {
            baseURL = LocalChat.normaliseURL(state.ollamaServerURL)
        } else if provider == .lmstudio {
            baseURL = LocalChat.normaliseURL(state.lmstudioServerURL)
        } else {
            switch provider {
            case .google:  baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
            case .openai:  baseURL = "https://api.openai.com/v1"
            case .openrouter: baseURL = "https://openrouter.ai/api/v1"
            case .anthropic, .ollama, .lmstudio: baseURL = ""
            }
        }

        guard !baseURL.isEmpty else {
            if provider.isLocal {
                let name = provider == .ollama ? "Ollama" : "LM Studio"
                await showError("Connect \(name) in Settings → Chat first.", state: state)
            }
            return
        }
        guard let url = URL(string: "\(baseURL)/chat/completions") else { return }

        // Auth header
        let authHeader: String
        if provider.isLocal {
            authHeader = "Bearer ollama"
        } else {
            guard let key = KeychainStore.shared.get(provider.keychainKey), !key.isEmpty else {
                await showError("\(provider.displayName) API key missing. Configure it in Settings.", state: state)
                return
            }
            authHeader = "Bearer \(key)"
        }

        // Revalidate pricing before sending: a cached catalogue must never opt into billing.
        let selectedModel = state.activeChatModel
        if provider == .openrouter {
            do {
                let key = KeychainStore.shared.get(provider.keychainKey) ?? ""
                let models = try await OpenRouterChat.fetchModels(apiKey: key)
                guard models.contains(where: { $0.id == selectedModel }) else {
                    throw OpenRouterChat.Failure.unavailableModel
                }
            } catch {
                await showError(error.localizedDescription, state: state)
                return
            }
        }

        // Build messages
        var msgs: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for m in conversationMessages {
            var simplified = m
            if let content = m["content"] as? [[String: Any]],
               let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                simplified["content"] = text
            }
            msgs.append(simplified)
        }
        var userText = query
        if conversationMessages.isEmpty, let ctx = context {
            switch ctx {
            case .window(let app, let title, let url):
                var prefix = "Context — App: \(app), Window: \(title)"
                if let u = url { prefix += ", URL: \(u)" }
                userText = prefix + "\n\n" + query
            case .file(let name, let fileURL):
                if provider.isLocal, let fileURL = fileURL {
                    let ext = fileURL.pathExtension.lowercased()
                    let binaryExts = ["pdf", "jpg", "jpeg", "png", "gif", "webp"]
                    if !binaryExts.contains(ext),
                       let text = try? String(contentsOf: fileURL, encoding: .utf8), !text.isEmpty {
                        let truncated = text.count > 24_000
                            ? String(text.prefix(24_000)) + "\n[truncated]"
                            : text
                        userText = "File: \(name)\n\n\(truncated)\n\n" + query
                    } else {
                        userText = "File: \(name)\n\n" + query
                    }
                } else {
                    userText = "File: \(name)\n\n" + query
                }
            }
        }
        msgs.append(["role": "user", "content": userText])
        conversationMessages.append(["role": "user", "content": userText])

        let useStream = provider.isLocal
        var body: [String: Any] = [
            "model": selectedModel,
            "max_tokens": 4096,
            "messages": msgs,
        ]
        if useStream { body["stream"] = true }
        if provider == .openrouter {
            body["provider"] = OpenRouterChat.freeProviderPreferences
        }

        var req = URLRequest(url: url, timeoutInterval: (useStream || provider == .openrouter) ? 120 : 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if useStream {
            // Add placeholder (hidden until first token via ChatBubble empty-content guard)
            let placeholder = ChatMessage(role: .assistant, content: "")
            let msgId = placeholder.id
            state.chatHistory.append(placeholder)
            state.stateOverride = .thinking
            let modelCopy = state.activeChatModel
            let streamBody: [String: Any] = [
                "model": modelCopy,
                "messages": msgs,
                "stream": true,
                "max_tokens": 4096,
            ]
            let encodedBody = (try? JSONSerialization.data(withJSONObject: streamBody)) ?? Data()
            do {
                let final = try await LocalChat.streamChat(
                    baseURL: baseURL,
                    encodedBody: encodedBody,
                    model: modelCopy
                ) { [state, msgId] visible in
                    if !visible.isEmpty, state.stateOverride == .thinking {
                        state.stateOverride = nil   // hide typing dots on first visible text
                    }
                    if let idx = state.chatHistory.firstIndex(where: { $0.id == msgId }) {
                        state.chatHistory[idx].content = visible
                    }
                }
                conversationMessages.append(["role": "assistant", "content": final])
                if let idx = state.chatHistory.firstIndex(where: { $0.id == msgId }) {
                    state.chatHistory[idx].content = final
                }
                state.stateOverride = nil
                state.view = .prompt
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch let e as LocalChatError {
                conversationMessages.removeLast()
                state.chatHistory.removeAll { $0.id == msgId }
                state.stateOverride = nil
                let msg: String
                switch e {
                case .serverUnreachable:
                    msg = provider == .ollama
                        ? "Ollama isn't running. Open it, then ask again."
                        : "Start the local server in LM Studio, then ask again."
                case .modelNotFound(let m):
                    msg = "\(m) isn't installed. Pick another model above the chat box."
                case .serverError(let s):
                    msg = s
                }
                await showError(msg, state: state)
            } catch {
                conversationMessages.removeLast()
                state.chatHistory.removeAll { $0.id == msgId }
                state.stateOverride = nil
                await showError(error.localizedDescription, state: state)
            }
        } else {
            // Non-streaming (Google, OpenAI, OpenRouter)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    if status == 404 { state.fetchedProviderModels[provider] = nil }
                    throw ChatAPIError(status: status, provider: provider.displayName,
                                       model: selectedModel, data: data)
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unexpected response format"])
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                conversationMessages.append(["role": "assistant", "content": trimmed])
                state.chatHistory.append(ChatMessage(role: .assistant, content: trimmed))
                state.stateOverride = nil
                state.view = .prompt
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch {
                conversationMessages.removeLast()
                await showError(error.localizedDescription, state: state)
            }
        }
    }

    // MARK: - Structured search (M8 — window attach + web search)

    func search(query: String, context: PromptContext?, state: AppState) async {
        guard let key = apiKey, !key.isEmpty else {
            await showError("Anthropic API key missing. Open settings to configure it.", state: state)
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

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": tools,
            "system": system,
            "messages": [["role": "user", "content": userContent]],
        ]

        do {
            let result = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleResult(result, state: state)
        } catch {
            await showError(error.localizedDescription, state: state)
        }
    }

    // MARK: - API call

    private func callAPI(body: [String: Any], key: String, beta: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 404 { AppState.shared.fetchedProviderModels[.anthropic] = nil }
            throw ChatAPIError(status: status, provider: "Anthropic",
                               model: body["model"] as? String ?? "unknown", data: data)
        }
        return data
    }

    // MARK: - Chat result handler

    private func handleChatResult(_ data: Data, state: AppState) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            await showError("Unexpected API response.", state: state)
            return
        }

        // Store full content (includes tool_use/tool_result blocks) for correct multi-turn context
        conversationMessages.append(["role": "assistant", "content": content])

        guard let text = claudeResponseText(fromContent: content) else {
            await showError("No response text.", state: state)
            return
        }

        // Add to display history
        state.chatHistory.append(ChatMessage(role: .assistant, content: text))

        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: - Structured result handler

    private func handleResult(_ data: Data, state: AppState) async {
        // Extract text from Anthropic response (may contain tool_use / web_search_tool_result blocks)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = claudeResponseText(fromContent: content) else {
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
