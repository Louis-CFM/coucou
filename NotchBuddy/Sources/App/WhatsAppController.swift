#if !APPSTORE
import Foundation
import AppKit
import Combine
import Intents

// MARK: - Settings

/// WhatsApp's choices (Settings → Integrations → WhatsApp). Secrets (gateway URL, credentials,
/// webhook secret) live in the Keychain; only harmless choices go to UserDefaults.
enum WhatsAppSettings {
    static let urlKey = "whatsapp-url"
    static let credentialKey = "whatsapp-api-key"
    static let secretKey = "whatsapp-webhook-secret"
    static let defaultPort = 47823

    private static var ud: UserDefaults { .standard }

    static var enabled: Bool {
        get { ud.bool(forKey: "whatsappEnabled") }
        set { ud.set(newValue, forKey: "whatsappEnabled") }
    }
    static var gateway: WAGatewayKind {
        get { WAGatewayKind(rawValue: ud.string(forKey: "whatsappGateway") ?? "") ?? .gowa }
        set { ud.set(newValue.rawValue, forKey: "whatsappGateway") }
    }
    static var port: Int {
        get { let p = ud.integer(forKey: "whatsappPort"); return (1024...65535).contains(p) ? p : defaultPort }
        set { ud.set(newValue, forKey: "whatsappPort") }
    }
    /// Read receipts: sent when a conversation is opened (on), or only when replying (off).
    /// Never on mere reception.
    static var markReadOnOpen: Bool {
        get { ud.object(forKey: "whatsappMarkReadOnOpen") as? Bool ?? true }
        set { ud.set(newValue, forKey: "whatsappMarkReadOnOpen") }
    }
    static var respectFocus: Bool {
        get { ud.object(forKey: "whatsappRespectFocus") as? Bool ?? true }
        set { ud.set(newValue, forKey: "whatsappRespectFocus") }
    }
    static var filters: WAFilters {
        get {
            WAFilters(muteGroups: ud.object(forKey: "whatsappMuteGroups") as? Bool ?? true,
                      ignored: Set(ud.stringArray(forKey: "whatsappIgnored") ?? []))
        }
        set {
            ud.set(newValue.muteGroups, forKey: "whatsappMuteGroups")
            ud.set(Array(newValue.ignored).sorted(), forKey: "whatsappIgnored")
        }
    }

    static var url: String {
        KeychainStore.shared.get(urlKey) ?? gateway.defaultURL
    }

    /// The webhook's signing secret, made once (random, 64 hex characters).
    static func webhookSecret() -> String {
        if let s = KeychainStore.shared.get(secretKey), s.count >= 16 { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let s = Data(bytes).waHex
        KeychainStore.shared.set(secretKey, value: s)
        return s
    }

    static func makeProvider() -> WhatsAppProvider? {
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.scheme?.hasPrefix("http") == true else { return nil }
        let credential = KeychainStore.shared.get(credentialKey)
        switch gateway {
        case .gowa:   return GOWAProvider(base: base, basicAuth: credential)
        case .openwa: return OpenWAProvider(base: base, apiKey: credential)
        }
    }
}

// MARK: - Controller

/// WhatsApp in the notch (GitHub build only). Talks to the local gateway the user runs (GOWA
/// or OpenWA), receives new messages on a webhook bound to 127.0.0.1, falls back to polling
/// when no webhook comes, and keeps the conversations in memory only: nothing of a message is
/// ever written to disk or to a log, and everything is forgotten when Coucou quits or the
/// integration is turned off. Runs only while the integration is on and its pill is active.
@MainActor
final class WhatsAppController: ObservableObject {
    static let shared = WhatsAppController()
    nonisolated static let pillId = "integration_whatsapp"
    nonisolated static let webhookPath = "/whatsapp"

    enum Link: Equatable {
        case off
        case connecting
        /// The gateway runs, WhatsApp isn't linked: the QR is shown in Settings.
        case needsQR
        case connected
        case unreachable
        case unauthorized
        case failed(String)
    }

    enum Webhook: Equatable {
        case off
        /// Listening on the port, not yet accepted by the gateway.
        case listening
        /// The gateway accepted the address: messages should come on their own.
        case registered
        /// The gateway refused it (its message): polling instead.
        case refused(String)
        /// The port is taken.
        case portBusy
    }

