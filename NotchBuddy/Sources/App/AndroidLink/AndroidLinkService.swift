import AppKit
import Combine
import Foundation

// MARK: - Android link: the bridge to the island (GitHub build)
//
// Lets Coucou for Android pair with this Mac (docs/ANDROID_LINK.md, protocol v1), the same way it
// pairs with a PC. Off by default and opt-in in Settings → Android phone. While it is off nothing
// listens, nothing is announced on the network and no timer runs. While it is on, the work is event
// driven: AppState changes (debounced) are published to the hub, and phones' lines are handled as
// they arrive. No polling anywhere.
//
// The island keeps owning the sessions and the pending request. A phone's decision goes through
// `AndroidLinkHub.decide`, which applies it only if its fingerprint is the request still pending, and
// then `AndroidLinkAppHost` answers the waiting nb-hook through `HookServer.sendApprovalDecision`,
// the very path a click on the Mac's own card takes, so that card keeps working all along.
//
// Compiled out of the App Store build: the sandbox has no server entitlement, and that build has its
// own iPhone link.

#if !APPSTORE

// MARK: Switches

/// The switches in Settings → Android phone, read again for every connection.
final class AndroidLinkDefaultsFeatures: AndroidLinkFeatures, @unchecked Sendable {
    static let detailsKey = "androidLinkDetails"
    static let answersKey = "androidLinkAnswers"
    static let usageKey = "androidLinkUsage"

    func details() -> Bool { UserDefaults.standard.bool(forKey: Self.detailsKey) }
    func answers() -> Bool { UserDefaults.standard.bool(forKey: Self.answersKey) }
    func usage() -> Bool { UserDefaults.standard.bool(forKey: Self.usageKey) }
}

// MARK: Host

/// Applies a phone's decision as a click on the Mac's own card would.
final class AndroidLinkAppHost: AndroidLinkHost, @unchecked Sendable {
    func decide(requestId: String, allow: Bool) {
        Task { @MainActor in
            // Checked again on the main actor, right before answering the hook: the request must
            // still be the one on the card.
            guard let pending = AppState.shared.pendingApproval, pending.id.uuidString == requestId else {
                AndroidLinkService.log("decision arrived after the request was resolved, ignored")
                return
            }
            AndroidLinkService.log("\(allow ? "allowed" : "denied") from the Android phone: \(pending.tool)")
            HookServer.shared.sendApprovalDecision(allow ? "allow" : "deny", for: pending.id)
        }
    }

    func answer(requestId: String, picks: [[String]]) {
        Task { @MainActor in
            guard let entry = AppState.shared.waitingQuestions.first(where: { $0.id.uuidString == requestId }) else {
                AndroidLinkService.log("answer for a question no longer waiting, ignored")
                return
            }
            // Never what was picked.
            AndroidLinkService.log("answered a question from the Android phone")
            HookServer.shared.sendQuestionAnswers(
                AskQuestion.buildAnswers(questions: entry.question.questions, selections: picks), for: entry.id)
        }
    }
}

// MARK: Service

@MainActor
final class AndroidLinkService: ObservableObject {
    static let shared = AndroidLinkService()
    static let enabledKey = "androidLinkEnabled"

    @Published private(set) var running = false
    @Published private(set) var port: UInt16 = 0
    @Published private(set) var error: String?

    private var hub: AndroidLinkHub?
    private var server: AndroidLinkServer?
    private var identity: AndroidLinkIdentity?
    private var cancellable: AnyCancellable?
    private let store = AndroidLinkKeychainStore()

