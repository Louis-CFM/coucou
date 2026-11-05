import Foundation

// MARK: - Hermes approvals (pure logic: parsing, the text of the card, the queue, the wire messages). Nothing here does I/O
// (the URLRequest of the API key answer is only built).
//
// A Hermes agent asks before it runs a dangerous command, and the owner answers from the notch. Everything the
// server sends is untrusted: the command is text a model wrote, relayed by a server. Nothing here answers
// anything by itself; an answer exists only as the result of `HermesApprovalQueue.click`, which the card calls
// after a click on one of its buttons.

/// One approval asked by a Hermes agent.
struct HermesApprovalRequest: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// Sign in transport: the id of the server request frame and the live session id it names.
        case signIn(frameID: String, runtimeSession: String)
        /// API key transport: the id of the streamed completion (a run).
        case apiKey(runID: String)
    }
    /// The agent's identity name (`HermesAgent.name`), set by the transport, never by the server.
    var agentName: String
    var origin: Origin
    /// The queue's own id for this request: the only thing an answer is addressed to.
    var requestID: String
    /// As received. Shown only through `HermesApproval.display`.
    var command: String
    /// The server's description of what was flagged. Shown only through `grantLabel`, which says what Session and Always grant.
    var description: String
    /// What the server allows for this request, as it sent it. The card and the wire use `offered`.
    var choices: Set<HermesApproval.Choice>
    /// The server's pattern keys: Session and Always grant these (a class of commands), not the one command.
    var patternKeys: [String] = []

    /// Hermes redacts secrets before it sends the command: a mask in the text means part of it is hidden from the owner.
    var masked: Bool { HermesApproval.hasMask(command) }

    /// What the server allows AND the app can show honestly: Session and Always only when the card can name what they
    /// grant, and never for a command Hermes masked. Once and Deny stay.
    var offered: Set<HermesApproval.Choice> {
        if grantLabel == nil || masked { return choices.subtracting([.session, .always]) }
        return choices
    }

    /// One line naming what Session and Always grant: the description, through the display escaping, when it is plain
    /// printable text that fits the line and covers every pattern key. nil otherwise (then neither is offered).
    var grantLabel: String? { HermesApproval.grantLabel(description: description, patternKeys: patternKeys) }
}

/// The text the card shows for a command: every character visible, nothing reordered, nothing hidden.
struct HermesApprovalDisplay: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        /// One line of printable ASCII (and the marks) that fits the block: the card shows it whole.
        case inline
        /// Anything else: the closed card shows the start, the reading view shows everything.
        case reading
        /// Over the ceiling: it is never answerable with an allow in the notch.
        case tooLong
    }
    enum Kind: Equatable, Sendable {
        case plain
        /// A mark standing for a line break, a tab or a carriage return.
        case visible
        /// `⟨U+XXXX⟩` for a character that must not reach the text view.
        case escape
    }
    struct Run: Equatable, Sendable {
        var text: String
        var kind: Kind
    }
    var runs: [Run]
    var tier: Tier
    /// Lines and scalars of the text shown; of the raw command when `tier == .tooLong`.
    var lineCount: Int
    var scalarCount: Int
    /// Scalars of the command as it came (what "N characters" means to the person reading).
    var sourceScalarCount: Int
    /// The widest line of the text shown, in cells of the monospaced font (`HermesApproval.cells`).
    var widestRow: Int = 0
    /// Every plain scalar is printable ASCII: the only text whose width is known.
    var plainASCII: Bool = true

    var plain: String { runs.map(\.text).joined() }

    /// The start of the text for the closed card: at most `rows` lines, each cut at `HermesApproval.rowMaxCells` cells,
    /// whole marks only, with no line break after the last row. `cut` is true when a line was cut short;
    /// `hiddenLines` counts the lines after the last row. Both are announced by the card.
    struct Preview: Equatable, Sendable {
        var runs: [Run]
        var cut: Bool
        var hiddenLines: Int
    }

    func closedPreview(rows: Int) -> Preview {
        var out: [Run] = []
        var row = 1
        var cells = 0
        var skipping = false
        var cut = false
        var buffer = ""
        func flush() { if !buffer.isEmpty { out.append(Run(text: buffer, kind: .plain)); buffer = "" } }
        for run in runs {
            if run.kind == .plain, run.text == "\n" {
                if row >= rows { break }
                flush()
                out.append(run)
                row += 1
                cells = 0
                skipping = false
                continue
            }
            if skipping { continue }
            if run.kind == .plain {
                for u in run.text.unicodeScalars {
                    let c = HermesApproval.cells(u)
                    if cells + c > HermesApproval.rowMaxCells { skipping = true; cut = true; break }
                    buffer.unicodeScalars.append(u)
                    cells += c
                }
            } else {
                flush()
                let c = run.text.unicodeScalars.reduce(0) { $0 + HermesApproval.cells($1) }
                if cells + c > HermesApproval.rowMaxCells { skipping = true; cut = true } else { out.append(run); cells += c }
            }
        }
        flush()
        return Preview(runs: out, cut: cut, hiddenLines: max(0, lineCount - rows))
    }
}

