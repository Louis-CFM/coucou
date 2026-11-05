import Foundation

// MARK: - Android link: what the phone is told, and what it may decide
//
// The hub holds the last list of sessions, the one permission request and the one
// question still waiting, as the island publishes them. It knows nothing about
// sockets or AppState: connections subscribe to it, and a decision from a phone goes
// back to the app through `AndroidLinkHost`. That keeps every rule of
// docs/ANDROID_LINK.md testable without a window, exactly as the Rust `hub.rs` does.
//
// The rules that matter:
//   * a phone decision is applied only if its fingerprint is the one of the request that is
//     *still* pending (same session, tool, command and request);
//   * only one decision is ever applied per request;
//   * a request older than 115 s is dismissed, whatever the phone says;
//   * a command cut to 500 characters can be denied from the phone, never allowed;
//   * nothing here can block the agent: the Mac's own card keeps working, and a phone that never
//     answers changes nothing.

// MARK: What the island publishes

struct AndroidSessionIn: Equatable, Sendable {
    var pillId: String
    var agent: String
    var state: String = "idle"
    var statusText: String = ""
    var stepIndex: Int = 0
    var stepCount: Int = 0
    /// Details, sent only to phones that asked for and were offered `details`.
    var steps: [String] = []
    var finalLine: String? = nil
    /// The folder the session runs in; only its last segment is ever kept.
    var project: String? = nil
    var color: String? = nil
}

/// The permission request waiting on the island.
struct AndroidApprovalIn: Equatable, Sendable {
    var requestId: String
    var sessionId: String
    var pillId: String
    var tool: String
    var command: String
}

struct AndroidOptionIn: Equatable, Sendable {
    var label: String
    var description: String = ""
}

struct AndroidQuestionItemIn: Equatable, Sendable {
    var question: String
    var options: [AndroidOptionIn]
    var multiSelect: Bool = false
}

/// The question Claude Code is waiting on, as the island has it (cap `answers`).
struct AndroidQuestionIn: Equatable, Sendable {
    var requestId: String
    var sessionId: String
    var pillId: String
    var questions: [AndroidQuestionItemIn]
}

struct AndroidUsageWindowIn: Equatable, Sendable {
    var usedPct: Double
    var resetsAt: UInt64
}

struct AndroidUsagePlanIn: Equatable, Sendable {
    var fiveHour: AndroidUsageWindowIn? = nil
    var sevenDay: AndroidUsageWindowIn? = nil
    var plan: String? = nil
    var resetCredits: Int? = nil
    var updatedAt: UInt64? = nil
}

/// What the island's Claude and Codex pills show (cap `usage`).
struct AndroidUsageIn: Equatable, Sendable {
    var claude: AndroidUsagePlanIn? = nil
    var codex: AndroidUsagePlanIn? = nil
}

/// What a connection may have been offered.
struct AndroidLinkCaps: Equatable, Sendable {
    var details = false
    var answers = false
    var usage = false

    /// The `caps` of the welcome line, in the Rust order; empty means the field is left out.
    var offered: [String] {
        var list: [String] = []
        if details { list.append("details") }
        if answers { list.append("answers") }
        if usage { list.append("usage") }
        return list
    }
}

/// What reaches a connection's writer.
enum AndroidLinkOut: Equatable, Sendable {
    /// One JSON line, without its newline.
    case line(String)
    /// Tell the phone why, then close.
    case close(code: String, message: String)
}

/// How a decision gets back to the agent. The app's implementation answers the waiting
/// nb-hook exactly as a click on the island would, only for the request still pending.
protocol AndroidLinkHost: AnyObject, Sendable {
    func decide(requestId: String, allow: Bool)
    /// A phone answered a question: one list of labels per question, in order, already checked against
    /// the question's options. Only called for the question still pending; the app builds the agent's
    /// `{question: label}` shape with the island's own `AskQuestion.buildAnswers`.
    func answer(requestId: String, picks: [[String]])
}

