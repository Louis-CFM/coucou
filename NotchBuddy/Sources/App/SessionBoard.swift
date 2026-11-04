import Foundation

// MARK: - SessionBoard
// What each session behind a pill shows: its title, state, steps and last message.
//
// A pill belongs to a client (VS Code, the Claude app, Codex…), and every session of that
// client lands on it (PillSessionRegistry). The board keeps each session apart, so the pill
// can show one session at a time, whole: the most urgent one, else the one active last, held
// for a few seconds so the pill does not flip between busy sessions. Open, the card lists
// them all. A session that starts waiting for a permission or an answer while it shares the
// pill pops out into a pill of its own ("<pill>#2"…) and folds back once it is answered.
//
// Pure value: HookServer owns it and changes it on the main actor only.

struct BoardSession: Equatable, Sendable {
    var title: String
    /// The id the session's hook events carry ("unknown" for one that sends none).
    var rawSession: String
    var state: BotState = .idle
    var steps: [String] = []
    var finalLine: String? = nil
    var lastActive: Date
    /// When its last turn finished or failed: for a moment that is what its pill shows.
    var endedAt: Date? = nil

    mutating func appendStep(_ step: String) {
        steps.append(step)
        if steps.count > SessionBoard.maxSteps { steps.removeFirst(steps.count - SessionBoard.maxSteps) }
    }
}

struct SessionBoard: Sendable {
    static let maxSteps = 20
    /// A finished turn shows on its pill this long, ahead of a sibling still working.
    static let finishMoment: TimeInterval = 5.2
    /// A failed turn shows on its pill this long, ahead of a sibling still working.
    static let errorMoment: TimeInterval = 30
    /// A pill keeps showing a session this long before an equally urgent one may take over.
    static let minHold: TimeInterval = 6
    /// A popped-out session stays out this long at least, so a quick answer does not flash it.
    static let minPopOut: TimeInterval = 3
    /// A sibling silent for this long (a terminal killed without SessionEnd, say) does not make
    /// a waiting session pop out: there is nobody else to keep the client's pill for.
    static let siblingQuiet: TimeInterval = 30 * 60

    private struct PopOut: Equatable, Sendable {
        var number: Int
        var since: Date
    }

    private struct Pill: Sendable {
        /// Sessions in the order they first came.
        var order: [String] = []
        var sessions: [String: BoardSession] = [:]
        var shown: String? = nil
        var shownSince: Date = .distantPast
        var popped: [String: PopOut] = [:]
    }

    private var pills: [String: Pill] = [:]

    static func poppedPillId(_ pill: String, number: Int) -> String { "\(pill)#\(number)" }

    // MARK: Recording

    /// Applies `change` to `session` behind `pill`, adding the session on first sight. A
    /// non-empty `title` renames it; every update counts as activity.
    mutating func update(pill: String, session: String, rawSession: String, title: String,
                         now: Date, _ change: (inout BoardSession) -> Void = { _ in }) {
        var p = pills[pill] ?? Pill()
        if p.sessions[session] == nil { p.order.append(session) }
        var s = p.sessions[session] ?? BoardSession(title: title, rawSession: rawSession, lastActive: now)
        if !title.isEmpty { s.title = title }
        s.rawSession = rawSession
        s.lastActive = now
        change(&s)
        p.sessions[session] = s
        pills[pill] = p
    }

    /// Changes `session` without counting it as activity (a timer, not an event). No-op if unknown.
    mutating func amend(pill: String, session: String, _ change: (inout BoardSession) -> Void) {
        guard var s = pills[pill]?.sessions[session] else { return }
        change(&s)
        pills[pill]?.sessions[session] = s
    }

    func session(pill: String, session: String) -> BoardSession? { pills[pill]?.sessions[session] }

    func sessionCount(pill: String) -> Int { pills[pill]?.order.count ?? 0 }