enum HermesApproval {

    // MARK: Choices

    enum Choice: String, Sendable, CaseIterable {
        case once, session, always, deny
    }

    /// The three ways of allowing, as the selector of the card shows them.
    enum Scope: String, Sendable, CaseIterable {
        case once, session, always
        var choice: Choice {
            switch self {
            case .once: return .once
            case .session: return .session
            case .always: return .always
            }
        }
    }

    enum WithdrawReason: Equatable, Sendable {
        case timeout, resolved, interrupted, sessionClosed, socketLost, turnEnded, agentRemoved, stale, other
    }

    enum AnswerOutcome: Equatable, Sendable {
        /// The server took the answer.
        case applied
        /// The server says nothing was waiting any more.
        case tooLate
        /// The server refused it or could not be reached.
        case failed
        /// The connection ended before the answer came back: nobody knows.
        case unknown
    }

    // MARK: Turns

    private static let tokenLock = NSLock()
    nonisolated(unsafe) private static var lastToken = 0

    /// A number for one turn (or stream), so that its end withdraws exactly its own requests.
    static func nextTurnToken() -> Int {
        tokenLock.withLock { lastToken += 1; return lastToken }
    }

    // MARK: Limits

    static let maxPayloadBytes = 64 * 1024
    /// The card shows a line whole when it is printable ASCII of at most this many cells. Measured with the system monospaced
    /// font at 12 pt: one cell is 7.42 pt and the text area of the card is 468 pt (620 slot - 116 - 16 - 20), 63 cells.
    /// 56 cells (415 pt) leaves 53 pt of margin. The marks `⟨ ⟩ ⏎ ⇥ ␍` measure one cell each; every other scalar is
    /// counted 8 cells (the widest scalar of the Unicode range, U+1242B, measures 55.6 pt = 7.5 cells), so a line made of
    /// anything but ASCII never reads as short.
    static let inlineMaxCells = 56
    /// The closed card cuts a line here (explicitly, announced), so a row can never wrap or end in an ellipsis.
    static let rowMaxCells = 56
    /// At most this many of the eight places of the queue belong to one agent.
    static let maxPerAgent = 4

    /// Width of one scalar in cells of the monospaced font (see `inlineMaxCells`).
    static func cells(_ u: Unicode.Scalar) -> Int {
        switch u.value {
        case 0x20...0x7E, 0x27E8, 0x27E9, 0x23CE, 0x21E5, 0x240D: return 1
        default: return 8
        }
    }
    /// Above 2000 characters or 25 lines (of the text as shown) nothing allows in the notch.
    static let ceilingScalars = 2000
    static let ceilingLines = 25

