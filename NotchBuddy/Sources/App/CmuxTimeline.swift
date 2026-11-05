import Foundation

#if !APPSTORE

// The timeline of a cmux session: what the hooks of one session tell, cut into turns and kept as the rows the chat
// draws (`ChatSegment`). Pure and Foundation only: no I/O, no clock of its own, nothing encoded, persisted, logged or
// sent anywhere. The caller passes the time. Memory only, bounded by the caps below.

// MARK: - Turn and events

/// One turn of a session: the prompt (nil when the turn was seen from its middle) and the rows after it.
struct TimelineTurn: Equatable, Identifiable {
    let id: Int                      // increasing in the store, never reused
    var prompt: String?
    var segments: [ChatSegment]      // ids increase per session
    var open: Bool                   // no end event yet
    var closedAt: TimeInterval?
    /// Characters of the prompt and of every text row, counted once when the text entered.
    var chars = 0
}

/// What a hook event means for the timeline. Strings arrive already localized by the caller and are cleaned here.
enum TimelineEvent: Equatable {
    case prompt(String)
    case toolStarted(key: String, tool: String, symbol: String?, label: String)
    /// `failedWord`: the tool failed, its step is stopped and carries that word (a failure does not say the permission
    /// was granted). `allowedWord`: what a step says once the permission that was asked for it is settled by the tool
    /// having run. `edit`: the tool changed a file.
    case toolFinished(key: String, tool: String, symbol: String?, label: String, failedWord: String?,
                      edit: ChatEdit?, allowedWord: String)
    case permission(key: String, label: String, outcome: ChatMoment.Outcome, allowedWord: String)
    case question(text: String, more: Int, outcome: ChatMoment.Outcome)
    case answer(String)                          // Stop
    case ended(ok: Bool, note: String?)          // StopFailure, Interrupt
    case notice(String)
    case reset                                   // SessionStart with source startup or clear
}

/// What one event did to the store, for the holder: the turns changed, the session was reset, and the sessions the
/// store dropped to stay under its cap (their messages and fold entries go with them).
struct TimelineApplied: Equatable {
    var changed = false
    var reset = false
    var evicted: [String] = []
}

// MARK: - Names

enum TimelineNames {
    /// The chip symbol of a tool, from the raw tool name of the hook. nil keeps the generic wrench.
    static func symbol(forTool raw: String) -> String? {
        switch raw {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Grep", "Glob", "LS": return "magnifyingglass"
        case "WebSearch", "WebFetch": return "globe"
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": return "pencil"
        case "Task", "spawn_agent": return "person.2"
        case "TodoWrite", "update_plan": return "checklist"
        default: return nil
        }
    }

    static let maxToolScalars = 64

    /// The key that pairs the events of one tool call: the tool name and a hash of its sorted input. Only the hash is
    /// kept (the input can hold whole file contents). FNV-1a, 64 bits: stable between runs. The tool name is cut first
    /// and the hash appended after, so the hash is never the part that is lost.
    static func pairingKey(tool: String, inputKey: String) -> String {
        // The whole tool name goes into the hash (then a separator, then the input): two long names that share their
        // first scalars still pair differently.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in tool.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        hash = (hash ^ 0) &* 0x100000001b3
        for byte in inputKey.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        var name = String.UnicodeScalarView()
        name.append(contentsOf: tool.unicodeScalars.prefix(maxToolScalars))
        return String(name) + ":" + String(hash, radix: 16)
    }
}

// MARK: - Store

struct TimelineStore {
    static let maxSessions = 32
    static let maxTurns = 20
    static let maxSessionRows = 300              // steps, edits, moments, notes of all turns
    static let maxSessionChars = 120_000         // prompts and answers of all turns
    static let maxTurnRows = ChatTurnBuilder.maxSteps   // 60 steps and edits, then `.hiddenSteps`
    static let maxTurnMoments = 12
    static let maxTurnNotes = 6
    static let maxPromptChars = 2000
    static let maxAnswerChars = 16_000
    static let maxLabelChars = ChatTurnBuilder.maxLabelChars
    static let maxQuestionChars = 200
    static let maxChoiceChars = 120
    static let maxNameChars = 80
    static let maxPathChars = 512
    static let maxPreviewLines = 6
    static let maxPreviewLineChars = 160
    static let maxPreviewEdits = 24              // newest edits of a session that keep their preview
    static let lateToolWindow: TimeInterval = 2
    /// Keys the reducer remembers for the late start and the late end of a call. Only the keys of rows that exist matter.
    static let maxMarks = 64
    /// A text is cut to this many scalars per character of its cap: a character can hold any number of scalars.
    static let maxScalarsPerChar = 2