/// What became of a decision from a phone.
enum AndroidLinkOutcome: Equatable, Sendable {
    case applied
    /// Not the pending request (another command, or already answered).
    case noMatch
    /// The request was pending but is older than the TTL.
    case late
    /// Neither `allow` nor `deny`, or picks that do not match the question.
    case invalid
    /// `allow` for a request whose command was cut to fit the phone: refused, the request stays pending.
    case tooLong
}

/// A subscriber's way out: true when the line was taken, false when the phone cannot keep up
/// (it is then dropped and closes, and reconnects to a fresh picture).
typealias AndroidLinkSender = @Sendable (AndroidLinkOut) -> Bool

final class AndroidLinkHub: @unchecked Sendable {
    private struct Session: Equatable {
        var pillId: String
        var agent: String
        var state: String
        var statusText: String
        var stepIndex: Int
        var stepCount: Int
        var updatedAt: UInt64
        var steps: [String]
        var finalLine: String?
        var project: String?
        var color: String?

        func sameContent(as other: Session) -> Bool {
            var a = self, b = other
            a.updatedAt = 0; b.updatedAt = 0
            return a == b
        }
    }

    private struct Approval {
        var requestId: String
        var fingerprint: String
        var pillId: String
        var tool: String
        var command: String
        /// The command was longer than `maxCommandChars` and the phone is shown only the start.
        var truncated: Bool
        var createdAt: UInt64
    }

    private struct Question {
        var requestId: String
        var fingerprint: String
        var pillId: String
        var items: [AndroidQuestionItemIn]
        var createdAt: UInt64
    }

    private struct Sub {
        let id: UInt64
        let send: AndroidLinkSender
        let caps: AndroidLinkCaps
    }

    private let host: AndroidLinkHost
    private let lock = NSLock()
    private var sessions: [Session] = []
    private var approval: Approval?
    private var question: Question?
    /// The last `usage` line (nil: the island has nothing to say).
    private var usage: String?
    private var subs: [Sub] = []
    private var nextSub: UInt64 = 0

    init(host: AndroidLinkHost) {
        self.host = host
    }

    // MARK: Publishing

    /// The island's current picture. Sends the phones only what changed.
    func publish(sessions incoming: [AndroidSessionIn], approval incomingApproval: AndroidApprovalIn?, now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let P = AndroidLinkProtocol.self
        var next: [Session] = []
        for s in incoming.filter({ !$0.pillId.isEmpty }).prefix(P.maxSessions) {
            var fresh = Session(
                pillId: s.pillId,
                agent: P.clip(s.agent, 64),
                state: P.states.contains(s.state) ? s.state : "idle",
                statusText: P.clip(s.statusText, P.maxTextChars),
                stepIndex: s.stepIndex,
                stepCount: s.stepCount,
                updatedAt: now,
                steps: P.cleanSteps(s.steps),
                finalLine: s.finalLine.map { P.clip($0, P.maxTextChars) }.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
                project: s.project.flatMap(P.projectName),
                color: s.color.flatMap { P.isColor($0) ? $0 : nil })
            if let old = sessions.first(where: { $0.pillId == fresh.pillId }), old.sameContent(as: fresh) {
                fresh.updatedAt = old.updatedAt
            }
            next.append(fresh)
        }
        if next != sessions {
            sessions = next
            broadcastSessions()
        }

        // The pending request: a new one replaces the old, none retracts it.
        let same: Bool
        switch (approval, incomingApproval) {
        case (let a?, let b?): same = a.requestId == b.requestId
        case (nil, nil): same = true
        default: same = false
        }
        if same { return }
        if let old = approval {
            approval = nil
            broadcast(Self.resolvedLine(old.fingerprint))
        }
        if let a = incomingApproval, !a.requestId.isEmpty {
            let tool = P.clip(a.tool, 64)
            let truncated = P.length(a.command) > P.maxCommandChars
            let command = P.clip(a.command, P.maxCommandChars)
            let fresh = Approval(
                requestId: a.requestId,
                fingerprint: P.fingerprint(pillId: a.pillId, sessionId: a.sessionId, tool: tool, command: command, inputKey: a.requestId),
                pillId: a.pillId, tool: tool, command: command, truncated: truncated, createdAt: now)
            approval = fresh
            broadcast(Self.approvalLine(fresh))
        }
    }

