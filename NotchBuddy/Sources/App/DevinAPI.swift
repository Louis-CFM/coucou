import Foundation

// MARK: - Devin API models (Foundation only — unit-tested without the app)
//
// Shapes follow the official Cognition Devin API v3 (docs.devin.ai/api-reference):
//   GET /v3/self                                     → PatUserSelf (identity + sessions org)
//   GET /v3/organizations/{org_id}/sessions          → PaginatedResponse[SessionResponse]
//
// Sessions are cloud-hosted: unlike Claude Code there is no local hook process,
// so these types translate remote session lifecycle into Coucou's agent states.

// MARK: - Phase (normalized session state)

/// Normalized Devin session state, mapped from the API's `status` + `status_detail`.
///
/// Mapping (from the v3 SessionResponse documentation):
/// | status               | status_detail                            | phase              |
/// |----------------------|------------------------------------------|--------------------|
/// | new / claimed        | —                                        | starting           |
/// | resuming             | —                                        | starting           |
/// | running              | working / absent                         | working            |
/// | running              | waiting_for_user                         | waitingForUser     |
/// | running              | waiting_for_approval                     | waitingForApproval |
/// | running              | finished                                 | finished           |
/// | exit                 | —                                        | finished           |
/// | error                | —                                        | failed             |
/// | suspended            | error / payment_declined / contract_expired | failed          |
/// | suspended            | usage_limit_exceeded, out_of_credits, out_of_quota, no_quota_allocation, org_usage_limit_exceeded, user_usage_limit_exceeded, total_session_limit_exceeded | rateLimited |
/// | suspended            | inactivity / user_request / other       | ended              |
/// | anything unrecognized| —                                        | unknown            |
///
/// Unknown values degrade to a "still active" reading rather than success or
/// failure, so a future API status never crashes Coucou or reports a dead
/// session as finished; the tracker only keeps an unresolved status fresh for
/// `DevinTracker.unknownWindow`, so it cannot show "working" forever either.
enum DevinPhase: Equatable {
    case starting
    case working
    case waitingForUser
    case waitingForApproval
    case finished
    case failed
    case rateLimited
    case ended
    case unknown

    init(status: String?, detail: String?) {
        let s = (status ?? "").lowercased()
        let d = (detail ?? "").lowercased()
        switch s {
        case "new", "claimed", "resuming":
            self = .starting
        case "running":
            switch d {
            case "waiting_for_user":      self = .waitingForUser
            case "waiting_for_approval":  self = .waitingForApproval
            case "finished":              self = .finished
            default:                      self = .working   // working, absent or unrecognized detail
            }
        case "exit":
            self = .finished
        case "error":
            self = .failed
        case "suspended":
            switch d {
            case "error", "payment_declined", "contract_expired":
                self = .failed
            case "usage_limit_exceeded", "out_of_credits", "out_of_quota", "no_quota_allocation",
                 "org_usage_limit_exceeded", "user_usage_limit_exceeded", "total_session_limit_exceeded":
                self = .rateLimited
            default:
                self = .ended   // inactivity, user_request, absent or unrecognized detail
            }
        default:
            self = .unknown
        }
    }

    /// True when the session needs the user (reliably exposed by the API as
    /// status_detail waiting_for_user / waiting_for_approval).
    var isAttention: Bool { self == .waitingForUser || self == .waitingForApproval }

    /// True while the session still exists remotely and should keep being tracked.
    /// Terminal phases (finished / failed / ended) are only kept for a grace window.
    var isLive: Bool {
        switch self {
        case .starting, .working, .waitingForUser, .waitingForApproval, .rateLimited, .unknown:
            return true
        case .finished, .failed, .ended:
            return false
        }
    }

    /// Terminal phases age out of the pill after a display window.
    var isTerminal: Bool {
        switch self {
        case .finished, .failed, .ended: return true
        default: return false
        }
    }
}

// MARK: - Session

struct DevinPullRequest: Equatable {
    let url: String
    let state: String?