    private struct Session {
        var turns: [TimelineTurn] = []
        var nextSegmentId = 0
        var lastTouched: TimeInterval = 0
        var revision = 0
        /// Keys whose end came before their start, with the time of that end: the late start adds nothing, but only
        /// within `lateToolWindow`. At most `maxMarks`.
        var finishedWithoutStart: [String: TimeInterval] = [:]
        /// Keys of steps added as done to a closed turn, or closed by the stop that came first: their end finds that
        /// step. Oldest first, at most `maxMarks`, cleared whenever a turn closes or a prompt opens one.
        var lateStarted: [String] = []
    }

    private var sessions: [String: Session] = [:]
    private var nextTurnId = 0

    // MARK: Reading

    func turns(for key: String) -> [TimelineTurn] { sessions[key]?.turns ?? [] }

    /// Prompts plus the turns that have rows: what a prompt and an answer count as in a transcript.
    func messageCount(for key: String) -> Int {
        (sessions[key]?.turns ?? []).reduce(0) { $0 + ($1.prompt == nil ? 0 : 1) + ($1.segments.isEmpty ? 0 : 1) }
    }

    func isOpen(_ key: String) -> Bool { sessions[key]?.turns.last?.open ?? false }

    /// Changes whenever the turns of the session changed.
    func revision(for key: String) -> Int { sessions[key]?.revision ?? 0 }

    var sessionCount: Int { sessions.count }

    /// How many keys the reducer remembers for the calls of a session (both sets together).
    func markCount(for key: String) -> Int {
        guard let s = sessions[key] else { return 0 }
        return s.finishedWithoutStart.count + s.lateStarted.count
    }

    mutating func remove(_ key: String) { sessions[key] = nil }

    // MARK: Writing

    /// `shown`: the key of the session the reply view renders; it is never evicted. The session is changed in place:
    /// an event copies none of its collections (only the array of turns is compared, and it is bounded by the caps).
    @discardableResult
    mutating func apply(_ event: TimelineEvent, to key: String, now: TimeInterval, shown: String?) -> TimelineApplied {
        var result = TimelineApplied()
        let isNew = sessions[key] == nil
        if isNew, case .reset = event { return result }
        if isNew { sessions[key] = Session() }
        let before = sessions[key]?.turns ?? []
        sessions[key]?.lastTouched = now
        Self.reduce(&sessions[key]!, event, now: now, nextTurnId: &nextTurnId)
        Self.enforceSessionCaps(&sessions[key]!)
        result.changed = sessions[key]!.turns != before
        if result.changed { sessions[key]!.revision += 1 }
        if case .reset = event { result.reset = true }
        if isNew && !result.changed {
            sessions[key] = nil
            return result
        }
        if isNew { result.evicted = evictSessions(keeping: key, shown: shown) }
        return result
    }

    private mutating func evictSessions(keeping key: String, shown: String?) -> [String] {
        var gone: [String] = []
        while sessions.count > Self.maxSessions {
            let victim = sessions
                .filter { $0.key != key && $0.key != shown }
                .min { $0.value.lastTouched < $1.value.lastTouched }
            guard let victim else { break }
            sessions[victim.key] = nil
            gone.append(victim.key)
        }
        return gone
    }

    // MARK: The reducer

