import Foundation

/// Gives every Claude Code session its own pill. The first session shows in the main
/// Claude Code pill; sessions running alongside it get an extra pill until they end.
struct ClaudeSessionPills {
    static let mainId = "integration_claude"
    /// An idle session silent this long gives up its pill.
    static let staleAfter: TimeInterval = 15 * 60
    /// A long Bash run fires no hooks, so a working session gets much longer.
    static let workingStaleAfter: TimeInterval = 2 * 60 * 60

    enum Activity { case idle, working, waitingOnUser }

    private(set) var mainSession: String?
    private var extra: [String: String] = [:]      // session ID → extra pill ID
    private var lastSeen: [String: Date] = [:]

    static func isSessionPill(_ id: String) -> Bool {
        id == mainId || id.hasPrefix("claude_")
    }

    /// The pill for an event of `session`. A quiet session's main pill is taken over.
    mutating func pill(for session: String, now: Date = Date(),
                       activity: (String) -> Activity = { _ in .idle }) -> String {
        defer { lastSeen[session] = now }
        if session == mainSession { return Self.mainId }
        if let id = extra[session] { return id }
        if let owner = mainSession, !isStale(owner, pill: Self.mainId, now: now, activity: activity) {
            let id = "claude_" + String(session.prefix(8))
            extra[session] = id
            return id
        }
        if let owner = mainSession { lastSeen[owner] = nil }
        mainSession = session
        return Self.mainId
    }

    /// Forgets `session`. Returns its pill, to reset (main) or remove (extra).
    mutating func end(_ session: String) -> String? {
        lastSeen[session] = nil
        if session == mainSession {
            mainSession = nil
            return Self.mainId
        }
        return extra.removeValue(forKey: session)
    }

    /// Extra pills whose session went quiet (closed terminal, no SessionEnd). Forgets them.
    mutating func pruneStale(now: Date = Date(), activity: (String) -> Activity = { _ in .idle }) -> [String] {
        let stale = extra.filter { isStale($0.key, pill: $0.value, now: now, activity: activity) }
        for (session, _) in stale {
            extra[session] = nil
            lastSeen[session] = nil
        }
        return Array(stale.values)
    }

    private func isStale(_ session: String, pill: String, now: Date, activity: (String) -> Activity) -> Bool {
        let limit: TimeInterval
        switch activity(pill) {
        case .waitingOnUser: return false
        case .working:       limit = Self.workingStaleAfter
        case .idle:          limit = Self.staleAfter
        }
        guard let seen = lastSeen[session] else { return true }
        return now.timeIntervalSince(seen) > limit
    }
}
