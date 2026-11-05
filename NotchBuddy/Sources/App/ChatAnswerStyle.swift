import Foundation

// The pure rules behind the answer card of a chat turn: how the rows of a turn are grouped and folded, how an
// answer paragraph gets a lead, a status strip, marks and an ask call-out. Foundation only, in both builds, no flag.
//
// Every rule only adds a role or a mark to text. The characters of the agent text are always drawn, in order, none
// dropped and none repeated; the one exception is white space: a section splits its paragraph on every line break
// character and trims spaces and tabs at the ends of each line (empty lines vanish). A rule that does not match
// leaves the block as a plain paragraph. Display only: nothing here is stored, logged or sent.

// MARK: - Work group of a turn

enum ChatTurnLayout {
    /// Whether an answer card draws a mail plan card for its ```coucou-mail block. Only a turn of the shared chat asked with
    /// Mail on may: text from a Hermes agent (it reads Telegram, the web) or from a chat with Mail off is never a plan to
    /// run on the user's mailbox, so its block stays plain markdown.
    static func shouldShowMailPlan(askedWithMail: Bool, text: String) -> Bool {
        askedWithMail && text.contains("```coucou-mail")
    }

    /// The steps, the dropped steps row and the interim sentences that come before an answer, in order.
    struct WorkGroup: Equatable {
        let id: Int                      // id of the first row
        let rows: [ChatSegment]
    }

    enum Mode: Equatable {
        case rows                        // drawn as today's rows: nothing worth folding
        case live                        // the turn runs: one box with the current step
        case folded                      // one summary row, the list opens on a click
    }

    enum Item: Equatable, Identifiable {
        case group(WorkGroup, mode: Mode)
        case card(id: Int, text: String, open: Bool)
        case note(id: Int, text: String)
        /// A permission or a question that stays outside the fold (cmux timeline only; Hermes never has one).
        case moment(id: Int, ChatMoment)

        var id: Int {
            switch self {
            case .group(let group, _): return group.id
            case .card(let id, _, _), .note(let id, _), .moment(let id, _): return id
            }
        }
    }

    /// Every segment lands in exactly one item (a text with nothing but whitespace makes none). A note never folds:
    /// inside a run of work it is emitted right after the group. So does a moment that stays visible (`ChatMoment.staysVisible`);
    /// any other moment joins the run and is seen when the group is open. `media`: the answers of this agent may carry media
    /// directives (`ChatMediaDirectives`): a text that is only directives, or only the start of one, makes no card
    /// until something to draw is there.
    static func items(segments: [ChatSegment], running: Bool, media: Bool = false) -> [Item] {
        var out: [Item] = []
        var run: [ChatSegment] = []
        var held: [ChatSegment] = []

        func flush() {
            if !run.isEmpty { out.append(.group(WorkGroup(id: run[0].id, rows: run), mode: .rows)); run = [] }
            for n in held {
                switch n.kind {
                case .note(let t): out.append(.note(id: n.id, text: t))
                case .moment(let m): out.append(.moment(id: n.id, m))
                default: break
                }
            }
            held = []
        }

        for segment in segments {
            switch segment.kind {
            case .step, .hiddenSteps, .edit:
                run.append(segment)
            case .moment(let m):
                if !m.staysVisible {
                    run.append(segment)
                } else if run.isEmpty {
                    out.append(.moment(id: segment.id, m))
                } else {
                    held.append(segment)
                }
            case .text(let t, let role):
                if role == .interim {
                    run.append(segment)
                } else {
                    flush()
                    if !t.allSatisfy(\.isWhitespace), !(media && isEmptyOfMedia(t, streaming: role == .open)) {
                        out.append(.card(id: segment.id, text: t, open: role == .open))
                    }
                }
            case .note(let t):
                if run.isEmpty { out.append(.note(id: segment.id, text: t)) } else { held.append(segment) }
            }
        }
        flush()

        let lastGroup = out.lastIndex { if case .group = $0 { return true }; return false }
        for index in out.indices {
            guard case .group(let group, _) = out[index] else { continue }
            let closedCardFollows = out[(index + 1)...].contains { if case .card(_, _, false) = $0 { return true }; return false }
            out[index] = .group(group, mode: mode(of: group, live: running && index == lastGroup && !closedCardFollows))
        }
        return out
    }

    /// Nothing to draw once the directives are taken out: no text and no attachment.
    private static func isEmptyOfMedia(_ text: String, streaming: Bool) -> Bool {
        let found = ChatMediaDirectives.extractCached(text, streaming: streaming)
        return found.attachments.isEmpty && found.text.allSatisfy(\.isWhitespace)
    }

    private static func mode(of group: WorkGroup, live: Bool) -> Mode {
        if live { return .live }
        var steps = 0, interim = false, hidden = false
        for row in group.rows {
            switch row.kind {
            case .step, .edit: steps += 1
            case .hiddenSteps: hidden = true
            case .text: interim = true
            case .note, .moment: break
            }
        }
        if steps == 0 && !hidden { return .rows }
        if steps <= 2 && !interim && !hidden { return .rows }
        return .folded
    }