    // MARK: Validation of ids that come from the server

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    }
    private static func isLowerHex(_ b: UInt8) -> Bool { (b >= 48 && b <= 57) || (b >= 97 && b <= 102) }

    static func isRequestID(_ s: String) -> Bool {
        (1...64).contains(s.utf8.count) && s.utf8.allSatisfy { isAlnum($0) || $0 == 45 || $0 == 95 }
    }

    /// `srq-` and hex: the id of a server request frame.
    static func isFrameID(_ s: String) -> Bool {
        guard s.hasPrefix("srq-") else { return false }
        let rest = s.utf8.dropFirst(4)
        return (6...64).contains(rest.count) && rest.allSatisfy(isLowerHex)
    }

    /// `chatcmpl-` and hex: the id of a streamed completion. It goes into a URL path.
    static func isRunID(_ s: String) -> Bool {
        guard s.hasPrefix("chatcmpl-") else { return false }
        let rest = s.utf8.dropFirst(9)
        return (1...64).contains(rest.count) && rest.allSatisfy(isLowerHex)
    }

    // MARK: Parsing

    private static func common(_ o: [String: Any]) -> (id: String, command: String, description: String, choices: Set<Choice>, keys: [String])? {
        guard let id = o["request_id"] as? String, isRequestID(id),
              let command = o["command"] as? String,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let raw = o["choices"] as? [Any] else { return nil }
        var choices = Set<Choice>()
        for c in raw { if let s = c as? String, let choice = Choice(rawValue: s) { choices.insert(choice) } }
        guard choices.contains(.once), choices.contains(.deny) else { return nil }
        if (o["allow_session"] as? Bool) == false { choices.remove(.session) }
        if (o["allow_permanent"] as? Bool) == false { choices.remove(.always) }
        if (o["smart_denied"] as? Bool) == true { choices = [.once, .deny] }
        let description = String(((o["description"] as? String) ?? "").prefix(1000))
        // Session and Always grant these keys on the server. A key the app cannot read as text leaves the list empty:
        // then nothing can be named, and `offered` drops both.
        var keys: [String] = []
        var readable = true
        if let one = o["pattern_key"] { if let k = one as? String { keys.append(k) } else { readable = false } }
        if let many = o["pattern_keys"] {
            if let list = many as? [Any], list.count <= 16 {
                for item in list { if let k = item as? String, k.utf8.count <= 256 { keys.append(k) } else { readable = false } }
            } else { readable = false }
        }
        return (id, command, description, choices, readable ? keys.filter { !$0.isEmpty } : [])
    }

    /// A `method: "approval"` server request frame (the whole JSON text). nil when anything is off: such a request
    /// is not answerable and is never answered with an error (that would withdraw it for every other client).
    static func parseSignIn(_ text: String, agent: String) -> HermesApprovalRequest? {
        guard text.utf8.count <= maxPayloadBytes,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              (obj["method"] as? String) == "approval",
              let frameID = obj["id"] as? String, isFrameID(frameID),
              let params = obj["params"] as? [String: Any],
              let session = params["session_id"] as? String, !session.isEmpty, session.utf8.count <= 256,
              let c = common(params) else { return nil }
        return HermesApprovalRequest(agentName: agent, origin: .signIn(frameID: frameID, runtimeSession: session),
                                     requestID: c.id, command: c.command, description: c.description, choices: c.choices,
                                     patternKeys: c.keys)
    }

    /// The data line of an `approval.request` SSE frame.
    static func parseAPIEvent(_ data: String, agent: String) -> HermesApprovalRequest? {
        guard data.utf8.count <= maxPayloadBytes,
              let obj = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any],
              let run = obj["run_id"] as? String, isRunID(run),
              let c = common(obj) else { return nil }
        return HermesApprovalRequest(agentName: agent, origin: .apiKey(runID: run), requestID: c.id,
                                     command: c.command, description: c.description, choices: c.choices, patternKeys: c.keys)
    }

    // MARK: The text of the card

    /// Letters, digits and punctuation of the right to left scripts. The bidirectional algorithm would reorder a command
    /// that holds them (`mv א ב` draws as `mv ב א`), so they are shown as marks and the line always reads left to right.
    /// Blocks: Hebrew to Arabic Extended-A (0590 to 08FF), Hebrew and Arabic presentation forms (FB1D to FDFF, FE70 to FEFF),
    /// the right to left scripts of the supplementary planes (10800 to 10FFF, 1E800 to 1EFFF).
    static func isRightToLeft(_ v: UInt32) -> Bool {
        (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v)
            || (0x10800...0x10FFF).contains(v) || (0x1E800...0x1EFFF).contains(v)
    }

    /// One rule: every scalar outside printable ASCII (0x20 to 0x7E) is shown as a mark, unassigned ones included, except
    /// the precomposed accented Latin letters below. The line break, tab and carriage return have their own marks and never
    /// get here. So no scalar can draw nothing, draw as an ASCII character (the Greek question mark, curly quotes, the
    /// division slash, full width digits) or reorder the line, and there is no list to keep up to date.
    private static func mustEscape(_ u: Unicode.Scalar) -> Bool {
        if (0x20...0x7E).contains(u.value) { return false }
        return !isPrecomposedAccented(u)
    }

    /// An accented letter that exists as one scalar in Latin-1 Supplement or Latin Extended-A: a base ASCII letter and
    /// accents (é, ñ, ü, ő). The only non ASCII letters that pass unmarked in a token that also holds ASCII letters.
    /// Not ı ſ ĸ (look alikes of i, f, k), ß æ ø đ ł (no base letter), IPA, modifier letters, small capitals.
    private static func isPrecomposedAccented(_ u: Unicode.Scalar) -> Bool {
        guard (0xC0...0x17F).contains(u.value) else { return false }
        let d = Array(String(u).decomposedStringWithCanonicalMapping.unicodeScalars)
        guard d.count >= 2, let first = d.first, first.isASCII, first.properties.isAlphabetic else { return false }
        return d.dropFirst().allSatisfy { $0.properties.generalCategory == .nonspacingMark }
    }

    /// Letters that draw nothing (Hangul fillers, Khmer inherent vowels): never kept as a glyph, only the mark.
    private static let blankLetters: Set<UInt32> = [0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0]

    /// A non ASCII letter that can pass for an ASCII one (Cyrillic, Greek, full width, IPA, small capitals…) and draws something.
    private static func isForeignLetter(_ u: Unicode.Scalar) -> Bool {
        !u.isASCII && u.properties.isAlphabetic && !isPrecomposedAccented(u) && !blankLetters.contains(u.value)
    }

    private static func escapeMark(_ u: Unicode.Scalar) -> String { "⟨U+" + String(format: "%04X", u.value) + "⟩" }

    /// Hermes redacts secrets in the command before it sends it (`agent/redact.py`): `***` for a short value, the first six
    /// characters, `...` and the last four for a value of 18 characters or more, `«redacted…»`, `[REDACTED…]`. A mask can sit
    /// where the shell code continues, so the owner never sees the whole command. The rule errs on the side of detecting:
    /// besides those words, any run of three or more dots (the character `…` counts as three), wherever it sits: the JSON
    /// field pass of the redactor keeps white space inside the value it hides, so a mask can read `"abcde ... xyz"`.
    /// `git diff a...b` and `echo ...` are therefore detected too; plain text without dots, `cd ..` and `ls .` are not.
    static func hasMask(_ text: String) -> Bool {
        if text.contains("***") { return true }
        let lower = text.lowercased()
        if lower.contains("«redacted") || lower.contains("[redacted") { return true }
        let s = Array(text.unicodeScalars)
        func weight(_ u: Unicode.Scalar) -> Int { u == "." ? 1 : u == "\u{2026}" ? 3 : 0 }
        var i = 0
        while i < s.count {
            guard weight(s[i]) > 0 else { i += 1; continue }
            var j = i
            var dots = 0
            while j < s.count, weight(s[j]) > 0 { dots += weight(s[j]); j += 1 }
            if dots >= 3 { return true }
            i = j
        }
        return false
    }

    /// Width in tenths of a point of the printable ASCII characters (0x20 to 0x7E) in the system font at 12 pt, rounded up.
    private static let asciiWidthTenths: [Int] = [
        34, 38, 58, 76, 76, 112, 86, 36, 46, 46, 57, 76, 36, 57, 36, 37, 76, 56, 73, 76, 78, 75, 77, 69, 77, 77, 36, 36, 76, 76, 76, 62,
        111, 81, 79, 86, 88, 72, 69, 90, 90, 33, 65, 80, 69, 105, 90, 93, 77, 93, 79, 77, 77, 89, 81, 117, 82, 79, 80, 46, 37, 46, 76, 71,
        60, 67, 74, 68, 74, 69, 44, 74, 71, 30, 30, 66, 31, 105, 71, 71, 74, 74, 46, 63, 44, 71, 66, 93, 63, 66, 65, 46, 32, 46, 76]
    /// The most the description of a grant may measure (pt, 6 % margin added). The card's line holds the agent name, the
    /// words "Always allow: " or "Allow for the session: " (up to 152 pt in the longest language) and the description in the
    /// 488 pt of the card; the name gives way first, so the description is never cut.
    static let grantMaxPoints = 250

    /// What Session and Always grant, as one line: the description of the request, when it is plain printable ASCII,
    /// passes the display escaping unchanged, fits `grantMaxPoints`, and says every pattern key the server will store.
    /// nil otherwise: the card then offers Once and Deny only.
    static func grantLabel(description: String, patternKeys: [String]) -> String? {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty, !patternKeys.isEmpty, d.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else { return nil }
        let shown = display(d)
        guard shown.tier == .inline, shown.runs.allSatisfy({ $0.kind == .plain }), shown.plain == d else { return nil }
        guard patternKeys.allSatisfy({ d.contains($0) }) else { return nil }
        let tenths = d.unicodeScalars.reduce(0) { $0 + asciiWidthTenths[Int($1.value) - 0x20] }
        return tenths * 106 / 1000 <= grantMaxPoints ? d : nil
    }

    /// Rules of plan 6.1: no normalisation; line breaks, tabs and carriage returns as visible marks; every other scalar
    /// outside printable ASCII, except the precomposed accented Latin letters, as `⟨U+XXXX⟩` (see `mustEscape`); a non ASCII
    /// letter in a token that also holds ASCII letters keeps its glyph and gets the mark; never a truncation.
    static func display(_ command: String) -> HermesApprovalDisplay {
        let scalars = Array(command.unicodeScalars)
        // A token ends at any whitespace. A foreign letter is a look alike only in a token with an ASCII letter.
        var mixedToken = [Bool](repeating: false, count: scalars.count)
        var start = 0
        func isBreak(_ u: Unicode.Scalar) -> Bool { u.properties.isWhitespace || mustEscape(u) && u.properties.generalCategory == .spaceSeparator }
        var i = 0
        while i <= scalars.count {
            if i == scalars.count || isBreak(scalars[i]) {
                if start < i {
                    let hasASCII = scalars[start..<i].contains { $0.isASCII && $0.properties.isAlphabetic }
                    if hasASCII { for j in start..<i { mixedToken[j] = true } }
                }
                start = i + 1
            }
            i += 1
        }

        var runs: [HermesApprovalDisplay.Run] = []
        var buffer = ""
        var count = 0
        var lines = 1
        var over = false
        var plainASCII = true
        var rowCells = 0
        var widest = 0
        func flush() {
            if !buffer.isEmpty { runs.append(.init(text: buffer, kind: .plain)); buffer = "" }
        }
        func mark(_ s: String, _ kind: HermesApprovalDisplay.Kind) {
            flush()
            runs.append(.init(text: s, kind: kind))
            count += s.unicodeScalars.count
            rowCells += s.unicodeScalars.reduce(0) { $0 + cells($1) }
            widest = max(widest, rowCells)
        }
        func plainScalar(_ u: Unicode.Scalar) {
            buffer.unicodeScalars.append(u)
            count += 1
            if !(0x20...0x7E).contains(u.value) { plainASCII = false }
            rowCells += cells(u)
            widest = max(widest, rowCells)
        }
        for (idx, u) in scalars.enumerated() {
            if count > ceilingScalars || lines > ceilingLines { over = true; break }
            switch u {
            case "\n":
                mark("⏎", .visible)
                runs.append(.init(text: "\n", kind: .plain))
                count += 1
                lines += 1
                rowCells = 0
            case "\t": mark("⇥", .visible)
            case "\r": mark("␍", .visible)
            default:
                if mixedToken[idx], isForeignLetter(u), !isRightToLeft(u.value) {
                    plainScalar(u)
                    mark(escapeMark(u), .escape)
                } else if mustEscape(u) {
                    mark(escapeMark(u), .escape)
                } else {
                    plainScalar(u)
                }
            }
        }
        if count > ceilingScalars || lines > ceilingLines { over = true }
        flush()
        if over {
            let rawLines = scalars.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
            return HermesApprovalDisplay(runs: runs, tier: .tooLong, lineCount: rawLines, scalarCount: scalars.count,
                                         sourceScalarCount: scalars.count, widestRow: widest, plainASCII: plainASCII)
        }
        // Inline only for what the card is known to hold on one line: printable ASCII and the marks, at most `inlineMaxCells`.
        let tier: HermesApprovalDisplay.Tier = (lines == 1 && plainASCII && widest <= inlineMaxCells) ? .inline : .reading
        return HermesApprovalDisplay(runs: runs, tier: tier, lineCount: lines, scalarCount: count, sourceScalarCount: scalars.count,
                                     widestRow: widest, plainASCII: plainASCII)
    }

    // MARK: Decisions

    /// The choice a button stands for, and only when the server offered it. There is no default: anything unknown
    /// (including "ask") is nil, and nil sends nothing.
    static func decision(for button: String, request: HermesApprovalRequest) -> Choice? {
        let choice: Choice
        switch button {
        case "allow", "once": choice = .once
        case "session": choice = .session
        case "always": choice = .always
        case "deny": choice = .deny
        default: return nil
        }
        return request.offered.contains(choice) ? choice : nil
    }

    /// Whether an answer may leave. Deny always may; an allow needs the whole text to have been shown: at once for a
    /// short command, after the end of the text for a long one, never above the ceiling.
    static func mayAnswer(_ choice: Choice, display: HermesApprovalDisplay, reachedEnd: Bool) -> Bool {
        if choice == .deny { return true }
        switch display.tier {
        case .inline: return true
        case .reading: return reachedEnd
        case .tooLong: return false
        }
    }

    // MARK: Pills and the card

    /// The pill of a connected Hermes agent (`agent_hermes_<key>`), not the hook pill `agent_hermes`.
    static func isHermesPill(_ id: String?) -> Bool { HermesPills.isTaskId(id) }

    /// A Hermes approval never goes to the iPhone or to iCloud.
    static func reachesPhone(pillId: String) -> Bool { !isHermesPill(pillId) }

    struct CardIdentity: Equatable {
        var sessionId: String
        var tool: String
        var inputKey: String
        var pillId: String
    }

    /// What the shared card slot holds for a Hermes request: ids only, no command text.
    static func cardIdentity(request: HermesApprovalRequest, pillId: String) -> CardIdentity {
        CardIdentity(sessionId: "hermes:\(request.agentName):\(request.requestID)", tool: "terminal",
                     inputKey: request.requestID, pillId: pillId)
    }

    enum NextCard: Equatable { case cmux, hermes, none }

    /// When the card slot frees: the cmux queue first (as before), then Hermes.
    static func nextForFreeSlot(cmuxWaiting: Bool, hermesWaiting: Bool) -> NextCard {
        cmuxWaiting ? .cmux : hermesWaiting ? .hermes : .none
    }

    // MARK: Words (fixed sentences; the command is never part of one)

    static func note(for reason: WithdrawReason) -> String {
        switch reason {
        case .timeout: return String(localized: "Timed out with no answer. Hermes blocked the command.")
        case .resolved: return String(localized: "Answered somewhere else.")
        case .interrupted, .sessionClosed, .turnEnded: return String(localized: "Hermes ended the session.")
        case .socketLost: return String(localized: "Connection to Hermes lost.")
        case .agentRemoved: return String(localized: "The agent was removed.")
        case .stale, .other: return String(localized: "Hermes withdrew the request.")
        }
    }

    static func answerNote(_ choice: Choice) -> String {
        switch choice {
        case .once: return String(localized: "Allowed once.")
        case .session: return String(localized: "Allowed for the session.")
        case .always: return String(localized: "Allowed always.")
        case .deny: return String(localized: "Denied.")
        }
    }

    static let tooLateNote = String(localized: "This request was no longer waiting.")
    static let failedNote = String(localized: "Hermes did not take the answer. Approve it in the Hermes app.")
    static let unknownNote = String(localized: "The answer may not have reached Hermes.")

    /// The 3 s note of the island after an answer.
    static func outcomeNote(choice: Choice, outcome: AnswerOutcome) -> String {
        switch outcome {
        case .applied: return answerNote(choice)
        case .tooLate: return tooLateNote
        case .failed: return failedNote
        case .unknown: return unknownNote
        }
    }

    /// The row the chat keeps after an answer: one sentence, never the command.
    static func chatNote(choice: Choice, outcome: AnswerOutcome) -> String {
        switch outcome {
        case .applied:
            switch choice {
            case .once: return String(localized: "(Approval asked: allowed once.)")
            case .session: return String(localized: "(Approval asked: allowed for the session.)")
            case .always: return String(localized: "(Approval asked: always allowed.)")
            case .deny: return String(localized: "(Approval asked: denied.)")
            }
        case .tooLate: return String(localized: "(Approval asked: not answered in time.)")
        case .failed: return String(localized: "(Approval asked: Hermes did not take the answer.)")
        case .unknown: return String(localized: "(Approval asked: the answer may not have reached Hermes.)")
        }
    }

    static func chatNote(withdrawn reason: WithdrawReason) -> String {
        switch reason {
        case .timeout: return String(localized: "(Approval asked: Hermes stopped waiting.)")
        case .resolved: return String(localized: "(Approval asked: answered somewhere else.)")
        case .socketLost: return String(localized: "(Approval asked: the connection was lost.)")
        default: return String(localized: "(Approval asked: withdrawn.)")
        }
    }

    // MARK: Wire: sign in

    static func capabilitiesParams() -> [String: Any] { ["server_requests": true] }

    static func pendingParams(session: String) -> [String: Any] { ["session_id": session] }

    static func receivedParams(_ r: HermesApprovalRequest) -> [String: String]? {
        guard case .signIn(_, let session) = r.origin else { return nil }
        return ["session_id": session, "request_id": r.requestID]
    }

    /// `approval.respond`: the session, the exact request id and the choice. Never `all`, never without an id.
    static func respondParams(_ r: HermesApprovalRequest, _ choice: Choice) -> [String: String]? {
        guard case .signIn(_, let session) = r.origin, r.offered.contains(choice) else { return nil }
        return ["session_id": session, "request_id": r.requestID, "choice": choice.rawValue]
    }

    private static func result(_ text: String, id: Int) -> [String: Any]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let n = obj["id"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.intValue == id,
              obj["method"] == nil, let r = obj["result"] as? [String: Any] else { return nil }
        return r
    }

    /// The `server_requests` list of the `client.capabilities` answer.
    static func parseCapabilities(_ text: String, id: Int) -> [String]? {
        guard let r = result(text, id: id), let list = r["server_requests"] as? [Any] else { return nil }
        return list.compactMap { $0 as? String }
    }

    /// The number the server resolved (`approval.respond`). A boolean counts as 1 (true) or 0 (false): the server may say
    /// "resolved: true" for an answer it applied.
    static func parseResolved(_ text: String, id: Int) -> Int? {
        guard let r = result(text, id: id) else { return nil }
        return resolvedCount(r["resolved"])
    }

    private static func resolvedCount(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber else { return nil }
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? 1 : 0 }
        let d = n.doubleValue
        guard d.isFinite, d >= 0, d <= 1_000_000, d == d.rounded() else { return nil }
        return n.intValue
    }

    /// The request ids `approval.pending` lists. nil (do nothing) when the list is not a list or any entry has no valid
    /// request id: a shape the app does not know must never read as "nothing is pending" and withdraw every card.
    static func parsePendingIDs(_ text: String, id: Int) -> Set<String>? {
        guard let r = result(text, id: id), let list = r["approvals"] as? [Any] else { return nil }
        var out = Set<String>()
        for item in list {
            guard let d = item as? [String: Any], let rid = d["request_id"] as? String, isRequestID(rid) else { return nil }
            out.insert(rid)
        }
        return out
    }

    static func reason(fromServer s: String) -> WithdrawReason {
        switch s {
        case "timeout": return .timeout
        case "resolved": return .resolved
        case "interrupted", "interrupt", "shutdown": return .interrupted
        case "session_closed": return .sessionClosed
        default: return .other
        }
    }

    private static func event(_ text: String, type: String) -> [String: Any]? {
        guard text.utf8.count <= maxPayloadBytes,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              (obj["method"] as? String) == "event", let p = obj["params"] as? [String: Any],
              (p["type"] as? String) == type else { return nil }
        return (p["payload"] as? [String: Any]) ?? [:]
    }

    /// `request.cancel` for an `approval` request: the id of the frame that is withdrawn.
    static func parseCancel(_ text: String) -> (frameID: String, reason: WithdrawReason)? {
        guard let p = event(text, type: "request.cancel"), (p["method"] as? String) == "approval",
              let id = p["id"] as? String, isFrameID(id) else { return nil }
        return (id, reason(fromServer: (p["reason"] as? String) ?? ""))
    }

    /// The `approval.cancelled` broadcast: request ids dropped by an interrupt or a teardown.
    static func parseCancelled(_ text: String) -> (ids: [String], reason: WithdrawReason)? {
        guard let p = event(text, type: "approval.cancelled"), let list = p["request_ids"] as? [Any] else { return nil }
        let ids = list.compactMap { $0 as? String }.filter(isRequestID)
        return (ids, reason(fromServer: (p["reason"] as? String) ?? "interrupt"))
    }

    static func interpretRespond(resolved: Int?) -> AnswerOutcome {
        guard let n = resolved else { return .failed }
        return n >= 1 ? .applied : .tooLate
    }

    // MARK: Wire: API key

    /// `POST <root>/v1/runs/<run id>/approval` with the same bearer key. 10 s, never retried by the caller.
    static func answerRequest(apiRoot: String, key: String, request r: HermesApprovalRequest, choice: Choice) -> URLRequest? {
        guard case .apiKey(let run) = r.origin, isRunID(run), isRequestID(r.requestID), r.offered.contains(choice),
              let url = URL(string: apiRoot + "/v1/runs/" + run + "/approval") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["choice": choice.rawValue, "request_id": r.requestID],
                                                   options: [.sortedKeys])
        return req
    }

    static func parseHTTPResolved(_ body: Data) -> Int? {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return resolvedCount(obj["resolved"])
    }

    static func interpretHTTP(status: Int, resolved: Int?) -> AnswerOutcome {
        switch status {
        case 200:
            guard let n = resolved else { return .failed }
            return n >= 1 ? .applied : .tooLate
        case 409: return .tooLate
        default: return .failed
        }
    }
}

