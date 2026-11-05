import Foundation

// MARK: - Test harness (same style as HermesChatTests). Runs against tests/fake_hermes_dashboard.py on 127.0.0.1.

@main
enum HermesSignInTests {

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

    typealias SI = HermesSignIn

    final class Box: @unchecked Sendable {
        var value = ""
        var port = 0
        var lsof = ""
        var favicon = 0
        var tokens: [String] = []
        var sessionIDs: [String] = []
        var strayWrongState = ""
        var strayWrongHost = ""
        var stillListening = false
    }

    static var base = ""

    // MARK: Fake server control

    static func ctl(_ path: String, _ json: [String: Any] = [:]) async {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        _ = try? await URLSession.shared.data(for: req)
    }

    static func state() async -> [String: Any] {
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: base + "/_test/state")!),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    static func int(_ s: [String: Any], _ k: String) -> Int { (s[k] as? NSNumber)?.intValue ?? -1 }
    static func interrupts() async -> Int { ((await state())["interrupts"] as? [Any])?.count ?? 0 }

    /// The RPCs the fake saw, without `client.capabilities` (which every socket sends first; counted on its own).
    static func rpcLog(_ s: [String: Any]) -> [[String: Any]] {
        ((s["rpc"] as? [[String: Any]]) ?? []).filter { ($0["method"] as? String) != "client.capabilities" }
    }
    static func capabilityCalls(_ s: [String: Any]) -> [[String: Any]] { (s["capabilities"] as? [[String: Any]]) ?? [] }
    static func methods(_ s: [String: Any]) -> [String] { rpcLog(s).compactMap { $0["method"] as? String } }

    static func waitFor(_ timeout: Double = 3, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await cond()
    }

    // MARK: Sessions

    final class Mem: @unchecked Sendable {
        let lock = NSLock()
        var v = ""
        var value: String { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    static func makeSessions(_ mem: Mem, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                             retry: HermesChat.ConnectRetry = .standard) -> HermesSessions {
        HermesSessions(storage: HermesSessionStorage(load: { mem.value }, save: { mem.value = $0 }), now: now, connectRetry: retry)
    }

    static func record(_ mem: Mem, _ name: String = "steve") -> SI.SessionRecord? { SI.decodeSessions(mem.value)[name] }

    static func agent(profile: String = "codex", name: String = "steve") -> HermesAgent {
        HermesAgent(name: name, baseURL: base, profile: profile, modelName: "", connection: .signIn)
    }

    /// Real sign in against the fake (the "browser" is a URLSession that follows the 302), then stored.
    static func signedIn(_ mem: Mem, sessions: HermesSessions, name: String = "steve") async -> SI.SessionRecord? {
        let r = await HermesSignInNet.signIn(baseURL: base, timeout: 10) { url in
            Task { _ = try? await URLSession.shared.data(from: url) }
        }
        guard case .success(var rec) = r else { return nil }
        rec.label = "Test User"
        await sessions.store(rec, name: name)
        return rec
    }

    /// A raw HTTP request to the loopback listener (so the test controls the Host header). Returns the status line.
    static func raw(port: Int, request: String) async -> String {
        await Task.detached { () -> String in
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return "" }
            defer { close(fd) }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port)).bigEndian
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard ok == 0 else { return "" }
            let bytes = Array(request.utf8)
            _ = send(fd, bytes, bytes.count, 0)
            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(fd, &buf, buf.count, 0)
            return n > 0 ? String(decoding: buf[0..<n], as: UTF8.self).components(separatedBy: "\r\n").first ?? "" : ""
        }.value
    }

    static func lsof(port: Int) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    static func connects(port: Int) async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/callback")!, timeoutInterval: 2)
        req.httpMethod = "GET"
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    static func port(of authorizeURL: URL) -> Int {
        guard let c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false),
              let r = c.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let p = URL(string: r)?.port else { return 0 }
        return p
    }

    // MARK: Turns

    struct TurnResult { var text: String?; var error: Error?; var stored: String?; var tokens: [String] }

    static func turn(_ a: HermesAgent, _ sessions: HermesSessions, _ text: String, stored: String? = nil,
                     limits: HermesChat.Limits = .standard) async -> TurnResult {
        let box = Box()
        do {
            let t = try await HermesSignInNet.streamTurn(agent: a, sessions: sessions, storedSession: stored, text: text,
                                                         limits: limits,
                                                         onSession: { box.sessionIDs.append($0) },
                                                         onToken: { box.tokens.append($0) })
            return TurnResult(text: t, error: nil, stored: box.sessionIDs.last, tokens: box.tokens)
        } catch {
            return TurnResult(text: nil, error: error, stored: box.sessionIDs.last, tokens: box.tokens)
        }
    }

    final class RowLog: @unchecked Sendable { var calls = 0; var last: [ChatSegment] = []; var all: [[ChatSegment]] = [] }

    /// A turn that also keeps the rows it was given (the last call is what the chat ends with).
    static func turnRows(_ a: HermesAgent, _ sessions: HermesSessions, _ text: String, stored: String? = nil,
                         limits: HermesChat.Limits = .standard) async -> (result: TurnResult, rows: RowLog) {
        let box = Box()
        let log = RowLog()
        do {
            let t = try await HermesSignInNet.streamTurn(agent: a, sessions: sessions, storedSession: stored, text: text,
                                                         limits: limits,
                                                         onSession: { box.sessionIDs.append($0) },
                                                         onToken: { box.tokens.append($0) },
                                                         onSegments: { log.calls += 1; log.last = $0; log.all.append($0) })
            return (TurnResult(text: t, error: nil, stored: box.sessionIDs.last, tokens: box.tokens), log)
        } catch {
            return (TurnResult(text: nil, error: error, stored: box.sessionIDs.last, tokens: box.tokens), log)
        }
    }

    final class TimedLog: @unchecked Sendable { var t0 = Date(); var rows: [(at: Double, rows: [ChatSegment])] = [] }

    /// A turn that keeps every call of `onSegments` with its offset from the start of the call.
    static func timedRows(_ a: HermesAgent, _ sessions: HermesSessions, _ text: String) async -> TimedLog {
        let log = TimedLog()
        log.t0 = Date()
        _ = try? await HermesSignInNet.streamTurn(agent: a, sessions: sessions, storedSession: nil, text: text,
                                                  onSession: { _ in }, onToken: { _ in },
                                                  onSegments: { log.rows.append((Date().timeIntervalSince(log.t0), $0)) })
        return log
    }

    static func describe(_ segs: [ChatSegment]) -> [String] {
        segs.map { seg in
            switch seg.kind {
            case .text(let t, let role): return "\(role):\(t)"
            case .step(let st): return "step:\(st.tool)|\(st.label)|\(st.detail ?? "-")|\(st.status)"
            case .note(let n): return "note:\(n)"
            case .hiddenSteps: return "hidden"
            case .edit, .moment: return "timeline"
            }
        }
    }

    static func chatError(_ r: TurnResult) -> HermesChatError? { r.error as? HermesChatError }

    // MARK: Main

    static func main() async {
        let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0"
        base = "http://127.0.0.1:\(port)"

        pureTests()
        await endToEnd()
        await approvalTests()
        await connectRetryTests()
        finish()
    }

    // MARK: Connection retry

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var v: [String] = []
        func add(_ s: String) { lock.withLock { v.append(s) } }
        var all: [String] { lock.withLock { v } }
        func reset() { lock.withLock { v = [] } }
    }

    static func wsForms(_ s: [String: Any]) -> [String] {
        ((s["ws"] as? [[String: Any]]) ?? []).map { ($0["form"] as? String ?? "?") + ($0["accepted"] as? Bool == true ? "+" : "-") }
    }

    static func submits(_ s: [String: Any]) -> Int { methods(s).filter { $0 == "prompt.submit" }.count }

    /// Runs `op`; nil when it does not finish within `seconds` (a retry that never gives up would hang the suite).
    static func within<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await op() }
            g.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    static func connectRetryTests() async {
        let lines = Lines()
        HermesChat.Diagnostics.setSink { lines.add($0) }
        defer { HermesChat.Diagnostics.setSink(nil) }
        // Same shape as the real policy, with the per attempt wait and the backoff scaled down.
        let fastPolicy = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: 0.6, backoff: [0.05, 0.1], budget: 20)
        var fast = HermesChat.Limits.standard
        fast.connectRetry = fastPolicy

        let mem = Mem()
        let ses = makeSessions(mem, retry: fastPolicy)
        let ag = agent()
        func fresh() async -> Bool {
            await ctl("/_test/reset")
            lines.reset()
            mem.value = ""
            return await signedIn(mem, sessions: ses) != nil
        }

        print("retry: ticket request that never gets an answer")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ticket_drop": 2])
        var x = await turn(ag, ses, "hello", limits: fast)
        check("two lost ticket connections, the third works", x.text, "Hello from Steve.")
        var st = await state()
        check("three ticket requests reached the server", int(st, "ticket_count"), 3)
        check("prompt.submit was sent exactly once", submits(st), 1)
        check("one socket", ((st["ws"] as? [Any]) ?? []).count, 1)
        checkTrue("recovery logged with the step and the attempts", lines.all.contains("hermes connect recovered step=ticket attempts=3"))

        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ticket_drop": 3])
        x = await turn(ag, ses, "hello", limits: fast)
        check("all three ticket attempts lost: unreachable", chatError(x), .unreachable("127.0.0.1"))
        st = await state()
        check("exactly three ticket requests", int(st, "ticket_count"), 3)
        check("no socket was opened", ((st["ws"] as? [Any]) ?? []).count, 0)
        check("no prompt.submit", submits(st), 0)
        checkTrue("failure logged with the step and the attempts", lines.all.contains("hermes connect failed step=ticket attempts=3"))
        checkTrue("diagnostics carry no URL, host or token",
                  lines.all.allSatisfy { !$0.contains("127.0.0.1") && !$0.contains("http") && !$0.contains("at-") && !$0.contains("rt-") })

        print("retry: a ticket answer is final, whatever the status")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ticket_status": 500])
        x = await turn(ag, ses, "hello", limits: fast)
        check("500 is reported", chatError(x), .server("HTTP 500"))
        check("a 500 is not retried", int(await state(), "ticket_count"), 1)
        await ctl("/_test/config", ["ticket_status": 503])
        x = await turn(ag, ses, "hello", limits: fast)
        check("503 is busy", chatError(x), .busy)
        check("a 503 is not retried either", int(await state(), "ticket_count"), 2)

        // A handshake that is dropped is repeated by URLSession itself (it repeats an idempotent GET), so a dropped
        // handshake is checked for its outcome only; the attempts of Coucou are counted with stalled handshakes,
        // which only Coucou's own attempt timeout can end.
        print("retry: WebSocket handshake that drops")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ws_drop": 2])
        x = await turn(ag, ses, "hello", limits: fast)
        check("dropped handshakes, then an open socket", x.text, "Hello from Steve.")
        st = await state()
        check("prompt.submit was sent exactly once", submits(st), 1)

        print("retry: WebSocket handshake that stalls past the attempt timeout")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ws_stall": 2, "ws_stall_seconds": 3])
        let t0 = Date()
        x = await turn(ag, ses, "hello", limits: fast)
        check("two stalled handshakes, the third opens", x.text, "Hello from Steve.")
        checkTrue("each stalled one was cut at the attempt timeout, not waited for", Date().timeIntervalSince(t0) < 2.8)
        st = await state()
        check("three handshakes, all in the subprotocol form, the last accepted", wsForms(st), ["?-", "?-", "subprotocol+"])
        check("a fresh ticket for every attempt", int(st, "ticket_count"), 3)
        check("prompt.submit was sent exactly once", submits(st), 1)
        checkTrue("recovery logged with the step and the attempts", lines.all.contains("hermes connect recovered step=socket attempts=3"))

        print("retry: all subprotocol handshakes stall, the query form gets its own attempts")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ws_stall": 3, "ws_stall_seconds": 3])
        x = await turn(ag, ses, "hello", limits: fast)
        check("falls back after three attempts", x.text, "Hello from Steve.")
        st = await state()
        check("three stalled, then the query form accepted", wsForms(st), ["?-", "?-", "?-", "query+"])
        check("a ticket per handshake", int(st, "ticket_count"), 4)
        check("prompt.submit was sent exactly once", submits(st), 1)

        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ws_stall": 6, "ws_stall_seconds": 3])
        x = await turn(ag, ses, "hello", limits: fast)
        check("both forms stall: unreachable", chatError(x), .unreachable("127.0.0.1"))
        st = await state()
        check("three attempts per form", ((st["ws"] as? [Any]) ?? []).count, 6)
        check("never a prompt.submit", submits(st), 0)
        checkTrue("failure logged for the socket step", lines.all.contains("hermes connect failed step=socket attempts=3"))

        print("retry: a refused handshake is not retried in the same form")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["reject_subprotocol": true])
        x = await turn(ag, ses, "hello", limits: fast)
        check("fallback to the query form", x.text, "Hello from Steve.")
        st = await state()
        check("one refused handshake, one accepted", wsForms(st), ["subprotocol-", "query+"])
        check("no retry of the refused form", int(st, "ticket_count"), 2)

        print("retry: the budget keeps the worst case short")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ws_stall": 6, "ws_stall_seconds": 3])
        var tight = HermesChat.Limits.standard
        tight.connectRetry = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: 0.6, backoff: [0.05, 0.1], budget: 0.5)
        x = await turn(ag, ses, "hello", limits: tight)
        check("over budget: unreachable", chatError(x), .unreachable("127.0.0.1"))
        check("no retry past the budget, no query fallback", ((await state())["ws"] as? [Any])?.count, 1)

        print("retry: nothing after prompt.submit is retried")
        guard await fresh() else { failures += 1; return }
        x = await turn(ag, ses, "close", limits: fast)
        check("the socket closes during the turn: the partial answer is kept", x.error == nil, true)
        st = await state()
        check("one handshake", ((st["ws"] as? [Any]) ?? []).count, 1)
        check("prompt.submit exactly once", submits(st), 1)
        check("one ticket", int(st, "ticket_count"), 1)

        print("retry: cancellation during a backoff")
        guard await fresh() else { failures += 1; return }
        await ctl("/_test/config", ["ticket_drop": 3])
        var slow = HermesChat.Limits.standard
        slow.connectRetry = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: 0.6, backoff: [30, 30], budget: 100)
        let task = Task { await turn(ag, ses, "hello", limits: slow) }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let tc = Date()
        task.cancel()
        let cancelled = await task.value
        checkTrue("CancellationError", cancelled.error is CancellationError)
        checkTrue("at once", Date().timeIntervalSince(tc) < 2)
        check("no further ticket request", int(await state(), "ticket_count"), 1)

        print("retry: refresh (a POST with side effects: repeated only when no body byte left the machine)")
        guard await fresh() else { failures += 1; return }
        var expired = record(mem)!
        let before = expired
        expired.expiresAt = Date().timeIntervalSince1970 - 10
        await ses.store(expired, name: "steve")
        await ctl("/_test/config", ["refresh_drop": 3])
        x = await turn(ag, ses, "hello", limits: fast)
        check("the server READ the refresh body, then dropped the connection: busy, nothing removed", chatError(x), .busy)
        check("the server saw exactly ONE refresh request (a request that reached it is never sent again)", int(await state(), "refresh_count"), 1)
        check("the tokens are kept", record(mem)?.refreshToken, before.refreshToken)
        checkTrue("logged as a failed request with the body sent, not as a connect failure",
                  lines.all.contains("hermes request failed step=refresh attempts=1 sent=true") && !lines.all.contains { $0.hasPrefix("hermes connect failed") })

        guard await fresh() else { failures += 1; return }
        expired = record(mem)!
        expired.expiresAt = Date().timeIntervalSince1970 - 10
        await ses.store(expired, name: "steve")
        await ctl("/_test/config", ["refresh_mode": "503"])
        x = await turn(ag, ses, "hello", limits: fast)
        check("a 503 on refresh: the token is expired, so busy", chatError(x), .busy)
        check("a refresh that got an answer is never repeated", int(await state(), "refresh_count"), 1)
        check("the tokens are kept", record(mem)?.refreshToken, expired.refreshToken)

        guard await fresh() else { failures += 1; return }
        expired = record(mem)!
        expired.expiresAt = Date().timeIntervalSince1970 - 10
        await ses.store(expired, name: "steve")
        x = await turn(ag, ses, "hello", limits: fast)
        check("a normal refresh still rotates the token", x.text, "Hello from Steve.")
        checkTrue("the rotated tokens were stored", record(mem)?.refreshToken != expired.refreshToken)

        // Connect level failures of the refresh, against a listener of our own (no byte can leave).
        let refreshAnswer = "{\"access_token\":\"at-from-the-listener-0123456789\",\"refresh_token\":\"rt-from-the-listener\",\"expires_at\":9999999999}"
        let refreshHTTP = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(refreshAnswer.utf8.count)\r\n\r\n" + refreshAnswer
        func listenerRecord(_ port: UInt16) -> SI.SessionRecord {
            var r = record(mem)!
            r.baseURL = "http://127.0.0.1:\(port)"
            return r
        }
        func isRefreshed(_ o: HermesSessions.RefreshOutcome?) -> Bool { if case .refreshed? = o { return true }; return false }
        func isUnavailable(_ o: HermesSessions.RefreshOutcome?) -> Bool { if case .unavailable? = o { return true }; return false }

        guard await fresh() else { failures += 1; return }
        if let dead = StallingListener.closedPort() {
            let rec = listenerRecord(dead)
            let t = Date()
            let o = await HermesSignInNet.refresh(record: rec, retry: fastPolicy)
            checkTrue("refresh: connection refused on every attempt → unavailable (tokens kept by the caller)", isUnavailable(o))
            checkTrue("refresh: a refused connection is retried three times", lines.all.contains("hermes connect failed step=refresh attempts=3"))
            checkTrue("refresh: ... and quickly", Date().timeIntervalSince(t) < 4)
            lines.reset()
            let revive = Task { () -> StallingListener? in
                try? await Task.sleep(for: .seconds(0.15))
                let l = StallingListener(port: dead)
                l?.serve(refreshHTTP)
                return l
            }
            var lateRetry = fastPolicy
            lateRetry.backoff = [0.3, 0.6]
            let o2 = await HermesSignInNet.refresh(record: rec, retry: lateRetry)
            let srv = await revive.value
            checkTrue("refresh: refused, then the server is up: the refresh goes through", isRefreshed(o2))
            check("refresh: the body reached the server exactly once", srv?.requests, 1)
            checkTrue("refresh: recovery logged", lines.all.contains { $0.hasPrefix("hermes connect recovered step=refresh attempts=") })
            srv?.stop()
        } else { print("  ✗ no free port"); failures += 1 }

        print("retry: refresh on a connection that never completes (the reported failure mode)")
        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let rec = listenerRecord(hang.port)
            let t = Date()
            let o = await within(8) { await HermesSignInNet.refresh(record: rec, retry: fastPolicy) }
            let took = Date().timeIntervalSince(t)
            checkTrue("refresh: gives up after the attempts (without retries it waits the 15 s request timeout)", isUnavailable(o))
            checkTrue("refresh: three attempts, each cut at the attempt timeout (\(String(format: "%.1f", took)) s)", took >= 1.5 && took < 5)
            checkTrue("refresh: logged with three attempts", lines.all.contains("hermes connect failed step=refresh attempts=3"))
            check("refresh: no request ever reached the server", hang.requests, 0)
            hang.stop()
        } else { print("  ✗ could not build the stalled listener"); failures += 1 }

        lines.reset()
        if let hang = StallingListener(fillBacklog: true) {
            let rec = listenerRecord(hang.port)
            let release = Task { try? await Task.sleep(for: .seconds(0.2)); hang.serve(refreshHTTP) }
            let o = await within(8) { await HermesSignInNet.refresh(record: rec, retry: fastPolicy) }
            await release.value
            checkTrue("refresh: the first connection hangs, a later attempt gets through", isRefreshed(o))
            check("refresh: the body reached the server exactly once", hang.requests, 1)
            hang.stop()
        }

        print("retry: the refresh counts against the turn's budget and is not repeated for every ticket")
        guard await fresh() else { failures += 1; return }
        var near = record(mem)!
        near.expiresAt = Date().timeIntervalSince1970 + 10   // inside the 60 s refresh window, still valid
        await ses.store(near, name: "steve")
        await ctl("/_test/config", ["refresh_drop": 100, "ws_stall": 2, "ws_stall_seconds": 3])
        x = await turn(ag, ses, "hello", limits: fast)
        check("the turn works with the access token that is still valid", x.text, "Hello from Steve.")
        st = await state()
        check("three tickets (two stalled handshakes, then the open one)", int(st, "ticket_count"), 3)
        check("the refresh ran once for the whole turn (one request, it is not repeated per ticket)", int(st, "refresh_count"), 1)

        print("retry: the real budget to attempt ratio keeps the third handshake attempt with slow tickets")
        guard await fresh() else { failures += 1; return }
        let attemptT = 0.6
        let ratio = HermesChat.ConnectRetry.standard.budget / HermesChat.ConnectRetry.standard.attemptTimeout
        var real = HermesChat.Limits.standard
        real.connectRetry = HermesChat.ConnectRetry(attempts: 3, attemptTimeout: attemptT, backoff: [0.05, 0.1], budget: ratio * attemptT)
        await ctl("/_test/config", ["ws_stall": 2, "ws_stall_seconds": 3, "ticket_delay": 0.3])
        x = await turn(ag, ses, "hello", limits: real)
        check("two stalled handshakes after 0.3 s tickets: the third attempt still happens", x.text, "Hello from Steve.")
        // The form of the third one is not asserted here: with a 0.6 s attempt on a slow machine the subprotocol form may
        // not get ready in time and the query form opens instead, which is the designed fallback. The forms are checked above.
        let lateForms = wsForms(await state())
        checkTrue("three handshakes, the last accepted", lateForms.count == 3 && lateForms.prefix(2) == ["?-", "?-"] && lateForms.last?.hasSuffix("+") == true)

        print("retry: profiles and me")
        guard await fresh() else { failures += 1; return }
        let tok = record(mem)!.accessToken
        await ctl("/_test/config", ["profiles_drop": 2])
        if case .success(let p) = await HermesSignInNet.profiles(baseURL: base, token: tok, retry: fastPolicy) {
            check("profiles after two lost connections", p.map(\.name), ["default", "codex"])
        } else { print("  ✗ profiles failed"); failures += 1 }
        await ctl("/_test/config", ["profiles_drop": 100])
        if case .failure(let e) = await HermesSignInNet.profiles(baseURL: base, token: tok, retry: fastPolicy) {
            check("profiles never reached: unreachable", e, .unreachable("127.0.0.1"))
        } else { print("  ✗ profiles: expected failure"); failures += 1 }
        checkTrue("failure logged for profiles", lines.all.contains { $0.hasPrefix("hermes connect failed step=profiles attempts=") })
    }

    // MARK: Pure logic

    static func pureTests() {
        print("PKCE (RFC 7636 appendix B vector)")
        let vector: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                               22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        let p = SI.makePKCE(random: { n in n == 32 ? vector : [UInt8](repeating: 7, count: n) })
        check("verifier", p.verifier, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        check("challenge", p.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let a = SI.makePKCE(), b = SI.makePKCE()
        check("verifier length", a.verifier.count, 43)
        check("state length", a.state.count, 32)
        checkTrue("fresh randomness", a.verifier != b.verifier && a.state != b.state)
        checkTrue("base64url alphabet", a.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })

        print("redirect and authorize URLs")
        check("redirectURI", SI.redirectURI(port: 53682), "http://127.0.0.1:53682/callback")
        let pk = SI.PKCE(verifier: "v", challenge: "c-h_a", state: "s-t_8")
        let u = SI.authorizeURL(baseURL: "https://agent.example.com", pkce: pk, redirectURI: SI.redirectURI(port: 5), provider: nil)?.absoluteString ?? ""
        check("authorize URL", u, "https://agent.example.com/auth/native/authorize?code_challenge=c-h_a&code_challenge_method=S256&redirect_uri=http%3A%2F%2F127.0.0.1%3A5%2Fcallback&state=s-t_8")
        let u2 = SI.authorizeURL(baseURL: "https://agent.example.com/hermes", pkce: pk, redirectURI: SI.redirectURI(port: 5), provider: "self hosted")?.absoluteString ?? ""
        checkTrue("keeps the base path", u2.hasPrefix("https://agent.example.com/hermes/auth/native/authorize?"))
        checkTrue("provider encoded", u2.hasSuffix("&provider=self%20hosted"))
        check("not normalised base refused", SI.authorizeURL(baseURL: "https://agent.example.com/", pkce: pk, redirectURI: "x", provider: nil) == nil, true)
        check("http public host refused", SI.authorizeURL(baseURL: "http://agent.example.com", pkce: pk, redirectURI: "x", provider: nil) == nil, true)

        print("parseCallback")
        func cb(_ line: String, _ state: String = "S") -> String {
            switch SI.parseCallback(requestLine: line, expectedState: state) {
            case .success(let c): return "OK:\(c)"
            case .failure(let e): return "ERR:\(e.userMessage)"
            }
        }
        check("ok", cb("GET /callback?code=abc&state=S HTTP/1.1"), "OK:abc")
        check("extra params", cb("GET /callback?foo=1&code=abc&iss=x&state=S HTTP/1.1"), "OK:abc")
        check("wrong state", cb("GET /callback?code=abc&state=X HTTP/1.1"), "ERR:" + SI.stateMessage)
        check("missing state", cb("GET /callback?code=abc HTTP/1.1"), "ERR:" + SI.stateMessage)
        check("state checked before error", cb("GET /callback?error=access_denied&state=X HTTP/1.1"), "ERR:" + SI.stateMessage)
        check("error param", cb("GET /callback?error=access_denied&state=S HTTP/1.1"), "ERR:" + SI.refusedMessage)
        check("missing code", cb("GET /callback?state=S HTTP/1.1"), "ERR:" + SI.refusedMessage)
        check("empty code", cb("GET /callback?code=&state=S HTTP/1.1"), "ERR:" + SI.refusedMessage)
        check("wrong path", cb("GET /other?code=abc&state=S HTTP/1.1"), "ERR:" + SI.refusedMessage)
        check("wrong method", cb("POST /callback?code=abc&state=S HTTP/1.1"), "ERR:" + SI.refusedMessage)
        check("percent decoded code", cb("GET /callback?code=a%2Bb&state=S HTTP/1.1"), "OK:a+b")
        check("isCallback code", SI.isCallback(requestLine: "GET /callback?code=1&state=S HTTP/1.1", expectedState: "S"), true)
        check("isCallback error", SI.isCallback(requestLine: "GET /callback?error=x&state=S HTTP/1.1", expectedState: "S"), true)
        check("isCallback state only", SI.isCallback(requestLine: "GET /callback?state=S HTTP/1.1", expectedState: "S"), true)
        check("isCallback wrong state", SI.isCallback(requestLine: "GET /callback?code=1&state=X HTTP/1.1", expectedState: "S"), false)
        check("isCallback no state", SI.isCallback(requestLine: "GET /callback?code=1 HTTP/1.1", expectedState: "S"), false)
        check("isCallback bare", SI.isCallback(requestLine: "GET /callback HTTP/1.1", expectedState: "S"), false)
        check("isCallback favicon", SI.isCallback(requestLine: "GET /favicon.ico HTTP/1.1", expectedState: "S"), false)
        check("isCallback wrong path", SI.isCallback(requestLine: "GET /other?state=S HTTP/1.1", expectedState: "S"), false)
        check("isCallback garbage", SI.isCallback(requestLine: "\u{0}\u{1}", expectedState: "S"), false)

        print("parseTokenResponse")
        let tok = Data(#"{"access_token":"aaaaaaaaaaaaaaaaaaaa","refresh_token":"rrr","token_type":"Bearer","expires_at":1234567890,"provider":"self-hosted","user_id":"u1"}"#.utf8)
        let rec: SI.SessionRecord? = { if case .success(let r) = SI.parseTokenResponse(tok, baseURL: "https://h", previous: nil) { return r }; return nil }()
        check("access", rec?.accessToken, "aaaaaaaaaaaaaaaaaaaa")
        check("refresh", rec?.refreshToken, "rrr")
        check("expiry", rec?.expiresAt, 1234567890)
        check("provider and user", [rec?.provider, rec?.userID, rec?.baseURL], ["self-hosted", "u1", "https://h"])
        func parse(_ s: String, prev: SI.SessionRecord? = nil) -> SI.SessionRecord? {
            if case .success(let r) = SI.parseTokenResponse(Data(s.utf8), baseURL: "https://h", previous: prev) { return r }
            return nil
        }
        check("missing token", parse(#"{"refresh_token":"x"}"#) == nil, true)
        check("short token", parse(#"{"access_token":"short"}"#) == nil, true)
        check("token with a space", parse(#"{"access_token":"aaaaaaaa aaaaaaaaaaaa"}"#) == nil, true)
        check("not json", parse("nope") == nil, true)
        var prev = rec!
        prev.label = "Me"
        let kept = parse(#"{"access_token":"bbbbbbbbbbbbbbbbbbbb","refresh_token":""}"#, prev: prev)
        check("empty refresh keeps the previous one", kept?.refreshToken, "rrr")
        check("label kept on rotation", kept?.label, "Me")
        check("no previous and no refresh", parse(#"{"access_token":"bbbbbbbbbbbbbbbbbbbb"}"#)?.refreshToken, "")
        check("bad expiry becomes unknown", parse(#"{"access_token":"bbbbbbbbbbbbbbbbbbbb","expires_at":-5}"#)?.expiresAt, 0)
        check("string expiry becomes unknown", parse(#"{"access_token":"bbbbbbbbbbbbbbbbbbbb","expires_at":"soon"}"#)?.expiresAt, 0)

        print("tokenAction")
        func rc(_ exp: Double, rt: String) -> SI.SessionRecord {
            SI.SessionRecord(accessToken: "a", refreshToken: rt, expiresAt: exp, provider: "", userID: "", label: "", baseURL: "")
        }
        check("fresh", SI.tokenAction(rc(1000, rt: "r"), now: 900), .use)
        check("within skew refreshes", SI.tokenAction(rc(1000, rt: "r"), now: 950), .refresh)
        check("exactly at skew refreshes", SI.tokenAction(rc(1000, rt: "r"), now: 940), .refresh)
        check("just before skew", SI.tokenAction(rc(1000, rt: "r"), now: 939), .use)
        check("past expiry refreshes", SI.tokenAction(rc(1000, rt: "r"), now: 2000), .refresh)
        check("within skew without refresh token", SI.tokenAction(rc(1000, rt: ""), now: 950), .use)
        check("expired without refresh token", SI.tokenAction(rc(1000, rt: ""), now: 1000), .signInAgain)
        check("unknown expiry with refresh token", SI.tokenAction(rc(0, rt: "r"), now: 5), .refresh)
        check("unknown expiry without refresh token", SI.tokenAction(rc(0, rt: ""), now: 5), .use)

        print("session storage and binding")
        let sess = ["steve": rec!]
        check("round trip", SI.decodeSessions(SI.encodeSessions(sess)), sess)
        check("garbage decodes to empty", SI.decodeSessions("[[["), [:])
        var good = rec!
        good.baseURL = "https://agent.example.com"
        let ag = HermesAgent(name: "steve", baseURL: "https://agent.example.com", profile: "codex", modelName: "", connection: .signIn)
        func bound(_ a: HermesAgent, _ s: [String: SI.SessionRecord]) -> String {
            switch SI.boundSession(for: a, in: s) { case .success: return "OK"; case .failure(let e): return "ERR:\(e)" }
        }
        check("bound", bound(ag, ["steve": good]), "OK")
        check("other base URL", bound(HermesAgent(name: "steve", baseURL: "https://other.example.com", profile: "codex", modelName: "", connection: .signIn), ["steve": good]), "ERR:signInNeeded(\"steve\")")
        var other = good
        other.baseURL = "https://other.example.com"
        check("record for another URL", bound(ag, ["steve": other]), "ERR:signInNeeded(\"steve\")")
        check("api key agent", bound(HermesAgent(name: "steve", baseURL: "https://agent.example.com", profile: "codex", modelName: ""), ["steve": good]), "ERR:signInNeeded(\"steve\")")
        var empty = good
        empty.accessToken = ""
        check("empty token", bound(ag, ["steve": empty]), "ERR:signInNeeded(\"steve\")")
        check("no record", bound(ag, [:]), "ERR:signInNeeded(\"steve\")")
        check("unnormalised agent URL", bound(HermesAgent(name: "steve", baseURL: "https://agent.example.com/", profile: "", modelName: "", connection: .signIn), ["steve": good]), "ERR:signInNeeded(\"steve\")")

        print("agents storage compatibility")
        let old = #"[{"name":"mark","baseURL":"https://agent.example.com","profile":"mark","modelName":"mark"}]"#
        let decoded = HermesChat.decodeAgents(old)
        check("old JSON without connection decodes", decoded.count, 1)
        check("and reads as nil", decoded.first?.connection, nil)
        check("api key agent encodes without the field", HermesChat.encodeAgents(decoded).contains("connection"), false)
        let si = HermesAgent(name: "steve", baseURL: "https://agent.example.com", profile: "codex", modelName: "", connection: .signIn)
        check("sign in agent round trips", HermesChat.decodeAgents(HermesChat.encodeAgents([si])), [si])
        check("signInNeeded message", HermesChatError.signInNeeded("steve").userMessage, "Sign in to steve again in Settings → Chat.")

        print("URLs, tickets, profiles")
        check("endpoint", SI.endpoint("https://agent.example.com/x", "/api/ws")?.absoluteString, "https://agent.example.com/x/api/ws")
        check("endpoint refuses unnormalised", SI.endpoint("https://agent.example.com/", "/api/ws") == nil, true)
        check("endpoint refuses http public", SI.endpoint("http://agent.example.com", "/api/ws") == nil, true)
        check("endpoint refuses http to a single label name", SI.endpoint("http://mac-mini", "/api/ws") == nil, true)
        check("endpoint refuses http to a .local name", SI.endpoint("http://hermes.local", "/api/ws") == nil, true)
        check("endpoint refuses http to a private address", SI.endpoint("http://192.168.1.5:9119", "/api/ws") == nil, true)
        check("endpoint allows http to 127.0.0.1", SI.endpoint("http://127.0.0.1:9119", "/api/ws")?.absoluteString, "http://127.0.0.1:9119/api/ws")
        check("endpoint allows http to localhost", SI.endpoint("http://localhost:9119", "/api/ws")?.absoluteString, "http://localhost:9119/api/ws")
        check("endpoint allows http to ::1", SI.endpoint("http://[::1]:9119", "/api/ws")?.absoluteString, "http://[::1]:9119/api/ws")
        check("endpoint allows https to a private address", SI.endpoint("https://192.168.1.5", "/api/ws")?.absoluteString, "https://192.168.1.5/api/ws")
        check("authorize URL refuses http to a name", SI.authorizeURL(baseURL: "http://mac-mini", pkce: pk, redirectURI: "x", provider: nil) == nil, true)
        check("socket URL refuses http to a name", SI.socketURL(baseURL: "http://mac-mini", queryTicket: nil) == nil, true)
        check("socket URL with a query ticket refuses a non loopback ws target", SI.socketURL(baseURL: "http://hermes.local", queryTicket: "abcdefghijklmnopqrstuvwxyz0123456789-_") == nil, true)
        check("query ticket allowed on ws to loopback", SI.socketURL(baseURL: "http://127.0.0.1:9", queryTicket: "abcdefghijklmnopqrstuvwxyz0123456789-_")?.absoluteString, "ws://127.0.0.1:9/api/ws?ticket=abcdefghijklmnopqrstuvwxyz0123456789-_")
        check("loopback hosts", ["127.0.0.1", "localhost", "LOCALHOST", "::1"].map(SI.isLoopbackHost), [true, true, true, true])
        check("not loopback", ["10.0.0.1", "mac-mini", "x.local", "127.0.0.2", "example.com"].map(SI.isLoopbackHost), [false, false, false, false, false])
        check("endpoint needs a leading slash", SI.endpoint("https://agent.example.com", "api/ws") == nil, true)
        check("wss", SI.socketURL(baseURL: "https://agent.example.com", queryTicket: nil)?.absoluteString, "wss://agent.example.com/api/ws")
        check("ws", SI.socketURL(baseURL: "http://127.0.0.1:9", queryTicket: nil)?.absoluteString, "ws://127.0.0.1:9/api/ws")
        check("query ticket", SI.socketURL(baseURL: "https://h.example.com", queryTicket: "abcdefghijklmnopqrstuvwxyz0123456789-_")?.absoluteString, "wss://h.example.com/api/ws?ticket=abcdefghijklmnopqrstuvwxyz0123456789-_")
        check("bad query ticket", SI.socketURL(baseURL: "https://h.example.com", queryTicket: "a b") == nil, true)
        check("ticket protocols", SI.ticketProtocols("abcdefghijklmnop0123"), ["hermes-gateway-v1", "hermes-gateway-ticket.abcdefghijklmnop0123"])
        check("short ticket", SI.ticketProtocols("short") == nil, true)
        check("ticket with a comma", SI.ticketProtocols("abcdefghijklmnop,0123") == nil, true)
        check("ticket with a dot", SI.ticketProtocols("abcdefghijklmnop.0123") == nil, true)
        check("parseTicket", SI.parseTicket(Data(#"{"ticket":"abcdefghijklmnop0123","ttl_seconds":30}"#.utf8)), "abcdefghijklmnop0123")
        check("parseTicket bad", SI.parseTicket(Data(#"{"ticket":"x y"}"#.utf8)) == nil, true)
        let profs = SI.parseProfiles(Data(#"{"profiles":[{"name":"default","is_default":true,"display_name":"Default"},{"name":"codex","display_name":"  "},{"name":"bad name!"},{"name":"codex"},{"nope":1}]}"#.utf8))
        check("profiles", profs, [SI.Profile(name: "default", title: "Default", isDefault: true), SI.Profile(name: "codex", title: "codex", isDefault: false)])
        check("profiles garbage", SI.parseProfiles(Data("x".utf8)), [])
        check("me display name", SI.parseMe(Data(#"{"user_id":"u","email":"e@x","display_name":"Ann"}"#.utf8)), "Ann")
        check("me email fallback", SI.parseMe(Data(#"{"user_id":"u","email":"e@x","display_name":""}"#.utf8)), "e@x")
        check("me nothing", SI.parseMe(Data("{}".utf8)), nil)
        check("401 is expired", SI.isSessionExpired(status: 401, body: Data()), true)
        check("200 is not", SI.isSessionExpired(status: 200, body: Data()), false)

        print("JSON-RPC frames")
        let req = SI.request(id: 3, method: "prompt.submit", params: ["session_id": "r1", "text": "hi"])
        check("request frame", req, #"{"id":3,"jsonrpc":"2.0","method":"prompt.submit","params":{"session_id":"r1","text":"hi"}}"#)
        check("rejection frame", SI.rejection(id: "srq-1"), #"{"error":{"code":-32601,"message":"Method not found"},"id":"srq-1","jsonrpc":"2.0"}"#)
        func ev(_ type: String, _ session: String = "s1", _ payload: String = "{}") -> String {
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"\#(type)","session_id":"\#(session)","payload":\#(payload)}}"#
        }
        check("ready", SI.decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"skin":{}}}}"#), .ready)
        check("result", SI.decode(#"{"jsonrpc":"2.0","id":2,"result":{"session_id":"r","stored_session_id":"s","n":5,"messages":[]}}"#), .result(id: 2, ["session_id": "r", "stored_session_id": "s"]))
        check("result without object", SI.decode(#"{"jsonrpc":"2.0","id":2,"result":true}"#), .result(id: 2, [:]))
        check("failure", SI.decode(#"{"jsonrpc":"2.0","id":4,"error":{"code":4009,"message":"session busy"}}"#), .failure(id: 4, code: 4009, message: "session busy"))
        check("delta", SI.decode(ev("message.delta", "s1", #"{"text":"hi","rendered":"hi"}"#)), .delta(session: "s1", text: "hi"))
        check("delta without text", SI.decode(ev("message.delta", "s1", "{}")), .ignored)
        check("complete", SI.decode(ev("message.complete", "s1", #"{"text":"done","status":"complete","usage":{}}"#)), .complete(session: "s1", text: "done", status: "complete", error: nil))
        check("complete default status", SI.decode(ev("message.complete", "s1", #"{"text":"done"}"#)), .complete(session: "s1", text: "done", status: "complete", error: nil))
        check("complete error", SI.decode(ev("message.complete", "s1", #"{"text":"","status":"error","error":"boom"}"#)), .complete(session: "s1", text: "", status: "error", error: "boom"))
        check("complete error object", SI.decode(ev("message.complete", "s1", #"{"status":"error","error":{"message":"deep"}}"#)), .complete(session: "s1", text: "", status: "error", error: "deep"))
        check("bare error", SI.decode(ev("error", "s1", #"{"message":"bad"}"#)), .error(session: "s1", message: "bad"))
        check("server request", SI.decode(#"{"jsonrpc":"2.0","id":"srq-ab","method":"approval","params":{}}"#), .serverRequest(id: "srq-ab", method: "approval"))
        check("server request with a number id", SI.decode(#"{"jsonrpc":"2.0","id":9,"method":"clarify","params":{}}"#), .serverRequest(id: "9", method: "clarify"))
        check("request.cancel", SI.decode(ev("request.cancel", "s1", #"{"id":"srq-ab","method":"approval","reason":"x"}"#)), .requestCancelled(method: "approval"))
        check("approval hint in tool.complete", SI.decode(ev("tool.complete", "s1", #"{"name":"t","preview":"the approval was withdrawn before"}"#)), .approvalHint)
        check("approval hint in status.update", SI.decode(ev("status.update", "s1", #"{"kind":"x","text":"Approval was withdrawn"}"#)), .approvalHint)
        check("plain tool.complete", SI.decode(ev("tool.complete", "s1", #"{"name":"t"}"#)), .ignored)
        check("unknown event", SI.decode(ev("tool.progress")), .ignored)
        check("thinking is ignored", SI.decode(ev("thinking.delta", "s1", #"{"text":"hmm"}"#)), .ignored)
        check("1 interim", SI.decode(ev("message.interim", "s1", #"{"text":"Looking.","already_streamed":true}"#)),
              .interim(session: "s1", text: "Looking.", alreadyStreamed: true))
        check("1 interim without already_streamed", SI.decode(ev("message.interim", "s1", #"{"text":"Looking."}"#)),
              .interim(session: "s1", text: "Looking.", alreadyStreamed: false))
        check("1 interim without text", SI.decode(ev("message.interim", "s1", "{}")), .ignored)
        check("1 tool.start reads the id, the name and the context",
              SI.decode(ev("tool.start", "s1", #"{"tool_id":"t1","name":"terminal","context":"ls -la","args":{"command":"SECRET"},"args_text":"SECRET","labels":["x"]}"#)),
              .toolStart(session: "s1", id: "t1", name: "terminal", context: "ls -la"))
        check("1 tool.start without a context", SI.decode(ev("tool.start", "s1", #"{"tool_id":"t1","name":"terminal"}"#)),
              .toolStart(session: "s1", id: "t1", name: "terminal", context: ""))
        check("1 tool.start without tool_id is ignored", SI.decode(ev("tool.start", "s1", #"{"name":"terminal"}"#)), .ignored)
        check("1 tool.start without name is ignored", SI.decode(ev("tool.start", "s1", #"{"tool_id":"t1"}"#)), .ignored)
        check("1 tool.complete reads the id and the summary",
              SI.decode(ev("tool.complete", "s1", #"{"tool_id":"t1","name":"terminal","args":{},"result":"SECRET","summary":"3 files in 1.2s","inline_diff":"SECRET"}"#)),
              .toolComplete(session: "s1", id: "t1", summary: "3 files in 1.2s", approvalHint: false))
        check("1 tool.complete without a summary", SI.decode(ev("tool.complete", "s1", #"{"tool_id":"t1","name":"terminal"}"#)),
              .toolComplete(session: "s1", id: "t1", summary: nil, approvalHint: false))
        check("1 tool.complete without tool_id is ignored", SI.decode(ev("tool.complete", "s1", #"{"name":"terminal","summary":"x"}"#)), .ignored)
        check("2 tool.complete whose result mentions the withdrawn approval",
              SI.decode(ev("tool.complete", "s1", #"{"tool_id":"t1","name":"terminal","result":"approval was withdrawn before"}"#)),
              .toolComplete(session: "s1", id: "t1", summary: nil, approvalHint: true))
        check("3 complete with response_previewed", SI.decode(ev("message.complete", "s1", #"{"text":"done","status":"complete","response_previewed":true}"#)),
              .complete(session: "s1", text: "done", status: "complete", error: nil, delivered: true))
        check("3 complete with response_reused", SI.decode(ev("message.complete", "s1", #"{"text":"done","response_reused":true}"#)),
              .complete(session: "s1", text: "done", status: "complete", error: nil, delivered: true))
        check("garbage", SI.decode("not json"), .ignored)
        check("array", SI.decode("[1,2]"), .ignored)
        check("empty", SI.decode(""), .ignored)
        check("boolean id is not an id", SI.decode(#"{"jsonrpc":"2.0","id":true,"result":{}}"#), .ignored)

        print("Turn reducer")
        var t = SI.Turn()
        t.session = "s1"
        check("delta grows", t.ingest(.delta(session: "s1", text: "Hello "), maxChars: 100), true)
        check("other session ignored", t.ingest(.delta(session: "s2", text: "WRONG"), maxChars: 100), false)
        check("no session id counts as ours", t.ingest(.delta(session: "", text: "there"), maxChars: 100), true)
        check("text", t.text, "Hello there")
        check("complete text wins", t.ingest(.complete(session: "s1", text: "Hello there!", status: "complete", error: nil), maxChars: 100), true)
        check("done", t.done, true)
        check("final", (try? t.finalText(tooSlow: false, closedEarly: false, resumedFresh: false)) ?? "ERR", "Hello there!")
        check("nothing after done", t.ingest(.delta(session: "s1", text: "late"), maxChars: 100), false)
        var capped = SI.Turn()
        _ = capped.ingest(.delta(session: "", text: String(repeating: "a", count: 30)), maxChars: 20)
        check("cap truncates", capped.text.count, 20)
        check("cap flag", capped.overLimit, true)
        check("cap note", (try? capped.finalText(tooSlow: false, closedEarly: false, resumedFresh: false)) ?? "ERR", String(repeating: "a", count: 20) + "\n\n" + HermesChat.tooLongNote)
        check("slow note", (try? capped.finalText(tooSlow: true, closedEarly: false, resumedFresh: false)) ?? "ERR", String(repeating: "a", count: 20) + "\n\n" + HermesChat.tooSlowNote)
        var big = SI.Turn()
        _ = big.ingest(.complete(session: "", text: String(repeating: "b", count: 50), status: "complete", error: nil), maxChars: 20)
        check("complete text is capped too", big.completeText.count, 20)
        var notes = SI.Turn()
        _ = notes.ingest(.delta(session: "", text: "Answer"), maxChars: 100)
        _ = notes.ingest(.serverRequest(id: "srq-1", method: "approval"), maxChars: 100)
        check("approval flag", notes.approval, true)
        check("notes order", (try? notes.finalText(tooSlow: false, closedEarly: true, resumedFresh: true)) ?? "ERR",
              "Answer\n\n" + HermesChat.interruptedNote + "\n" + SI.approvalNote + "\n" + SI.newSessionNote)
        print("Turn reducer: rows")
        var rt = SI.Turn()
        rt.session = "s1"
        _ = rt.ingest(.delta(session: "s1", text: "Looking."), maxChars: 100)
        _ = rt.ingest(.toolStart(session: "s2", id: "x", name: "foreign", context: "FOREIGN"), maxChars: 100)
        check("4 a step of another session id is ignored", describe(rt.rows.segments), ["open:Looking."])
        _ = rt.ingest(.toolStart(session: "s1", id: "t1", name: "terminal", context: "ls"), maxChars: 100)
        check("4 a step of ours is a row, the text before it is interim", describe(rt.rows.segments), ["interim:Looking.", "step:terminal|ls|-|running"])
        check("4 ... and the stream loop is told", rt.stepsTouched, true)
        _ = rt.ingest(.toolComplete(session: "s1", id: "t1", summary: "ok", approvalHint: false), maxChars: 100)
        check("4 a completion closes the step", describe(rt.rows.segments), ["interim:Looking.", "step:terminal|ls|ok|done"])
        _ = rt.ingest(.start(session: "s1"), maxChars: 100)
        check("4 message.start clears the rows", describe(rt.rows.segments), [])
        var wait = SI.Turn()
        wait.session = "s1"
        wait.queuedBehindRunningTurn()
        _ = wait.ingest(.toolStart(session: "s1", id: "t1", name: "terminal", context: "OLD"), maxChars: 100)
        _ = wait.ingest(.interim(session: "s1", text: "OLD", alreadyStreamed: false), maxChars: 100)
        check("4 a step frame while awaitingStart is ignored", describe(wait.rows.segments), [])
        var fin = SI.Turn()
        _ = fin.ingest(.delta(session: "", text: "Progress then answer"), maxChars: 100)
        _ = fin.ingest(.complete(session: "", text: "Answer", status: "complete", error: nil), maxChars: 100)
        check("the server's final text is the answer row", describe(fin.rows.segments), ["answer:Answer"])
        var appr = SI.Turn()
        _ = appr.ingest(.delta(session: "", text: "Answer"), maxChars: 100)
        _ = appr.ingest(.serverRequest(id: "srq-1", method: "approval"), maxChars: 100)
        check("an approval request is the existing sentence as a row, once",
              describe(appr.rows.segments), ["interim:Answer", "note:" + SI.approvalNote])
        _ = appr.ingest(.requestCancelled(method: "approval"), maxChars: 100)
        check("... and not twice", appr.rows.segments.count, 2)
        var out = SI.Turn()
        _ = out.ingest(.toolStart(session: "", id: "t1", name: "terminal", context: "ls"), maxChars: 100)
        let o1 = out.outcome(tooSlow: false, closedEarly: true, resumedFresh: false)
        check("outcome: closed early is not ok and carries the interrupted note", o1.ok == false && o1.notes == [HermesChat.interruptedNote], true)
        out.settleRows(ok: o1.ok, notes: o1.notes)
        check("settle: the step stopped, the note is a row", describe(out.rows.segments), ["step:terminal|ls|-|stopped", "note:" + HermesChat.interruptedNote])
        var hintFrom = SI.Turn()
        hintFrom.session = "s1"
        _ = hintFrom.ingest(.delta(session: "s1", text: "Working."), maxChars: 100)
        _ = hintFrom.ingest(.toolComplete(session: "s2", id: "x", summary: nil, approvalHint: true), maxChars: 100)
        // The hint is applied before the session guard, as at HEAD: a subagent runs under another session id, and a
        // missed approval notice is worse than a spurious one (informational only).
        check("25 a withdrawn approval hint inside a frame of another session still leaves the notice (as HEAD)", hintFrom.approval, true)
        check("25 ... as one note row", describe(hintFrom.rows.segments), ["interim:Working.", "note:" + SI.approvalNote])
        _ = hintFrom.ingest(.complete(session: "s1", text: "Done.", status: "complete", error: nil), maxChars: 100)
        var hintLate = SI.Turn()
        hintLate.session = "s1"
        _ = hintLate.ingest(.complete(session: "s1", text: "Done.", status: "complete", error: nil), maxChars: 100)
        _ = hintLate.ingest(.toolComplete(session: "s1", id: "y", summary: nil, approvalHint: true), maxChars: 100)
        check("25 ... and so does one that comes after the turn is done", hintLate.approval, true)
        var hintOurs = SI.Turn()
        hintOurs.session = "s1"
        _ = hintOurs.ingest(.toolComplete(session: "s1", id: "y", summary: nil, approvalHint: true), maxChars: 100)
        check("25 ... while one from our session counts, once", hintOurs.approval && hintOurs.rows.segments.count == 1, true)
        check("26 a tool name made only of format characters is ignored by the decoder",
              SI.decode(ev("tool.start", "s1", #"{"tool_id":"t1","name":"\u200B\u202E"}"#)), .ignored)
        // One function decides the notes: finalText appends exactly what outcome says.
        var grid = 0, gridBad = 0
        for status in ["complete", "interrupted", "error"] {
            for failure in [nil, "boom"] as [String?] {
                for over in [false, true] {
                    for slow in [false, true] {
                        for early in [false, true] {
                            for appr in [false, true] {
                                for fresh in [false, true] {
                                    var t = SI.Turn()
                                    _ = t.ingest(.delta(session: "", text: "Answer"), maxChars: 100)
                                    t.status = status; t.failure = failure; t.overLimit = over; t.approval = appr
                                    let o = t.outcome(tooSlow: slow, closedEarly: early, resumedFresh: fresh)
                                    let got = (try? t.finalText(tooSlow: slow, closedEarly: early, resumedFresh: fresh)) ?? "ERR"
                                    let want = o.notes.isEmpty ? "Answer" : "Answer\n\n" + o.notes.joined(separator: "\n")
                                    grid += 1
                                    if got != want { gridBad += 1 }
                                }
                            }
                        }
                    }
                }
            }
        }
        check("27 finalText and outcome agree on \(grid) states", gridBad, 0)
        var q = SI.Turn()
        q.session = "s1"
        _ = q.ingest(.delta(session: "s1", text: "early old "), maxChars: 100)
        q.queuedBehindRunningTurn()
        check("queued: earlier text forgotten", q.text.isEmpty && !q.done, true)
        check("queued: earlier deltas ignored", q.ingest(.delta(session: "s1", text: "OLD"), maxChars: 100), false)
        _ = q.ingest(.complete(session: "s1", text: "OLD", status: "interrupted", error: nil), maxChars: 100)
        check("queued: the earlier turn's end is not ours", q.done, false)
        _ = q.ingest(.start(session: "s1"), maxChars: 100)
        _ = q.ingest(.delta(session: "s1", text: "mine"), maxChars: 100)
        _ = q.ingest(.complete(session: "s1", text: "mine!", status: "complete", error: nil), maxChars: 100)
        check("queued: the queued turn's end is", q.done && q.completeText == "mine!", true)
        var qe = SI.Turn()
        qe.session = "s1"
        _ = qe.ingest(.complete(session: "s1", text: "OLD", status: "interrupted", error: nil), maxChars: 100)
        qe.queuedBehindRunningTurn()
        check("queued after the earlier end: reset, waiting for the next start", qe.done == false && qe.awaitingStart && qe.completeText.isEmpty, true)
        // The earlier turn's terminal event is NOT the boundary: only the next message.start is.
        var qn = SI.Turn()
        qn.session = "s1"
        _ = qn.ingest(.delta(session: "s1", text: "OLD "), maxChars: 100)
        qn.queuedBehindRunningTurn()
        _ = qn.ingest(.delta(session: "s1", text: "more old"), maxChars: 100)
        check("queued, no earlier terminal: earlier deltas ignored", qn.text.isEmpty, true)
        _ = qn.ingest(.start(session: "s1"), maxChars: 100)
        _ = qn.ingest(.delta(session: "s1", text: "mine"), maxChars: 100)
        _ = qn.ingest(.complete(session: "s1", text: "mine!", status: "complete", error: nil), maxChars: 100)
        check("queued, no earlier terminal: the first complete after the start ends our turn", qn.done && qn.completeText == "mine!", true)
        var qs = SI.Turn()
        qs.session = "s1"
        _ = qs.ingest(.delta(session: "s1", text: "OLD "), maxChars: 100)
        _ = qs.ingest(.complete(session: "s1", text: "OLD", status: "interrupted", error: nil), maxChars: 100)
        _ = qs.ingest(.start(session: "s1"), maxChars: 100)
        _ = qs.ingest(.delta(session: "s1", text: "Drained "), maxChars: 100)
        qs.queuedBehindRunningTurn()   // the answer comes after the start
        check("queued, start before the answer: our text is kept", qs.text == "Drained " && !qs.done && !qs.awaitingStart, true)
        _ = qs.ingest(.complete(session: "s1", text: "Drained answer.", status: "complete", error: nil), maxChars: 100)
        check("queued, start before the answer: the next terminal event is ours", qs.done && qs.completeText == "Drained answer.", true)
        var qf = SI.Turn()
        qf.session = "s1"
        _ = qf.ingest(.start(session: "other"), maxChars: 100)
        check("a start of another session changes nothing", qf.startSeen, false)
        check("message.start decodes", SI.decode(#"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"s1"}}"#), .start(session: "s1"))
        var th = SI.Turn()
        _ = th.ingest(.complete(session: "", text: "<think>hidden</think>Visible", status: "complete", error: nil), maxChars: 100)
        check("thinking blocks filtered", (try? th.finalText(tooSlow: false, closedEarly: false, resumedFresh: false)) ?? "ERR", "Visible")
        var bare = SI.Turn()
        _ = bare.ingest(.error(session: "", message: "kaput"), maxChars: 100)
        do { _ = try bare.finalText(tooSlow: false, closedEarly: false, resumedFresh: false); print("  ✗ empty bare error returned text"); failures += 1 }
        catch { check("empty bare error throws agentFailed", error as? HermesChatError, .agentFailed("kaput")) }
        var intr = SI.Turn()
        _ = intr.ingest(.delta(session: "", text: "some"), maxChars: 100)
        _ = intr.ingest(.complete(session: "", text: "", status: "interrupted", error: nil), maxChars: 100)
        check("interrupted keeps text and says so", (try? intr.finalText(tooSlow: false, closedEarly: false, resumedFresh: false)) ?? "ERR", "some\n\n" + HermesChat.interruptedNote)
        let none = SI.Turn()
        do { _ = try none.finalText(tooSlow: false, closedEarly: true, resumedFresh: false); print("  ✗ empty turn returned text"); failures += 1 }
        catch { check("empty turn", error as? HermesChatError, .agentFailed("The agent returned no text.")) }
    }

    // MARK: End to end (fake dashboard on 127.0.0.1)

    static func endToEnd() async {
        print("sign in (loopback listener, PKCE exchange)")
        await ctl("/_test/reset")
        let box = Box()
        let r = await HermesSignInNet.signIn(baseURL: base, timeout: 10) { url in
            box.port = port(of: url)
            box.lsof = lsof(port: box.port)
            Task {
                // Noise first: a favicon and a bare /callback must not end the flow.
                _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(box.port)/favicon.ico")!)
                _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(box.port)/callback")!)
                _ = try? await URLSession.shared.data(from: url)   // the "browser": follows the 302 to the listener
            }
        }
        var rec: SI.SessionRecord?
        if case .success(let x) = r { rec = x } else { print("  ✗ sign in failed: \(r)"); failures += 1 }
        checkTrue("access token present", (rec?.accessToken.count ?? 0) >= 16)
        checkTrue("refresh token present", !(rec?.refreshToken.isEmpty ?? true))
        checkTrue("expiry in the future", (rec?.expiresAt ?? 0) > Date().timeIntervalSince1970)
        check("bound to the base URL", rec?.baseURL, base)
        check("provider", rec?.provider, "self-hosted")
        var st = await state()
        check("authorize called once", int(st, "authorize_count"), 1)
        check("token called once", int(st, "token_count"), 1)
        checkTrue("listener bound to 127.0.0.1 only", box.lsof.contains("127.0.0.1:\(box.port)") && !box.lsof.contains("*:\(box.port)"))
        checkTrue("listener closed after the callback", !(await connects(port: box.port)))

        let token = rec?.accessToken ?? ""
        check("me label", await HermesSignInNet.me(baseURL: base, token: token), "Test User")
        check("me with a bad token", await HermesSignInNet.me(baseURL: base, token: "nope-nope-nope-nope"), nil)
        if case .success(let p) = await HermesSignInNet.profiles(baseURL: base, token: token) {
            check("profiles", p.map { $0.name }, ["default", "codex"])
            check("profile titles", p.map { $0.title }, ["Default", "Steve"])
            check("default flag", p.map { $0.isDefault }, [true, false])
        } else { print("  ✗ profiles failed"); failures += 1 }
        if case .failure(let e) = await HermesSignInNet.profiles(baseURL: base, token: "nope-nope-nope-nope") {
            check("profiles with a bad token", e, .signInFailed("Hermes refused the session. Sign in again."))
        } else { print("  ✗ profiles accepted a bad token"); failures += 1 }

        print("sign in failures (listener torn down every time, nothing stored)")
        func failure(_ mode: String, timeout: TimeInterval = 10, browse: Bool = true) async -> (HermesChatError?, Int) {
            await ctl("/_test/reset")
            await ctl("/_test/config", ["authorize_mode": mode])
            let b = Box()
            let res = await HermesSignInNet.signIn(baseURL: base, timeout: timeout) { url in
                b.port = port(of: url)
                if browse { Task { _ = try? await URLSession.shared.data(from: url) } }
            }
            if case .failure(let e) = res { return (e, b.port) }
            return (nil, b.port)
        }
        // A callback with another state is ignored (a stray request cannot end the flow): the flow waits, then times out.
        var (e, p) = await failure("bad_state", timeout: 1.5)
        check("wrong state is ignored until the timeout", e, .signInFailed("Sign in timed out. Try again."))
        st = await state()
        check("wrong state: the code is not redeemed", int(st, "token_count"), 0)
        checkTrue("wrong state: listener closed", !(await connects(port: p)))
        (e, p) = await failure("error")
        check("error callback", e, .signInFailed(SI.refusedMessage))
        checkTrue("error callback: listener closed", !(await connects(port: p)))
        (e, p) = await failure("no_code")
        check("callback without a code", e, .signInFailed(SI.refusedMessage))
        (e, p) = await failure("ok", timeout: 1, browse: false)
        check("timeout", e, .signInFailed("Sign in timed out. Try again."))
        checkTrue("timeout: listener closed", !(await connects(port: p)))
        let outerBox = Box()
        let outer = Task { await HermesSignInNet.signIn(baseURL: base, timeout: 30) { url in outerBox.port = port(of: url) } }
        try? await Task.sleep(nanoseconds: 300_000_000)
        outer.cancel()
        if case .failure(let ce) = await outer.value { check("cancellation ends the flow", ce, .signInFailed("Sign in timed out. Try again.")) }
        else { print("  ✗ cancelled sign in succeeded"); failures += 1 }
        let outerStillUp = await connects(port: outerBox.port)
        checkTrue("cancellation: listener closed", outerBox.port != 0 && !outerStillUp)

        print("sign in: stray requests do not end the flow")
        await ctl("/_test/reset")
        let stray = Box()
        let sr = await HermesSignInNet.signIn(baseURL: base, timeout: 10) { url in
            stray.port = port(of: url)
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            Task {
                let p = stray.port
                stray.strayWrongState = await raw(port: p, request: "GET /callback?code=evil&state=wrong HTTP/1.1\r\nHost: 127.0.0.1:\(p)\r\n\r\n")
                stray.strayWrongHost = await raw(port: p, request: "GET /callback?code=evil&state=\(state) HTTP/1.1\r\nHost: evil.example:\(p)\r\n\r\n")
                stray.stillListening = await connects(port: p)
                _ = try? await URLSession.shared.data(from: url)   // the real browser round trip
            }
        }
        if case .success(let rec) = sr { checkTrue("the real callback still signs in", rec.accessToken.count >= 16) }
        else { print("  ✗ a stray request ended the flow: \(sr)"); failures += 1 }
        checkTrue("wrong state is answered (static page)", stray.strayWrongState.contains("200"))
        checkTrue("wrong Host is answered too", stray.strayWrongHost.contains("200"))
        checkTrue("still listening after both", stray.stillListening)
        check("only the real code was redeemed", int(await state(), "token_count"), 1)

        print("sign in over plain http is refused except on loopback")
        for u in ["http://mac-mini", "http://hermes.local", "http://192.168.1.5:9119"] {
            if case .failure(let he) = await HermesSignInNet.signIn(baseURL: u, open: { _ in print("  ✗ browser opened for \(u)"); failures += 1 }) {
                check("signIn refuses \(u)", he, .signInFailed(SI.httpsOnlyMessage))
            } else { print("  ✗ signIn accepted \(u)"); failures += 1 }
        }
        check("me refuses http to a name", await HermesSignInNet.me(baseURL: "http://mac-mini", token: "abcdefghijklmnopqrstuvwx"), nil)
        if case .failure(let pe) = await HermesSignInNet.profiles(baseURL: "http://mac-mini", token: "abcdefghijklmnopqrstuvwx") {
            check("profiles refuses http to a name", pe, .invalidURL)
        } else { print("  ✗ profiles accepted http to a name"); failures += 1 }
        let httpRec = SI.SessionRecord(accessToken: "abcdefghijklmnopqrstuvwx", refreshToken: "rrr", expiresAt: 0, provider: "p", userID: "u", label: "", baseURL: "http://mac-mini")
        if case .unavailable = await HermesSignInNet.refresh(record: httpRec) { print("  ✓ refresh refuses http to a name") }
        else { print("  ✗ refresh went out over http to a name"); failures += 1 }
        if case .failure(let ie) = await HermesSignInNet.signIn(baseURL: "http://agent.example.com", open: { _ in print("  ✗ browser opened"); failures += 1 }) {
            check("http to a public host", ie, .invalidURL)
        } else { print("  ✗ http public sign in succeeded"); failures += 1 }

        // ── sessions ─────────────────────────────────────────────────────────
        print("session store and refresh")
        await ctl("/_test/reset")
        let mem = Mem()
        let sessions = makeSessions(mem)
        guard let signed = await signedIn(mem, sessions: sessions) else { print("  ✗ cannot sign in, stopping"); failures += 1; return }
        let ag = agent()
        var tk = (try? await sessions.validToken(for: ag)) ?? ""
        check("fresh token is used as is", tk, signed.accessToken)
        st = await state()
        check("no refresh needed", int(st, "refresh_count"), 0)

        func setRecord(_ transform: (inout SI.SessionRecord) -> Void) async {
            var r = record(mem)!
            transform(&r)
            await sessions.store(r, name: "steve")
        }
        let oldRT = signed.refreshToken
        await setRecord { $0.expiresAt = Date().timeIntervalSince1970 - 10 }
        tk = (try? await sessions.validToken(for: ag)) ?? ""
        checkTrue("expired token is refreshed", !tk.isEmpty && tk != signed.accessToken)
        let rotated = record(mem)
        check("rotated access token stored before use", rotated?.accessToken, tk)
        checkTrue("refresh token rotated", rotated?.refreshToken != oldRT && !(rotated?.refreshToken.isEmpty ?? true))
        check("label survives rotation", rotated?.label, "Test User")
        st = await state()
        check("one refresh call", int(st, "refresh_count"), 1)

        await ctl("/_test/config", ["refresh_mode": "slow"])
        await setRecord { $0.expiresAt = Date().timeIntervalSince1970 - 10 }
        async let t1 = sessions.validToken(for: ag)
        async let t2 = sessions.validToken(for: ag)
        let (a1, a2) = await ((try? t1) ?? "x1", (try? t2) ?? "x2")
        check("concurrent callers share one token", a1, a2)
        st = await state()
        check("concurrent callers make one refresh", int(st, "refresh_count"), 2)
        await ctl("/_test/config", ["refresh_mode": "ok"])

        // reused (dead) refresh token
        let dead = record(mem)!
        await setRecord { $0.refreshToken = oldRT; $0.expiresAt = Date().timeIntervalSince1970 - 10 }
        do { _ = try await sessions.validToken(for: ag); print("  ✗ dead refresh token accepted"); failures += 1 }
        catch { check("reused refresh token needs a new sign in", error as? HermesChatError, .signInNeeded("steve")) }
        check("record removed after session_expired", record(mem) == nil, true)
        check("storage emptied", mem.value, "")

        // 503 keeps the tokens
        _ = dead
        await ctl("/_test/reset")
        guard let s2 = await signedIn(mem, sessions: sessions) else { print("  ✗ second sign in failed"); failures += 1; return }
        await ctl("/_test/config", ["refresh_mode": "503"])
        await setRecord { $0.expiresAt = Date().timeIntervalSince1970 + 30 }
        tk = (try? await sessions.validToken(for: ag)) ?? ""
        check("503 inside the skew uses the access token", tk, s2.accessToken)
        check("503 keeps the record", record(mem)?.refreshToken, s2.refreshToken)
        await setRecord { $0.expiresAt = Date().timeIntervalSince1970 - 10 }
        do { _ = try await sessions.validToken(for: ag); print("  ✗ expired token used after 503"); failures += 1 }
        catch { check("503 after expiry is busy", error as? HermesChatError, .busy) }
        check("503 keeps the tokens", record(mem)?.refreshToken, s2.refreshToken)
        await ctl("/_test/config", ["refresh_mode": "ok"])

        // no refresh token
        await setRecord { $0.refreshToken = ""; $0.expiresAt = Date().timeIntervalSince1970 - 10 }
        let before = int(await state(), "refresh_count")
        do { _ = try await sessions.validToken(for: ag); print("  ✗ expired token without refresh used"); failures += 1 }
        catch { check("expired without refresh token", error as? HermesChatError, .signInNeeded("steve")) }
        check("no network call for it", int(await state(), "refresh_count"), before)
        // bound to another URL
        await setRecord { $0.baseURL = "http://127.0.0.1:1" }
        do { _ = try await sessions.validToken(for: ag); print("  ✗ foreign record used"); failures += 1 }
        catch { check("record for another URL is not used", error as? HermesChatError, .signInNeeded("steve")) }

        // ── one owner for the Keychain item ──────────────────────────────────
        print("session store: a refresh in flight never undoes another writer")
        await ctl("/_test/reset")
        let memR = Mem()
        let sesR = makeSessions(memR)
        guard await signedIn(memR, sessions: sesR) != nil else { print("  ✗ cannot sign in, stopping"); failures += 1; return }
        let agR = agent()
        func expire(_ name: String = "steve", refresh: String? = nil) async {
            var r = record(memR, name)!
            r.expiresAt = Date().timeIntervalSince1970 - 10
            if let refresh { r.refreshToken = refresh }
            await sesR.store(r, name: name)
        }
        func slowToken(_ a: HermesAgent) -> Task<Result<String, Error>, Never> {
            Task { do { return .success(try await sesR.validToken(for: a)) } catch { return .failure(error) } }
        }
        func refreshCount() async -> Int { int(await state(), "refresh_count") }
        await ctl("/_test/config", ["refresh_mode": "slow"])

        // sign out during a refresh
        await expire()
        var n0 = await refreshCount()
        var flight = slowToken(agR)
        _ = await waitFor { await refreshCount() == n0 + 1 }
        await sesR.remove(name: "steve")
        if case .failure(let fe) = await flight.value { check("sign out during a refresh: the caller is told to sign in", fe as? HermesChatError, .signInNeeded("steve")) }
        else { print("  ✗ sign out during a refresh: a token came back"); failures += 1 }
        check("sign out during a refresh: the record stays removed", record(memR) == nil, true)
        check("sign out during a refresh: storage stays empty", memR.value, "")

        // sign in again during an old refresh (the old one would have rotated)
        guard await signedIn(memR, sessions: sesR) != nil else { failures += 1; return }
        await expire()
        n0 = await refreshCount()
        flight = slowToken(agR)
        _ = await waitFor { await refreshCount() == n0 + 1 }
        guard let again = await signedIn(memR, sessions: sesR) else { failures += 1; return }
        if case .success(let tok) = await flight.value { check("sign in again during a refresh: the new session is used", tok, again.accessToken) }
        else { print("  ✗ sign in again during a refresh: failed"); failures += 1 }
        check("sign in again during a refresh: the new record is kept", [record(memR)?.accessToken, record(memR)?.refreshToken], [again.accessToken, again.refreshToken])

        // sign in again during an old refresh that gets 401 (it would have removed the new record)
        await expire(refresh: "rt-dead-xyz")
        n0 = await refreshCount()
        flight = slowToken(agR)
        _ = await waitFor { await refreshCount() == n0 + 1 }
        guard let again2 = await signedIn(memR, sessions: sesR) else { failures += 1; return }
        if case .success(let tok) = await flight.value { check("401 of an old refresh does not remove the new session", tok, again2.accessToken) }
        else { print("  ✗ 401 of an old refresh removed the new session"); failures += 1 }
        check("the new record survives the 401", record(memR)?.refreshToken, again2.refreshToken)

        // two agents interleaving with a refresh
        guard await signedIn(memR, sessions: sesR, name: "mark") != nil else { failures += 1; return }
        let beforeRT = record(memR)!.refreshToken
        await expire()
        n0 = await refreshCount()
        flight = slowToken(agR)
        _ = await waitFor { await refreshCount() == n0 + 1 }
        var edited = record(memR, "mark")!
        edited.label = "Edited"
        await sesR.store(edited, name: "mark")
        await sesR.remove(name: "mark")
        let mark2 = await signedIn(memR, sessions: sesR, name: "mark")
        if case .success(let tok) = await flight.value {
            check("interleaved: steve is refreshed", [record(memR)?.accessToken, record(memR)?.refreshToken != beforeRT ? "rotated" : "same"], [tok, "rotated"])
        } else { print("  ✗ interleaved refresh failed"); failures += 1 }
        check("interleaved: mark keeps its last write", record(memR, "mark")?.accessToken, mark2?.accessToken)

        // removal after a refused ticket only touches the record that was refused
        if let cur = record(memR, "mark") {
            await sesR.remove(name: "mark", ifAccessToken: "an-older-refused-token")
            check("conditional remove: a newer record stays", record(memR, "mark")?.accessToken, cur.accessToken)
            await sesR.remove(name: "mark", ifAccessToken: cur.accessToken)
            check("conditional remove: the refused record goes", record(memR, "mark") == nil, true)
        } else { print("  ✗ conditional remove: no record to test"); failures += 1 }
        await ctl("/_test/config", ["refresh_mode": "ok"])

        // ── redirect with Authorization ──────────────────────────────────────
        print("redirects never carry the bearer")
        await ctl("/_test/reset")
        await ctl("/_test/config", ["profiles_redirect": true])
        if case .failure = await HermesSignInNet.profiles(baseURL: base, token: "abcdefghijklmnopqrstuvwx") { print("  ✓ profiles refuses the redirect") }
        else { print("  ✗ profiles followed a redirect"); failures += 1 }
        st = await state()
        check("redirect target never reached", int(st, "captured_hits"), 0)
        check("redirect target never saw the bearer", int(st, "captured_with_auth"), 0)

        // ── chat turns ───────────────────────────────────────────────────────
        await ctl("/_test/reset")
        let mem2 = Mem()
        let ses = makeSessions(mem2)
        guard await signedIn(mem2, sessions: ses) != nil else { print("  ✗ third sign in failed"); failures += 1; return }

        print("turn: hello (subprotocol ticket, create, submit, stream)")
        var r1 = await turn(ag, ses, "hello")
        check("answer", r1.text, "Hello from Steve.")
        checkTrue("session id reported", !(r1.stored ?? "").isEmpty)
        check("last streamed text", r1.tokens.last, "Hello from Steve.")
        st = await state()
        let ws = (st["ws"] as? [[String: Any]]) ?? []
        check("one socket", ws.count, 1)
        checkTrue("no Origin header", ws.first?["origin"] is NSNull || ws.first?["origin"] == nil)
        check("no Authorization header on the socket", ws.first?["authorization"] as? Bool, false)
        check("no cookie on the socket", ws.first?["cookie"] as? Bool, false)
        check("ticket in the subprotocol", ws.first?["form"] as? String, "subprotocol")
        checkTrue("stable protocol offered", ((ws.first?["protocols"] as? String) ?? "").hasPrefix("hermes-gateway-v1, hermes-gateway-ticket."))
        check("ticket minted with the current token", (st["ticket_bearers"] as? [String])?.last, record(mem2)?.accessToken)
        let log = rpcLog(st)
        check("create then submit", methods(st), ["session.create", "prompt.submit"])
        let createParams = log.first?["params"] as? [String: Any]
        check("profile sent", createParams?["profile"] as? String, "codex")
        checkTrue("idempotency key sent", ((createParams?["idempotency_key"] as? String) ?? "").count >= 8)
        check("prompt text sent", (log.last?["params"] as? [String: Any])?["text"] as? String, "hello")
        check("capabilities_are_sent_once_per_socket: one call, server_requests true", capabilityCalls(st).map { $0["server_requests"] as? Bool }, [true])
        checkTrue("socket closed after the turn", await waitFor { int(await state(), "closes") == 1 })

        print("turn: resume on the second turn")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        r1 = await turn(ag, ses, "echo-history")
        check("first turn", r1.text, "prompts=1")
        let r2 = await turn(ag, ses, "echo-history", stored: r1.stored)
        check("second turn sees the first (same server session)", r2.text, "prompts=2")
        st = await state()
        check("create, submit, resume, submit", methods(st), ["session.create", "prompt.submit", "session.resume", "prompt.submit"])
        let resumeParams = rpcLog(st)[2]["params"] as? [String: Any]
        check("resume by stored id", resumeParams?["session_id"] as? String, r1.stored)
        check("resume omits the messages", resumeParams?["omit_messages"] as? Bool, true)
        check("same stored id reported", r2.stored, r1.stored)
        check("two sockets, two tickets", (st["ws"] as? [[String: Any]])?.count, 2)

        print("turn: unknown stored session falls back to a new one")
        let r3 = await turn(ag, ses, "hello", stored: "stored-gone")
        check("answer with note", r3.text, "Hello from Steve.\n\n" + SI.newSessionNote)
        checkTrue("new session id reported", !(r3.stored ?? "").isEmpty && r3.stored != "stored-gone")

        print("turn: error paths")
        var x = await turn(ag, ses, "error")
        check("complete with status error and no text", chatError(x), .agentFailed("boom from the agent"))
        x = await turn(ag, ses, "error-partial")
        check("error after some text", x.text, "half an answer\n\n" + HermesChat.interruptedNote)
        x = await turn(ag, ses, "bare-error")
        check("bare error event", chatError(x), .agentFailed("bare boom"))
        x = await turn(ag, ses, "close")
        check("socket closed mid turn keeps the text", x.text, "partial answer\n\n" + HermesChat.interruptedNote)
        x = await turn(ag, ses, "close-empty")
        check("socket closed with no text", chatError(x), .unreachable("127.0.0.1"))
        x = await turn(ag, ses, "busy")
        check("error 4009 is busy", chatError(x), .busy)
        x = await turn(ag, ses, "foreign")
        check("frames for another session are ignored", x.text, "Hello from Steve.")

        print("turn: an accepted message is never reported busy (queued, steered, redirected)")
        x = await turn(ag, ses, "queued")
        check("queued: the earlier turn ends, then the queued turn answers", x.text, "Drained answer.")
        x = await turn(ag, ses, "queued-early")
        check("queued, earlier turn ended before the answer", x.text, "Drained answer.")
        x = await turn(ag, ses, "queued-noterm")
        check("queued, no earlier terminal event on this socket", x.text, "Drained answer.")
        x = await turn(ag, ses, "queued-start-first")
        check("queued, message.start before the answer", x.text, "Drained answer.")
        x = await turn(ag, ses, "steered")
        check("steered keeps streaming on this socket", x.text, "Hello from Steve.")
        x = await turn(ag, ses, "redirected")
        check("redirected keeps streaming on this socket", x.text, "Hello from Steve.")

        print("turn: a terminal event that arrives before the submit answer ends the turn at once")
        var started = Date()
        x = await turn(ag, ses, "early-terminal")
        check("early complete", x.text, "Early answer.")
        checkTrue("no wait for a ping", Date().timeIntervalSince(started) < 5)
        started = Date()
        x = await turn(ag, ses, "early-error")
        check("early bare error", chatError(x), .agentFailed("early boom"))
        checkTrue("no wait for a ping either", Date().timeIntervalSince(started) < 5)

        print("turn: server requests are refused, never answered")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        x = await turn(ag, ses, "approval")
        check("turn continues and notes the approval", x.text, "continued after the approval.\n\n" + SI.approvalNote)
        st = await state()
        check("approval_frame_is_declined_with_4404_not_refused_with_method_not_found", (st["rejections"] as? [Int]) ?? [], [4404])
        x = await turn(ag, ses, "withdrawn")
        check("withdrawn approval hint", x.text, "I could not run that.\n\n" + SI.approvalNote)

        print("turn: steps and interim text")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        let steps = await turnRows(ag, ses, "steps")
        check("5 steps: interim text, done step with its summary, answer",
              describe(steps.rows.last),
              ["interim:Let me check the page.", "step:terminal|curl -s graph.facebook.com/v19.0/me|200 OK in 1.2s|done", "answer:The page is limited."])
        check("5 steps: the returned string is the final text, as before", steps.result.text, "The page is limited.")
        let keptRows = describe(steps.rows.last).joined(separator: "\n") + (steps.result.text ?? "")
        checkTrue("6 no argument, result or reasoning left the decoder",
                  !keptRows.contains("ARGS_MARKER_41") && !keptRows.contains("RESULT_MARKER_52") && !keptRows.contains("REASONING_MARKER_63"))
        let two = await turnRows(ag, ses, "steps2")
        check("end to end, two tools", describe(two.rows.last),
              ["interim:Let me check the page.", "step:terminal|curl -s graph.facebook.com/v19.0/me|200 OK in 1.2s|done",
               "interim:The restriction has an unlock date.", "step:mongo_query|automations-flow, last 48h|-|done",
               "answer:**Yes.** The page is *limited* now."])
        print("  e2e sign in segments: " + describe(two.rows.last).joined(separator: " ⏎ "))
        print("  e2e sign in returned: " + (two.result.text ?? "-").replacingOccurrences(of: "\n", with: "\\n"))
        let only = await turnRows(ag, ses, "interim-only")
        check("7 interim not streamed, no delta before it: an interim row, then the answer",
              describe(only.rows.last), ["interim:I will look at it.", "answer:Done looking."])
        let dup = await turnRows(ag, ses, "interim-final")
        check("an interim text delivered again by the final answer is not shown twice", describe(dup.rows.last), ["answer:Final words."])
        let foreign = await turnRows(ag, ses, "steps-noturn")
        check("tool events of another session id add nothing", describe(foreign.rows.last), ["answer:Own answer."])
        let cut = await turnRows(ag, ses, "steps-cut")
        check("the socket closes in the middle of a tool: the step is stopped, the note is a row",
              describe(cut.rows.last), ["interim:Starting.", "step:terminal|sleep 100|-|stopped", "note:" + HermesChat.interruptedNote])
        check("... and the string is as before", cut.result.text, "Starting.\n\n" + HermesChat.interruptedNote)
        let err = await turnRows(ag, ses, "steps-error")
        check("a turn that ends with an error: the step is stopped", describe(err.rows.last).contains("step:terminal|make|-|stopped"), true)
        check("... and the string is as before: the text with the interrupted note", err.result.text, "Starting.\n\n" + HermesChat.interruptedNote)
        check("... the interrupted note is a row", describe(err.rows.last).last, "note:" + HermesChat.interruptedNote)
        let wd = await turnRows(ag, ses, "withdrawn")
        check("a withdrawn approval is the existing sentence as a row, once", describe(wd.rows.last),
              ["note:" + SI.approvalNote, "answer:I could not run that."])
        let hello = await turnRows(ag, ses, "hi")
        check("a turn with no step is one answer row", describe(hello.rows.last), ["answer:Hello from Steve."])
        let all = [steps, two, only, dup, foreign, cut, err, wd, hello]
        checkTrue("8 no row stays running after any turn",
                  all.allSatisfy { r in !r.rows.last.contains { if case .step(let s) = $0.kind { return s.status == .running }; return false } })

        print("turn: review fixes")
        let pre = await turnRows(ag, ses, "interim-prefix")
        check("20 a sentence streamed in part, then sent whole with already_streamed false, is one row",
              describe(pre.rows.last), ["interim:Let me check the page.", "step:terminal|ls|ok|done", "answer:Done."])
        check("20 ... the returned string is the final text", pre.result.text, "Done.")
        let reuse = await turnRows(ag, ses, "reuse-id")
        check("21 a tool_id used by two calls is two steps", describe(reuse.rows.last),
              ["interim:First.", "step:terminal|ls|one|done", "interim:Again.", "step:terminal|ls|two|done", "answer:Answer."])
        let think = await turnRows(ag, ses, "think-split")
        check("22 a think block that opens before a tool and closes after it", describe(think.rows.last),
              ["interim:Hello.", "step:terminal|ls|ok|done", "interim:Mid text.", "step:terminal|ls|ok|done", "answer:Answer."])
        checkTrue("22 ... no call and no token shows the reasoning",
                  !(think.rows.all.flatMap(describe) + think.result.tokens).joined().contains("plan part"))
        let seq3 = await timedRows(ag, ses, "seq3")
        print("  timing proof, sign in, seq3 (the fake pauses 0.5 s before each completion):")
        for r in seq3.rows { print(String(format: "    +%.2fs  ", r.at) + describe(r.rows).map { $0.replacingOccurrences(of: "step:terminal|", with: "") }.joined(separator: " | ")) }
        checkTrue("27 the second tool of a round is published as running before its completion frame",
                  seq3.rows.contains { r in let d = describe(r.rows); return d.contains("step:terminal|two|-|running") && d.contains("step:terminal|one|ok|done") && !d.contains("step:terminal|three|-|running") && r.at < 0.45 })
        checkTrue("27b ... and so is the third, with the second done, before the third completes",
                  seq3.rows.contains { let d = describe($0.rows); return d.contains("step:terminal|three|-|running") && d.contains("step:terminal|two|ok|done") })
        check("27c ... the rows at the end", describe(seq3.rows.last?.rows ?? []),
              ["interim:Look.", "step:terminal|one|ok|done", "step:terminal|two|ok|done", "step:terminal|three|ok|done", "answer:Answer."])
        let tt = await timedRows(ag, ses, "text-tool")
        print("  timing proof, sign in, text-tool (a sentence and a tool start back to back, 0.6 s before the completion):")
        for r in tt.rows { print(String(format: "    +%.2fs  ", r.at) + describe(r.rows).map { $0.replacingOccurrences(of: "step:terminal|", with: "") }.joined(separator: " | ")) }
        checkTrue("27d a tool start right after the sentence before it is published at once",
                  tt.rows.contains { describe($0.rows).contains("step:terminal|work|-|running") && $0.at < 0.5 })
        let thinkOpen = await turnRows(ag, ses, "think-open")
        check("28 a think tag with no closing tag: the rows show the whole turn, as the stored text holds it", describe(thinkOpen.rows.last),
              ["interim:Hi. <think>plan", "step:terminal|ls|ok|done", "interim:More.", "step:terminal|ls|ok|done", "answer:Answer."])
        let literal = await turnRows(ag, ses, "think-literal")
        check("28b an answer that names the tag in inline code is shown whole", describe(literal.rows.last),
              ["answer:Use the `<think>` tag for reasoning. Then answer."])
        let burst = await turnRows(ag, ses, "burst")
        checkTrue("23 a burst of a hundred tools makes few row updates (\(burst.rows.calls))", burst.rows.calls >= 1 && burst.rows.calls <= 2 * StepPublishBudget.perSecond + 2)
        checkTrue("23 ... few token updates (\(burst.result.tokens.count))", burst.result.tokens.count <= 8)
        check("23 ... the last rows: sixty steps, one hidden row, the answer",
              [describe(burst.rows.last).filter { $0.hasPrefix("step:") }.count, describe(burst.rows.last).filter { $0 == "hidden" }.count,
               describe(burst.rows.last).last == "answer:Burst done." ? 1 : 0], [60, 1, 1])
        check("23 ... and the string", burst.result.text, "Burst done.")
        // Privacy: every onSegments call, every onToken value, the returned string; every field the server sends and
        // the app does not read has a marker.
        let appr = await turnRows(ag, ses, "approval")
        check("24 an approval request: the existing sentence is the only trace", describe(appr.rows.last),
              ["note:" + SI.approvalNote, "answer:continued after the approval."])
        let markers = ["ARGS_MARKER_41", "RESULT_MARKER_52", "REASONING_MARKER_63", "LABELS_MARKER_74", "STATUS_MARKER_85",
                       "COMPLETE_REASONING_MARKER_96", "APPROVAL_COMMAND_MARKER_88", "rm -rf"]
        for (name, run) in [("steps", steps), ("steps2", two), ("approval", appr), ("withdrawn", wd), ("interim-prefix", pre),
                            ("reuse-id", reuse), ("think-split", think), ("burst", burst), ("hello", hello)] {
            let seen = (run.rows.all.flatMap(describe) + run.result.tokens + [run.result.text ?? ""]).joined(separator: "\n")
            checkTrue("24 \(name): no marker in any row, any token or the returned string", !markers.contains { seen.contains($0) })
        }

        print("turn: caps and cancellation")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        var lim = HermesChat.Limits.standard
        lim.textChars = 1000
        x = await turn(ag, ses, "big", limits: lim)
        checkTrue("text cap note", (x.text ?? "").hasSuffix(HermesChat.tooLongNote))
        checkTrue("text capped", (x.text ?? "").count <= 1000 + HermesChat.tooLongNote.count + 2)
        checkTrue("cap interrupts the agent", await waitFor { ((await state())["interrupts"] as? [Any])?.count == 1 })
        lim = HermesChat.Limits.standard
        lim.duration = 0.6
        x = await turn(ag, ses, "slow", limits: lim)
        checkTrue("duration cap note", (x.text ?? "").hasSuffix(HermesChat.tooSlowNote))
        checkTrue("duration cap interrupts too", await waitFor { ((await state())["interrupts"] as? [Any])?.count == 2 })
        let t0 = Date()
        let running = Task { await turn(ag, ses, "slow") }
        try? await Task.sleep(nanoseconds: 700_000_000)
        running.cancel()
        let cr = await running.value
        checkTrue("cancellation throws CancellationError", cr.error is CancellationError)
        checkTrue("cancellation is prompt", Date().timeIntervalSince(t0) < 4)
        checkTrue("cancellation interrupts the agent", await waitFor { ((await state())["interrupts"] as? [Any])?.count == 3 })

        print("turn: a flood of frames ends the turn (ignored frames count)")
        lim = HermesChat.Limits.standard
        lim.maxFrames = 200
        var i0 = await interrupts()
        x = await turn(ag, ses, "flood", limits: lim)
        checkTrue("frame budget: text kept, cap note", (x.text ?? "").hasPrefix("start") && (x.text ?? "").hasSuffix(HermesChat.tooLongNote))
        checkTrue("frame budget interrupts the agent", await waitFor { await interrupts() == i0 + 1 })
        lim = HermesChat.Limits.standard
        lim.maxBytes = 1_000_000
        i0 = await interrupts()
        x = await turn(ag, ses, "flood-big", limits: lim)
        checkTrue("byte budget: text kept, cap note", (x.text ?? "").hasPrefix("start") && (x.text ?? "").hasSuffix(HermesChat.tooLongNote))
        checkTrue("byte budget interrupts the agent", await waitFor { await interrupts() == i0 + 1 })

        print("turn: a binary frame does not stop the reader")
        started = Date()
        x = await turn(ag, ses, "binary")
        check("binary frame mid turn: the turn finishes with its text", x.text, "before after.")
        checkTrue("binary frame: no wait for a timer", Date().timeIntervalSince(started) < 8)
        lim = HermesChat.Limits.standard
        lim.maxFrames = 200
        i0 = await interrupts()
        x = await turn(ag, ses, "binary-flood", limits: lim)
        checkTrue("binary flood counts against the frame budget: text kept, cap note",
                  (x.text ?? "").hasPrefix("start") && (x.text ?? "").hasSuffix(HermesChat.tooLongNote))
        checkTrue("binary flood interrupts the agent", await waitFor { await interrupts() == i0 + 1 })
        lim = HermesChat.Limits.standard
        lim.maxBytes = 50_000
        i0 = await interrupts()
        x = await turn(ag, ses, "binary-flood", limits: lim)
        checkTrue("binary bytes count against the byte budget",
                  (x.text ?? "").hasPrefix("start") && (x.text ?? "").hasSuffix(HermesChat.tooLongNote))
        checkTrue("binary byte budget interrupts the agent", await waitFor { await interrupts() == i0 + 1 })

        print("turn: cancel while the submit answer is pending")
        i0 = await interrupts()
        let pending = Task { await turn(ag, ses, "submit-slow") }
        try? await Task.sleep(nanoseconds: 500_000_000)
        pending.cancel()
        checkTrue("cancellation throws CancellationError", (await pending.value).error is CancellationError)
        checkTrue("best effort interrupt after the submit was sent", await waitFor(4) { await interrupts() == i0 + 1 })

        print("turn: keepalive")
        lim = HermesChat.Limits.standard
        lim.pingInterval = 0.4
        x = await turn(ag, ses, "ping-wait", limits: lim)
        check("answer after a quiet period", x.text, "waited")
        checkTrue("pings sent while waiting", int(await state(), "pings") >= 2)

        print("turn: 22 s of silence at the default timeouts (runs about 23 s, two turns in parallel)")
        var noPingLimits = HermesChat.Limits.standard
        noPingLimits.pingInterval = 100   // only the request timeout stands between the socket and the answer
        let noPing = noPingLimits
        async let quietDefault = turn(ag, ses, "silence")
        async let quietNoPing = turn(ag, ses, "silence", limits: noPing)
        let (qd, qn) = await (quietDefault, quietNoPing)
        check("default limits (ping every 15 s) survive the silence", qd.text, "quiet answer")
        check("no ping at all: the request timeout is not an idle limit", qn.text, "quiet answer")

        print("turn: cancellation before the socket is ready leaves nothing open")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        await ctl("/_test/config", ["ready_delay": 2])
        let notReady = Task { await turn(ag, ses, "hello") }
        try? await Task.sleep(nanoseconds: 600_000_000)
        notReady.cancel()
        checkTrue("cancelled", (await notReady.value).error is CancellationError)
        checkTrue("the socket was closed", await waitFor(6) { int(await state(), "closes") == 1 })

        print("turn: a fallback create without a stored id drops the stale one")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        await ctl("/_test/config", ["omit_stored_id": true])
        let od = await turn(ag, ses, "hello", stored: "stored-gone")
        check("answer with the note", od.text, "Hello from Steve.\n\n" + SI.newSessionNote)
        check("the stale id is reported as gone", od.stored, "")

        print("turn: ticket in the query when the subprotocol is refused")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        await ctl("/_test/config", ["reject_subprotocol": true])
        x = await turn(ag, ses, "hello")
        check("fallback works", x.text, "Hello from Steve.")
        st = await state()
        let forms = ((st["ws"] as? [[String: Any]]) ?? []).map { ($0["form"] as? String ?? "?") + ($0["accepted"] as? Bool == true ? "+" : "-") }
        check("subprotocol refused, then query accepted", forms, ["subprotocol-", "query+"])
        check("a fresh ticket for the retry", int(st, "ticket_count"), 2)
        var strict = HermesChat.Limits.standard
        strict.allowQueryTicketFallback = false
        x = await turn(ag, ses, "hello", limits: strict)
        check("fallback off fails closed", chatError(x), .unreachable("127.0.0.1"))
        st = await state()
        check("no query attempt when the fallback is off", ((st["ws"] as? [[String: Any]]) ?? []).filter { ($0["form"] as? String) == "query" }.count, 1)

        print("turn: token problems")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        let beforeToken = record(mem2)!.accessToken
        await ctl("/_test/config", ["ticket_401": 1])
        x = await turn(ag, ses, "hello")
        check("one refused ticket: refresh and retry", x.text, "Hello from Steve.")
        st = await state()
        check("refreshed once", int(st, "refresh_count"), 1)
        checkTrue("retry used the new token", (st["ticket_bearers"] as? [String])?.last == record(mem2)?.accessToken && record(mem2)?.accessToken != beforeToken)
        await ctl("/_test/config", ["ticket_401": 2])
        x = await turn(ag, ses, "hello")
        check("two refused tickets end the session", chatError(x), .signInNeeded("steve"))
        check("record removed", record(mem2) == nil, true)
        x = await turn(ag, ses, "hello")
        check("then no network at all", chatError(x), .signInNeeded("steve"))

        await ctl("/_test/reset")
        guard let fresh = await signedIn(mem2, sessions: ses) else { failures += 1; return }
        var expired = record(mem2)!
        expired.expiresAt = Date().timeIntervalSince1970 - 10
        await ses.store(expired, name: "steve")
        x = await turn(ag, ses, "hello")
        check("expired token refreshed before the ticket", x.text, "Hello from Steve.")
        st = await state()
        let used = (st["ticket_bearers"] as? [String])?.last
        checkTrue("ticket minted with the rotated token", used == record(mem2)?.accessToken && used != fresh.accessToken)

        print("turn: plain http to a name is refused by the transport")
        let memH = Mem()
        let sesH = makeSessions(memH)
        let hrec = SI.SessionRecord(accessToken: "abcdefghijklmnopqrstuvwx", refreshToken: "", expiresAt: 0, provider: "p", userID: "u", label: "", baseURL: "http://hermes.local")
        await sesH.store(hrec, name: "steve")
        x = await turn(HermesAgent(name: "steve", baseURL: "http://hermes.local", profile: "", modelName: "", connection: .signIn), sesH, "hello")
        check("no ticket, no socket", chatError(x), .invalidURL)

        print("turn: guards")
        x = await turn(HermesAgent(name: "steve", baseURL: base, profile: "codex", modelName: ""), ses, "hello")
        check("an API key agent never uses this transport", chatError(x), .invalidURL)
        x = await turn(HermesAgent(name: "steve", baseURL: base + "/", profile: "", modelName: "", connection: .signIn), ses, "hello")
        check("unnormalised agent URL", chatError(x), .invalidURL)
        await ctl("/_test/reset")
        let none = makeSessions(Mem())
        x = await turn(ag, none, "hello")
        check("no session: no network call", chatError(x), .signInNeeded("steve"))
        check("no ticket was requested", int(await state(), "ticket_count"), 0)
        let dflt = agent(profile: "default")
        await ctl("/_test/reset")
        guard await signedIn(mem2, sessions: ses) != nil else { failures += 1; return }
        x = await turn(dflt, ses, "hello")
        check("default profile works", x.text, "Hello from Steve.")
        let dp = rpcLog(await state()).first?["params"] as? [String: Any]
        check("default profile sends no profile field", dp?["profile"] == nil, true)
    }

    private static func finish() -> Never {
        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed.")
        exit(1)
    }
}