    /// The turn has a work group: a step, a file edit, a dropped steps row or an interim sentence. A note, a moment or
    /// an answer is not work.
    static func hasWork(_ segments: [ChatSegment]) -> Bool {
        segments.contains { segment in
            switch segment.kind {
            case .step, .hiddenSteps, .edit: return true
            case .text(_, let role): return role == .interim
            case .note, .moment: return false
            }
        }
    }

    /// The agent waits for the user: a permission or a question that is open, or handed to the terminal, and nothing
    /// else is still running (a tool that runs in parallel with the request keeps the turn at work).
    static func waitsForUser(_ segments: [ChatSegment]) -> Bool {
        var awaiting = Set<String>()
        var waits = false
        for segment in segments {
            guard case .moment(let m) = segment.kind, m.waitsForUser else { continue }
            waits = true
            if m.kind == .permission { awaiting.insert(m.callId) }
        }
        guard waits else { return false }
        return !segments.contains { segment in
            if case .step(let step) = segment.kind { return step.status == .running && !awaiting.contains(step.callId) }
            return false
        }
    }

    /// The pairing keys of the permissions that wait for the user: the steps of those calls are shown by their moment.
    /// A request handled where Coucou does not hear is not here: it was most likely allowed in the terminal, so its step
    /// is the live one while it runs (`close` drops a step whose request never reached a decision).
    static func awaitingKeys(_ items: [Item]) -> Set<String> {
        var keys = Set<String>()
        for case .moment(_, let m) in items where m.kind == .permission && m.waitsForUser { keys.insert(m.callId) }
        return keys
    }

    /// The block of a turn shows the typing dots itself when it runs and draws nothing alive: no live group and no
    /// card (open or closed), so its items are notes or none. Pure on the items: it does not read the typing flag of
    /// the surface, which Hermes drops at its first row of any kind. A block with no items also shows them while the
    /// surface waits (`typing`).
    static func showsOwnDots(items: [Item], running: Bool, typing: Bool) -> Bool {
        if items.isEmpty { return running || typing }
        return running && !items.contains { item in
            switch item {
            case .group(_, .live), .card: return true
            // A turn that waits for the user is not typing.
            case .moment(_, let m): return m.waitsForUser
            default: return false
            }
        }
    }

    /// The typing dots block under the running turn gives way to the zero height anchor when the turn already draws
    /// something alive: a live box (it has a work group) or its own dots (`showsOwnDots`). Otherwise a second set of
    /// dots would sit under the first.
    /// `lastSegments`: the segments of the last message when it is the running agent message, else nil.
    static func anchorReplacesDots(typing: Bool, streamingLast: Bool, lastSegments: [ChatSegment]?, media: Bool = false) -> Bool {
        guard typing, streamingLast, let segments = lastSegments, !segments.isEmpty else { return false }
        return hasWork(segments) || waitsForUser(segments)
            || showsOwnDots(items: items(segments: segments, running: true, media: media), running: true, typing: false)
    }

    /// A finished turn with a folded group, interim text in it and no answer: what the agent said must not be hidden.
    static func startsExpanded(_ items: [Item]) -> Bool {
        var folded = false
        for item in items {
            switch item {
            case .card: return false
            case .group(let group, .folded):
                if group.rows.contains(where: { if case .text = $0.kind { return true }; return false }) { folded = true }
            case .group(_, .live): return false
            default: break
            }
        }
        return folded
    }
}

// MARK: - Summary of a group

struct ChatWorkSummary: Equatable {
    struct ToolCount: Equatable {
        let tool: String
        let count: Int
        /// SF Symbol of the first row of that tool, when it brought one (cmux). nil: the table below.
        var symbol: String? = nil
    }
    /// A file edited in the group: the counts of all its edits and the newest of them.
    struct FileCount: Equatable {
        let path: String
        let name: String
        let added: Int
        let removed: Int
        let latest: ChatEdit
        /// The diff of the newest edit that kept one.
        var diffId: Int? { latest.diffId }
    }
    static let maxFiles = 40
    enum State: Equatable { case done, running, stopped }
    struct LiveStep: Equatable { let step: ChatStep; let segmentId: Int; let number: Int? }

    /// Steps in the group (at most `ChatTurnBuilder.maxSteps`).
    let count: Int
    /// Older steps were dropped: the real count is unknown, the text says "N+".
    let more: Bool
    /// Distinct tool names (server text, verbatim), most used first, ties in order of first appearance.
    let tools: [ToolCount]
    let state: State

