import Foundation

// API key transport, approvals: the stream and the answer endpoint against tests/fake_hermes.py.
// The "owner" stands for the app: it is handed the requests and answers only when a line says it clicks.

extension HermesChatTests {

    typealias HA = HermesApproval

    final class ApprovalOwner: @unchecked Sendable {
        struct Offered { var request: HermesApprovalRequest; var turn: Int; var answer: HermesApprovalAnswer }
        private let lock = NSLock()
        private var _accept = true
        private var _offered: [Offered] = []
        private var _ended: [(Int, HermesApproval.WithdrawReason)] = []
        var accept: Bool { get { lock.withLock { _accept } } set { lock.withLock { _accept = newValue } } }
        var offered: [Offered] { lock.withLock { _offered } }
        var ended: [(Int, HermesApproval.WithdrawReason)] { lock.withLock { _ended } }
        var hooks: HermesApprovalHooks {
            HermesApprovalHooks(
                offer: { [self] r, t, a in lock.withLock { _offered.append(Offered(request: r, turn: t, answer: a)) }; return accept },
                withdrawn: { _, _ in }, retain: { _, _, _ in },
                turnEnded: { [self] t, why in lock.withLock { _ended.append((t, why)) } })
        }
        func click(_ i: Int = 0, _ choice: HermesApproval.Choice) async -> HermesApproval.AnswerOutcome { await offered[i].answer(choice) }
    }

    final class Rows: @unchecked Sendable { var last: [ChatSegment] = []; var tokens: [String] = [] }