    /// Drops a session that ended. Returns the pill it had popped out into, if any.
    @discardableResult
    mutating func remove(pill: String, session: String) -> String? {
        guard var p = pills[pill] else { return nil }
        p.order.removeAll { $0 == session }
        p.sessions.removeValue(forKey: session)
        let popped = p.popped.removeValue(forKey: session).map { Self.poppedPillId(pill, number: $0.number) }
        if p.shown == session { p.shown = nil }
        pills[pill] = p.order.isEmpty ? nil : p
        return popped
    }

    /// Drops the sessions of `pill` that `isLive` says are gone (silent for hours, so the
    /// registry let them go). Returns the pills they had popped out into.
    mutating func keep(pill: String, where isLive: (BoardSession) -> Bool) -> [String] {
        guard let p = pills[pill] else { return [] }
        return p.order.filter { !isLive(p.sessions[$0]!) }.compactMap { remove(pill: pill, session: $0) }
    }

    // MARK: What the pill shows

    /// Lower is more urgent: waiting for you, a turn that just failed, one that just finished,
    /// work in progress, an older finish, idle.
    static func rank(_ s: BoardSession, waiting: Bool, now: Date) -> Int {
        if waiting { return 0 }
        let since = s.endedAt.map { now.timeIntervalSince($0) } ?? .infinity
        switch s.state {
        case .error:    return since < errorMoment ? 1 : 4
        case .finished: return since < finishMoment ? 2 : 4
        case .idle, .sleeping, .dizzy: return 5
        default:        return 3   // working, thinking, searching, ratelimit, question, approval
        }
    }

    /// The session `pill` shows, among those not popped out: the most urgent, then the one
    /// active last. The one shown keeps the pill `minHold` unless a more urgent one comes.
    /// `waiting` holds the sessions waiting for an answer.
    mutating func shown(pill: String, waiting: Set<String>, now: Date) -> String? {
        guard var p = pills[pill] else { return nil }
        let candidates = p.order.filter { p.popped[$0] == nil }
        func rank(_ id: String) -> Int { Self.rank(p.sessions[id]!, waiting: waiting.contains(id), now: now) }
        guard var best = candidates.first else { return nil }
        for id in candidates.dropFirst() {
            let (r, b) = (rank(id), rank(best))
            if r < b || (r == b && p.sessions[id]!.lastActive > p.sessions[best]!.lastActive) { best = id }
        }
        if let current = p.shown, current != best, candidates.contains(current),
           rank(current) <= rank(best), now.timeIntervalSince(p.shownSince) < Self.minHold {
            return current
        }
        if p.shown != best {
            p.shown = best
            p.shownSince = now
            pills[pill] = p
        }
        return best
    }

    /// The sessions still in `pill` (not popped out), in the order they came, for the open
    /// card. Empty when only one is: the card then shows that session as it always has.
    func lines(pill: String) -> [(session: String, value: BoardSession)] {
        guard let p = pills[pill] else { return [] }
        let inside = p.order.filter { p.popped[$0] == nil }
        guard inside.count > 1 else { return [] }
        return inside.map { ($0, p.sessions[$0]!) }
    }

    // MARK: Popping out

    /// Pops `session` out into a pill of its own when it starts waiting while another session,
    /// not popped out and active lately, shares the pill. Returns that pill, nil when the
    /// session stays (it is alone).
    mutating func popOut(pill: String, session: String, now: Date) -> String? {
        guard var p = pills[pill], p.sessions[session] != nil else { return nil }
        if let out = p.popped[session] { return Self.poppedPillId(pill, number: out.number) }
        guard p.order.contains(where: {
            $0 != session && p.popped[$0] == nil
                && now.timeIntervalSince(p.sessions[$0]!.lastActive) < Self.siblingQuiet
        }) else { return nil }
        let taken = Set(p.popped.values.map(\.number))
        let number = (2...).first { !taken.contains($0) }!
        p.popped[session] = PopOut(number: number, since: now)
        if p.shown == session { p.shown = nil }
        pills[pill] = p
        return Self.poppedPillId(pill, number: number)
    }