    static func parse(_ obj: [String: Any]) -> DevinPullRequest? {
        guard let url = obj["pr_url"] as? String, !url.isEmpty else { return nil }
        return DevinPullRequest(url: url, state: obj["pr_state"] as? String)
    }
}

struct DevinSession: Equatable {
    let id: String            // session_id ("devin-…") — the stable remote identifier
    let url: String           // official session URL, straight from the API
    let title: String          // session title, "" when the API has none yet
    let status: String         // raw status, kept for unknown-value degradation
    let statusDetail: String? // raw status_detail (nil when absent)
    let orgId: String
    let createdAt: Date?      // epoch seconds
    let updatedAt: Date?
    let pullRequests: [DevinPullRequest]

    var phase: DevinPhase { DevinPhase(status: status, detail: statusDetail) }

    /// Ticker-friendly name: the session title, else the tail of the session id.
    var displayName: String {
        if !title.isEmpty { return title }
        if id.hasPrefix("devin-") { return String(id.dropFirst("devin-".count)).prefix(8).description }
        return id.prefix(8).description
    }

    // MARK: Parse (tolerant: one malformed item never drops the whole page)

    static func parse(_ obj: [String: Any]) -> DevinSession? {
        guard let id = obj["session_id"] as? String, !id.isEmpty,
              let url = obj["url"] as? String, !url.isEmpty,
              let status = obj["status"] as? String else { return nil }
        let epoch = { (_ key: String) -> Date? in
            guard let t = obj[key] as? Int, t > 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(t))
        }
        let prs = (obj["pull_requests"] as? [[String: Any]] ?? [])
            .compactMap { DevinPullRequest.parse($0) }
        return DevinSession(
            id: id,
            url: url,
            title: (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            status: status,
            statusDetail: obj["status_detail"] as? String,
            orgId: obj["org_id"] as? String ?? "",
            createdAt: epoch("created_at"),
            updatedAt: epoch("updated_at"),
            pullRequests: prs
        )
    }
}

// MARK: - Session page (cursor pagination)

struct DevinSessionPage: Equatable {
    let items: [DevinSession]
    let hasNextPage: Bool
    let endCursor: String?

    static func parse(_ data: Data) -> DevinSessionPage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawItems = root["items"] as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        let items = rawItems.compactMap { raw -> DevinSession? in
            guard let s = DevinSession.parse(raw), seen.insert(s.id).inserted else { return nil }
            return s
        }
        return DevinSessionPage(
            items: items,
            hasNextPage: root["has_next_page"] as? Bool ?? false,
            endCursor: root["end_cursor"] as? String
        )
    }

    /// Merges the pages of a single poll (discovery page + by-id refresh) into
    /// one, deduplicating by session id — first occurrence wins.
    static func merge(_ pages: [DevinSessionPage]) -> DevinSessionPage {
        var seen = Set<String>()
        var items: [DevinSession] = []
        var hasNext = false
        for page in pages {
            for session in page.items where seen.insert(session.id).inserted {
                items.append(session)
            }
            hasNext = hasNext || page.hasNextPage
        }
        return DevinSessionPage(items: items, hasNextPage: hasNext,
                                endCursor: pages.last?.endCursor)
    }
}

// MARK: - Identity (GET /v3/self with a Personal Access Token)

struct DevinIdentity: Equatable {
    let principalType: String
    let userId: String
    let userName: String
    /// Organization the caller's Devin Cloud sessions run in (devin_sessions_org_id).
    /// Nil when the account has no usable organization — Devin cannot be monitored then.
    let sessionsOrgId: String?

    static func parse(_ data: Data) -> DevinIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let principal = root["principal_type"] as? String,
              let userId = root["user_id"] as? String,
              let userName = root["user_name"] as? String else { return nil }
        return DevinIdentity(
            principalType: principal,
            userId: userId,
            userName: userName,
            sessionsOrgId: root["devin_sessions_org_id"] as? String
        )
    }
}

// MARK: - Tracker (pure multi-session reducer)