    nonisolated static func log(_ message: String) {
        appendAppLog("AndroidLink.log", message)
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// At launch: starts only if the user turned it on.
    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start() } else { stop() }
    }

    // MARK: Start and stop

    private func start() {
        guard server == nil else { return }
        guard let identity = AndroidLinkIdentity.loadOrCreate(store: store),
              let token = AndroidLinkIdentity.token(store: store) else {
            fail("no secure storage for the certificate or the pairing code")
            return
        }
        guard let secIdentity = AndroidLinkSecIdentity.make(for: identity) else {
            fail("the certificate could not be loaded")
            return
        }
        let hub = AndroidLinkHub(host: AndroidLinkAppHost())
        let server = AndroidLinkServer(hub: hub, features: AndroidLinkDefaultsFeatures(),
                                       name: AndroidLinkProtocol.computerName(), token: token)
        server.onState = { [weak self] state in
            Task { @MainActor in self?.serverState(state) }
        }
        self.hub = hub
        self.server = server
        self.identity = identity
        error = nil
        server.start(identity: secIdentity, txt: AndroidLinkProtocol.txtRecord(fingerprint: identity.fingerprint) ?? [:])
        observe()
        Self.log("starting")
    }

    private func stop() {
        cancellable = nil
        server?.stop()
        server = nil
        hub = nil
        identity = nil
        AndroidLinkSecIdentity.remove()
        running = false
        port = 0
        error = nil
        Self.log("stopped")
    }

    private func fail(_ message: String) {
        error = message
        running = false
        Self.log("could not start: \(message)")
    }

    private func serverState(_ state: AndroidLinkServer.State) {
        guard server != nil else { return }
        switch state {
        case .ready(let p):
            port = p
            running = true
            error = nil
            Self.log("listening on port \(p)")
            publish()
        case .failed(let message):
            // Nothing is left half running: the listener is gone, so is everything else.
            stop()
            fail(message)
        }
    }

    // MARK: Pairing

    /// The pairing link for this Mac, or nil while the link is not running.
    func pairingLink() -> String? {
        guard running, let identity, let server, let host = AndroidLinkNetwork.lanAddress() else { return nil }
        return AndroidLinkProtocol.pairingLink(host: host, port: port, fingerprint: identity.fingerprint,
                                               token: server.currentToken, name: AndroidLinkProtocol.computerName())
    }

    /// A new pairing code: the phone that held the old one is locked out and disconnected.
    func pairAgain() {
        guard let server, let hub, let token = AndroidLinkIdentity.newToken(store: store) else { return }
        server.replaceToken(token)
        hub.kickAll(code: "auth", message: "unpaired")
        Self.log("paired again")
    }

    /// A switch changed: phones reconnect once, to be told what is offered now.
    func switchesChanged() {
        hub?.kickAll(code: "closed", message: "settings changed")
    }

    // MARK: From the island to the phones

    /// Event driven: the island's state changes, debounced, are published. Nothing else wakes this up.
    private func observe() {
        let s = AppState.shared
        let sources: [AnyPublisher<Void, Never>] = [
            s.$tasks.map { _ in () }.eraseToAnyPublisher(),
            s.$pendingApproval.map { _ in () }.eraseToAnyPublisher(),
            s.$waitingQuestions.map { _ in () }.eraseToAnyPublisher(),
            s.$claudePlanUsage.map { _ in () }.eraseToAnyPublisher(),
            s.$codexPlanUsage.map { _ in () }.eraseToAnyPublisher(),
        ]
        // @Published sends before the property changes: the debounce lets the value settle, and it is read back.
        cancellable = Publishers.MergeMany(sources)
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] in
                MainActor.assumeIsolated { self?.publish() }
            }
    }

    private func publish() {
        guard let hub else { return }
        let state = AppState.shared
        let now = AndroidLinkProtocol.nowMs()
        // The demo is not real: nothing of it leaves the Mac.
        let demo = DemoEngine.shared.isActive
        let sessions = demo ? [] : Self.sessions(from: state.tasks)
        let approval = demo ? nil : state.pendingApproval.flatMap(Self.approval(from:))
        hub.publish(sessions: sessions, approval: approval, now: now)
        hub.publishQuestion(demo ? nil : Self.question(from: state.waitingQuestions), now: now)
        hub.publishUsage(Self.usage(claude: state.claudePlanUsage, codex: state.codexPlanUsage))
    }

    // MARK: Mapping (AppState → the phone's picture)

    /// One session per agent pill, as the iPhone gets them: services (Stripe, GitHub…) and chat providers are not sessions.
    static func sessions(from tasks: [AgentTask]) -> [AndroidSessionIn] {
        tasks.filter { $0.source != .n8n && PillCatalog.isSession($0.id) }
            .map { task in
                let current = task.steps.indices.contains(task.stepIndex) ? task.steps[task.stepIndex] : (task.steps.last ?? "")
                return AndroidSessionIn(
                    pillId: task.id, agent: task.name, state: task.state.rawValue, statusText: current,
                    stepIndex: task.stepIndex, stepCount: task.steps.count,
                    steps: task.steps, finalLine: task.finalLine, project: task.sessionCwd, color: task.color)
            }
    }

    /// The request on the card. Its queue id is the request id, so asking for the same command twice
    /// gives two different fingerprints, and a late decision for the first can never answer the second.
    static func approval(from info: ApprovalInfo) -> AndroidApprovalIn? {
        guard info.sessionId != "demo_session" else { return nil }
        return AndroidApprovalIn(requestId: info.id.uuidString, sessionId: info.sessionId, pillId: info.pillId,
                                 tool: info.tool, command: info.command)
    }

    /// The first waiting question that fits what a phone can show whole; the others stay on the Mac.
    static func question(from waiting: [QueuedQuestion]) -> AndroidQuestionIn? {
        for entry in waiting {
            let items = entry.question.questions.map { item in
                AndroidQuestionItemIn(question: item.question,
                                      options: item.options.map { AndroidOptionIn(label: $0.label, description: $0.description) },
                                      multiSelect: item.multiSelect)
            }
            if AndroidLinkHub.fitsTheLimits(items) {
                return AndroidQuestionIn(requestId: entry.id.uuidString, sessionId: entry.sessionId, pillId: entry.displayPill, questions: items)
            }
        }
        return nil
    }

    static func usage(claude: PlanUsage?, codex: CodexPlanUsage?) -> AndroidUsageIn? {
        func ms(_ d: Date) -> UInt64 { UInt64(max(0, d.timeIntervalSince1970 * 1000)) }
        func window(_ w: PlanWindow?) -> AndroidUsageWindowIn? {
            w.map { AndroidUsageWindowIn(usedPct: $0.usedPct, resetsAt: ms($0.resetsAt)) }
        }
        let c = claude.map { AndroidUsagePlanIn(fiveHour: window($0.fiveHour), sevenDay: window($0.sevenDay), updatedAt: ms($0.updatedAt)) }
        let x = codex.map {
            AndroidUsagePlanIn(fiveHour: window($0.fiveHour), sevenDay: window($0.sevenDay), plan: $0.planType,
                               resetCredits: $0.resetCredits, updatedAt: ms($0.updatedAt))
        }
        return (c == nil && x == nil) ? nil : AndroidUsageIn(claude: c, codex: x)
    }
}

// MARK: Network

enum AndroidLinkNetwork {
    /// This Mac's address on the local network: the one the system would use to reach the outside.
    /// Connecting a UDP socket sends nothing; it only makes the system pick the interface.
    static func lanAddress() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, "192.0.2.1", &remote.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = local.sin_addr
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        let text = String(cString: buffer)
        return text == "0.0.0.0" ? nil : text
    }
}

#endif
