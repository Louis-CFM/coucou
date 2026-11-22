import Foundation

// MARK: - Botan link: what the little screen shows, and what its button may decide
//
// Botan is a small screen with one button that sits next to the Mac (docs/BOTAN_LINK.md). It shows
// one thing at a time, as a single line of text it understands:
//
//     #token state|label|title|detail        (token: only on approvals and questions)
//
// This file is pure: the island's picture in, the line out, and the button's events checked against
// the request still waiting. It is shared: the Mac links Botan directly (BotanLinkService), the iPhone
// links it through iCloud (BotanBridge), and both go by the same rules.
//
// The rules that matter:
//   * one screen at a time, the most urgent first: a permission request, then a question, then an
//     error, a session at work, a session that just finished, and Mochi resting when nothing runs;
//   * a decision from the button carries the token of the screen it was pressed on, and is applied
//     only if that token is the one of the request *still* pending: a press on an old screen never
//     answers a newer request;
//   * Botan can approve or pick an answer, never deny or type: anything else stays on the Mac's card,
//     which keeps working all along.

/// One agent session, as the island has it.
struct BotanSessionIn: Equatable, Sendable {
    var pillId: String
    var agent: String          // "Claude Code", "Codex"…
    var state: String          // BotState raw value
    var statusText: String = ""
    var finalLine: String? = nil
    var project: String? = nil // the folder the session runs in
    var isWorkflow: Bool = false
}

/// The permission request on the island's card.
struct BotanApprovalIn: Equatable, Sendable {
    var requestId: String
    var agent: String
    var project: String
    var tool: String
    var command: String
}

/// The question Claude Code is waiting on: Botan takes it only when it is one question with
/// 2 to 4 short choices, one to pick.
struct BotanQuestionIn: Equatable, Sendable {
    var requestId: String
    var agent: String
    var project: String
    var question: String
    var options: [String]
    var multiSelect: Bool = false
    /// How many questions Claude Code asks at once (Botan shows one).
    var count: Int = 1
}

/// What the screen shows: the line, and the request a press would answer.
struct BotanScreen: Equatable, Sendable {
    enum Request: Equatable, Sendable {
        case approval(requestId: String)
        case question(requestId: String, options: [String])
    }
    var line: String
    var token: String?
    var request: Request?
}

/// What a button event asks for, once checked.
enum BotanDecision: Equatable, Sendable {
    case allow(requestId: String)
    case answer(requestId: String, label: String)
    /// Nothing to do: a press with nothing waiting, an old screen, or something Botan may not decide.
    case ignore(String)
}

enum BotanLinkScreen {
    /// The firmware's field sizes, in bytes (ui.h: label 48, title 96, detail 128, a choice 40).
    static let maxLabel = 47, maxTitle = 95, maxDetail = 127, maxChoice = 39
    /// A question Botan shows whole: 2 to 4 choices that fit, one to pick.
    static func fits(_ q: BotanQuestionIn) -> Bool {
        guard q.count == 1, !q.multiSelect, (2...4).contains(q.options.count) else { return false }
        return q.options.allSatisfy { label in
            let clean = field(label, maxChoice)
            return !clean.isEmpty && clean == label && !label.contains(";")
        }
    }

    /// The screen for the island's current picture.
    static func screen(sessions: [BotanSessionIn], approval: BotanApprovalIn?, question: BotanQuestionIn?) -> BotanScreen {
        if let a = approval, !a.requestId.isEmpty {
            let t = token(a.requestId)
            let line = "#\(t) " + compose("approval", label(a.agent, a.project), approvalTitle(tool: a.tool, command: a.command), a.tool)
            return BotanScreen(line: line, token: t, request: .approval(requestId: a.requestId))
        }
        if let q = question, !q.requestId.isEmpty, fits(q) {
            let t = token(q.requestId)
            let line = "#\(t) " + compose("question", label(q.agent, q.project), q.question, q.options.joined(separator: ";"))
            return BotanScreen(line: line, token: t, request: .question(requestId: q.requestId, options: q.options))
        }
        if let s = pick(sessions) {
            return BotanScreen(line: sessionLine(s), token: nil, request: nil)
        }
        return BotanScreen(line: compose("idle", "BOTAN", "Mochi is here.", "Nothing running on your Mac."), token: nil, request: nil)
    }

    /// Botan's heartbeat ("tick", every few seconds while linked): it decides nothing, it only wakes
    /// a locked iPhone up so it can look for news.
    static func isTick(_ event: String) -> Bool {
        event.trimmingCharacters(in: .whitespacesAndNewlines) == "tick"
    }