    private static func reduce(_ s: inout Session, _ event: TimelineEvent, now: TimeInterval, nextTurnId: inout Int) {
        switch event {
        case .reset:
            s.turns = []
            s.finishedWithoutStart = [:]
            s.lateStarted = []
        case .prompt(let raw):
            let text = cleanBlock(raw, max: maxPromptChars)
            guard !text.isEmpty else { return }
            var closedHere = false
            if let last = s.turns.last, last.open {
                if last.prompt == text && last.segments.isEmpty { return }
                close(&s, at: s.turns.count - 1, ok: true, now: now)
                closedHere = true
            }
            s.finishedWithoutStart = [:]
            // The marks that closing this turn just made stay: the end of a call that was running may still come, and
            // it belongs to that turn, not to the new one.
            if !closedHere { s.lateStarted = [] }
            s.turns.append(TimelineTurn(id: nextTurnId, prompt: text, segments: [], open: true, closedAt: nil, chars: text.count))
            nextTurnId += 1
        case .toolStarted(let key, let tool, let symbol, let label):
            toolStarted(&s, key: key, tool: tool, symbol: symbol, label: label, now: now, nextTurnId: &nextTurnId)
        case .toolFinished(let key, let tool, let symbol, let label, let failedWord, let edit, let allowedWord):
            toolFinished(&s, key: key, tool: tool, symbol: symbol, label: label, failedWord: failedWord, edit: edit,
                         allowedWord: allowedWord, now: now, nextTurnId: &nextTurnId)
        case .permission(let key, let label, let outcome, let allowedWord):
            permission(&s, key: key, label: label, outcome: outcome, allowedWord: allowedWord, now: now, nextTurnId: &nextTurnId)
        case .question(let text, let more, let outcome):
            question(&s, text: text, more: more, outcome: outcome, now: now, nextTurnId: &nextTurnId)
        case .answer(let raw):
            let text = cleanBlock(raw, max: maxAnswerChars)
            if let last = s.turns.last, last.open {
                if !text.isEmpty { append(&s, .text(text, role: .answer), toTurn: s.turns.count - 1) }
                close(&s, at: s.turns.count - 1, ok: true, now: now)
                return
            }
            guard !text.isEmpty else { return }
            // The same Stop again, whatever rows came after the answer, is not a second answer.
            if let last = s.turns.last, lastAnswer(of: last) == text { return }
            let i = openTurn(&s, now: now, nextTurnId: &nextTurnId)
            append(&s, .text(text, role: .answer), toTurn: i)
            close(&s, at: i, ok: true, now: now)
        case .ended(let ok, let note):
            guard let last = s.turns.last, last.open else { return }
            let i = s.turns.count - 1
            if let note { addNote(&s, note, toTurn: i) }
            close(&s, at: i, ok: ok, now: now)
        case .notice(let raw):
            let text = wording(raw, max: maxLabelChars)
            guard !text.isEmpty else { return }
            if let last = s.turns.last, last.open {
                addNote(&s, text, toTurn: s.turns.count - 1)
            } else if case .note(text)? = s.turns.last?.segments.last?.kind, s.turns.last?.prompt == nil {
                return
            } else {
                // A turn of its own that never counts as the one a late tool joins.
                s.turns.append(TimelineTurn(id: nextTurnId, prompt: nil, segments: [], open: false, closedAt: nil))
                nextTurnId += 1
                addNote(&s, text, toTurn: s.turns.count - 1)
            }
        }
    }

    private static func lastAnswer(of turn: TimelineTurn) -> String? {
        for segment in turn.segments.reversed() {
            if case .text(let t, .answer) = segment.kind { return t }
        }
        return nil
    }

    // MARK: Turns

    /// Ends a turn: running steps are done (or stopped when it failed), open moments are handled. A running step whose
    /// permission never reached a decision did not run (the request was refused where Coucou does not hear): it goes,
    /// as a denied one does. The marks of the calls of earlier turns are not needed any more.
    private static func close(_ s: inout Session, at index: Int, ok: Bool, now: TimeInterval) {
        s.finishedWithoutStart = [:]
        s.lateStarted = []
        var unsettled = Set<String>()
        for segment in s.turns[index].segments {
            if case .moment(let m) = segment.kind, m.kind == .permission, m.rank < 3 { unsettled.insert(m.callId) }
        }
        var dropped: [Int] = []
        for i in s.turns[index].segments.indices {
            switch s.turns[index].segments[i].kind {
            case .step(var step) where step.status == .running:
                if unsettled.contains(step.callId) { dropped.append(i); continue }
                step.status = ok ? .done : .stopped
                s.turns[index].segments[i].kind = .step(step)
                // Its end may still come (it lost the race with the stop): it finds this step.
                markLate(&s, step.callId)
            case .moment(var moment) where moment.waitsForUser:
                moment.outcome = .handled
                s.turns[index].segments[i].kind = .moment(moment)
            default: break
            }
        }
        for i in dropped.reversed() { s.turns[index].segments.remove(at: i) }
        s.turns[index].open = false
        s.turns[index].closedAt = now
    }

