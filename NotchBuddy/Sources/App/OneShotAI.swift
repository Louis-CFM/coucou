import Foundation

// MARK: - OneShotAI
//
// The chat providers other than Claude, for one question outside the chat (the
// summary of a call): whichever the user set up in Settings → Chat, with the
// model picked for it there. Claude keeps its own path (ClaudeEndpoint): its API
// is not OpenAI's.

@MainActor
enum OneShotAI {

    /// The providers other than Claude that can answer now: a key in the Keychain,
    /// or a local server's address. In the order of Settings → Chat.
    static func configured(_ state: AppState = .shared) -> [ChatProvider] {
        ChatProvider.allCases.filter { $0 != .anthropic && isConfigured($0, state) }
    }

    static func isConfigured(_ provider: ChatProvider, _ state: AppState = .shared) -> Bool {
        if provider.isLocal { return !baseURL(provider, state).isEmpty }
        guard !provider.keychainKey.isEmpty else { return false }
        return !(KeychainStore.shared.get(provider.keychainKey) ?? "").isEmpty
    }

    /// The provider's OpenAI-compatible base URL; "" for Claude, or a local server not set up.
    static func baseURL(_ provider: ChatProvider, _ state: AppState = .shared) -> String {
        switch provider {
        case .google:    return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .openai:    return "https://api.openai.com/v1"
        case .deepseek:  return "https://api.deepseek.com/v1"
        case .qwen:      return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .moonshot:  return "https://api.moonshot.cn/v1"
        case .ollama:    return LocalChat.normaliseURL(state.ollamaServerURL)
        case .lmstudio:  return LocalChat.normaliseURL(state.lmstudioServerURL)
        case .anthropic: return ""
        }
    }

    /// The model picked for `provider` above the chat box, or its default.
    static func model(_ provider: ChatProvider, _ state: AppState = .shared) -> String {
        let picked: String
        switch provider {
        case .google:    picked = state.googleChatModel
        case .openai:    picked = state.openAIChatModel
        case .deepseek:  picked = state.deepseekChatModel
        case .qwen:      picked = state.qwenChatModel
        case .moonshot:  picked = state.moonshotChatModel
        case .ollama:    picked = state.ollamaChatModel
        case .lmstudio:  picked = state.lmstudioChatModel
        case .anthropic: picked = state.claudeModel
        }
        let trimmed = picked.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    /// The answer of `provider` to one system + user message. nil on any failure:
    /// not set up, no network, an error or an empty reply.
    static func ask(_ provider: ChatProvider, system: String, user: String,
                    timeout: TimeInterval, temperature: Double? = nil) async -> String? {
        guard provider != .anthropic, isConfigured(provider),
              let url = OpenAICompletion.url(base: baseURL(provider), local: provider.isLocal) else { return nil }
        let key = provider.isLocal ? nil : KeychainStore.shared.get(provider.keychainKey)
        let request = OpenAICompletion.request(url: url, key: key, model: model(provider), system: system,
                                               user: user, timeout: timeout, temperature: temperature)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                appendAppLog("nb.log", "[AI] \(provider.displayName): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            return OpenAICompletion.text(from: data)
        } catch {
            appendAppLog("nb.log", "[AI] \(provider.displayName): \(error.localizedDescription)")
            return nil
        }
    }
}
