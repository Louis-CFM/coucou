import Foundation

// The turn of an agent as the chat shows it. Foundation only, in both builds, no flag.
// Display data only: nothing here is encoded, persisted, logged or sent to a server.

/// One tool call of a turn, as the server names it.
struct ChatStep: Equatable {
    var callId: String
    var tool: String                 // "terminal", "web_search"… as the server names it
    var label: String                // the server's one line preview, cut
    var detail: String?              // web socket only: the summary of the completion, cut
    var status: Status
    enum Status: Equatable { case running, done, stopped }   // stopped: the turn ended while it ran
    /// SF Symbol for the chip of this tool in the summary row; nil keeps the generic one. Only the cmux timeline sets it.
    var symbol: String? = nil
}

/// One changed line of a file edit, as the edit row keeps it (the view maps it to a diff line).
struct ChatEditLine: Equatable {
    enum Kind: Equatable { case context, added, removed }
    var kind: Kind
    var text: String
}

/// A file edit of a turn: counts and a few changed lines, never the whole diff. Produced only by the cmux timeline.
struct ChatEdit: Equatable {
    var callId: String
    var tool: String                 // the chip word, already localized ("Edita")
    var symbol: String?              // SF Symbol for its chip
    var name: String                 // file name
    var path: String
    var added: Int
    var removed: Int
    var isNewFile: Bool
    var tooLarge: Bool
    var preview: [ChatEditLine]      // may be empty (too large, or dropped by the cap)
    var diffId: Int?                 // id in the owner's diff store, to open the full diff

    /// The edit as a step: for the live box and the summary. Tool, file name, "+12 −3".
    var asStep: ChatStep {
        var counts: [String] = []
        if added > 0 { counts.append("+\(added)") }
        if removed > 0 { counts.append("−\(removed)") }
        return ChatStep(callId: callId, tool: tool, label: name, detail: counts.isEmpty ? nil : counts.joined(separator: " "),
                        status: .done, symbol: symbol)
    }
}

/// A moment where the agent waits for the user: a permission or a question. Shown, never answerable from a row.
struct ChatMoment: Equatable {
    enum Kind: Equatable { case permission, question }
    enum Outcome: Equatable { case waiting, inTerminal, handled, allowed, denied, answered(String) }
    var kind: Kind
    var callId: String               // pairs a permission with its step; "" for a question
    var text: String                 // permission: the step wording. question: the question text
    var more: Int                    // further questions of the same card
    var outcome: Outcome

    /// Outcomes only move forward: waiting, in the terminal, handled, then a decision.
    var rank: Int { Self.rank(of: outcome) }

    static func rank(of outcome: Outcome) -> Int {
        switch outcome {
        case .waiting: return 0
        case .inTerminal: return 1
        case .handled: return 2
        case .allowed, .denied, .answered: return 3
        }
    }

    /// The agent waits for the user: a waiting card, or a request handed to the terminal.
    var waitsForUser: Bool { outcome == .waiting || outcome == .inTerminal }

    /// Stays outside the fold of the work: a question and its answer, a request still open, a denied one.
    var staysVisible: Bool { kind == .question || waitsForUser || outcome == .denied }
}

/// One row of an agent turn.
struct ChatSegment: Identifiable, Equatable {
    let id: Int                      // increasing in list order; never two live rows with the same id
    var kind: Kind
    enum Kind: Equatable {
        case text(String, role: TextRole)
        case step(ChatStep)
        case note(String)            // an already localized sentence: approval needed, answer cut…
        case hiddenSteps             // older steps were dropped (cap)
        case edit(ChatEdit)          // a file edit (cmux timeline only)
        case moment(ChatMoment)      // a permission or a question (cmux timeline only)
    }
    enum TextRole: Equatable { case open, interim, answer }

    /// A step, a file edit, or the row that stands for dropped steps.
    var isStepRow: Bool {
        switch kind {
        case .step, .hiddenSteps, .edit: return true
        case .text, .note, .moment: return false
        }
    }
}

/// Who speaks in an agent block: a name and the colour of its pill.
struct ChatSpeaker: Equatable {
    var name: String
    var colorHex: String
}

