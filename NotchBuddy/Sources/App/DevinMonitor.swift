import Foundation
import SwiftUI

// MARK: - DevinMonitor
// Polls the official Devin API for the user's cloud sessions and translates them
// into the "agent_devin" pill. Sessions are cloud-hosted, so unlike Claude Code
// there is no local hook process: this poller is the event source.
//
// Scheduling follows the GithubPoller pattern (one chain of DispatchWorkItems,
// re-armed after each cycle): 20 s while a session is live, 120 s to discover new
// ones, exponential backoff (60 s → 10 min) on errors, Retry-After honored on 429.
// No poll ever leaves the Mac when no token is configured.

final class DevinMonitor: @unchecked Sendable {
    static let shared = DevinMonitor()
    static let tokenKey = "devin-api-key"
    static let pillId = "agent_devin"
    private static let apiBase = URL(string: "https://api.devin.ai/v3")!
    private static let fallbackAppURL = URL(string: "https://app.devin.ai/sessions")!

    // MARK: - State (main thread only)

    private var started = false
    private var pollInFlight = false
    private var nextPoll: DispatchWorkItem?
    private var generation = 0
    private var identity: DevinIdentity?
    private var tracker = DevinTracker()
    private var consecutiveErrors = 0
    private var retryAfter: TimeInterval? = nil

    private init() {}

