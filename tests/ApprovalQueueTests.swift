import Foundation

@main
enum ApprovalQueueTests {
    static func entry(_ n: Int, session: String = "s1", pill: String = "integration_claude",
                      tool: String = "Bash", key: String = "{}") -> QueuedApproval {
        QueuedApproval(id: UUID(), fd: Int32(n), sessionId: session, pillId: pill,
                       projectName: "p", cwd: "/", tool: tool, command: "cmd\(n)", inputKey: key)
    }

    static func main() {
        // FIFO: head is the oldest, removal of the head promotes the next
        var q = ApprovalQueue()
        let a = entry(1), b = entry(2), c = entry(3)
        for e in [a, b, c] { precondition(q.enqueue(e) == .accepted) }
        precondition(q.count == 3 && q.head == a)
        precondition(q.position(of: a.id) == 1 && q.position(of: c.id) == 3)
        precondition(q.remove(id: a.id) == a)
        precondition(q.head == b && q.count == 2)

        // Removal on disconnect / timeout of a non-head entry leaves the others untouched
        precondition(q.remove(id: c.id) == c)
        precondition(q.head == b && q.count == 1)
        precondition(q.remove(id: c.id) == nil)   // already gone: no-op
        precondition(q.remove(id: b.id) == b && q.isEmpty && q.head == nil)

        // Cap: the newest is rejected, queue unchanged
        var full = ApprovalQueue()
        let all = (1...ApprovalQueue.maxPending).map { entry($0) }
        for e in all { precondition(full.enqueue(e) == .accepted) }
        precondition(full.enqueue(entry(99)) == .rejectedFull)
        precondition(full.entries == all)
        // Room again after a removal
        _ = full.remove(id: all[0].id)
        precondition(full.enqueue(entry(97), maxPending: ApprovalQueue.maxPending) == .accepted)

        // Event matching is per request: session + agent, never the pill alone
        var m = ApprovalQueue()
        let s1 = entry(1, session: "s1", tool: "Bash", key: "{\"command\":\"ls\"}")
        let s2 = entry(2, session: "s2", tool: "Bash", key: "{\"command\":\"ls\"}")
        let cur = entry(3, session: "s1", pill: "agent_cursor", tool: "Bash", key: "{\"command\":\"ls\"}")
        for e in [s1, s2, cur] { _ = m.enqueue(e) }
        let pt = m.resolved(byEvent: "PostToolUse", sessionId: "s1", pillId: "integration_claude",
                            tool: "Bash", inputKey: "{\"command\":\"ls\"}")
        precondition(pt == [s1])
        precondition(m.resolved(byEvent: "PostToolUse", sessionId: "s1", pillId: "integration_claude",
                                tool: "Bash", inputKey: "{\"command\":\"pwd\"}").isEmpty)
        precondition(m.resolved(byEvent: "PostToolUse", sessionId: "s1", pillId: "integration_claude",
                                tool: "Read", inputKey: "{\"command\":\"ls\"}").isEmpty)
        precondition(m.resolved(byEvent: "Stop", sessionId: "s2", pillId: "integration_claude",
                                tool: "", inputKey: "") == [s2])
        precondition(m.resolved(byEvent: "Stop", sessionId: "s1", pillId: "agent_cursor",
                                tool: "", inputKey: "") == [cur])
        precondition(m.resolved(byEvent: "Stop", sessionId: "other", pillId: "integration_claude",
                                tool: "", inputKey: "").isEmpty)
        precondition(m.resolved(byEvent: "PreToolUse", sessionId: "s1", pillId: "integration_claude",
                                tool: "Bash", inputKey: "{\"command\":\"ls\"}").isEmpty)

        // Mixed sources and per-pill lookup
        precondition(m.hasMixedSources)
        precondition(m.hasEntries(forPill: "agent_cursor") && !m.hasEntries(forPill: "agent_codex"))
        var same = ApprovalQueue()
        _ = same.enqueue(entry(1)); _ = same.enqueue(entry(2, tool: "Edit"))
        precondition(!same.hasMixedSources)

        print("pass")
    }
}