    /// The question the island shows, or nil when none waits. Only phones with `answers` hear of it.
    func publishQuestion(_ incoming: AndroidQuestionIn?, now: UInt64) {
        lock.lock(); defer { lock.unlock() }
        let usable = incoming.flatMap { !$0.requestId.isEmpty && Self.fitsTheLimits($0.questions) ? $0 : nil }
        let same: Bool
        switch (question, usable) {
        case (let a?, let b?): same = a.requestId == b.requestId
        case (nil, nil): same = true
        default: same = false
        }
        if same { return }
        if let old = question {
            question = nil
            broadcast(Self.resolvedLine(old.fingerprint), onlyTo: { $0.answers })
        }
        if let q = usable {
            let texts = q.questions.map(\.question).joined(separator: "\n")
            let fresh = Question(
                requestId: q.requestId,
                fingerprint: AndroidLinkProtocol.fingerprint(pillId: q.pillId, sessionId: q.sessionId, tool: "AskUserQuestion",
                                                             command: texts, inputKey: q.requestId),
                pillId: q.pillId, items: q.questions, createdAt: now)
            question = fresh
            broadcast(Self.questionLine(fresh), onlyTo: { $0.answers })
        }
    }

    /// The plan usage. Only phones with `usage` hear of it; a change with nothing usable left is sent as a
    /// bare `{"type":"usage"}`, which makes the phone remove its panel.
    func publishUsage(_ incoming: AndroidUsageIn?) {
        lock.lock(); defer { lock.unlock() }
        let next = incoming.flatMap(Self.usageLine)
        if next == usage { return }
        usage = next
        broadcast(next ?? AndroidLinkProtocol.json(["type": "usage"]), onlyTo: { $0.usage })
    }

    // MARK: Subscribers