    /// A button event ("approve|#token", "choose|1|Alloy|#token", "press"), checked against the screen.
    static func decision(for event: String, screen: BotanScreen?) -> BotanDecision {
        var parts = event.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        var sent: String?
        if let last = parts.last, last.hasPrefix("#") {
            sent = String(last.dropFirst())
            parts.removeLast()
        }
        guard let kind = parts.first else { return .ignore("empty") }
        guard kind == "approve" || kind == "choose" else { return .ignore("not a decision") }
        guard let screen, let request = screen.request, let token = screen.token else { return .ignore("nothing waiting") }
        guard let sent, sent == token else { return .ignore("pressed on another screen") }
        switch (kind, request) {
        case ("approve", .approval(let id)):
            return .allow(requestId: id)
        case ("choose", .question(let id, let options)):
            guard parts.count >= 3, let i = Int(parts[1]), options.indices.contains(i) else { return .ignore("no such choice") }
            // The label must be the one Botan was given for that place.
            let label = parts[2...].joined(separator: "|")
            guard label == options[i] else { return .ignore("choice changed") }
            return .answer(requestId: id, label: options[i])
        default:
            return .ignore("not what is waiting")
        }
    }

    // MARK: Pieces

    /// The session to show: something broke first, then work in progress, then work just done.
    static func pick(_ sessions: [BotanSessionIn]) -> BotanSessionIn? {
        let order: [String: Int] = [
            "error": 0, "dizzy": 0, "ratelimit": 1,
            "working": 2, "thinking": 2, "searching": 2,
            "finished": 3,
        ]
        return sessions
            .enumerated()
            .compactMap { i, s in order[s.state].map { (rank: $0, index: i, session: s) } }
            .min { ($0.rank, $0.index) < ($1.rank, $1.index) }?
            .session
    }

    static func sessionLine(_ s: BotanSessionIn) -> String {
        let lbl = label(s.agent, s.project)
        let status = oneLine(s.statusText)
        let where_ = s.isWorkflow ? "" : projectName(s.project)
        switch s.state {
        case "error", "dizzy":
            return compose("error", lbl, status.isEmpty ? "Something went wrong" : status, where_)
        case "ratelimit":
            return compose("error", lbl, "Rate limited", status)
        case "thinking":
            return compose("thinking", lbl, status.isEmpty ? "Thinking" : status, where_)
        case "working", "searching":
            return compose("working", lbl, status.isEmpty ? "Working" : status, where_)
        case "finished":
            let done = oneLine(s.finalLine ?? "")
            return compose("finished", lbl, done.isEmpty ? (status.isEmpty ? "Done." : status) : done, where_)
        default:
            return compose("idle", lbl, "Mochi is here.", where_)
        }
    }

    /// "Run npm run build?" for a shell command, "Edit Button.swift" for the rest.
    static func approvalTitle(tool: String, command: String) -> String {
        let cmd = oneLine(command)
        if tool == "Bash" || tool == "Shell" { return cmd.isEmpty ? "Run a command?" : "Run \(cmd)?" }
        if cmd.isEmpty { return "\(tool)?" }
        // A file path: its name is what a person reads.
        let name = cmd.hasPrefix("/") ? (cmd as NSString).lastPathComponent : cmd
        return "\(tool) \(name)?"
    }

    /// "CLAUDE CODE · BOTAN": the agent and the project, in capitals, as the firmware's label.
    static func label(_ agent: String, _ project: String?) -> String {
        let a = oneLine(agent).uppercased()
        let p = projectName(project).uppercased()
        if a.isEmpty { return p.isEmpty ? "BOTAN" : p }
        return p.isEmpty ? a : "\(a) · \(p)"
    }

    static func projectName(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return oneLine((trimmed as NSString).lastPathComponent)
    }

    /// The short token a press must carry: the start of the request id, letters and digits only.
    static func token(_ requestId: String) -> String {
        String(requestId.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
    }

    static func compose(_ state: String, _ label: String, _ title: String, _ detail: String) -> String {
        "\(state)|\(field(label, maxLabel))|\(field(title, maxTitle))|\(field(detail, maxDetail))"
    }

    /// One field of the line: on one line, without the separator, cut to the firmware's size on a
    /// character boundary (with "…" when cut).
    static func field(_ text: String, _ maxBytes: Int) -> String {
        let clean = oneLine(text).replacingOccurrences(of: "|", with: "/")
        if clean.utf8.count <= maxBytes { return clean }
        var out = ""
        let ellipsis = "…"
        for ch in clean {
            if out.utf8.count + String(ch).utf8.count + ellipsis.utf8.count > maxBytes { break }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces) + ellipsis
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
