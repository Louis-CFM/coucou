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
}

struct ApprovalQueue: Sendable {
    /// Upper bound of simultaneously pending requests. Each one holds a socket and a 115 s timer
    /// and the card only shows one at a time, so beyond this the newest falls back to its terminal.
    static let maxPending = 5

    enum EnqueueResult: Equatable, Sendable { case accepted, rejectedFull }

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