/// What changed for one session between two polls. The monitor turns these into
/// ticker steps, sounds and badges — the tracker itself never touches AppState.
struct DevinEvent: Equatable {
    enum Kind: Equatable {
        case started           // session appeared while Coucou was watching
        case working           // became / still is actively working
        case waiting           // needs the user (input or approval)
        case finished          // task complete
        case failed           // error status or failure-like suspension
        case rateLimited       // suspended on a usage / credit / quota limit
        case suspended         // ended by the user, inactivity, or removed
        case prReady           // a pull request appeared
    }
    let sessionId: String
    let title: String
    let kind: Kind
}

/// In-memory view of the sessions the pill should represent. Sessions are keyed
/// by their official Devin session id, so concurrent sessions can never overwrite
/// each other; a transition on one session does not affect any other.
struct DevinTracker: Equatable {
    private(set) var sessions: [String: DevinSession] = [:]
    private(set) var firstPollDone = false

    /// How long a terminal session (finished / failed / ended) stays on the pill
    /// after its last update before Coucou drops it. Mirrors the Stripe poller's
    /// 60 s "finished" clear-out.
    static let terminalWindow: TimeInterval = 60
    /// An unrecognized status is watched while fresh, but if the API never
    /// resolves it (a renamed terminal status left in the list), the session
    /// leaves the pill after this window instead of showing "working" forever.
    /// It recovers on the next poll that sees a status we understand.
    static let unknownWindow: TimeInterval = 24 * 3600

    // MARK: Ingest

    /// Merges one poll's page. Returns the events worth surfacing; the first
    /// poll after launch is silent (pre-existing sessions populate the pill without
    /// playing sounds, exactly like the GitHub pulse poller).
    mutating func ingest(_ page: DevinSessionPage, now: Date = Date()) -> [DevinEvent] {
        var events: [DevinEvent] = []
        var incoming: [String: DevinSession] = [:]
        for session in page.items where isTrackable(session, now: now) {
            incoming[session.id] = session
        }

        if !firstPollDone {
            // First poll: adopt everything silently.
            sessions = incoming
            firstPollDone = true
            return []
        }

        // New and changed sessions.
        for session in incoming.values.sorted(by: { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }) {
            let prev = sessions[session.id]
            let event = event(for: session, prev: prev)
            if let event { events.append(event) }
            sessions[session.id] = session
        }

        // Sessions gone from the page (archived, deleted, or filtered out).
        // A session stuck in an unrecognized status past unknownWindow leaves
        // silently: "suspended" would claim a state the API never confirmed.
        for (id, prev) in sessions.filter({ incoming[$0.key] == nil }) {
            sessions.removeValue(forKey: id)
            if prev.phase.isLive && !isStaleUnknown(prev, now: now) {
                events.append(DevinEvent(sessionId: id, title: prev.displayName, kind: .suspended))
            }
        }

        return events
    }

    /// Drops everything (disconnect). Returns the ids that were being watched.
    mutating func reset() -> [String] {
        let ids = Array(sessions.keys)
        sessions = [:]
        firstPollDone = false
        return ids
    }

    /// Whether a session belongs in the tracker: live sessions and terminal
    /// sessions still inside their display window — and unrecognized statuses
    /// only while fresh (unknownWindow above).
    private func isTrackable(_ session: DevinSession, now: Date) -> Bool {
        if isStaleUnknown(session, now: now) { return false }
        return session.phase.isLive || isRecentTerminal(session, now: now)
    }

    private func isStaleUnknown(_ session: DevinSession, now: Date) -> Bool {
        guard session.phase == .unknown, let updated = session.updatedAt else { return false }
        return now.timeIntervalSince(updated) >= Self.unknownWindow
    }

    private func isRecentTerminal(_ session: DevinSession, now: Date) -> Bool {
        guard session.phase.isTerminal else { return true }
        guard let updated = session.updatedAt else { return true }   // no timestamp: keep, the next poll decides
        return now.timeIntervalSince(updated) < Self.terminalWindow
    }

