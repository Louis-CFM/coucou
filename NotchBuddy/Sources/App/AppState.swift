import Foundation
import SwiftUI
import Combine


@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden {
        didSet {
            #if !APPSTORE
            if mode != .expanded { clearCmuxPrompt() }
            #endif
            clearHermesBadgeIfChatShown()
            syncChatMediaVisibility()
        }
    }
    @Published var view: IslandView = .overview {
        didSet {
            #if !APPSTORE
            // Every entry to the prompt view that is not the cmux one shows the normal chat.
            if view == .prompt && !cmuxOpeningPrompt { clearCmuxPrompt() }
            #endif
            clearHermesBadgeIfChatShown()
            syncChatMediaVisibility()
        }
    }

    /// The chat is on screen only while the island is open on the prompt view: a media row fetches by itself only then,
    /// and a voice message that plays is paused (keeping its position) the moment the island folds or hides.
    private func syncChatMediaVisibility() {
        ChatMediaVisibility.shared.set(mode == .expanded && view == .prompt)
    }

    /// Another conversation came on screen (another agent, or the shared chat): a voice message of the one that left
    /// pauses, keeping its position.
    private func syncChatMediaConversation() {
        ChatMediaStore.shared.conversationChanged(to: activeConversationID.mediaKey)
    }

    /// Where the answers of the chat on screen come from, for the media rows. Only a Hermes agent writes directives;
    /// only a sign in agent can be asked for a file.
    var chatMediaContext: ChatMediaContext {
        guard chatProvider == .hermes, let agent = activeHermesAgent else { return ChatMediaContext() }
        return ChatMediaContext(enabled: true, conversation: activeConversationID.mediaKey, agent: agent, agentName: agent.shownName)
    }

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil {
        didSet {
            // The prompt slot must show what belongs to the focused pill: any writer that moves the focus
            // (new session, approval card, Hermes announce...) closes a slot that no longer belongs to it.
            guard oldValue != focusId, !applyingFocusEffect, let content = promptContent,
                  !PromptSlot.belongs(content, to: focusPill) else { return }
            closePromptSlot()
        }
    }

    // Bot state override
    @Published var stateOverride: BotState? = nil

    // Real notch dimensions (set by IslandWindowController on launch)
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight
    var hasNotch = true

    // Last app active before NotchBuddy (for window context capture)
    var lastExternalApp: NSRunningApplication? = nil

    // Bot drag-attach state (hides original bot while ghost follows cursor)
    @Published var isDraggingBot: Bool = false

    // Desktop Mochi: true while Mochi lives on the desktop instead of the notch
    @Published var mochiOnDesktop: Bool = false

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

    // Keyboard navigation — index of the selected item within the current card's list (nil = none)
    @Published var cardSelection: Int? = nil
    // Number of navigable items in the card currently on screen (0 = no list)
    @Published var cardItemCount: Int = 0

    // Upload progress (0-1) — set to 1.0 only at completion; animation is time-based
    @Published var uploadProgress: Double = 0

    // Upload animation timing (non-published — TimelineViews read these directly)
    var uploadStartTime: Date?
    var uploadDuration: Double = 2.4

    // File drag-over state (mailbox morph glow + mouth spring)
    @Published var fileDragOver: Bool = false

    // Sound enabled — persisted
    @Published var soundEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    // Weekly recap — persisted
    @Published var recapEnabled: Bool = (UserDefaults.standard.object(forKey: "recapEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(recapEnabled, forKey: "recapEnabled") }
    }
    @Published var recapHideProjects: Bool = UserDefaults.standard.bool(forKey: "recapHideProjects") {
        didSet { UserDefaults.standard.set(recapHideProjects, forKey: "recapHideProjects") }
    }

    // Mochi outfit selection — persisted
    @Published var mochiOutfitSelection: Outfit = .auto {
        didSet { Outfit.stored = mochiOutfitSelection }
    }
    // A colour of the user's own for each pill's Mochi (pill id → "#RRGGBB") — persisted.
    // Empty means the catalog's colours. PillDefinition.color reads the stored value, so
    // what is built from the catalog follows on its own; the tasks already on the island
    // hold a copy of their colour and are repainted here.
    @Published var pillColors: [String: String] = [:] {
        didSet {
            PillColors.stored = pillColors
            var repainted = tasks
            var changed = false
            for i in repainted.indices {
                guard let def = PillCatalog.definition(for: repainted[i].id),
                      repainted[i].color != def.color else { continue }
                repainted[i].color = def.color
                changed = true
            }
            if changed { tasks = repainted }
        }
    }
    /// Picks a colour for a pill's Mochi; nil, or the pill's own catalog colour, goes back to the default.
    func setPillColor(_ id: String, _ hex: String?) {
        guard let def = PillCatalog.definition(for: id) else { return }
        pillColors = PillColors.picking(hex, for: id, catalogColor: def.defaultColor, in: pillColors)
    }
    // Transient: outfit preview while hovering in wardrobe (overrides resolvedOutfit in BotCanvasView)
    var wardrobePreviewOutfit: Outfit? = nil
    // Per-day seasonal cache — read on every Mochi frame: valid until the next midnight,
    // so a frame costs one date comparison instead of calendar math.
    private var _seasonalCache: (validUntil: Date, outfit: Outfit)?
    var resolvedOutfit: Outfit {
        if let preview = wardrobePreviewOutfit { return preview }
        guard mochiOutfitSelection == .auto else { return mochiOutfitSelection }
        let now = Date()
        if let c = _seasonalCache, now < c.validUntil { return c.outfit }
        let cal = Calendar.current
        let outfit = Outfit.seasonal(for: now, calendar: cal)
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))
            ?? now.addingTimeInterval(3600)
        _seasonalCache = (validUntil: midnight, outfit: outfit)
        return outfit
    }

    // Claude model used by the chat and the search — persisted
    static let defaultClaudeModel = "claude-sonnet-4-6"
    @Published var claudeModel: String = AppState.defaultClaudeModel {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }

    // In-chat provider + model — picked via the model selector in the prompt view
    /// The chat's Mail switch (GitHub build): the AI sees the latest messages and may prepare
    /// actions on them. Off at each launch.
    @Published var chatMailMode = false

    @Published var chatProvider: ChatProvider = .anthropic {
        didSet {
            UserDefaults.standard.set(chatProvider.rawValue, forKey: "chatProvider")
            if chatProvider != .hermes { lastSharedProvider = chatProvider }
            syncChatMediaConversation()
            // Switching only changes which conversation is shown: a Hermes agent never shares one with another
            // provider or agent, and nothing is cleared or cancelled by the switch.
            clearHermesBadgeIfChatShown()
        }
    }

    /// The last provider of the shared chat (any provider but Hermes). The shared chat is shown with it when the
    /// provider is Hermes and the slot opens for a pill that is not a Hermes agent.
    /// Nil when it is not known (Hermes was already selected before this was tracked): nothing switches to a
    /// cloud provider by itself then.
    private(set) var lastSharedProvider: ChatProvider? = nil {
        didSet { if let p = lastSharedProvider { UserDefaults.standard.set(p.rawValue, forKey: "chatSharedProvider") } }
    }

    /// Every chat conversation, in memory for the app session only (never written to disk): one for the non Hermes
    /// providers, one per Hermes agent (by identity name).
    @Published private var chatHistories = ConversationStore<[ChatMessage]>(empty: [])

    /// The conversation on screen.
    var activeConversationID: ConversationID {
        .current(hermesActive: chatProvider == .hermes, agent: activeHermesAgent?.name)
    }

    /// The messages of the conversation on screen.
    var chatHistory: [ChatMessage] {
        get { chatHistories[activeConversationID] }
        set { chatHistories.set(activeConversationID, newValue) }
    }

    /// The messages of one conversation, shown or not (a missing one reads as empty).
    func chatMessages(_ id: ConversationID) -> [ChatMessage] { chatHistories[id] }

    /// Changes the messages of one conversation, shown or not (a turn may finish while another chat is on screen).
    /// A turn that outlives its conversation (the agent was removed) passes `createIfMissing: false`: it must not
    /// bring an empty conversation back.
    func updateChat(_ id: ConversationID, createIfMissing: Bool = true, _ body: (inout [ChatMessage]) -> Void) {
        if createIfMissing { chatHistories.mutate(id, body) } else { chatHistories.mutateIfPresent(id, body) }
    }

    /// Clears one conversation: its messages, its stored server session and its running turns, nothing else.
    func clearConversation(_ id: ConversationID) {
        ChatFolds.memory.forget(chatHistories[id].map(\.id))
        chatHistories.remove(id)
        ClaudeService.shared.clearConversation(id)
        // Cancelled turns end by themselves and release their own count in `hermesTurnsRunning`.
        if let name = id.hermesAgent { clearHermesPillCard(agentName: name) }
        if let name = id.hermesAgent, let pill = HermesPills.taskIds(for: hermesAgents.map { $0.name })[name],
           let i = tasks.firstIndex(where: { $0.id == pill }) { tasks[i].pillBadge = nil }
    }

    /// The new conversation action: clears the conversation on screen only.
    func clearActiveConversation() { clearConversation(activeConversationID) }

    /// An agent that is gone: its conversation and its running turns go with it.
    private func discardHermesConversations(of names: [String]) {
        for name in names {
            ChatFolds.memory.forget(chatHistories[.hermes(name)].map(\.id))
            chatHistories.remove(.hermes(name))
            hermesCards[name]?.discard()
            ClaudeService.shared.dropConversation(.hermes(name))
            promptDrafts.clear(.hermesChat(agent: name))
        }
    }
    @Published var googleChatModel: String = ChatProvider.google.defaultModel {
        didSet { UserDefaults.standard.set(googleChatModel, forKey: "googleChatModel") }
    }
    @Published var openAIChatModel: String = ChatProvider.openai.defaultModel {
        didSet { UserDefaults.standard.set(openAIChatModel, forKey: "openAIChatModel") }
    }
    @Published var ollamaChatModel: String = ChatProvider.ollama.defaultModel {
        didSet { UserDefaults.standard.set(ollamaChatModel, forKey: "ollamaChatModel") }
    }
    @Published var lmstudioChatModel: String = ChatProvider.lmstudio.defaultModel {
        didSet { UserDefaults.standard.set(lmstudioChatModel, forKey: "lmstudioChatModel") }
    }
    @Published var deepseekChatModel: String = ChatProvider.deepseek.defaultModel {
        didSet { UserDefaults.standard.set(deepseekChatModel, forKey: "deepseekChatModel") }
    }
    @Published var qwenChatModel: String = ChatProvider.qwen.defaultModel {
        didSet { UserDefaults.standard.set(qwenChatModel, forKey: "qwenChatModel") }
    }
    @Published var moonshotChatModel: String = ChatProvider.moonshot.defaultModel {
        didSet { UserDefaults.standard.set(moonshotChatModel, forKey: "moonshotChatModel") }
    }
    @Published var ollamaServerURL: String = "" {
        didSet { UserDefaults.standard.set(ollamaServerURL, forKey: "ollamaServerURL") }
    }
    @Published var lmstudioServerURL: String = "" {
        didSet { UserDefaults.standard.set(lmstudioServerURL, forKey: "lmstudioServerURL") }
    }
    // Hermes agents: the list holds no secret (keys live in the Keychain item "hermes-agent-keys")
    @Published var hermesAgents: [HermesAgent] = [] {
        didSet {
            UserDefaults.standard.set(HermesChat.encodeAgents(hermesAgents), forKey: "hermesAgents")
            let gone = Set(oldValue.map { $0.name }).subtracting(hermesAgents.map { $0.name })
            discardHermesConversations(of: gone.sorted())
            for name in gone { HermesApprovalCenter.shared.agentRemoved(name) }
        }
    }
    @Published var hermesChatAgent: String = "" {
        didSet {
            UserDefaults.standard.set(hermesChatAgent, forKey: "hermesChatAgent")
            clearHermesBadgeIfChatShown()
            syncChatMediaConversation()
        }
    }
    /// The agent picked in the chat (by name), else the first configured one.
    var activeHermesAgent: HermesAgent? {
        hermesAgents.first(where: { $0.name == hermesChatAgent }) ?? hermesAgents.first
    }

    /// Picks the Hermes agent used by the chat. Each agent has its own conversation: selecting another one only
    /// switches which conversation is shown, nothing is cleared or cancelled.
    func selectHermesAgent(_ name: String) {
        hermesChatAgent = name
    }

    /// Replaces the stored agent of the same name (or adds it) with one update of the list. A conversation tied to a
    /// different destination (another address, profile or kind) is dropped: its history must not reach the new one.
    private func storeHermesAgent(_ agent: HermesAgent) {
        let old = hermesAgents.first { $0.name == agent.name }
        var next = agent
        if next.displayName == nil { next.displayName = old?.displayName }
        var list = hermesAgents
        list.removeAll { $0.name == agent.name }
        list.append(next)
        hermesAgents = list
        if let old, !old.sameDestination(as: next) { clearConversation(.hermes(agent.name)) }
    }

    /// Sets (or clears, with an empty text) the display name of an agent. The identity name stays: Keychain binding,
    /// pill id, conversation and selection are untouched.
    @discardableResult
    func renameHermesAgent(_ identity: String, to raw: String) -> Result<String, HermesAgentNames.RenameError> {
        switch HermesAgentNames.rename(identity, to: raw, in: hermesAgents) {
        case .failure(let e): return .failure(e)
        case .success(let list):
            hermesAgents = list
            fetchedProviderModels[.hermes] = nil   // the picker lists the shown names
            syncHermesPills()
            return .success(list.first { $0.name == identity }?.shownName ?? identity)
        }
    }

    /// True when `name` is already the identity or the shown name of an agent (a new agent may not take it).
    func hermesNameTaken(_ name: String) -> Bool {
        hermesAgents.contains { $0.name == name } || HermesAgentNames.isTaken(name, in: hermesAgents, except: nil)
    }

    /// Stores the agent and its key bound to its URL and profile (Keychain only), then selects it.
    func addHermesAgent(_ agent: HermesAgent, key: String) {
        var keys = HermesChat.decodeKeys(KeychainStore.shared.get("hermes-agent-keys") ?? "")
        keys[agent.name] = HermesChat.KeyRecord(key: key, baseURL: agent.baseURL, profile: agent.profile)
        KeychainStore.shared.set("hermes-agent-keys", value: HermesChat.encodeKeys(keys))
        storeHermesAgent(agent)
        fetchedProviderModels[.hermes] = nil
        providerModelFetchError[.hermes] = nil
        hermesChatAgent = agent.name
        syncHermesPills()
    }

    /// True when the key stored for `agent` is bound to its current URL and profile.
    func isHermesAgentBound(_ agent: HermesAgent) -> Bool {
        if case .success = HermesChat.boundKey(for: agent, in: HermesChat.decodeKeys(KeychainStore.shared.get("hermes-agent-keys") ?? "")) { return true }
        return false
    }

    // MARK: Hermes sign in sessions (Keychain item "hermes-agent-sessions", one record per agent name)
    // Reads happen here; every write goes through `HermesSessions.shared`, the single owner of the item.

    private func hermesSessions() -> [String: HermesSignIn.SessionRecord] {
        HermesSignIn.decodeSessions(KeychainStore.shared.get("hermes-agent-sessions") ?? "")
    }

    /// "Signed in as <label>" text for a sign in agent, or nil when it has no usable session
    /// (no record, a record for another address, or an expired one that cannot be refreshed).
    func hermesSessionLabel(_ agent: HermesAgent) -> String? {
        guard case .success(let r) = HermesSignIn.boundSession(for: agent, in: hermesSessions()),
              HermesSignIn.tokenAction(r, now: Date().timeIntervalSince1970) != .signInAgain else { return nil }
        return r.label.isEmpty ? r.userID : r.label
    }

    /// Keeps a session obtained by "Sign in again", only while the agent still exists with the same address and
    /// kind; otherwise the result is dropped (false). The check and the store call happen with no suspension in
    /// between, and `removeHermesAgent` removes the record again after the row, so no record outlives its agent.
    func storeHermesSession(_ record: HermesSignIn.SessionRecord, for agent: HermesAgent) async -> Bool {
        guard hermesAgents.contains(where: { $0.name == agent.name && $0.baseURL == agent.baseURL && $0.connection == .signIn }) else { return false }
        await HermesSessions.shared.store(record, name: agent.name)
        clearConversation(.hermes(agent.name))   // the stored server session belonged to the old sign in
        return true
    }

    /// Drops the session of an agent, keeps the row.
    func signOutHermesAgent(named name: String) async {
        await HermesSessions.shared.remove(name: name)
        clearConversation(.hermes(name))
    }

    /// Adds a signed-in agent and stores its session (Keychain only), then selects it.
    func addHermesSignedInAgent(_ agent: HermesAgent, record: HermesSignIn.SessionRecord) async {
        var signedIn = agent
        signedIn.connection = .signIn
        await HermesSessions.shared.store(record, name: signedIn.name)
        storeHermesAgent(signedIn)
        fetchedProviderModels[.hermes] = nil
        providerModelFetchError[.hermes] = nil
        hermesChatAgent = signedIn.name
        syncHermesPills()
    }

    func removeHermesAgent(named name: String) async {
        var keys = HermesChat.decodeKeys(KeychainStore.shared.get("hermes-agent-keys") ?? "")
        keys[name] = nil
        if keys.isEmpty { KeychainStore.shared.remove("hermes-agent-keys") }
        else { KeychainStore.shared.set("hermes-agent-keys", value: HermesChat.encodeKeys(keys)) }
        await HermesSessions.shared.remove(name: name)
        hermesAgents.removeAll { $0.name == name }   // its conversation is dropped by the list observer
        fetchedProviderModels[.hermes] = nil
        providerModelFetchError[.hermes] = nil
        if hermesChatAgent == name { hermesChatAgent = hermesAgents.first?.name ?? "" }
        if hermesAgents.isEmpty, chatProvider == .hermes { chatProvider = .anthropic }
        syncHermesPills()
        // A "Sign in again" stored while the first removal ran: the row is gone now, so the record goes too.
        await HermesSessions.shared.remove(name: name)
    }

    // The always-on workspace pill (default: VS Code). Persisted.
    @Published var mainPillId: String = PillCatalog.defaultMainPillId {
        didSet { UserDefaults.standard.set(mainPillId, forKey: "mainPill") }
    }

    // Dynamically fetched model lists for the in-chat picker (keyed by provider)
    @Published var fetchedProviderModels: [ChatProvider: [(id: String, label: String)]] = [:]
    @Published var providerModelFetchError: [ChatProvider: String] = [:]
    @Published var loadingProviderModels: Set<ChatProvider> = []

    /// Fetches models for `provider` if not already loaded or loading.
    /// Sets `providerModelFetchError` if the key is absent or the request fails.
    func fetchModelsIfNeeded(for provider: ChatProvider) {
        guard !loadingProviderModels.contains(provider),
              fetchedProviderModels[provider] == nil else { return }
        // Hermes: the picker lists the configured agents (local list, no network call)
        if provider == .hermes {
            if hermesAgents.isEmpty {
                providerModelFetchError[.hermes] = String(localized: "Connect a Hermes agent in Settings → Chat first.")
            } else {
                fetchedProviderModels[.hermes] = hermesAgents.map { (id: $0.name, label: $0.shownName) }
                providerModelFetchError.removeValue(forKey: .hermes)
                if !hermesAgents.contains(where: { $0.name == hermesChatAgent }) {
                    selectHermesAgent(hermesAgents[0].name)
                }
            }
            return
        }
        #if !APPSTORE
        // Through the subscription: Claude Code takes the model aliases; the other tools
        // use the model chosen in them.
        if usesSubscription(provider) {
            providerModelFetchError.removeValue(forKey: provider)
            if provider == .anthropic {
                var models = Self.claudeCodeModels
                if !models.contains(where: { $0.id == claudeModel }) { models.insert((claudeModel, claudeModel), at: 0) }
                fetchedProviderModels[provider] = models
            } else {
                let tool = (provider.installedCLI ?? provider.subscriptionCLIs.first)?.displayName ?? provider.displayName
                fetchedProviderModels[provider] = [("", String(format: String(localized: "chat.subscriptions.default-model"), tool))]
            }
            return
        }
        #endif
        // Local providers: fetch from server URL (no API key needed)
        if provider.isLocal {
            let baseURL = provider == .ollama ? ollamaServerURL : lmstudioServerURL
            let normalised = LocalChat.normaliseURL(baseURL)
            guard !normalised.isEmpty else {
                providerModelFetchError[provider] = provider == .ollama
                    ? String(localized: "Connect Ollama in Settings → Chat first.")
                    : String(localized: "Connect LM Studio in Settings → Chat first.")
                return
            }
            loadingProviderModels.insert(provider)
            providerModelFetchError.removeValue(forKey: provider)
            Task {
                let result = await LocalChat.fetchModelsResult(baseURL: normalised)
                loadingProviderModels.remove(provider)
                switch result {
                case .success(let models) where models.isEmpty:
                    providerModelFetchError[provider] = provider == .ollama
                        ? String(localized: "No models yet. Download one in Ollama first.")
                        : String(localized: "No models yet. Download one in LM Studio first.")
                case .success(let models):
                    fetchedProviderModels[provider] = models
                    let current = provider == .ollama ? ollamaChatModel : lmstudioChatModel
                    if !models.contains(where: { $0.id == current }) {
                        let first = models.first!.id
                        if provider == .ollama { ollamaChatModel = first }
                        else                   { lmstudioChatModel = first }
                    }
                case .failure:
                    providerModelFetchError[provider] = String(localized: "Cannot reach \(normalised). Is the server running?")
                }
            }
            return
        }
        // Remote providers: require API key
        guard let apiKey = KeychainStore.shared.get(provider.keychainKey), !apiKey.isEmpty else {
            providerModelFetchError[provider] = String(localized: "No API key — add it in Settings.")
            return
        }
        loadingProviderModels.insert(provider)
        providerModelFetchError.removeValue(forKey: provider)
        Task {
            let models: [(id: String, label: String)]
            switch provider {
            case .anthropic: models = await ClaudeService.fetchModels(apiKey: apiKey)
            case .google:    models = await ClaudeService.fetchGoogleModels(apiKey: apiKey)
            case .openai:    models = await ClaudeService.fetchOpenAIModels(apiKey: apiKey)
            case .deepseek:  models = await ClaudeService.fetchOpenAICompatibleModels(baseURL: "https://api.deepseek.com/v1", apiKey: apiKey)
            case .qwen:      models = await ClaudeService.fetchOpenAICompatibleModels(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", apiKey: apiKey)
            case .moonshot:  models = await ClaudeService.fetchOpenAICompatibleModels(baseURL: "https://api.moonshot.cn/v1", apiKey: apiKey)
            case .ollama, .lmstudio, .hermes: models = []  // handled above
            case .cursor, .copilot:  models = []  // subscription only, handled above
            }
            loadingProviderModels.remove(provider)
            if models.isEmpty {
                providerModelFetchError[provider] = String(localized: "Failed to load models. Check your API key.")
            } else {
                fetchedProviderModels[provider] = models
                switch provider {
                case .anthropic:
                    if !models.contains(where: { $0.id == claudeModel }) {
                        claudeModel = models.first(where: { $0.id.contains("sonnet") })?.id ?? models.first!.id
                    }
                case .google:
                    if !models.contains(where: { $0.id == googleChatModel }) {
                        googleChatModel = models.first(where: { $0.id.contains("flash") })?.id ?? models.first!.id
                    }
                case .openai:
                    if !models.contains(where: { $0.id == openAIChatModel }) {
                        openAIChatModel = models.first(where: { $0.id.contains("mini") })?.id ?? models.first!.id
                    }
                case .deepseek:
                    if !models.contains(where: { $0.id == deepseekChatModel }) {
                        deepseekChatModel = models.first!.id
                    }
                case .qwen:
                    if !models.contains(where: { $0.id == qwenChatModel }) {
                        qwenChatModel = models.first!.id
                    }
                case .moonshot:
                    if !models.contains(where: { $0.id == moonshotChatModel }) {
                        moonshotChatModel = models.first!.id
                    }
                case .ollama, .lmstudio, .hermes, .cursor, .copilot: break
                }
            }
        }
    }

    /// What the chat header shows for the model: the shown name of the active Hermes agent, else the model id.
    var activeChatModelLabel: String {
        chatProvider == .hermes ? (activeHermesAgent?.shownName ?? "Hermes") : activeChatModel
    }

    /// The models offered when Claude Code answers: its aliases always point at the latest.
    static let claudeCodeModels: [(id: String, label: String)] = [
        ("sonnet", "Claude Sonnet"), ("opus", "Claude Opus"), ("haiku", "Claude Haiku"),
    ]

    /// The model currently active for chat (provider-aware).
    var activeChatModel: String { chatModel(for: chatProvider) }

    /// The model of one provider (a turn keeps the provider it started with).
    func chatModel(for provider: ChatProvider) -> String {
        switch provider {
        case .anthropic: return claudeModel
        case .google:    return googleChatModel
        case .openai:    return openAIChatModel
        case .ollama:    return ollamaChatModel
        case .lmstudio:  return lmstudioChatModel
        case .hermes:    return activeHermesAgent?.name ?? "Hermes"
        case .deepseek:  return deepseekChatModel
        case .qwen:      return qwenChatModel
        case .moonshot:  return moonshotChatModel
        case .cursor, .copilot: return ""
        }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Selected app language ("" = System, else BCP-47 code e.g. "fr")
    @Published var appLanguage: String = {
        let bundleId = Bundle.main.bundleIdentifier ?? "fr.louisraille.NotchBuddy"
        let langs = UserDefaults.standard.persistentDomain(forName: bundleId)?["AppleLanguages"] as? [String]
        return langs?.first ?? ""
    }()

    // Context for prompt (window attach / file)
    @Published var promptContext: PromptContext? = nil

    // Dropped file (set during upload flow)
    @Published var droppedFile: DroppedFile? = nil
    /// A mail prepared by voice: fills the mail card; sent through Apple Mail on the
    /// user's click. nil for the drop-a-file flow.
    @Published var voiceMailDraft: VoiceMailDraft? = nil

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    // Hovering the island opens it (folds shortly after the pointer leaves) — persisted, off by default
    @Published var openOnHover: Bool = false {
        didSet { UserDefaults.standard.set(openOnHover, forKey: "openOnHover") }
    }
    /// A pill other than the one shown finishes or fails: show its card for a moment (#683).
    @Published var alertsFromAllPills: Bool = false {
        didSet { UserDefaults.standard.set(alertsFromAllPills, forKey: "alertsFromAllPills") }
    }
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — persisted
    @Published var absenceInterval: TimeInterval = 3 * 60 {
        didSet { UserDefaults.standard.set(absenceInterval, forKey: "absenceInterval") }
    }

    // Greeting threshold — how long hidden before greeting on reappear (default 2 min)
    var greetThresholdSeconds: TimeInterval = 120 {
        didSet { UserDefaults.standard.set(greetThresholdSeconds, forKey: "greetThreshold") }
    }

    // Hotkey to show island (e.g. ⌘⇧N)
    @Published var hotkeyEnabled: Bool = false {
        didSet { UserDefaults.standard.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }
    var hotkeyFlags: UInt = NSEvent.ModifierFlags([.command, .shift]).rawValue {
        didSet { UserDefaults.standard.set(Int(hotkeyFlags), forKey: "hotkeyFlags") }
    }
    var hotkeyCode: UInt16 = 45 {  // 'n'
        didSet { UserDefaults.standard.set(Int(hotkeyCode), forKey: "hotkeyCode") }
    }

    /// Two Mochis swapping places in a corner (CornerArcView draws both): the main one hides.
    @Published var cornerSwapping = false
    /// The pointer on the compact tile in a corner: the other pills come out of it (CornerBubbles).
    @Published var cornerPeek = false
    /// One of them clicked: once open, the island swaps it with Mochi (CornerArcView).
    @Published var cornerPendingSwap: String? = nil

    /// Where the island lives on its screen: the notch, or a corner (IslandPlacement) — persisted.
    @Published var islandPlacement: IslandPlacement = .notch {
        didSet {
            IslandPlacement.current = islandPlacement
            UserDefaults.standard.set(islandPlacement.rawValue, forKey: "islandPlacement")
        }
    }

    // Screen hosting the island (notch screen by default) — persisted
    @Published var islandDisplay: IslandDisplayChoice = .notch {
        didSet { UserDefaults.standard.set(islandDisplay.storageValue, forKey: "islandDisplay") }
    }

    // Vercel project filter — empty = watch all projects
    @Published var vercelProjectFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(vercelProjectFilter)) {
                UserDefaults.standard.set(data, forKey: "vercelProjectFilter")
            }
        }
    }

    // n8n workflow filter — empty = watch all workflows
    @Published var n8nWorkflowFilter: Set<String> = [] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(n8nWorkflowFilter)) {
                UserDefaults.standard.set(data, forKey: "n8nWorkflowFilter")
            }
        }
    }

    // Active integration pills (main workspace pill excluded). Max 4.
    @Published var activeIntegrations: Set<String> = ["integration_resend", "integration_n8n", "integration_vercel", "integration_github"] {
        didSet {
            if let data = try? JSONEncoder().encode(Array(activeIntegrations)) {
                UserDefaults.standard.set(data, forKey: "activeIntegrations")
            }
            // Clear stale GitHub data when the integration is disabled
            if !activeIntegrations.contains("integration_github") && oldValue.contains("integration_github") {
                githubPulse = nil
                githubActivity = nil
            }
        }
    }

    // Pending API result
    @Published var searchResult: SearchResult? = nil

    // Vercel deployments (populated by VercelPoller)
    @Published var vercelDeployments: [VercelDeployment] = []

    // Resend emails (populated by ResendPoller)
    @Published var resendEmails: [ResendEmail] = []
    @Published var resendTotal: Int? = nil

    // GitHub stats + pulse + activity (populated by GithubPoller)
    @Published var githubStats: GitHubStats? = nil
    @Published var githubPulse: GitHubPulse? = nil
    @Published var githubActivity: GitHubActivity? = nil

    // Stripe (populated by StripePoller)
    @Published var stripePayments: [StripePayment] = []
    @Published var stripeBalance: Int = 0           // raw balance in cents
    @Published var stripeDisplayBalance: Int = 0    // animated balance target
    @Published var stripeCurrency: String = "eur"
    @Published var stripeLoaded: Bool = false       // true after first successful poll
    @Published var stripeError: String? = nil      // last API error (nil = ok)

    // Cal.com (populated by CalcomPoller)
    @Published var calcomBookings: [CalcomBooking] = []
    @Published var calcomLoaded: Bool = false
    @Published var calcomError: String? = nil

    // Notion (populated by NotionPoller)
    @Published var notionPages: [NotionPage] = []
    @Published var notionLoaded: Bool = false
    @Published var notionError: String? = nil

    // n8n — the last executions, newest first (for the iPhone; the notch shows only the latest)
    @Published var n8nRuns: [N8nRun] = []

    // Chat conversation history

    #if !APPSTORE
    // cmux as the main workspace: the reply / new chat prompt, per session transcripts, settings.
    @Published var cmuxPrompt: CmuxPromptMode? = nil
    /// True only while `IslandWindowController.openCmuxPrompt` switches to the prompt view.
    var cmuxOpeningPrompt = false
    /// 0, 1 or 2 and more: how many messages the timeline of the session on screen holds, as far as the height of the
    /// reply view tells. Written by `CmuxTimelines` only when that changes, so an event of a session redraws nothing here.
    @Published var cmuxTimelineBucket = 0
    /// The session the user picked in the reply header, per pill id. Memory only, until that session closes.
    @Published var cmuxReplyChoice: [String: String] = [:]
    /// Bumped when the sessions of a workspace change, so the reply header and cards redraw.
    @Published var cmuxRevision = 0
    @Published var cmuxNotice: String? = nil {
        didSet { if !settingCmuxFailure { cmuxNoticeFailure = nil; cmuxNoticeOffersCmux = false; cmuxNoticeOwner = nil } }
    }
    /// The reply the notice is about (a failed send). The reply view shows a notice with an owner only when it
    /// renders that very reply; a notice with no owner belongs to the prompt in general.
    @Published private(set) var cmuxNoticeOwner: PromptSlot.Content? = nil
    /// What `CmuxPromptView` renders now. Set and cleared by that view; a send that ends after the view is gone
    /// uses it to tell whether its reply is still on screen.
    var cmuxRenderedContent: PromptSlot.Content? = nil
    /// The notice is the "started in cmux" one of a command line launcher: it offers the Open cmux action.
    @Published private(set) var cmuxNoticeOffersCmux = false
    func showCmuxStarted(_ text: String) {
        cmuxNotice = text
        cmuxNoticeOffersCmux = true
    }
    /// Which cmux failure the notice shows, when it is one. The prompt view tells them apart by this case,
    /// never by comparing the translated text.
    @Published private(set) var cmuxNoticeFailure: CmuxControl.Failure? = nil
    private var settingCmuxFailure = false
    func showCmuxFailure(_ failure: CmuxControl.Failure, owner: PromptSlot.Content? = nil) {
        settingCmuxFailure = true
        cmuxNotice = failure.message
        cmuxNoticeFailure = failure
        cmuxNoticeOffersCmux = false
        cmuxNoticeOwner = owner
        settingCmuxFailure = false
    }
    @Published var cmuxBusy = false
    @Published var cmuxRecentFolders: [String] = UserDefaults.standard.stringArray(forKey: "cmuxRecentFolders") ?? [] {
        didSet { UserDefaults.standard.set(cmuxRecentFolders, forKey: "cmuxRecentFolders") }
    }
    @Published var cmuxDefaultFolder: String = UserDefaults.standard.string(forKey: "cmuxDefaultFolder") ?? "" {
        didSet { UserDefaults.standard.set(cmuxDefaultFolder, forKey: "cmuxDefaultFolder") }
    }
    /// Launch command per launcher, by `CmuxLauncher.Id` raw value. Loaded once, with the migration of the
    /// old single command (see `CmuxLauncher.resolvedCommand`). Nothing is written at load: a value is
    /// stored only when the user edits it (`setCmuxCommand`).
    @Published var cmuxLaunchCommands: [String: String] = {
        let defaults = UserDefaults.standard
        var out: [String: String] = [:]
        for l in CmuxLauncher.all {
            let value = l.resolvedCommand(stored: defaults.string(forKey: l.defaultsKey),
                                          legacy: defaults.string(forKey: CmuxLauncher.legacyDefaultsKey))
            out[l.id.rawValue] = value
        }
        return out
    }()

    /// A valid command typed by the user: kept in memory and stored under the launcher's own key.
    func setCmuxCommand(_ value: String, for launcher: CmuxLauncher) {
        guard CmuxRouting.isValidLaunchCommand(value) else { return }
        cmuxLaunchCommands[launcher.id.rawValue] = value
        UserDefaults.standard.set(value, forKey: launcher.defaultsKey)
    }

    func cmuxCommand(for launcher: CmuxLauncher) -> String {
        cmuxLaunchCommands[launcher.id.rawValue] ?? launcher.defaultCommand
    }

    /// Closes the cmux prompt (reply / new chat) and its notice. Drafts stay in `promptDrafts`.
    func clearCmuxPrompt() {
        if cmuxPrompt != nil { cmuxPrompt = nil }
        if cmuxNotice != nil { cmuxNotice = nil }
    }
    #endif

    /// Messages shown in the prompt view, for its height: the cmux transcript or new chat when one is
    /// open, else the normal chat. Equal to `chatHistory.count` whenever cmux is not involved.
    var promptMessageCount: Int {
        #if !APPSTORE
        switch cmuxPrompt {
        case .reply(let id)?: return CmuxTimelines.shared.messageCount(for: HookServer.shared.cmuxReplyTarget(for: id) ?? id)
        case .newChat?:       return 1
        case nil:             break
        }
        #endif
        return chatHistory.count
    }

    // MARK: Chat height (the user can stretch the chat card; see ChatHeight)

    /// Height the user chose for the chat; nil = never stretched. Persisted, raw (clamped when read).
    @Published private(set) var chatStretchedHeight: CGFloat? = ChatHeight.storedValue(
        from: UserDefaults.standard.double(forKey: ChatHeight.defaultsKey))
    /// Tallest the chat may be on the screen the island is on; the window controller keeps it current.
    @Published var chatMaxHeight: CGFloat = ChatHeight.defaultCap
    /// Height of the island panel (560 until the chat has been stretched); the window controller keeps it current.
    @Published var panelHeight: CGFloat = ChatHeight.basePanelHeight
    /// True while the grip is being dragged: the island follows the pointer without animation and stays open.
    @Published var chatResizing = false
    /// Set when the pointer reaches the grip: the panel grows before the mouse goes down, not inside the drag.
    @Published var chatRoomRequested = false

    /// Height of the chat card for the current messages and the user's stretch.
    var chatPromptHeight: CGFloat {
        ChatHeight.resolve(messageCount: promptMessageCount, stored: chatStretchedHeight, maximum: chatMaxHeight)
    }
    var chatCanStretch: Bool {
        ChatHeight.canStretch(messageCount: promptMessageCount, maximum: chatMaxHeight)
    }
    var chatIsStretched: Bool {
        ChatHeight.isStretched(messageCount: promptMessageCount, stored: chatStretchedHeight, maximum: chatMaxHeight)
    }

    /// Sets the stretch; `persist: false` while dragging (written once when the drag ends).
    func setChatStretch(_ height: CGFloat?, persist: Bool = true) {
        chatStretchedHeight = height
        guard persist else { return }
        if let height { UserDefaults.standard.set(Double(height), forKey: ChatHeight.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: ChatHeight.defaultsKey) }
    }

    /// Double click on the grip, or the header button.
    func toggleChatStretch() {
        setChatStretch(ChatHeight.toggled(messageCount: promptMessageCount,
                                          stored: chatStretchedHeight, maximum: chatMaxHeight))
    }

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    /// Height of the island while the whole text of a long Hermes command is read (nil: the card of every day).
    @Published var approvalReadingHeight: CGFloat? = nil {
        didSet { ApprovalReadingLayout.height = approvalReadingHeight }
    }

    // Pending AskUserQuestion from Claude Code hook
    @Published var pendingQuestion: AskQuestion? = nil {
        didSet { QuestionLayout.height = pendingQuestion?.estimatedIslandHeight }
    }

    /// Every AskUserQuestion waiting for an answer, oldest first: the first one is on the
    /// card (`pendingQuestion`). Written by HookServer only; empty for a demo question.
    @Published var waitingQuestions: [QueuedQuestion] = []

    // Per-pill flat list of FileDiffs, in order of reception.
    // Not @Published — steps[] changes already trigger redraws.
    var sessionDiffs: [String: [FileDiff]] = [:]
    private var sessionDiffTimers: [String: DispatchWorkItem] = [:]
    // Monotonically increasing — never reset, not even in clearSessionDiffs.
    private var nextDiffId: Int = 0

    @discardableResult
    func appendSessionDiff(_ diff: FileDiff, for pillId: String) -> Int {
        var d = diff
        d.id = nextDiffId
        nextDiffId += 1
        if sessionDiffs[pillId] == nil { sessionDiffs[pillId] = [] }
        sessionDiffs[pillId]!.append(d)
        // Keep at most 50 diffs per pill; drop oldest first
        while sessionDiffs[pillId]!.count > 50 {
            sessionDiffs[pillId]!.removeFirst()
        }
        resetSessionDiffTimer(for: pillId)
        return d.id
    }

    func clearSessionDiffs(for pillId: String) {
        sessionDiffTimers[pillId]?.cancel()
        sessionDiffTimers.removeValue(forKey: pillId)
        sessionDiffs.removeValue(forKey: pillId)
        // nextDiffId intentionally NOT reset — ids remain unique across sessions
    }

    private func resetSessionDiffTimer(for pillId: String) {
        sessionDiffTimers[pillId]?.cancel()
        // The closure is MainActor-isolated (AppState is @MainActor): it must run on the main
        // queue. Scheduled on a global queue, Swift 6's isolation check traps and the app quits.
        let work = DispatchWorkItem { [weak self] in
            self?.clearSessionDiffs(for: pillId)
        }
        sessionDiffTimers[pillId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600, execute: work)
    }

    #if !APPSTORE
    @Published var musicPlaying: Bool = false
    @Published var musicAutomationDenied: Bool = false

    // Voice command result (shown in VoiceResultView for ~2 s, then cleared by IWC)
    @Published var voiceResult: VoiceActionResult? = nil
    /// True from "OK Coucou" until Coucou has finished answering (island stays compact).
    /// Drives Mochi's single attentive pose for the whole exchange.
    @Published var voiceActive = false
    /// Listening / thinking / speaking — drives per-frame Mochi animations.
    /// Set by IslandWindowController; read by BotCanvasView each display frame.
    @Published var voiceSubState: BotVoiceSubState = .none
    #endif

    // Claude plan gauge (from statusline hook)
    @Published var claudePlanUsage: PlanUsage? = nil {
        didSet {
            if let u = claudePlanUsage,
               let data = try? JSONEncoder().encode(u) {
                UserDefaults.standard.set(data, forKey: "claudePlanUsage")
            }
        }
    }

    // Plan gauge: show pill in notch header — persisted
    #if !APPSTORE
    @Published var showPlanInNotch: Bool = false {
        didSet { UserDefaults.standard.set(showPlanInNotch, forKey: "showPlanInNotch") }
    }
    // In-memory plan usage override for demo mode. Never persisted. Set by DemoEngine.
    @Published var demoPlanUsageOverride: PlanUsage? = nil
    // Cached relay-installed state — updated at launch, after install/uninstall, on Settings open
    @Published var planRelayInstalled: Bool = false
    // Transient — reset when island closes or view changes
    @Published var showingPlanDetail: Bool = false

    // Codex plan gauge (from `codex app-server`) — fetched when the pill shows
    @Published var showCodexPlanInNotch: Bool = false {
        didSet { UserDefaults.standard.set(showCodexPlanInNotch, forKey: "showCodexPlanInNotch") }
    }
    @Published var codexPlanUsage: CodexPlanUsage? = nil
    // Which card showingPlanDetail opens
    @Published var planDetailIsCodex: Bool = false

    /// Rate-limited on the attempt, not only on success: without Codex installed or
    /// signed in, every appearance of the pill used to spawn `codex app-server` again.
    private static var lastCodexAttempt: Date = .distantPast
    private static var codexFetchInFlight = false

    func refreshCodexPlanUsage() {
        if let u = codexPlanUsage, Date().timeIntervalSince(u.updatedAt) < 60 { return }
        guard !Self.codexFetchInFlight, Date().timeIntervalSince(Self.lastCodexAttempt) > 60 else { return }
        Self.codexFetchInFlight = true
        Self.lastCodexAttempt = Date()
        Task {
            if let u = await CodexPlanGauge.fetch() { codexPlanUsage = u }
            Self.codexFetchInFlight = false
        }
    }

    func refreshPlanRelayState() {
        planRelayInstalled = HookServer.statusLineInstalled()
    }
    #endif

    // MARK: - Init (loads persisted settings)

    private init() {
        let ud = UserDefaults.standard

        if let v = ud.object(forKey: "soundEnabled") as? Bool   { soundEnabled = v }
        if let v = ud.object(forKey: "soundVolume")  as? Double { soundVolume  = v }
        mochiOutfitSelection = Outfit.stored
        pillColors = PillColors.stored
        if let v = ud.string(forKey: "claudeModel"),
           !v.trimmingCharacters(in: .whitespaces).isEmpty { claudeModel = v }
        if let v = ud.string(forKey: "chatSharedProvider"), let p = ChatProvider(rawValue: v), p != .hermes { lastSharedProvider = p }
        if let v = ud.string(forKey: "chatProvider"), let p = ChatProvider(rawValue: v) { chatProvider = p }
        // didSet does not run in init: seed the shared provider from the one loaded when it was never stored.
        if lastSharedProvider == nil, chatProvider != .hermes { lastSharedProvider = chatProvider }
        if let v = ud.string(forKey: "googleChatModel"), !v.isEmpty { googleChatModel = v }
        if let v = ud.string(forKey: "openAIChatModel"), !v.isEmpty { openAIChatModel = v }
        if let v = ud.string(forKey: "ollamaChatModel"), !v.isEmpty { ollamaChatModel = v }
        if let v = ud.string(forKey: "lmstudioChatModel"), !v.isEmpty { lmstudioChatModel = v }
        if let v = ud.string(forKey: "deepseekChatModel"), !v.isEmpty { deepseekChatModel = v }
        if let v = ud.string(forKey: "qwenChatModel"),     !v.isEmpty { qwenChatModel     = v }
        if let v = ud.string(forKey: "moonshotChatModel"), !v.isEmpty { moonshotChatModel = v }
        if let v = ud.string(forKey: "ollamaServerURL"), !v.isEmpty { ollamaServerURL = v }
        if let v = ud.string(forKey: "lmstudioServerURL"), !v.isEmpty { lmstudioServerURL = v }
        if let v = ud.string(forKey: "hermesAgents"), !v.isEmpty { hermesAgents = HermesChat.decodeAgents(v) }
        if let v = ud.string(forKey: "hermesChatAgent"), !v.isEmpty { hermesChatAgent = v }
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "openOnHover") as? Bool { openOnHover = v }
        if let v = ud.object(forKey: "alertsFromAllPills") as? Bool { alertsFromAllPills = v }
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
        if let v = ud.string(forKey: "islandDisplay") { islandDisplay = IslandDisplayChoice(storageValue: v) }
        if let v = ud.string(forKey: "islandPlacement"), let p = IslandPlacement(rawValue: v) {
            islandPlacement = p
            IslandPlacement.current = p   // didSet doesn't run from init
        }
        if let d = ud.data(forKey: "vercelProjectFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { vercelProjectFilter = Set(a) }
        if let d = ud.data(forKey: "n8nWorkflowFilter"),
           let a = try? JSONDecoder().decode([String].self, from: d) { n8nWorkflowFilter = Set(a) }
        if let d = ud.data(forKey: "activeIntegrations"),
           let a = try? JSONDecoder().decode([String].self, from: d) { activeIntegrations = Set(a) }
        if let v = ud.string(forKey: "mainPill"), !v.isEmpty,
           PillCatalog.available.contains(where: { $0.id == v && $0.category == .workspace && !$0.comingSoon }) {
            mainPillId = v
        }
        if let d = ud.data(forKey: "claudePlanUsage"),
           let u = try? JSONDecoder().decode(PlanUsage.self, from: d) { claudePlanUsage = u }
        #if !APPSTORE
        if let v = ud.object(forKey: "showPlanInNotch") as? Bool { showPlanInNotch = v }
        if let v = ud.object(forKey: "showCodexPlanInNotch") as? Bool { showCodexPlanInNotch = v }
        planRelayInstalled = HookServer.statusLineInstalled()
        #endif

        // Sync SoundEngine volume on launch
        SoundEngine.shared.volume = Float(soundVolume)

        // Always load integration pills
        loadIntegrationTasks()
    }

    // MARK: - Computed

    var focusTask: AgentTask? {
        tasks.first { $0.id == focusId } ?? tasks.first
    }

    /// The places beside the focused pill (4, SessionBoard.slots): the pills as they come, a
    /// waiting one (a session popped out of its client's pill, or a pill waiting itself) in the
    /// place of an idle or finished pill, and "+N" for the waiting ones left over.
    var gridSlots: [SessionBoard.Slot] {
        SessionBoard.slots(tasks.filter { $0.id != focusId }.map {
            SessionBoard.Cell(id: $0.id, state: $0.state, poppedOut: $0.id != $0.pill)
        })
    }

    var effectiveState: BotState {
        stateOverride ?? focusTask?.state ?? .idle
    }

    // MARK: - Task management

    func addTask(_ task: AgentTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        if focusId == nil { focusId = task.id }
        syncMode()
        syncView()
    }

    func removeTask(id: String) {
        // mainPillId: always reset, never remove (the active workspace tool)
        // activeIntegrations: also reset (user declared it active, keep it as idle)
        let isProtected = id == mainPillId
        let isActiveDecl = PillCatalog.definition(for: id) != nil && activeIntegrations.contains(id)
        if isProtected || isActiveDecl {
            if let idx = tasks.firstIndex(where: { $0.id == id }) {
                let catalogName = PillCatalog.definition(for: id)?.name
                tasks[idx].state      = .idle
                tasks[idx].steps      = []
                tasks[idx].stepIndex  = 0
                tasks[idx].pillBadge  = nil
                if let n = catalogName { tasks[idx].name = n }
            }
            return
        }
        // Undeclared or declared-but-not-active: remove
        tasks.removeAll { $0.id == id }
        if focusId == id { focusId = mainPillId }
        syncMode()
        syncView()
    }

    func updateTask(id: String, state: BotState) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = state
    }

    // Prompt slot state (the logic is in PromptSlotState.swift): stored properties cannot live in an extension.
    /// Set while `setFocus` moves the focus itself and applies the slot rule right after.
    var applyingFocusEffect = false
    /// Drafts of the prompt slot by content. Memory only, capped. Not published: the views write it on every
    /// keystroke; a writer outside the views uses `writeDraft` so the open view picks the text up.
    var promptDrafts = PromptDrafts()
    /// First prompts of a new chat that could not go back to their field (see PromptStash). Memory only.
    var promptStash = PromptStash()
    /// Bumped by `writeDraft` only, never by the typing of the user: an open view that sees it reloads its draft.
    @Published var draftRevision = 0
    /// Bumped by the writers that end a launch (timeout, folder match, failed first prompt): only these lower `launching`.
    @Published var launchEndedRevision = 0

    func setPillBadge(_ badge: PillBadge, for id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].pillBadge = badge
    }

    /// Called on main thread after each GitHub pulse poll. Fires badge + sound based on events.
    func handleGitHubEvents(_ events: [GitHubEvent]) {
        guard !events.isEmpty else { return }
        // Priority: error > question (reviewRequested) > finish (ciPassed)
        var level = 0          // 0 = none, 1 = finish, 2 = question, 3 = error
        var badge: PillBadge?
        var sound: String?
        for event in events {
            switch event {
            case .ciFailed, .mainFailed:
                if level < 3 { level = 3; badge = .error;    sound = "error"    }
            case .reviewRequested:
                if level < 2 { level = 2; badge = .finished; sound = "question" }
            case .ciPassed:
                if level < 1 { level = 1; badge = .finished; sound = "finish"   }
            }
        }
        // Only set badge when the GitHub pill is not currently in focus
        if let b = badge, focusId != "integration_github" { setPillBadge(b, for: "integration_github") }
        if let s = sound { SoundEngine.shared.play(s) }
    }

    func syncMode() {
        // If no tasks and not expanded/peek, go hidden
        if tasks.isEmpty && mode == .compact {
            mode = .hidden
        } else if !tasks.isEmpty && mode == .hidden && isPresent {
            mode = .compact
        }
    }

    func syncView() {
        guard mode == .expanded else { return }
        if view == .empty && !tasks.isEmpty { view = .overview }
        else if view == .overview && tasks.isEmpty { view = .empty }
    }

    /// Load catalog pills into tasks, respecting activeIntegrations. Safe to call multiple times.
    func loadIntegrationTasks() {
        let catalog = PillCatalog.available
        // Sanitize: remove saved IDs not in catalog
        let catalogIds = Set(catalog.map { $0.id })
        activeIntegrations = activeIntegrations.filter { catalogIds.contains($0) }
        // Validate mainPillId: must be a non-comingSoon workspace pill in the catalog
        if !PillCatalog.available.contains(where: { $0.id == mainPillId && $0.category == .workspace && !$0.comingSoon }) {
            mainPillId = PillCatalog.defaultMainPillId
        }
        // mainPillId must never be in activeIntegrations (migration + invariant)
        activeIntegrations.remove(mainPillId)
        for def in catalog {
            // mainPillId always loads; activeIntegrations load
            let shouldLoad = def.id == mainPillId || activeIntegrations.contains(def.id)
            let loaded = tasks.contains(where: { $0.id == def.id })
            if shouldLoad && !loaded {
                let task = AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: .idle, steps: [], source: def.source, isIntegration: true)
                tasks.append(task)
            }
            if !shouldLoad && loaded {
                tasks.removeAll { $0.id == def.id }
            }
        }
        sortTasksByCatalog()
        syncHermesPills()
        if focusId == nil { focusId = mainPillId }
        syncMode()
    }

    // MARK: Hermes agent pills (one per connected agent, not in the catalog, not sessions)

    /// Creates the pill of each connected agent, drops the pill of a removed one and puts them right
    /// after the main pill. Pills are never touched by hook events: their ids match no hook agent.
    func syncHermesPills() {
        let plan = HermesPills.reconcile(existingIds: tasks.map { $0.id }, agents: hermesAgents.map { $0.name })
        for id in plan.remove {
            tasks.removeAll { $0.id == id }
            if focusId == id { focusId = mainPillId }
        }
        var taken = Set(tasks.filter { HermesPills.isTaskId($0.id) }.map { $0.color })
        for entry in plan.add {
            let look = PillLook.appearance(key: String(entry.id.dropFirst(HermesPills.taskPrefix.count)), takenColors: taken)
            taken.insert(look.color)
            let shown = hermesAgents.first { $0.name == entry.name }?.shownName ?? entry.name
            var task = AgentTask(id: entry.id, name: shown, color: look.color, state: .idle, steps: [], source: .agent)
            if look.eye != "pill" { task.miniEye = EyeShape(rawValue: look.eye) }
            tasks.append(task)
        }
        let ids = HermesPills.taskIds(for: hermesAgents.map { $0.name })
        for agent in hermesAgents {
            guard let id = ids[agent.name], let i = tasks.firstIndex(where: { $0.id == id }) else { continue }
            let line = HermesPills.subtitle(profile: agent.profile, baseURL: agent.baseURL)
            if tasks[i].subtitle != line { tasks[i].subtitle = line }
            if tasks[i].name != agent.shownName { tasks[i].name = agent.shownName }
        }
        placeHermesPills()
        syncMode()
        syncView()
    }

    /// Keeps the Hermes pills (in connection order) right after the main pill, ahead of cmux sessions.
    func placeHermesPills() {
        let ids = HermesPills.taskIds(for: hermesAgents.map { $0.name })
        let hermes = hermesAgents.compactMap { a in ids[a.name].flatMap { id in tasks.first { $0.id == id } } }
        guard !hermes.isEmpty else { return }
        var rest = tasks.filter { !HermesPills.isTaskId($0.id) }
        let at = (rest.firstIndex { $0.id == mainPillId }).map { $0 + 1 } ?? 0
        rest.insert(contentsOf: hermes, at: at)
        if rest.map({ $0.id }) != tasks.map({ $0.id }) { tasks = rest }
    }

    /// Running chat turns per agent name. The pill stays thinking until the last of them ends.
    /// Published: the last message of a chat is drawn as finished when the count drops, with or without a pill row.
    @Published private(set) var hermesTurnsRunning: [String: Int] = [:]

    /// A turn starts (`true`) or ends (`false`) for an agent: the pill is thinking while any turn runs.
    func setHermesPillBusy(agentName: String, _ busy: Bool) {
        let count = max(0, (hermesTurnsRunning[agentName] ?? 0) + (busy ? 1 : -1))
        hermesTurnsRunning[agentName] = count == 0 ? nil : count
        guard let id = HermesPills.taskIds(for: hermesAgents.map { $0.name })[agentName],
              let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let target: BotState = count > 0 ? .thinking : .idle
        if tasks[i].state != target { tasks[i].state = target }
    }

    /// The overview card of each Hermes agent across its turns (see `HermesCard`): display only, never persisted.
    private var hermesCards: [String: HermesCard] = [:]

    /// A turn of this agent starts: the card starts from scratch. The returned number goes with every later call of the turn.
    func beginHermesPillTurn(agentName: String) -> Int {
        var card = hermesCards[agentName] ?? HermesCard()
        let turn = card.start()
        hermesCards[agentName] = card
        showHermesCard(agentName)
        return turn
    }

    /// The rows of a running turn reach the card of that agent's pill, as ticker lines. Only what the chat already
    /// shows; the pill of another agent is never touched, and only the newest running turn writes.
    func setHermesPillRows(agentName: String, turn: Int, segments: [ChatSegment]) {
        guard hermesCards[agentName] != nil else { return }
        hermesCards[agentName]?.rows(turn, HermesTicker.lines(from: segments))
        showHermesCard(agentName)
    }

    /// A turn of this agent ends. After a success the rows stay (the last one is the answer); a failed or cancelled
    /// turn, or one whose conversation was cleared, leaves no row.
    func endHermesPillTurn(agentName: String, turn: Int, finished: Bool) {
        guard hermesCards[agentName] != nil else { return }
        hermesCards[agentName]?.end(turn, finished: finished)
        showHermesCard(agentName)
    }

    /// The conversation of this agent was cleared: the card empties now, running turns write nothing more.
    func clearHermesPillCard(agentName: String) {
        guard hermesCards[agentName] != nil else { return }
        hermesCards[agentName]?.clear()
        showHermesCard(agentName)
    }

    private func showHermesCard(_ agentName: String) {
        guard let card = hermesCards[agentName],
              let id = HermesPills.taskIds(for: hermesAgents.map { $0.name })[agentName],
              let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        // The index goes with the lines, also for a pill that was created with the default 0 and no row.
        let index = HermesTicker.stepIndex(forCount: card.lines.count)
        if tasks[i].steps != card.lines { tasks[i].steps = card.lines }
        if tasks[i].stepIndex != index { tasks[i].stepIndex = index }
    }

    /// Task id of the pill of the active Hermes agent, when the Hermes chat is the selected one.
    var activeHermesPillId: String? {
        guard chatProvider == .hermes, let agent = activeHermesAgent else { return nil }
        return HermesPills.taskIds(for: hermesAgents.map { $0.name })[agent.name]
    }

    /// The pill of the active agent carries an answer the user has not seen yet.
    var hermesHasUnseenAnswer: Bool {
        guard let id = activeHermesPillId else { return false }
        return tasks.first { $0.id == id }?.pillBadge == .finished
    }

    /// A chat turn of the active agent is running.
    var hermesTurnRunning: Bool {
        guard chatProvider == .hermes, let agent = activeHermesAgent else { return false }
        return (hermesTurnsRunning[agent.name] ?? 0) > 0
    }

    /// An approval or question card is on screen, or cmux cards wait for their turn.
    var alertCardPending: Bool {
        if pendingApproval != nil || pendingQuestion != nil { return true }
        #if !APPSTORE
        if HookServer.shared.hasQueuedCmuxCards { return true }
        #endif
        return false
    }

    /// The island should open on the Hermes chat rather than the overview.
    var opensOnHermesChat: Bool {
        PromptSlot.reopensOnHermesChat(focus: focusPill, activeAgent: chatProvider == .hermes ? activeHermesAgent?.name : nil,
                                       unseenAnswer: hermesHasUnseenAnswer, turnRunning: hermesTurnRunning,
                                       alertPending: alertCardPending)
    }

    /// The cmux prompt occupies the prompt slot, or is being opened (the view changes before `cmuxPrompt` is set).
    var cmuxPromptIsOpenOrOpening: Bool {
        #if !APPSTORE
        return cmuxPrompt != nil || cmuxOpeningPrompt
        #else
        return false
        #endif
    }

    /// Set when an announced answer takes the screen: it is not the user's own opening of the chat, so it must not
    /// take keyboard focus, and the delayed collapses of earlier alerts must not close it right away.
    private(set) var hermesAnnounceAt: Date = .distantPast
    /// The panel must not become key for an announced answer (keystrokes meant for another app).
    var hermesAnnounceBlocksKey: Bool { Date().timeIntervalSince(hermesAnnounceAt) < 1 }
    /// A pending collapse from an earlier alert (approval note 3 s, finished pin 5.2 s) must leave an announced answer open.
    var hermesAnnounceHoldsIsland: Bool { Date().timeIntervalSince(hermesAnnounceAt) < 8 }

    /// The badge of the answer goes away once the chat with that agent is on screen.
    private func clearHermesBadgeIfChatShown() {
        guard let id = activeHermesPillId,
              let i = tasks.firstIndex(where: { $0.id == id }), tasks[i].pillBadge != nil else { return }
        guard HermesAnnounce.chatIsShown(expanded: mode == .expanded, viewIsChat: view == .prompt,
                                         cmuxPromptOpen: cmuxPromptIsOpenOrOpening) else { return }
        tasks[i].pillBadge = nil
    }

    /// A finished turn: tells the user when the chat is not on screen. Sound and badge always, the island
    /// comes back to `target` (the chat, or the error note) unless an approval or question card holds the screen.
    @discardableResult
    func announceHermesTurn(agentName: String, failed: Bool, view target: IslandView) -> HermesAnnounce.Outcome {
        let ofThisAgent = activeConversationID == .hermes(agentName)
        let outcome = HermesAnnounce.decide(expanded: mode == .expanded, viewIsChat: view == .prompt,
                                            cmuxPromptOpen: cmuxPromptIsOpenOrOpening, alertPending: alertCardPending,
                                            chatIsOfThisAgent: ofThisAgent)
        guard outcome != .none else { return outcome }
        SoundEngine.shared.play(failed ? "error" : "finish")
        let pillId = HermesPills.taskIds(for: hermesAgents.map { $0.name })[agentName]
        // An error that takes the screen is read on the spot: no badge left behind.
        if let pillId, let i = tasks.firstIndex(where: { $0.id == pillId }), !(failed && outcome == .expand) {
            tasks[i].pillBadge = failed ? .error : .finished
        }
        guard outcome == .expand else { return outcome }
        // The island comes back on the chat of the agent that answered, not on whatever was selected.
        if !ofThisAgent, hermesAgents.contains(where: { $0.name == agentName }) {
            chatProvider = .hermes
            hermesChatAgent = agentName
        }
        if let pillId, tasks.contains(where: { $0.id == pillId }) { focusId = pillId }
        hermesAnnounceAt = Date()
        if mode == .expanded { view = target }
        else { NotificationCenter.default.post(name: .hermesAnnounceExpand, object: target) }
        return outcome
    }

    /// Toggle a catalog pill on/off.
    /// mainPillId: never toggleable (change via the Main picker first).
    /// Max 4 non-main pills active at once.
    /// Switch the always-on workspace pill. Mirrors what the Settings Picker does.
    func setMainPill(_ id: String) {
        guard PillCatalog.available.contains(where: {
            $0.id == id && $0.category == .workspace && !$0.comingSoon
        }) else { return }
        mainPillId = id
        activeIntegrations.remove(id)
        loadIntegrationTasks()
        setFocus(id)
    }

    func toggleIntegration(_ id: String) {
        guard id != mainPillId else { return }
        guard PillCatalog.available.contains(where: { $0.id == id }) else { return }
        if activeIntegrations.contains(id) {
            activeIntegrations.remove(id)
            tasks.removeAll { $0.id == id }
            if focusId == id { focusId = mainPillId }
        } else {
            guard activeIntegrations.count < 4 else { return }
            activeIntegrations.insert(id)
            if let def = PillCatalog.available.first(where: { $0.id == id }),
               !tasks.contains(where: { $0.id == id }) {
                let task = AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: .idle, steps: [], source: def.source, isIntegration: true)
                tasks.append(task)
                sortTasksByCatalog()
            }
        }
        syncMode()
    }

    /// Sort tasks so catalog pills are in catalog order, undeclared pills sit right after
    /// integration_claude (matching HookServer insertion behaviour), and the rest follows.
    private func sortTasksByCatalog() {
        let order = PillCatalog.available.enumerated()
            .reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        let catalogPills    = tasks.filter { order[$0.id] != nil }
        let undeclaredPills = tasks.filter { order[$0.id] == nil }
        let sortedCatalog   = catalogPills.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        if let claudeIdx = sortedCatalog.firstIndex(where: { $0.id == "integration_claude" }) {
            var result: [AgentTask] = Array(sortedCatalog[...claudeIdx])
            result.append(contentsOf: undeclaredPills)
            if claudeIdx + 1 < sortedCatalog.count {
                result.append(contentsOf: sortedCatalog[(claudeIdx + 1)...])
            }
            tasks = result
        } else {
            tasks = undeclaredPills + sortedCatalog
        }
    }

}

