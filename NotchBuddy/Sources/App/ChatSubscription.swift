import Foundation

// MARK: - Which chat providers can answer through the user's subscription
//
// Settings → Chat → Your AI subscriptions: one switch per provider. On, the chat goes
// through the provider's own terminal tool (CLIRelay.swift); off, through its API key.
// Cursor and GitHub Copilot have no API here: the switch shows or hides them in the chat.

extension ChatProvider {
    /// The tools that answer for this provider, the preferred one first. Empty: API only.
    var subscriptionCLIs: [SubscriptionCLI] {
        switch self {
        case .anthropic: [.claude]
        case .google:    [.antigravity, .gemini]
        case .openai:    [.codex]
        case .cursor:    [.cursor]
        case .copilot:   [.copilot]
        case .ollama, .lmstudio, .deepseek, .qwen, .moonshot: []
        }
    }

    /// Answered only through a subscription (no key to fall back on).
    var subscriptionOnly: Bool { self == .cursor || self == .copilot }

    /// The providers listed under "Your AI subscriptions", in order.
    static let subscriptionProviders: [ChatProvider] = [.anthropic, .google, .openai, .cursor, .copilot]

    /// The name under "Your AI subscriptions": the plan people know.
    var subscriptionName: String {
        switch self {
        case .anthropic: "Claude"
        case .google:    "Google Gemini"
        case .openai:    "ChatGPT"
        case .cursor:    "Cursor"
        case .copilot:   "GitHub Copilot"
        default:         displayName
        }
    }

    #if !APPSTORE
    /// The installed tool that answers for this provider, if any.
    var installedCLI: SubscriptionCLI? {
        subscriptionCLIs.first { CLILocator.shared.isInstalled($0) }
    }
    #endif
}

extension AppState {
    private static func subscriptionKey(_ p: ChatProvider) -> String { "chat.useSubscription.\(p.rawValue)" }

    /// Whether the chat with `p` goes through the user's subscription.
    func usesSubscription(_ p: ChatProvider) -> Bool {
        #if APPSTORE
        return false
        #else
        guard !p.subscriptionCLIs.isEmpty else { return false }
        if let chosen = UserDefaults.standard.object(forKey: Self.subscriptionKey(p)) as? Bool { return chosen }
        // Never chosen: on when there is no key to use instead (what 0.5.5 did for Claude),
        // and for Cursor and Copilot once their tool is installed.
        if p.subscriptionOnly { return p.installedCLI != nil }
        return (KeychainStore.shared.get(p.keychainKey) ?? "").isEmpty
        #endif
    }

    func setUsesSubscription(_ on: Bool, for p: ChatProvider) {
        UserDefaults.standard.set(on, forKey: Self.subscriptionKey(p))
        objectWillChange.send()
        // The chat can't stay on a provider that no longer answers.
        if !on && p.subscriptionOnly && chatProvider == p { chatProvider = .anthropic }
        fetchedProviderModels[p] = nil
        providerModelFetchError[p] = nil
    }

    /// Shown on the chat's model chip.
    var chatChipLabel: String {
        #if !APPSTORE
        if usesSubscription(chatProvider) {
            let tool = (chatProvider.installedCLI ?? chatProvider.subscriptionCLIs.first)?.displayName ?? ""
            return chatProvider == .anthropic ? "\(claudeModel) · \(tool)" : tool
        }
        #endif
        return activeChatModel
    }
}

extension AppState {
    /// The subscription answers for `p` right now: switched on and its tool installed.
    func subscriptionReady(_ p: ChatProvider) -> Bool { subscriptionTool(p) != nil }

    /// The tool answering for `p` through the subscription, if it does.
    func subscriptionTool(_ p: ChatProvider) -> String? {
        #if APPSTORE
        return nil
        #else
        guard usesSubscription(p) else { return nil }
        return p.installedCLI?.displayName
        #endif
    }

    /// The model the chat's picker shows as chosen: the tool's own default ("") when a
    /// tool other than Claude Code answers.
    var pickerModel: String {
        usesSubscription(chatProvider) && chatProvider != .anthropic ? "" : activeChatModel
    }
}