    init(group: ChatTurnLayout.WorkGroup) {
        var order: [String] = []
        var counts: [String: Int] = [:]
        var symbols: [String: String] = [:]
        var n = 0, hidden = false, stopped = false, running = false
        for row in group.rows {
            switch row.kind {
            case .step(let s):
                n += 1
                if counts[s.tool] == nil { order.append(s.tool); if let sym = s.symbol { symbols[s.tool] = sym } }
                counts[s.tool, default: 0] += 1
                if s.status == .stopped { stopped = true }
                if s.status == .running { running = true }
            case .edit(let e):
                n += 1
                if counts[e.tool] == nil { order.append(e.tool); if let sym = e.symbol { symbols[e.tool] = sym } }
                counts[e.tool, default: 0] += 1
            case .hiddenSteps: hidden = true
            case .text, .note, .moment: break
            }
        }
        count = n
        more = hidden
        // `sorted` is not stable: the position of first appearance breaks the ties.
        tools = order.enumerated()
            .sorted { a, b in
                let ca = counts[a.element] ?? 0, cb = counts[b.element] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map { ToolCount(tool: $0.element, count: counts[$0.element] ?? 0, symbol: symbols[$0.element]) }
        state = stopped ? .stopped : (running ? .running : .done)
    }

    /// The first `limit` tools, and how many distinct tools are left out.
    func shown(limit: Int) -> (tools: [ToolCount], extra: Int) {
        let n = max(0, min(limit, tools.count))
        return (Array(tools.prefix(n)), tools.count - n)
    }

    static func symbol(for tool: String) -> String {
        switch tool {
        case "terminal": return "terminal"
        case "read_file": return "doc.text"
        case "search_files": return "magnifyingglass"
        case "web_search": return "globe"
        default: return "wrench"
        }
    }

    /// The last running step (the one that shimmers), else the last step; a file edit is a candidate too. `number` is
    /// its 1 based position among the steps of the group, nil once steps were dropped. `awaiting`: pairing keys of
    /// calls that wait for the user; their running step is shown by its moment, so it is not the live one.
    static func liveStep(group: ChatTurnLayout.WorkGroup, awaiting: Set<String> = []) -> LiveStep? {
        var steps: [(segment: ChatSegment, step: ChatStep)] = []
        var hidden = false
        for row in group.rows {
            if case .step(let s) = row.kind { steps.append((row, s)) }
            if case .edit(let e) = row.kind { steps.append((row, e.asStep)) }
            if case .hiddenSteps = row.kind { hidden = true }
        }
        let shown = steps.indices.filter { !(steps[$0].step.status == .running && awaiting.contains(steps[$0].step.callId)) }
        guard !shown.isEmpty else { return nil }
        let index = shown.last { steps[$0].step.status == .running } ?? shown[shown.count - 1]
        return LiveStep(step: steps[index].step, segmentId: steps[index].segment.id, number: hidden ? nil : index + 1)
    }

    /// The files edited in the group: distinct paths in order of first edit, counts summed, at most `maxFiles`.
    static func files(group: ChatTurnLayout.WorkGroup) -> [FileCount] {
        var order: [String] = []
        var sums: [String: (added: Int, removed: Int, latest: ChatEdit)] = [:]
        for row in group.rows {
            guard case .edit(let e) = row.kind else { continue }
            if var entry = sums[e.path] {
                entry.added += e.added
                entry.removed += e.removed
                entry.latest = e
                sums[e.path] = entry
            } else {
                order.append(e.path)
                sums[e.path] = (e.added, e.removed, e)
            }
        }
        return order.prefix(maxFiles).compactMap { path in
            sums[path].map { FileCount(path: path, name: $0.latest.name, added: $0.added, removed: $0.removed, latest: $0.latest) }
        }
    }

    /// The last interim sentence of the group.
    static func liveSentence(group: ChatTurnLayout.WorkGroup) -> String? {
        for row in group.rows.reversed() {
            if case .text(let t, .interim) = row.kind { return t }
        }
        return nil
    }
}

// MARK: - Header label

enum ChatTurnHeader {
    enum Label: Equatable { case working, answered, waitingForYou, none }

    /// The pending placeholder (no message yet) is not labelled here: its block carries `.working` itself.
    static func label(running: Bool, isNotice: Bool, hasAnswer: Bool) -> Label {
        if isNotice { return .none }
        if running { return .working }
        return hasAnswer ? .answered : .none
    }

    /// The same, for a turn that may wait for the user (cmux only: no other chat has a moment). A turn that waits says
    /// so before anything else; with `waitsForUser` false it is exactly `label`.
    static func turnLabel(running: Bool, isNotice: Bool, hasAnswer: Bool, waitsForUser: Bool) -> Label {
        if !isNotice && waitsForUser { return .waitingForYou }
        return label(running: running, isNotice: isNotice, hasAnswer: hasAnswer)
    }

    /// The message has an answer to label: a text with the role of an answer (interim sentences are not one), or the
    /// plain `content` of a message with no segments.
    static func hasAnswer(segments: [ChatSegment], content: String) -> Bool {
        if segments.isEmpty { return !content.isEmpty }
        return segments.contains { if case .text(let t, .answer) = $0.kind { return !t.isEmpty }; return false }
    }
}

// MARK: - Marks and kinds

enum StatusKind: Equatable { case good, warn, bad, mute }

enum MarkKind: Equatable {
    case status(String, StatusKind)
    case amount
    case time                            // dates and times
}

struct PlainMark: Equatable {
    let range: Range<String.Index>
    let kind: MarkKind
}

struct AttributedMark {
    let range: Range<AttributedString.Index>
    let kind: MarkKind
}

/// What the card draws, from the blocks of the parser.
enum CardItem: Equatable {
    case verdict(String)
    case section(lead: String, lines: [String])
    case ask(String)
    case block(MDBlock, closed: Bool)
    case hairline
    /// The row of an attachment (`ChatMediaDirectives`), at the place of the directive line.
    case attachment(Int)
}

// MARK: - Rules

enum ChatAnswerRules {
    static let leadMaxChars = 70
    static let askMaxChars = 400
    static let maxMarksPerBlock = 400
    /// The one switch of the status strip under each section lead. False removes the strip row and nothing else.
    static let showsStatusStrip = true

