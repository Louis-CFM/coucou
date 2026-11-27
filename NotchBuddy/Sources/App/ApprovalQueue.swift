import Foundation

// MARK: - ApprovalQueue
// Pure FIFO queue of pending PermissionRequests. No AppKit, no SwiftUI, no I/O:
// HookServer owns the sockets, timers and UI, and mutates this value on the main actor only.
// The head is the request currently shown on the approval card.

struct QueuedApproval: Equatable, Sendable {
    let id: UUID
    /// Client socket, held open until the user decides. Closed by the owner's dispatch source.
    let fd: Int32
    let sessionId: String
    /// "integration_claude", "agent_cursor" or "agent_codex".
    let pillId: String
    let projectName: String
    let cwd: String
    let tool: String
    let command: String
    /// tool_input serialized with sortedKeys, "" if absent. Used to match PostToolUse.
    let inputKey: String
    /// Host app / bundle id of the session, so the card's pill keeps showing where it runs.
    var hostApp: String? = nil
    var bundleId: String = ""
    /// When the request arrived (for the log: how long it waited).
    var received = Date()
    /// The pill the request shows on when its session popped out of `pillId` (SessionBoard),
    /// nil when it shows on `pillId` itself.
    var shownPill: String? = nil
    /// MCP tool approvals only: an Allow counts when clicked strictly before this.
    var deadline: Date? = nil

    /// Where the card, the focus and the iPhone find the request.
    var displayPill: String { shownPill ?? pillId }

    /// The pill and session every MCP tool approval of the chat shows on.
    static let mcpPill = "agent_mcp"
    static let mcpSession = "mcp"

    /// A request from Coucou's own chat to run a tool of an MCP server that changes things.
    /// Nothing waits on a socket for it (fd -1): HookServer resumes the chat instead.
    var isMCP: Bool { fd < 0 && pillId == Self.mcpPill }

    static func mcp(tool: String, command: String, inputKey: String, deadline: Date) -> QueuedApproval {
        QueuedApproval(id: UUID(), fd: -1, sessionId: mcpSession, pillId: mcpPill,
                       projectName: "MCP tools", cwd: "", tool: tool, command: command,
                       inputKey: inputKey, deadline: deadline)
    }
}

struct ApprovalQueue: Sendable {
    /// Upper bound of simultaneously pending requests. Each one holds a socket and a 115 s timer
    /// and the card only shows one at a time, so beyond this the newest falls back to its terminal.
    static let maxPending = 5

    enum EnqueueResult: Equatable, Sendable { case accepted, rejectedFull }

    /// Fail closed, for MCP tool approvals: only an Allow (or Always) clicked strictly
    /// before the request's deadline approves. Deny, Reply in terminal, a plan choice or a
    /// click at or after the deadline are all refusals.
    static func approves(decision: String, at click: Date, deadline: Date) -> Bool {
        (decision == "allow" || decision == "always") && click < deadline
    }

    private(set) var entries: [QueuedApproval] = []

    var head: QueuedApproval? { entries.first }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    func contains(id: UUID) -> Bool { entries.contains { $0.id == id } }

    /// 1-based position of the entry in the queue, nil if absent.
    func position(of id: UUID) -> Int? {
        entries.firstIndex { $0.id == id }.map { $0 + 1 }
    }

    /// True when the queued requests do not all come from the same session and agent.
    var hasMixedSources: Bool {
        guard let first = entries.first else { return false }
        return entries.contains { $0.sessionId != first.sessionId || $0.pillId != first.pillId }
    }

    func hasEntries(forPill pillId: String) -> Bool {
        entries.contains { $0.pillId == pillId }
    }

    mutating func enqueue(_ entry: QueuedApproval, maxPending: Int = ApprovalQueue.maxPending) -> EnqueueResult {
        guard entries.count < maxPending else { return .rejectedFull }
        entries.append(entry)
        return .accepted
    }

    /// Removes only the entry with this id. Other entries keep their order.
    @discardableResult
    mutating func remove(id: UUID) -> QueuedApproval? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: idx)
    }

    /// Entries made moot by a later hook event of the same agent. Matching is per request
    /// (session + agent, plus tool and input for PostToolUse), never by pill alone.
    func resolved(byEvent name: String, sessionId: String, pillId: String,
                  tool: String, inputKey: String) -> [QueuedApproval] {
        switch name {
        case "PostToolUse", "PostToolUseFailure":
            return entries.filter {
                $0.pillId == pillId && $0.sessionId == sessionId
                    && $0.tool == tool && $0.inputKey == inputKey
            }
        case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
            return entries.filter { $0.pillId == pillId && $0.sessionId == sessionId }
        default:
            return []
        }
    }
}