    private static func markLate(_ s: inout Session, _ key: String) {
        if s.lateStarted.contains(key) { return }
        s.lateStarted.append(key)
        if s.lateStarted.count > maxMarks { s.lateStarted.removeFirst(s.lateStarted.count - maxMarks) }
    }

    private static func markFinished(_ s: inout Session, _ key: String, now: TimeInterval) {
        s.finishedWithoutStart[key] = now
        while s.finishedWithoutStart.count > maxMarks,
              let oldest = s.finishedWithoutStart.min(by: { $0.value < $1.value })?.key {
            s.finishedWithoutStart[oldest] = nil
        }
    }

    /// The open turn, or a new one with no prompt: a turn seen from its middle.
    private static func openTurn(_ s: inout Session, now: TimeInterval, nextTurnId: inout Int) -> Int {
        if let last = s.turns.last, last.open { return s.turns.count - 1 }
        s.turns.append(TimelineTurn(id: nextTurnId, prompt: nil, segments: [], open: true, closedAt: nil))
        nextTurnId += 1
        return s.turns.count - 1
    }

    /// Where a tool event goes: the open turn; a turn closed `lateToolWindow` ago or less (the start and the stop
    /// swapped); else a new turn with no prompt. `late` says the closed turn was joined.
    private static func toolTurn(_ s: inout Session, now: TimeInterval, nextTurnId: inout Int) -> (index: Int, late: Bool) {
        if let last = s.turns.last {
            if last.open { return (s.turns.count - 1, false) }
            if let closed = last.closedAt, now - closed <= lateToolWindow { return (s.turns.count - 1, true) }
        }
        return (openTurn(&s, now: now, nextTurnId: &nextTurnId), false)
    }

    private static func append(_ s: inout Session, _ kind: ChatSegment.Kind, toTurn index: Int) {
        if case .text(let t, _) = kind { s.turns[index].chars += t.count }
        s.turns[index].segments.append(ChatSegment(id: s.nextSegmentId, kind: kind))
        s.nextSegmentId += 1
        capRows(&s, turn: index)
    }

    /// Past `maxTurnRows` steps and edits the oldest step that is not running goes, else the oldest running step, else
    /// the oldest edit; one `hiddenSteps` row takes its place, with the id of the row it replaces so ids still
    /// increase in list order.
    private static func capRows(_ s: inout Session, turn index: Int) {
        func isRow(_ seg: ChatSegment) -> Bool {
            switch seg.kind { case .step, .edit: return true; default: return false }
        }
        while s.turns[index].segments.filter(isRow).count > maxTurnRows {
            let segs = s.turns[index].segments
            let victim = segs.firstIndex { if case .step(let st) = $0.kind { return st.status != .running }; return false }
                ?? segs.firstIndex { if case .step = $0.kind { return true }; return false }
                ?? segs.firstIndex { if case .edit = $0.kind { return true }; return false }
            guard let victim else { return }
            let removed = s.turns[index].segments.remove(at: victim)
            if !s.turns[index].segments.contains(where: { $0.kind == .hiddenSteps }) {
                s.turns[index].segments.insert(ChatSegment(id: removed.id, kind: .hiddenSteps), at: victim)
            }
        }
        // Moments: the oldest resolved one goes, never one that waits for the user.
        var moments: [Int] { s.turns[index].segments.indices.filter { if case .moment = s.turns[index].segments[$0].kind { return true }; return false } }
        while moments.count > maxTurnMoments {
            func outcome(_ i: Int) -> ChatMoment.Outcome? {
                if case .moment(let m) = s.turns[index].segments[i].kind { return m.outcome }
                return nil
            }
            let list = moments
            let drop = list.first { !(outcome($0).map { $0 == .waiting || $0 == .inTerminal } ?? false) }
                ?? list.first { outcome($0) == .inTerminal }
            if let drop { s.turns[index].segments.remove(at: drop) } else { s.turns[index].segments.removeLast(); break }
        }
    }