    @Published private(set) var inbox = WAInbox()
    @Published private(set) var link: Link = .off
    @Published private(set) var webhook: Webhook = .off
    @Published private(set) var qrPNG: Data?
    /// This account (JID or number), once linked.
    @Published private(set) var me: String?
    /// Whether macOS lets Coucou read the Focus state (nil: not asked yet).
    @Published private(set) var focusReadable: Bool?
    /// A reply on its way.
    @Published private(set) var sending = false
    /// A reply is being typed: the island stays open until it is sent or cleared.
    var composing = false
    /// Why the last reply didn't go (shown under the field until the next try).
    @Published private(set) var sendError: String?
    @Published var filters = WhatsAppSettings.filters {
        didSet { WhatsAppSettings.filters = filters }
    }

    var visibleConversations: [WAConversation] { inbox.visible(filters: filters) }

    private var provider: WhatsAppProvider?
    private let listener = WhatsAppWebhook()
    private var timer: Timer?
    private var tick = 0
    private var refreshing = false
    private var polling = false
    private var backfilled = false
    private var qrExpiry: Date = .distantPast
    private var lastWebhook: Date?
    private var lastPoll = Date()
    private var lastAnnounce: Date = .distantPast
    private var namingGroups: Set<String> = []
    /// The conversation open in the card: what arrives there is seen, so it isn't unread.
    private(set) var openChat: String?
    private var rateLimit = WARateLimit(limit: 6, window: 60)
    /// Failed checks in a row (the gateway down, refusing, unreachable).
    private var failures = 0
    /// Bumped at each start and stop: an answer from before a restart is dropped.
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()

    private var shouldRun: Bool {
        WhatsAppSettings.enabled && AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    private init() {
        // Pill turned on or off from anywhere: follow it on the next turn (the sink runs
        // before the property changes).
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
            .store(in: &cancellables)
        // Back from sleep: ask the gateway again at once.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.wake() }
            }
            .store(in: &cancellables)
    }

    /// Called once at launch.
    func start() { update() }

    /// Settings changed (turned on/off, gateway, URL, credentials, port): start over.
    func settingsChanged() {
        stop(forget: !shouldRun)
        update()
    }

    /// Turns the integration on or off; on also makes room for its pill when a slot is free.
    func setEnabled(_ on: Bool) {
        WhatsAppSettings.enabled = on
        let state = AppState.shared
        if on, !state.activeIntegrations.contains(Self.pillId), state.activeIntegrations.count < 4 {
            state.toggleIntegration(Self.pillId)
        } else if !on, state.activeIntegrations.contains(Self.pillId) {
            state.toggleIntegration(Self.pillId)
        }
        settingsChanged()
    }

    private func update() {
        if shouldRun && provider == nil { begin() }
        else if !shouldRun && provider != nil { stop(forget: true) }
    }

    // MARK: - Lifecycle

