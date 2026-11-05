import Foundation

// MARK: - Test harness

@main
enum HermesChatTests {

    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got)")
            print("    expected: \(expected)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func norm(_ s: String) -> String {
        switch HermesChat.normaliseBaseURL(s) {
        case .success(let u): return u
        case .failure(let e): return "ERR:\(e)"
        }
    }

    static func isUnreachable(_ e: HermesChatError?) -> Bool {
        if case .unreachable = e { return true }
        return false
    }

    final class Box: @unchecked Sendable {
        var calls = 0
        var last = ""
    }

    static func headerValue(_ url: URL, _ key: String, _ name: String, body: String) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = Data(body.utf8)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: name)
    }

    static func main() async {
        let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0"
        let base = "http://127.0.0.1:\(port)"

        // ── Unit tests ───────────────────────────────────────────────────────
        print("normaliseBaseURL")
        check("trailing slash", norm("https://agent.example.com/"), "https://agent.example.com")
        check("/v1", norm("https://agent.example.com/v1"), "https://agent.example.com")
        check("/p/mark/v1", norm("https://agent.example.com/p/mark/v1"), "https://agent.example.com")
        check("/p/mark", norm("https://agent.example.com/p/mark/"), "https://agent.example.com")
        check("whitespace", norm("  https://agent.example.com  "), "https://agent.example.com")
        check("keeps port", norm("https://agent.example.com:8443/"), "https://agent.example.com:8443")
        check("ftp", norm("ftp://agent.example.com"), "ERR:invalidURL")
        check("file", norm("file:///etc/passwd"), "ERR:invalidURL")
        check("user-info", norm("https://user:pw@agent.example.com"), "ERR:invalidURL")
        check("query", norm("https://agent.example.com/?a=1"), "ERR:invalidURL")
        check("empty", norm(""), "ERR:invalidURL")
        check("http public", norm("http://example.com"), "ERR:insecureURL")
        check("http localhost", norm("http://localhost:8642"), "http://localhost:8642")
        check("http LAN", norm("http://192.168.1.10:8642"), "http://192.168.1.10:8642")
        check("http tailscale", norm("http://100.101.1.2:8642"), "http://100.101.1.2:8642")
        check("http 172.32 public", norm("http://172.32.0.1"), "ERR:insecureURL")
        check("http 172.16 private", norm("http://172.16.0.1"), "http://172.16.0.1")
        check("http .local", norm("http://mac-mini.local:8642"), "http://mac-mini.local:8642")
        check("http single label", norm("http://mac-mini:8642"), "http://mac-mini:8642")
        check("http all-digit host", norm("http://134744072"), "ERR:insecureURL")
        check("http 0x host", norm("http://0x08080808"), "ERR:insecureURL")
        check("http digit host with port", norm("http://134744072:8642"), "ERR:insecureURL")
        check("https all-digit host untouched", norm("https://134744072"), "https://134744072")
        check("http loopback v6", norm("http://[::1]:8642"), "http://[::1]:8642")
        check("http public v6", norm("http://[2001:db8::1]"), "ERR:insecureURL")
        check("http ULA v6", norm("http://[fd00::1]:8642"), "http://[fd00::1]:8642")
        check("http 100.128 public", norm("http://100.128.0.1"), "ERR:insecureURL")

        print("host classification")
        checkTrue("loopback", HermesChat.isLocalHost("127.0.0.1"))
        checkTrue("private 10", HermesChat.isLocalHost("10.1.2.3"))
        checkTrue("100.64/10", HermesChat.isLocalHost("100.100.1.1"))
        checkTrue("name.local", HermesChat.isLocalHost("mac-mini.local"))
        checkTrue("single label", HermesChat.isLocalHost("mac-mini"))
        checkTrue("digits are not a label", !HermesChat.isLocalHost("134744072"))
        checkTrue("0x is not a label", !HermesChat.isLocalHost("0x08080808"))
        checkTrue("0X is not a label", !HermesChat.isLocalHost("0X7f000001"))
        checkTrue("public name", !HermesChat.isLocalHost("example.com"))
        checkTrue("localhost.attacker", !HermesChat.isLocalHost("localhost.attacker.example"))
        checkTrue("unencrypted: single label name", HermesChat.sendsKeyUnencryptedToName("http://mac-mini:8642"))
        checkTrue("unencrypted: .local name", HermesChat.sendsKeyUnencryptedToName("http://mac-mini.local"))
        checkTrue("not unencrypted: https", !HermesChat.sendsKeyUnencryptedToName("https://agent.example.com"))
        checkTrue("not unencrypted: IPv4 literal", !HermesChat.sendsKeyUnencryptedToName("http://192.168.1.10:8642"))
        checkTrue("not unencrypted: tailscale IP", !HermesChat.sendsKeyUnencryptedToName("http://100.101.1.2"))
        checkTrue("not unencrypted: IPv6 literal", !HermesChat.sendsKeyUnencryptedToName("http://[fd00::1]:8642"))
        checkTrue("not unencrypted: localhost", !HermesChat.sendsKeyUnencryptedToName("http://localhost:8642"))

        print("profileInURL")
        check("/p/mark/v1", HermesChat.profileInURL("https://agent.example.com/p/mark/v1"), "mark")
        check("/p/mark/v1/", HermesChat.profileInURL("https://agent.example.com/p/mark/v1/"), "mark")
        checkTrue("/p/mark without v1", HermesChat.profileInURL("https://agent.example.com/p/mark") == nil)
        checkTrue("plain /v1", HermesChat.profileInURL("https://agent.example.com/v1") == nil)
        checkTrue("invalid name", HermesChat.profileInURL("https://agent.example.com/p/a%20b/v1") == nil)

        print("isValidProfile")
        checkTrue("mark", HermesChat.isValidProfile("mark"))
        checkTrue("a/b", !HermesChat.isValidProfile("a/b"))
        checkTrue("../x", !HermesChat.isValidProfile("../x"))
        checkTrue("empty", HermesChat.isValidProfile(""))
        checkTrue("65 chars", !HermesChat.isValidProfile(String(repeating: "a", count: 65)))

        print("apiRoot / chatURL")
        check("empty", HermesChat.apiRoot(baseURL: "https://h.io", profile: ""), "https://h.io")
        check("default", HermesChat.apiRoot(baseURL: "https://h.io", profile: "default"), "https://h.io")
        check("mark", HermesChat.apiRoot(baseURL: "https://h.io", profile: "mark"), "https://h.io/p/mark")
        let a = HermesAgent(name: "mark", baseURL: "https://h.io", profile: "mark", modelName: "mark")
        check("chatURL", HermesChat.chatURL(for: a)?.absoluteString ?? "", "https://h.io/p/mark/v1/chat/completions")
        check("modelsURL", HermesChat.modelsURL(baseURL: "https://h.io", profile: "")?.absoluteString ?? "", "https://h.io/v1/models")
        checkTrue("bad profile → nil", HermesChat.modelsURL(baseURL: "https://h.io", profile: "../x") == nil)

        print("parseStreamFailure")
        checkTrue("stop", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#) == nil)
        checkTrue("null", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{"content":"x"},"finish_reason":null}]}"#) == nil)
        check("error + message", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{},"finish_reason":"error"}],"error":{"message":"boom"}}"#) ?? "", "boom")
        check("error no message", HermesChat.parseStreamFailure(#"data: {"choices":[{"delta":{},"finish_reason":"error"}]}"#) ?? "", "The agent stopped with an error.")
        checkTrue("non-data", HermesChat.parseStreamFailure(": keepalive") == nil)
        checkTrue("named event data", HermesChat.parseStreamFailure(#"data: {"tool":"terminal"}"#) == nil)

        print("error(status:body:)")
        let env = Data(#"{"error":{"message":"kaput","type":"x","code":"y"}}"#.utf8)
        check("401", HermesChat.error(status: 401, body: env), .unauthorized)
        check("404", HermesChat.error(status: 404, body: env), .notFound)
        check("429", HermesChat.error(status: 429, body: env), .busy)
        check("500 envelope", HermesChat.error(status: 500, body: env), .server("kaput"))
        check("500 bare", HermesChat.error(status: 500, body: Data()), .server("HTTP 500"))
        check("302", HermesChat.error(status: 302, body: Data()), .notHermes)

        print("agents / keys JSON")
        let agents = [a, HermesAgent(name: "x", baseURL: "http://localhost:1", profile: "", modelName: "hermes-agent")]
        check("agents round-trip", HermesChat.decodeAgents(HermesChat.encodeAgents(agents)), agents)
        check("agents garbage", HermesChat.decodeAgents("not json"), [])
        let keys = [
            "mark": HermesChat.KeyRecord(key: "k1", baseURL: "https://h.io", profile: "mark"),
            "x": HermesChat.KeyRecord(key: "k2", baseURL: "http://localhost:1", profile: ""),
        ]
        check("keys round-trip", HermesChat.decodeKeys(HermesChat.encodeKeys(keys)), keys)
        check("keys garbage", HermesChat.decodeKeys("nope"), [:])
        checkTrue("agents JSON has no key material", !HermesChat.encodeAgents(agents).contains("k1"))

        print("sanitiseAgents")
        let dup = HermesAgent(name: "mark", baseURL: "https://other.io", profile: "", modelName: "m")
        check("duplicate name dropped, first wins", HermesChat.sanitiseAgents([a, dup]), [a])
        let httpPublic = HermesAgent(name: "p", baseURL: "http://example.com", profile: "", modelName: "m")
        let slash = HermesAgent(name: "s", baseURL: "https://h.io/", profile: "", modelName: "m")
        let badProfile = HermesAgent(name: "b", baseURL: "https://h.io", profile: "../x", modelName: "m")
        let digits = HermesAgent(name: "d", baseURL: "http://134744072", profile: "", modelName: "m")
        let noName = HermesAgent(name: "", baseURL: "https://h.io", profile: "", modelName: "m")
        check("http public, non-normal, bad profile, digit host, no name dropped",
              HermesChat.sanitiseAgents([httpPublic, slash, badProfile, digits, noName, a]), [a])
        let tampered = HermesChat.encodeAgents([HermesAgent(name: "mark", baseURL: "https://attacker.example/", profile: "", modelName: "m")])
        check("loaded entry that does not round-trip is dropped", HermesChat.decodeAgents(tampered), [])
        check("chatURL refuses an invalid stored agent", HermesChat.chatURL(for: httpPublic) == nil, true)

        print("boundKey")
        func bound(_ agent: HermesAgent, _ k: [String: HermesChat.KeyRecord]) -> String {
            switch HermesChat.boundKey(for: agent, in: k) {
            case .success(let key): return key
            case .failure(let e): return "ERR:\(e)"
            }
        }
        let good = ["mark": HermesChat.KeyRecord(key: "k1", baseURL: "https://h.io", profile: "mark")]
        check("matching binding returns the key", bound(a, good), "k1")
        check("different host refused", bound(HermesAgent(name: "mark", baseURL: "https://attacker.example", profile: "mark", modelName: "m"), good), "ERR:notBound(\"mark\")")
        check("different profile refused", bound(HermesAgent(name: "mark", baseURL: "https://h.io", profile: "other", modelName: "m"), good), "ERR:notBound(\"mark\")")
        check("scheme change refused", bound(HermesAgent(name: "mark", baseURL: "http://localhost:1", profile: "mark", modelName: "m"), good), "ERR:notBound(\"mark\")")
        check("no record refused", bound(a, [:]), "ERR:notBound(\"mark\")")
        check("empty key refused", bound(a, ["mark": HermesChat.KeyRecord(key: "", baseURL: "https://h.io", profile: "mark")]), "ERR:notBound(\"mark\")")
        let oldFormat = HermesChat.decodeKeys(#"{"mark":"k1"}"#)
        check("previous format decodes with the key", oldFormat["mark"]?.key ?? "", "k1")
        check("previous format counts as not bound", bound(a, oldFormat), "ERR:notBound(\"mark\")")
        checkTrue("notBound message asks to reconnect", HermesChatError.notBound("mark").userMessage.contains("connect it again"))

        // ── Integration against the fake server ──────────────────────────────
        print("connect")
        func conn(_ profile: String, _ key: String, _ b: String = base) async -> (String?, HermesChatError?) {
            switch await HermesChat.connect(baseURL: b, profile: profile, key: key) {
            case .success(let m): return (m, nil)
            case .failure(let e): return (nil, e)
            }
        }
        var r = await conn("", "test-key-default")
        check("default ok", r.0 ?? "", "hermes-agent")
        r = await conn("mark", "test-key-mark")
        check("mark ok", r.0 ?? "", "mark")
        r = await conn("mark", "test-key-default")
        check("default key on /p/mark → unauthorized", r.1, .unauthorized)
        r = await conn("mark", "")
        check("empty key → unauthorized", r.1, .unauthorized)
        r = await conn("nobody", "test-key-mark")
        check("unknown profile → notFound", r.1, .notFound)
        r = await conn("", "test-key-default", base + "/dashboard")
        check("html page → notHermes", r.1, .notHermes)
        r = await conn("", "test-key-default", base + "/sso")
        check("redirect not followed → notHermes", r.1, .notHermes)
        r = await conn("", "test-key-default", "http://127.0.0.1:1")
        checkTrue("closed port → unreachable", isUnreachable(r.1))

        print("streamChat")
        func body(_ text: String, model: String = "mark") -> Data {
            let b: [String: Any] = ["model": model, "stream": true, "messages": [["role": "user", "content": text]]]
            return (try? JSONSerialization.data(withJSONObject: b)) ?? Data()
        }
        let markAgent = HermesAgent(name: "mark", baseURL: base, profile: "mark", modelName: "mark")
        let tokens = Box()
        do {
            let text = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi")) { visible in
                tokens.calls += 1; tokens.last = visible
            }
            check("exact text, frames skipped", text, "Hello from mark.")
            checkTrue("onToken called", tokens.calls >= 1)
            check("last onToken is the full text", tokens.last, "Hello from mark.")
        } catch { print("  ✗ unexpected: \(error)"); failures += 1 }

        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("fail")) { _ in }
            print("  ✗ fail: expected throw"); failures += 1
        } catch { check("fail → agentFailed(boom)", error as? HermesChatError, .agentFailed("boom")) }

        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("busy")) { _ in }
            print("  ✗ busy: expected throw"); failures += 1
        } catch { check("busy → busy", error as? HermesChatError, .busy) }

        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "wrong", encodedBody: body("hi")) { _ in }
            print("  ✗ 401: expected throw"); failures += 1
        } catch { check("wrong key → unauthorized", error as? HermesChatError, .unauthorized) }

        do {
            let dead = HermesAgent(name: "d", baseURL: "http://127.0.0.1:1", profile: "", modelName: "hermes-agent")
            _ = try await HermesChat.streamChat(agent: dead, key: "k", encodedBody: body("hi")) { _ in }
            print("  ✗ closed port: expected throw"); failures += 1
        } catch { checkTrue("closed port → unreachable", isUnreachable(error as? HermesChatError)) }

        print("interrupted streams keep the text and say so")
        func run(_ prompt: String, limits: HermesChat.Limits = .standard) async -> (String?, HermesChatError?, Double) {
            let t0 = Date()
            do {
                let t = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body(prompt), limits: limits) { _ in }
                return (t, nil, Date().timeIntervalSince(t0))
            } catch { return (nil, error as? HermesChatError, Date().timeIntervalSince(t0)) }
        }
        var rr = await run("content_error")
        check("content then error: text kept + note", rr.0 ?? "", "Partial answer.\n\n" + HermesChat.interruptedNote)
        rr = await run("content_closed")
        check("content then closed socket: text kept + note", rr.0 ?? "", "Partial answer.\n\n" + HermesChat.interruptedNote)
        rr = await run("content_reset")
        check("content then reset: text kept + note", rr.0 ?? "", "Partial answer.\n\n" + HermesChat.interruptedNote)

        print("steps: SSEFrames (pure)")
        var fr = HermesChat.SSEFrames()
        check("a data line alone is a plain frame", fr.feed("data: {}")?.data ?? "-", "{}")
        check("... with no event name", fr.feed("data: {}")?.event ?? "none", "none")
        check("event then data is a named frame", fr.feed("event: hermes.tool.progress") == nil, true)
        let named = fr.feed("data: {\"a\":1}")
        check("... the name", named?.event ?? "none", "hermes.tool.progress")
        check("... the data", named?.data ?? "-", "{\"a\":1}")
        check("the name is used once: the next data line is plain", fr.feed("data: {\"b\":2}")?.event ?? "none", "none")
        _ = fr.feed("event: approval.request")
        check("a blank line clears the pending name", fr.feed("") == nil, true)
        check("... so the next data line is plain", fr.feed("data: {}")?.event ?? "none", "none")
        check("a keepalive comment gives nothing", fr.feed(": keepalive") == nil, true)
        _ = fr.feed("event: hermes.status")
        check("a keepalive between event and data keeps the name", fr.feed(": keepalive") == nil && fr.feed("data: {}")?.event == "hermes.status", true)
        _ = fr.feed("event: lonely")
        check("event with no data gives nothing", fr.feed("") == nil, true)
        check("a line that is neither gives nothing", fr.feed("id: 4") == nil, true)

        print("steps: parseToolProgress (pure)")
        let tp = HermesChat.parseToolProgress(#"{"tool":"terminal","emoji":"x","label":"ls -la","toolCallId":"c1","status":"running"}"#)
        check("running is read", tp, HermesChat.ToolProgress(id: "c1", tool: "terminal", label: "ls -la", running: true))
        check("completed is read", HermesChat.parseToolProgress(#"{"tool":"terminal","toolCallId":"c1","status":"completed"}"#),
              HermesChat.ToolProgress(id: "c1", tool: "terminal", label: "", running: false))
        checkTrue("a missing toolCallId gives nil", HermesChat.parseToolProgress(#"{"tool":"t","status":"running"}"#) == nil)
        checkTrue("a missing tool gives nil", HermesChat.parseToolProgress(#"{"toolCallId":"c","status":"running"}"#) == nil)
        checkTrue("an unknown status gives nil", HermesChat.parseToolProgress(#"{"tool":"t","toolCallId":"c","status":"failed"}"#) == nil)
        checkTrue("a non JSON payload gives nil", HermesChat.parseToolProgress("not json") == nil)
        check("a running frame without label has an empty label", HermesChat.parseToolProgress(#"{"tool":"t","toolCallId":"c","status":"running"}"#)?.label ?? "-", "")

        print("steps over the fake")
        final class SegLog: @unchecked Sendable {
            var calls = 0
            var last: [ChatSegment] = []
            var everRunningAfterLast = false
            var all: [[ChatSegment]] = []      // every call, not only the last
            var tokens: [String] = []          // every onToken value
        }
        func desc(_ segs: [ChatSegment]) -> [String] {
            segs.map { seg in
                switch seg.kind {
                case .text(let t, let role): return "\(role):\(t)"
                case .step(let st): return "step:\(st.tool)|\(st.label)|\(st.status)"
                case .note(let n): return "note:\(n)"
                case .hiddenSteps: return "hidden"
                case .edit, .moment: return "timeline"
                }
            }
        }
        func runSegs(_ prompt: String, limits: HermesChat.Limits = .standard) async -> (text: String?, error: HermesChatError?, log: SegLog) {
            let log = SegLog()
            do {
                let t = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body(prompt), limits: limits,
                                                        onToken: { log.tokens.append($0) },
                                                        onSegments: { segs in log.calls += 1; log.last = segs; log.all.append(segs) })
                return (t, nil, log)
            } catch { return (nil, error as? HermesChatError, log) }
        }
        func noRunning(_ segs: [ChatSegment]) -> Bool {
            !segs.contains { if case .step(let s) = $0.kind { return s.status == .running }; return false }
        }
        let stepsRun = await runSegs("steps")
        let offRun = await runSegs("steps_off")
        check("3 steps: interim, done step, answer", desc(stepsRun.log.last),
              ["interim:Let me check the page.", "step:terminal|curl -s graph.facebook.com/v19.0/me|done", "answer:The page is limited."])
        check("3 steps: the returned string equals the string of steps_off (the text path did not move)",
              stepsRun.text ?? "-", offRun.text ?? "+")
        check("3 steps: ... and is the text with the blank line, as today", stepsRun.text ?? "-", "Let me check the page.\n\nThe page is limited.")
        check("4 steps_off: one answer segment", desc(offRun.log.last), ["answer:Let me check the page.\n\nThe page is limited."])
        let apprRun = await runSegs("approval")
        check("5 approval: the existing sentence is the only trace",
              desc(apprRun.log.last), ["interim:I need to run a command.", "note:" + HermesChat.approvalNote, "answer:Waiting."])
        check("5 approval: the returned string is unchanged by the approval frame", apprRun.text ?? "-", "I need to run a command.\n\nWaiting.")
        checkTrue("5 approval: the command of the request is nowhere",
                  !desc(apprRun.log.last).joined().contains("APPROVAL_COMMAND_MARKER_88") && !(apprRun.text ?? "").contains("APPROVAL_COMMAND_MARKER_88"))
        let longRun = await runSegs("long_label")
        if case .step(let st)? = longRun.log.last.compactMap({ seg -> ChatSegment.Kind? in if case .step = seg.kind { return seg.kind }; return nil }).first {
            check("6 long_label: the label is 120 characters", st.label.count, 120)
        } else { print("  ✗ 6 long_label: no step"); failures += 1 }
        let statusRun = await runSegs("status")
        check("7 status: no row for it, and the text is untouched", desc(statusRun.log.last), ["answer:Before. After."])
        check("7 status: the returned string", statusRun.text ?? "-", "Before. After.")
        checkTrue("7 status: its text is nowhere", !desc(statusRun.log.last).joined().contains("STATUS_MARKER_99"))
        let cutRun = await runSegs("cut_in_tool")
        check("8 a turn cut in the middle of a tool: the step is stopped, the interrupted note is a row",
              desc(cutRun.log.last), ["interim:Starting.", "step:terminal|sleep 100|stopped", "note:" + HermesChat.interruptedNote])
        check("8 ... the string keeps its note as today", cutRun.text ?? "-", "Starting.\n\n" + HermesChat.interruptedNote)
        let failRun = await runSegs("fail")
        check("8b a failed turn throws", failRun.error, .agentFailed("boom"))
        checkTrue("8b ... and the rows it left have no running step", noRunning(failRun.log.last) && failRun.log.calls >= 1)
        let defRun = await runSegs("hi")
        check("default turn: a done step then the answer", desc(defRun.log.last), ["step:terminal|curl -s localhost|done", "answer:Hello from mark."])
        check("... reasoning is not read", desc(defRun.log.last).joined().contains("thinking about it"), false)
        checkTrue("every normal end leaves no running step", [stepsRun, offRun, apprRun, longRun, statusRun, cutRun, defRun].allSatisfy { noRunning($0.log.last) })
        let reasoningRun = desc(stepsRun.log.last).joined() + (stepsRun.text ?? "")
        checkTrue("the reasoning text is nowhere", !reasoningRun.contains("REASONING_MARKER_77"))
        let two = await runSegs("steps2")
        check("end to end, two tools",
              desc(two.log.last),
              ["interim:Let me check the page.", "step:terminal|curl -s graph.facebook.com/v19.0/me|done",
               "interim:The restriction has an unlock date. Checking the queue.", "step:mongo_query|automations-flow, last 48h|done",
               "answer:**Yes.** The page is *limited* now."])
        print("  e2e API key segments: " + desc(two.log.last).joined(separator: " ⏎ "))
        print("  e2e API key returned: " + (two.text ?? "-").replacingOccurrences(of: "\n", with: "\\n"))

        print("steps: review fixes")
        func seg(_ id: Int, _ t: String, _ r: ChatSegment.TextRole) -> ChatSegment { ChatSegment(id: id, kind: .text(t, role: r)) }
        func stepRow(_ id: Int) -> ChatSegment {
            ChatSegment(id: id, kind: .step(ChatStep(callId: "c\(id)", tool: "t", label: "l", detail: nil, status: .done)))
        }
        check("10 a think block that opens before a tool and closes after it is hidden in both halves",
              desc(HermesChat.displaySegments([seg(0, "<think>secret plan A", .interim), stepRow(1),
                                               seg(2, "secret plan B</think>Visible answer.", .answer)])),
              ["step:t|l|done", "answer:Visible answer."])
        check("10b text before the open block stays, text after the closing tag shows",
              desc(HermesChat.displaySegments([seg(0, "Hello. <think>plan part one", .interim), stepRow(1),
                                               seg(2, "plan part two</think>Answer.", .answer)])),
              ["interim:Hello.", "step:t|l|done", "answer:Answer."])
        check("10c two blocks across three rows",
              desc(HermesChat.displaySegments([seg(0, "A<think>x", .interim), stepRow(1), seg(2, "y</think>B<think>z", .interim),
                                               stepRow(3), seg(4, "w</think>C", .answer)])),
              ["interim:A", "step:t|l|done", "interim:B", "step:t|l|done", "answer:C"])
        check("10d a block that never closes hides every later text row, not the steps",
              desc(HermesChat.displaySegments([seg(0, "<think>never", .interim), stepRow(1), seg(2, "later", .open)])),
              ["step:t|l|done"])
        for sample in ["a<think>b</think>c", "<think>x", "plain", "</think>x", "a <think>b</think> c <think>d", "  spaced  ", "<think>a</think>"] {
            let want = LocalChat.progressiveFilter(sample)
            check("10e one row is filtered as the text is: \(sample.debugDescription)",
                  desc(HermesChat.displaySegments([seg(0, sample, .answer)])), want.isEmpty ? [] : ["answer:" + want])
        }
        let thinkRun = await runSegs("think_split")
        check("10f over the fake, a think block split by a tool: the rows",
              desc(thinkRun.log.last),
              ["interim:Hello.", "step:terminal|ls|done", "interim:Mid text.", "step:terminal|ls|done", "answer:Answer."])
        check("10f ... the returned string is as before", thinkRun.text ?? "-", "Hello. Mid text.\n\nAnswer.")
        checkTrue("10f ... no row of any call, no token, shows the reasoning",
                  !(thinkRun.log.all.flatMap(desc) + thinkRun.log.tokens).joined().contains("plan part"))
        let reuseRun = await runSegs("reuse_id")
        check("11 a call id used again after its completion is a second step",
              desc(reuseRun.log.last),
              ["interim:First.", "step:terminal|ls|done", "interim:Again.", "step:terminal|ls|done", "answer:Answer."])
        check("11 ... the returned string is as before", reuseRun.text ?? "-", "First.\n\nAgain.\n\nAnswer.")
        let burstRun = await runSegs("burst")
        checkTrue("12 a burst of a hundred tools makes few row updates (\(burstRun.log.calls))", burstRun.log.calls >= 1 && burstRun.log.calls <= 2 * StepPublishBudget.perSecond + 2)
        checkTrue("12 ... few token updates (\(burstRun.log.tokens.count))", burstRun.log.tokens.count <= 4)
        check("12 ... and the last rows hold sixty steps, one hidden row, the answer",
              [desc(burstRun.log.last).filter { $0.hasPrefix("step:") }.count, desc(burstRun.log.last).filter { $0 == "hidden" }.count,
               desc(burstRun.log.last).last == "answer:Burst done." ? 1 : 0], [60, 1, 1])
        check("12 ... the string", burstRun.text ?? "-", "Burst done.")
        print("steps: round 3 (budget, end of turn think filter)")
        final class Timed: @unchecked Sendable { var t0 = Date(); var rows: [(at: Double, rows: [ChatSegment])] = [] }
        func runTimed(_ prompt: String) async -> (text: String?, log: Timed) {
            let log = Timed()
            log.t0 = Date()
            let t = try? await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body(prompt), onToken: { _ in },
                                                     onSegments: { log.rows.append((Date().timeIntervalSince(log.t0), $0)) })
            return (t, log)
        }
        let seq3 = await runTimed("seq3")
        print("  timing proof, API key, seq3 (the fake pauses 0.5 s before each completion):")
        for r in seq3.log.rows { print(String(format: "    +%.2fs  ", r.at) + desc(r.rows).map { $0.replacingOccurrences(of: "step:terminal|", with: "") }.joined(separator: " | ")) }
        let seqStates = seq3.log.rows.map { desc($0.rows) }
        checkTrue("50 the second tool of a round is published as running before its completion frame",
                  seq3.log.rows.contains { r in let d = desc(r.rows); return d.contains("step:terminal|two|running") && d.contains("step:terminal|one|done") && !d.contains("step:terminal|three|running") && r.at < 0.45 })
        checkTrue("50b ... and so is the third, with the second done, before the third completes",
                  seqStates.contains { $0.contains("step:terminal|three|running") && $0.contains("step:terminal|two|done") })
        check("50c ... the rows at the end", desc(seq3.log.rows.last?.rows ?? []),
              ["interim:Look.", "step:terminal|one|done", "step:terminal|two|done", "step:terminal|three|done", "answer:Answer."])
        check("50d ... the returned string is as before", seq3.text ?? "-", "Look.\n\nAnswer.")
        let tt = await runTimed("text_tool")
        print("  timing proof, API key, text_tool (a sentence and a tool start in one write, 0.6 s before the completion):")
        for r in tt.log.rows { print(String(format: "    +%.2fs  ", r.at) + desc(r.rows).map { $0.replacingOccurrences(of: "step:terminal|", with: "") }.joined(separator: " | ")) }
        checkTrue("51 a tool start in the same write as the sentence before it is published at once",
                  tt.log.rows.contains { desc($0.rows).contains("step:terminal|work|running") && $0.at < 0.5 })
        func final(_ prompt: String) async -> (text: String?, log: SegLog) { let r = await runSegs(prompt); return (r.text, r.log) }
        let thinkOpen = await final("think_open")
        check("52 a think tag with no closing tag: the rows show the whole turn, as the stored text holds it",
              desc(thinkOpen.log.last),
              ["interim:Hi. <think>plan", "step:terminal|ls|done", "interim:More.", "step:terminal|ls|done", "answer:Answer."])
        check("52 ... the returned string is as before", thinkOpen.text ?? "-", "Hi. <think>plan\n\nMore.\n\nAnswer.")
        let literal = await final("think_literal")
        check("52b an answer that names the tag in inline code is shown whole", desc(literal.log.last),
              ["answer:Use the `<think>` tag for reasoning. Then answer."])
        func seg2(_ id: Int, _ t: String, _ r: ChatSegment.TextRole) -> ChatSegment { ChatSegment(id: id, kind: .text(t, role: r)) }
        func step2(_ id: Int) -> ChatSegment {
            ChatSegment(id: id, kind: .step(ChatStep(callId: "c\(id)", tool: "t", label: "l", detail: nil, status: .done)))
        }
        check("53 at the end, a block closed across a tool is hidden in both rows",
              desc(HermesChat.finalDisplaySegments([seg2(0, "<think>secret plan A", .interim), step2(1), seg2(2, "secret plan B</think>Visible.", .answer)])),
              ["step:t|l|done", "answer:Visible."])
        check("53b ... text around the block stays",
              desc(HermesChat.finalDisplaySegments([seg2(0, "Hello. <think>plan one", .interim), step2(1), seg2(2, "plan two</think>Answer.", .answer)])),
              ["interim:Hello.", "step:t|l|done", "answer:Answer."])
        check("53c ... an open block after a closed one stays whole, as the stored text",
              desc(HermesChat.finalDisplaySegments([seg2(0, "A<think>x</think>B<think>never", .interim), step2(1), seg2(2, "later", .answer)])),
              ["interim:AB<think>never", "step:t|l|done", "answer:later"])
        for sample in ["a<think>b</think>c", "<think>x", "plain", "</think>x", "a <think>b</think> c <think>d", "  spaced  ", "<think>a</think>", "`<think>` tag"] {
            let want = LocalChat.filterThinkingBlocks(sample)
            check("53d one row at the end is filtered as the returned string is: \(sample.debugDescription)",
                  desc(HermesChat.finalDisplaySegments([seg2(0, sample, .answer)])), want.isEmpty ? [] : ["answer:" + want])
        }

        // One published write per tick: with onTurn the two callbacks are not used.
        final class TurnLog: @unchecked Sendable { var calls = 0; var both = 0; var content: String?; var rows: [ChatSegment] = []; var separate = 0 }
        let tlog = TurnLog()
        let turnText = try? await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("steps2"),
                                                        onToken: { _ in tlog.separate += 1 }, onSegments: { _ in tlog.separate += 1 },
                                                        onTurn: { c, r in
                                                            tlog.calls += 1
                                                            if c != nil && r != nil { tlog.both += 1 }
                                                            if let c { tlog.content = c }
                                                            if let r { tlog.rows = r }
                                                        })
        check("13 with onTurn, the two separate callbacks are never called", tlog.separate, 0)
        checkTrue("13 ... the rows and the text arrive through it", tlog.calls >= 1 && tlog.content != nil && desc(tlog.rows) == desc(two.log.last))
        check("13 ... and the returned string is the same", turnText ?? "-", two.text ?? "+")
        // Privacy: every call, every token, the returned string.
        let markers = ["REASONING_MARKER_77", "APPROVAL_COMMAND_MARKER_88", "STATUS_MARKER_99", "💻", "🗄️", "🔧"]
        for (name, run) in [("steps", stepsRun), ("steps_off", offRun), ("approval", apprRun), ("status", statusRun), ("steps2", two),
                            ("default", defRun), ("think_split", thinkRun), ("reuse_id", reuseRun), ("burst", burstRun)] {
            let seen = (run.log.all.flatMap(desc) + run.log.tokens + [run.text ?? ""]).joined(separator: "\n")
            checkTrue("15 \(name): no marker and no emoji in any row, any token or the returned string", !markers.contains { seen.contains($0) })
        }

        print("steps: the request body and the history")
        // What the app does after a turn with steps: the assistant entry is the returned string, nothing else.
        let history: [String: Any] = ["model": "mark", "stream": true, "messages": [
            ["role": "user", "content": "steps"],
            ["role": "assistant", "content": stepsRun.text ?? ""],
            ["role": "user", "content": "next"]]]
        let historyBody = (try? JSONSerialization.data(withJSONObject: history)) ?? Data()
        _ = try? await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: historyBody) { _ in }
        let seen = (try? await URLSession.shared.data(from: URL(string: base + "/_test/last_body")!))?.0 ?? Data()
        check("9 streamChat sends the body it is given untouched (byte for byte)", seen, historyBody)
        let seenJSON = (try? JSONSerialization.jsonObject(with: seen)) as? [String: Any]
        let seenMsgs = (seenJSON?["messages"] as? [[String: Any]]) ?? []
        check("9 ... the assistant message in it is the string the test put there", seenMsgs.count > 1 ? (seenMsgs[1]["content"] as? String ?? "-") : "-", stepsRun.text ?? "+")
        let seenText = String(decoding: seen, as: UTF8.self)
        checkTrue("9 ... and a body the test built holds no label, no tool name, no note (the transport adds none)",
                  !seenText.contains("graph.facebook.com") && !seenText.contains("terminal") && !seenText.contains(HermesChat.approvalNote)
                    && !seenText.contains(HermesChat.interruptedNote))

        print("media directives: the transport keeps the text as the server sent it, and asks for nothing else")
        await ctl("/_test/reset")
        let mediaRun = await { () -> String? in
            try? await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("media"), onToken: { _ in })
        }()
        let mediaSent = "Primeiro audio. 6s.\n\n[[audio_as_voice]]\nMEDIA:/tmp/AI Brain/her-new-photos.ogg\n\nOuve e me fala."
        check("16 the stored text is byte for byte the deltas, directives and all", mediaRun ?? "-", mediaSent)
        let mediaHistory: [String: Any] = ["model": "mark", "stream": true, "messages": [
            ["role": "user", "content": "media"], ["role": "assistant", "content": mediaRun ?? ""], ["role": "user", "content": "next"]]]
        let mediaBody = (try? JSONSerialization.data(withJSONObject: mediaHistory)) ?? Data()
        _ = try? await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: mediaBody) { _ in }
        let mediaSeen = (try? await URLSession.shared.data(from: URL(string: base + "/_test/last_body")!))?.0 ?? Data()
        let mediaMsgs = (((try? JSONSerialization.jsonObject(with: mediaSeen)) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
        check("16 the next request carries it unchanged", mediaMsgs.count > 1 ? (mediaMsgs[1]["content"] as? String ?? "-") : "-", mediaSent)
        check("16 no request other than the chat requests reaches the server (a path in an answer is never fetched)", await hits("other_hits"), 0)
        check("16 ... exactly the two chat requests", await hits("chat_hits"), 2)

        // The history the app sends is built by one pure function (ClaudeService calls it): rows never enter it.
        let storedMessages: [[String: Any]] = [
            ["role": "user", "content": [["type": "text", "text": "steps"], ["type": "image_url", "image_url": "x"]]],
            ["role": "assistant", "content": stepsRun.text ?? ""],
            ["role": "user", "content": "next"]]
        let built = HermesChat.requestMessages(from: storedMessages)
        check("14 the history keeps the roles and the text of each message", built.map { ($0["role"] as? String ?? "-") + ":" + ($0["content"] as? String ?? "-") },
              ["user:steps", "assistant:" + (stepsRun.text ?? ""), "user:next"])
        let builtJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: built, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
        let rowWords = desc(stepsRun.log.last).filter { !$0.hasPrefix("answer:") && !$0.hasPrefix("interim:") }
        checkTrue("14 ... and holds no step, label, tool name or note of the rows",
                  !builtJSON.contains("graph.facebook.com") && !builtJSON.contains("terminal") && !builtJSON.contains(HermesChat.approvalNote)
                    && !builtJSON.contains(HermesChat.interruptedNote) && !builtJSON.contains("running") && !rowWords.isEmpty)
        check("14 ... the same dictionaries are used for a message that is already text", built.count, 3)

        print("limits")
        var small = HermesChat.Limits()
        small.lineBytes = 2048
        rr = await run("longline", limits: small)
        check("line over the cap, no text → message", rr.1, .agentFailed(HermesChat.tooLongNote))
        small = HermesChat.Limits()
        small.textChars = 1000
        rr = await run("bigtext", limits: small)
        checkTrue("text over the cap: kept, truncated, noted", (rr.0 ?? "").hasSuffix(HermesChat.tooLongNote) && (rr.0 ?? "").hasPrefix("Start. yyy") && (rr.0 ?? "").count < 1100)
        small = HermesChat.Limits()
        small.duration = 0.6
        rr = await run("slow", limits: small)
        check("duration cap: text kept + note", rr.0 ?? "", "Slow start.\n\n" + HermesChat.tooSlowNote)
        checkTrue("duration cap ended the turn well before the server did", rr.2 < 5)
        small = HermesChat.Limits()
        small.connectBodyBytes = 1000
        switch await HermesChat.connect(baseURL: base + "/big", profile: "", key: "test-key-default", limits: small) {
        case .failure(let e): check("connect body over the cap", e, .server("The server answer is too large for a Hermes API."))
        case .success: print("  ✗ connect body over the cap: expected failure"); failures += 1
        }
        switch await HermesChat.connect(baseURL: base + "/big", profile: "", key: "test-key-default") {
        case .success(let m): check("100 KB body under no small cap is refused by the 64 KB default", m, "never")
        case .failure(let e): check("connect body over the 64 KB default", e, .server("The server answer is too large for a Hermes API."))
        }

        print("connect retry policy (pure)")
        let std = HermesChat.ConnectRetry.standard
        check("3 attempts", std.attempts, 3)
        check("6 s per attempt", std.attemptTimeout, 6)
        check("wait after attempt 1", std.delay(afterAttempt: 1), 0.3)
        check("wait after attempt 2", std.delay(afterAttempt: 2), 1)
        check("no attempt after the 3rd", std.delay(afterAttempt: 3), nil)
        check("attempt 0 is not a thing", std.delay(afterAttempt: 0), nil)
        let connectLevel: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed]
        // A POST with side effects: retried only when it is certain that no body byte left the machine.
        for c in connectLevel {
            checkTrue("sideEffects: \(c.rawValue) with 0 bytes sent is retried", std.isRetryable(c, rule: .sideEffects, bytesSent: 0))
            checkTrue("sideEffects: \(c.rawValue) with the bytes unknown is retried (no byte can leave before it connects)", std.isRetryable(c, rule: .sideEffects, bytesSent: nil))
            checkTrue("sideEffects: \(c.rawValue) with bytes sent is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: 1))
        }
        for c in [URLError.Code.timedOut, .networkConnectionLost] {
            checkTrue("sideEffects: \(c.rawValue) with 0 bytes sent is retried", std.isRetryable(c, rule: .sideEffects, bytesSent: 0))
            checkTrue("sideEffects: \(c.rawValue) after the body went out is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: 1))
            checkTrue("sideEffects: \(c.rawValue) after the whole body went out is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: 4096))
            checkTrue("sideEffects: \(c.rawValue) with the bytes unknown is final", !std.isRetryable(c, rule: .sideEffects, bytesSent: nil))
        }
        // Idempotent (GET, WebSocket handshake, ticket POST): connection lost is retried as well.
        for c in connectLevel + [.networkConnectionLost] {
            checkTrue("idempotent: \(c.rawValue) is retried", std.isRetryable(c, rule: .idempotent, bytesSent: 0))
            checkTrue("idempotent: \(c.rawValue) is retried, bytes unknown", std.isRetryable(c, rule: .idempotent, bytesSent: nil))
        }
        checkTrue("idempotent: a timeout before any body byte is retried", std.isRetryable(.timedOut, rule: .idempotent, bytesSent: 0))
        checkTrue("idempotent: a timeout after the body went out is a slow server, not retried", !std.isRetryable(.timedOut, rule: .idempotent, bytesSent: 10))
        for rule in [HermesChat.ConnectRetry.Rule.idempotent, .sideEffects] {
            for c in [URLError.Code.cancelled, .badServerResponse, .cannotParseResponse, .serverCertificateUntrusted, .badURL, .unsupportedURL, .notConnectedToInternet, .dataLengthExceedsMaximum] {
                checkTrue("never retried (\(rule)): \(c.rawValue)", !std.isRetryable(c, rule: rule, bytesSent: 0))
            }
        }
        let t0c = ContinuousClock.now
        check("deadline far away: waits", std.mayRetry(afterAttempt: 1, now: t0c, deadline: t0c.advanced(by: .seconds(20))), 0.3)
        check("no deadline: waits", std.mayRetry(afterAttempt: 2, now: t0c, deadline: nil), 1)
        check("an attempt that cannot finish before the deadline does not start", std.mayRetry(afterAttempt: 1, now: t0c, deadline: t0c.advanced(by: .seconds(6))), nil)
        check("no attempts left", std.mayRetry(afterAttempt: 3, now: t0c, deadline: nil), nil)
        checkTrue("the budget leaves room for three attempts of a step plus about 10 s of successful round trips",
                  std.budget >= Double(std.attempts) * std.attemptTimeout + std.backoff.reduce(0, +) + 10)

        print("connect retry (API key path)")
        final class Lines: @unchecked Sendable {
            let lock = NSLock()
            var v: [String] = []
            func add(_ s: String) { lock.withLock { v.append(s) } }
            var all: [String] { lock.withLock { v } }
            func reset() { lock.withLock { v = [] } }
        }
        let lines = Lines()
        HermesChat.Diagnostics.setSink { lines.add($0) }
        func ctl(_ path: String, _ json: [String: Any] = [:]) async {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = "POST"
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
            _ = try? await URLSession.shared.data(for: req)
        }
        func hits(_ k: String) async -> Int {
            guard let (d, _) = try? await URLSession.shared.data(from: URL(string: base + "/_test/state")!),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Int] else { return -1 }
            return j[k] ?? -1
        }
        /// Runs `op`; nil when it does not finish within `seconds` (a retry that never gives up would hang the suite).
        func within<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
            await withTaskGroup(of: T?.self) { g in
                g.addTask { await op() }
                g.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
                let first = await g.next() ?? nil
                g.cancelAll()
                return first
            }
        }
        let sseAnswer = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
            + "data: {\"choices\":[{\"delta\":{\"content\":\"Hello from the listener.\"},\"finish_reason\":null}]}\n\n"
            + "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let modelsJSON = "{\"object\":\"list\",\"data\":[{\"id\":\"listener-model\"}]}"
        let modelsAnswer = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(modelsJSON.utf8.count)\r\n\r\n" + modelsJSON
        @Sendable func agentAt(_ port: UInt16) -> HermesAgent {
            HermesAgent(name: "mark", baseURL: "http://127.0.0.1:\(port)", profile: "", modelName: "", connection: nil)
        }
        @Sendable func chatTo(_ port: UInt16, _ limits: HermesChat.Limits) async -> Result<String, HermesChatError> {
            do {
                return .success(try await HermesChat.streamChat(agent: agentAt(port), key: "test-key-mark", encodedBody: body("hi"), limits: limits) { _ in })
            } catch { return .failure((error as? HermesChatError) ?? .unreachable("?")) }
        }
        func limits(backoff: [TimeInterval]) -> HermesChat.Limits {
            var l = HermesChat.Limits.standard
            l.connectRetry = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: 0.5, backoff: backoff, budget: 20)
            return l
        }
        let fast = limits(backoff: [0.05, 0.1])
        let late = limits(backoff: [0.3, 0.6])
        func isUnreachableResult(_ r: Result<String, HermesChatError>?) -> Bool {
            if case .failure(let e)? = r { return isUnreachable(e) }
            return false
        }

        // GET /v1/models is idempotent: connection lost is retried. URLSession itself repeats an idempotent GET up to
        // twice when the connection closes without an answer, so the server may see more than one request per Coucou
        // attempt: those counts are bounds, not exact.
        await ctl("/_test/reset")
        await ctl("/_test/config", ["models_drop": 2])
        switch await HermesChat.connect(baseURL: base, profile: "", key: "test-key-default", limits: fast) {
        case .success(let m): check("GET models: two lost connections, then the answer", m, "hermes-agent")
        case .failure(let e): print("  ✗ connect after 2 drops: \(e)"); failures += 1
        }
        checkTrue("GET models: the lost connections reached the server before the answer", await hits("models_hits") >= 3)

        await ctl("/_test/reset")
        lines.reset()
        await ctl("/_test/config", ["models_drop": 100])
        switch await HermesChat.connect(baseURL: base, profile: "", key: "test-key-default", limits: fast) {
        case .success: print("  ✗ connect: expected failure"); failures += 1
        case .failure(let e): checkTrue("GET models: all attempts lost → unreachable", isUnreachable(e))
        }
        let modelHits = await hits("models_hits")
        checkTrue("GET models: three attempts, no more (URLSession itself repeats a GET up to twice)", modelHits >= 3 && modelHits <= 9)
        checkTrue("GET models: the connect failure is logged with step and attempts", lines.all.contains("hermes connect failed step=models attempts=3"))
        checkTrue("the log carries no URL, host or key", lines.all.allSatisfy { !$0.contains("127.0.0.1") && !$0.contains("test-key") && !$0.contains("http") })

        await ctl("/_test/reset")
        switch await HermesChat.connect(baseURL: base, profile: "", key: "wrong", limits: fast) {
        case .success: print("  ✗ 401: expected failure"); failures += 1
        case .failure(let e): check("GET models: an HTTP answer (401) is final", e, .unauthorized)
        }
        check("GET models: a 401 is not retried", await hits("models_hits"), 1)

        // A slow but healthy server: the first attempts are cut at attemptTimeout, the last keeps the old allowance.
        await ctl("/_test/reset")
        lines.reset()
        await ctl("/_test/config", ["models_stall": 1.2, "models_stall_count": 3])
        let tSlow = Date()
        switch await HermesChat.connect(baseURL: base, profile: "", key: "test-key-default", limits: fast) {
        case .success(let m): check("GET models: a server that answers after 1.2 s (> attempt timeout) still works", m, "hermes-agent")
        case .failure(let e): print("  ✗ slow healthy GET failed: \(e)"); failures += 1
        }
        checkTrue("GET models: it took the last attempt's longer allowance, not a failure", Date().timeIntervalSince(tSlow) >= 1.2)
        check("GET models: three requests (two cut, the last answered)", await hits("models_hits"), 3)

        // POST chat, a server that READS THE WHOLE BODY and then drops the connection: exactly one request.
        await ctl("/_test/reset")
        lines.reset()
        await ctl("/_test/config", ["chat_drop": 3])
        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi"), limits: fast) { _ in }
            print("  ✗ chat: expected failure"); failures += 1
        } catch { checkTrue("chat: body delivered, connection dropped → unreachable", isUnreachable(error as? HermesChatError)) }
        check("chat: the server saw exactly ONE request (a request that reached it is never sent again)", await hits("chat_hits"), 1)
        checkTrue("chat: logged as a failed request with the body sent, not as a connect failure",
                  lines.all.contains("hermes request failed step=chat attempts=1 sent=true") && !lines.all.contains { $0.hasPrefix("hermes connect failed") })

        await ctl("/_test/reset")
        await ctl("/_test/config", ["chat_status": 500])
        do {
            _ = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi"), limits: fast) { _ in }
            print("  ✗ 500: expected failure"); failures += 1
        } catch { check("chat: a 500 is reported as is", error as? HermesChatError, .server("injected")) }
        check("chat: a request that got a response (500) is never retried", await hits("chat_hits"), 1)

        await ctl("/_test/reset")
        await ctl("/_test/config", ["chat_stall": 1.5, "chat_stall_count": 1])
        do {
            let t = try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("hi"), limits: fast) { _ in }
            check("chat: a slow answer after the request went out still arrives", t, "Hello from mark.")
        } catch { print("  ✗ chat slow headers: \(error)"); failures += 1 }
        check("chat: the slow answer is not a connect failure, so the turn is not started twice", await hits("chat_hits"), 1)

        // POST chat, a connection that is refused (nothing listens): nothing left the machine, so it is retried.
        lines.reset()
        if let dead = StallingListener.closedPort() {
            let tRef = Date()
            let r = await within(8) { await chatTo(dead, fast) }
            check("chat: connection refused on every attempt → unreachable", isUnreachableResult(r), true)
            checkTrue("chat: refused is retried three times", lines.all.contains("hermes connect failed step=chat attempts=3"))
            checkTrue("chat: ... and quickly", Date().timeIntervalSince(tRef) < 4)

            // ... and it recovers when the server comes up between attempts.
            lines.reset()
            let revive = Task { () -> StallingListener? in
                try? await Task.sleep(for: .seconds(0.15))
                let l = StallingListener(port: dead)
                l?.serve(sseAnswer)
                return l
            }
            let got = await within(8) { await chatTo(dead, late) }
            let srv = await revive.value
            if case .success(let t)? = got { check("chat: refused, then the server is up: the answer arrives", t, "Hello from the listener.") }
            else { print("  ✗ chat after refused: \(String(describing: got))"); failures += 1 }
            check("chat: the body reached the server once", srv?.requests, 1)
            checkTrue("chat: the recovery is logged", lines.all.contains { $0.hasPrefix("hermes connect recovered step=chat attempts=") })
            srv?.stop()
        } else { print("  ✗ no free port"); failures += 1 }

        // The reported failure mode: a connection that never completes (the kernel drops the SYN).
        print("connect retry (connection that never completes)")
        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let t = Date()
            let r = await within(8) { await chatTo(hang.port, fast) }
            let took = Date().timeIntervalSince(t)
            check("chat: never completes → unreachable after the attempts (without retries this waits the 300 s request timeout)",
                  isUnreachableResult(r), true)
            checkTrue("chat: three attempts, each cut at the attempt timeout (\(String(format: "%.1f", took)) s)", took >= 1.5 && took < 5)
            checkTrue("chat: logged as a connect failure with three attempts", lines.all.contains("hermes connect failed step=chat attempts=3"))
            check("chat: no request ever reached the server", hang.requests, 0)
            hang.stop()
        } else { print("  ✗ could not build the stalled listener"); failures += 1 }

        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let release = Task { try? await Task.sleep(for: .seconds(0.2)); hang.serve(sseAnswer) }
            let r = await within(8) { await chatTo(hang.port, fast) }
            await release.value
            if case .success(let t)? = r { check("chat: the first connection hangs, a later attempt gets through", t, "Hello from the listener.") }
            else { print("  ✗ chat after a hang: \(String(describing: r))"); failures += 1 }
            check("chat: the body reached the server exactly once", hang.requests, 1)
            hang.stop()
        }

        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let t = Date()
            let m = await within(20) { await HermesChat.connect(baseURL: "http://127.0.0.1:\(hang.port)", profile: "", key: "test-key-default", limits: fast) }
            let took = Date().timeIntervalSince(t)
            if case .failure(let e)? = m { checkTrue("GET models: never completes → unreachable", isUnreachable(e)) }
            else { print("  ✗ GET models on a hang: \(String(describing: m))"); failures += 1 }
            checkTrue("GET models: two attempts cut at the attempt timeout, the last is not cut at 0.5 s but runs on the request's own 10 s timeout (\(String(format: "%.1f", took)) s)",
                      took >= 5 && took < 14)
            checkTrue("GET models: logged with three attempts", lines.all.contains("hermes connect failed step=models attempts=3"))
            hang.stop()
        }

        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let release = Task { try? await Task.sleep(for: .seconds(0.2)); hang.serve(modelsAnswer) }
            let m = await within(8) { await HermesChat.connect(baseURL: "http://127.0.0.1:\(hang.port)", profile: "", key: "test-key-default", limits: fast) }
            await release.value
            if case .success(let id)? = m { check("GET models: a hung connection, then the answer", id, "listener-model") }
            else { print("  ✗ GET models after a hang: \(String(describing: m))"); failures += 1 }
            hang.stop()
        }

        // Cancellation during a backoff (a refused connection is retried; nothing else is needed to get there).
        if let dead = StallingListener.closedPort() {
            var sb = HermesChat.Limits.standard
            sb.connectRetry = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: 0.5, backoff: [30, 30], budget: 100)
            let slowBackoff = sb
            let cs = Task { await chatTo(dead, slowBackoff) }
            let cs2 = Task { try await HermesChat.streamChat(agent: agentAt(dead), key: "test-key-mark", encodedBody: body("hi"), limits: slowBackoff) { _ in } }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let tc = Date()
            cs.cancel(); cs2.cancel()
            do { _ = try await cs2.value; print("  ✗ cancelled retry returned"); failures += 1 }
            catch { checkTrue("chat: cancelling during the backoff throws CancellationError", error is CancellationError) }
            _ = await cs.value
            checkTrue("chat: ... at once, not after the 30 s backoff", Date().timeIntervalSince(tc) < 2)
        }
        HermesChat.Diagnostics.setSink(nil)
        await ctl("/_test/reset")

        print("cancellation")
        let t0 = Date()
        let task = Task { try await HermesChat.streamChat(agent: markAgent, key: "test-key-mark", encodedBody: body("slow")) { _ in } }
        try? await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        do { _ = try await task.value; print("  ✗ cancelled stream returned"); failures += 1 }
        catch { checkTrue("cancelled stream throws CancellationError", error is CancellationError) }
        checkTrue("cancel ended the turn promptly", Date().timeIntervalSince(t0) < 4)

        print("request shape (model field, no system message)")
        if let url = HermesChat.chatURL(for: markAgent) {
            check("model echoed", await headerValue(url, "test-key-mark", "X-Test-Model", body: String(decoding: body("hi", model: "mark"), as: UTF8.self)) ?? "", "mark")
            check("no system message", await headerValue(url, "test-key-mark", "X-Test-System", body: String(decoding: body("hi"), as: UTF8.self)) ?? "", "0")
        }

        await approvalTests(base: base)

        finish()
    }

    private static func finish() -> Never {
        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed.")
        exit(1)
    }
}