// MARK: - The queue

/// The Hermes requests that wait for the card slot, in arrival order, and what is on screen. A value type with no
/// timers and no I/O: time and the slot are the caller's. Nothing in it sends an answer; `click` returns one only
/// for the request that is on screen, a choice the server offered, and a text that was shown as far as it must be.
struct HermesApprovalQueue {
    static let maxEntries = 8

    enum Phase: Equatable, Sendable { case queued, shown, answering }

    struct Entry: Equatable, Sendable {
        var request: HermesApprovalRequest
        var display: HermesApprovalDisplay
        /// The turn (or stream) that owns it: its end withdraws the request.
        var turn: Int
        var phase: Phase = .queued
        var soundPlayed = false
        var reachedEnd = false
    }

    enum AddResult: Equatable { case queued, duplicate, full, agentFull }

    struct Promotion: Equatable {
        var request: HermesApprovalRequest
        var display: HermesApprovalDisplay
        var playSound: Bool
    }

    enum ClickResult: Equatable {
        case send(HermesApprovalRequest, HermesApproval.Choice)
        case dropped
    }

    enum WithdrawEffect: Equatable {
        case none
        case droppedQueued
        case endedShown(HermesApprovalRequest)
    }

    struct Withdrawal: Equatable {
        var endedShown: HermesApprovalRequest?
        var dropped = 0
        /// Every request id that left the queue (the shown one included).
        var ids: [String] = []
    }