enum ChatVisibility {
    /// Whether a message has anything to draw: its text, or the rows of an agent turn that has written no text yet
    /// (a turn whose first event is a tool). The chat list and its scroll targets share this one rule.
    static func isShown(content: String, segments: [ChatSegment]) -> Bool {
        !content.isEmpty || !segments.isEmpty
    }
}

enum ChatStreaming {
    /// Whether a message is parsed as a text that is still arriving: only the last one, only while a turn runs,
    /// and never a sentence the app wrote (an error kept in the chat).
    static func shows(streamingLast: Bool, isLast: Bool, isNotice: Bool) -> Bool {
        streamingLast && isLast && !isNotice
    }
}

enum ChatSpeakers {
    /// The header is drawn on the first agent message after a user message (or at the top), and again when
    /// the speaker changes (shared chat, provider switched in the middle, an agent renamed).
    static func showsHeader(previous: (isUser: Bool, speaker: ChatSpeaker?)?, speaker: ChatSpeaker) -> Bool {
        guard let previous else { return true }
        if previous.isUser { return true }
        return previous.speaker != speaker
    }
}

// MARK: - Publish budget

/// How often the rows may be published because a step or a note changed: at most `limit` times in any `window`.
/// Pure: the caller passes the clock and keeps no timer. A normal round (two frames, or up to eight starts in a
/// burst) always fits, so it is published at once; a burst of a hundred tools is bounded.
struct StepPublishBudget: Equatable {
    static let perSecond = 15
    let limit: Int
    let window: TimeInterval
    private var stamps: [Date] = []

    init(limit: Int = StepPublishBudget.perSecond, window: TimeInterval = 1) {
        self.limit = limit
        self.window = window
    }

    /// Whether a publish at `now` fits in the budget; when it does, it is counted.
    mutating func take(at now: Date) -> Bool {
        stamps.removeAll { now.timeIntervalSince($0) >= window }
        guard stamps.count < limit else { return false }
        stamps.append(now)
        return true
    }
}

// MARK: - Turn builder

/// What happened in a turn, as the transports report it. Only the words a row needs: a tool's name and one line
/// preview, a completion summary, text. Arguments, results and reasoning have no case here on purpose.
enum ChatTurnEvent: Equatable {
    case text(String)                                   // a content delta
    case interim(String, alreadyStreamed: Bool)         // web socket message.interim
    case toolStarted(id: String, tool: String, label: String)
    case toolFinished(id: String, detail: String?)
    case finalText(String, alreadyDelivered: Bool)      // web socket message.complete.text
    case note(String)
    /// The end of the turn: `notes` are the already localized sentences the text gets at its end (cut, interrupted…).
    case ended(ok: Bool, notes: [String] = [])
}

/// Turns the events of one agent turn into the rows the chat draws. Pure; owns no I/O and keeps nothing but the rows.
struct ChatTurnBuilder: Equatable {
    static let maxSteps = 60
    static let maxLabelChars = 120
    static let maxToolChars = 40
    static let maxDetailChars = 80
    static let maxTextChars = 200_000        // the existing limit, HermesChat.Limits.textChars
    static let maxTextRows = 300             // text rows of one turn; past it new text joins the last text row
    private static let maxIdChars = 128         // scalars

    private(set) var segments: [ChatSegment] = []
    private var nextId = 0
    private var textChars = 0
    /// Set by `ended`: nothing runs after the end of a turn, so a later event changes nothing.
    private var finished = false

    mutating func reset() {
        // Ids keep counting: a new turn never reuses an id of the old one.
        segments = []
        textChars = 0
        finished = false
    }

    /// Every text segment in order, joined with a blank line. Display and scroll anchors only.
    var plainText: String {
        segments.compactMap { seg -> String? in
            if case .text(let t, _) = seg.kind, !t.isEmpty { return t }
            return nil
        }.joined(separator: "\n\n")
    }