// MARK: - Supporting types

enum PromptContext {
    case window(appName: String, title: String, url: String?)
    case file(name: String, fileURL: URL?)
}

struct VoiceMailDraft: Equatable {
    var to: String
    var subject: String
    var body: String
}

struct DroppedFile {
    var url: URL
    var name: String
}

struct SearchResult {
    var title: String
    var items: [ResultItem]
    var note: String?
}

struct ResultItem {
    var label: String
    var detail: String
    var url: String?
}

// MARK: - Vercel

struct VercelDeployment: Identifiable {
    let id: String
    let projectName: String
    let url: String
    let state: String        // "READY", "ERROR", "CANCELED"
    let createdAt: Date
    let commitMessage: String?
    let branch: String?

    var isSuccess: Bool { state == "READY" }
    var statusLabel: String { isSuccess ? String(localized: "Ready") : (state == "CANCELED" ? String(localized: "Canceled") : String(localized: "Error")) }
    var isJustNow: Bool { Date().timeIntervalSince(createdAt) < 60 }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return String(localized: "just now") }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Publish only on change

extension AppState {
    /// A @Published set notifies every view that observes AppState, even with the same
    /// value: pollers use this so an unchanged answer redraws nothing.
    func setIfChanged<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

// MARK: - Resend

struct ResendEmail: Identifiable {
    let id: String
    let to: [String]
    let subject: String
    let createdAt: Date
    let lastEvent: String   // "delivered", "bounced", "complained", "opened", etc.