    // MARK: - Lifecycle

    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.scheduleNext(delay: 8)
        }
    }

    /// Re-poll immediately (Settings → Agents → Devin → Connect, token change).
    func pollNow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.cancelNext()
            self.poll()
        }
    }

    /// Stops watching, forgets sessions and clears the pill. The key itself is
    /// removed by Settings (disconnect); this only clears derived state.
    func disconnect() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.cancelNext()
            self.pollInFlight = false
            self.identity = nil
            self.consecutiveErrors = 0
            self.retryAfter = nil
            _ = self.tracker.reset()
            let state = AppState.shared
            state.devinError = nil
            state.devinUserName = nil
            state.devinActiveCount = 0
            state.removeTask(id: Self.pillId)
            self.scheduleNext(delay: DevinSchedule.discoveryInterval)
        }
    }

    // MARK: - Poll cycle

    private func poll() {
        // Same shape as GithubPoller.pollPulse: state guards on main, network off main.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let token = KeychainStore.shared.get(Self.tokenKey) else {
                // Not configured: stay idle, keep the loop alive so connecting later just works.
                AppState.shared.devinError = nil
                self.scheduleNext(hasLive: false)
                return
            }
            guard !self.pollInFlight else { self.scheduleNext(delay: DevinSchedule.activeInterval); return }
            self.pollInFlight = true
            let gen = self.generation
            let cachedIdentity = self.identity
            let trackedIds = self.trackedSessionIds()
            Task.detached { [weak self] in
                await self?.fetchCycle(token: token, identity: cachedIdentity,
                                        trackedIds: trackedIds, generation: gen)
            }
        }
    }

    private func fetchCycle(token: String, identity: DevinIdentity?,
                           trackedIds: [String], generation: Int) async {
        do {
            var identity = identity
            if identity == nil {
                identity = try await fetchIdentity(token: token)
            }
            guard let identity, let orgId = identity.sessionsOrgId else {
                await complete(generation: generation, error: "This account has no Devin organization to watch.")
                return
            }
            let page = try await fetchSessions(token: token, orgId: orgId,
                                               userId: identity.userId, trackedIds: trackedIds)
            await MainActor.run {
                self.identity = identity
                self.apply(page: page, generation: generation)
            }
        } catch let error as DevinAPIError {
            await complete(generation: generation, error: error.message,
                           refetchIdentity: error.refetchIdentity, retryAfter: error.retryAfter)
        } catch {
            await complete(generation: generation, error: "Cannot reach api.devin.ai.")
        }
    }

    /// Applies one page on the main thread: tracker events → ticker steps, sounds,
    /// badges; aggregate phase → pill state; empty tracker → pill ends.
    /// The generation guard makes a response that raced a token change a no-op,
    /// but pollInFlight is always released so the loop can never wedge.
    @MainActor
    private func apply(page: DevinSessionPage, generation: Int) {
        pollInFlight = false
        guard generation == self.generation else { scheduleNext(); return }

        let events = tracker.ingest(page)
        let state = AppState.shared
        state.devinError = nil
        state.devinActiveCount = tracker.liveCount
        if let identity { state.devinUserName = identity.userName }

        if tracker.totalCount == 0 {
            endPill()
            consecutiveErrors = 0
            retryAfter = nil
            scheduleNext(hasLive: false)
            return
        }

        upsertPill()
        if let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            state.tasks[idx].name = tracker.leadSession?.displayName ?? "Devin"
            state.tasks[idx].state = botState(for: tracker.aggregatePhase)
        }

        let focused = state.focusId == Self.pillId
        for event in events {
            applyEvent(event, focused: focused, state: state)
        }
        nbLog("watching \(tracker.totalCount) session(s), \(tracker.liveCount) live")

        consecutiveErrors = 0
        retryAfter = nil
        scheduleNext(hasLive: tracker.liveCount > 0)
    }

    @MainActor
    private func complete(generation: Int, error: String,
                         refetchIdentity: Bool = false, retryAfter: TimeInterval? = nil) {
        pollInFlight = false
        guard generation == self.generation else { scheduleNext(); return }
        if refetchIdentity { identity = nil }
        AppState.shared.devinError = error
        consecutiveErrors += 1
        self.retryAfter = retryAfter
        nbLog(error)
        scheduleNext()
    }

    // MARK: - Event → pill

    @MainActor
    private func applyEvent(_ event: DevinEvent, focused: Bool, state: AppState) {
        let step = Self.stepText(for: event)
        if let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            state.tasks[idx].steps.append(step)
            if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
            state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
        }
        switch event.kind {
        case .started:
            SoundEngine.shared.play("work")
        case .waiting:
            SoundEngine.shared.play("question")
            if !focused { state.setPillBadge(.finished, for: Self.pillId) }
        case .finished:
            SoundEngine.shared.play("finish")
            if !focused { state.setPillBadge(.finished, for: Self.pillId) }
        case .failed:
            SoundEngine.shared.play("error")
            if !focused { state.setPillBadge(.error, for: Self.pillId) }
        case .prReady, .working, .rateLimited, .suspended:
            break
        }
    }

    private static func stepText(for event: DevinEvent) -> String {
        let title = String(event.title.prefix(40))
        switch event.kind {
        case .started:       return title
        case .working:       return "\(title) · working"
        case .waiting:       return "\(title) · waiting for you"
        case .finished:      return "\(title) · finished"
        case .failed:        return "\(title) · failed"
        case .rateLimited:   return "\(title) · usage limit"
        case .suspended:     return "\(title) · suspended"
        case .prReady:       return "\(title) · PR ready"
        }
    }

    @MainActor
    private func botState(for phase: DevinPhase?) -> BotState {
        switch phase {
        case .starting:            return .thinking
        case .working, .unknown:    return .working
        case .waitingForUser, .waitingForApproval: return .question
        case .finished:            return .finished
        case .failed:               return .error
        case .rateLimited:          return .ratelimit
        case .ended, nil:           return .idle
        }
    }

    // MARK: - Pill bookkeeping

    /// Creates the transient Devin pill on first session (inserted right after the
    /// main pill, like HookServer's dynamic agent pills); no-ops when it exists.
    @MainActor
    private func upsertPill() {
        let state = AppState.shared
        guard state.tasks.firstIndex(where: { $0.id == Self.pillId }) == nil else { return }
        let def = PillCatalog.definition(for: Self.pillId)
        let task = AgentTask(id: Self.pillId, name: def?.name ?? "Devin",
                             color: def?.color ?? "#3969CA", state: .idle, steps: [],
                             source: def?.source ?? .agent, isIntegration: true)
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.append(task)
        }
        state.syncMode()
    }

    /// Empty tracker: declared pills reset to idle (the catalog + Active pills
    /// contract), undeclared pills disappear — same as Stop for hook agents.
    @MainActor
    private func endPill() {
        AppState.shared.removeTask(id: Self.pillId)
    }

    // MARK: - Scheduling (main thread)

    private func cancelNext() {
        nextPoll?.cancel()
        nextPoll = nil
    }

    private func scheduleNext(hasLive: Bool? = nil, delay: TimeInterval? = nil) {
        cancelNext()
        let work = DispatchWorkItem { [weak self] in self?.poll() }
        nextPoll = work
        let d = delay ?? DevinSchedule.nextDelay(
            hasLive: hasLive ?? (tracker.liveCount > 0),
            consecutiveErrors: consecutiveErrors,
            retryAfter: retryAfter)
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }

    // MARK: - Networking

    private func request(path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!, timeoutInterval: 15)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func fetchIdentity(token: String) async throws -> DevinIdentity {
        var req = request(path: "self")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DevinAPIError.network }
        switch http.statusCode {
        case 200:
            guard let identity = DevinIdentity.parse(data) else { throw DevinAPIError.malformed }
            return identity
        case 401: throw DevinAPIError.invalidToken
        default:  throw DevinAPIError.api(http.statusCode)
        }
    }

    /// Ids of the sessions we watch, most relevant first (waiting, then live,
    /// then fresh terminal; newest update within each group) — the by-id refresh
    /// keeps them if the list has to be truncated.
    @MainActor
    private func trackedSessionIds() -> [String] {
        tracker.sessions.values
            .sorted {
                let lhsRank = $0.phase.isAttention ? 0 : ($0.phase.isLive ? 1 : 2)
                let rhsRank = $1.phase.isAttention ? 0 : ($1.phase.isLive ? 1 : 2)
                return (lhsRank, $0.updatedAt ?? .distantPast, $0.id)
                    > (rhsRank, $1.updatedAt ?? .distantPast, $1.id)
            }
            .map(\.id)
    }

    /// Two bounded requests per poll, both documented filters:
    ///
    /// 1. Discovery — the user's recent, non-archived sessions, first page only.
    ///    created_after keeps deep history out of it, so any recency-based
    ///    ordering puts new sessions on this page.
    /// 2. By-id refresh (only while sessions are watched) — the tracked
    ///    sessions re-queried by session_id. Whatever the server's ordering and
    ///    however much history the user has, a session Coucou already watches
    ///    can never be crowded out of the discovery page and falsely reported
    ///    suspended; if it is missing here, it is genuinely archived or deleted.
    private func fetchSessions(token: String, orgId: String, userId: String,
                               trackedIds: [String]) async throws -> DevinSessionPage {
        let createdAfter = Int(Date().timeIntervalSince1970) - 30 * 24 * 3600
        var page = try await fetchPage(token: token, orgId: orgId, query: [
            URLQueryItem(name: "first", value: "200"),
            URLQueryItem(name: "is_archived", value: "false"),
            URLQueryItem(name: "user_ids", value: userId),
            URLQueryItem(name: "created_after", value: String(createdAfter)),
        ])
        if !trackedIds.isEmpty {
            // Repeated query keys — the documented array encoding for the API.
            let ids = Array(trackedIds.prefix(50))   // keeps the URL comfortably small
            let refresh = try await fetchPage(token: token, orgId: orgId, query: [
                URLQueryItem(name: "first", value: "200"),
                URLQueryItem(name: "is_archived", value: "false"),
            ] + ids.map { URLQueryItem(name: "session_ids", value: $0) })
            page = DevinSessionPage.merge([refresh, page])
        }
        return page
    }

    private func fetchPage(token: String, orgId: String, query: [URLQueryItem]) async throws -> DevinSessionPage {
        var req = request(path: "organizations/\(orgId)/sessions", query: query)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DevinAPIError.network }
        switch http.statusCode {
        case 200:
            guard let page = DevinSessionPage.parse(data) else { throw DevinAPIError.malformed }
            return page
        case 401: throw DevinAPIError.invalidToken
        case 403: throw DevinAPIError.forbidden
        case 404: throw DevinAPIError.orgNotFound
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
            throw DevinAPIError.rateLimited(retry)
        default:  throw DevinAPIError.api(http.statusCode)
        }
    }

    // MARK: - Connection test (Settings → Agents → Devin → Connect)

    /// Cheap official check of an un-saved token: GET /v3/self. The token is only
    /// ever placed in the Authorization header — it never reaches logs or the UI.
    static func testConnection(token: String) async -> Result<DevinIdentity, DevinConnectError> {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.message("Enter an API token first.")) }
        var req = URLRequest(url: URL(string: "\(apiBase.absoluteString)/self")!, timeoutInterval: 15)
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.message("No response from Devin.")) }
            switch http.statusCode {
            case 200:
                guard let identity = DevinIdentity.parse(data) else {
                    return .failure(.message("Unexpected response from Devin."))
                }
                return .success(identity)
            case 401: return .failure(.message("Invalid token (401). Create one at Settings → Devin API → PATs (app.devin.ai)."))
            case 403: return .failure(.message("This token cannot access the Devin API (403)."))
            default:  return .failure(.message("Devin API error (\(http.statusCode))."))
            }
        } catch {
            return .failure(.message("Cannot reach api.devin.ai."))
        }
    }

    // MARK: - Open in Devin

    /// The URL the pill opens — DevinTracker.bestSession's deterministic rule
    /// (waiting first, then newest live, then newest), straight from the API.
    /// Falls back to the sessions page.
    @MainActor
    var bestSessionURL: URL {
        guard let pick = tracker.bestSession, let url = URL(string: pick.url),
              url.scheme == "https" || url.scheme == "http" else { return Self.fallbackAppURL }
        return url
    }

    private func nbLog(_ message: String) {
        appendAppLog("devin.log", message)
    }
}

// MARK: - API errors (sanitized — never include the token)

enum DevinAPIError: Error {
    case network
    case malformed
    case invalidToken
    case forbidden
    case orgNotFound
    case api(Int)
    case rateLimited(TimeInterval?)

    var message: String {
        switch self {
        case .network:             return "Cannot reach api.devin.ai."
        case .malformed:           return "Unexpected response from Devin."
        case .invalidToken:         return "Invalid token (401)."
        case .forbidden:           return "No access to this organization's sessions (403)."
        case .orgNotFound:         return "Devin organization not found (404)."
        case .api(let code):        return "Devin API error (\(code))."
        case .rateLimited:         return "Rate limited (429) — backing off."
        }
    }

    /// Server-provided wait time from a 429, nil otherwise.
    var retryAfter: TimeInterval? {
        if case .rateLimited(let t) = self { return t }
        return nil
    }

    /// True when the cached identity may be stale and must be refetched.
    var refetchIdentity: Bool {
        switch self {
        case .orgNotFound: return true
        default: return false
        }
    }
}

// MARK: - Connection test error (Settings → Agents → Devin → Connect)

enum DevinConnectError: Error {
    case message(String)
}