    private func begin() {
        guard let provider = WhatsAppSettings.makeProvider() else {
            link = .failed(String(localized: "whatsapp.status.bad-url"))
            return
        }
        self.provider = provider
        generation += 1
        link = .connecting
        startListener(kind: provider.kind)
        if WhatsAppSettings.respectFocus { askFocus() }
        // GOWA started by Coucou when asked to (Settings), before the first check.
        WhatsAppGOWAProcess.shared.sync()
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { WhatsAppController.shared.onTick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    /// Stops talking to the gateway. `forget`: the conversations go too.
    private func stop(forget: Bool) {
        generation += 1
        refreshing = false
        polling = false
        timer?.invalidate()
        timer = nil
        listener.stop()
        provider = nil
        link = .off
        webhook = .off
        qrPNG = nil
        me = nil
        backfilled = false
        lastWebhook = nil
        namingGroups = []
        failures = 0
        // Turned off: GOWA goes too. Otherwise begin() keeps it, or restarts it if its
        // settings changed.
        if !shouldRun { WhatsAppGOWAProcess.shared.stopNow() }
        if forget {
            openChat = nil
            inbox.clear()
            resetTask()
        }
    }

    private func wake() {
        guard provider != nil else { return }
        // Nothing is trusted after a sleep: the gateway may have restarted without Coucou's webhook.
        webhook = webhook == .portBusy ? .portBusy : .listening
        lastWebhook = nil
        refresh()
    }

    private func onTick() {
        tick += 1
        if link != .connected {
            // Every 5 s while linking (QR, gateway coming up); every 30 s once the gateway
            // has been down for a minute.
            if failures > 12 && tick % 6 != 0 { return }
            refresh()
        } else {
            if tick % 12 == 0 { refresh() } // every minute: still linked?
            if tick % 4 == 0 { poll() }     // every 20 s, unless the webhook delivers
        }
    }

    // MARK: - Status and QR

    func refresh() {
        guard let provider, !refreshing else { return }
        refreshing = true
        let gen = generation
        Task {
            defer { if gen == generation { refreshing = false } }
            do {
                let status = try await provider.status()
                guard gen == generation else { return }
                if failures > 0 { failures = 0; showDown(false) }
                me = status.me
                switch status.link {
                case .connected:
                    if link != .connected { qrPNG = nil }
                    link = .connected
                    if webhook == .listening { await register(provider, gen: gen) }
                    if !backfilled, gen == generation { await backfill(provider, gen: gen) }
                case .needsQR:
                    link = .needsQR
                    if qrPNG == nil || Date() > qrExpiry {
                        // Not asked again for 15 s even when nothing came: each GOWA login call
                        // restarts the pairing.
                        qrExpiry = Date().addingTimeInterval(15)
                        if let qr = try await provider.qrCode(), gen == generation {
                            qrPNG = qr.png
                            qrExpiry = Date().addingTimeInterval(TimeInterval(qr.seconds))
                        }
                    }
                case .connecting:
                    link = .connecting
                }
            } catch let error as WAError {
                if gen == generation { apply(error) }
            } catch {
                if gen == generation { apply(.unreachable) }
            }
        }
    }

    private func apply(_ error: WAError) {
        switch error {
        case .unreachable:      link = .unreachable
        case .unauthorized:     link = .unauthorized
        case .notLoggedIn:      link = .needsQR
        case .refused(let why): link = .failed(why)
        }
        guard error != .notLoggedIn else { return }
        failures += 1
        // Twice in a row (not a gateway still starting): a small red dot on the pill, nothing more.
        if failures == 2 { showDown(true) }
        // GOWA started by Coucou and gone (crash, killed): started again, once a minute at most.
        if error == .unreachable { WhatsAppGOWAProcess.shared.sync() }
    }

    /// The discreet error pill: the pill's red badge while the gateway is down.
    private func showDown(_ down: Bool) {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        if down { state.tasks[i].pillBadge = .error }
        else if state.tasks[i].pillBadge == .error { state.tasks[i].pillBadge = nil }
    }

    /// One check from Settings' "Test connection": what the gateway says, in a sentence.
    func testConnection() async -> String {
        // The running connection when there is one (a second one could race it for OpenWA's session).
        guard let provider = provider ?? WhatsAppSettings.makeProvider() else { return String(localized: "whatsapp.status.bad-url") }
        do {
            var status: WAStatus
            var attempt = 0
            while true {
                do {
                    status = try await provider.status()
                    break
                } catch WAError.unreachable where WhatsAppGOWAProcess.shared.isRunning && attempt < 8 {
                    // GOWA just started by Coucou: give it a few seconds to come up.
                    attempt += 1
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            switch status.link {
            case .connected:
                let who = status.me.map(WAJID.displayNumber) ?? ""
                return String(format: String(localized: "whatsapp.test.connected %@"), who)
            case .needsQR:    return String(localized: "whatsapp.test.needs-qr")
            case .connecting: return String(localized: "whatsapp.test.connecting")
            }
        } catch let error as WAError {
            switch error {
            case .unreachable:      return String(localized: "whatsapp.status.unreachable")
            case .unauthorized:     return String(localized: "whatsapp.status.unauthorized")
            case .notLoggedIn:      return String(localized: "whatsapp.test.needs-qr")
            case .refused(let why): return why
            }
        } catch {
            return String(localized: "whatsapp.status.unreachable")
        }
    }

    // MARK: - Webhook

    private func startListener(kind: WAGatewayKind) {
        let secret = WhatsAppSettings.webhookSecret()
        listener.onRequest = { request in
            guard request.method == "POST", request.path.hasPrefix(WhatsAppController.webhookPath) else { return 404 }
            // Signed by the gateway with Coucou's secret, over the exact bytes received.
            guard WAWebhook.verify(kind: kind, headers: request.headers, body: request.body, secret: secret) else { return 401 }
            let body = request.body
            Task { @MainActor in WhatsAppController.shared.received(body, kind: kind) }
            return 200
        }
        listener.onListening = { ok in
            Task { @MainActor in
                let c = WhatsAppController.shared
                guard c.provider != nil else { return }
                if !ok { c.webhook = .portBusy }
                else if c.webhook == .off || c.webhook == .portBusy { c.webhook = .listening; c.refresh() }
            }
        }
        if !listener.start(port: UInt16(WhatsAppSettings.port)) { webhook = .portBusy }
    }

    private var webhookURL: String { "http://127.0.0.1:\(WhatsAppSettings.port)\(Self.webhookPath)" }

    private func register(_ provider: WhatsAppProvider, gen: Int) async {
        do {
            try await provider.registerWebhook(url: webhookURL, secret: WhatsAppSettings.webhookSecret())
            if gen == generation { webhook = .registered }
        } catch WAError.refused(let why) {
            guard gen == generation else { return }
            webhook = .refused(why)
            appendAppLog("nb.log", "[WhatsApp] gateway refused the webhook: \(why)")
        } catch {
            // Tried again on the next minute's check.
        }
    }

    private func received(_ body: Data, kind: WAGatewayKind) {
        guard provider != nil else { return }
        lastWebhook = Date()
        if webhook != .registered { webhook = .registered }
        guard case .message(let message)? = WAWebhook.parse(kind: kind, body: body, me: me) else { return }
        ingest([message], announce: true)
    }

    /// True while webhooks keep coming: no need to poll.
    private var webhookAlive: Bool {
        guard let lastWebhook else { return false }
        return Date().timeIntervalSince(lastWebhook) < 300
    }

    // MARK: - Messages

    /// The last hours of history, once linked: kept, but nothing counts as new.
    private func backfill(_ provider: WhatsAppProvider, gen: Int) async {
        backfilled = true
        let since = Date().addingTimeInterval(-12 * 3600)
        guard let messages = try? await provider.recentMessages(since: since, me: me), gen == generation else { return }
        // History: kept, never counted as unread (whether it was read is unknown), never announced.
        for message in messages { inbox.add(message, filters: filters, history: true) }
        for message in messages { nameGroupIfNeeded(WAJID.normalized(message.chat)) }
        lastPoll = Date()
    }

    private func poll() {
        guard let provider, !polling, !webhookAlive, backfilled else { return }
        polling = true
        let since = lastPoll.addingTimeInterval(-30)   // a little overlap; duplicates are dropped
        let started = Date()
        let gen = generation
        Task {
            defer { if gen == generation { polling = false } }
            guard let messages = try? await provider.recentMessages(since: since, me: me), gen == generation else { return }
            lastPoll = started
            ingest(messages, announce: true)
        }
    }

    private func ingest(_ messages: [WAMessage], announce: Bool) {
        var fresh: WAMessage?
        for message in messages {
            let key = WAJID.normalized(message.chat)
            let outcome = inbox.add(message, filters: filters)
            nameGroupIfNeeded(key)
            if key == openChat {
                // Read on screen: no unread, no Mochi. The receipt waits for a reply (or the
                // next opening), as Settings says.
                inbox.markRead(key)
                continue
            }
            if outcome == .notify, !message.fromMe { fresh = message }
        }
        if announce, let fresh { self.announce(fresh) }
    }

    /// Groups arrive under their id (GOWA's webhook carries no group name): asked once.
    private func nameGroupIfNeeded(_ chat: String) {
        guard WAJID.isGroup(chat), let provider, let conv = inbox.conversations[chat],
              conv.name == WAJID.displayNumber(chat), !namingGroups.contains(chat) else { return }
        namingGroups.insert(chat)
        let gen = generation
        Task {
            if let name = await provider.groupName(chat), gen == generation { inbox.rename(chat, to: name) }
        }
    }

    // MARK: - Conversation (phase 2)

    /// A conversation opened in the card: its latest messages from the gateway, and the read
    /// receipt when Settings says so.
    func open(_ chat: String) {
        sendError = nil
        openChat = WAJID.normalized(chat)
        guard let provider else { return }
        if WhatsAppSettings.markReadOnOpen { markRead(chat) }
        let gen = generation
        Task {
            guard let history = try? await provider.messages(chat: chat, limit: 10, me: me), gen == generation else { return }
            for message in history { inbox.add(message, filters: filters, history: true) }
        }
    }

    /// The conversation closed (back to the list, Escape, the island folded).
    func close(_ chat: String) {
        if openChat == WAJID.normalized(chat) { openChat = nil }
    }

    /// Marks the chat read here and on WhatsApp (up to its newest received message).
    func markRead(_ chat: String) {
        let key = WAJID.normalized(chat)
        guard let provider, let conv = inbox.conversations[key] else { return }
        let hadUnread = conv.unread > 0
        inbox.markRead(key)
        if inbox.visibleUnread(filters: filters) == 0 { clearBadge() }
        // Nothing new: no receipt to send.
        guard hadUnread else { return }
        let last = conv.messages.last { !$0.fromMe }?.id
        Task { try? await provider.markRead(chat: key, lastIncoming: last) }
    }

    /// Sends a reply. Only to a conversation already in the inbox, one at a time, a few a minute.
    /// True once the gateway took it.
    func send(_ text: String, to chat: String) async -> Bool {
        let key = WAJID.normalized(chat)
        guard let provider, !sending else { return false }
        if let refusal = WAReply.check(text, to: key, in: inbox) {
            if refusal == .tooLong { sendError = String(localized: "whatsapp.reply.too-long") }
            return false
        }
        guard rateLimit.allow() else {
            sendError = String(localized: "whatsapp.reply.too-fast")
            return false
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        sendError = nil
        defer { sending = false }
        let gen = generation
        do {
            let id = try await provider.send(text: body, to: key)
            // Turned off or restarted meanwhile: the inbox it belonged to is gone.
            guard gen == generation else { return true }
            var mine = WAMessage(id: id ?? "coucou-\(UUID().uuidString)", chat: key, sender: me ?? "",
                                 senderName: "", text: body, date: Date(), fromMe: true)
            mine.chatName = inbox.conversations[key]?.name
            inbox.add(mine, filters: filters)
            // Replying reads the conversation, whatever the setting.
            let last = inbox.conversations[key]?.messages.last { !$0.fromMe }?.id
            if inbox.visibleUnread(filters: filters) == 0 { clearBadge() }
            Task { try? await provider.markRead(chat: key, lastIncoming: last) }
            return true
        } catch let error as WAError {
            switch error {
            case .unreachable:      sendError = String(localized: "whatsapp.status.unreachable")
            case .unauthorized:     sendError = String(localized: "whatsapp.status.unauthorized")
            case .notLoggedIn:      sendError = String(localized: "whatsapp.status.needs-qr")
            case .refused(let why): sendError = why
            }
            return false
        } catch {
            sendError = String(localized: "whatsapp.status.unreachable")
            return false
        }
    }

    private func clearBadge() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[i].pillBadge = nil
    }

    // MARK: - Mochi

    /// A new message reaches you: Mochi's little "happy" emote, the global sound setting, and
    /// the pill lights up under the island's usual rules. Silent during a Focus.
    private func announce(_ message: WAMessage) {
        if WhatsAppSettings.respectFocus && focusIsOn { return }
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let name = inbox.conversations[WAJID.normalized(message.chat)]?.name ?? WAJID.displayNumber(message.chat)
        state.tasks[idx].state = .finished
        // Only the conversation's name on the pill, never the text.
        state.tasks[idx].steps = [name]
        if state.focusId != Self.pillId { state.tasks[idx].pillBadge = .finished }
        // A burst of messages is one reaction, not ten.
        if Date().timeIntervalSince(lastAnnounce) > 4 {
            lastAnnounce = Date()
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            SoundEngine.shared.play("pop")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            let state = AppState.shared
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
                  state.tasks[i].state == .finished,
                  Date().timeIntervalSince(WhatsAppController.shared.lastAnnounce) >= 59 else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }

    private func resetTask() {
        let state = AppState.shared
        guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[i].state = .idle
        state.tasks[i].steps = []
        state.tasks[i].pillBadge = nil
    }

    // MARK: - Focus

    /// macOS Focus (Concentration), when the system lets Coucou read it.
    private var focusIsOn: Bool {
        guard focusReadable == true else { return false }
        return INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    /// Asks once to read the Focus state. macOS answers only to apps signed with the
    /// Communication Notifications capability; elsewhere this stays unreadable.
    func askFocus() {
        let center = INFocusStatusCenter.default
        switch center.authorizationStatus {
        case .authorized:
            focusReadable = center.focusStatus.isFocused != nil
        case .notDetermined:
            // Intents may answer on any queue: the closure is @Sendable and hops to the main actor.
            center.requestAuthorization { @Sendable status in
                Task { @MainActor in
                    WhatsAppController.shared.focusReadable = status == .authorized
                        && INFocusStatusCenter.default.focusStatus.isFocused != nil
                }
            }
        default:
            focusReadable = false
        }
    }

    // MARK: - Filters

    func ignore(_ chat: String) {
        let key = WAJID.normalized(chat)
        filters.ignored.insert(key)
        inbox.remove(key)
        if openChat == key { openChat = nil }
    }

    func unignore(_ chat: String) {
        filters.ignored.remove(chat)
    }
}
#endif