    var recipientShort: String {
        guard let first = to.first else { return "?" }
        return first.components(separatedBy: "@").first ?? first
    }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return String(localized: "just now") }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
    var isDelivered: Bool { lastEvent == "delivered" }
}

// MARK: - GitHub

struct GitHubStats {
    let totalRepos: Int
    let totalStars: Int
}

// MARK: - Stripe

struct StripePayment: Identifiable, Equatable {
    let id: String
    let amount: Int         // in cents/smallest unit
    let currency: String
    let description: String?
    let createdAt: Date
    let status: String      // "succeeded", "pending", "failed"

    var amountFormatted: String { String(format: "%.2f", Double(amount) / 100.0) }
    var isSuccess: Bool { status == "succeeded" }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return String(localized: "just now") }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Cal.com

struct CalcomBooking: Identifiable, Equatable {
    let id: Int
    let title: String
    let startTime: Date
    let endTime: Date
    let status: String
    let attendeeName: String?
    let attendeeEmail: String?
    let attendeeNotes: String?

    var isActive: Bool { status == "ACCEPTED" || status == "PENDING" }
    var timeLabel: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: startTime)
    }
    var dayKey: String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: startTime)
        return "\(c.year!)-\(String(format: "%02d", c.month!))-\(String(format: "%02d", c.day!))"
    }
}