    func poppedPill(pill: String, session: String) -> String? {
        pills[pill]?.popped[session].map { Self.poppedPillId(pill, number: $0.number) }
    }

    /// The sessions popped out of `pill`, oldest out first, with their pills.
    func poppedOut(pill: String) -> [(session: String, pill: String)] {
        guard let p = pills[pill] else { return [] }
        return p.popped.sorted { ($0.value.since, $0.value.number) < ($1.value.since, $1.value.number) }
            .map { ($0.key, Self.poppedPillId(pill, number: $0.value.number)) }
    }

    /// Folds back into `pill` the popped-out sessions that no longer wait, once out for
    /// `minPopOut`, and all of them when no session is left in the pill. Returns the pills
    /// folded, and when to look again for the ones that must stay out a little longer.
    mutating func fold(pill: String, waiting: Set<String>, now: Date) -> (folded: [String], recheck: Date?) {
        guard var p = pills[pill], !p.popped.isEmpty else { return ([], nil) }
        let emptyInside = !p.order.contains { p.popped[$0] == nil }
        var folded: [String] = []
        var recheck: Date? = nil
        for (session, out) in p.popped.sorted(by: { $0.value.number < $1.value.number }) {
            let due = out.since.addingTimeInterval(Self.minPopOut)
            if emptyInside || (!waiting.contains(session) && now >= due) {
                p.popped.removeValue(forKey: session)
                folded.append(Self.poppedPillId(pill, number: out.number))
            } else if !waiting.contains(session) {
                recheck = min(recheck ?? due, due)
            }
        }
        pills[pill] = p
        return (folded, recheck)
    }

    // MARK: The places beside the focused pill

    enum Slot: Equatable, Sendable {
        case pill(String)
        /// Waiting pills with no place left: "+N", N being their count; a tap shows the first.
        case waiting([String])

        var id: String {
            switch self {
            case .pill(let id): return id
            case .waiting: return "waiting-stack"
            }
        }
    }

    struct Cell: Equatable, Sendable {
        var id: String
        var state: BotState
        /// A session popped out of its client's pill (it waits for you).
        var poppedOut: Bool
    }

    /// Fills the places beside the focused pill. Pills keep the order they have; a waiting one
    /// (popped out, or a pill waiting itself) that would not show takes a free place, else the
    /// place of the last idle pill, else of the last finished one, the one waiting longest
    /// first. Working and waiting pills keep theirs. When waiting pills are left over, the last
    /// place becomes "+N" for them and for the newest one that had a place: the ones waiting
    /// longest stay in sight.
    static func slots(_ cells: [Cell], places: Int = 4) -> [Slot] {
        func waits(_ c: Cell) -> Bool { c.poppedOut || c.state == .approval || c.state == .question }
        let inPlace = cells.filter { !$0.poppedOut }
        var visible = Array(inPlace.prefix(places))
        let queue = cells.filter(\.poppedOut) + inPlace.dropFirst(places).filter(waits)
        var placed: [String] = []
        var left: [String] = []
        for c in queue {
            if visible.count < places {
                visible.append(c)
                placed.append(c.id)
            } else if let i = visible.lastIndex(where: { !waits($0) && [.idle, .sleeping].contains($0.state) })
                        ?? visible.lastIndex(where: { !waits($0) && $0.state == .finished }) {
                visible[i] = c
                placed.append(c.id)
            } else {
                left.append(c.id)
            }
        }
        guard !left.isEmpty, !visible.isEmpty else { return visible.map { Slot.pill($0.id) } }
        // The stack takes one place: the newest waiting pill's (it joins the stack), else the last.
        let newest = placed.last.flatMap { id in visible.firstIndex { $0.id == id } }
        let covered = visible.remove(at: newest ?? visible.count - 1)
        return visible.map { Slot.pill($0.id) } + [.waiting((waits(covered) ? [covered.id] : []) + left)]
    }
}