    private static func addNote(_ s: inout Session, _ raw: String, toTurn index: Int) {
        let text = wording(raw, max: maxLabelChars)
        guard !text.isEmpty else { return }
        if s.turns[index].segments.contains(where: { $0.kind == .note(text) }) { return }
        append(&s, .note(text), toTurn: index)
        var notes: [Int] { s.turns[index].segments.indices.filter { if case .note = s.turns[index].segments[$0].kind { return true }; return false } }
        while notes.count > maxTurnNotes, let first = notes.first { s.turns[index].segments.remove(at: first) }
    }

    // MARK: Tools

    private static func toolStarted(_ s: inout Session, key rawKey: String, tool rawTool: String, symbol: String?,
                                    label: String, now: TimeInterval, nextTurnId: inout Int) {
        let key = pairing(rawKey)
        let tool = wording(rawTool, max: ChatTurnBuilder.maxToolChars)
        guard !tool.isEmpty else { return }
        // The start that came after its own end adds nothing, when that end was a moment ago.
        if let at = s.finishedWithoutStart.removeValue(forKey: key), now - at <= lateToolWindow { return }
        if let last = s.turns.last, runningStep(in: last, key: key) != nil { return }
        let (i, late) = toolTurn(&s, now: now, nextTurnId: &nextTurnId)
        if late { markLate(&s, key) }
        let step = ChatStep(callId: key, tool: tool, label: wording(label, max: maxLabelChars), detail: nil,
                            status: late ? .done : .running, symbol: cleanSymbol(symbol))
        append(&s, .step(step), toTurn: i)
    }

    private static func toolFinished(_ s: inout Session, key rawKey: String, tool rawTool: String, symbol: String?,
                                     label: String, failedWord: String?, edit: ChatEdit?, allowedWord: String,
                                     now: TimeInterval, nextTurnId: inout Int) {
        let key = pairing(rawKey)
        let tool = wording(rawTool, max: ChatTurnBuilder.maxToolChars)
        guard !tool.isEmpty else { return }
        let failed = failedWord.map { wording($0, max: ChatTurnBuilder.maxDetailChars) }.flatMap { $0.isEmpty ? nil : $0 }
        var turnIndex: Int
        // The step of the last turn that this end closes: a running one, else one a late start added as done.
        var found: Int?
        var foundTurn = s.turns.count - 1
        if let last = s.turns.last {
            found = runningStep(in: last, key: key)
            if found == nil, s.lateStarted.contains(key) {
                found = last.segments.lastIndex { if case .step(let st) = $0.kind { return st.callId == key }; return false }
                // A prompt came while the call ran: its end belongs to the turn before the last.
                if found == nil, s.turns.count >= 2 {
                    let before = s.turns[s.turns.count - 2]
                    found = before.segments.lastIndex { if case .step(let st) = $0.kind { return st.callId == key }; return false }
                    if found != nil { foundTurn = s.turns.count - 2 }
                }
            }
        }
        if let i = found {
            s.lateStarted.removeAll { $0 == key }
            turnIndex = foundTurn
            let id = s.turns[turnIndex].segments[i].id
            if let edit {
                s.turns[turnIndex].segments[i] = ChatSegment(id: id, kind: .edit(clean(edit, key: key, tool: tool, symbol: symbol)))
            } else if case .step(var step) = s.turns[turnIndex].segments[i].kind {
                step.status = failed != nil ? .stopped : .done
                if let failed { step.detail = join(step.detail, failed, first: false) }
                s.turns[turnIndex].segments[i].kind = .step(step)
            }
        } else {
            let (i, _) = toolTurn(&s, now: now, nextTurnId: &nextTurnId)
            turnIndex = i
            markFinished(&s, key, now: now)
            if let edit {
                append(&s, .edit(clean(edit, key: key, tool: tool, symbol: symbol)), toTurn: i)
            } else {
                let step = ChatStep(callId: key, tool: tool, label: wording(label, max: maxLabelChars),
                                    detail: failed, status: failed != nil ? .stopped : .done, symbol: cleanSymbol(symbol))
                append(&s, .step(step), toTurn: i)
            }
        }
        // The tool ran, so a permission asked for it that is not settled was granted. A failure says nothing of it.
        if failed == nil, let m = momentIndex(in: s.turns[turnIndex], kind: .permission, key: key),
           case .moment(let moment) = s.turns[turnIndex].segments[m].kind, moment.rank < 3 {
            settleAllowed(&s, turn: turnIndex, moment: m, key: key, word: allowedWord)
        }
        stripOldPreviews(&s)
    }

