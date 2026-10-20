import Foundation

// MARK: - PillSessionRegistry

/// Keeps track of the agent sessions living behind each pill.
///
/// A pill is picked from the client that sent the event — bundle ID,
/// `term_program`, `coucou_agent` — never from the session. Two `claude`
/// started in two projects under VS Code therefore land on the same
/// `integration_claude`, while `AppState.tasks` holds one entry per pill.
/// Without a session set, the first session to end wipes the card and the
/// diffs the second one is still filling.
///
/// A value type on purpose: the hook server owns one copy and every change
/// goes through a `mutating` call, so no other object can alias the state.
struct PillSessionRegistry {

    /// A session unheard of for this long counts as gone. A `SessionEnd` that
    /// never arrives — a killed terminal, a crash — would otherwise pin a card
    /// to a session nobody is running any more.
    static let maxSilence: TimeInterval = 12 * 3600

    /// A session mid-turn emits a hook event every few seconds, so this long
    /// without one means its `Stop` went missing. Stops counting it as working,
    /// which is what keeps a sibling session from staying stuck out of its
    /// finished state. Longer than any tool call Claude Code will wait on.
    static let maxTurnSilence: TimeInterval = 30 * 60

    /// How far a terminal event is allowed to reach.
    enum TerminalScope: Equatable {
        /// No other session is mid-turn behind this pill, so the pill may
        /// follow: finished state, sound, badge, card removal.
        case pill
        /// Another session is still working — leave the pill as it is.
        case sessionOnly
    }

    /// What a pill shows while a session owns it.
    struct Display: Equatable {
        var session: String
        var projectName: String
        var cwd: String
        /// Terminal the session runs in (bundle id), for "Open terminal".
        var hostApp: String? = nil
        /// Bundle id of the client (VS Code, Cursor…) that sent the event.
        var bundleId: String = ""
    }

    private struct Session {
        var projectName: String
        var cwd: String
        var hostApp: String?
        var bundleId: String
        var isWorking: Bool
        var lastSeen: Date
        /// Last time the session was mid-turn or ended a turn. A stray notification
        /// from an idle session does not move it, unlike `lastSeen`.
        var lastWorked: Date = .distantPast
    }

    private struct Pill {
        /// Live sessions, oldest first.
        var order: [String] = []
        var sessions: [String: Session] = [:]
    }

    private var pills: [String: Pill] = [:]

    // MARK: - Recording activity

    /// Records the session that sent an event as live behind `pill`.
    /// `working` says whether the event means the session is mid-turn: a
    /// `PreToolUse` does, a `SessionStart` or a stray notification does not.
    mutating func note(pill: String, display: Display, working: Bool, now: Date = Date()) {
        var p = pills[pill] ?? Pill()
        sweep(&p, now: now)
        if p.sessions[display.session] == nil {
            p.order.append(display.session)
        }
        var session = p.sessions[display.session]
            ?? Session(projectName: display.projectName, cwd: display.cwd,
                       hostApp: display.hostApp, bundleId: display.bundleId,
                       isWorking: false, lastSeen: now)
        session.projectName = display.projectName
        if !display.cwd.isEmpty { session.cwd = display.cwd }
        if display.hostApp != nil { session.hostApp = display.hostApp }
        if !display.bundleId.isEmpty { session.bundleId = display.bundleId }
        if working { session.isWorking = true; session.lastWorked = now }
        session.lastSeen = now
        p.sessions[display.session] = session
        pills[pill] = p
    }

    // MARK: - Terminal events

    /// Ends a session's turn without ending the session: a `Stop` closes a
    /// turn, and the user can send another prompt right after.
    ///
    /// A session we have never seen stays untracked — Coucou can start in the
    /// middle of one, and a session we only ever heard stop owns nothing.
    mutating func endTurn(pill: String, session: String, now: Date = Date()) -> TerminalScope {
        var p = pills[pill] ?? Pill()
        sweep(&p, now: now)
        p.sessions[session]?.isWorking = false
        p.sessions[session]?.lastSeen = now
        p.sessions[session]?.lastWorked = now
        if p.order.isEmpty { pills.removeValue(forKey: pill) } else { pills[pill] = p }
        return p.sessions.values.contains(where: \.isWorking) ? .sessionOnly : .pill
    }

    /// Drops a session for good. `.pill` only when it was the last one live,
    /// so the card and the diffs survive a sibling session ending.
    mutating func endSession(pill: String, session: String, now: Date = Date()) -> TerminalScope {
        var p = pills[pill] ?? Pill()
        sweep(&p, now: now)
        p.order.removeAll { $0 == session }
        p.sessions.removeValue(forKey: session)
        guard !p.order.isEmpty else {
            pills.removeValue(forKey: pill)
            return .pill
        }
        pills[pill] = p
        return .sessionOnly
    }

    // MARK: - Reading

    /// The session whose project name and cwd the pill shows, so the name matches
    /// the activity under it: the oldest session that is mid-turn (it keeps the
    /// name while parallel sessions work, so it does not flip between them), else
    /// the one that worked last, else the oldest live one.
    func displayOwner(of pill: String) -> Display? {
        guard let p = pills[pill] else { return nil }
        let working = p.order.first { p.sessions[$0]?.isWorking == true }
        // max(by:) keeps the first of equal elements: with no turn seen yet, the oldest.
        let lastWorked = p.order.max {
            (p.sessions[$0]?.lastWorked ?? .distantPast) < (p.sessions[$1]?.lastWorked ?? .distantPast)
        }
        guard let id = working ?? lastWorked, let session = p.sessions[id] else { return nil }
        return Display(session: id, projectName: session.projectName, cwd: session.cwd,
                       hostApp: session.hostApp, bundleId: session.bundleId)
    }

    /// Whether this session may write the pill's name and cwd. True when the
    /// pill has no live session yet, so a first event is never dropped.
    func ownsDisplay(pill: String, session: String) -> Bool {
        guard let owner = displayOwner(of: pill) else { return true }
        return owner.session == session
    }

    func liveCount(pill: String) -> Int { pills[pill]?.order.count ?? 0 }

    func workingCount(pill: String) -> Int {
        pills[pill]?.sessions.values.filter(\.isWorking).count ?? 0
    }

    // MARK: - Silence sweep

    private func sweep(_ pill: inout Pill, now: Date) {
        for (id, session) in pill.sessions.map({ ($0.key, $0.value) }) {
            let silence = now.timeIntervalSince(session.lastSeen)
            if silence > Self.maxSilence {
                pill.sessions.removeValue(forKey: id)
                pill.order.removeAll { $0 == id }
            } else if session.isWorking, silence > Self.maxTurnSilence {
                pill.sessions[id]?.isWorking = false
            }
        }
    }
}
