import Foundation

// MARK: - Sessions of an external agent pill

/// One session seen on an external agent pill (e.g. Claude Desktop), so the card can list
/// every session with its status instead of only the last event received.
struct AgentSessionRow: Identifiable, Equatable {
    enum Status: String {
        case started, thinking, working, waiting, finished, error
    }
    let id: String          // session_id
    var project: String
    var title: String       // session title when the host sends one (e.g. Claude Desktop), else ""
    var status: Status
    var line: String
    var updated: Date
}

/// Pure reducer over a pill's session list — no UI, no AppState — so it can be unit-tested.
enum AgentSessions {
    static let maxAge: TimeInterval = 6 * 3600
    static let maxRows = 12
    static let maxLine = 120

    /// Applies one hook event and returns the new list, newest first.
    /// `line` is what to show for the session (prompt, step, final message); nil keeps the previous one.
    static func apply(_ rows: [AgentSessionRow], event: String, sessionId: String,
                      project: String, title: String? = nil, line: String?,
                      notificationType: String? = nil, now: Date) -> [AgentSessionRow] {
        // Injected prompts (<task-notification>, <agent-message>, <system-reminder>…) are not what the user typed.
        let line = line.flatMap { $0.hasPrefix("<") ? nil : String($0.prefix(maxLine)) }
        var rows = rows.filter { now.timeIntervalSince($0.updated) <= maxAge }
        guard !sessionId.isEmpty, sessionId != "unknown" else { return sorted(rows) }
        if event == "SessionEnd" {
            rows.removeAll { $0.id == sessionId }
            return sorted(rows)
        }
        let status: AgentSessionRow.Status?
        switch event {
        case "SessionStart":                 status = .started
        case "UserPromptSubmit":             status = .thinking
        case "PreToolUse", "PostToolUse",
             "SubagentStart", "SubagentStop": status = .working
        case "Notification":
            // Claude Code tags permission/idle prompts; other agents only send text, where a trailing "?"
            // is the best signal that the session waits on the user.
            if let t = notificationType, !t.isEmpty {
                status = (t == "permission_prompt" || t == "idle_prompt" || t == "elicitation_dialog") ? .waiting : nil
            } else {
                status = (line ?? "").hasSuffix("?") ? .waiting : nil
            }
        case "Stop":                         status = .finished
        case "StopFailure":                  status = .error
        default:                             status = nil
        }
        if let i = rows.firstIndex(where: { $0.id == sessionId }) {
            if let s = status { rows[i].status = s }
            if let l = line, !l.isEmpty { rows[i].line = l }
            if !project.isEmpty { rows[i].project = project }
            if let t = title, !t.isEmpty { rows[i].title = t }
            rows[i].updated = now
        } else if let s = status {
            rows.append(AgentSessionRow(id: sessionId, project: project, title: title ?? "", status: s,
                                        line: line ?? "", updated: now))
        }
        return Array(sorted(rows).prefix(maxRows))
    }

    /// Rows still worth showing at `now` (the reducer only prunes when an event arrives).
    static func visible(_ rows: [AgentSessionRow], now: Date) -> [AgentSessionRow] {
        rows.filter { now.timeIntervalSince($0.updated) <= maxAge }
    }

    /// "now", "5m", "2h", "3d".
    static func ago(_ date: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    private static func sorted(_ rows: [AgentSessionRow]) -> [AgentSessionRow] {
        rows.sorted { $0.updated > $1.updated }
    }
}