    private static func runningStep(in turn: TimelineTurn, key: String) -> Int? {
        turn.segments.lastIndex { if case .step(let st) = $0.kind { return st.callId == key && st.status == .running }; return false }
    }

    private static func momentIndex(in turn: TimelineTurn, kind: ChatMoment.Kind, key: String?) -> Int? {
        turn.segments.lastIndex {
            if case .moment(let m) = $0.kind { return m.kind == kind && (key == nil || m.callId == key) }
            return false
        }
    }

    private static func pairing(_ raw: String) -> String { String(raw.unicodeScalars.prefix(128)) }

    private static func join(_ existing: String?, _ word: String, first: Bool) -> String {
        guard let existing, !existing.isEmpty else { return word }
        if existing.contains(word) { return existing }
        return first ? word + " " + existing : existing + " " + word
    }

    // MARK: Moments

    /// A request is a moment of the turn it was asked in. A decision, or the note that it went to the terminal or was
    /// handled, only updates a moment of the last turn that is already there: it never makes a row from nothing (a
    /// denial of the open turn whose request was never seen is the one exception) and it never opens a turn.
    private static func permission(_ s: inout Session, key rawKey: String, label: String, outcome: ChatMoment.Outcome,
                                   allowedWord: String, now: TimeInterval, nextTurnId: inout Int) {
        let key = pairing(rawKey)
        if let li = s.turns.indices.last, let m = momentIndex(in: s.turns[li], kind: .permission, key: key),
           case .moment(var moment) = s.turns[li].segments[m].kind {
            if outcome == .waiting {
                if moment.rank >= 2 {
                    let turn = openTurn(&s, now: now, nextTurnId: &nextTurnId)
                    addPermission(&s, key: key, label: label, outcome: outcome, turn: turn)
                }
                return
            }
            guard ChatMoment.rank(of: outcome) > moment.rank else { return }
            if outcome == .allowed {
                settleAllowed(&s, turn: li, moment: m, key: key, word: allowedWord)
            } else {
                moment.outcome = clean(outcome)
                s.turns[li].segments[m].kind = .moment(moment)
                if outcome == .denied { dropRunningStep(&s, turn: li, key: key) }
            }
            return
        }
        switch outcome {
        case .waiting:
            let turn = openTurn(&s, now: now, nextTurnId: &nextTurnId)
            addPermission(&s, key: key, label: label, outcome: outcome, turn: turn)
        case .denied:
            guard let last = s.turns.last, last.open else { return }
            let turn = s.turns.count - 1
            addPermission(&s, key: key, label: label, outcome: outcome, turn: turn)
            dropRunningStep(&s, turn: turn, key: key)
        case .allowed:
            // No moment to settle: the word still goes on the step it was asked for.
            if let last = s.turns.last, last.open,
               let st = last.segments.lastIndex(where: { if case .step(let x) = $0.kind { return x.callId == key }; return false }),
               case .step(var step) = last.segments[st].kind {
                step.detail = join(step.detail, wording(allowedWord, max: ChatTurnBuilder.maxDetailChars), first: true)
                s.turns[s.turns.count - 1].segments[st].kind = .step(step)
            }
        case .inTerminal, .handled, .answered:
            return
        }
    }

    /// A denied call never runs: the hook that announced it started a step, and the moment now stands for the call, so
    /// the step is not work and goes.
    private static func dropRunningStep(_ s: inout Session, turn: Int, key: String) {
        if let i = runningStep(in: s.turns[turn], key: key) { s.turns[turn].segments.remove(at: i) }
    }

    private static func addPermission(_ s: inout Session, key: String, label: String, outcome: ChatMoment.Outcome, turn: Int) {
        let moment = ChatMoment(kind: .permission, callId: key, text: wording(label, max: maxLabelChars),
                                more: 0, outcome: clean(outcome))
        append(&s, .moment(moment), toTurn: turn)
    }