    private(set) var entries: [Entry] = []
    /// The allowing scope selected on the shown card. Back to once for every card that appears.
    private(set) var scope: HermesApproval.Scope = .once

    var shownID: String? { entries.first { $0.phase == .shown }?.request.requestID }
    var shown: Entry? { entries.first { $0.phase == .shown } }
    /// Waiting for the slot or on it: what the demo and the "a card is pending" rules look at.
    var hasWaiting: Bool { entries.contains { $0.phase != .answering } }
    var waitingBehind: Int { entries.filter { $0.phase == .queued }.count }

    mutating func add(_ request: HermesApprovalRequest, display: HermesApprovalDisplay, turn: Int) -> AddResult {
        if entries.contains(where: { $0.request.requestID == request.requestID }) { return .duplicate }
        if entries.count >= Self.maxEntries { return .full }
        if entries.filter({ $0.request.agentName == request.agentName }).count >= HermesApproval.maxPerAgent { return .agentFull }
        entries.append(Entry(request: request, display: display, turn: turn))
        return .queued
    }

    /// Puts the next queued request on screen, when none is. The selector goes back to once.
    mutating func promoteNext() -> Promotion? {
        guard shownID == nil, let i = entries.firstIndex(where: { $0.phase == .queued }) else { return nil }
        entries[i].phase = .shown
        entries[i].reachedEnd = false
        scope = .once
        let play = !entries[i].soundPlayed
        entries[i].soundPlayed = true
        return Promotion(request: entries[i].request, display: entries[i].display, playSound: play)
    }