    private static let statusKinds: [String: StatusKind] = [
        "ACTIVE": .good,
        "PAUSED": .warn, "PENDING": .warn, "PENDING_REVIEW": .warn, "IN_PROCESS": .warn, "WITH_ISSUES": .warn,
        "DISAPPROVED": .bad, "REJECTED": .bad, "FAILED": .bad,
        "ARCHIVED": .mute, "DELETED": .mute,
    ]

    // MARK: Lead

    /// The lines of a paragraph (trimmed of spaces and tabs, empty ones dropped) and, when the first line is a short
    /// title, that line. A title: two lines at least, at most 70 characters with a letter, no final punctuation, one
    /// sentence, not a URL, not closed by a quote or bracket after a sentence end, and the next line is not a peer:
    /// the same `key: value` shape at the start of both lines, three lines or more that are all short with no
    /// sentence end, a sign off (one word under the title); nor the rest of a wrapped sentence (a first line of 50
    /// characters or more, and a next line that starts with a lower case letter).
    static func lead(of paragraph: String) -> (lead: String?, lines: [String]) {
        let edge = CharacterSet(charactersIn: " \t")
        let lines = paragraph.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: edge) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2, let first = lines.first,
              !isTagLine(first),
              first.count <= leadMaxChars,
              first.contains(where: \.isLetter),
              let last = first.last, !".!?:;…,".contains(last),
              !first.contains(". "), !first.contains("! "), !first.contains("? "),
              !endsSentenceInsideClosers(first), !isURL(first),
              let second = lines.dropFirst().first else { return (nil, lines) }
        if first.count >= wrapMinChars, second.first?.isLowercase == true { return (nil, lines) }
        if startsWithKeyValue(first) && startsWithKeyValue(second) { return (nil, lines) }
        let short = lines.allSatisfy { $0.count <= leadMaxChars && !endsSentence($0) }
        if short && lines.count >= 3 { return (nil, lines) }
        if short && lines.count == 2 && !second.contains(where: \.isWhitespace) { return (nil, lines) }
        return (first, Array(lines.dropFirst()))
    }

    /// `[[word]]`: a directive of the agent platforms (an unknown one stays text, but never a title).
    private static func isTagLine(_ line: String) -> Bool {
        guard line.hasPrefix("[["), line.hasSuffix("]]"), line.count > 4 else { return false }
        return line.dropFirst(2).dropLast(2).allSatisfy { $0.isLowercase || $0 == "_" || $0.isNumber }
    }

    /// A first line this long, followed by a lower case line, is the first half of a hard wrapped sentence.
    private static let wrapMinChars = 50

    /// `Nome: Emma`: a key of at most three words, a colon and a space, at the start of the line.
    private static func startsWithKeyValue(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":"), line.index(after: colon) < line.endIndex,
              line[line.index(after: colon)] == " " else { return false }
        let key = line[..<colon].split(whereSeparator: \.isWhitespace)
        return !key.isEmpty && key.count <= 3
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    private static let quoteClosers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

    private static func endsSentence(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return sentenceEnds.contains(last) || endsSentenceInsideClosers(line)
    }

    /// `Fim."` or `Pergunta?)`: a sentence end followed only by closing quotes or brackets.
    private static func endsSentenceInsideClosers(_ line: String) -> Bool {
        var end = line.endIndex
        var closed = false
        while end > line.startIndex, quoteClosers.contains(line[line.index(before: end)]) {
            end = line.index(before: end)
            closed = true
        }
        guard closed, end > line.startIndex else { return false }
        return sentenceEnds.contains(line[line.index(before: end)])
    }

    private static func isURL(_ line: String) -> Bool {
        let lower = line.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://")) && !line.contains(where: \.isWhitespace)
    }

    // MARK: Ask

    static func isAsk(block: MDBlock, index: Int, count: Int, streaming: Bool) -> Bool {
        guard !streaming, count >= 2, index == count - 1, case .paragraph(let text) = block,
              text.count <= askMaxChars else { return false }
        var end = text.endIndex
        let closers: Set<Character> = ["*", "_", "~"]
        while end > text.startIndex {
            let before = text.index(before: end)
            let ch = text[before]
            if ch.isWhitespace || closers.contains(ch) { end = before } else { break }
        }
        guard end > text.startIndex else { return false }
        let last = text[text.index(before: end)]
        return last == "?" || last == "？"
    }

    // MARK: Sections