    /// A settled permission is not a row when its step is there: the step says the word. Without the step the moment
    /// stays, as allowed.
    private static func settleAllowed(_ s: inout Session, turn: Int, moment m: Int, key: String, word: String) {
        let step = s.turns[turn].segments.lastIndex {
            switch $0.kind {
            case .step(let x): return x.callId == key
            case .edit(let e): return e.callId == key
            default: return false
            }
        }
        guard let step else {
            if case .moment(var moment) = s.turns[turn].segments[m].kind {
                moment.outcome = .allowed
                s.turns[turn].segments[m].kind = .moment(moment)
            }
            return
        }
        if case .step(var x) = s.turns[turn].segments[step].kind {
            let w = wording(word, max: ChatTurnBuilder.maxDetailChars)
            if !w.isEmpty { x.detail = join(x.detail, w, first: true) }
            s.turns[turn].segments[step].kind = .step(x)
        }
        s.turns[turn].segments.remove(at: m)
    }

    private static func question(_ s: inout Session, text raw: String, more: Int, outcome: ChatMoment.Outcome,
                                 now: TimeInterval, nextTurnId: inout Int) {
        let text = wording(raw, max: maxQuestionChars)
        if let li = s.turns.indices.last, let q = momentIndex(in: s.turns[li], kind: .question, key: nil),
           case .moment(var moment) = s.turns[li].segments[q].kind {
            if outcome == .waiting {
                // The same card asking again (promoted, requeued) changes nothing; a later question is a new moment.
                if moment.rank >= 2, !text.isEmpty {
                    let turn = openTurn(&s, now: now, nextTurnId: &nextTurnId)
                    addQuestion(&s, text: text, more: more, outcome: outcome, turn: turn)
                }
                return
            }
            guard ChatMoment.rank(of: outcome) > moment.rank else { return }
            moment.outcome = clean(outcome)
            s.turns[li].segments[q].kind = .moment(moment)
            return
        }
        // No row of this question yet. Only a request makes one; a request handed to the terminal or settled carries
        // no text and an answer needs the turn it was asked in.
        guard !text.isEmpty else { return }
        switch outcome {
        case .waiting:
            let turn = openTurn(&s, now: now, nextTurnId: &nextTurnId)
            addQuestion(&s, text: text, more: more, outcome: outcome, turn: turn)
        case .answered:
            guard let last = s.turns.last, last.open else { return }
            addQuestion(&s, text: text, more: more, outcome: outcome, turn: s.turns.count - 1)
        default:
            return
        }
    }

    private static func addQuestion(_ s: inout Session, text: String, more: Int, outcome: ChatMoment.Outcome, turn: Int) {
        let moment = ChatMoment(kind: .question, callId: "", text: text, more: max(0, more), outcome: clean(outcome))
        append(&s, .moment(moment), toTurn: turn)
    }

    private static func clean(_ outcome: ChatMoment.Outcome) -> ChatMoment.Outcome {
        if case .answered(let labels) = outcome { return .answered(wording(labels, max: maxChoiceChars)) }
        return outcome
    }

    // MARK: Edits

    private static func clean(_ edit: ChatEdit, key: String, tool: String, symbol: String?) -> ChatEdit {
        var out = edit
        out.callId = key
        out.tool = tool
        out.symbol = cleanSymbol(edit.symbol ?? symbol)
        out.name = wording(edit.name, max: maxNameChars)
        out.path = wording(edit.path, max: maxPathChars)
        out.added = max(0, edit.added)
        out.removed = max(0, edit.removed)
        // Only changed lines, at most six, each cut; a diff too large for the engine keeps no line at all.
        out.preview = edit.tooLarge ? [] : edit.preview
            .filter { $0.kind != .context }
            .prefix(maxPreviewLines)
            .map { ChatEditLine(kind: $0.kind, text: codeLine($0.text, max: maxPreviewLineChars)) }
        return out
    }