// MARK: - Notion

struct N8nRun: Equatable {
    let workflow: String
    let detail: String?
    let success: Bool
    let date: Date
}

struct NotionPage: Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let lastEditedAt: Date
    let url: String

    var timeAgo: String {
        let diff = Date().timeIntervalSince(lastEditedAt)
        if diff < 60 { return String(localized: "now") }
        if diff < 3600 { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Chat

enum ChatRole { case user, assistant }

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: ChatRole
    var content: String   // var for streaming updates
    /// Display only, never encoded, persisted, logged or sent: the shared chat provider that wrote an answer
    /// (nil for the user, for Hermes and for messages made before this field), and the rows of an agent turn
    /// (empty: the message is drawn as one answer made from `content`).
    var provider: ChatProvider? = nil
    var segments: [ChatSegment] = []
    /// A sentence the app wrote (an error kept in the chat), never a text that is still arriving.
    var isNotice = false
    /// Something to draw: text, or the rows of an agent turn that has written no text yet. The chat list and the
    /// scroll targets of the chat share this one rule.
    var isShown: Bool { ChatVisibility.isShown(content: content, segments: segments) }
}

/// The one sign in session store of the app, over the Keychain item "hermes-agent-sessions".
extension ChatMediaStore {
    /// The one store of the app: it asks the agents with the one set of sign in sessions.
    static let shared = ChatMediaStore(sessions: .shared)
}

extension HermesSessions {
    static let shared = HermesSessions(storage: HermesSessionStorage(
        load: { KeychainStore.shared.get("hermes-agent-sessions") ?? "" },
        save: { value in
            if value.isEmpty { KeychainStore.shared.remove("hermes-agent-sessions") }
            else { KeychainStore.shared.set("hermes-agent-sessions", value: value) }
        }))
}