    mutating func apply(_ event: ChatTurnEvent) {
        if finished { return }
        switch event {
        case .text(let t):
            appendText(t)
        case .toolStarted(let id, let tool, let label):
            let key = Self.idKey(id)
            let name = Self.cleanTool(tool)
            guard !name.isEmpty else { return }
            // A second start is the same step only while that step runs: the server forgets an id when its tool
            // completes, and may use it again for the next call.
            if steps.contains(where: { $0.callId == key && $0.status == .running }) { return }
            sealOpen()
            append(.step(ChatStep(callId: key, tool: name,
                                  label: Self.oneLine(label, max: Self.maxLabelChars), detail: nil, status: .running)))
            capSteps()
        case .toolFinished(let id, let detail):
            let key = Self.idKey(id)
            guard let i = segments.lastIndex(where: { if case .step(let s) = $0.kind { return s.callId == key }; return false }),
                  case .step(var step) = segments[i].kind else { return }
            step.status = .done
            if let detail {
                let d = Self.oneLine(detail, max: Self.maxDetailChars)
                step.detail = d.isEmpty ? nil : d
            }
            segments[i].kind = .step(step)
        case .interim(let incoming, let alreadyStreamed):
            if alreadyStreamed { sealOpen(); return }
            let t = Self.trimmed(incoming)
            guard !t.isEmpty else { return }
            // `already_streamed: false` means the deltas were not the whole sentence: the open text and the server's
            // text are prefixes of one another, in either direction (the server does not match a streamed text that is
            // longer), and the server's version wins. A different open text is a sentence of its own.
            if let i = openIndex {
                let open = Self.collapsed(text(at: i)), sent = Self.collapsed(t)
                if sent.hasPrefix(open) || open.hasPrefix(sent) {
                    replaceText(at: i, with: t, role: .interim)
                    return
                }
            }
            // The same sentence as the last text row is skipped only while no step followed that row: after a tool it
            // is a sentence of its own.
            if let i = lastTextIndex, !segments[(i + 1)...].contains(where: { $0.isStepRow }),
               Self.collapsed(text(at: i)) == Self.collapsed(t) { return }
            sealOpen()
            appendNewText(t, role: .interim)
        case .finalText(let text, let alreadyDelivered):
            let t = Self.trimmed(text)
            guard !t.isEmpty else { return }
            if let i = openIndex {
                replaceText(at: i, with: t, role: .answer)
            } else if alreadyDelivered, let i = lastTextIndex,
                      case .text(let s, .interim) = segments[i].kind, Self.collapsed(s) == Self.collapsed(t) {
                // The server matches on collapsed whitespace, and the sentence is the last text row or nothing.
                replaceText(at: i, with: t, role: .answer)
            } else {
                appendNewText(t, role: .answer)
            }
        case .note(let n):
            if case .note(let last)? = segments.last?.kind, last == n { return }
            // The sentence before a request the turn cannot answer was written before it: it is not the answer.
            sealOpen()
            append(.note(n))
        case .ended(let ok, let notes):
            if let i = openIndex {
                let t = Self.trimmed(text(at: i))
                if t.isEmpty { textChars -= text(at: i).count; segments.remove(at: i) }
                else { replaceText(at: i, with: t, role: .answer) }
            }
            for i in segments.indices {
                if case .step(var s) = segments[i].kind, s.status == .running {
                    s.status = ok ? .done : .stopped
                    segments[i].kind = .step(s)
                }
            }
            for n in notes where !segments.contains(where: { $0.kind == .note(n) }) { append(.note(n)) }
            finished = true
        }
    }

    // MARK: Internals

    private var steps: [ChatStep] {
        segments.compactMap { if case .step(let s) = $0.kind { return s }; return nil }
    }

    private var openIndex: Int? {
        segments.lastIndex { if case .text(_, .open) = $0.kind { return true }; return false }
    }

    private var lastTextIndex: Int? {
        segments.lastIndex { if case .text = $0.kind { return true }; return false }
    }

    private var textRowCount: Int {
        segments.reduce(0) { if case .text = $1.kind { return $0 + 1 }; return $0 }
    }

    private func text(at i: Int) -> String {
        if case .text(let t, _) = segments[i].kind { return t }
        return ""
    }

    private mutating func append(_ kind: ChatSegment.Kind) {
        segments.append(ChatSegment(id: nextId, kind: kind))
        nextId += 1
    }

    /// The text being written is interim from the moment something else happens: it is the order rule.
    private mutating func sealOpen() {
        guard let i = openIndex else { return }
        let t = Self.trimmed(text(at: i))
        if t.isEmpty {
            textChars -= text(at: i).count
            segments.remove(at: i)
        } else {
            textChars -= text(at: i).count - t.count
            segments[i].kind = .text(t, role: .interim)
        }
    }