    /// The newest `maxPreviewEdits` edits of a session keep their lines; older ones keep their row and their diff id.
    private static func stripOldPreviews(_ s: inout Session) {
        var kept = 0
        for t in s.turns.indices.reversed() {
            for i in s.turns[t].segments.indices.reversed() {
                guard case .edit(var e) = s.turns[t].segments[i].kind, !e.preview.isEmpty else { continue }
                kept += 1
                if kept > maxPreviewEdits {
                    e.preview = []
                    s.turns[t].segments[i].kind = .edit(e)
                }
            }
        }
    }

    // MARK: Session caps

    private static func enforceSessionCaps(_ s: inout Session) {
        while s.turns.count > maxTurns { s.turns.removeFirst() }
        func rows(_ t: TimelineTurn) -> Int {
            t.segments.reduce(0) { n, seg in if case .text = seg.kind { return n }; return n + 1 }
        }
        // The characters of a turn were counted when the text entered: no text is walked here.
        while s.turns.count > 1,
              s.turns.reduce(0, { $0 + rows($1) }) > maxSessionRows || s.turns.reduce(0, { $0 + $1.chars }) > maxSessionChars {
            s.turns.removeFirst()
        }
    }

    // MARK: Text

    private static func cleanSymbol(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = wording(raw, max: 60)
        return line.isEmpty ? nil : line
    }

    /// Characters that read as a blank without being a space: they are folded into the white space of a line.
    private static func isBlank(_ u: Unicode.Scalar) -> Bool {
        if u.properties.isWhitespace { return true }
        switch u.value {
        case 0x115F, 0x1160, 0x180E, 0x2800, 0x3164, 0xFFA0: return true
        default: return false
        }
    }

    private static func isHidden(_ u: Unicode.Scalar) -> Bool {
        let v = u.value
        return v < 0x20 || (v >= 0x7F && v <= 0x9F) || (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069)
            || u.properties.generalCategory == .format
    }

    /// Combining scalars kept after a base character: a base can carry any number of them.
    static let maxMarksPerBase = 3

    private static func isMark(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    /// One line of timeline wording. Control and format characters go, every run of white space (the Unicode blanks
    /// too) is one space, the ends are trimmed. The walk stops on what is kept, not on what is read: it goes on until
    /// `max + 1` visible characters are kept (blanks and removed characters do not count, and a base character keeps at
    /// most `maxMarksPerBase` combining scalars), so no run of blanks or marks can push the end of a command out of the
    /// window. When text is left unread the row ends with the cut mark `…` (within `max`).
    static func wording(_ raw: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        var kept = 0
        var marks = 0
        var gap = false
        var more = false
        for u in raw.unicodeScalars {
            if isBlank(u) { gap = !out.isEmpty; continue }
            if isHidden(u) { continue }
            if isMark(u) {
                if out.isEmpty || gap || marks >= maxMarksPerBase { continue }
                out.append(u)
                marks += 1
                continue
            }
            if gap { out.append(" "); kept += 1; gap = false }
            out.append(u)
            kept += 1
            marks = 0
            if kept > max { more = true; break }
        }
        let text = String(out)
        return more ? String(text.prefix(max - 1)) + "…" : String(text.prefix(max))
    }

    /// A prompt or an answer: the lines stay. Control and format characters go, the ends are trimmed, then it is cut by
    /// characters and by scalars (a character can hold any number of scalars).
    static func cleanBlock(_ raw: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars.prefix(max * 4 + 64) {
            let v = u.value
            if v == 0x0A || v == 0x09 {
                out.append(u)
            } else if v == 0x0D {
                continue
            } else if v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029
                        || (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069)
                        || u.properties.generalCategory == .format {
                continue
            } else {
                out.append(u)
            }
        }
        var capped = String.UnicodeScalarView()
        capped.append(contentsOf: out.prefix(max * maxScalarsPerChar))
        let text = String(capped).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(max))
    }

    /// One line of code: the indentation stays (a tab is four spaces), control characters go, then it is cut.
    private static func codeLine(_ raw: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars.prefix(max * 4) {
            let v = u.value
            if v == 0x09 {
                out.append(contentsOf: "    ".unicodeScalars)
            } else if v == 0x0A || v == 0x0D {
                break
            } else if v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029
                        || (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069)
                        || u.properties.generalCategory == .format {
                continue
            } else {
                out.append(u)
            }
        }
        return String(String(out).prefix(max))
    }
}

#endif