    /// Another card took the slot: the shown request waits again, at the head of the line.
    mutating func requeueShown() {
        guard let i = entries.firstIndex(where: { $0.phase == .shown }) else { return }
        entries[i].phase = .queued
        entries[i].reachedEnd = false
        scope = .once
    }

    mutating func select(_ s: HermesApproval.Scope) {
        guard let e = shown, e.request.offered.contains(s.choice) else { return }
        scope = s
    }

    /// The end of the text was on screen (reading view). Only for the shown request.
    mutating func markReachedEnd(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.phase == .shown && $0.request.requestID == id }) else { return }
        entries[i].reachedEnd = true
    }

    /// An explicit click on a button of the shown card. The id is the one the card was built for.
    mutating func click(_ choice: HermesApproval.Choice, id: String) -> ClickResult {
        guard let i = entries.firstIndex(where: { $0.phase == .shown && $0.request.requestID == id }) else { return .dropped }
        let e = entries[i]
        guard e.request.offered.contains(choice),
              HermesApproval.mayAnswer(choice, display: e.display, reachedEnd: e.reachedEnd) else { return .dropped }
        entries[i].phase = .answering
        scope = .once
        return .send(e.request, choice)
    }

    /// The answer came back (or could not): the request is done.
    mutating func finish(_ id: String) {
        entries.removeAll { $0.request.requestID == id && $0.phase == .answering }
    }

    mutating func withdraw(_ id: String) -> WithdrawEffect {
        guard let i = entries.firstIndex(where: { $0.request.requestID == id }) else { return .none }
        switch entries[i].phase {
        case .queued:
            entries.remove(at: i)
            return .droppedQueued
        case .shown:
            let r = entries[i].request
            entries.remove(at: i)
            scope = .once
            return .endedShown(r)
        case .answering:
            return .none   // the answer in flight reports its own outcome
        }
    }

    private mutating func withdrawWhere(_ match: (Entry) -> Bool) -> Withdrawal {
        var w = Withdrawal()
        var keep: [Entry] = []
        for e in entries {
            if match(e), e.phase != .answering {
                w.ids.append(e.request.requestID)
                if e.phase == .shown { w.endedShown = e.request; scope = .once } else { w.dropped += 1 }
            } else {
                keep.append(e)
            }
        }
        entries = keep
        return w
    }

    mutating func withdrawAll(turn: Int) -> Withdrawal {
        withdrawWhere { $0.turn == turn }
    }

    mutating func withdrawAll(agent: String) -> Withdrawal {
        withdrawWhere { $0.request.agentName == agent }
    }

    /// `approval.pending` listed `ids`: what this turn knew before the question and the server no longer lists is gone.
    mutating func retain(ids: Set<String>, knownBefore: Set<String>, turn: Int) -> Withdrawal {
        withdrawWhere { $0.turn == turn && knownBefore.contains($0.request.requestID) && !ids.contains($0.request.requestID) }
    }
}