    /// Registers a connection that has authenticated. It is sent what brings it up to date: the
    /// sessions, then the request still waiting, the question (with `answers`) and the usage (with `usage`).
    @discardableResult
    func subscribe(caps: AndroidLinkCaps, now: UInt64, send: @escaping AndroidLinkSender) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        expire(now: now)
        let id = nextSub
        nextSub += 1
        _ = send(.line(Self.sessionsLine(sessions, details: caps.details)))
        if let a = approval { _ = send(.line(Self.approvalLine(a))) }
        if caps.answers, let q = question { _ = send(.line(Self.questionLine(q))) }
        if caps.usage, let u = usage { _ = send(.line(u)) }
        subs.append(Sub(id: id, send: send, caps: caps))
        return id
    }

    func unsubscribe(_ id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        subs.removeAll { $0.id == id }
    }

    /// Unpaired or switched off: every connection is told and closed.
    func kickAll(code: String, message: String) {
        lock.lock()
        let gone = subs
        subs = []
        lock.unlock()
        for s in gone { _ = s.send(.close(code: code, message: message)) }
    }

    var clients: Int {
        lock.lock(); defer { lock.unlock() }
        return subs.count
    }

    // MARK: Decisions

    /// A phone's answer. Applied only for the request that is still pending.
    func decide(fingerprint: String, decision: String, now: UInt64) -> AndroidLinkOutcome {
        let allow: Bool
        switch decision {
        case "allow": allow = true
        case "deny": allow = false
        default: return .invalid
        }
        lock.lock()
        guard let a = approval, AndroidLinkProtocol.constantEq(a.fingerprint, fingerprint) else {
            lock.unlock()
            return .noMatch
        }
        // A command the phone could not show in full is never allowed from the phone, whatever the phone says.
        if allow && a.truncated {
            lock.unlock()
            return .tooLong
        }
        // Taken in every case: a request is answered once, or dismissed.
        approval = nil
        broadcast(Self.resolvedLine(a.fingerprint))
        let late = Self.age(now, since: a.createdAt) > AndroidLinkProtocol.approvalTTLms
        lock.unlock()
        if late { return .late }
        // Outside the lock: the host answers the agent and touches the island.
        host.decide(requestId: a.requestId, allow: allow)
        return .applied
    }

    /// A phone's answer to the question that is still pending. `picks` has one list of labels per question,
    /// in order. Applied only if every label is exactly one of that question's options, one label for a
    /// single choice and at least one (each at most once) for a multiple choice; anything else changes nothing.
    func answer(fingerprint: String, picks: [[String]], now: UInt64) -> AndroidLinkOutcome {
        lock.lock()
        guard let q = question, AndroidLinkProtocol.constantEq(q.fingerprint, fingerprint) else {
            lock.unlock()
            return .noMatch
        }
        guard Self.picksMatch(q.items, picks: picks) else {
            lock.unlock()
            return .invalid
        }
        question = nil
        broadcast(Self.resolvedLine(q.fingerprint), onlyTo: { $0.answers })
        let late = Self.age(now, since: q.createdAt) > AndroidLinkProtocol.approvalTTLms
        lock.unlock()
        if late { return .late }
        host.answer(requestId: q.requestId, picks: picks)
        return .applied
    }

    // MARK: Rules (pure, for the tests)

    static func fitsTheLimits(_ items: [AndroidQuestionItemIn]) -> Bool {
        let P = AndroidLinkProtocol.self
        guard !items.isEmpty, items.count <= P.maxQuestions else { return false }
        return items.allSatisfy { item in
            let labels = item.options.map(\.label)
            return !item.question.trimmingCharacters(in: .whitespaces).isEmpty
                && P.length(item.question) <= P.maxQuestionChars
                && !labels.isEmpty && labels.count <= P.maxOptions
                && labels.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty && P.length($0) <= P.maxLabelChars }
                && item.options.allSatisfy { P.length($0.description) <= P.maxDescriptionChars }
                // two options with the same label could not be told apart in an answer
                && Set(labels).count == labels.count
        }
    }

    /// One list per question; each label one of that question's (exact, case-sensitive), once; one label for a
    /// single choice, one or more for a multiple choice.
    static func picksMatch(_ items: [AndroidQuestionItemIn], picks: [[String]]) -> Bool {
        guard picks.count == items.count else { return false }
        for (item, chosen) in zip(items, picks) {
            if chosen.isEmpty || chosen.count > item.options.count || (!item.multiSelect && chosen.count != 1) { return false }
            var seen: Set<String> = []
            for label in chosen {
                guard item.options.contains(where: { $0.label == label }), !seen.contains(label) else { return false }
                seen.insert(label)
            }
        }
        return true
    }

    /// Milliseconds since `since`, 0 when the clock went backwards.
    static func age(_ now: UInt64, since: UInt64) -> UInt64 {
        now >= since ? now - since : 0
    }

    // MARK: Lines

    private func broadcast(_ line: String, onlyTo wants: (AndroidLinkCaps) -> Bool = { _ in true }) {
        subs.removeAll { s in wants(s.caps) && !s.send(.line(line)) }
    }

    /// Every phone gets the picture it asked for: the v1 line, or the one with details.
    private func broadcastSessions() {
        var lines: [Bool: String] = [:]
        subs.removeAll { s in
            let line: String
            if let known = lines[s.caps.details] { line = known } else {
                line = Self.sessionsLine(sessions, details: s.caps.details)
                lines[s.caps.details] = line
            }
            return !s.send(.line(line))
        }
    }

    private func expire(now: UInt64) {
        if let q = question, Self.age(now, since: q.createdAt) > AndroidLinkProtocol.approvalTTLms {
            question = nil
            broadcast(Self.resolvedLine(q.fingerprint), onlyTo: { $0.answers })
        }
        if let a = approval, Self.age(now, since: a.createdAt) > AndroidLinkProtocol.approvalTTLms {
            approval = nil
            broadcast(Self.resolvedLine(a.fingerprint))
        }
    }

    private static func sessionJSON(_ s: Session) -> [String: Any] {
        ["pillId": s.pillId, "agent": s.agent, "state": s.state, "statusText": s.statusText,
         "stepIndex": s.stepIndex, "stepCount": s.stepCount, "updatedAt": s.updatedAt]
    }

    /// The v1 line, or the one with `steps`, `finalLine`, `project` and `color` where there is something to
    /// say. Steps are dropped from the oldest first (and then from all sessions) until the line fits the budget.
    private static func sessionsLine(_ sessions: [Session], details: Bool) -> String {
        var keep = AndroidLinkProtocol.maxSteps
        while true {
            let list: [[String: Any]] = sessions.map { s in
                var v = sessionJSON(s)
                if details {
                    let steps = Array(s.steps.suffix(keep))
                    if !steps.isEmpty { v["steps"] = steps }
                    if let l = s.finalLine { v["finalLine"] = l }
                    if let p = s.project { v["project"] = p }
                    if let c = s.color { v["color"] = c }
                }
                return v
            }
            let line = AndroidLinkProtocol.json(["type": "sessions", "sessions": list])
            if !details || line.utf8.count <= AndroidLinkProtocol.detailsLineBudget || keep == 0 { return line }
            keep /= 2
        }
    }

    private static func approvalLine(_ a: Approval) -> String {
        AndroidLinkProtocol.json(["type": "approval", "pillId": a.pillId, "fingerprint": a.fingerprint, "tool": a.tool,
                                  "command": a.command, "truncated": a.truncated, "createdAt": a.createdAt])
    }

    private static func resolvedLine(_ fingerprint: String) -> String {
        AndroidLinkProtocol.json(["type": "approvalResolved", "fingerprint": fingerprint])
    }

    private static func questionLine(_ q: Question) -> String {
        let questions: [[String: Any]] = q.items.map { item in
            ["question": item.question, "multiSelect": item.multiSelect,
             "options": item.options.map { ["label": $0.label, "description": $0.description] }]
        }
        return AndroidLinkProtocol.json(["type": "question", "pillId": q.pillId, "fingerprint": q.fingerprint,
                                         "createdAt": q.createdAt, "questions": questions])
    }

    private static func windowJSON(_ w: AndroidUsageWindowIn) -> [String: Any]? {
        guard w.usedPct.isFinite, w.resetsAt > 0 else { return nil }
        return ["pct": Int(min(100, max(0, w.usedPct)).rounded()), "resetsAt": w.resetsAt]
    }

    private static func planJSON(_ p: AndroidUsagePlanIn) -> [String: Any]? {
        var v: [String: Any] = [:]
        if let w = p.fiveHour.flatMap(windowJSON) { v["fiveHour"] = w }
        if let w = p.sevenDay.flatMap(windowJSON) { v["sevenDay"] = w }
        // A plan with no usable window is left out.
        if v.isEmpty { return nil }
        if let c = p.resetCredits { v["resetCredits"] = min(99, max(0, c)) }
        // "plus", "pro", "max 5x": ASCII letters, digits, spaces and dashes only, short.
        if let plan = p.plan {
            let clean = String(plan.filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == " " || $0 == "-" }.prefix(20))
                .trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { v["plan"] = clean }
        }
        if let t = p.updatedAt, t > 0 { v["updatedAt"] = t }
        return v
    }

    /// nil when neither plan has a usable window (the phone is then told so with a bare line).
    static func usageLine(_ u: AndroidUsageIn) -> String? {
        var v: [String: Any] = ["type": "usage"]
        if let c = u.claude.flatMap(planJSON) { v["claude"] = c }
        if let c = u.codex.flatMap(planJSON) { v["codex"] = c }
        return v.count > 1 ? AndroidLinkProtocol.json(v) : nil
    }
}
