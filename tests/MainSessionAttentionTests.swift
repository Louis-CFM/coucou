import Foundation

@main
enum MainSessionAttentionTests {
    static func main() {
        let now: TimeInterval = 100
        let session = "01a14345-b5dc-7ed3-855a-c7d8e5e3115f"
        func request(_ id: String, sessionId: String = session) -> [String: Any] {
            ["source": "codex", "id": id, "session_id": sessionId, "title": "Human chat", "reason": "Choose one?", "kind": "question"]
        }
        func snapshot(_ items: [[String: Any]], expires: TimeInterval = 125) -> [String: Any] {
            ["action": "snapshot", "expires_at": expires, "requests": items]
        }
        var queue = MainSessionAttentionQueue()
        assert(queue.replace(payload: snapshot([request("one")]), now: now))
        assert(!queue.replace(payload: snapshot([request("one"), request("one")]), now: now + 1))
        assert(queue.visible.count == 1)
        assert(queue.visible.first?.chatURL?.absoluteString == "codex://threads/\(session)")
        assert(queue.replace(payload: snapshot([request("two"), request("one")]), now: now + 2))
        assert(queue.visible.map(\.requestId) == ["one", "two"])
        let dismissed = queue.visible[0].id
        queue.dismiss(id: dismissed)
        assert(queue.visible.map(\.requestId) == ["two"])
        assert(!queue.replace(payload: snapshot([request("one"), request("two")]), now: now + 3))
        assert(queue.visible.map(\.requestId) == ["two"])
        _ = queue.replace(payload: snapshot([]), now: now + 4)
        assert(!queue.replace(payload: snapshot([request("one")]), now: now + 5))
        assert(queue.visible.isEmpty) // a transient read failure cannot revive a dismissed request
        assert(queue.replace(payload: snapshot([request("one", sessionId: UUID().uuidString)]), now: now + 6))
        assert(queue.visible.count == 1)
        queue.expire(now: 126)
        assert(queue.visible.isEmpty)
        assert(!queue.replace(payload: snapshot([request("late")], expires: 99), now: now))
        assert(!queue.replace(payload: snapshot([request("too-long")], expires: 9999), now: now))
        assert(!queue.replace(payload: snapshot([request("invalid", sessionId: "x/?url=bad")]), now: now))
        let open: [String: Any] = ["source": "opencode", "id": "per_A", "session_id": "ses_A", "title": "Main", "reason": "npm test", "kind": "permission"]
        assert(queue.replace(payload: snapshot([open]), now: now))
        assert(queue.visible.first?.chatURL == nil)
        assert(queue.visible.first?.bundleId == "ai.opencode.desktop")
        // The attention route is a thread-safe mirror of the opt-in state: it must
        // default to disabled, and toggling it must be visible to socket threads.
        assert(MainSessionAttentionRoute.isEnabled == false, "native attention must default to disabled")
        MainSessionAttentionRoute.setEnabled(true)
        assert(MainSessionAttentionRoute.isEnabled == true)
        MainSessionAttentionRoute.setEnabled(false)
        assert(MainSessionAttentionRoute.isEnabled == false)
        // Controller snapshot policy, not just the mirror switch: disabled
        // ignores snapshots; only the feature or the isolated smoke test accepts.
        assert(!MainSessionAttentionPolicy.acceptsSnapshots(featureEnabled: false, smokeSynthetic: false),
               "disabled must ignore snapshots")
        assert(MainSessionAttentionPolicy.acceptsSnapshots(featureEnabled: true, smokeSynthetic: false))
        #if DEBUG
        assert(MainSessionAttentionPolicy.acceptsSnapshots(featureEnabled: false, smokeSynthetic: true),
               "the isolated smoke test accepts synthetic snapshots")
        #endif
        print("Attention queue: all lifecycle, isolation, safe-navigation and disabled-default assertions passed")
    }
}