    /// The status strip of a section is not part of the item: it is computed by the view of the item (`statusStrip`),
    /// once, when the paragraph closes, and not again while a later block streams.
    static func sections(blocks all: [MDBlock], streaming: Bool, verdict: Bool, attachments: Int = 0) -> [CardItem] {
        // The slot lines of the attachments (`ChatMediaDirectives.slotLine`) are not blocks of text: they place a row.
        // Every rule below reads the blocks without them (the first paragraph, the last one), and the row is emitted
        // where its slot was. Only the slots of a parse that made `attachments` rows are read: a paragraph that merely looks
        // like a slot (private use characters in some other chat) stays a paragraph.
        var blocks: [MDBlock] = []
        var slots: [[Int]] = [[]]
        for block in all {
            if case .paragraph(let text) = block, let id = ChatMediaDirectives.slotID(of: text), id < attachments {
                slots[slots.count - 1].append(id)
            } else {
                blocks.append(block)
                slots.append([])
            }
        }
        var items: [CardItem] = []
        var afterSection = false
        var sawHeading = false

        func hairline() {
            if !items.isEmpty, items.last != .hairline { items.append(.hairline) }
        }
        func add(_ item: CardItem) {
            if afterSection {
                if case .ask = item {} else { hairline() }
                afterSection = false
            }
            items.append(item)
        }

        for (index, block) in blocks.enumerated() {
            for id in slots[index] { add(.attachment(id)) }
            let closed = !streaming || index < blocks.count - 1
            switch block {
            case .paragraph(let text):
                if isAsk(block: block, index: index, count: blocks.count, streaming: streaming) {
                    add(.ask(text))
                } else if !closed {
                    // Open text is body, except a first paragraph under a verdict: it never changes size while it
                    // streams, unless it is already shaped like a lead section (then it is body until it closes).
                    if verdict && index == 0 && lead(of: text).lead == nil {
                        add(.verdict(text))
                    } else {
                        add(.block(block, closed: false))
                    }
                } else if !sawHeading, case let split = lead(of: text), let title = split.lead {
                    hairline()
                    items.append(.section(lead: title, lines: split.lines))
                    afterSection = true
                } else if verdict && index == 0 {
                    add(.verdict(text))
                } else {
                    add(.block(block, closed: true))
                }
            case .heading:
                sawHeading = true
                add(.block(block, closed: closed))
            case .rule:
                hairline()
                afterSection = false
            default:
                add(.block(block, closed: closed))
            }
        }
        for id in slots[blocks.count] { add(.attachment(id)) }
        // A text that ends with a rule has no divider to close the card on.
        if items.last == .hairline { items.removeLast() }
        return items
    }

    // MARK: Status strip

    /// The distinct status words of the texts the body draws (`bodyTexts`, so a marker open over two lines is read
    /// as the view reads it), in order of first appearance. The same scan as the tint of the body (code, links and
    /// bare URLs excluded), so a capsule never names a word the text does not show tinted.
    /// Called by the view of a closed section, not by `sections`: it costs a markdown parse per line.
    static func statusStrip(lines: [String]) -> [String] {
        var seen: [String] = []
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        for line in bodyTexts(lines: lines) {
            let attributed = (try? AttributedString(markdown: line, options: options)) ?? AttributedString(line)
            for mark in marks(in: attributed) {
                if case .status(let word, _) = mark.kind, !seen.contains(word) { seen.append(word) }
            }
        }
        return seen
    }

    // MARK: Open markers

    /// A body line that starts an emphasis, a code span or a link it does not close (`**nota que`, `[o log`): the
    /// markdown goes on in the next line, so the lines of the section must be drawn as one text.
    static func leavesMarkerOpen(_ line: String) -> Bool {
        let c = Array(line)
        let n = c.count
        var doubleStar = 0, singleStar = 0, doubleUnderscore = 0, singleUnderscore = 0, doubleTilde = 0
        var brackets = 0
        var i = 0
        while i < n {
            let ch = c[i]
            if ch == "\\" { i += 2; continue }
            if ch == "`" {
                var k = i
                while k < n, c[k] == "`" { k += 1 }
                let length = k - i
                var j = k
                var closed = false
                while j < n {
                    guard c[j] == "`" else { j += 1; continue }
                    var m = j
                    while m < n, c[m] == "`" { m += 1 }
                    if m - j == length { closed = true; j = m; break }
                    j = m
                }
                if !closed { return true }
                i = j
                continue
            }
            if ch == "*" || ch == "_" || ch == "~" {
                var k = i
                while k < n, c[k] == ch { k += 1 }
                let length = k - i
                let before = i > 0 ? c[i - 1] : " "
                let after = k < n ? c[k] : " "
                // Not a marker: a lone `*` or `~`, spaces on both sides, an underscore inside a word.
                let intraword = (before.isLetter || before.isNumber) && (after.isLetter || after.isNumber)
                let counts = ch == "_" ? !intraword : !(before.isWhitespace && after.isWhitespace)
                if counts {
                    switch ch {
                    case "*": doubleStar += length / 2; singleStar += length % 2
                    case "_": doubleUnderscore += length / 2; singleUnderscore += length % 2
                    default: doubleTilde += length / 2
                    }
                }
                i = k
                continue
            }
            if ch == "[" { brackets += 1 }
            if ch == "]", brackets > 0 {
                brackets -= 1
                if i + 1 < n, c[i + 1] == "(" {
                    guard let close = c[(i + 2)...].firstIndex(of: ")") else { return true }
                    i = close + 1
                    continue
                }
            }
            i += 1
        }
        return brackets > 0 || doubleStar % 2 == 1 || singleStar % 2 == 1 || doubleUnderscore % 2 == 1
            || singleUnderscore % 2 == 1 || doubleTilde % 2 == 1
    }

    /// The texts a section draws for its body lines: one per line, or a single text joined with newlines when a line
    /// leaves a marker open (the 7 pt gap between lines is lost for that section only).
    static func bodyTexts(lines: [String]) -> [String] {
        guard !lines.isEmpty else { return [] }
        return lines.contains(where: leavesMarkerOpen) ? [lines.joined(separator: "\n")] : lines
    }

