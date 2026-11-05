import Foundation

@main
enum CmuxRoutingTests {

    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        // ── taskId ─────────────────────────────────────────────────────────────
        print("CmuxRouting.taskId")
        let uuid = "ABCDEF12-3456-7890-ABCD-EF1234567890"
        check("surface id → lowercased key",
              CmuxRouting.taskId(payload: ["cmux_surface_id": uuid, "session_id": "s1"])
                == "agent_cmux_abcdef12-3456-7890-abcd-ef1234567890")
        check("bundle id only → keyed by session",
              CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "session_id": "Sess-9"])
                == "agent_cmux_sess-9")
        check("bundle id match is case-insensitive",
              CmuxRouting.taskId(payload: ["bundle_id": "COM.CmuxTerm.App", "session_id": "x1"])
                == "agent_cmux_x1")
        check("neither → nil",
              CmuxRouting.taskId(payload: ["session_id": "s1", "bundle_id": "com.microsoft.VSCode"]) == nil)
        check("session unknown and no surface → nil",
              CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "session_id": "unknown"]) == nil)
        check("odd characters stripped",
              CmuxRouting.taskId(payload: ["cmux_surface_id": "A_b/c d$1"]) == "agent_cmux_abcd1")
        check("key capped at 36",
              CmuxRouting.taskId(payload: ["cmux_surface_id": String(repeating: "a", count: 80)])
                == "agent_cmux_" + String(repeating: "a", count: 36))
        check("conversation_id fallback",
              CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "conversation_id": "c7"])
                == "agent_cmux_c7")

        print("CmuxRouting.sessionKey")
        check("surface that sanitizes to empty → session id",
              CmuxRouting.sessionKey(surfaceId: "___///", sessionId: "Sess-1") == "sess-1")
        check("UNKNOWN upper case, no usable surface → nil",
              CmuxRouting.sessionKey(surfaceId: "", sessionId: "UNKNOWN") == nil)
        check("UNKNOWN upper case but surface usable → surface",
              CmuxRouting.sessionKey(surfaceId: "S1", sessionId: "UNKNOWN") == "s1")
        check("neither usable → nil",
              CmuxRouting.sessionKey(surfaceId: "@@", sessionId: "$$") == nil)

        // ── isCmuxTaskId ───────────────────────────────────────────────────────
        print("CmuxRouting.isCmuxTaskId")
        check("prefix → true", CmuxRouting.isCmuxTaskId("agent_cmux_abc"))
        check("agent_cmux (external agent) → false", !CmuxRouting.isCmuxTaskId("agent_cmux"))
        check("agent_codex → false", !CmuxRouting.isCmuxTaskId("agent_codex"))
        check("integration_claude → false", !CmuxRouting.isCmuxTaskId("integration_claude"))
        check("nil → false", !CmuxRouting.isCmuxTaskId(nil))

        // ── pillLabel ──────────────────────────────────────────────────────────
        print("CmuxRouting.pillLabel")
        check("name, role and tag cut to the name",
              CmuxRouting.pillLabel("Proteus (Swift Implementer) [names]") == "Proteus")
        check("bracket after space", CmuxRouting.pillLabel("Zeus [codex]") == "Zeus")
        check("plain title kept whole", CmuxRouting.pillLabel("cmux") == "cmux")
        check("title with spaces but no marker kept", CmuxRouting.pillLabel("Integração com cmux") == "Integração com cmux")
        check("no space before paren kept", CmuxRouting.pillLabel("coucou(feat)") == "coucou(feat)")
        check("marker at start kept whole", CmuxRouting.pillLabel(" (x)") == " (x)")
        check("empty and short", CmuxRouting.pillLabel("") == "" && CmuxRouting.pillLabel("a") == "a")
        check("multi word head", CmuxRouting.pillLabel("My project (x)") == "My project")

        // ── displayName ────────────────────────────────────────────────────────
        print("CmuxRouting.displayName")
        check("unique base unchanged",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_a", existing: []) == "api")
        check("second same base → 2",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_a", "api")]) == "api 2")
        check("same task keeps its name",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_a",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api")
        check("suffixed task keeps its suffix",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api 2")
        check("third → 3",
              CmuxRouting.displayName(base: "api", taskId: "agent_cmux_c",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api 3")

        check("base changed for an existing task → new base",
              CmuxRouting.displayName(base: "web", taskId: "agent_cmux_a",
                                      existing: [("agent_cmux_a", "api")]) == "web")
        check("base changed while a suffixed name was held → new base",
              CmuxRouting.displayName(base: "web", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "web")
        check("folder really named 'api 2' keeps its name",
              CmuxRouting.displayName(base: "api 2", taskId: "agent_cmux_b",
                                      existing: [("agent_cmux_b", "api 2")]) == "api 2")
        check("folder named 'api 2' next to a task already called 'api 2' → 'api 2 2'",
              CmuxRouting.displayName(base: "api 2", taskId: "agent_cmux_c",
                                      existing: [("agent_cmux_a", "api"), ("agent_cmux_b", "api 2")]) == "api 2 2")

        // ── registry ───────────────────────────────────────────────────────────
        print("CmuxRegistry")
        var reg = CmuxRegistry()
        reg.note(taskId: "t1", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/c.sock",
                 capability: "tok1", sessionId: "sess", now: 10)
        check("insert", reg.surface(for: "t1")?.surfaceId == "s" && reg.surface(for: "t1")?.capability == "tok1")
        reg.note(taskId: "t1", surfaceId: "", workspaceId: "", socketPath: "", capability: "",
                 sessionId: "", now: 20)
        check("empty fields do not erase",
              reg.surface(for: "t1")?.capability == "tok1" && reg.surface(for: "t1")?.workspaceId == "w"
              && reg.surface(for: "t1")?.sessionId == "sess")
        check("lastSeen advances", reg.surface(for: "t1")?.lastSeen == 20)
        let rotated = reg.note(taskId: "t1", surfaceId: "s2", workspaceId: "w2", socketPath: "/tmp/c.sock",
                               capability: "tok2", sessionId: "", now: 30)
        check("new capability on the same socket replaces the whole unit",
              rotated && reg.surface(for: "t1")?.capability == "tok2" && reg.surface(for: "t1")?.surfaceId == "s2"
              && reg.surface(for: "t1")?.workspaceId == "w2" && reg.surface(for: "t1")?.socketPath == "/tmp/c.sock")
        let moved = reg.note(taskId: "t1", surfaceId: "s3", workspaceId: "w3", socketPath: "/tmp/d.sock",
                             capability: "tok3", sessionId: "", now: 35, isStoredSocketTrusted: { _ in true })
        check("live entry: a different socket path refuses the whole unit while the stored socket is trusted",
              !moved && reg.surface(for: "t1")?.socketPath == "/tmp/c.sock" && reg.surface(for: "t1")?.capability == "tok2"
              && reg.surface(for: "t1")?.surfaceId == "s2" && reg.surface(for: "t1")?.workspaceId == "w2")
        var rb = CmuxRegistry()
        rb.note(taskId: "x", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/c.sock", capability: "T", sessionId: "", now: 1)
        rb.clearCredentials()
        check("entry without a live token accepts a new socket path (cmux restarted)",
              rb.note(taskId: "x", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/e.sock", capability: "T2", sessionId: "", now: 2)
              && rb.surface(for: "x")?.socketPath == "/tmp/e.sock")
        var rg = reg
        let healed = rg.note(taskId: "t1", surfaceId: "s4", workspaceId: "w4", socketPath: "/tmp/d.sock",
                             capability: "tok4", sessionId: "", now: 36, isStoredSocketTrusted: { _ in false })
        check("live entry: the new unit is accepted when the stored socket file is gone or not a user socket",
              healed && rg.surface(for: "t1")?.socketPath == "/tmp/d.sock" && rg.surface(for: "t1")?.capability == "tok4")
        check("trust is asked about the stored path, not the new one",
              { var asked: [String] = []
                var r2 = reg
                r2.note(taskId: "t1", surfaceId: "s5", workspaceId: "w5", socketPath: "/tmp/z.sock",
                        capability: "t5", sessionId: "", now: 37, isStoredSocketTrusted: { asked.append($0); return true })
                return asked == ["/tmp/c.sock"] }())
        reg.note(taskId: "t1", surfaceId: "evil", workspaceId: "evil", socketPath: "/tmp/evil.sock",
                 capability: "", sessionId: "sess2", now: 40)
        check("no capability: socket, ids and token unchanged",
              reg.surface(for: "t1")?.socketPath == "/tmp/c.sock" && reg.surface(for: "t1")?.surfaceId == "s2"
              && reg.surface(for: "t1")?.workspaceId == "w2" && reg.surface(for: "t1")?.capability == "tok2")
        check("no capability: sessionId and lastSeen still refresh",
              reg.surface(for: "t1")?.sessionId == "sess2" && reg.surface(for: "t1")?.lastSeen == 40)
        reg.note(taskId: "t9", surfaceId: "s", workspaceId: "w", socketPath: "/tmp/c.sock",
                 capability: "", sessionId: "x", now: 50)
        check("entry created without capability cannot focus",
              reg.surface(for: "t9") != nil && reg.surface(for: "t9")?.canFocusExactly == false
              && reg.surface(for: "t9")?.socketPath == "")
        reg.remove(taskId: "t1")
        check("remove", reg.surface(for: "t1") == nil)

        // ── staleness ──────────────────────────────────────────────────────────
        print("CmuxRegistry.staleTaskIds")
        var st = CmuxRegistry()
        st.note(taskId: "old", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 0)
        st.note(taskId: "edge", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 100)
        st.note(taskId: "held", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 0)
        st.note(taskId: "fresh", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: 1900)
        let nowT: TimeInterval = 100 + CmuxRouting.staleAfter
        check("staleAfter is 30 minutes", CmuxRouting.staleAfter == 1800)
        check("older than 30 min removed, exactly 30 min kept, protected kept, fresh kept",
              st.staleTaskIds(now: nowT, protected: ["held"]) == ["old"])
        check("nothing stale just under the limit", st.staleTaskIds(now: 1799, protected: []).isEmpty)
        check("protected entry stays however old",
              !st.staleTaskIds(now: 100_000, protected: ["held"]).contains("held"))

        // ── canFocusExactly ────────────────────────────────────────────────────
        print("CmuxSurface.canFocusExactly")
        let full = CmuxSurface(taskId: "t", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                               capability: "c", sessionId: "", lastSeen: 0)
        check("complete → true", full.canFocusExactly)
        var m = full; m.capability = ""
        check("no token → false", !m.canFocusExactly)
        m = full; m.surfaceId = ""
        check("no surface → false", !m.canFocusExactly)
        m = full; m.workspaceId = ""
        check("no workspace → false", !m.canFocusExactly)
        m = full; m.socketPath = ""
        check("no socket → false", !m.canFocusExactly)

        // ── evictionCandidates ─────────────────────────────────────────────────
        print("CmuxRegistry.evictionCandidates")
        var big = CmuxRegistry()
        for i in 1...12 {
            big.note(taskId: "t\(i)", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                     capability: "c", sessionId: "", now: TimeInterval(i))
        }
        check("maxTasks is 12 pills", CmuxRouting.maxTasks == 12)
        let all = Set((1...12).map { "t\($0)" })
        check("none at 12", big.evictionCandidates(idle: all, keep: nil).isEmpty)
        big.note(taskId: "t13", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                 capability: "c", sessionId: "", now: 13)
        let all13 = all.union(["t13"])
        check("at 13 → oldest idle", big.evictionCandidates(idle: all13, keep: "t13") == ["t1"])
        check("never returns keep", big.evictionCandidates(idle: all13, keep: "t1") == ["t2"])
        check("nothing when all busy", big.evictionCandidates(idle: [], keep: "t13").isEmpty)
        big.note(taskId: "t14", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                 capability: "c", sessionId: "", now: 14)
        big.note(taskId: "t15", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock",
                 capability: "c", sessionId: "", now: 15)
        let all15 = all13.union(["t14", "t15"])
        check("excess 3 → three oldest idle in order",
              big.evictionCandidates(idle: all15, keep: "t15") == ["t1", "t2", "t3"])
        check("fewer idle than the excess → only the idle ones",
              big.evictionCandidates(idle: ["t4", "t6"], keep: "t15") == ["t4", "t6"])
        check("mix of idle and busy skips the busy oldest",
              big.evictionCandidates(idle: ["t3", "t5", "t8"], keep: "t15") == ["t3", "t5", "t8"])

        // ── queue ──────────────────────────────────────────────────────────────
        print("CmuxCardQueue")
        var q = CmuxCardQueue()
        let a = q.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k1", now: 100)
        let b = q.enqueue(kind: .question, taskId: "t2", sessionId: "s2", tool: "AskUserQuestion", inputKey: "k2", now: 101)
        check("FIFO order", q.popNext(now: 102).card?.id == a && q.popNext(now: 102).card?.id == b)
        check("empty queue pops nil", q.popNext(now: 102).card == nil)

        let c = q.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 200)
        let d = q.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 201,
                          atFront: true, arrivedAt: 150)
        let popped = q.popNext(now: 205)
        check("atFront pops first, keeps arrivedAt", popped.card?.id == d && popped.card?.arrivedAt == 150)
        check("front card not expired at 55 s", popped.expired.isEmpty)
        _ = c

        var qe = CmuxCardQueue()
        let old = qe.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let fresh = qe.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 100)
        let r = qe.popNext(now: 111)
        check("expired card skipped and reported", r.expired == [old] && r.card?.id == fresh)

        var qb = CmuxCardQueue()
        let edge = qb.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let atEdge = qb.popNext(now: 110)
        check("exactly 110 s is not expired", atEdge.card?.id == edge && atEdge.expired.isEmpty)
        var qb2 = CmuxCardQueue()
        let just = qb2.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        check("110.5 s is expired", qb2.popNext(now: 110.5).expired == [just])

        var qx = CmuxCardQueue()
        let x1 = qx.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let x2 = qx.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 1)
        let x3 = qx.enqueue(kind: .approval, taskId: "t3", sessionId: "s3", tool: "Bash", inputKey: "k", now: 2)
        let x4 = qx.enqueue(kind: .approval, taskId: "t4", sessionId: "s4", tool: "Bash", inputKey: "k", now: 200)
        let multi = qx.popNext(now: 210)
        check("several expired in a row are all reported, in order, then the live card",
              multi.expired == [x1, x2, x3] && multi.card?.id == x4)
        var qa = CmuxCardQueue()
        let a1 = qa.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0)
        let a2 = qa.enqueue(kind: .question, taskId: "t2", sessionId: "s2", tool: "AskUserQuestion", inputKey: "k", now: 5)
        let allGone = qa.popNext(now: 500)
        check("all expired → no card, every id reported, queue empty",
              allGone.card == nil && allGone.expired == [a1, a2] && qa.cards.isEmpty)

        print("CmuxCardQueue.canAccept")
        var qc = CmuxCardQueue()
        check("empty queue accepts", qc.canAccept(taskId: "t1"))
        _ = qc.enqueue(kind: .approval, taskId: "t1", sessionId: "s", tool: "Bash", inputKey: "1", now: 0)
        check("one card of the task: still accepts", qc.canAccept(taskId: "t1"))
        _ = qc.enqueue(kind: .approval, taskId: "t1", sessionId: "s", tool: "Bash", inputKey: "2", now: 0)
        check("two cards of the task: refuses a third", !qc.canAccept(taskId: "t1"))
        check("another task is still accepted", qc.canAccept(taskId: "t2"))
        for i in 0..<14 {
            _ = qc.enqueue(kind: .approval, taskId: "u\(i)", sessionId: "s", tool: "Bash", inputKey: "k", now: 0)
        }
        check("16 cards in total: refuses any task", qc.cards.count == 16 && !qc.canAccept(taskId: "new"))
        _ = qc.removeAll(taskId: "t1")
        check("room again after removals", qc.canAccept(taskId: "new"))

        // resolve
        var qe0 = CmuxCardQueue()
        _ = qe0.enqueue(kind: .approval, taskId: "t1", sessionId: "", tool: "Bash", inputKey: "k", now: 0)
        check("empty session id resolves nothing (Stop and PostToolUse)",
              qe0.resolve(event: "Stop", sessionId: "", tool: "", inputKey: "").isEmpty
              && qe0.resolve(event: "PostToolUse", sessionId: "", tool: "Bash", inputKey: "k").isEmpty
              && qe0.cards.count == 1)

        var qr = CmuxCardQueue()
        let r1 = qr.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "ka", now: 1)
        _ = qr.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "kb", now: 1)
        _ = qr.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "ka", now: 1)
        check("PostToolUse removes only same session+tool+input",
              qr.resolve(event: "PostToolUse", sessionId: "s1", tool: "Bash", inputKey: "ka") == [r1]
              && qr.cards.count == 2)
        check("PostToolUse other tool untouched",
              qr.resolve(event: "PostToolUseFailure", sessionId: "s1", tool: "Edit", inputKey: "kb").isEmpty)
        check("PreToolUse removes nothing",
              qr.resolve(event: "PreToolUse", sessionId: "s1", tool: "Bash", inputKey: "kb").isEmpty)
        for ev in ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt"] {
            var qs = CmuxCardQueue()
            let x = qs.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k1", now: 1)
            let y = qs.enqueue(kind: .question, taskId: "t1", sessionId: "s1", tool: "AskUserQuestion", inputKey: "k2", now: 1)
            let z = qs.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k1", now: 1)
            let gone = qs.resolve(event: ev, sessionId: "s1", tool: "", inputKey: "")
            check("\(ev) removes that session only", Set(gone) == Set([x, y]) && qs.cards.map { $0.id } == [z])
        }

        // remove / removeAll / hasCards
        var qm = CmuxCardQueue()
        let m1 = qm.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Bash", inputKey: "k", now: 1)
        let m2 = qm.enqueue(kind: .approval, taskId: "t1", sessionId: "s1", tool: "Edit", inputKey: "k", now: 1)
        let m3 = qm.enqueue(kind: .approval, taskId: "t2", sessionId: "s2", tool: "Bash", inputKey: "k", now: 1)
        check("hasCards true", qm.hasCards(for: "t1") && qm.hasCards(for: "t2"))
        check("remove(id:) returns the card", qm.remove(id: m1)?.id == m1 && qm.remove(id: m1) == nil)
        check("removeAll(taskId:)", qm.removeAll(taskId: "t1") == [m2])
        check("hasCards after removals", !qm.hasCards(for: "t1") && qm.hasCards(for: "t2"))
        _ = m3

        // ── validation ─────────────────────────────────────────────────────────
        print("CmuxRouting validation")
        check("id: uuid ok", CmuxRouting.isValidId("ABCDEF12-3456-7890-ABCD-EF1234567890"))
        check("id: colon and underscore ok", CmuxRouting.isValidId("workspace:3_a-b"))
        check("id: 64 chars ok, 65 refused",
              CmuxRouting.isValidId(String(repeating: "a", count: 64)) && !CmuxRouting.isValidId(String(repeating: "a", count: 65)))
        check("id: starts with a dash refused", !CmuxRouting.isValidId("--help") && !CmuxRouting.isValidId("-x"))
        check("id: starts with colon or underscore refused", !CmuxRouting.isValidId(":a") && !CmuxRouting.isValidId("_a"))
        check("id: empty, space, slash, newline refused",
              !CmuxRouting.isValidId("") && !CmuxRouting.isValidId("a b") && !CmuxRouting.isValidId("a/b")
              && !CmuxRouting.isValidId("a\nb"))
        check("id: non ASCII refused", !CmuxRouting.isValidId("é1"))

        check("capability: printable ascii ok", CmuxRouting.isValidCapability("Ab3-_.~=+/xyz"))
        check("capability: 512 ok, 513 refused",
              CmuxRouting.isValidCapability(String(repeating: "a", count: 512))
              && !CmuxRouting.isValidCapability(String(repeating: "a", count: 513)))
        check("capability: empty, space, control, non ASCII refused",
              !CmuxRouting.isValidCapability("") && !CmuxRouting.isValidCapability("a b")
              && !CmuxRouting.isValidCapability("a\u{7}b") && !CmuxRouting.isValidCapability("tökén"))

        check("socket: absolute .sock ok", CmuxRouting.isValidSocketPath("/tmp/cmux.sock"))
        check("socket: 103 bytes ok, 104 refused",
              CmuxRouting.isValidSocketPath("/" + String(repeating: "a", count: 97) + ".sock")
              && !CmuxRouting.isValidSocketPath("/" + String(repeating: "a", count: 98) + ".sock"))
        check("socket: relative, no suffix, empty refused",
              !CmuxRouting.isValidSocketPath("tmp/c.sock") && !CmuxRouting.isValidSocketPath("/tmp/c")
              && !CmuxRouting.isValidSocketPath(""))
        check("socket: dot-dot and space refused",
              !CmuxRouting.isValidSocketPath("/tmp/../etc/x.sock") && !CmuxRouting.isValidSocketPath("/tmp/a b.sock"))

        let okSock = "/tmp/cmux.sock"
        check("context: all valid",
              CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: okSock, capability: "tok"))
        check("context: value starting with a dash drops everything",
              !CmuxRouting.isValidContext(surfaceId: "--help", workspaceId: "W1", socketPath: okSock, capability: "tok")
              && !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "-x", socketPath: okSock, capability: "tok"))
        check("context: bad socket or bad capability drops everything",
              !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: "/tmp/x", capability: "tok")
              && !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: okSock, capability: "a b"))
        check("context: empty field drops everything",
              !CmuxRouting.isValidContext(surfaceId: "", workspaceId: "W1", socketPath: okSock, capability: "tok")
              && !CmuxRouting.isValidContext(surfaceId: "S1", workspaceId: "W1", socketPath: okSock, capability: ""))

        // ── socket file ────────────────────────────────────────────────────────
        print("CmuxRouting.isTrustedSocket")
        let uid = UInt32(getuid())
        check("socket owned by the user", CmuxRouting.isTrustedSocket(mode: UInt32(S_IFSOCK) | 0o600, owner: uid, currentUid: uid))
        check("other owner refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFSOCK) | 0o600, owner: uid + 1, currentUid: uid))
        check("regular file refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFREG) | 0o600, owner: uid, currentUid: uid))
        check("symlink refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFLNK) | 0o777, owner: uid, currentUid: uid))
        check("directory refused", !CmuxRouting.isTrustedSocket(mode: UInt32(S_IFDIR) | 0o700, owner: uid, currentUid: uid))

        let sockDir = "/tmp/cmuxrt-\(getpid())"
        mkdir(sockDir, 0o700)
        let sockPath = sockDir + "/real.sock"
        let linkPath = sockDir + "/link.sock"
        let filePath = sockDir + "/file.sock"
        let fdSock = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, sockPath, 103) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fdSock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        symlink(sockPath, linkPath)
        FileManager.default.createFile(atPath: filePath, contents: Data())
        check("lstat: a real socket of the user is trusted", bound == 0 && CmuxRouting.socketFileIsTrusted(path: sockPath))
        check("lstat: a symlink to that socket is refused", !CmuxRouting.socketFileIsTrusted(path: linkPath))
        check("lstat: a regular file is refused", !CmuxRouting.socketFileIsTrusted(path: filePath))
        check("lstat: a missing path is refused", !CmuxRouting.socketFileIsTrusted(path: sockDir + "/none.sock"))
        close(fdSock)
        try? FileManager.default.removeItem(atPath: sockDir)

        // ── timing and lifecycle ───────────────────────────────────────────────
        print("CmuxRouting.recapAgentKey")
        check("a cmux workspace folds into the cmux bucket",
              CmuxRouting.recapAgentKey("agent_cmux_abcdef12-3456-7890-abcd-ef1234567890") == CmuxRouting.taskPrefix)
        check("two workspaces share one bucket",
              CmuxRouting.recapAgentKey("agent_cmux_aaa") == CmuxRouting.recapAgentKey("agent_cmux_bbb"))
        check("the bucket is still a cmux task id (displayed as cmux)",
              CmuxRouting.isCmuxTaskId(CmuxRouting.recapAgentKey("agent_cmux_aaa")))
        check("other pills keep their own id",
              CmuxRouting.recapAgentKey("agent_vscode") == "agent_vscode" && CmuxRouting.recapAgentKey("integration_claude") == "integration_claude")
        var tally: [String: Int] = [:]
        for id in (0..<6).flatMap({ i in Array(repeating: "agent_cmux_ws\(i)", count: 5) }) + Array(repeating: "agent_vscode", count: 8) {
            tally[CmuxRouting.recapAgentKey(id), default: 0] += 1
        }
        check("30 cmux turns over 6 workspaces beat 8 turns in one pill",
              tally.max { $0.value < $1.value }?.key == CmuxRouting.taskPrefix)

        print("CmuxRouting.inputLocked / isLateCard / mayRegister")
        check("lock window is 700 ms", CmuxRouting.promotionLock == 0.7)
        check("no promotion → never locked", !CmuxRouting.inputLocked(promotedAt: nil, now: 100))
        check("0 ms after promotion → locked", CmuxRouting.inputLocked(promotedAt: 100, now: 100))
        check("699 ms after promotion → locked", CmuxRouting.inputLocked(promotedAt: 100, now: 100.699))
        check("700 ms after promotion → free", !CmuxRouting.inputLocked(promotedAt: 100, now: 100.7))
        check("clock going backwards does not lock forever", !CmuxRouting.inputLocked(promotedAt: 100, now: 99))
        check("card shown 115 s is not late, 115.1 s is late",
              !CmuxRouting.isLateCard(arrivedAt: 0, now: 115) && CmuxRouting.isLateCard(arrivedAt: 0, now: 115.1))
        check("creating events register without a live task",
              ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "AskUserQuestion"]
                .allSatisfy { CmuxRouting.mayRegister(event: $0, taskIsLive: false) })
        check("other events do not create an entry for a dead task",
              ["PostToolUse", "Notification", "Stop", "StopFailure", "SessionEnd", "SubagentStop", ""]
                .allSatisfy { !CmuxRouting.mayRegister(event: $0, taskIsLive: false) })
        check("any event registers for a live task",
              ["PostToolUse", "Stop", "SessionEnd"].allSatisfy { CmuxRouting.mayRegister(event: $0, taskIsLive: true) })
        check("requirement pins identifier and team",
              CmuxRouting.codeRequirement.contains("com.cmuxterm.app") && CmuxRouting.codeRequirement.contains("7WLXT3NR37")
              && CmuxRouting.codeRequirement.hasPrefix("anchor apple generic"))


        // ── cmux as Main: reply, new chat, icons ───────────────────────────────
        do {
        print("hub pill id")
        check("hub id is not a cmux task id", !CmuxRouting.isCmuxTaskId(CmuxRouting.hubPillId))
        check("taskId never returns the hub id",
              CmuxRouting.taskId(payload: ["cmux_surface_id": "integration_cmux"]) != CmuxRouting.hubPillId
              && CmuxRouting.taskId(payload: ["bundle_id": "com.cmuxterm.app", "session_id": "integration_cmux"]) != CmuxRouting.hubPillId)

        print("fnv1a / appearance")
        check("fnv1a empty", CmuxRouting.fnv1a("") == 0xcbf29ce484222325)
        check("fnv1a a", CmuxRouting.fnv1a("a") == 0xaf63dc4c8601ec8c)
        let a1 = CmuxRouting.appearance(key: "abc", takenColors: [])
        let a2 = CmuxRouting.appearance(key: "abc", takenColors: [])
        let sameColor = a1.color == a2.color
        let sameEye = a1.eye == a2.eye
        check("appearance deterministic", sameColor && sameEye)
        let a3 = CmuxRouting.appearance(key: "abc", takenColors: [a1.color])
        check("taken colour is skipped", a3.color != a1.color && CmuxRouting.palette.contains(a3.color))
        check("eye of the probed result is unchanged", a3.eye == a1.eye)
        check("all 8 taken → base colour",
              CmuxRouting.appearance(key: "abc", takenColors: Set(CmuxRouting.palette)).color == a1.color)
        var live = Set<String>()
        var distinct = true
        for i in 0..<8 {
            let c = CmuxRouting.appearance(key: "surface-\(i)", takenColors: live).color
            if live.contains(c) { distinct = false }
            live.insert(c)
        }
        check("8 live sessions get 8 different colours", distinct && live.count == 8)
        check("eye always in the list",
              (0..<200).allSatisfy { CmuxRouting.eyes.contains(CmuxRouting.appearance(key: "k\($0)", takenColors: []).eye) })

        print("preparePrompt")
        check("newline, CR, tab become spaces",
              CmuxRouting.preparePrompt("a\nb\rc\td") == "a b c d")
        check("ESC, 0x03, 0x7F become spaces",
              CmuxRouting.preparePrompt("x\u{1B}y\u{03}z\u{7F}w") == "x y z w")
        check("C1 control becomes a space", CmuxRouting.preparePrompt("a\u{85}b") == "a b")
        check("literal backslash-n kept", CmuxRouting.preparePrompt("a\\nb") == "a\\nb")
        check("quotes, $(), backticks, ; kept verbatim",
              CmuxRouting.preparePrompt("say \"hi\" $(id) `ls`; 'x'") == "say \"hi\" $(id) `ls`; 'x'")
        check("whitespace only → nil", CmuxRouting.preparePrompt(" \n\t ") == nil && CmuxRouting.preparePrompt("") == nil)
        check("capped at 8000", CmuxRouting.preparePrompt(String(repeating: "a", count: 9000))?.count == 8000)

        print("isValidLaunchCommand / isValidFolder")
        check("accepts claude", CmuxRouting.isValidLaunchCommand("claude"))
        check("accepts flag", CmuxRouting.isValidLaunchCommand("claude --dangerously-skip-permissions"))
        check("accepts path and =", CmuxRouting.isValidLaunchCommand("/opt/bin/claude --model=opus"))
        check("rejects empty", !CmuxRouting.isValidLaunchCommand(""))
        check("rejects shell syntax",
              [";", "&&", "|", "$", "`", "\"", "'", "\n", "(", ">", "\\"].allSatisfy { !CmuxRouting.isValidLaunchCommand("claude\($0)x") })
        check("rejects leading dash", !CmuxRouting.isValidLaunchCommand("-claude"))
        check("rejects an environment prefix (= in the first token)",
              !CmuxRouting.isValidLaunchCommand("ANTHROPIC_BASE_URL=http://host claude")
              && !CmuxRouting.isValidLaunchCommand("A=b")
              && CmuxRouting.isValidLaunchCommand("claude --model=opus"))
        check("121 chars rejected, 120 accepted",
              !CmuxRouting.isValidLaunchCommand(String(repeating: "a", count: 121))
              && CmuxRouting.isValidLaunchCommand(String(repeating: "a", count: 120)))
        check("folder absolute ok", CmuxRouting.isValidFolder("/Users/me/Dev/app"))
        check("folder relative rejected", !CmuxRouting.isValidFolder("Dev/app"))
        check("folder .. rejected", !CmuxRouting.isValidFolder("/Users/me/../root"))
        check("folder control char rejected", !CmuxRouting.isValidFolder("/Users/me\n/x"))
        check("folder C1 control char rejected", !CmuxRouting.isValidFolder("/Users/me/\u{85}x") && !CmuxRouting.isValidFolder("/Users/me/\u{9F}x"))
        check("folder DEL rejected", !CmuxRouting.isValidFolder("/Users/me/\u{7F}x"))
        check("folder with accents ok", CmuxRouting.isValidFolder("/Users/me/Projetos/açaí"))
        check("existing folder: / yes, missing no, invalid no",
              CmuxRouting.isExistingFolder("/tmp") && !CmuxRouting.isExistingFolder("/no/such/dir/at/all")
              && !CmuxRouting.isExistingFolder("tmp") && !CmuxRouting.isExistingFolder("/tmp/../etc"))
        check("chip labels: last component, parent when two share it",
              CmuxRouting.chipLabels(for: ["/a/x/coucou", "/b/y/api", "/c/z/coucou"]) == ["x/coucou", "api", "z/coucou"]
              && CmuxRouting.chipLabels(for: ["/a/app", "/b/web"]) == ["app", "web"])
        check("folder over 1024 bytes rejected", !CmuxRouting.isValidFolder("/" + String(repeating: "a", count: 1030)))

        print("rpcParams")
        check("invalid ids give nil",
              CmuxRouting.rpcParams(workspaceId: "", surfaceId: "s1", text: "x") == nil
              && CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "a b", text: "x") == nil
              && CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "../x", key: "enter") == nil)
        let nasty = "q\"uote \\ back $(id) `x` é 🙂 \\n"
        if let p = CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "s1", text: nasty),
           let data = try? JSONSerialization.data(withJSONObject: p),
           let back = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            check("text round trips byte for byte", back["text"] == nasty && back["surface_id"] == "s1")
        } else { check("text round trips byte for byte", false) }
        check("key params", CmuxRouting.rpcParams(workspaceId: "w1", surfaceId: "s1", key: "enter")?["key"] == "enter")

        print("credential / clearCredentials")
        var cr = CmuxRegistry()
        cr.note(taskId: "a", surfaceId: "sa", workspaceId: "w", socketPath: "/s.sock", capability: "TA", sessionId: "x", now: 10)
        cr.note(taskId: "b", surfaceId: "sb", workspaceId: "w", socketPath: "/s.sock", capability: "TB", sessionId: "y", now: 20)
        cr.note(taskId: "c", surfaceId: "", workspaceId: "", socketPath: "", capability: "", sessionId: "z", now: 30)
        if case .token(let s) = cr.credential(for: "a", hasPassword: true) { check("own token wins", s.taskId == "a") }
        else { check("own token wins", false) }
        if case .token(let s) = cr.credential(for: "c", hasPassword: true) { check("entry without token → freshest other", s.taskId == "b") }
        else { check("entry without token → freshest other", false) }
        if case .token(let s) = cr.credential(for: nil, hasPassword: false) { check("no target → freshest token", s.taskId == "b") }
        else { check("no target → freshest token", false) }
        cr.clearCredentials()
        check("clear keeps entries and ids, empties tokens",
              cr.surfaces.count == 3 && cr.surface(for: "a")?.surfaceId == "sa"
              && cr.surface(for: "a")?.capability == "" && cr.surface(for: "a")?.canFocusExactly == false)
        check("password when no token", cr.credential(for: "a", hasPassword: true) == .password)
        check("none without token or password", cr.credential(for: "a", hasPassword: false) == CmuxCredential.none)

        print("staleTaskIds busy")
        var sb = CmuxRegistry()
        sb.note(taskId: "busy", surfaceId: "s", workspaceId: "w", socketPath: "/s.sock", capability: "T", sessionId: "", now: 0)
        sb.note(taskId: "idle", surfaceId: "s", workspaceId: "w", socketPath: "/s.sock", capability: "T", sessionId: "", now: 0)
        sb.note(taskId: "held", surfaceId: "s", workspaceId: "w", socketPath: "/s.sock", capability: "T", sessionId: "", now: 0)
        check("busy at 31 min kept, idle stale",
              sb.staleTaskIds(now: 31 * 60, protected: ["held"], busy: ["busy"]) == ["idle"])
        check("busy at 6 h + 1 s stale, protected never",
              sb.staleTaskIds(now: 6 * 3600 + 1, protected: ["held"], busy: ["busy"]) == ["busy", "idle"])

        print("CmuxPendingLaunch")
        let pl = CmuxPendingLaunch(workspaceId: "AB12", socketPath: "/s.sock", cwd: "/a/b", prompt: "p", createdAt: 100)
        check("workspace and socket match", pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 105))
        check("workspace id compared case insensitively", pl.matches(workspaceId: "ab12", socketPath: "/s.sock", isNewTask: true, now: 105))
        check("workspace mismatch", !pl.matches(workspaceId: "W2", socketPath: "/s.sock", isNewTask: true, now: 105))
        check("socket path mismatch", !pl.matches(workspaceId: "AB12", socketPath: "/other.sock", isNewTask: true, now: 105))
        check("empty incoming workspace id never matches", !pl.matches(workspaceId: "", socketPath: "/s.sock", isNewTask: true, now: 105))
        let unresolved = CmuxPendingLaunch(workspaceId: "", socketPath: "/s.sock", cwd: "/a/b", prompt: "p", createdAt: 100)
        check("empty stored workspace id never matches, even with an empty one",
              !unresolved.matches(workspaceId: "", socketPath: "/s.sock", isNewTask: true, now: 105)
              && !unresolved.matches(workspaceId: "Z", socketPath: "/s.sock", isNewTask: true, now: 105))
        let noSocket = CmuxPendingLaunch(workspaceId: "AB12", socketPath: "", cwd: "/a/b", prompt: "p", createdAt: 100)
        check("password mode (no socket path) is not auto sendable",
              !noSocket.autoSendable && !noSocket.matches(workspaceId: "AB12", socketPath: "", isNewTask: true, now: 105))
        check("autoSendable needs both", pl.autoSendable && !unresolved.autoSendable)
        check("existing task (/clear) never matches", !pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: false, now: 105))
        check("expired never matches", !pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 191))
        check("90 s boundary still matches", pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 190))
        check("clock before creation never matches", !pl.matches(workspaceId: "AB12", socketPath: "/s.sock", isNewTask: true, now: 99))
        check("folder match only for a launch started with the password (no socket path)",
              noSocket.matchesFolder(cwd: "/a/b/", isNewTask: true, now: 105)
              && !unresolved.matchesFolder(cwd: "/a/b", isNewTask: true, now: 105)
              && !pl.matchesFolder(cwd: "/a/b", isNewTask: true, now: 105))
        check("folder match: other folder, existing task, expired, empty cwd all refused",
              !noSocket.matchesFolder(cwd: "/a/c", isNewTask: true, now: 105)
              && !noSocket.matchesFolder(cwd: "/a/b", isNewTask: false, now: 105)
              && !noSocket.matchesFolder(cwd: "/a/b", isNewTask: true, now: 191)
              && !noSocket.matchesFolder(cwd: "", isNewTask: true, now: 105))
        check("folder notice names the session",
              CmuxRouting.folderDraftNotice(sessionName: "Hera (Code Reviewer)")
                == "claude started in Hera (Code Reviewer). Check the prompt and press Send."
              && CmuxRouting.folderDraftNotice(sessionName: "") == "claude started in the new session. Check the prompt and press Send.")

        print("workspace ref / UUID parsers")
        let wsUUID = "7A1B2C3D-0000-4abc-8def-0123456789AB"
        check("ref from stdout", CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:10\n") == "workspace:10")
        check("ref: none, junk, empty digits",
              CmuxRouting.workspaceRef(inNewWorkspaceOutput: "") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "Error: nope") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:1a") == nil)
        check("ref: anchored, the first token is OK and the second is the ref",
              CmuxRouting.workspaceRef(inNewWorkspaceOutput: "workspace:3") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "x workspace:3 y") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK /tmp/x workspace:3 y") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "ERR workspace:3") == nil
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "OK workspace:3 workspace:4") == "workspace:3"
              && CmuxRouting.workspaceRef(inNewWorkspaceOutput: "  OK\tworkspace:12\r\n") == "workspace:12")
        let listJSON = "{\"workspaces\":[{\"id\":\"11111111-1111-4111-8111-111111111111\",\"ref\":\"workspace:9\",\"title\":\"a\",\"current_directory\":\"/x\"},{\"id\":\"\(wsUUID)\",\"ref\":\"workspace:10\",\"title\":\"b\",\"current_directory\":\"/y\"}]}"
        check("UUID from the list by ref", CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: listJSON) == wsUUID)
        check("UUID: unknown ref, bad JSON, id that is not a UUID",
              CmuxRouting.workspaceId(forRef: "workspace:11", inListJSON: listJSON) == nil
              && CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: "not json") == nil
              && CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: "{\"workspaces\":[{\"id\":\"workspace:10\",\"ref\":\"workspace:10\"}]}") == nil)
        check("UUID under a result wrapper",
              CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: "{\"result\":\(listJSON)}") == wsUUID)

        // Shapes of workspace.list in cmux 0.64.25 (made up ids and titles): `--id-format uuids` drops `ref`,
        // `both` and the default keep the UUID id and add the ref.
        let itemA = "\"id\":\"11111111-1111-4111-8111-111111111111\",\"index\":0,\"title\":\"one\",\"current_directory\":\"/x\""
        let itemB = "\"id\":\"\(wsUUID)\",\"index\":1,\"title\":\"two\",\"current_directory\":\"/y\""
        let uuidsShape = "{\"window_id\":\"22222222-2222-4222-8222-222222222222\",\"workspaces\":[{\(itemA)},{\(itemB)}]}"
        let bothShape = "{\"window_id\":\"22222222-2222-4222-8222-222222222222\",\"window_ref\":\"window:1\",\"workspaces\":[{\(itemA),\"ref\":\"workspace:9\"},{\(itemB),\"ref\":\"workspace:10\"}]}"
        check("UUID: the uuids shape has no ref, nothing else may match (index, title, folder)",
              CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: uuidsShape) == nil
              && CmuxRouting.workspaceId(forRef: "workspace:1", inListJSON: uuidsShape) == nil)
        check("UUID: the both shape and the default shape resolve by ref",
              CmuxRouting.workspaceId(forRef: "workspace:10", inListJSON: bothShape) == wsUUID
              && CmuxRouting.workspaceId(forRef: "workspace:9", inListJSON: bothShape) == "11111111-1111-4111-8111-111111111111")
        check("workspace.list lookup: asks for ids and refs first, then the default form once, nothing else",
              CmuxRouting.workspaceListIdFormats == ["both", nil]
              && CmuxRouting.workspaceListArguments(idFormat: "both") == ["--id-format", "both", "rpc", "workspace.list", "{}"]
              && CmuxRouting.workspaceListArguments(idFormat: nil) == ["rpc", "workspace.list", "{}"])
        let token = CmuxPendingLaunch(workspaceId: "", socketPath: "/s.sock", cwd: "/x", prompt: "p", createdAt: 0)
        check("unresolved launch: a token launch without workspace id is reported, a resolved one and a password one are not",
              token.cannotBeMatched
              && !CmuxPendingLaunch(workspaceId: wsUUID, socketPath: "/s.sock", cwd: "/x", prompt: "p", createdAt: 0).cannotBeMatched
              && !CmuxPendingLaunch(workspaceId: "", socketPath: "", cwd: "/x", prompt: "p", createdAt: 0).cannotBeMatched
              && !token.matches(workspaceId: wsUUID, socketPath: "/s.sock", isNewTask: true, now: 1)
              && !token.matchesFolder(cwd: "/x", isNewTask: true, now: 1))

        print("sendCredential (its own token only, never the password)")
        var sc = CmuxRegistry()
        sc.note(taskId: "a", surfaceId: "sa", workspaceId: "w", socketPath: "/s.sock", capability: "TA", sessionId: "", now: 10)
        sc.note(taskId: "b", surfaceId: "sb", workspaceId: "w", socketPath: "/s.sock", capability: "TB", sessionId: "", now: 20)
        sc.note(taskId: "o", surfaceId: "so", workspaceId: "w", socketPath: "/other.sock", capability: "TO", sessionId: "", now: 30)
        if case .token(let t) = sc.sendCredential(for: "a") { check("own token", t.taskId == "a") } else { check("own token", false) }
        check("unknown task: none", sc.sendCredential(for: "zzz") == CmuxCredential.none)
        sc.clearCredentials()
        check("no token anywhere: none, even with a password stored", sc.sendCredential(for: "a") == CmuxCredential.none)
        sc.note(taskId: "b", surfaceId: "sb", workspaceId: "w", socketPath: "/s.sock", capability: "TB2", sessionId: "", now: 40)
        check("no own token: none, the token of another surface on the same socket is never lent for typing",
              sc.sendCredential(for: "a") == CmuxCredential.none)
        if case .token(let t) = sc.sendCredential(for: "b") { check("the surface that reported again has its own token", t.capability == "TB2") }
        else { check("the surface that reported again has its own token", false) }
        if case .token(let t) = sc.jumpCredential(forKey: "a") { check("jump may borrow the freshest token on the same socket", t.taskId == "b") }
        else { check("jump may borrow the freshest token on the same socket", false) }
        sc.note(taskId: "o", surfaceId: "so", workspaceId: "w", socketPath: "/other.sock", capability: "TO2", sessionId: "", now: 50)
        if case .token(let t) = sc.jumpCredential(forKey: "a") { check("jump: a fresher token on another socket is not used", t.taskId == "b") }
        else { check("jump: a fresher token on another socket is not used", false) }
        var sd = CmuxRegistry()
        sd.note(taskId: "d", surfaceId: "", workspaceId: "", socketPath: "", capability: "", sessionId: "x", now: 1)
        sd.note(taskId: "e", surfaceId: "se", workspaceId: "w", socketPath: "/s.sock", capability: "TE", sessionId: "", now: 2)
        check("entry that never had a socket: none", sd.sendCredential(for: "d") == CmuxCredential.none && sd.jumpCredential(forKey: "d") == CmuxCredential.none)
        check("password is never a send or jump credential",
              ["a", "b", "o", "zzz"].allSatisfy { sc.sendCredential(for: $0) != .password && sc.jumpCredential(forKey: $0) != .password })

        print("shouldFocusNewSession / nextFocus / canSend")
        let hub = CmuxRouting.hubPillId
        check("hub main, focus nil, allowed", CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: nil, viewAllowsSteal: true))
        check("hub main, focus hub, allowed", CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: hub, viewAllowsSteal: true))
        check("hub main, focus on a session, never", !CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: "agent_cmux_x", viewAllowsSteal: true))
        check("view does not allow", !CmuxRouting.shouldFocusNewSession(mainPillId: hub, focusId: nil, viewAllowsSteal: false))
        check("VS Code main never", !CmuxRouting.shouldFocusNewSession(mainPillId: "integration_claude", focusId: nil, viewAllowsSteal: true))
        check("nextFocus: most recent remaining",
              CmuxRouting.nextFocus(afterRemoving: "c", mainPillId: hub,
                                    candidates: [(id: "a", lastSeen: 1), (id: "b", lastSeen: 5), (id: "c", lastSeen: 9)]) == "b")
        check("nextFocus: none left → hub", CmuxRouting.nextFocus(afterRemoving: "c", mainPillId: hub, candidates: [(id: "c", lastSeen: 9)]) == hub)
        check("nextFocus: VS Code main → main",
              CmuxRouting.nextFocus(afterRemoving: "c", mainPillId: "integration_claude", candidates: [(id: "a", lastSeen: 1)]) == "integration_claude")
        check("canSend", CmuxRouting.canSend(state: "idle", holdsCard: false) && CmuxRouting.canSend(state: "thinking", holdsCard: false)
              && !CmuxRouting.canSend(state: "approval", holdsCard: false) && !CmuxRouting.canSend(state: "question", holdsCard: false)
              && !CmuxRouting.canSend(state: "idle", holdsCard: true))
        check("canSend false while a dialog may be open in the terminal",
              !CmuxRouting.canSend(state: "working", holdsCard: false, dialogMayBeOpen: true)
              && CmuxRouting.canSend(state: "working", holdsCard: false, dialogMayBeOpen: false))

        print("dialogResolved (marker of a dialog left in the terminal)")
        let permMark = CmuxRouting.DialogMark(tool: "Bash", inputKey: "{\"command\":\"ls\"}")
        let askMark = CmuxRouting.DialogMark(tool: "AskUserQuestion", inputKey: nil)
        check("matching PostToolUse / PostToolUseFailure resolves",
              CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUse", tool: "Bash", inputKey: "{\"command\":\"ls\"}")
              && CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUseFailure", tool: "Bash", inputKey: "{\"command\":\"ls\"}"))
        check("another tool or another input does not resolve",
              !CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUse", tool: "Read", inputKey: "{\"command\":\"ls\"}")
              && !CmuxRouting.dialogResolved(mark: permMark, event: "PostToolUse", tool: "Bash", inputKey: "{\"command\":\"rm\"}"))
        check("Stop, StopFailure, UserPromptSubmit, SessionEnd, SessionStart resolve",
              ["Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "SessionStart"].allSatisfy {
                  CmuxRouting.dialogResolved(mark: permMark, event: $0, tool: "", inputKey: "") })
        check("PreToolUse, Notification, SubagentStop, Interrupt do not resolve",
              ["PreToolUse", "Notification", "SubagentStop", "SubagentStart", "Interrupt", "PermissionRequest"].allSatisfy {
                  !CmuxRouting.dialogResolved(mark: permMark, event: $0, tool: "Bash", inputKey: "{\"command\":\"ls\"}") })
        check("question mark: any PostToolUse of AskUserQuestion resolves, other tools do not",
              CmuxRouting.dialogResolved(mark: askMark, event: "PostToolUse", tool: "AskUserQuestion", inputKey: "anything")
              && !CmuxRouting.dialogResolved(mark: askMark, event: "PostToolUse", tool: "Bash", inputKey: ""))

        print("prune / eviction protection, answer in place, launch focus")
        check("pruneProtected adds the open reply task",
              CmuxRouting.pruneProtected(holdingCard: ["a"], openReplyTask: "b") == ["a", "b"]
              && CmuxRouting.pruneProtected(holdingCard: ["a"], openReplyTask: nil) == ["a"])
        check("evictableIdle drops the open reply task",
              CmuxRouting.evictableIdle(["a", "b"], openReplyTask: "a") == ["b"]
              && CmuxRouting.evictableIdle(["a", "b"], openReplyTask: nil) == ["a", "b"])
        var ev = CmuxRegistry()
        for i in 0..<13 { ev.note(taskId: "t\(i)", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", now: Double(i)) }
        check("eviction never picks the open reply task even when it is the oldest",
              ev.evictionCandidates(idle: CmuxRouting.evictableIdle(["t0", "t1", "t2"], openReplyTask: "t0"), keep: "t12") == ["t1"])
        check("stale prune never picks the open reply task",
              ev.staleTaskIds(now: 99999, protected: CmuxRouting.pruneProtected(holdingCard: [], openReplyTask: "t0")).contains("t0") == false)
        check("answer stays in the reply view of that session only",
              CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "a"), taskId: "a", viewIsPrompt: true)
              && !CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "a"), taskId: "b", viewIsPrompt: true)
              && !CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "a"), taskId: "a", viewIsPrompt: false)
              && !CmuxRouting.answerStaysInReply(prompt: .newChat, taskId: "a", viewIsPrompt: true)
              && !CmuxRouting.answerStaysInReply(prompt: nil, taskId: "a", viewIsPrompt: true))
        check("matched launch takes focus only from the New chat view with no card open",
              CmuxRouting.launchMayTakeFocus(cardOpen: false, promptIsNewChat: true)
              && !CmuxRouting.launchMayTakeFocus(cardOpen: true, promptIsNewChat: true)
              && !CmuxRouting.launchMayTakeFocus(cardOpen: false, promptIsNewChat: false))

        print("recentFolders / firstUUID")
        check("recent: most recent first, deduped",
              CmuxRouting.recentFolders(adding: "/b", to: ["/a", "/b", "/c"]) == ["/b", "/a", "/c"])
        check("recent: capped at 8",
              CmuxRouting.recentFolders(adding: "/n", to: (0..<12).map { "/f\($0)" }).count == 8)
        let u1 = "0A1B2C3D-4e5f-6789-abcd-ef0123456789"
        check("isUUID", CmuxRouting.isUUID(u1) && !CmuxRouting.isUUID("workspace:3") && !CmuxRouting.isUUID("")
              && !CmuxRouting.isUUID(u1 + "0") && !CmuxRouting.isUUID("0A1B2C3D_4e5f-6789-abcd-ef0123456789")
              && !CmuxRouting.isUUID("0G1B2C3D-4e5f-6789-abcd-ef0123456789"))

        // ── EOF of a card, tab title, folder and branch, socket peer ───────────
        print("EOF of a young card")
        check("EOF younger than the late age: answered in the terminal, no marker",
              !CmuxRouting.eofLeavesDialogOpen(arrivedAt: 100, now: 130)
              && !CmuxRouting.eofLeavesDialogOpen(arrivedAt: 100, now: 215))
        check("EOF older than the late age may leave a dialog open",
              CmuxRouting.eofLeavesDialogOpen(arrivedAt: 100, now: 216))

        print("cleanLabel / tab title")
        check("clean: format characters (Cf) dropped",
              CmuxRouting.cleanLabel("a\u{200B}b\u{200E}c\u{200F}d\u{061C}e\u{FEFF}f\u{2060}g\u{E0041}h") == "abcdefgh")
        check("clean: only format characters gives nil", CmuxRouting.cleanLabel("\u{200B}\u{200E}\u{E0041}") == nil)
        check("clean: 60 characters of combining marks are cut at 120 scalars",
              { let t = String(repeating: "e\u{301}\u{302}\u{303}\u{304}", count: 60)
                guard let r = CmuxRouting.cleanLabel(t) else { return false }
                return r.unicodeScalars.count <= 120 && r.count <= 60 && r.unicodeScalars.count >= 100 }())
        check("clean: one cluster of thousands of marks gives nil",
              CmuxRouting.cleanLabel("e" + String(repeating: "\u{301}", count: 5000)) == nil)
        check("clean: the 60 character cap still holds", CmuxRouting.cleanLabel(String(repeating: "é", count: 90))?.count == 60)
        func tabLabel(_ raw: String) -> String? { CmuxRouting.cleanLabel(CmuxRouting.stripLeadingGlyphs(raw)) }
        check("title: Cf in a tab title", tabLabel("✳ Pro\u{200B}eus") == "Proeus")
        check("title: two live sessions with the same title get the suffix",
              CmuxRouting.displayName(base: "Proteus", taskId: "b", existing: [(id: "a", name: "Proteus"), (id: "b", name: "x")]) == "Proteus 2"
              && CmuxRouting.displayName(base: "Proteus", taskId: "c", existing: [(id: "a", name: "Proteus"), (id: "b", name: "Proteus 2")]) == "Proteus 3"
              && CmuxRouting.displayName(base: "Proteus", taskId: "b", existing: [(id: "a", name: "Proteus"), (id: "b", name: "Proteus 2")]) == "Proteus 2"
              && CmuxRouting.displayName(base: "Proteus", taskId: "a", existing: [(id: "a", name: "Proteus")]) == "Proteus")
        check("clean: control characters, trim, nil when empty",
              CmuxRouting.cleanLabel("  Hera\u{1B}[31m\n(Code)\u{7F}\u{85}  ") == "Hera[31m(Code)"
              && CmuxRouting.cleanLabel(" \t\n ") == nil && CmuxRouting.cleanLabel("\u{1B}\u{07}") == nil
              && CmuxRouting.cleanLabel("a\u{202E}b\u{2028}c") == "abc")
        check("clean: capped at 60",
              CmuxRouting.cleanLabel(String(repeating: "x", count: 100))?.count == 60)
        check("glyph prefix stripped",
              CmuxRouting.stripLeadingGlyphs("◐ Hera (Code Reviewer)") == "Hera (Code Reviewer)"
              && CmuxRouting.stripLeadingGlyphs("✳ Zeus") == "Zeus"
              && CmuxRouting.stripLeadingGlyphs("✶  ⠂ Ana") == "Ana"
              && CmuxRouting.stripLeadingGlyphs("Hera") == "Hera"
              && CmuxRouting.stripLeadingGlyphs("3rd run") == "3rd run"
              && CmuxRouting.stripLeadingGlyphs("★ ✦") == "")
        check("title of a tab, glyph removed", tabLabel("✳ Hera (Code Reviewer) [re-review 2]") == "Hera (Code Reviewer) [re-review 2]")
        check("title that is only glyphs or control characters is nil", tabLabel("✳ \u{0007}") == nil && tabLabel("") == nil)
        check("title: control characters removed and capped",
              tabLabel("A\u{1b}[2Jb\n\(String(repeating: "z", count: 90))")?.count == 60 && tabLabel("A\u{1b}[2Jb") == "A[2Jb")
        check("folder pill name: cleaned folder, else the fallback",
              CmuxRouting.folderPillName(cwd: "/Users/x/proj", fallback: "Session") == "proj"
              && CmuxRouting.folderPillName(cwd: "/Users/x/pro\u{202E}j\u{200B}", fallback: "Session") == "proj"
              && CmuxRouting.folderPillName(cwd: "", fallback: "Session") == "Session"
              && CmuxRouting.folderPillName(cwd: "/", fallback: "Session") == "Session"
              && CmuxRouting.folderPillName(cwd: "/x/\u{202E}\u{200B}", fallback: "Session") == "Session"
              && CmuxRouting.folderPillName(cwd: "/x/" + String(repeating: "q", count: 200), fallback: "S").count == 60)
        check("refresh throttled to once per 5 s",
              CmuxRouting.metaRefreshDue(last: nil, now: 10) && !CmuxRouting.metaRefreshDue(last: 10, now: 14.9)
              && CmuxRouting.metaRefreshDue(last: 10, now: 15) && CmuxRouting.metaRefreshDue(last: 10, now: 5))

        print("git branch")
        let hash = "0123456789abcdef0123456789abcdef01234567"
        check("HEAD: branch ref", CmuxRouting.branchName(fromHEAD: "ref: refs/heads/feat/cmux-integration\n") == "feat/cmux-integration")
        check("HEAD: detached gives 7 characters", CmuxRouting.branchName(fromHEAD: hash + "\n") == "0123456")
        check("HEAD: garbage, other ref, short hash, empty are nil",
              CmuxRouting.branchName(fromHEAD: "banana") == nil && CmuxRouting.branchName(fromHEAD: "ref: refs/tags/v1") == nil
              && CmuxRouting.branchName(fromHEAD: "0123456") == nil && CmuxRouting.branchName(fromHEAD: "") == nil
              && CmuxRouting.branchName(fromHEAD: "ref: refs/heads/\n") == nil)
        check("HEAD: control characters stripped, capped at 60",
              CmuxRouting.branchName(fromHEAD: "ref: refs/heads/a\u{1B}b") == "ab"
              && CmuxRouting.branchName(fromHEAD: "ref: refs/heads/" + String(repeating: "q", count: 90))?.count == 60)
        check("gitdir pointer: absolute, relative, garbage",
              CmuxRouting.gitDirectory(fromPointer: "gitdir: /r/.git/worktrees/w\n", base: "/x") == "/r/.git/worktrees/w"
              && CmuxRouting.gitDirectory(fromPointer: "gitdir: ../r/.git/worktrees/w", base: "/x/y") == "/x/y/../r/.git/worktrees/w"
              && CmuxRouting.gitDirectory(fromPointer: "hello", base: "/x") == nil
              && CmuxRouting.gitDirectory(fromPointer: "gitdir:", base: "/x") == nil)
        let fm = FileManager.default
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("coucou-git-\(getpid())")
        try? fm.removeItem(atPath: tmp)
        func write(_ path: String, _ text: String) {
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
        write(tmp + "/repo/.git/HEAD", "ref: refs/heads/feat/x\n")
        try? fm.createDirectory(atPath: tmp + "/repo/a/b/c", withIntermediateDirectories: true)
        check("branch: walks up from a subfolder", CmuxRouting.gitBranch(cwd: tmp + "/repo/a/b/c") == "feat/x")
        check("branch: at the repo root", CmuxRouting.gitBranch(cwd: tmp + "/repo") == "feat/x")
        write(tmp + "/det/.git/HEAD", hash + "\n")
        check("branch: detached HEAD", CmuxRouting.gitBranch(cwd: tmp + "/det") == "0123456")
        write(tmp + "/main/.git/worktrees/wt/HEAD", "ref: refs/heads/wt-branch\n")
        write(tmp + "/wt/.git", "gitdir: " + tmp + "/main/.git/worktrees/wt\n")
        check("branch: .git file pointing to a worktree gitdir", CmuxRouting.gitBranch(cwd: tmp + "/wt") == "wt-branch")
        write(tmp + "/relwt/.git", "gitdir: ../main/.git/worktrees/wt\n")
        check("branch: relative gitdir pointer", CmuxRouting.gitBranch(cwd: tmp + "/relwt") == "wt-branch")
        write(tmp + "/bad/.git/HEAD", "###\u{1}garbage")
        check("branch: garbage HEAD is nil", CmuxRouting.gitBranch(cwd: tmp + "/bad") == nil)
        write(tmp + "/badptr/.git", "not a pointer")
        check("branch: garbage .git file is nil", CmuxRouting.gitBranch(cwd: tmp + "/badptr") == nil)
        write(tmp + "/nohead/.git/config", "x")
        check("branch: .git without HEAD is nil", CmuxRouting.gitBranch(cwd: tmp + "/nohead") == nil)
        check("branch: not absolute or missing folder is nil",
              CmuxRouting.gitBranch(cwd: "relative/dir") == nil && CmuxRouting.gitBranch(cwd: "") == nil)
        check("branch: a pointer is followed once only",
              { write(tmp + "/loop/.git", "gitdir: " + tmp + "/loop2\n")
                write(tmp + "/loop2/.git", "gitdir: " + tmp + "/loop\n")
                return CmuxRouting.gitBranch(cwd: tmp + "/loop") == nil }())
        // Symlinks, FIFOs and gitdir targets
        write(tmp + "/real/HEAD", "ref: refs/heads/secret\n")
        try? fm.createDirectory(atPath: tmp + "/symhead/.git", withIntermediateDirectories: true)
        symlink(tmp + "/real/HEAD", tmp + "/symhead/.git/HEAD")
        check("branch: a symlinked HEAD is refused", CmuxRouting.gitBranch(cwd: tmp + "/symhead") == nil)
        write(tmp + "/ptrtarget/x/.git/HEAD", "ref: refs/heads/linked\n")
        try? fm.createDirectory(atPath: tmp + "/symptr", withIntermediateDirectories: true)
        write(tmp + "/ptrreal", "gitdir: " + tmp + "/ptrtarget/x/.git\n")
        symlink(tmp + "/ptrreal", tmp + "/symptr/.git")
        check("branch: a symlinked .git pointer file is refused", CmuxRouting.gitBranch(cwd: tmp + "/symptr") == nil)
        write(tmp + "/odd/target/HEAD", "ref: refs/heads/odd\n")
        write(tmp + "/oddptr/.git", "gitdir: " + tmp + "/odd/target\n")
        check("branch: a gitdir that is not a .git folder is refused", CmuxRouting.gitBranch(cwd: tmp + "/oddptr") == nil)
        write(tmp + "/bare.git/HEAD", "ref: refs/heads/bare\n")
        write(tmp + "/bareptr/.git", "gitdir: " + tmp + "/bare.git\n")
        check("branch: a gitdir ending in .git is accepted", CmuxRouting.gitBranch(cwd: tmp + "/bareptr") == "bare")
        check("gitdir plausibility",
              CmuxRouting.isPlausibleGitDir("/r/.git") && CmuxRouting.isPlausibleGitDir("/r/.git/worktrees/w")
              && CmuxRouting.isPlausibleGitDir("/r/x.git") && !CmuxRouting.isPlausibleGitDir("/etc")
              && !CmuxRouting.isPlausibleGitDir("/r/.git/../etc") && !CmuxRouting.isPlausibleGitDir("/r/.github")
              && !CmuxRouting.isPlausibleGitDir("/"))
        try? fm.createDirectory(atPath: tmp + "/fifohead/.git", withIntermediateDirectories: true)
        mkfifo(tmp + "/fifohead/.git/HEAD", 0o600)
        let fifoStart = Date()
        let fifoBranch = CmuxRouting.gitBranch(cwd: tmp + "/fifohead")
        check("branch: a FIFO named HEAD returns nil, promptly", fifoBranch == nil && Date().timeIntervalSince(fifoStart) < 2)
        try? fm.createDirectory(atPath: tmp + "/fifoptr", withIntermediateDirectories: true)
        mkfifo(tmp + "/fifoptr/.git", 0o600)
        let fifoStart2 = Date()
        let fifoBranch2 = CmuxRouting.gitBranch(cwd: tmp + "/fifoptr")
        check("branch: a FIFO named .git returns nil, promptly", fifoBranch2 == nil && Date().timeIntervalSince(fifoStart2) < 2)
        try? fm.removeItem(atPath: tmp)
        check("folder line: folder and branch, folder alone, nothing",
              CmuxRouting.folderLine(cwd: "/Users/x/Dev/coucou", branch: "feat/cmux-integration") == "coucou (feat/cmux-integration)"
              && CmuxRouting.folderLine(cwd: "/Users/x/Dev/coucou/", branch: nil) == "coucou"
              && CmuxRouting.folderLine(cwd: "/Users/x/Dev/coucou", branch: "") == "coucou"
              && CmuxRouting.folderLine(cwd: "", branch: "main") == nil
              && CmuxRouting.folderLine(cwd: "/", branch: "main") == nil)

        print("socket peer (LOCAL_PEERTOKEN, audit token)")
        let sockPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("cp\(getpid()).sock")
        unlink(sockPath)
        let lfd = socket(AF_UNIX, SOCK_STREAM, 0)
        var la = sockaddr_un()
        la.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &la.sun_path) { raw in
            for (i, b) in Array(sockPath.utf8).enumerated() { raw[i] = b }
        }
        let bound = withUnsafePointer(to: &la) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(lfd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0 && listen(lfd, 4) == 0
        if bound && CmuxRouting.isValidSocketPath(sockPath) {
            let token = CmuxRouting.socketPeerAuditToken(path: sockPath)
            check("audit token of a local listener is 32 bytes", token?.count == 32)
            check("audit token names this process", token.flatMap { CmuxRouting.pid(ofAuditToken: $0) } == getpid())
            check("a listener that is not cmux is refused", !CmuxRouting.socketPeerIsCmux(path: sockPath))
        } else {
            print("  - skipped: temp socket path not usable here")
        }
        close(lfd)
        unlink(sockPath)
        check("peer: missing socket, bad path give no token",
              CmuxRouting.socketPeerAuditToken(path: "/tmp/does-not-exist-\(getpid()).sock") == nil
              && CmuxRouting.socketPeerAuditToken(path: "relative.sock") == nil && !CmuxRouting.socketPeerIsCmux(path: ""))
        check("an unreadable or short audit token fails closed",
              !CmuxRouting.processIsCmux(auditToken: Data()) && !CmuxRouting.processIsCmux(auditToken: Data(count: 31))
              && !CmuxRouting.processIsCmux(auditToken: Data(count: 32)) && CmuxRouting.pid(ofAuditToken: Data(count: 5)) == nil)
        check("verification reuse: fresh inside 60 s, stale after, never after a backwards clock, none without a stamp",
              CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 100)
              && CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 159.9)
              && !CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 160)
              && !CmuxRouting.verificationIsFresh(verifiedAt: 100, now: 99)
              && !CmuxRouting.verificationIsFresh(verifiedAt: nil, now: 100))
        }

        // ── launchers ──────────────────────────────────────────────────────────
        print("CmuxLauncher")
        check("four launchers in order: Claude, Codex, Grok, Agy",
              CmuxLauncher.all.map { $0.name } == ["Claude", "Codex", "Grok", "Agy"]
              && CmuxLauncher.all.map { $0.id.rawValue } == ["claude", "codex", "grok", "agy"])
        check("default commands",
              CmuxLauncher.all.map { $0.defaultCommand }
                == ["claude --dangerously-skip-permissions", "codex", "grok", "agy"])
        check("every default command passes the launch command validation",
              CmuxLauncher.all.allSatisfy { CmuxRouting.isValidLaunchCommand($0.defaultCommand) })
        check("prompt flags: only Agy has one (-i)",
              CmuxLauncher.all.map { $0.promptFlag } == ["", "", "", "-i"])
        check("only Claude reports its session start",
              CmuxLauncher.all.map { $0.reportsSessionStart } == [true, false, false, false])
        check("defaults keys are distinct, the legacy key is not one of them",
              Set(CmuxLauncher.all.map { $0.defaultsKey }).count == 4
              && !CmuxLauncher.all.map { $0.defaultsKey }.contains(CmuxLauncher.legacyDefaultsKey))
        check("launcher(id) finds each one", CmuxLauncher.Id.allCases.allSatisfy { CmuxLauncher.launcher($0).id == $0 })

        print("CmuxLauncher.resolvedCommand (migration)")
        let claude = CmuxLauncher.claude
        check("nothing stored → new Claude default", claude.resolvedCommand(stored: nil, legacy: nil) == "claude --dangerously-skip-permissions")
        check("an explicitly stored old `claude` stays `claude` (no silent permission skipping)",
              claude.resolvedCommand(stored: nil, legacy: "claude") == "claude"
              && claude.resolvedCommand(stored: "claude", legacy: nil) == "claude"
              && claude.resolvedCommand(stored: "claude", legacy: "claude --model=opus") == "claude")
        check("any other old value is kept as the Claude command",
              claude.resolvedCommand(stored: nil, legacy: "claude --model=opus") == "claude --model=opus"
              && claude.resolvedCommand(stored: nil, legacy: "Claude") == "Claude"
              && claude.resolvedCommand(stored: nil, legacy: "/opt/bin/claude") == "/opt/bin/claude")
        check("an invalid old value is not kept", claude.resolvedCommand(stored: nil, legacy: "claude; rm -rf /") == claude.defaultCommand)
        check("a stored new value wins over the legacy one",
              claude.resolvedCommand(stored: "claude -x", legacy: "claude --model=opus") == "claude -x")
        check("a stored invalid new value falls back", claude.resolvedCommand(stored: "a;b", legacy: nil) == claude.defaultCommand)
        let codex = CmuxLauncher.launcher(.codex)
        check("the legacy command never reaches another launcher",
              codex.resolvedCommand(stored: nil, legacy: "claude --model=opus") == "codex"
              && codex.resolvedCommand(stored: "codex --x", legacy: nil) == "codex --x")

        print("CmuxLauncher.acceptsPrompt / launchLine")
        let agy = CmuxLauncher.launcher(.agy)
        let grok = CmuxLauncher.launcher(.grok)
        let W = "/var/folders/ab/cd_ef-1234/T/coucou-launch/launch.sh"
        let P = "/var/folders/ab/cd_ef-1234/T/coucou-launch/prompt-0123456789abcdef0123456789abcdef.txt"
        check("launch line: /bin/sh, wrapper, prompt file, command; Agy adds -i last",
              codex.launchLine(command: "codex", wrapperPath: W, promptFile: P) == "/bin/sh \(W) \(P) codex"
              && grok.launchLine(command: "grok", wrapperPath: W, promptFile: P) == "/bin/sh \(W) \(P) grok"
              && agy.launchLine(command: "agy", wrapperPath: W, promptFile: P) == "/bin/sh \(W) \(P) agy -i"
              && codex.launchLine(command: "/opt/bin/codex --model=x", wrapperPath: W, promptFile: P)
                == "/bin/sh \(W) \(P) /opt/bin/codex --model=x")
        let lines = [codex, grok, agy].compactMap { $0.launchLine(command: $0.defaultCommand, wrapperPath: W, promptFile: P) }
        check("every launch line stays in the launch command charset (same meaning in sh, bash, zsh, fish)",
              lines.count == 3 && lines.allSatisfy { l in
                  l.utf8.allSatisfy { c in
                      (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
                          || [0x20, 0x5F, 0x2E, 0x2F, 0x3D, 0x3A, 0x2D].contains(c)
                  }
              })
        check("an invalid command produces no line",
              codex.launchLine(command: "codex; id", wrapperPath: W, promptFile: P) == nil
              && codex.launchLine(command: "", wrapperPath: W, promptFile: P) == nil
              && codex.launchLine(command: "A=b codex", wrapperPath: W, promptFile: P) == nil)
        check("an unsafe wrapper or prompt path produces no line",
              codex.launchLine(command: "codex", wrapperPath: "/tmp/a b/launch.sh", promptFile: P) == nil
              && codex.launchLine(command: "codex", wrapperPath: W, promptFile: "/tmp/it's") == nil
              && codex.launchLine(command: "codex", wrapperPath: W, promptFile: "relative/p.txt") == nil)
        check("Claude never gets a launch line (its prompt is typed after SessionStart)",
              claude.launchLine(command: "claude", wrapperPath: W, promptFile: P) == nil)
        check("isSafePath: charset, absolute, no space, no .., bounded",
              CmuxLaunchFiles.isSafePath(W) && CmuxLaunchFiles.isSafePath("/a")
              && !CmuxLaunchFiles.isSafePath("") && !CmuxLaunchFiles.isSafePath("a/b")
              && !CmuxLaunchFiles.isSafePath("/a b") && !CmuxLaunchFiles.isSafePath("/a/../b")
              && !CmuxLaunchFiles.isSafePath("/a'b") && !CmuxLaunchFiles.isSafePath("/a\\b")
              && !CmuxLaunchFiles.isSafePath("/a$b") && !CmuxLaunchFiles.isSafePath("/a\nb")
              && !CmuxLaunchFiles.isSafePath("/ação")
              && !CmuxLaunchFiles.isSafePath("/" + String(repeating: "a", count: 400)))
        check("a prompt starting with a dash is refused by every command line launcher",
              !codex.acceptsPrompt("-x") && !grok.acceptsPrompt("--help") && !agy.acceptsPrompt("-p hi")
              && !codex.acceptsPrompt("-\u{0301}x"))
        check("a dash inside the prompt is fine", codex.acceptsPrompt("fix a - b") && agy.acceptsPrompt("x-y"))
        check("a prompt that is a whole subcommand name is refused for codex and grok, not when longer",
              !codex.acceptsPrompt("exec") && !codex.acceptsPrompt("resume") && !grok.acceptsPrompt("login")
              && !grok.acceptsPrompt("update") && codex.acceptsPrompt("exec the tests") && grok.acceptsPrompt("login page")
              && codex.acceptsPrompt("Exec") && agy.acceptsPrompt("exec"))
        check("Claude accepts any prompt (it is typed, not parsed)", claude.acceptsPrompt("-x") && claude.acceptsPrompt("exec"))

        print("CmuxLaunchFiles (private directory, files, wrapper)")
        func runProcess(_ exe: String, _ args: [String]) -> (status: Int32, out: [UInt8])? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, Array(out))
        }
        func modeOf(_ path: String) -> UInt16? {
            var st = stat()
            return lstat(path, &st) == 0 ? st.st_mode & 0o7777 : nil
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-launch-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        print("  real per user temporary directory: \(FileManager.default.temporaryDirectory.path)")
        check("the per user temporary directory passes the path check",
              CmuxLaunchFiles.isSafePath(FileManager.default.temporaryDirectory.standardizedFileURL.path + "/coucou-launch/launch.sh"))
        if let prep = CmuxLaunchFiles.prepare(prompt: "hello", baseDirectory: base) {
            let dir = (prep.wrapperPath as NSString).deletingLastPathComponent
            check("directory is named coucou-launch with mode 0700", dir.hasSuffix("/coucou-launch") && modeOf(dir) == 0o700)
            check("wrapper has mode 0700 and the exact script text",
                  modeOf(prep.wrapperPath) == 0o700
                  && (try? String(contentsOfFile: prep.wrapperPath, encoding: .utf8)) == CmuxLaunchFiles.wrapperScript)
            check("prompt file has mode 0600, a random name, and the exact prompt",
                  modeOf(prep.promptFile) == 0o600 && prep.promptFile.hasPrefix(dir + "/prompt-")
                  && (try? String(contentsOfFile: prep.promptFile, encoding: .utf8)) == "hello")
            let second = CmuxLaunchFiles.prepare(prompt: "hello", baseDirectory: base)
            check("a second launch gets another prompt file and the same wrapper",
                  second != nil && second!.promptFile != prep.promptFile && second!.wrapperPath == prep.wrapperPath)
            // Stale files: older than 10 minutes go at the next launch, fresh ones stay.
            let old = dir + "/old.txt", fresh = dir + "/fresh.txt"
            FileManager.default.createFile(atPath: old, contents: Data("x".utf8))
            FileManager.default.createFile(atPath: fresh, contents: Data("x".utf8))
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-700)], ofItemAtPath: old)
            _ = CmuxLaunchFiles.prepare(prompt: "again", baseDirectory: base)
            check("files older than 10 minutes are deleted at the next launch, fresh ones are kept",
                  !FileManager.default.fileExists(atPath: old) && FileManager.default.fileExists(atPath: fresh)
                  && FileManager.default.fileExists(atPath: prep.promptFile))
            CmuxLaunchFiles.discard(prep.promptFile)
            check("discard removes the prompt file", !FileManager.default.fileExists(atPath: prep.promptFile))
        } else { check("prepare works in a private base directory", false) }
        check("an empty prompt prepares nothing", CmuxLaunchFiles.prepare(prompt: "", baseDirectory: base) == nil)
        // Fail closed: a directory with group/other permission, a symlink, a base path with a space.
        let loose = base.appendingPathComponent("loose")
        try? FileManager.default.createDirectory(at: loose.appendingPathComponent("coucou-launch"), withIntermediateDirectories: true)
        chmod(loose.path + "/coucou-launch", 0o755)
        check("a coucou-launch directory with group/other permission fails closed",
              CmuxLaunchFiles.prepare(prompt: "x", baseDirectory: loose) == nil)
        let linkBase = base.appendingPathComponent("linked")
        try? FileManager.default.createDirectory(at: linkBase, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(atPath: linkBase.path + "/coucou-launch", withDestinationPath: base.path)
        check("a coucou-launch symlink fails closed", CmuxLaunchFiles.prepare(prompt: "x", baseDirectory: linkBase) == nil)
        let spaced = base.appendingPathComponent("with space")
        try? FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        check("a temporary directory path with a space fails closed",
              CmuxLaunchFiles.prepare(prompt: "x", baseDirectory: spaced) == nil
              && !FileManager.default.fileExists(atPath: spaced.path + "/coucou-launch"))

        // The real wrapper under /bin/sh, with a stub agent that writes its argv (NUL separated) to argv.bin next to itself.
        print("CmuxLaunchFiles.wrapperScript (real /bin/sh, stub agent)")
        let stubDir = base.appendingPathComponent("stub")
        try? FileManager.default.createDirectory(at: stubDir, withIntermediateDirectories: true)
        let stub = stubDir.path + "/agent"
        let outFile = stubDir.path + "/argv.bin"
        FileManager.default.createFile(atPath: stub, contents: Data("#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$(dirname \"$0\")/argv.bin\"\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        let promptCases: [(String, String)] = [
            ("plain", "fix the login bug"),
            ("quotes", "don't \"x\" ''' ` '"),
            ("backslashes", "a\\b \\\\ \\n \\' \\\""),
            ("dollar parens", "$(touch \(stubDir.path)/PWNED) $HOME ${PATH} $((1+1))"),
            ("backticks", "`touch \(stubDir.path)/PWNED2` ``"),
            ("trailing backslash", "ends with a backslash \\"),
            ("leading space", "  leading spaces"),
            ("shell syntax", "a; b | c && d > e < f & # g * ? [a-z] ~ !! {a,b}"),
            ("looks like an option", "x --dangerously-skip-permissions -i"),
            ("unicode", "olá, ação ✓ 日本語 🙂 e\u{0301} \u{00E1}"),
            ("embedded newline", "line one\nline two"),
            ("trailing newlines", "text\n\n"),
            ("only a quote", "'"),
            ("8000 characters", String(String(repeating: "word 'q' \\ $x ", count: 800).prefix(CmuxRouting.maxPromptLength))),
        ]
        var wrapperOK = true
        var wrapperFirstBad = ""
        for (label, text) in promptCases {
            // Newlines are stripped upstream by preparePrompt; the file is written raw here to show it holds anyway.
            guard let prep = CmuxLaunchFiles.prepare(prompt: "seed", baseDirectory: base),
                  (try? Data(text.utf8).write(to: URL(fileURLWithPath: prep.promptFile))) != nil else {
                wrapperOK = false; wrapperFirstBad = label; break
            }
            try? FileManager.default.removeItem(atPath: outFile)
            guard let r = runProcess("/bin/sh", [prep.wrapperPath, prep.promptFile, stub, "-i"]) else {
                wrapperOK = false; wrapperFirstBad = label; break
            }
            let got = (try? Data(contentsOf: URL(fileURLWithPath: outFile))).map { Array($0) } ?? []
            let want = Array("-i".utf8) + [0] + Array(text.utf8) + [0]
            if r.status != 0 || got != want || FileManager.default.fileExists(atPath: prep.promptFile) {
                wrapperOK = false; wrapperFirstBad = label; break
            }
        }
        check("wrapper under /bin/sh passes each prompt as ONE last argument, byte for byte, and removes the file"
              + " (\(promptCases.count) cases)" + (wrapperOK ? "" : " (first mismatch: \(wrapperFirstBad))"), wrapperOK)
        check("no command was executed by the dollar paren and backtick prompts",
              !FileManager.default.fileExists(atPath: stubDir.path + "/PWNED")
              && !FileManager.default.fileExists(atPath: stubDir.path + "/PWNED2"))
        try? FileManager.default.removeItem(atPath: outFile)
        if let missing = runProcess("/bin/sh", [W, "/nonexistent/prompt.txt", stub]) {
            check("a missing prompt file: the wrapper exits and starts nothing", missing.status != 0 && !FileManager.default.fileExists(atPath: outFile))
        }
        if let wrapper = CmuxLaunchFiles.prepare(prompt: "seed", baseDirectory: base)?.wrapperPath,
           let missing = runProcess("/bin/sh", [wrapper, "/nonexistent/prompt.txt", stub]) {
            check("the real wrapper with a missing prompt file exits 1 and starts nothing",
                  missing.status == 1 && !FileManager.default.fileExists(atPath: outFile))
        }
        // The typed line, read by each shell with -c: hostile prompt, delivered as one argument.
        func lineRun(_ shell: String, _ args: [String]) -> Bool {
            guard let prep = CmuxLaunchFiles.prepare(prompt: "seed", baseDirectory: base) else { return false }
            let text = "it's $(id) `id` \\' \\\\ ; & | > done \\"
            guard (try? Data(text.utf8).write(to: URL(fileURLWithPath: prep.promptFile))) != nil else { return false }
            let command = stub
            guard let line = CmuxLauncher.launcher(.agy).launchLine(command: command, wrapperPath: prep.wrapperPath, promptFile: prep.promptFile)
            else { return false }
            try? FileManager.default.removeItem(atPath: outFile)
            guard let r = runProcess(shell, args + [line]), r.status == 0 else { return false }
            let got = (try? Data(contentsOf: URL(fileURLWithPath: outFile))).map { Array($0) } ?? []
            return got == Array("-i".utf8) + [0] + Array(text.utf8) + [0] && !FileManager.default.fileExists(atPath: prep.promptFile)
        }
        for (shell, args) in [("/bin/zsh", ["-f", "-c"]), ("/bin/bash", ["-c"]), ("/bin/sh", ["-c"])] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { print("  - skipped: \(shell) not installed"); continue }
            check("the typed line run by \(shell) -c delivers the hostile prompt as one argument", lineRun(shell, args))
        }
        if let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            check("the typed line run by \(fish) -c delivers the hostile prompt as one argument", lineRun(fish, ["-c"]))
        } else {
            print("  - fish NOT RUN: neither /opt/homebrew/bin/fish nor /usr/local/bin/fish exists on this machine")
        }

        // ── workspaces: task id, folded state, main surface ────────────────────
        let wsA = "11111111-2222-3333-4444-555555555555"
        let wsB = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let sfA1 = "0A000000-0000-0000-0000-000000000001"
        let sfA2 = "0A000000-0000-0000-0000-000000000002"
        let sfB1 = "0B000000-0000-0000-0000-000000000001"
        let sfShell = "0C000000-0000-0000-0000-000000000009"
        print("CmuxRouting.taskId per workspace")
        check("workspace id present → workspace key",
              CmuxRouting.taskId(payload: ["cmux_surface_id": sfA1, "cmux_workspace_id": wsB, "session_id": "s"])
                == "agent_cmux_aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        check("two surfaces of one workspace → same id",
              CmuxRouting.taskId(payload: ["cmux_surface_id": sfA1, "cmux_workspace_id": wsA])
                == CmuxRouting.taskId(payload: ["cmux_surface_id": sfA2, "cmux_workspace_id": wsA]))
        check("no workspace → old surface key",
              CmuxRouting.taskId(payload: ["cmux_surface_id": sfA1]) == "agent_cmux_0a000000-0000-0000-0000-000000000001")
        check("junk workspace id → old surface key",
              CmuxRouting.taskId(payload: ["cmux_surface_id": sfA1, "cmux_workspace_id": "workspace:3"])
                == "agent_cmux_0a000000-0000-0000-0000-000000000001")
        check("workspace id but no usable surface or session → nil",
              CmuxRouting.taskId(payload: ["cmux_workspace_id": wsA, "session_id": "unknown"]) == nil)
        check("surfaceKey is the old per surface key",
              CmuxRouting.surfaceKey(payload: ["cmux_surface_id": sfA2, "cmux_workspace_id": wsA]) == "0a000000-0000-0000-0000-000000000002"
              && CmuxRouting.surfaceKey(payload: ["session_id": "s1"]) == nil)
        check("workspaceKey lowercases a UUID only",
              CmuxRouting.workspaceKey(wsB) == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" && CmuxRouting.workspaceKey("x") == nil)

        print("CmuxRouting.foldedState")
        let order = ["approval", "question", "working", "searching", "thinking", "error", "ratelimit", "finished", "idle"]
        var orderOK = true
        for i in 0..<order.count { for j in i..<order.count {
            if CmuxRouting.foldedState([order[j], order[i]]) != order[i] || CmuxRouting.foldedState([order[i], order[j]]) != order[i] { orderOK = false }
        } }
        check("every pair follows the priority approval > question > working > searching > thinking > error > ratelimit > finished > idle", orderOK)
        check("empty → idle", CmuxRouting.foldedState([]) == "idle")
        check("unknown raw value → idle, and loses to a known state",
              CmuxRouting.foldedState(["bogus"]) == "idle" && CmuxRouting.foldedState(["bogus", "finished"]) == "finished")

        print("CmuxRouting.mainSurfaceKey")
        let cand: [(key: String, index: Int?, startedAt: TimeInterval?)] = [("c", 2, 5), ("a", 1, 9), ("b", 0, 7)]
        check("lowest index", CmuxRouting.mainSurfaceKey(current: nil, candidates: cand) == "b")
        check("sticky while nobody sits at a lower index",
              CmuxRouting.mainSurfaceKey(current: "b", candidates: cand) == "b"
              && CmuxRouting.mainSurfaceKey(current: "x", candidates: [("x", 1, 9), ("y", 1, 3)]) == "x")
        check("a lower index takes the main role back (a /clear in the main agent hands it to a helper and back)",
              CmuxRouting.mainSurfaceKey(current: "a", candidates: cand) == "b")
        check("current gone → first by order", CmuxRouting.mainSurfaceKey(current: "zzz", candidates: cand) == "b")
        check("same index → oldest startedAt",
              CmuxRouting.mainSurfaceKey(current: nil, candidates: [("x", 1, 9), ("y", 1, 3)]) == "y")
        check("no index → startedAt, then key",
              CmuxRouting.mainSurfaceKey(current: nil, candidates: [("x", nil, 9), ("y", nil, 3)]) == "y"
              && CmuxRouting.mainSurfaceKey(current: nil, candidates: [("q", nil, nil), ("p", nil, nil)]) == "p")
        check("no candidates → nil", CmuxRouting.mainSurfaceKey(current: "a", candidates: []) == nil)
        check("a current without index yields to a surface with one",
              CmuxRouting.mainSurfaceKey(current: "h", candidates: [("h", nil, 1), ("m", 0, 2)]) == "m")
        check("a current without index stays when nobody has one",
              CmuxRouting.mainSurfaceKey(current: "h", candidates: [("h", nil, 5), ("m", nil, 2)]) == "h")

        print("CmuxRouting.discoveryDue / needsDialogMark / surfaceLabels")
        check("first run is due", CmuxRouting.discoveryDue(last: nil, now: 0, inFlight: false))
        check("inside 5 s is not due", !CmuxRouting.discoveryDue(last: 100, now: 104.9, inFlight: false))
        check("at 5 s is due", CmuxRouting.discoveryDue(last: 100, now: 105, inFlight: false))
        check("in flight is never due", !CmuxRouting.discoveryDue(last: nil, now: 500, inFlight: true))
        check("clock going backwards is due", CmuxRouting.discoveryDue(last: 100, now: 50, inFlight: false))
        check("heard surface: no mark", !CmuxRouting.needsDialogMark(heard: true))
        check("never heard: mark, whatever the session file says about its lifecycle", CmuxRouting.needsDialogMark(heard: false))
        check("labels: short title, fallback, numbered duplicates",
              CmuxRouting.surfaceLabels(titles: ["Proteus (Swift) [x]", nil, "Proteus", nil], fallback: "Session")
                == ["Proteus", "Session", "Proteus 2", "Session 2"])

        // ── parseTree ──────────────────────────────────────────────────────────
        print("CmuxRouting.parseTree")
        func surfaceJSON(_ id: String, _ title: String, _ type: String = "terminal", _ index: Int) -> String {
            "{\"id\":\"\(id)\",\"title\":\"\(title)\",\"type\":\"\(type)\",\"index\":\(index),\"focused\":false,\"tty\":\"ttys000\"}"
        }
        let treeJSON = """
        {"active":{"window_id":"W"},"caller":{},"windows":[{"id":"w1","index":0,"workspaces":[
          {"id":"\(wsA)","title":"core.joinads.me","index":0,"selected":true,"pinned":false,"layout":{"children":[]},
           "panes":[{"id":"p1","surfaces":[\(surfaceJSON(sfA1, "✳ Diagnóstico e plano", "terminal", 0))]},
                    {"id":"p2","surfaces":[\(surfaceJSON(sfA2, "Proteus (Swift) [names]", "terminal", 1)),\(surfaceJSON(sfShell, "~", "browser", 2))]}]},
          {"id":"\(wsB)","title":"coucou","index":1,"selected":false,"panes":[{"surfaces":[\(surfaceJSON(sfB1, "claude", "terminal", 0))]}]}
        ]}]}
        """
        let tree = CmuxRouting.parseTree(treeJSON)
        check("real shape: two workspaces in order", tree?.map { $0.title } == ["core.joinads.me", "coucou"] && tree?.map { $0.index } == [0, 1])
        check("surfaces of all panes, by workspace wide index", tree?.first?.surfaces.map { $0.index } == [0, 1, 2])
        check("glyph prefix stripped from a title", tree?.first?.surfaces.first?.title == "Diagnóstico e plano")
        check("non terminal surfaces are kept with their type", tree?.first?.surfaces.last?.type == "browser")
        check("selected is read", tree?.first?.selected == true && tree?.last?.selected == false)
        check("result wrapper is accepted",
              CmuxRouting.parseTree("{\"ok\":true,\"result\":" + treeJSON + "}")?.count == 2)
        let badIds = """
        {"windows":[{"workspaces":[{"id":"not-a-uuid","title":"x","index":0,"panes":[]},
          {"id":"\(wsA)","title":"ok","index":1,"panes":[{"surfaces":[{"id":"bad","type":"terminal","index":0},\(surfaceJSON(sfA1, "t", "terminal", 1))]}]}]}]}
        """
        let bad = CmuxRouting.parseTree(badIds)
        check("a workspace or surface with a bad UUID is dropped", bad?.count == 1 && bad?.first?.surfaces.count == 1)
        let dirty = CmuxRouting.parseTree("""
        {"windows":[{"workspaces":[{"id":"\(wsA)","title":"a\\u202Eb\\u0007c\\u200Bd","index":0,"panes":[]}]}]}
        """)
        check("bidi, control and format characters are removed from titles", dirty?.first?.title == "abcd")
        var manyWs = "{\"windows\":[{\"workspaces\":["
        manyWs += (0..<80).map { i in
            let id = String(format: "%08X-0000-0000-0000-000000000000", i + 1)
            return "{\"id\":\"\(id)\",\"title\":\"w\(i)\",\"index\":\(i),\"panes\":[]}"
        }.joined(separator: ",")
        manyWs += "]}]}"
        check("at most 64 workspaces", CmuxRouting.parseTree(manyWs)?.count == 64)
        var manySf = "{\"windows\":[{\"workspaces\":[{\"id\":\"\(wsA)\",\"title\":\"w\",\"index\":0,\"panes\":[{\"surfaces\":["
        manySf += (0..<50).map { i in surfaceJSON(String(format: "%08X-0000-0000-0000-000000000000", i + 1), "t", "terminal", i) }.joined(separator: ",")
        manySf += "]}]}]}]}"
        check("at most 32 surfaces per workspace", CmuxRouting.parseTree(manySf)?.first?.surfaces.count == 32)
        check("garbage → nil",
              CmuxRouting.parseTree("not json") == nil && CmuxRouting.parseTree("[1,2]") == nil
              && CmuxRouting.parseTree("{\"foo\":1}") == nil && CmuxRouting.parseTree("") == nil)
        check("an empty tree is a valid, empty answer", CmuxRouting.parseTree("{\"windows\":[]}")?.isEmpty == true)

        // ── parseSessionFile ───────────────────────────────────────────────────
        print("CmuxRouting.parseSessionFile")
        func sessionJSON(_ sid: String, surface: String, ws: String, cwd: String = "/Users/x/proj", pid: Int = 4242, life: String = "idle", started: Double = 100) -> String {
            "\"\(sid)\":{\"sessionId\":\"\(sid)\",\"surfaceId\":\"\(surface)\",\"workspaceId\":\"\(ws)\",\"cwd\":\"\(cwd)\",\"pid\":\(pid),\"pidStartSeconds\":777,\"agentLifecycle\":\"\(life)\",\"startedAt\":\(started),\"launchCommand\":{\"arguments\":[\"claude\"]}}"
        }
        let fileJSON = """
        {"version":1,"sessions":{\(sessionJSON("s-old", surface: sfA1, ws: wsA, started: 10)),\(sessionJSON("s-new", surface: sfA1, ws: wsA, life: "running", started: 50)),
        \(sessionJSON("s-helper", surface: sfA2, ws: wsA, started: 60)),\(sessionJSON("s-b", surface: sfB1, ws: wsB, cwd: "/Users/x/../etc", life: "needsInput"))},
        "activeSessionsBySurface":{"\(sfA1)":{"sessionId":"s-new"},"\(sfA2)":{"sessionId":"s-helper"},"\(sfB1)":{"sessionId":"s-b"},"\(sfShell)":{"sessionId":"s-gone"}},
        "activeSessionsByWorkspace":{}}
        """
        let parsed = CmuxRouting.parseSessionFile(Data(fileJSON.utf8))
        check("only the current session of each surface is kept",
              Set(parsed?.map { $0.sessionId } ?? []) == ["s-new", "s-helper", "s-b"])
        check("fields are read", parsed?.first { $0.sessionId == "s-new" }.map { $0.lifecycle == "running" && $0.startedAt == 50 && $0.pid == 4242 && $0.pidStart == 777 && $0.cwd == "/Users/x/proj" } == true)
        check("a cwd with .. is dropped, the session stays", parsed?.first { $0.sessionId == "s-b" }?.cwd == "")
        check("a session of another surface than the one that points at it is ignored",
              CmuxRouting.parseSessionFile(Data("""
              {"sessions":{\(sessionJSON("s1", surface: sfA2, ws: wsA))},"activeSessionsBySurface":{"\(sfA1)":{"sessionId":"s1"}}}
              """.utf8))?.isEmpty == true)
        check("invalid ids are dropped",
              CmuxRouting.parseSessionFile(Data("""
              {"sessions":{\(sessionJSON("s/1", surface: sfA1, ws: wsA)),\(sessionJSON("s2", surface: "nope", ws: wsA)),\(sessionJSON("s3", surface: sfA2, ws: "bad"))},
              "activeSessionsBySurface":{"\(sfA1)":{"sessionId":"s/1"},"\(sfA2)":{"sessionId":"s3"},"nope":{"sessionId":"s2"}}}
              """.utf8))?.isEmpty == true)
        check("a dead process (isLive false) is dropped",
              CmuxRouting.parseSessionFile(Data(fileJSON.utf8), isLive: { pid, start in pid == 4242 && start == 999 })?.isEmpty == true)
        check("liveness gets the pid and the start time",
              { var seen: [(Int32, Int)] = []; _ = CmuxRouting.parseSessionFile(Data(fileJSON.utf8), isLive: { seen.append(($0, $1)); return true })
                return seen.count == 3 && seen.allSatisfy { $0.0 == 4242 && $0.1 == 777 } }())
        check("pid 0 or missing is dropped",
              CmuxRouting.parseSessionFile(Data("""
              {"sessions":{\(sessionJSON("s1", surface: sfA1, ws: wsA, pid: 0))},"activeSessionsBySurface":{"\(sfA1)":{"sessionId":"s1"}}}
              """.utf8))?.isEmpty == true)
        check("missing maps or garbage → nil",
              CmuxRouting.parseSessionFile(Data("{\"sessions\":{}}".utf8)) == nil
              && CmuxRouting.parseSessionFile(Data("{\"activeSessionsBySurface\":{}}".utf8)) == nil
              && CmuxRouting.parseSessionFile(Data("nope".utf8)) == nil && CmuxRouting.parseSessionFile(Data()) == nil)
        check("the file holds no token field the parser could return", !fileJSON.contains("capability"))
        var bigFile = "{\"sessions\":{"
        var bigActive = "\"activeSessionsBySurface\":{"
        var bigParts: [String] = [], bigActiveParts: [String] = []
        for i in 0..<300 {
            let sf = String(format: "%08X-0000-0000-0000-00000000AAAA", i + 1)
            bigParts.append(sessionJSON("s\(i)", surface: sf, ws: wsA))
            bigActiveParts.append("\"\(sf)\":{\"sessionId\":\"s\(i)\"}")
        }
        bigFile += bigParts.joined(separator: ",") + "}," + bigActive + bigActiveParts.joined(separator: ",") + "}}"
        check("at most 256 sessions", CmuxRouting.parseSessionFile(Data(bigFile.utf8))?.count == 256)

        // ── reconcile ──────────────────────────────────────────────────────────
        print("CmuxRouting.reconcile")
        func entry(_ key: String, task: String, surface: String, heard: Bool, seen: TimeInterval = 10) -> CmuxSurface {
            CmuxSurface(taskId: task, surfaceId: surface, workspaceId: "w", socketPath: "/x.sock", capability: "", sessionId: "",
                        lastSeen: seen, key: key, heard: heard)
        }
        let kA1 = CmuxRouting.sanitize(sfA1), kA2 = CmuxRouting.sanitize(sfA2), kB1 = CmuxRouting.sanitize(sfB1)
        let taskA = "agent_cmux_" + CmuxRouting.sanitize(wsA), taskB = "agent_cmux_" + CmuxRouting.sanitize(wsB)
        let sessA1 = CmuxFileSession(sessionId: "s-new", surfaceId: sfA1, workspaceId: wsA, cwd: "/p/a", lifecycle: "idle", pid: 1, pidStart: 1, startedAt: 5)
        let sessA2 = CmuxFileSession(sessionId: "s-helper", surfaceId: sfA2, workspaceId: wsA, cwd: "/p/a", lifecycle: "running", pid: 2, pidStart: 1, startedAt: 9)
        let sessB1 = CmuxFileSession(sessionId: "s-b", surfaceId: sfB1, workspaceId: wsB, cwd: "/p/b", lifecycle: "needsInput", pid: 3, pidStart: 1, startedAt: 7)
        let snap = CmuxSnapshot(tree: tree, sessions: [sessA1, sessA2, sessB1], socketPath: "/x.sock", startedAt: 1000)
        let plan1 = CmuxRouting.reconcile(snapshot: snap, entries: [], protected: [])
        check("new workspaces → one pill each, in tree order", plan1.workspaces.map { $0.taskId } == [taskA, taskB])
        check("all agent surfaces fold into the workspace pill", plan1.workspaces.first?.surfaces.map { $0.key } == [kA1, kA2])
        check("pill name is the workspace title, folder from the first surface",
              plan1.workspaces.first?.title == "core.joinads.me" && plan1.workspaces.first?.cwd == "/p/a")
        check("a non terminal surface and a shell surface give no agent surface",
              plan1.workspaces.flatMap { $0.surfaces.map { $0.key } }.contains(CmuxRouting.sanitize(sfShell)) == false)
        check("lifecycle and session id travel with the surface",
              plan1.workspaces.last?.surfaces.first.map { $0.lifecycle == "needsInput" && $0.sessionId == "s-b" } == true)
        let shellOnly = CmuxSnapshot(tree: tree, sessions: [], socketPath: "/x.sock", startedAt: 1000)
        check("a workspace with no agent session gets no pill",
              CmuxRouting.reconcile(snapshot: shellOnly, entries: [], protected: []).workspaces.isEmpty)
        check("a surface the hooks reported counts as an agent even without a file session",
              CmuxRouting.reconcile(snapshot: shellOnly, entries: [entry(kB1, task: taskB, surface: sfB1, heard: true)], protected: [])
                .workspaces.map { $0.taskId } == [taskB])
        check("an entry that was only discovered and whose session is gone is not an agent",
              CmuxRouting.reconcile(snapshot: shellOnly, entries: [entry(kB1, task: taskB, surface: sfB1, heard: false)], protected: [])
                .workspaces.isEmpty)
        let gone = CmuxRouting.reconcile(snapshot: snap, entries: [
            entry(kA1, task: taskA, surface: sfA1, heard: true), entry("zz-closed", task: taskA, surface: "0Z", heard: true)], protected: [])
        check("a surface missing from the tree is removed, the pill stays", gone.removeKeys == ["zz-closed"] && gone.removeTasks.isEmpty)
        let treeA = Array(tree!.prefix(1))
        let lastGone = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA, sessions: [sessA1, sessA2], socketPath: "/x.sock", startedAt: 1000),
                                             entries: [entry(kA1, task: taskA, surface: sfA1, heard: true), entry(kB1, task: taskB, surface: sfB1, heard: true)], protected: [])
        check("last surface gone → the pill is removed", lastGone.removeKeys == [kB1] && lastGone.removeTasks == [taskB])
        let prot = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA, sessions: [sessA1], socketPath: "/x.sock", startedAt: 1000),
                                         entries: [entry(kB1, task: taskB, surface: sfB1, heard: true)], protected: [taskB])
        check("a protected pill is kept with its surfaces", prot.removeKeys.isEmpty && prot.removeTasks.isEmpty)
        let newer = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA, sessions: [sessA1], socketPath: "/x.sock", startedAt: 1000),
                                          entries: [entry(kB1, task: taskB, surface: sfB1, heard: true, seen: 1001)], protected: [])
        check("an entry heard after the snapshot began is newer than the tree: kept", newer.removeKeys.isEmpty && newer.removeTasks.isEmpty)
        let unanchored = CmuxRouting.reconcile(snapshot: snap, entries: [entry("sess-only", task: "agent_cmux_sess-only", surface: "", heard: true)], protected: [])
        check("an entry without a surface id is left to the time rule", unanchored.removeKeys.isEmpty)
        let noTree = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: nil, sessions: [sessA1, sessA2, sessB1], socketPath: "", startedAt: 1000),
                                           entries: [entry("old", task: "agent_cmux_old", surface: "0Z", heard: true)], protected: [])
        check("tree nil → nothing is removed", noTree.removeKeys.isEmpty && noTree.removeTasks.isEmpty)
        check("tree nil → pills come from the session file, grouped by workspace, no title",
              noTree.workspaces.map { $0.taskId } == [taskA, taskB] && noTree.workspaces.allSatisfy { $0.title == nil }
              && noTree.workspaces.first?.surfaces.count == 2 && noTree.workspaces.first?.surfaces.allSatisfy { $0.index == nil } == true)
        check("no tree and no session file → an empty plan",
              CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: nil, sessions: nil, socketPath: "", startedAt: 0), entries: [entry("a", task: "t", surface: "s", heard: true)], protected: []) == CmuxReconcilePlan())
        var manyTree: [CmuxTreeWorkspace] = [], manySess: [CmuxFileSession] = []
        for i in 0..<20 {
            let w = String(format: "%08X-0000-0000-0000-00000000BBBB", i + 1), sf = String(format: "%08X-0000-0000-0000-00000000CCCC", i + 1)
            manyTree.append(CmuxTreeWorkspace(id: w, title: "w\(i)", index: i, selected: false, surfaces: [CmuxTreeSurface(id: sf, title: "t", type: "terminal", index: 0)]))
            manySess.append(CmuxFileSession(sessionId: "s\(i)", surfaceId: sf, workspaceId: w, cwd: "", lifecycle: "idle", pid: 1, pidStart: 1, startedAt: Double(i)))
        }
        let capped = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: manyTree, sessions: manySess, socketPath: "", startedAt: 0), entries: [], protected: [])
        check("new pills stop at 12, lowest index first",
              capped.workspaces.count == 12 && capped.workspaces.first?.title == "w0" && capped.workspaces.last?.title == "w11")
        let cappedKeep = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: manyTree, sessions: manySess, socketPath: "", startedAt: 0),
            entries: [entry(CmuxRouting.sanitize(manySess[19].surfaceId), task: "agent_cmux_" + CmuxRouting.sanitize(manyTree[19].id), surface: manySess[19].surfaceId, heard: true)], protected: [])
        check("a pill that exists already is kept past the cap", cappedKeep.workspaces.contains { $0.title == "w19" } && cappedKeep.workspaces.count == 12)

        // ── registry per surface ───────────────────────────────────────────────
        print("CmuxRegistry per surface")
        var rr = CmuxRegistry()
        rr.note(taskId: "P", key: "k1", surfaceId: "S1", workspaceId: "W", socketPath: "/x.sock", capability: "tok", sessionId: "a", now: 1)
        check("note reports a new key", rr.lastNoteCreated)
        rr.note(taskId: "P", key: "k1", surfaceId: "S1", workspaceId: "W", socketPath: "/x.sock", capability: "tok", sessionId: "a", now: 2)
        check("note of a known key is not new", !rr.lastNoteCreated)
        rr.note(taskId: "P", key: "k2", surfaceId: "S2", workspaceId: "W", socketPath: "/x.sock", capability: "tok2", sessionId: "b", now: 3)
        check("two surfaces of one pill", rr.surfaces(ofTask: "P").count == 2 && rr.taskIds == ["P"])
        check("a heard surface is marked heard", rr.surface(key: "k1")?.heard == true && rr.surface(key: "k2")?.heard == true)
        rr.noteDiscovered(taskId: "P", key: "k1", surfaceId: "OTHER", workspaceId: "OTHERW", socketPath: "/y.sock", sessionId: "z",
                          title: "Main", index: 0, startedAt: 5, now: 10)
        check("noteDiscovered never replaces a token backed unit",
              rr.surface(key: "k1")?.surfaceId == "S1" && rr.surface(key: "k1")?.socketPath == "/x.sock" && rr.surface(key: "k1")?.capability == "tok"
              && rr.surface(key: "k1")?.workspaceId == "W")
        check("noteDiscovered sets title, index, start time, session id and lastSeen",
              rr.surface(key: "k1").map { $0.title == "Main" && $0.index == 0 && $0.startedAt == 5 && $0.sessionId == "z" } == true)
        check("discovery does not refresh lastSeen of a heard entry", rr.surface(key: "k1")?.lastSeen == 2)
        rr.noteDiscovered(taskId: "P", key: "k3", surfaceId: "S3", workspaceId: "W", socketPath: "/x.sock", sessionId: "c",
                          title: nil, index: 2, startedAt: 9, now: 11)
        check("a discovered surface has ids and socket but no token and is not heard",
              rr.surface(key: "k3").map { $0.capability.isEmpty && $0.socketPath == "/x.sock" && !$0.heard && !$0.canFocusExactly } == true)
        check("main surface: lowest index", rr.surface(for: "P")?.key == "k1")
        check("surfaces(ofTask:) puts the main first", rr.surfaces(ofTask: "P").first?.key == "k1")
        check("sendCredential(forKey:) gives a discovered surface nothing, whatever token sits on its socket",
              rr.sendCredential(forKey: "k3") == CmuxCredential.none)
        check("jumpCredential(forKey:) borrows the token on the same socket for it",
              { if case .token(let t) = rr.jumpCredential(forKey: "k3") { return t.key == "k1" || t.key == "k2" } else { return false } }())
        check("a discovered surface refreshes lastSeen (nothing else keeps it)", rr.surface(key: "k3")?.lastSeen == 11)
        var otherSocket = rr
        otherSocket.noteDiscovered(taskId: "P", key: "k4", surfaceId: "S4", workspaceId: "W", socketPath: "/other.sock", sessionId: "d",
                                   title: nil, index: 3, startedAt: nil, now: 12)
        check("no token on that socket: none, never the password",
              otherSocket.sendCredential(forKey: "k4") == CmuxCredential.none && otherSocket.jumpCredential(forKey: "k4") == CmuxCredential.none)
        var noSocket = CmuxRegistry()
        noSocket.noteDiscovered(taskId: "P", key: "k9", surfaceId: "S9", workspaceId: "W", socketPath: "", sessionId: "", title: nil, index: 0, startedAt: nil, now: 1)
        check("a discovered surface with no socket path has no credential",
              noSocket.sendCredential(forKey: "k9") == CmuxCredential.none && noSocket.jumpCredential(forKey: "k9") == CmuxCredential.none)
        check("unknown key: none", rr.sendCredential(forKey: "nope") == CmuxCredential.none)
        rr.setState(key: "k2", "working")
        rr.setState(key: "k1", "finished")
        check("folded state of the pill", rr.foldedState(ofTask: "P") == "working" && rr.foldedState(ofTask: "none") == nil)
        rr.clearCredentials()
        check("clearCredentials keeps the entries and their ids", rr.surfaces.count == 3 && rr.surface(key: "k1")?.surfaceId == "S1" && rr.surface(key: "k1")?.capability == "")
        var rm = rr
        rm.remove(key: "k1")
        check("remove(key:) moves the main surface to the next one", rm.surfaces(ofTask: "P").count == 2 && rm.surface(for: "P")?.key != "k1" && rm.surface(for: "P") != nil)
        rm.remove(taskId: "P")
        check("remove(taskId:) removes every surface of the pill", rm.surfaces.isEmpty && rm.surface(for: "P") == nil && rm.mainKeys.isEmpty)
        var cap = CmuxRegistry()
        for i in 0..<26 { cap.note(taskId: "P", key: "k\(i)", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "", sessionId: "", now: Double(i)) }
        check("a pill holds at most 24 surfaces", cap.surfaces(ofTask: "P").count == CmuxRouting.maxSurfacesPerTask && CmuxRouting.maxSurfacesPerTask == 24)
        check("a 25th discovered surface is refused", cap.noteDiscovered(taskId: "P", key: "kx", surfaceId: "S", workspaceId: "W", socketPath: "", sessionId: "", title: nil, index: nil, startedAt: nil, now: 1) == false)
        check("10 live sessions of one workspace are all registered (the 9th and 10th used to be dropped)", {
            var ten = CmuxRegistry()
            for i in 0..<10 { ten.note(taskId: "P", key: "k\(i)", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "", sessionId: "", now: Double(i)) }
            return ten.surfaces(ofTask: "P").count == 10 && ten.surface(key: "k9") != nil
        }())
        check("a 26th noted session is refused and the first 24 stay", cap.surface(key: "k25") == nil && cap.surface(key: "k23") != nil)
        var ev2 = CmuxRegistry()
        for p in 1...13 { for s in 0..<2 { ev2.note(taskId: "p\(p)", key: "p\(p)s\(s)", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "", sessionId: "", now: Double(p)) } }
        check("eviction counts pills, not surfaces", ev2.evictionCandidates(idle: ev2.taskIds, keep: "p13") == ["p1"])
        var st2 = CmuxRegistry()
        st2.note(taskId: "P", key: "main", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "", sessionId: "", now: 0)
        st2.note(taskId: "P", key: "helper", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "", sessionId: "", now: 5000)
        check("stale prune works per surface", st2.staleTaskIds(now: 4000, protected: []) == ["main"])
        check("stale prune honours `only`", st2.staleTaskIds(now: 4000, protected: [], only: { _ in false }).isEmpty)
        check("a protected pill keeps its surfaces", st2.staleTaskIds(now: 4000, protected: ["P"]).isEmpty)
        check("a busy surface key lasts longer", st2.staleTaskIds(now: 4000, protected: [], busy: ["main"]).isEmpty)

        print("CmuxCardQueue per surface and pill")
        var qs2 = CmuxCardQueue()
        _ = qs2.enqueue(kind: .approval, taskId: "P", sessionId: "s1", tool: "Bash", inputKey: "1", now: 0, surfaceKey: "a")
        _ = qs2.enqueue(kind: .approval, taskId: "P", sessionId: "s1", tool: "Bash", inputKey: "2", now: 0, surfaceKey: "a")
        check("two cards of a surface: refuses a third for it", !qs2.canAccept(taskId: "P", surfaceKey: "a"))
        check("another surface of the same pill is still accepted", qs2.canAccept(taskId: "P", surfaceKey: "b"))
        for (i, k) in ["b", "b", "c", "c"].enumerated() { _ = qs2.enqueue(kind: .approval, taskId: "P", sessionId: "s\(i)", tool: "Bash", inputKey: "k\(i)", now: 0, surfaceKey: k) }
        check("six cards of a pill: refuses a seventh whatever the surface", !qs2.canAccept(taskId: "P", surfaceKey: "d") && qs2.canAccept(taskId: "Q", surfaceKey: "q"))
        check("hasCards by surface and by pill", qs2.hasCards(forSurface: "a") && !qs2.hasCards(forSurface: "d") && qs2.hasCards(for: "P"))
        let gone2 = qs2.removeAll(surfaceKey: "a")
        check("removeAll(surfaceKey:) removes that surface only", gone2.count == 2 && !qs2.hasCards(forSurface: "a") && qs2.hasCards(forSurface: "b"))
        var qres = CmuxCardQueue()
        let c1 = qres.enqueue(kind: .approval, taskId: "P", sessionId: "s1", tool: "Bash", inputKey: "k", now: 0, surfaceKey: "a")
        _ = qres.enqueue(kind: .approval, taskId: "P", sessionId: "s2", tool: "Bash", inputKey: "k", now: 0, surfaceKey: "b")
        check("resolve is still by session", qres.resolve(event: "Stop", sessionId: "s1", tool: "", inputKey: "") == [c1] && qres.cards.count == 1)
        check("a card without a surface key is keyed by its task",
              { var q = CmuxCardQueue(); _ = q.enqueue(kind: .approval, taskId: "T", sessionId: "s", tool: "Bash", inputKey: "k", now: 0)
                return q.cards.first?.surfaceKey == "T" }())

        print("answerStaysInReply with surfaces")
        check("only the targeted surface stays in place",
              CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "P"), taskId: "P", viewIsPrompt: true, surfaceKey: "a", targetKey: "a")
              && !CmuxRouting.answerStaysInReply(prompt: .reply(taskId: "P"), taskId: "P", viewIsPrompt: true, surfaceKey: "b", targetKey: "a"))

        // ── Aegis F1: only a hook event with a valid token makes a surface a typing target ──
        print("typing proof (a surface is typable only after a hook event with a valid token for it)")
        var fz = CmuxRegistry()
        // A forged SessionStart with no token, naming the surface of a plain shell.
        fz.note(taskId: "P", key: "shell", surfaceId: "", workspaceId: "", socketPath: "", capability: "", sessionId: "forged", now: 1)
        check("a tokenless event creates an entry that was never heard", fz.surface(key: "shell").map { !$0.heard && $0.capability.isEmpty } == true)
        check("and it reports the surface as not heard (nothing qualifies it as an agent)", fz.lastNoteCreated && !fz.lastNoteFirstHeard)
        // Discovery then fills the ids from the tree, on the socket of the token in use.
        fz.note(taskId: "P", key: "real", surfaceId: "SR", workspaceId: "W", socketPath: "/x.sock", capability: "tokR", sessionId: "s", now: 2)
        fz.noteDiscovered(taskId: "P", key: "shell", surfaceId: "SH", workspaceId: "W", socketPath: "/x.sock", sessionId: "forged",
                          title: nil, index: 0, startedAt: nil, now: 3)
        check("discovery gives the shell ids and a socket", fz.surface(key: "shell").map { $0.surfaceId == "SH" && $0.socketPath == "/x.sock" } == true)
        check("but the shell is not typable and gets no credential, although a live token sits on its socket",
              fz.surface(key: "shell")?.canType == false && fz.sendCredential(forKey: "shell") == CmuxCredential.none
              && fz.sendCredential(for: "shell") == CmuxCredential.none)
        check("the surface that reported with a token is typable with its own token",
              fz.surface(key: "real")?.canType == true
              && { if case .token(let t) = fz.sendCredential(forKey: "real") { return t.key == "real" && t.capability == "tokR" } else { return false } }())
        // A file-only surface (the user writable session file) is in the same position.
        fz.noteDiscovered(taskId: "P", key: "filesess", surfaceId: "SF", workspaceId: "W", socketPath: "/x.sock", sessionId: "s2",
                          title: nil, index: 2, startedAt: 5, now: 4)
        check("a surface known only through the session file has no credential", fz.sendCredential(forKey: "filesess") == CmuxCredential.none)
        // The first real event with a token proves it.
        fz.note(taskId: "P", key: "shell", surfaceId: "SH", workspaceId: "W", socketPath: "/x.sock", capability: "tokH", sessionId: "s3", now: 5)
        check("a hook event with a valid token for the very surface makes it typable", fz.surface(key: "shell")?.canType == true)
        fz.clearCredentials()
        check("cmux quit: every token is dead, nobody is typable until the next event",
              fz.surface(key: "shell")?.canType == false && fz.sendCredential(forKey: "real") == CmuxCredential.none)
        check("a hand built entry with ids and a token but never heard is not typable",
              CmuxSurface(taskId: "t", surfaceId: "s", workspaceId: "w", socketPath: "/x.sock", capability: "c", sessionId: "", lastSeen: 0).canType == false)

        // ── Hera M4: "new" means not heard before this event ──
        print("first event of a surface (a discovered entry is still new)")
        var fh = CmuxRegistry()
        fh.noteDiscovered(taskId: "P", key: "k", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", sessionId: "s", title: nil, index: 0, startedAt: 1, now: 1)
        fh.note(taskId: "P", key: "k", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "tok", sessionId: "s", now: 2)
        check("discovery created the entry, then the first hook event reports first heard", !fh.lastNoteCreated && fh.lastNoteFirstHeard)
        fh.note(taskId: "P", key: "k", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "tok", sessionId: "s", now: 3)
        check("a second event of the same surface does not", !fh.lastNoteFirstHeard)
        var fh2 = CmuxRegistry()
        fh2.note(taskId: "P", key: "k", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "tok", sessionId: "s", now: 1)
        check("an unknown surface's first event is created and first heard", fh2.lastNoteCreated && fh2.lastNoteFirstHeard)
        var fh3 = CmuxRegistry()
        fh3.note(taskId: "P", key: "k", surfaceId: "", workspaceId: "", socketPath: "", capability: "", sessionId: "s", now: 1)
        check("a tokenless first event is created but not first heard", fh3.lastNoteCreated && !fh3.lastNoteFirstHeard)
        fh3.note(taskId: "P", key: "k", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "tok", sessionId: "s", now: 2)
        check("the first event with a token after a tokenless one is first heard", !fh3.lastNoteCreated && fh3.lastNoteFirstHeard)

        // ── Aegis F2: the entry decides the pill; the tree re-homes ──
        print("one source of truth for surface to pill")
        var ph = CmuxRegistry()
        ph.note(taskId: "agent_cmux_W1", key: "k", surfaceId: "S", workspaceId: "W1", socketPath: "/x.sock", capability: "t", sessionId: "s", now: 1)
        check("pillId(forKey:) is the pill of the entry", ph.pillId(forKey: "k") == "agent_cmux_W1" && ph.pillId(forKey: "nope") == nil)
        ph.note(taskId: "agent_cmux_W3", key: "k", surfaceId: "S", workspaceId: "W3", socketPath: "/x.sock", capability: "t", sessionId: "s", now: 2)
        check("an event naming another workspace does not move the entry", ph.pillId(forKey: "k") == "agent_cmux_W1" && ph.taskIds == ["agent_cmux_W1"])
        ph.noteDiscovered(taskId: "agent_cmux_W2", key: "k", surfaceId: "S", workspaceId: "W2", socketPath: "/x.sock", sessionId: "s", title: nil, index: 0, startedAt: nil, now: 3)
        check("the tree moves the entry to its workspace's pill", ph.pillId(forKey: "k") == "agent_cmux_W2" && ph.taskIds == ["agent_cmux_W2"])
        check("the old pill has no main surface left, the new one has it", ph.surface(for: "agent_cmux_W1") == nil && ph.surface(for: "agent_cmux_W2")?.key == "k")
        var fullPill = CmuxRegistry()
        for i in 0..<CmuxRouting.maxSurfacesPerTask { fullPill.note(taskId: "T", key: "f\(i)", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "t", sessionId: "", now: 1) }
        fullPill.note(taskId: "U", key: "m", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", capability: "t", sessionId: "", now: 1)
        check("a move into a full pill is refused", fullPill.noteDiscovered(taskId: "T", key: "m", surfaceId: "S", workspaceId: "W", socketPath: "/x.sock", sessionId: "", title: nil, index: 0, startedAt: nil, now: 2) == false
              && fullPill.pillId(forKey: "m") == "U")
        // reconcile: the heard entry sits under another pill than the tree's workspace
        let legacyTask = "agent_cmux_" + kB1
        let rehome = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA + Array(tree!.suffix(1)), sessions: [sessA1, sessB1], socketPath: "/x.sock", startedAt: 1000),
                                           entries: [entry(kB1, task: legacyTask, surface: sfB1, heard: true)], protected: [])
        check("an entry filed under another pill is planned under the tree's workspace, and the old pill goes (no ghost pill)",
              rehome.workspaces.first { $0.taskId == taskB }?.surfaces.map { $0.key } == [kB1] && rehome.removeTasks == [legacyTask] && rehome.removeKeys.isEmpty)
        let rehomeProt = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA + Array(tree!.suffix(1)), sessions: [sessA1, sessB1], socketPath: "/x.sock", startedAt: 1000),
                                               entries: [entry(kB1, task: legacyTask, surface: sfB1, heard: true)], protected: [legacyTask])
        check("a protected pill is not re-homed and not removed",
              rehomeProt.removeTasks.isEmpty && rehomeProt.removeKeys.isEmpty && !rehomeProt.workspaces.contains { $0.taskId == taskB })

        // ── Hera M5(b), Aegis F7: only what this tree can speak for ──
        print("reconcile: socket, truncation, unreadable session file")
        func entryOn(_ key: String, task: String, surface: String, socket: String, heard: Bool = true) -> CmuxSurface {
            CmuxSurface(taskId: task, surfaceId: surface, workspaceId: "w", socketPath: socket, capability: "", sessionId: "",
                        lastSeen: 10, key: key, heard: heard)
        }
        let other = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA, sessions: [sessA1], socketPath: "/x.sock", startedAt: 1000),
                                          entries: [entryOn("zz-other", task: "agent_cmux_zz", surface: "0Z", socket: "/other.sock")], protected: [])
        check("an entry of another cmux socket is not removed by this tree", other.removeKeys.isEmpty && other.removeTasks.isEmpty)
        let mine = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA, sessions: [sessA1], socketPath: "/x.sock", startedAt: 1000),
                                         entries: [entryOn("zz-mine", task: "agent_cmux_zz", surface: "0Z", socket: "/x.sock")], protected: [])
        check("an entry of this socket the tree no longer lists is removed", mine.removeKeys == ["zz-mine"] && mine.removeTasks == ["agent_cmux_zz"])
        let cut = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: treeA, sessions: [sessA1], socketPath: "/x.sock", startedAt: 1000, treeTruncated: true),
                                        entries: [entryOn("zz-mine", task: "agent_cmux_zz", surface: "0Z", socket: "/x.sock")], protected: [])
        check("a tree cut at a cap removes nothing", cut.removeKeys.isEmpty && cut.removeTasks.isEmpty && cut.workspaces.map { $0.taskId } == [taskA])
        let noFile = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: tree, sessions: nil, socketPath: "/x.sock", startedAt: 1000),
                                           entries: [entry(kB1, task: taskB, surface: sfB1, heard: false)], protected: [])
        check("an unreadable session file does not remove an unheard entry the tree still lists as a terminal",
              noFile.removeKeys.isEmpty && noFile.removeTasks.isEmpty && noFile.workspaces.map { $0.taskId } == [taskB])
        let noFileShell = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: tree, sessions: nil, socketPath: "/x.sock", startedAt: 1000),
                                                entries: [], protected: [])
        check("with no file and no entry nothing is invented", noFileShell.workspaces.isEmpty)
        let json65 = "{\"windows\":[{\"workspaces\":[" + (0..<70).map { i in
            "{\"id\":\"\(String(format: "%08X-0000-0000-0000-000000000000", i + 1))\",\"title\":\"w\",\"index\":\(i),\"panes\":[]}" }.joined(separator: ",") + "]}]}"
        check("parseTreeChecked: 70 workspaces are cut at 64 and flagged", CmuxRouting.parseTreeChecked(json65).map { $0.workspaces.count == 64 && $0.truncated } == true)
        var many33 = "{\"windows\":[{\"workspaces\":[{\"id\":\"\(wsA)\",\"title\":\"w\",\"index\":0,\"panes\":[{\"surfaces\":["
        many33 += (0..<40).map { i in surfaceJSON(String(format: "%08X-0000-0000-0000-000000000000", i + 1), "t", "terminal", i) }.joined(separator: ",")
        many33 += "]}]}]}]}"
        check("parseTreeChecked: 40 surfaces are cut at 32 and flagged", CmuxRouting.parseTreeChecked(many33).map { $0.workspaces[0].surfaces.count == 32 && $0.truncated } == true)
        check("parseTreeChecked: a tree within the caps is not flagged", CmuxRouting.parseTreeChecked(treeJSON).map { !$0.truncated && $0.workspaces.count == 2 } == true)

        // ── Hera m1: a session that just ended is not brought back by an older snapshot ──
        print("reconcile: a session that just ended")
        let endedPlan = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: tree, sessions: [sessA1, sessA2, sessB1], socketPath: "/x.sock", startedAt: 1000),
                                              entries: [], protected: [], ended: [kA2: 995])
        check("the ended surface is not planned again within the grace", endedPlan.workspaces.first?.surfaces.map { $0.key } == [kA1])
        let endedLater = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: tree, sessions: [sessA1, sessA2, sessB1], socketPath: "/x.sock", startedAt: 1000),
                                               entries: [], protected: [], ended: [kA2: 980])
        check("after the grace it is planned if the file still lists it", endedLater.workspaces.first?.surfaces.map { $0.key } == [kA1, kA2])
        let endedNoTree = CmuxRouting.reconcile(snapshot: CmuxSnapshot(tree: nil, sessions: [sessA1, sessA2], socketPath: "", startedAt: 1000),
                                                entries: [], protected: [], ended: [kA2: 999])
        check("same without a tree", endedNoTree.workspaces.first?.surfaces.map { $0.key } == [kA1])

        // ── Hera M1: /clear in the main agent ──
        print("main surface after /clear")
        var cl = CmuxRegistry()
        cl.note(taskId: "P", key: "M", surfaceId: "SM", workspaceId: "W", socketPath: "/x.sock", capability: "t", sessionId: "a", now: 1)
        cl.note(taskId: "P", key: "H", surfaceId: "SH", workspaceId: "W", socketPath: "/x.sock", capability: "t", sessionId: "b", now: 2)
        cl.noteDiscovered(taskId: "P", key: "M", surfaceId: "SM", workspaceId: "W", socketPath: "/x.sock", sessionId: "a", title: nil, index: 0, startedAt: 1, now: 3)
        cl.noteDiscovered(taskId: "P", key: "H", surfaceId: "SH", workspaceId: "W", socketPath: "/x.sock", sessionId: "b", title: nil, index: 1, startedAt: 2, now: 3)
        check("main is the surface at index 0", cl.surface(for: "P")?.key == "M")
        cl.remove(key: "M")   // SessionEnd of /clear
        check("while the main is away the helper holds the role", cl.surface(for: "P")?.key == "H")
        cl.note(taskId: "P", key: "M", surfaceId: "SM", workspaceId: "W", socketPath: "/x.sock", capability: "t", sessionId: "a2", now: 4)   // SessionStart
        check("the new session has no index yet: the helper still holds it", cl.surface(for: "P")?.key == "H")
        cl.noteDiscovered(taskId: "P", key: "M", surfaceId: "SM", workspaceId: "W", socketPath: "/x.sock", sessionId: "a2", title: nil, index: 0, startedAt: 4, now: 5)
        check("the next discovery gives it index 0 and the main role comes back", cl.surface(for: "P")?.key == "M")

        // ── Hera M2, M3: alerts ──
        print("alerts: silent stop and placement")
        check("the main agent's Stop is never silent, even while a helper works",
              !CmuxRouting.stopIsSilent(stoppingKey: "M", mainKey: "M", states: ["M": "finished", "H": "working"]))
        check("a helper's Stop while the main works is silent",
              CmuxRouting.stopIsSilent(stoppingKey: "H", mainKey: "M", states: ["M": "thinking", "H": "finished"]))
        check("a helper's Stop while another helper searches is silent",
              CmuxRouting.stopIsSilent(stoppingKey: "H1", mainKey: "M", states: ["M": "idle", "H1": "finished", "H2": "searching"]))
        check("a helper's Stop alone alerts", !CmuxRouting.stopIsSilent(stoppingKey: "H", mainKey: "M", states: ["M": "idle", "H": "finished"]))
        check("a sibling stuck in error, ratelimit, approval, question or finished does not silence anybody",
              ["error", "ratelimit", "approval", "question", "finished", "idle"].allSatisfy {
                  !CmuxRouting.stopIsSilent(stoppingKey: "H", mainKey: "M", states: ["M": $0, "H": "finished"]) })
        check("no main known: a Stop is silent only while a sibling is busy",
              !CmuxRouting.stopIsSilent(stoppingKey: "H", mainKey: nil, states: ["H": "finished"])
              && CmuxRouting.stopIsSilent(stoppingKey: "H", mainKey: nil, states: ["H": "finished", "X": "working"]))
        check("focused pill, no card: the view", CmuxRouting.alertPlacement(focused: true, cardOfPillOnScreen: false, pillHoldsCard: false) == .view)
        check("a card of the pill on screen: the alert of a sibling never replaces it nor overwrites the badge",
              CmuxRouting.alertPlacement(focused: true, cardOfPillOnScreen: true, pillHoldsCard: true) == .none
              && CmuxRouting.alertPlacement(focused: false, cardOfPillOnScreen: true, pillHoldsCard: true) == .none)
        check("not focused: the badge, unless the pill holds a queued card (its approval badge stays)",
              CmuxRouting.alertPlacement(focused: false, cardOfPillOnScreen: false, pillHoldsCard: false) == .badge
              && CmuxRouting.alertPlacement(focused: false, cardOfPillOnScreen: false, pillHoldsCard: true) == .none)

        print("waiting notification")
        check("idle_prompt is a waiting notification, whatever the message",
              CmuxRouting.isWaitingNotification(type: "idle_prompt", message: "") && CmuxRouting.isWaitingNotification(type: "IDLE_PROMPT", message: "x"))
        check("another typed notification is not (permission prompt, elicitation, auth)",
              !CmuxRouting.isWaitingNotification(type: "permission_prompt", message: "Claude is waiting for your input")
              && !CmuxRouting.isWaitingNotification(type: "elicitation_dialog", message: "")
              && !CmuxRouting.isWaitingNotification(type: "auth_success", message: ""))
        check("untyped: the waiting messages count, a permission message or a question does not",
              CmuxRouting.isWaitingNotification(type: nil, message: "Claude is waiting for your input")
              && CmuxRouting.isWaitingNotification(type: "", message: "Waiting for your next prompt")
              && !CmuxRouting.isWaitingNotification(type: nil, message: "Claude needs your permission to use Bash")
              && !CmuxRouting.isWaitingNotification(type: nil, message: "Which file?")
              && !CmuxRouting.isWaitingNotification(type: nil, message: ""))
        func badge(_ nobody: Bool = true, focused: Bool = false, hasBadge: Bool = false, card: Bool = false, state: String? = "idle") -> Bool {
            CmuxRouting.waitingNeedsBadge(stopToldNobody: nobody, pillFocused: focused, pillHasBadge: hasBadge, pillHoldsCard: card, sessionState: state)
        }
        check("a Stop that told nobody, pill not on screen, session idle: the badge", badge() && badge(state: "finished") && badge(state: nil))
        check("the Stop told the user (not recorded): no second badge", !badge(false))
        check("the pill is the focused one, already badged or holding a card: nothing", !badge(focused: true) && !badge(hasBadge: true) && !badge(card: true))
        check("a session mid turn gets no badge", !badge(state: "working") && !badge(state: "thinking") && !badge(state: "searching"))
        check("a failed session (error, rate limit) never gets the finished badge", !badge(state: "error") && !badge(state: "ratelimit"))

        print("stop told nobody record")
        var rec = CmuxStopRecord()
        check("a session never recorded is not a candidate (fresh session, session that never stopped)", !rec.toldNobody("a"))
        rec.stop("a", told: false)
        check("a Stop that told nobody is recorded", rec.toldNobody("a"))
        rec.stop("a", told: true)
        check("a Stop that told someone takes it out", !rec.toldNobody("a"))
        rec.stop("a", told: false)
        rec.prompt("a")
        check("the next prompt of the session takes it out", !rec.toldNobody("a"))
        rec.stop("a", told: false)
        rec.gaveWaitingBadge("a")
        check("a waiting badge is given once per idle period (a second notification finds nothing)", !rec.toldNobody("a"))
        rec.stop("a", told: false)
        rec.stopFailed("a")
        check("a StopFailure takes it out: a failed session gets no finished badge", !rec.toldNobody("a"))
        rec.stop("a", told: false)
        rec.forget("a")
        check("a forgotten surface leaves the record", !rec.toldNobody("a"))
        var fullRec = CmuxStopRecord()
        for i in 0..<CmuxStopRecord.capacity { fullRec.stop("k\(i)", told: false) }
        fullRec.stop("extra", told: false)
        check("a full record refuses a new key (no badge instead of an extra one)", !fullRec.toldNobody("extra") && fullRec.toldNobody("k0"))
        fullRec.forget("k0")
        fullRec.stop("extra", told: false)
        check("a freed place takes the key", fullRec.toldNobody("extra"))
        check("the record is sized for every session the registry can hold", CmuxStopRecord.capacity >= CmuxRouting.maxTasks * CmuxRouting.maxSurfacesPerTask)

        print("silent stop badge")
        func silent(focused: Bool = false, screen: Bool = false, holds: Bool = false, hasBadge: Bool = false) -> CmuxRouting.AlertPlacement {
            CmuxRouting.silentStopPlacement(pillFocused: focused, cardOfPillOnScreen: screen, pillHoldsCard: holds, pillHasBadge: hasBadge)
        }
        check("a helper that stops while a sibling works gives the finished badge of its pill at once", silent() == .badge)
        check("the focused pill shows no badge (its row is not drawn in the pill grid): nothing", silent(focused: true) == .none)
        check("a card of the pill on screen or held keeps the screen and the approval badge", silent(screen: true) == .none && silent(holds: true) == .none)
        check("a pill that already has a badge keeps it", silent(hasBadge: true) == .none)
        check("a silent stop never takes the view", silent() != .view && silent(focused: true) != .view)

        // ── Aegis F4: a heard session does not outlive its process ──
        print("time rule")
        let heardEntry = entry("hk", task: "T", surface: "S", heard: true)
        check("a live process in the file keeps its entry whatever the hooks say",
              !CmuxRouting.timeRuleApplies(entry: heardEntry, treeKnown: true, liveKeys: ["hk"]))
        check("a heard entry with no live process in a readable file expires (tree known or not)",
              CmuxRouting.timeRuleApplies(entry: heardEntry, treeKnown: true, liveKeys: []) && CmuxRouting.timeRuleApplies(entry: heardEntry, treeKnown: false, liveKeys: ["other"]))
        check("no readable file: a known tree speaks only for entries with a surface id",
              !CmuxRouting.timeRuleApplies(entry: heardEntry, treeKnown: true, liveKeys: nil)
              && CmuxRouting.timeRuleApplies(entry: entry("n", task: "T", surface: "", heard: true), treeKnown: true, liveKeys: nil)
              && CmuxRouting.timeRuleApplies(entry: heardEntry, treeKnown: false, liveKeys: nil))

        // ── terminal host: cmux is never a terminal of the terminal pill ──
        print("terminal host")
        func host(_ term: String, _ bundle: String) -> String? { CmuxRouting.terminalHost(termProgram: term, bundleId: bundle)?.bundleId }
        check("cmux bundle → nil", host("", "com.cmuxterm.app") == nil)
        check("cmux bundle with TERM_PROGRAM=ghostty → nil", host("ghostty", "com.cmuxterm.app") == nil)
        check("cmux bundle in another case → nil", host("ghostty", "COM.CmuxTerm.App") == nil)
        check("Warp → Warp", host("WarpTerminal", "") == "dev.warp.Warp-Stable" && host("", "dev.warp.Warp-Stable") == "dev.warp.Warp-Stable")
        check("iTerm → iTerm", host("iTerm.app", "") == "com.googlecode.iterm2" && host("", "com.googlecode.iterm2") == "com.googlecode.iterm2")
        check("Ghostty (no cmux bundle) → Ghostty", host("ghostty", "") == "com.mitchellh.ghostty" && host("ghostty", "com.mitchellh.ghostty") == "com.mitchellh.ghostty")
        check("an unknown app → nil", host("", "com.microsoft.VSCode") == nil)

        print(failures == 0 ? "\nAll cmux routing tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