    private func event(for session: DevinSession, prev: DevinSession?) -> DevinEvent? {
        let title = session.displayName
        guard let prev else {
            // A session that was already terminal before Coucou watched is not news.
            guard session.phase.isLive else { return nil }
            return DevinEvent(sessionId: session.id, title: title, kind: .started)
        }
        if session.pullRequests.count > prev.pullRequests.count {
            return DevinEvent(sessionId: session.id, title: title, kind: .prReady)
        }
        guard session.phase != prev.phase else { return nil }   // same state, no update noise
        switch session.phase {
        case .starting, .working, .unknown:
            return DevinEvent(sessionId: session.id, title: title, kind: .working)
        case .waitingForUser, .waitingForApproval:
            return DevinEvent(sessionId: session.id, title: title, kind: .waiting)
        case .finished:
            return DevinEvent(sessionId: session.id, title: title, kind: .finished)
        case .failed:
            return DevinEvent(sessionId: session.id, title: title, kind: .failed)
        case .rateLimited:
            return DevinEvent(sessionId: session.id, title: title, kind: .rateLimited)
        case .ended:
            return DevinEvent(sessionId: session.id, title: title, kind: .suspended)
        }
    }

    // MARK: Aggregate

    /// Single phase for the whole pill, most urgent first:
    /// failed > waiting > rate-limited > working > starting > finished.
    /// nil when no session is left to show.
    var aggregatePhase: DevinPhase? {
        let phases = sessions.values.map(\.phase)
        if phases.isEmpty { return nil }
        if phases.contains(.failed) { return .failed }
        if phases.contains(where: { $0.isAttention }) { return .waitingForUser }
        if phases.contains(.rateLimited) { return .rateLimited }
        if phases.contains(.working) || phases.contains(.unknown) { return .working }
        if phases.contains(.starting) { return .starting }
        if phases.contains(.finished) { return .finished }
        return .ended
    }

    /// The session that defines the pill name and open-in-Devin target: the most
    /// recently updated session among the ones driving the aggregate phase.
    var leadSession: DevinSession? {
        sessions.values
            .filter { $0.phase == aggregatePhase }
            .max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }

    /// The session the pill opens in Devin — deterministic rule, most relevant
    /// first: the waiting session that updated last, else the live session that
    /// updated last, else the session that updated last. updated_at ties break
    /// on session id, so the choice cannot flicker between polls.
    var bestSession: DevinSession? {
        let ranked = sessions.values.sorted {
            ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id)
        }
        return ranked.first { $0.phase.isAttention }
            ?? ranked.first { $0.phase.isLive }
            ?? ranked.first
    }

    var liveCount: Int { sessions.values.filter { $0.phase.isLive }.count }
    var totalCount: Int { sessions.count }
}

// MARK: - Poll schedule (pure, testable)

enum DevinSchedule {
    /// Cadence while at least one session is live — fast enough to feel current,
    /// slow enough to stay far from the API's rate limits.
    static let activeInterval: TimeInterval = 20
    /// Cadence with no live session: enough to discover a session started in the
    /// Devin web app or CLI, cheap enough for a background desktop app.
    static let discoveryInterval: TimeInterval = 120
    /// Floor and ceiling for error backoff (doubling from the floor).
    static let backoffFloor: TimeInterval = 60
    static let backoffCeiling: TimeInterval = 600

    static func backoffDelay(consecutiveErrors: Int) -> TimeInterval {
        guard consecutiveErrors > 0 else { return discoveryInterval }
        let doubled = backoffFloor * pow(2, Double(min(consecutiveErrors - 1, 10)))
        return min(doubled, backoffCeiling)
    }

    static func nextDelay(hasLive: Bool, consecutiveErrors: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter, retryAfter > 0 { return min(retryAfter, backoffCeiling) }
        if consecutiveErrors > 0 { return backoffDelay(consecutiveErrors: consecutiveErrors) }
        return hasLive ? activeInterval : discoveryInterval
    }
}