    /// A table cell that is exactly one status word (drawn as a capsule).
    static func statusOnly(_ cell: String) -> (word: String, kind: StatusKind)? {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard let kind = statusKinds[trimmed] else { return nil }
        return (trimmed, kind)
    }

    // MARK: Marks

    /// The marks of an inline text: runs in a code span or a link are skipped, but their characters still count as
    /// neighbours for the whole word test.
    static func marks(in attributed: AttributedString) -> [AttributedMark] {
        let plain = String(attributed.characters)
        var skipped: [Range<Int>] = []
        var offset = 0
        for run in attributed.runs {
            let size = String(attributed[run.range].characters).utf8.count
            if (run.inlinePresentationIntent?.contains(.code) ?? false) || run.link != nil {
                skipped.append(offset..<(offset + size))
            }
            offset += size
        }
        var result: [AttributedMark] = []
        var cursor = plain.startIndex
        var cursorOffset = 0
        for mark in marks(inPlain: plain) {
            let lo = cursorOffset + plain.utf8.distance(from: cursor, to: mark.range.lowerBound)
            let hi = lo + plain.utf8.distance(from: mark.range.lowerBound, to: mark.range.upperBound)
            cursor = mark.range.lowerBound
            cursorOffset = lo
            if skipped.contains(where: { $0.lowerBound < hi && lo < $0.upperBound }) { continue }
            if let a = AttributedString.Index(mark.range.lowerBound, within: attributed),
               let b = AttributedString.Index(mark.range.upperBound, within: attributed) {
                result.append(AttributedMark(range: a..<b, kind: mark.kind))
            }
        }
        return result
    }

    /// Statuses first, then amounts, then dates and times; a match that overlaps an earlier one is dropped. At most
    /// `maxMarksPerBlock`: the rest of the text stays plain. Linear: no regular expression, no backtracking.
    static func marks(inPlain text: String) -> [PlainMark] {
        let c = Array(text)
        guard !c.isEmpty else { return [] }
        let limit = maxMarksPerBlock
        var found = statusPass(c, limit: limit)
        for candidate in amountPass(c, limit: limit) + datePass(c, limit: limit) {
            if !found.contains(where: { $0.range.overlaps(candidate.range) }) { found.append(candidate) }
        }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        if found.count > limit { found.removeLast(found.count - limit) }

        var indices: [String.Index] = []
        indices.reserveCapacity(c.count + 1)
        var i = text.startIndex
        while i < text.endIndex { indices.append(i); i = text.index(after: i) }
        indices.append(text.endIndex)
        return found.map { PlainMark(range: indices[$0.range.lowerBound]..<indices[$0.range.upperBound], kind: $0.kind) }
    }

    private struct Found { let range: Range<Int>; let kind: MarkKind }

    private static func isUpper(_ ch: Character) -> Bool {
        guard let a = ch.asciiValue else { return false }
        return a >= 65 && a <= 90
    }
    private static func isDigit(_ ch: Character) -> Bool {
        guard let a = ch.asciiValue else { return false }
        return a >= 48 && a <= 57
    }
    /// A letter, a number or an underscore (Unicode).
    private static func isWordChar(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }

    private static func statusPass(_ c: [Character], limit: Int) -> [Found] {
        var out: [Found] = []
        var i = 0
        while i < c.count, out.count < limit {
            guard isUpper(c[i]) else { i += 1; continue }
            var j = i
            while j < c.count, isUpper(c[j]) || c[j] == "_" { j += 1 }
            let length = j - i
            if length >= 5, length <= 14,
               i == 0 || !isWordChar(c[i - 1]),
               j == c.count || !isWordChar(c[j]),
               let kind = statusKinds[String(c[i..<j])] {
                out.append(Found(range: i..<j, kind: .status(String(c[i..<j]), kind)))
            }
            i = j
        }
        return out
    }

    private static func isMinus(_ ch: Character) -> Bool { ch == "-" || ch == "\u{2212}" }

    private static let magnitudeWords: Set<String> = ["mil", "milhao", "milhoes", "bilhao", "bilhoes", "bi", "k", "mi", "mm", "m"]