    private mutating func appendText(_ raw: String) {
        // The open text is always the last text row. Steps may follow it only after the row cap joined new text to it.
        if let i = openIndex {
            let room = Self.maxTextChars - textChars
            guard room > 0 else { return }
            let piece = raw.count > room ? String(raw.prefix(room)) : raw
            textChars += piece.count
            segments[i].kind = .text(text(at: i) + piece, role: .open)
            return
        }
        appendNewText(Self.dropLeadingBlankLines(raw), role: .open)
    }

    /// Past `maxTextRows` text rows, new text joins the last text row (after a blank line) instead of making a row:
    /// the rows of a chatty turn stay bounded and no text is lost, only its place relative to the steps after that
    /// row. The answer (`finalText`) is never joined: it is always its own row, at the end.
    private mutating func appendNewText(_ t: String, role: ChatSegment.TextRole) {
        guard !t.allSatisfy(\.isWhitespace) else { return }
        if role != .answer, textRowCount >= Self.maxTextRows, let j = lastTextIndex {
            let room = Self.maxTextChars - textChars - 2
            guard room > 0 else { return }
            let piece = t.count > room ? String(t.prefix(room)) : t
            textChars += piece.count + 2
            segments[j].kind = .text(text(at: j) + "\n\n" + piece, role: role)
            return
        }
        let room = Self.maxTextChars - textChars
        guard room > 0 else { return }
        let piece = t.count > room ? String(t.prefix(room)) : t
        textChars += piece.count
        append(.text(piece, role: role))
    }

    private mutating func replaceText(at i: Int, with t: String, role: ChatSegment.TextRole) {
        let old = text(at: i)
        let room = Self.maxTextChars - (textChars - old.count)
        let piece = t.count > room ? String(t.prefix(max(room, 0))) : t
        textChars += piece.count - old.count
        segments[i].kind = .text(piece, role: role)
    }

    /// Past `maxSteps` the oldest step goes and one `hiddenSteps` row stays where the first one was.
    private mutating func capSteps() {
        let isStep: (ChatSegment) -> Bool = { if case .step = $0.kind { return true }; return false }
        guard segments.filter(isStep).count > Self.maxSteps, let first = segments.firstIndex(where: isStep) else { return }
        let removed = segments.remove(at: first)
        // The hidden row takes the id of the step it replaces, so ids still increase in list order.
        if !segments.contains(where: { $0.kind == .hiddenSteps }) {
            segments.insert(ChatSegment(id: removed.id, kind: .hiddenSteps), at: first)
        }
    }

    // MARK: Text helpers

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Runs of whitespace as one space: how the server compares the sentences it already sent.
    private static func collapsed(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    /// The server puts a blank line in front of the text that follows a tool round: a segment starts without it.
    private static func dropLeadingBlankLines(_ s: String) -> String {
        var cut = s.startIndex
        var i = s.startIndex
        while i < s.endIndex, s[i].isWhitespace {
            i = s.index(after: i)
            if s[s.index(before: i)].isNewline { cut = i }
        }
        return String(s[cut...])
    }

    /// Cut by scalars, not characters: a character can be any number of combining marks.
    private static func idKey(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: raw.unicodeScalars.prefix(maxIdChars))
        return String(scalars)
    }

    /// The tool name as a row shows it. Empty after cleaning means there is no step to show.
    static func cleanTool(_ raw: String) -> String { oneLine(raw, max: maxToolChars) }

    /// One line, no control or format character (the rule `HermesAgentNames.clean` uses), cut to `max` characters.
    /// Server strings are untrusted: they are only ever drawn as verbatim text.
    static func oneLine(_ raw: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        // `max * 4` scalars is more than `max` characters can need here; a huge string is not walked to its end.
        for u in raw.unicodeScalars.prefix(max * 4) {
            let v = u.value
            if v == 0x0A || v == 0x0D || v == 0x09 {
                out.append(" ")
            } else if v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029
                        || (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069)
                        || u.properties.generalCategory == .format {
                continue
            } else {
                out.append(u)
            }
        }
        let line = String(out).trimmingCharacters(in: .whitespaces)
        return String(line.prefix(max))
    }
}