    static func approvalTests(base: String) async {
        let agent = HermesAgent(name: "mark", baseURL: base, profile: "mark", modelName: "mark")
        func body(_ text: String) -> Data {
            try! JSONSerialization.data(withJSONObject: ["model": "mark", "messages": [["role": "user", "content": text]], "stream": true])
        }
        func ctlConfig(_ cfg: [String: Any]) async {
            for (path, json) in [("/_test/reset", [String: Any]()), ("/_test/config", cfg)] {
                var req = URLRequest(url: URL(string: base + path)!)
                req.httpMethod = "POST"
                req.httpBody = try? JSONSerialization.data(withJSONObject: json)
                _ = try? await URLSession.shared.data(for: req)
            }
        }
        func state() async -> [String: Any] {
            guard let (d, _) = try? await URLSession.shared.data(from: URL(string: base + "/_test/posts")!),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return j
        }
        func posts(_ st: [String: Any]) -> [[String: Any]] { (st["posts"] as? [[String: Any]]) ?? [] }
        func noteRows(_ segs: [ChatSegment]) -> [String] {
            segs.compactMap { if case .note(let n) = $0.kind { return "note:" + n }; return nil }
        }
        struct Run { var text: String?; var error: HermesChatError?; var rows: [ChatSegment]; var tokens: [String] }
        func run(_ prompt: String, owner: ApprovalOwner, during: @escaping @Sendable () async -> Void = {}) async -> Run {
            let rows = Rows()
            let task = Task { () -> String in
                try await HermesChat.streamChat(agent: agent, key: "test-key-mark", encodedBody: body(prompt),
                                                onToken: { rows.tokens.append($0) }, onSegments: { rows.last = $0 },
                                                approvals: owner.hooks)
            }
            await during()
            do { return Run(text: try await task.value, error: nil, rows: rows.last, tokens: rows.tokens) }
            catch { return Run(text: nil, error: error as? HermesChatError, rows: rows.last, tokens: rows.tokens) }
        }
        func waitFor(_ timeout: Double = 4, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
            return cond()
        }
        let marker = "APPROVAL_COMMAND_MARKER_88"
        let sentence = "note:" + HermesChat.approvalNote
        final class Out: @unchecked Sendable { var v: HermesApproval.AnswerOutcome? }
        let lines = LinesBox()
        HermesChat.Diagnostics.setSink { lines.add($0) }
        defer { HermesChat.Diagnostics.setSink(nil) }

        print("approvals (api key): one request, one click")
        await ctlConfig(["approval_wait": 6])
        var owner = ApprovalOwner()
        var out = Out()
        var r = await run("approval-wait", owner: owner) {
            _ = await waitFor { owner.offered.count == 1 }
            out.v = await owner.click(0, .once)
        }
        var st = await state()
        let offered = owner.offered.first?.request
        check("approval_event_is_parsed_and_offered: id", offered?.requestID, "rq-1")
        check("  choices", offered?.choices, [.once, .session, .always, .deny])
        check("  agent", offered?.agentName, "mark")
        if case .apiKey(let run)? = offered?.origin { checkTrue("  run id is chatcmpl and hex", HA.isRunID(run)) } else { checkTrue("  origin is the API key", false) }
        check("answer_posts_to_runs_approval_with_bearer_and_request_id: one post", posts(st).count, 1)
        let post = posts(st).first
        checkTrue("  path under the profile root, ending in /approval",
                  (post?["path"] as? String).map { $0.hasPrefix("/p/mark/v1/runs/chatcmpl-") && $0.hasSuffix("/approval") } ?? false)
        check("  bearer is the key of the turn", post?["bearer"] as? String, "Bearer test-key-mark")
        let postBody = post?["body"] as? [String: Any]
        check("  body: choice and request id only", postBody.map { Set($0.keys) }, ["choice", "request_id"])
        check("  body values", [postBody?["choice"] as? String, postBody?["request_id"] as? String], ["once", "rq-1"])
        check("answer_200_is_applied", out.v, .applied)
        check("  the agent got the choice", r.text, "I need to run a command.\n\nran: once")
        check("  the chat keeps one fixed sentence", noteRows(r.rows), ["note:(Approval asked: allowed once.)"])
        check("  not the old sentence", noteRows(r.rows).contains(sentence), false)
        check("marker_in_command_never_reaches_text_or_logs: text", r.text?.contains(marker), false)
        check("  rows", noteRows(r.rows).joined().contains(marker), false)
        check("  tokens", r.tokens.contains { $0.contains(marker) }, false)
        check("  log lines", lines.all.contains { $0.contains(marker) || $0.contains("rq-1") || $0.contains("chatcmpl") }, false)
        check("the stream ended: the owner was told", owner.ended.contains { $0.0 == owner.offered.first?.turn }, true)

        for (choice, text) in [(HA.Choice.session, "ran: session"), (.always, "ran: always"), (.deny, "blocked: deny")] {
            await ctlConfig(["approval_wait": 6])
            owner = ApprovalOwner(); out = Out()
            r = await run("approval-wait", owner: owner) {
                _ = await waitFor { owner.offered.count == 1 }
                out.v = await owner.click(0, choice)
            }
            check("choice \(choice.rawValue) reaches the server", (posts(await state()).first?["body"] as? [String: Any])?["choice"] as? String, choice.rawValue)
            check("  and the agent", r.text, "I need to run a command.\n\n" + text)
        }

        print("approvals (api key): nothing without a click")
        await ctlConfig(["approval_wait": 1])
        owner = ApprovalOwner()
        r = await run("approval-wait", owner: owner)
        st = await state()
        check("no_click_sends_no_post", posts(st).count, 0)
        check("  the agent saw no answer", r.text, "I need to run a command.\n\nno answer")
        check("  the owner was told the stream ended", owner.ended.isEmpty, false)

        print("approvals (api key): late and refused answers")
        await ctlConfig(["approval_wait": 6])
        owner = ApprovalOwner(); out = Out()
        let second = Out()
        r = await run("approval-wait", owner: owner) {
            _ = await waitFor { owner.offered.count == 1 }
            out.v = await owner.click(0, .once)
            second.v = await owner.click(0, .once)
        }
        check("answer_409_is_too_late: the second answer", second.v, .tooLate)
        check("  the first one was applied", out.v, .applied)
        check("  two posts, no retry", posts(await state()).count, 2)

        await ctlConfig(["approval_wait": 1])
        owner = ApprovalOwner(); out = Out()
        r = await run("approval-end", owner: owner)
        let lateOutcome = await owner.click(0, .once)
        check("stream_end_withdraws_the_request: the owner was told", owner.ended.isEmpty, false)
        check("  a late answer is refused by the server", lateOutcome, .tooLate)

        for status in [401, 404, 500] {
            await ctlConfig(["approval_wait": 3, "approval_status": status])
            owner = ApprovalOwner(); out = Out()
            r = await run("approval-wait", owner: owner) {
                _ = await waitFor { owner.offered.count == 1 }
                out.v = await owner.click(0, .once)
            }
            check("answer_401_404_500_are_failed (\(status))", out.v, .failed)
            check("  answer_is_never_retried (\(status)): one post", posts(await state()).count, 1)
            check("  the chat says Hermes did not take it", noteRows(r.rows), ["note:(Approval asked: Hermes did not take the answer.)"])
        }

        print("approvals (api key): two requests, and what the app does not take")
        await ctlConfig(["approval_wait": 6])
        owner = ApprovalOwner()
        let oa = Out(), ob = Out()
        r = await run("approval-two", owner: owner) {
            _ = await waitFor { owner.offered.count == 2 }
            oa.v = await owner.click(0, .once)
            ob.v = await owner.click(1, .deny)
        }
        check("two requests need two answers", posts(await state()).compactMap { ($0["body"] as? [String: Any])?["request_id"] as? String }, ["rq-a", "rq-b"])
        check("  each applied", [oa.v, ob.v], [.applied, .applied])
        check("  the agent got both", r.text, "Two commands.\n\na:once b:deny")

        await ctlConfig(["approval_wait": 1])
        owner = ApprovalOwner()
        r = await run("approval-bad-run", owner: owner)
        check("a run id with path characters is not offered", owner.offered.count, 0)
        check("  the existing sentence stays, once", noteRows(r.rows).filter { $0 == sentence }.count, 1)
        check("  no post", posts(await state()).count, 0)

        await ctlConfig(["approval_wait": 1])
        owner = ApprovalOwner(); owner.accept = false
        r = await run("approval-wait", owner: owner)
        check("an owner that does not take it: the sentence, no post", [noteRows(r.rows).filter { $0 == sentence }.count, posts(await state()).count], [1, 0])

        await ctlConfig(["approval_wait": 1])
        owner = ApprovalOwner()
        _ = await run("approval-smart", owner: owner)
        check("smart denied: once and deny only", owner.offered.first?.request.choices, [.once, .deny])

        await ctlConfig(["approval_wait": 1])
        owner = ApprovalOwner()
        _ = await run("approval-bidi", owner: owner)
        check("a hostile command reaches the owner raw, the display marks it",
              [owner.offered.first?.request.command.unicodeScalars.contains { $0.value == 0x202E },
               HA.display(owner.offered.first?.request.command ?? "").plain.unicodeScalars.contains { $0.value == 0x202E }], [true, false])

        await ctlConfig(["approval_wait": 1])
        owner = ApprovalOwner()
        _ = await run("approval-long", owner: owner)
        check("a command over the ceiling reaches the owner, which cannot allow it", HA.display(owner.offered.first?.request.command ?? "").tier, .tooLong)

        // The old behaviour with the default hooks (no app): only the sentence.
        await ctlConfig(["approval_wait": 1])
        let plain = await run("approval-wait", owner: { let o = ApprovalOwner(); o.accept = false; return o }())
        check("default hooks: the sentence and nothing else", noteRows(plain.rows).filter { $0 == sentence }.count, 1)
        await ctlConfig([:])
    }

    final class LinesBox: @unchecked Sendable {
        private let lock = NSLock()
        private var v: [String] = []
        func add(_ s: String) { lock.withLock { v.append(s) } }
        var all: [String] { lock.withLock { v } }
    }
}