    /// The word that starts at `from` (letters only, at most 10), folded to lower case without accents; nil when
    /// there is none or it is longer than 10 letters.
    private static func foldedWord(_ c: [Character], from: Int) -> String? {
        var j = from
        while j < c.count, c[j].isLetter, j - from <= 10 { j += 1 }
        guard j > from, j - from <= 10 else { return nil }
        if j < c.count, c[j].isNumber { return nil }
        return String(c[from..<j]).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    /// An amount that goes on: a letter glued to it (`5k`), a magnitude word (`1,5 mil`), or a ratio (`12:30`, `07/10`).
    private static func amountContinues(_ c: [Character], at q: Int) -> Bool {
        let n = c.count
        guard q < n else { return false }
        if c[q].isLetter { return true }
        if (c[q] == ":" || c[q] == "/"), q + 1 < n, isDigit(c[q + 1]) { return true }
        if c[q] == " " || c[q] == "\u{00A0}", q + 1 < n, let word = foldedWord(c, from: q + 1) { return magnitudeWords.contains(word) }
        return false
    }

    private static func amountPass(_ c: [Character], limit: Int) -> [Found] {
        let n = c.count
        var out: [Found] = []
        var i = 0
        while i < n, out.count < limit {
            var p = i
            // A minus sign belongs to the amount unless it is the hyphen of a word or a number (`x-R$ 5`).
            if isMinus(c[p]), i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber) { p += 1 }
            let signed = p > i
            if p < n, c[p] == "~" { p += 1 }
            var symbol = 0
            if p + 1 < n, c[p] == "R", c[p + 1] == "$" { symbol = 2 }
            else if p + 2 < n, c[p] == "U", c[p + 1] == "S", c[p + 2] == "$" { symbol = 3 }
            guard symbol > 0 else { i += 1; continue }
            // Not glued to the end of a word or a number (`XR$ 5`, `2R$ 5`).
            if !signed, i > 0, c[i - 1].isLetter || c[i - 1].isNumber { i = p + symbol; continue }
            var q = p + symbol
            if q < n, c[q] == " " || c[q] == "\u{00A0}" { q += 1 }
            guard q < n, isDigit(c[q]) else { i = p + symbol; continue }
            while q < n, isDigit(c[q]) { q += 1 }
            // Groups: one `.` or `,` and digits. A final separator with no digit after it is not part of the amount.
            while q + 1 < n, c[q] == "." || c[q] == ",", isDigit(c[q + 1]) {
                q += 1
                while q < n, isDigit(c[q]) { q += 1 }
            }
            if !amountContinues(c, at: q) { out.append(Found(range: i..<q, kind: .amount)) }
            i = q
        }
        return out
    }

    private static func number(_ c: [Character], _ i: Int, digits: Int) -> Int? {
        guard i >= 0, i + digits <= c.count else { return nil }
        var v = 0
        for k in i..<(i + digits) {
            guard isDigit(c[k]), let a = c[k].asciiValue else { return nil }
            v = v * 10 + Int(a) - 48
        }
        return v
    }

    /// `H:MM` or `HH:MM`, optionally `:SS`; not touching a digit, `:` or `/` on either side. Returns the end.
    /// `twoDigitHour`: a time on its own needs `HH` (`2:15` and `3:16` are scores and verses); inside a date, one
    /// digit is fine.
    private static func timeEnd(_ c: [Character], from i: Int, twoDigitHour: Bool) -> Int? {
        let n = c.count
        guard i < n, isDigit(c[i]) else { return nil }
        if i > 0, isDigit(c[i - 1]) || c[i - 1] == ":" || c[i - 1] == "/" { return nil }
        let hourDigits = (i + 1 < n && isDigit(c[i + 1])) ? 2 : 1
        if twoDigitHour, hourDigits == 1 { return nil }
        guard let hour = number(c, i, digits: hourDigits), hour <= 23 else { return nil }
        let colon = i + hourDigits
        guard colon < n, c[colon] == ":", let minute = number(c, colon + 1, digits: 2), minute <= 59 else { return nil }
        var end = colon + 3
        if end < n, c[end] == ":" {
            guard let second = number(c, end + 1, digits: 2), second <= 59 else { return nil }
            end += 3
        }
        if end < n, isDigit(c[end]) || c[end] == ":" || c[end] == "/" { return nil }
        return end
    }