// MARK: - What a running turn reports to the app

/// The answer the card sends back to the turn that asked: it returns once the server said what happened. It is
/// called only after a click, by the app, for the request on screen.
typealias HermesApprovalAnswer = @Sendable (HermesApproval.Choice) async -> HermesApproval.AnswerOutcome

/// The callbacks of one turn or stream. The default takes nothing: every request stays with Hermes and the chat
/// keeps its one sentence.
struct HermesApprovalHooks: Sendable {
    /// A request was parsed. True when the app took it: it will show a card and answer only after a click.
    var offer: @MainActor @Sendable (HermesApprovalRequest, Int, @escaping HermesApprovalAnswer) -> Bool
    /// The server withdrew a request (or the turn lost it).
    var withdrawn: @MainActor @Sendable (String, HermesApproval.WithdrawReason) -> Void
    /// `approval.pending` listed these ids; of the ones known before the question, the rest is gone.
    var retain: @MainActor @Sendable (Set<String>, Set<String>, Int) -> Void
    /// The turn ended (or its socket was lost): every request of that turn goes.
    var turnEnded: @MainActor @Sendable (Int, HermesApproval.WithdrawReason) -> Void

    static let none = HermesApprovalHooks(offer: { _, _, _ in false }, withdrawn: { _, _ in }, retain: { _, _, _ in }, turnEnded: { _, _ in })
}

/// One answer on its way: settled exactly once, whatever happens to the connection.
final class HermesAnswerWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: HermesApproval.AnswerOutcome?
    private var continuation: CheckedContinuation<HermesApproval.AnswerOutcome, Never>?

    func settle(_ o: HermesApproval.AnswerOutcome) {
        let c = lock.withLock { () -> CheckedContinuation<HermesApproval.AnswerOutcome, Never>? in
            guard outcome == nil else { return nil }
            outcome = o
            let c = continuation
            continuation = nil
            return c
        }
        c?.resume(returning: o)
    }

    func wait() async -> HermesApproval.AnswerOutcome {
        await withCheckedContinuation { (c: CheckedContinuation<HermesApproval.AnswerOutcome, Never>) in
            let done = lock.withLock { () -> HermesApproval.AnswerOutcome? in
                if let outcome { return outcome }
                continuation = c
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }
}

/// A click that asks for an answer to leave: the request, the choice, and where the outcome goes.
struct HermesAnswerCommand: Sendable {
    let request: HermesApprovalRequest
    let choice: HermesApproval.Choice
    let waiter: HermesAnswerWaiter
}
