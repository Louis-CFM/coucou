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
        "deepseek-api-key",
        "qwen-api-key",
        "moonshot-api-key",
        "resend-api-key", "resend-from",
        "n8n-url", "n8n-api-key",
        "vercel-token",
        "github-token",
        "stripe-api-key",
        "calcom-api-key",
        "notion-api-key",
        "hermes-agent-keys",
        "hermes-agent-sessions",
        "elevenlabs-api-key",
        // WhatsApp (local gateway): its address, credentials and the webhook's signing secret
        "whatsapp-url", "whatsapp-api-key", "whatsapp-webhook-secret",
        // Portfolio exchange credentials
        "portfolio-binance-key",  "portfolio-binance-secret",
        "portfolio-okx-key",      "portfolio-okx-secret",      "portfolio-okx-passphrase",
        "portfolio-bybit-key",    "portfolio-bybit-secret",
        "portfolio-kraken-key",   "portfolio-kraken-secret",
        "portfolio-coinbase-key", "portfolio-coinbase-secret",  "portfolio-coinbase-passphrase",
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

    /// Fetches models from any OpenAI-compatible `/v1/models` endpoint.
    static func fetchOpenAICompatibleModels(baseURL: String, apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "\(baseURL)/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return (id: id, label: id)
        }
    }

    /// Chosen in Settings; falls back to the default when the field is left empty.
    private var model: String {
        let m = AppState.shared.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? AppState.defaultClaudeModel : m
    }

    var apiKey: String? { KeychainStore.shared.get("anthropic-api-key") }

    /// A local provider (Ollama, LM Studio) is streaming an answer into the shared chat. Display only: it tells the
    /// chat that the last text is still arriving. The writes that end it also write the message, which redraws.
    private(set) var sharedChatStreaming = false

    /// Hermes turns in flight, by id. A second message may start while the first still runs.
    private struct HermesTurn {
        var task: Task<String, Error>?
        var hasText = false
    }

    /// What the service keeps per conversation (see `ConversationID`): the messages sent to the server, the turns in
    /// flight and, for a signed-in Hermes agent, the stored server session. Memory only.
    private struct Conversation {
        var messages: [[String: Any]] = []
        var turns: [UUID: HermesTurn] = [:]
        var serverSession: String?
    }
    private var conversations = ConversationStore<Conversation>(empty: Conversation())
    /// A request that started before a clear or a drop must not touch the new conversation: it carries the
    /// generation it started under. Only `ensureConversation` and `clearConversation` create one.
    private var generations = ConversationGenerations()

    /// The conversation still has the generation the request started under (a cleared or dropped one does not).
    private func isCurrent(_ id: ConversationID, generation: Int) -> Bool {
        generations.isCurrent(id, generation)
    }

    /// Creates the conversation if it has none yet and returns its generation.
    @discardableResult
    private func ensureConversation(_ id: ConversationID) -> Int {
        let generation = generations.ensure(id)
        if !conversations.contains(id) { conversations.set(id, Conversation()) }
        return generation
    }

    /// Messages of the conversation shared by the non Hermes providers.
    private var conversationMessages: [[String: Any]] {
        get { conversations[.shared].messages }
        set { ensureConversation(.shared); conversations.mutate(.shared) { $0.messages = newValue } }
    }

    /// Empties one conversation (messages, server session) and cancels its running turns. The others are untouched.
    func clearConversation(_ id: ConversationID) {
        for turn in conversations[id].turns.values { turn.task?.cancel() }
        generations.renew(id)
        conversations.set(id, Conversation())
        #if !APPSTORE
        if id == .shared { relayHistory = [] }
        #endif
        ChatMediaStore.shared.forgetConversation(id.mediaKey)
    }

    /// Forgets one conversation for good (its agent was removed) and cancels its running turns.
    func dropConversation(_ id: ConversationID) {
        for turn in conversations[id].turns.values { turn.task?.cancel() }
        generations.drop(id)
        conversations.remove(id)
        ChatMediaStore.shared.forgetConversation(id.mediaKey)
    }

    /// A turn of this conversation has not produced its first text yet.
    func isWaiting(_ id: ConversationID) -> Bool {
        conversations[id].turns.values.contains { !$0.hasText }
    }

    /// A turn of any Hermes conversation has not produced its first text yet.
    var anyHermesWaiting: Bool {
        conversations.values.contains { $0.turns.values.contains { !$0.hasText } }
    }

    /// The typing dots show while a running turn has not produced text yet. Every override this code sets (dots, or
    /// the error left by a failed sibling turn) is dropped by the rule in `HermesAnnounce.typingOverride`.
    private func refreshHermesTyping(_ state: AppState) {
        let current: HermesAnnounce.Override
        switch state.stateOverride {
        case nil: current = .none
        case .some(.thinking): current = .thinking
        case .some(.error): current = .error
        default: current = .other
        }
        let next = HermesAnnounce.typingOverride(current: current, anyTurnWaiting: conversations.values.contains { $0.turns.values.contains { !$0.hasText } })
        guard next != current else { return }
        switch next {
        case .none: state.stateOverride = nil
        case .thinking: state.stateOverride = .thinking
        case .error, .other: break
        }
    }

    /// Whether the chat can answer with Claude: an API key, or else Claude Code (GitHub build).
    var canAnswer: Bool {
        #if APPSTORE
        return !(apiKey ?? "").isEmpty
        #else
        return !(apiKey ?? "").isEmpty || CLILocator.shared.isInstalled(.claude)
        #endif
    }

    #if !APPSTORE
    // MARK: - Chat through the user's subscription (CLIRelay.swift)

    /// The relay's turns, as plain text: they never mix with the API's content blocks.
    private var relayHistory: [(user: String, assistant: String)] = []

    private func chatThroughSubscription(_ provider: ChatProvider, query: String, context: PromptContext?, state: AppState) async {
        guard let cli = provider.installedCLI else {
            let tool = provider.subscriptionCLIs.first?.displayName ?? provider.displayName
            await showError(String(format: String(localized: "chat.subscriptions.error.missing"), tool), state: state)
            return
        }
        var contextLine: String?
        // What later turns see of this one: never a file's contents, which go out with
        // the web search of the turns after it otherwise.
        var historyContext: String?
        var readDir: URL?
        if relayHistory.isEmpty, let context {
            switch context {
            case .window(let app, let title, let url):
                var text = "Context — App: \(app), Window: \(title)"
                if let url { text += ", URL: \(url)" }
                contextLine = text
                historyContext = text
            case .file(let name, let fileURL):
                historyContext = "File: \(name)"
                if cli == .claude, let fileURL, let dir = try? CLIRelay.isolate(fileURL) {
                    readDir = dir
                    contextLine = "File: \(name) (read it at \(dir.appendingPathComponent(fileURL.lastPathComponent).path))"
                } else if let fileURL, let text = CLIRelay.inlineText(fileURL) {
                    contextLine = "File: \(name)\nFile contents:\n\(text)"
                } else {
                    contextLine = "File: \(name) (its contents can't be read here)"
                }
            }
        }
        defer { if let readDir { try? FileManager.default.removeItem(at: readDir) } }
        // A dropped file is read with no web at all: a file written to steer the model
        // could otherwise send what it reads to a website.
        let readsFile: Bool = {
            if case .file = context, relayHistory.isEmpty { return true }
            return false
        }()
        let request = CLIRequest(
            model: provider == .anthropic ? model : nil,
            system: systemPrompt + extraSystem,
            prompt: CLIRelay.chatPrompt(history: relayHistory, context: contextLine, query: query),
            web: !readsFile,
            readDir: readDir,
            noWebPolicy: nil,
            timeout: 180
        )
        do {
            let text = try await CLIRelay.ask(cli, request)
            relayHistory.append((user: historyContext.map { "\($0)\n\n\(query)" } ?? query, assistant: text))
            state.updateChat(.shared) { $0.append(ChatMessage(role: .assistant, content: text, provider: provider)) }
            state.stateOverride = nil
            state.showSharedChatAnswer()
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            await showError(error.localizedDescription, state: state)
        }
    }
    #endif

    /// Resolved once: NSFullUserName() is a system call, and the name cannot change under us
    /// while the app runs.
    private let systemPrompt = ClaudeService.makeSystemPrompt()
    /// Added to the system prompt for this turn (the chat's Mail switch).
    private var extraSystem = ""

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

    /// `target` is the conversation on screen when Send was pressed (the bubble went there): the request goes to
    /// that one, never to whatever is on screen when this runs.
    func chat(query: String, context: PromptContext?, state: AppState, target: ConversationID) async {
        if DemoEngine.shared.isActive {
            // A message for a Hermes agent never gets here during the demo: the caller refuses it first
            // (DemoGuard.mayChatSend), before the field is emptied or a bubble is added.
            state.stateOverride = .thinking
            await DemoEngine.shared.streamChatResponse(for: query)
            state.stateOverride = nil
            return
        }
        if let agentName = target.hermesAgent {
            await chatHermes(query: query, context: context, state: state, agentName: agentName)
            return
        }
        var query = query
        extraSystem = ""
        #if !APPSTORE
        // Mail on: the AI gets the latest messages under the request, and may answer with a
        // plan of actions (MailPlan.swift) that runs only after the user's click.
        if state.chatMailMode {
            query = await MailAgent.shared.decorate(query)
            extraSystem = MailAgentPrompt.instructions
        }
        #endif
        // The shared chat never reaches a Hermes agent, even if the provider was switched to Hermes since Send.
        // If the provider was never tracked (Hermes before this version) there is no provider to fall back on: nothing is sent.
        guard let provider = state.chatProvider == .hermes ? state.lastSharedProvider : state.chatProvider else {
            // Not reachable today (a shared target means the provider was not Hermes at the press). If it ever is,
            // the user sees the existing provider error and the typing dots go, never a bubble with no answer.
            state.stateOverride = nil
            await showError(String(localized: "API key missing. Open settings."), state: state)
            return
        }
        #if !APPSTORE
        // "Use my subscription": the provider's own terminal tool answers, signed in with
        // the user's account.
        if state.usesSubscription(provider) {
            await chatThroughSubscription(provider, query: query, context: context, state: state)
            return
        }
        #endif
        guard provider == .anthropic else {
            await chatOpenAICompatible(query: query, context: context, state: state, provider: provider)
            return
        }
        guard let key = apiKey, !key.isEmpty else {
            await showError(String(localized: "API key missing. Open settings."), state: state)
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
            "system": systemPrompt + extraSystem,
            "messages": conversationMessages,
        ]

        do {
            let data = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleChatResult(data, state: state)
        } catch {
            if !conversationMessages.isEmpty { conversationMessages.removeLast() }
            await showError(error.localizedDescription, state: state)
        }
    }

    // MARK: - OpenAI-compatible chat (Google Gemini / OpenAI / Ollama / LM Studio)

    func chatOpenAICompatible(query: String, context: PromptContext?, state: AppState, provider: ChatProvider) async {
        guard provider != .anthropic, provider != .hermes else { return }

        let baseURL: String
        if provider == .ollama {
            baseURL = LocalChat.normaliseURL(state.ollamaServerURL)
        } else if provider == .lmstudio {
            baseURL = LocalChat.normaliseURL(state.lmstudioServerURL)
        } else {
            switch provider {
            case .google:    baseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
            case .openai:    baseURL = "https://api.openai.com/v1"
            case .deepseek:  baseURL = "https://api.deepseek.com/v1"
            case .qwen:      baseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"
            case .moonshot:  baseURL = "https://api.moonshot.cn/v1"
            case .anthropic, .ollama, .lmstudio, .hermes, .cursor, .copilot: baseURL = ""
            }
        }

        guard !baseURL.isEmpty else {
            if provider.isLocal {
                let name = provider == .ollama ? "Ollama" : "LM Studio"
                await showError(String(localized: "Connect \(name) in Settings → Chat first."), state: state)
            }
            return
        }
        guard let url = URL(string: "\(baseURL)/chat/completions") else { return }

        // Auth header
        let authHeader: String
        let cloudKey: String?   // the provider's own key, sent when streaming too
        if provider.isLocal {
            authHeader = "Bearer ollama"
            cloudKey = nil
        } else {
            guard let key = KeychainStore.shared.get(provider.keychainKey), !key.isEmpty else {
                await showError(String(localized: "\(provider.displayName) API key missing. Configure it in Settings."), state: state)
                return
            }
            authHeader = "Bearer \(key)"
            cloudKey = key
        }

        // Build messages
        var msgs: [[String: Any]] = [["role": "system", "content": systemPrompt + extraSystem]]
        for m in conversationMessages {
            var simplified = m
            if let content = m["content"] as? [[String: Any]],
               let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                simplified["content"] = text
            }
            msgs.append(simplified)
        }
        let userText = openAIUserText(query: query, context: context, inlineFiles: provider.isLocal, firstTurn: conversationMessages.isEmpty)
        msgs.append(["role": "user", "content": userText])
        conversationMessages.append(["role": "user", "content": userText])

        let useStream = provider.isLocal || provider == .deepseek || provider == .qwen || provider == .moonshot
        var body: [String: Any] = [
            "model": state.chatModel(for: provider),
            "max_tokens": 4096,
            "messages": msgs,
        ]
        if useStream { body["stream"] = true }

        var req = URLRequest(url: url, timeoutInterval: useStream ? 120 : 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if useStream {
            // Add placeholder (hidden until first token via ChatBubble empty-content guard)
            let placeholder = ChatMessage(role: .assistant, content: "", provider: provider)
            let msgId = placeholder.id
            sharedChatStreaming = true
            state.updateChat(.shared) { $0.append(placeholder) }
            state.stateOverride = .thinking
            let modelCopy = state.chatModel(for: provider)
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
                    model: modelCopy,
                    apiKey: cloudKey
                ) { [state, msgId] visible in
                    if !visible.isEmpty, state.stateOverride == .thinking {
                        state.stateOverride = nil   // hide typing dots on first visible text
                    }
                    state.updateChat(.shared) { h in
                        if let idx = h.firstIndex(where: { $0.id == msgId }) { h[idx].content = visible }
                    }
                }
                sharedChatStreaming = false
                conversationMessages.append(["role": "assistant", "content": final])
                state.updateChat(.shared) { h in
                    if let idx = h.firstIndex(where: { $0.id == msgId }) { h[idx].content = final }
                }
                state.stateOverride = nil
                state.showSharedChatAnswer()
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch let e as LocalChatError {
                sharedChatStreaming = false
                if !conversationMessages.isEmpty { conversationMessages.removeLast() }
                state.updateChat(.shared) { $0.removeAll { $0.id == msgId } }
                state.stateOverride = nil
                let msg: String
                switch e {
                case .serverUnreachable:
                    if provider == .ollama {
                        msg = String(localized: "Ollama isn't running. Open it, then ask again.")
                    } else if provider == .lmstudio {
                        msg = String(localized: "Start the local server in LM Studio, then ask again.")
                    } else {
                        msg = String(localized: "\(provider.displayName) is unreachable. Check your connection and API key.")
                    }
                case .modelNotFound(let m):
                    msg = String(localized: "\(m) isn't installed. Pick another model above the chat box.")
                case .serverError(let s):
                    msg = s
                }
                await showError(msg, state: state)
            } catch {
                sharedChatStreaming = false
                if !conversationMessages.isEmpty { conversationMessages.removeLast() }
                state.updateChat(.shared) { $0.removeAll { $0.id == msgId } }
                state.stateOverride = nil
                await showError(error.localizedDescription, state: state)
            }
        } else {
            // Non-streaming (Google, OpenAI)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let err = (json["error"] as? [String: Any])?["message"] as? String {
                        throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: err])
                    }
                    throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"])
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Unexpected response format")])
                }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                conversationMessages.append(["role": "assistant", "content": trimmed])
                state.updateChat(.shared) { $0.append(ChatMessage(role: .assistant, content: trimmed, provider: provider)) }
                state.stateOverride = nil
                state.showSharedChatAnswer()
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } catch {
                if !conversationMessages.isEmpty { conversationMessages.removeLast() }
                await showError(error.localizedDescription, state: state)
            }
        }
    }

    /// User text for the first turn of an OpenAI-style chat: window/file context prepended to the query.
    /// `inlineFiles` inlines text files (up to 24 000 chars); otherwise only the file name is sent.
    private func openAIUserText(query: String, context: PromptContext?, inlineFiles: Bool, firstTurn: Bool) -> String {
        var userText = query
        if firstTurn, let ctx = context {
            switch ctx {
            case .window(let app, let title, let url):
                var prefix = "Context — App: \(app), Window: \(title)"
                if let u = url { prefix += ", URL: \(u)" }
                userText = prefix + "\n\n" + query
            case .file(let name, let fileURL):
                if inlineFiles, let fileURL = fileURL {
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
        return userText
    }

    // MARK: - Hermes agents (stateless, streamed, no Mochi system prompt)

    func chatHermes(query: String, context: PromptContext?, state: AppState, agentName: String) async {
        // The agent the message was typed for, by name: a different active agent now does not take it over.
        guard let agent = state.hermesAgents.first(where: { $0.name == agentName }) else {
            await showError(String(localized: "Connect a Hermes agent in Settings → Chat first."), state: state)
            return
        }
        let signIn = agent.connection == .signIn
        var key = ""
        if signIn {
            // No session for this agent (or for this address): nothing is sent.
            if case .failure(let e) = HermesSignIn.boundSession(for: agent, in: HermesSignIn.decodeSessions(KeychainStore.shared.get("hermes-agent-sessions") ?? "")) {
                await showError(e.userMessage, state: state)
                return
            }
        } else {
            switch HermesChat.boundKey(for: agent, in: HermesChat.decodeKeys(KeychainStore.shared.get("hermes-agent-keys") ?? "")) {
            case .success(let k): key = k
            case .failure(let e):
                // The key is never sent: the stored agent does not match what the key was connected to.
                await showError(e.userMessage, state: state)
                return
            }
        }

        // This agent's own conversation: nothing of another agent or provider is ever read or sent here.
        let id = ConversationID.hermes(agent.name)
        let generation = ensureConversation(id)
        // No system message: Hermes layers it over the agent's own prompt.
        var msgs = HermesChat.requestMessages(from: conversations[id].messages)
        let userText = openAIUserText(query: query, context: context, inlineFiles: true, firstTurn: conversations[id].messages.isEmpty)
        msgs.append(["role": "user", "content": userText])
        conversations.mutateIfPresent(id) { $0.messages.append(["role": "user", "content": userText]) }

        let placeholder = ChatMessage(role: .assistant, content: "")
        let msgId = placeholder.id
        state.updateChat(id) { $0.append(placeholder) }
        let turnId = UUID()
        conversations.mutateIfPresent(id) { $0.turns[turnId] = HermesTurn(task: nil, hasText: false) }
        refreshHermesTyping(state)
        state.setHermesPillBusy(agentName: agent.name, true)
        let pillTurn = state.beginHermesPillTurn(agentName: agent.name)
        defer { state.setHermesPillBusy(agentName: agent.name, false) }
        let startedAt = Date()
        appendAppLog("nb.log", "hermes turn started signIn=\(signIn)")
        let body: [String: Any] = ["model": agent.modelName, "messages": msgs, "stream": true]
        let encodedBody = signIn ? Data() : ((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        let storedSession = conversations[id].serverSession
        let task = Task { [state, msgId] () async throws -> String in
            let firstText: @MainActor () -> Void = {
                if self.conversations[id].turns[turnId]?.hasText == false {
                    // hide typing dots once no turn waits for text
                    self.conversations.mutateIfPresent(id) { $0.turns[turnId]?.hasText = true }
                    appendAppLog("nb.log", "hermes turn first text after=\(Self.seconds(since: startedAt))s")
                    self.refreshHermesTyping(state)
                }
            }
            // One write per tick: the text and the rows of the turn arrive together. Display only; written by message id
            // under the same rule as the text (a cleared or removed conversation is never brought back), and the first
            // text or the first row hides the typing dots.
            let onTurn: @MainActor (String?, [ChatSegment]?) -> Void = { visible, segments in
                if visible?.isEmpty == false || segments?.isEmpty == false { firstText() }
                // The overview card of this agent's pill follows the rows while the turn runs: a turn that already
                // ended (cancelled, cleared) writes nothing there.
                if let segments, self.conversations[id].turns[turnId] != nil {
                    state.setHermesPillRows(agentName: agent.name, turn: pillTurn, segments: segments)
                }
                state.updateChat(id, createIfMissing: false) { h in
                    guard let idx = h.firstIndex(where: { $0.id == msgId }) else { return }
                    if let visible { h[idx].content = visible }
                    if let segments { h[idx].segments = segments }
                }
            }
            if signIn {
                // The server keeps the history: only the new text is sent, the session is resumed by id.
                return try await HermesSignInNet.streamTurn(
                    agent: agent, sessions: HermesSessions.shared, storedSession: storedSession, text: userText,
                    onSession: { sessionId in
                        if self.isCurrent(id, generation: generation) {
                            self.conversations.mutateIfPresent(id) { $0.serverSession = sessionId.isEmpty ? nil : sessionId }
                        }
                    },
                    onToken: { onTurn($0, nil) }, onSegments: { onTurn(nil, $0) }, onTurn: onTurn,
                    approvals: HermesApprovalCenter.hooks)
            }
            return try await HermesChat.streamChat(agent: agent, key: key, encodedBody: encodedBody,
                                                   onToken: { onTurn($0, nil) }, onSegments: { onTurn(nil, $0) }, onTurn: onTurn,
                                                   approvals: HermesApprovalCenter.hooks)
        }
        conversations.mutateIfPresent(id) { $0.turns[turnId]?.task = task }
        do {
            let final = try await task.value
            conversations.mutateIfPresent(id) { $0.turns[turnId] = nil }
            guard isCurrent(id, generation: generation) else {
                state.endHermesPillTurn(agentName: agent.name, turn: pillTurn, finished: false)
                appendAppLog("nb.log", "hermes turn discarded (conversation cleared) after=\(Self.seconds(since: startedAt))s")
                refreshHermesTyping(state)
                return
            }
            // The rows already end with the answer (the last publish sealed it): nothing is added from the returned text.
            state.endHermesPillTurn(agentName: agent.name, turn: pillTurn, finished: true)
            conversations.mutateIfPresent(id) { $0.messages.append(["role": "assistant", "content": final]) }
            state.updateChat(id, createIfMissing: false) { h in
                if let idx = h.firstIndex(where: { $0.id == msgId }) { h[idx].content = final }
            }
            refreshHermesTyping(state)
            appendAppLog("nb.log", "hermes turn finished duration=\(Self.seconds(since: startedAt))s chars=\(final.count)")
            // This agent's chat on screen: nothing changes. Otherwise sound, badge and back to the chat.
            state.announceHermesTurn(agentName: agent.name, failed: false, view: .prompt)
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            conversations.mutateIfPresent(id) { $0.turns[turnId] = nil }
            guard isCurrent(id, generation: generation) else {
                // Cleared meanwhile: leave the new conversation alone, only stop the typing dots
                // when no newer Hermes request is still waiting for its first text.
                state.endHermesPillTurn(agentName: agent.name, turn: pillTurn, finished: false)
                appendAppLog("nb.log", "hermes turn discarded (conversation cleared) after=\(Self.seconds(since: startedAt))s")
                refreshHermesTyping(state)
                return
            }
            state.endHermesPillTurn(agentName: agent.name, turn: pillTurn, finished: false)
            // Remove this turn's own message: a sibling turn may have added its own after it.
            conversations.mutateIfPresent(id) { c in
                if let own = c.messages.lastIndex(where: { ($0["role"] as? String) == "user" && ($0["content"] as? String) == userText }) {
                    c.messages.remove(at: own)
                }
            }
            state.updateChat(id, createIfMissing: false) { $0.removeAll { $0.id == msgId } }
            refreshHermesTyping(state)
            let msg = (error as? HermesChatError)?.userMessage ?? String(localized: "Hermes request failed.")
            appendAppLog("nb.log", "hermes turn failed after=\(Self.seconds(since: startedAt))s error=\(Self.errorCaseName(error))")
            let outcome = state.announceHermesTurn(agentName: agent.name, failed: true, view: .note)
            // A card on screen keeps the screen: the error is only signalled by the sound and the pill badge.
            if outcome == .badgeOnly {
                // The text waits in the chat of this agent for when it is next shown.
                state.updateChat(id, createIfMissing: false) { $0.append(ChatMessage(role: .assistant, content: msg, isNotice: true)) }
            } else { await showError(msg, state: state) }
        }
    }

    private static func seconds(since start: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(start)) }

    /// Case name of an error, never its associated values (they may carry a host or a server text).
    private static func errorCaseName(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if error is HermesChatError { return String(String(describing: error).prefix { $0 != "(" }) }
        return "other"
    }

    // MARK: - Structured search (M8 — window attach + web search)

    func search(query: String, context: PromptContext?, state: AppState) async {
        guard let key = apiKey, !key.isEmpty else {
            await showError(String(localized: "Anthropic API key missing. Open settings to configure it."), state: state)
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

    #if !APPSTORE
    // MARK: - Voice brain turn (Claude with Coucou's tools)

    /// One Messages API call for the voice brain: returns the assistant content blocks and
    /// the stop reason. The fast model first, the Settings model if the key can't use it.
    func voiceTurn(system: String, messages: [[String: Any]], tools: [[String: Any]])
        async -> (content: [[String: Any]], stopReason: String)? {
        guard let key = apiKey, !key.isEmpty else { return nil }
        func body(_ model: String) -> [String: Any] {
            ["model": model, "max_tokens": 2048, "system": system, "tools": tools, "messages": messages]
        }
        let data: Data
        do {
            data = try await callAPI(body: body(Self.voiceModel), key: key, beta: "web-search-2025-03-05")
        } catch {
            guard let retry = try? await callAPI(body: body(model), key: key, beta: "web-search-2025-03-05") else {
                appendAppLog("nb.log", "[Voice] Claude turn failed: \(error.localizedDescription)")
                return nil
            }
            data = retry
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else { return nil }
        return (content, json["stop_reason"] as? String ?? "end_turn")
    }

    // MARK: - Voice answer (Coucou's voice, web search)

    /// Fast model for spoken answers; the chat model from Settings when it is unavailable.
    private static let voiceModel = "claude-haiku-4-5"

    /// A short answer Coucou can say aloud, with web search, in the answer language.
    /// `history` holds the previous exchanges of this voice conversation (memory only).
    /// nil on any failure: no key, network, quota.
    func voiceAnswer(_ question: String, history: [VoiceWebTurn], lang: VoiceLang) async -> String? {
        guard let key = apiKey, !key.isEmpty else { return nil }
        let today = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year()
            .locale(lang.formatLocale))
        let system: String
        switch lang {
        case .fr:
            system = """
              Tu es Coucou, un assistant vocal dans le notch du Mac. Nous sommes le \(today). \
              Ta réponse est lue à voix haute : 2 à 4 phrases courtes, en français, sans markdown, sans liste, \
              sans lien, sans citer tes sources. Cherche sur le web dès que la réponse peut avoir changé \
              (actualité, résultats, prix, horaires, météo, personnes). Donne directement les faits utiles. \
              S'il y a clairement plus à raconter, termine par une seule courte question pour proposer la suite.
              """
        case .pt:
            system = """
              Você é o Coucou, um assistente de voz no notch do Mac. Hoje é \(today). \
              Sua resposta é lida em voz alta: de 2 a 4 frases curtas, em português do Brasil, sem markdown, \
              sem listas, sem links, sem citar fontes. Pesquise na web sempre que a resposta puder ter mudado \
              (notícias, resultados, preços, horários, clima, pessoas). Dê direto os fatos úteis. \
              Se claramente houver mais a contar, termine com uma única pergunta curta se oferecendo para continuar.
              """
        case .en:
            system = """
              You are Coucou, a voice assistant in the Mac's notch. Today is \(today). \
              Your answer is read aloud: 2 to 4 short sentences in English, no markdown, no lists, no links, \
              never cite sources. Search the web whenever the answer may have changed (news, scores, prices, \
              opening hours, weather, people). Give the useful facts straight away. \
              When there is clearly more worth telling, end with one short question offering to go on.
              """
        }
        var messages: [[String: Any]] = []
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question])

        var search: [String: Any] = ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
        var location: [String: Any] = ["type": "approximate", "timezone": TimeZone.current.identifier]
        if let country = Locale.current.region?.identifier, country.count == 2 { location["country"] = country }
        search["user_location"] = location

        func body(_ model: String) -> [String: Any] {
            ["model": model, "max_tokens": 700, "system": system, "tools": [search], "messages": messages]
        }
        let data: Data
        do {
            data = try await callAPI(body: body(Self.voiceModel), key: key, beta: "web-search-2025-03-05")
        } catch {
            // The fast model is not available to this key: the Settings model instead.
            guard let retry = try? await callAPI(body: body(model), key: key, beta: "web-search-2025-03-05") else {
                appendAppLog("nb.log", "[Voice] web answer failed")
                return nil
            }
            data = retry
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = claudeResponseText(fromContent: content) else { return nil }
        let spoken = VoiceQuery.spokenText(text)
        return spoken.isEmpty ? nil : spoken
    }
    #endif

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

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Parse Anthropic error format: {"type":"error","error":{"type":"…","message":"…"}}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let errType = err["type"] as? String,
               let errMsg = err["message"] as? String {
                if errType == "not_found_error" {
                    let id = AppState.shared.claudeModel
                    throw NSError(domain: "Claude", code: 0,
                        userInfo: [NSLocalizedDescriptionKey:
                            String(localized: "Model not found: \(id). Pick another one in Settings.")])
                }
                throw NSError(domain: "Claude", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            let msg = String(data: data, encoding: .utf8) ?? String(localized: "unknown error")
            throw NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    // MARK: - Chat result handler

    private func handleChatResult(_ data: Data, state: AppState) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            await showError(String(localized: "Unexpected API response."), state: state)
            return
        }

        // Store full content (includes tool_use/tool_result blocks) for correct multi-turn context
        conversationMessages.append(["role": "assistant", "content": content])

        guard let text = claudeResponseText(fromContent: content) else {
            await showError(String(localized: "No response text."), state: state)
            return
        }

        // Add to display history
        let answer = ChatMessage(role: .assistant, content: text, provider: .anthropic)
        state.updateChat(.shared) { $0.append(answer) }

        state.stateOverride = nil
        state.showSharedChatAnswer()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: - Structured result handler

    private func handleResult(_ data: Data, state: AppState) async {
        // Extract text from Anthropic response (may contain tool_use / web_search_tool_result blocks)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = claudeResponseText(fromContent: content) else {
            await showError(String(localized: "Unexpected API response."), state: state)
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
            let title  = parsed["title"] as? String ?? String(localized: "Result")
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
                title: String(localized: "Claude's response"),
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
