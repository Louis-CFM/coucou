import Foundation
import SwiftUI
import Combine


@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Island state
    @Published var mode: IslandMode = .hidden
    @Published var view: IslandView = .overview

    // Tasks
    @Published var tasks: [AgentTask] = []
    @Published var focusId: String? = nil

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

    // Mouse tracking
    var mousePosition: CGPoint = .zero
    var lastMouseMove: Date = .now
    var lastActivity: Date = .now
    var isPresent: Bool = true

    // Pinned (alerts that stay open, never auto-close)
    var isPinned: Bool = false

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

    // Mochi outfit selection — persisted
    @Published var mochiOutfitSelection: Outfit = .auto {
        didSet { Outfit.stored = mochiOutfitSelection }
    }
    // Transient: outfit preview while hovering in wardrobe (overrides resolvedOutfit in BotCanvasView)
    var wardrobePreviewOutfit: Outfit? = nil
    // Per-day seasonal cache — avoids recomputing Easter and date math on every frame
    private var _seasonalCache: (dayOfYear: Int, year: Int, outfit: Outfit)?
    var resolvedOutfit: Outfit {
        if let preview = wardrobePreviewOutfit { return preview }
        guard mochiOutfitSelection == .auto else { return mochiOutfitSelection }
        let cal = Calendar.current
        let now = Date()
        let day  = cal.ordinality(of: .day, in: .year, for: now) ?? 0
        let year = cal.component(.year, from: now)
        if let c = _seasonalCache, c.dayOfYear == day && c.year == year { return c.outfit }
        let outfit = Outfit.seasonal(for: now, calendar: cal)
        _seasonalCache = (dayOfYear: day, year: year, outfit: outfit)
        return outfit
    }

    // Claude model used by the chat and the search — persisted
    static let defaultClaudeModel = "claude-sonnet-4-6"
    @Published var claudeModel: String = AppState.defaultClaudeModel {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "claudeModel") }
    }

    // In-chat provider + model — picked via the model selector in the prompt view
    @Published var chatProvider: ChatProvider = .anthropic {
        didSet { UserDefaults.standard.set(chatProvider.rawValue, forKey: "chatProvider") }
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
    @Published var ollamaServerURL: String = "" {
        didSet { UserDefaults.standard.set(ollamaServerURL, forKey: "ollamaServerURL") }
    }
    @Published var lmstudioServerURL: String = "" {
        didSet { UserDefaults.standard.set(lmstudioServerURL, forKey: "lmstudioServerURL") }
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
        // Local providers: fetch from server URL (no API key needed)
        if provider.isLocal {
            let baseURL = provider == .ollama ? ollamaServerURL : lmstudioServerURL
            let normalised = LocalChat.normaliseURL(baseURL)
            guard !normalised.isEmpty else {
                providerModelFetchError[provider] = provider == .ollama
                    ? "Connect Ollama in Settings → Chat first."
                    : "Connect LM Studio in Settings → Chat first."
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
                        ? "No models yet. Download one in Ollama first."
                        : "No models yet. Download one in LM Studio first."
                case .success(let models):
                    fetchedProviderModels[provider] = models
                    let current = provider == .ollama ? ollamaChatModel : lmstudioChatModel
                    if !models.contains(where: { $0.id == current }) {
                        let first = models.first!.id
                        if provider == .ollama { ollamaChatModel = first }
                        else                   { lmstudioChatModel = first }
                    }
                case .failure:
                    providerModelFetchError[provider] = "Cannot reach \(normalised). Is the server running?"
                }
            }
            return
        }
        // Remote providers: require API key
        guard let apiKey = KeychainStore.shared.get(provider.keychainKey), !apiKey.isEmpty else {
            providerModelFetchError[provider] = "No API key — add it in Settings."
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
            case .ollama, .lmstudio: models = []  // handled above
            }
            loadingProviderModels.remove(provider)
            if models.isEmpty {
                providerModelFetchError[provider] = "Failed to load models. Check your API key."
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
                case .ollama, .lmstudio: break
                }
            }
        }
    }

    /// The model currently active for chat (provider-aware).
    var activeChatModel: String {
        switch chatProvider {
        case .anthropic: return claudeModel
        case .google:    return googleChatModel
        case .openai:    return openAIChatModel
        case .ollama:    return ollamaChatModel
        case .lmstudio:  return lmstudioChatModel
        }
    }

    // Sound volume (0–0.2) — persisted, synced to SoundEngine
    @Published var soundVolume: Double = 0.12 {
        didSet {
            UserDefaults.standard.set(soundVolume, forKey: "soundVolume")
            SoundEngine.shared.volume = Float(soundVolume)
        }
    }

    // Context for prompt (window attach / file)
    @Published var promptContext: PromptContext? = nil

    // Dropped file (set during upload flow)
    @Published var droppedFile: DroppedFile? = nil

    // Short note message (shown in NoteView)
    @Published var noteMessage: String? = nil

    // Auto-close delay — persisted
    @Published var autoCloseInterval: TimeInterval = 15 {
        didSet { UserDefaults.standard.set(autoCloseInterval, forKey: "autoCloseInterval") }
    }

    // Absence interval — persisted
    var absenceInterval: TimeInterval = 3 * 60 {
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

    // Chat conversation history
    @Published var chatHistory: [ChatMessage] = []

    // Pending approval request from Claude Code hook
    @Published var pendingApproval: ApprovalInfo? = nil

    // Pending AskUserQuestion from Claude Code hook
    @Published var pendingQuestion: AskQuestion? = nil

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
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async { self?.clearSessionDiffs(for: pillId) }
        }
        sessionDiffTimers[pillId] = work
        DispatchQueue.global().asyncAfter(deadline: .now() + 3600, execute: work)
    }

    #if !APPSTORE
    @Published var musicPlaying: Bool = false
    @Published var musicAutomationDenied: Bool = false
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
    // Cached relay-installed state — updated at launch, after install/uninstall, on Settings open
    @Published var planRelayInstalled: Bool = false
    // Transient — reset when island closes or view changes
    @Published var showingPlanDetail: Bool = false

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
        if let v = ud.string(forKey: "claudeModel"),
           !v.trimmingCharacters(in: .whitespaces).isEmpty { claudeModel = v }
        if let v = ud.string(forKey: "chatProvider"), let p = ChatProvider(rawValue: v) { chatProvider = p }
        if let v = ud.string(forKey: "googleChatModel"), !v.isEmpty { googleChatModel = v }
        if let v = ud.string(forKey: "openAIChatModel"), !v.isEmpty { openAIChatModel = v }
        if let v = ud.string(forKey: "ollamaChatModel"), !v.isEmpty { ollamaChatModel = v }
        if let v = ud.string(forKey: "lmstudioChatModel"), !v.isEmpty { lmstudioChatModel = v }
        if let v = ud.string(forKey: "ollamaServerURL"), !v.isEmpty { ollamaServerURL = v }
        if let v = ud.string(forKey: "lmstudioServerURL"), !v.isEmpty { lmstudioServerURL = v }
        // Migrate old 60s default → 15s
        if let v = ud.object(forKey: "autoCloseInterval") as? Double {
            autoCloseInterval = (v == 60) ? 15 : v
        }
        if let v = ud.object(forKey: "absenceInterval")   as? Double { absenceInterval   = v }
        if let v = ud.object(forKey: "greetThreshold")    as? Double { greetThresholdSeconds = v }
        if let v = ud.object(forKey: "hotkeyEnabled") as? Bool  { hotkeyEnabled = v }
        if let v = ud.object(forKey: "hotkeyFlags")   as? Int   { hotkeyFlags = UInt(v) }
        if let v = ud.object(forKey: "hotkeyCode")    as? Int   { hotkeyCode = UInt16(v) }
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

    func setFocus(_ id: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        focusId = id
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
    }

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
        if focusId == nil { focusId = mainPillId }
        syncMode()
    }

    /// Toggle a catalog pill on/off.
    /// mainPillId: never toggleable (change via the Main picker first).
    /// Max 4 non-main pills active at once.
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
    var statusLabel: String { isSuccess ? "Ready" : (state == "CANCELED" ? "Canceled" : "Error") }
    var timeAgo: String {
        let diff = Date().timeIntervalSince(createdAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
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
        if diff < 60    { return "just now" }
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
        if diff < 60    { return "just now" }
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

struct NotionPage: Identifiable {
    let id: String
    let title: String
    let emoji: String?
    let lastEditedAt: Date
    let url: String

    var timeAgo: String {
        let diff = Date().timeIntervalSince(lastEditedAt)
        if diff < 60 { return "now" }
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
}