    private static let dateWords: Set<String> = [
        "dia", "desde", "ate", "em", "no", "na", "de", "do", "da", "ontem", "hoje", "on", "since", "until", "from", "of",
        // Weekdays (`feira`: the suffix of `segunda-feira`).
        "feira", "segunda", "terca", "quarta", "quinta", "sexta", "sabado", "domingo",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
    private static let dateWordMaxLetters = 9
    private static let afterBareDate: Set<Character> = [".", ",", ";", "!", "?", ")", "]", "}", "\"", "'", "”", "’", "…", ":"]
    private static let rangeWords: Set<String> = ["a", "e", "ate", "to", "and"]
    private static let rangeSymbols: Set<Character> = ["-", "–", "—"]

    /// The word right before position `i` (one or more spaces between) is one of the date words.
    private static func dateWordBefore(_ c: [Character], _ i: Int) -> Bool {
        var j = i
        while j > 0, c[j - 1] == " " || c[j - 1] == "\u{00A0}" { j -= 1 }
        guard j < i else { return false }
        var k = j
        while k > 0, c[k - 1].isLetter, j - k <= dateWordMaxLetters { k -= 1 }
        guard k < j, j - k <= dateWordMaxLetters else { return false }
        let word = String(c[k..<j]).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return dateWords.contains(word)
    }

    private static func isSpace(_ ch: Character) -> Bool { ch == " " || ch == "\u{00A0}" }

    /// `dd/mm`, optionally `/yy` or `/yyyy`, starting at `i` and not touching a digit, `/` or `:` before it. Returns
    /// the end. No time: the pieces of a range are only tested for their shape.
    private static func dayMonthEnd(_ c: [Character], from i: Int) -> Int? {
        let n = c.count
        guard i >= 0, i < n, isDigit(c[i]) else { return nil }
        if i > 0, isDigit(c[i - 1]) || c[i - 1] == "/" || c[i - 1] == ":" { return nil }
        guard let day = number(c, i, digits: 2), (1...31).contains(day), i + 2 < n, c[i + 2] == "/",
              let month = number(c, i + 3, digits: 2), (1...12).contains(month) else { return nil }
        var end = i + 5
        if end < n, isDigit(c[end]) { return nil }
        if end < n, c[end] == "/" {
            var k = end + 1
            while k < n, isDigit(c[k]) { k += 1 }
            if k - (end + 1) == 2 || k - (end + 1) == 4 { end = k }
        }
        return end
    }

    /// The connector of a range at `from` (spaces, a hyphen or a dash, or a word with a space on each side) and the
    /// position after it and its spaces; nil when there is none.
    private static func rangeConnector(_ c: [Character], from: Int) -> Int? {
        let n = c.count
        var j = from
        while j < n, isSpace(c[j]) { j += 1 }
        let spaced = j > from
        if j < n, rangeSymbols.contains(c[j]) {
            j += 1
            while j < n, isSpace(c[j]) { j += 1 }
            return j
        }
        guard spaced else { return nil }
        var k = j
        while k < n, c[k].isLetter, k - j <= 3 { k += 1 }
        guard k > j, k - j <= 3, k < n, isSpace(c[k]) else { return nil }
        let word = String(c[j..<k]).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        guard rangeWords.contains(word) else { return nil }
        while k < n, isSpace(c[k]) { k += 1 }
        return k
    }

    /// A bare date at `i..<end` is the first half of a range (`07/10 a 08/10`) or the second (`07/10 a 08/10`, read
    /// from the other side): a connector and another date touch it.
    private static func inDateRange(_ c: [Character], from i: Int, to end: Int) -> Bool {
        if let next = rangeConnector(c, from: end), dayMonthEnd(c, from: next) != nil { return true }
        // Backwards: spaces, a connector, spaces, then a date that ends there.
        var j = i
        while j > 0, isSpace(c[j - 1]) { j -= 1 }
        let spacedAfter = j < i
        let symbolBefore: Bool
        if j > 0, rangeSymbols.contains(c[j - 1]) {
            symbolBefore = true
            j -= 1
        } else {
            symbolBefore = false
            guard spacedAfter else { return false }
            var k = j
            while k > 0, c[k - 1].isLetter, j - k <= 3 { k -= 1 }
            guard k < j, j - k <= 3 else { return false }
            let word = String(c[k..<j]).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            guard rangeWords.contains(word) else { return false }
            j = k
        }
        let beforeConnector = j
        while j > 0, isSpace(c[j - 1]) { j -= 1 }
        if !symbolBefore, j == beforeConnector { return false }
        // The date that ends at `j`: `dd/mm`, `dd/mm/yy` or `dd/mm/yyyy`.
        return [5, 8, 10].contains { length in j - length >= 0 && dayMonthEnd(c, from: j - length) == j }
    }

    /// `dd/mm`, optionally `/yy` or `/yyyy`, optionally one space and a time; not touching a digit, `/` or `:`. A bare
    /// day and month (no year, no time) is a date only at the end of the text or a line, before punctuation or an
    /// opening parenthesis, after a date word (`desde 19/09`, a weekday, `de`), or as one end of a range
    /// (`07/10 a 08/10`): `10/12 testes` is a count. A colon and a digit after it is a time (`07/10:30`). Returns the end.
    private static func dateEnd(_ c: [Character], from i: Int) -> Int? {
        let n = c.count
        guard i < n, isDigit(c[i]) else { return nil }
        if i > 0, isDigit(c[i - 1]) || c[i - 1] == "/" || c[i - 1] == ":" { return nil }
        guard let day = number(c, i, digits: 2), (1...31).contains(day), i + 2 < n, c[i + 2] == "/",
              let month = number(c, i + 3, digits: 2), (1...12).contains(month) else { return nil }
        var end = i + 5
        if end < n, isDigit(c[end]) { return nil }
        var bare = true
        if end < n, c[end] == "/" {
            var k = end + 1
            while k < n, isDigit(c[k]) { k += 1 }
            if k - (end + 1) == 2 || k - (end + 1) == 4 { end = k; bare = false }
        }
        if end + 1 < n, c[end] == " ", let t = timeEnd(c, from: end + 1, twoDigitHour: false) { end = t; bare = false }
        if end + 1 < n, c[end] == ":", isDigit(c[end + 1]) { return nil }
        if bare {
            var after = end
            while after < n, isSpace(c[after]) { after += 1 }
            let atEdge = end == n || c[end].isNewline || afterBareDate.contains(c[end]) || (after < n && c[after] == "(")
            guard atEdge || dateWordBefore(c, i) || inDateRange(c, from: i, to: end) else { return nil }
        }
        return end
    }

    private static func datePass(_ c: [Character], limit: Int) -> [Found] {
        var out: [Found] = []
        var i = 0
        while i < c.count, out.count < limit {
            guard isDigit(c[i]) else { i += 1; continue }
            if let end = dateEnd(c, from: i) ?? timeEnd(c, from: i, twoDigitHour: true) {
                out.append(Found(range: i..<end, kind: .time))
                i = end
                continue
            }
            while i < c.count, isDigit(c[i]) { i += 1 }
        }
        return out
    }
}
