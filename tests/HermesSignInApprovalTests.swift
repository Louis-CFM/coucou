import Foundation

// Sign in transport, approvals: the wire against tests/fake_hermes_dashboard.py. The "owner" below stands for the
// app: it is handed the requests and answers only when a test line says "the owner clicks" (an explicit call).

extension HermesSignInTests {

    typealias HA = HermesApproval

    /// What the app does with the requests of a turn. Thread safe: the turn calls it from the main actor.
    final class Owner: @unchecked Sendable {
        struct Offered { var request: HermesApprovalRequest; var turn: Int; var answer: HermesApprovalAnswer }
        private let lock = NSLock()
        private var _accept = true
        private var _offered: [Offered] = []
        private var _withdrawn: [(String, HermesApproval.WithdrawReason)] = []
        private var _retained: [(ids: Set<String>, known: Set<String>)] = []
        private var _ended: [(Int, HermesApproval.WithdrawReason)] = []
        var accept: Bool { get { lock.withLock { _accept } } set { lock.withLock { _accept = newValue } } }
        var offered: [Offered] { lock.withLock { _offered } }
        var withdrawn: [(String, HermesApproval.WithdrawReason)] { lock.withLock { _withdrawn } }
        var retained: [(ids: Set<String>, known: Set<String>)] { lock.withLock { _retained } }
        var ended: [(Int, HermesApproval.WithdrawReason)] { lock.withLock { _ended } }

        var hooks: HermesApprovalHooks {
            HermesApprovalHooks(
                offer: { [self] r, t, a in lock.withLock { _offered.append(Offered(request: r, turn: t, answer: a)) }; return accept },
                withdrawn: { [self] id, why in lock.withLock { _withdrawn.append((id, why)) } },
                retain: { [self] ids, known, _ in lock.withLock { _retained.append((ids, known)) } },
                turnEnded: { [self] t, why in lock.withLock { _ended.append((t, why)) } })
        }

        /// The explicit click: the answer of the offered request number `i`.
        func click(_ i: Int = 0, _ choice: HermesApproval.Choice) async -> HermesApproval.AnswerOutcome {
            await offered[i].answer(choice)
        }
    }

    struct ApprovalRun {
        var result: TurnResult
        var rows: [ChatSegment]
        var interrupts: Int
    }

    /// Runs a turn with the owner's hooks. `during` runs while the turn is alive (the clicks, the cancellation).
    static func approvalTurn(_ ag: HermesAgent, _ ses: HermesSessions, _ text: String, owner: Owner,
                             limits: HermesChat.Limits = .standard,
                             during: @escaping @Sendable (Task<String, Error>) async -> Void = { _ in }) async -> ApprovalRun {
        let box = Box()
        let rows = RowLog()
        let task = Task { () -> String in
            try await HermesSignInNet.streamTurn(agent: ag, sessions: ses, storedSession: nil, text: text, limits: limits,
                                                 onSession: { box.sessionIDs.append($0) },
                                                 onToken: { box.tokens.append($0) },
                                                 onSegments: { rows.last = $0 },
                                                 approvals: owner.hooks)
        }
        await during(task)
        let result: TurnResult
        do {
            let t = try await task.value
            result = TurnResult(text: t, error: nil, stored: box.sessionIDs.last, tokens: box.tokens)
        } catch {
            result = TurnResult(text: nil, error: error, stored: box.sessionIDs.last, tokens: box.tokens)
        }
        return ApprovalRun(result: result, rows: rows.last, interrupts: await interrupts())
    }

    static func responds(_ st: [String: Any]) -> [[String: Any]] { (st["responds"] as? [[String: Any]]) ?? [] }
    static func notes(_ run: ApprovalRun) -> [String] { describe(run.rows).filter { $0.hasPrefix("note:") } }

    static func approvalTests() async {
        let mem = Mem()
        let ses = makeSessions(mem)
        let ag = agent()
        let marker = "APPROVAL_COMMAND_MARKER_88"
        let sentence = "note:" + SI.approvalNote

        func fresh(wait: Double = 1.5, _ extra: [String: Any] = [:]) async {
            await ctl("/_test/reset")
            var cfg: [String: Any] = ["approval_wait": wait]
            for (k, v) in extra { cfg[k] = v }
            await ctl("/_test/config", cfg)
            _ = await signedIn(mem, sessions: ses)
        }

        // ── capabilities
        print("approvals: capabilities")
        await fresh()
        var owner = Owner()
        var run = await approvalTurn(ag, ses, "hello", owner: owner)
        var st = await state()
        check("capabilities_are_sent_once_per_socket_before_the_session_rpcs: raw order",
              ((st["rpc"] as? [[String: Any]]) ?? []).compactMap { $0["method"] as? String }, ["client.capabilities", "session.create", "prompt.submit"])
        check("  the call says server_requests true and nothing else", (capabilityCalls(st).first as? [String: Bool]) ?? [:], ["server_requests": true])
        check("  a plain turn is unchanged", run.result.text, "Hello from Steve.")

        await fresh(["no_capabilities": true])
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-once", owner: owner)
        st = await state()
        check("capabilities_refused_by_old_server_keeps_today_behaviour: nothing offered", owner.offered.count, 0)
        check("  the turn ends with the sentence", run.result.text, "blocked: not advertised\n\n" + SI.approvalNote)
        check("  the plain turn works as it did", (await approvalTurn(ag, ses, "hello", owner: owner)).result.text, "Hello from Steve.")
        // The old server sends the frame anyway: not taken, and refused as it always was (it fails fast, the agent does not wait).
        await fresh(["no_capabilities": true])
        run = await approvalTurn(ag, ses, "approval", owner: owner)
        st = await state()
        check("  a frame from a server that does not know capabilities is not offered", owner.offered.count, 0)
        check("  and refused with method not found, as today", (st["rejections"] as? [Int]) ?? [], [-32601])
        check("  the sentence is there", run.result.text, "continued after the approval.\n\n" + SI.approvalNote)

        // 4404 only for a server that advertised approval (Hera minor 5)
        await fresh(["caps_mode": "no_approval"])
        owner = Owner()
        run = await approvalTurn(ag, ses, "approval", owner: owner)
        st = await state()
        check("capabilities_without_approval_keep_minus_32601: nothing offered", owner.offered.count, 0)
        check("  the frame is refused with method not found, not 4404", (st["rejections"] as? [Int]) ?? [], [-32601])
        check("  the sentence is there", run.result.text, "continued after the approval.\n\n" + SI.approvalNote)
        await fresh(["caps_mode": "frame_first"])
        owner = Owner()
        run = await approvalTurn(ag, ses, "hello", owner: owner)
        st = await state()
        check("frame_before_the_capabilities_answer_keeps_minus_32601: nothing offered", owner.offered.count, 0)
        check("  refused with method not found, not 4404", (st["rejections"] as? [Int]) ?? [], [-32601])
        check("  the turn ends with the sentence", run.result.text, "Hello from Steve.\n\n" + SI.approvalNote)
        // (a server that advertised approval gets 4404 for a frame the app does not take: the bad id, other session and owner tests below)

        // ── the other prompts stay refused
        print("approvals: sudo, secret and clarify are refused as before")
        for kind in ["sudo", "secret", "clarify"] {
            await fresh()
            owner = Owner()
            run = await approvalTurn(ag, ses, kind, owner: owner)
            st = await state()
            check("sudo_secret_vault_clarify_frames_are_still_refused (\(kind))", (st["rejections"] as? [Int]) ?? [], [-32601])
            check("  \(kind) is never offered to the owner", owner.offered.count, 0)
            check("  \(kind): no approval.respond", responds(st).count, 0)
        }

        // ── one approval, answered by an explicit click
        print("approvals: one request, one click")
        for (choice, word) in [(HA.Choice.once, "allowed once"), (.session, "allowed for the session"), (.always, "always allowed"), (.deny, "denied")] {
            await fresh(wait: 6)
            owner = Owner()
            var outcome: HA.AnswerOutcome?
            run = await approvalTurn(ag, ses, "approve-once", owner: owner) { _ in
                _ = await waitFor { owner.offered.count == 1 }
                outcome = await owner.click(0, choice)
            }
            st = await state()
            let log = responds(st)
            check("approval_respond_carries_session_request_id_and_choice_only (\(choice.rawValue)): one call", log.count, 1)
            check("  carries session, request id and choice only", Set(log.first?.keys.map { $0 } ?? []), ["session_id", "request_id", "choice"])
            check("  exact request id", log.first?["request_id"] as? String, "rq-1")
            check("  the live session id", (log.first?["session_id"] as? String)?.hasPrefix("run-"), true)
            check("  choice", log.first?["choice"] as? String, choice.rawValue)
            check("approval_respond_never_carries_all", log.first?["all"] == nil, true)
            check("respond_resolved_one_is_applied", outcome, .applied)
            check("  the agent got the choice", run.result.text, choice == .deny ? "blocked: deny" : "ran: " + choice.rawValue)
            check("  the chat keeps one fixed sentence (a late request.cancel resolved adds nothing)", notes(run), ["note:(Approval asked: \(word).)"])
            check("  nothing was refused", int(st, "approval_refused"), 0)
            check("  the request carried the choices of the server", owner.offered.first?.request.choices, [.once, .session, .always, .deny])
            check("  and the agent's name", owner.offered.first?.request.agentName, "steve")
        }
        check("the command reaches the owner and nothing else", owner.offered.first?.request.command.contains(marker), true)
        check("markers_in_command_never_reach_text_rows_or_logs: text", run.result.text?.contains(marker), false)
        check("  rows", describe(run.rows).contains { $0.contains(marker) }, false)
        check("  tokens", run.result.tokens.contains { $0.contains(marker) }, false)

        // ── nothing is sent without a click
        print("approvals: no click, no answer")
        await fresh(wait: 1)
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-once", owner: owner)
        st = await state()
        check("no_answer_for_the_whole_turn_sends_no_choice", responds(st).count, 0)
        check("  the agent saw no answer", run.result.text, "no answer")
        check("  the owner was told the turn ended", owner.ended.contains { $0.0 == owner.offered.first?.turn }, true)
        let late = await owner.click(0, .once)
        check("a click after the turn ended answers nothing", late, .unknown)
        check("  and sends nothing", responds(await state()).count, 0)

        // ── late and failed answers
        print("approvals: late and failed answers")
        await fresh(wait: 6, ["respond_mode": "zero"])
        owner = Owner()
        var o2: HA.AnswerOutcome?
        run = await approvalTurn(ag, ses, "approve-once", owner: owner) { _ in
            _ = await waitFor { owner.offered.count == 1 }
            o2 = await owner.click(0, .once)
        }
        check("respond_resolved_zero_is_too_late", o2, .tooLate)
        check("  the chat says it was not answered in time", notes(run), ["note:(Approval asked: not answered in time.)"])
        check("  one call only, never retried", responds(await state()).count, 1)

        await fresh(wait: 6, ["respond_mode": "error"])
        owner = Owner()
        var o3: HA.AnswerOutcome?
        run = await approvalTurn(ag, ses, "approve-once", owner: owner) { _ in
            _ = await waitFor { owner.offered.count == 1 }
            o3 = await owner.click(0, .once)
        }
        check("respond_error_is_failed", o3, .failed)
        check("  one call only", responds(await state()).count, 1)
        check("  the chat says Hermes did not take it", notes(run), ["note:(Approval asked: Hermes did not take the answer.)"])
        check("failed_answer_does_not_reshow_by_itself: one offer", owner.offered.count, 1)

        // ── withdrawals
        print("approvals: withdrawals")
        await fresh()
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-timeout", owner: owner)
        check("request_cancel_with_matching_id_withdraws", owner.withdrawn.map { $0.0 }, ["rq-1"])
        check("  reason timeout", owner.withdrawn.first?.1, .timeout)
        check("  the chat sentence, once", notes(run), ["note:(Approval asked: Hermes stopped waiting.)"])
        check("  it is not the old sentence", describe(run.rows).contains(sentence), false)
        check("  nothing was answered", responds(await state()).count, 0)

        await fresh()
        owner = Owner()
        _ = await approvalTurn(ag, ses, "approve-resolved-elsewhere", owner: owner)
        check("resolved elsewhere", owner.withdrawn.first?.1, .resolved)

        await fresh()
        owner = Owner()
        _ = await approvalTurn(ag, ses, "approve-cancelled-broadcast", owner: owner)
        check("approval_cancelled_broadcast_withdraws_listed_ids", owner.withdrawn.map { $0.0 }, ["rq-1"])
        check("  reason interrupted", owner.withdrawn.first?.1, .interrupted)

        // ── the stale card: another client answered by a response frame, no cancel was sent
        await fresh(wait: 3)
        owner = Owner()
        var fast = HermesChat.Limits.standard
        fast.pingInterval = 0.4
        run = await approvalTurn(ag, ses, "approve-stale", owner: owner, limits: fast)
        st = await state()
        check("pending_list_without_the_id_withdraws_it: approval.pending was asked", int(st, "pending_calls") >= 1, true)
        check("  the owner was told which ids were known and what the server listed", owner.retained.first.map { $0.known.contains("rq-1") && !$0.ids.contains("rq-1") }, true)
        check("  nothing was answered", responds(st).count, 0)

        // ── two approvals in one turn
        print("approvals: two in one turn")
        await fresh(wait: 6)
        owner = Owner()
        var oa: HA.AnswerOutcome?, ob: HA.AnswerOutcome?
        run = await approvalTurn(ag, ses, "approve-two", owner: owner) { _ in
            _ = await waitFor { owner.offered.count == 2 }
            oa = await owner.click(0, .once)
            ob = await owner.click(1, .deny)
        }
        st = await state()
        check("two_approvals_in_one_turn_need_two_answers: two calls", responds(st).count, 2)
        check("  each to its own request", responds(st).compactMap { $0["request_id"] as? String }.sorted(), ["rq-a", "rq-b"])
        check("  outcomes", [oa, ob], [.applied, .applied])
        check("  the agent got both choices", run.result.text, "a:once b:deny")
        check("  two sentences in the chat", notes(run).count, 2)

        await fresh(wait: 6)
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-two", owner: owner) { _ in
            _ = await waitFor { owner.offered.count == 2 }
            _ = await owner.click(1, .once)
        }
        st = await state()
        check("one click answers one request only", responds(st).compactMap { $0["request_id"] as? String }, ["rq-b"])
        check("  the other got nothing", run.result.text, "a:None b:once")

        // ── the socket goes away
        print("approvals: connection lost and cancellation")
        await fresh()
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-close", owner: owner)
        check("socket_closed_while_pending_sends_no_choice", responds(await state()).count, 0)
        check("  the owner dropped the turn's requests (socket lost)", owner.ended.contains { $0.1 == .socketLost }, true)
        check("  the turn reports the lost connection", chatError(run.result) != nil, true)
        let afterClose = await owner.click(0, .once)
        check("  a click after the loss answers nothing", afterClose, .unknown)

        await fresh(wait: 6)
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-once", owner: owner) { task in
            _ = await waitFor { owner.offered.count == 1 }
            task.cancel()
        }
        st = await state()
        check("cancelled_turn_sends_interrupt_and_no_choice: interrupt sent", run.interrupts >= 1, true)
        check("  no approval.respond", responds(st).count, 0)
        check("  the owner dropped the turn's requests", owner.ended.isEmpty, false)

        // ── what is not showable
        print("approvals: requests the app does not take")
        await fresh(wait: 1)
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-bad-id", owner: owner)
        st = await state()
        check("not_showable_request_keeps_the_existing_sentence_once: not offered", owner.offered.count, 0)
        check("  the sentence appears once", describe(run.rows).filter { $0 == sentence }.count, 1)
        check("not_showable_request_is_declined_with_4404_for_this_client_only", (st["rejections"] as? [Int]) ?? [], [4404])
        check("  not with method not found (that would settle it for every client)", int(st, "approval_refused"), 0)
        check("  the decline is counted as a decline", int(st, "approval_declined"), 1)
        check("  and no answer", responds(st).count, 0)

        await fresh(wait: 1)
        owner = Owner()
        run = await approvalTurn(ag, ses, "approve-unknown-session", owner: owner)
        st = await state()
        check("a request for another session is not offered", owner.offered.count, 0)
        check("  and declined with 4404", (st["rejections"] as? [Int]) ?? [], [4404])
        check("  the sentence appears once", describe(run.rows).filter { $0 == sentence }.count, 1)

        await fresh(wait: 1)
        owner = Owner()
        owner.accept = false
        run = await approvalTurn(ag, ses, "approve-once", owner: owner)
        st = await state()
        check("an owner that does not take it: the sentence", describe(run.rows).filter { $0 == sentence }.count, 1)
        check("  declined with 4404, nothing refused, nothing answered", [(st["rejections"] as? [Int]) ?? [], [int(st, "approval_refused"), responds(st).count]] as [[Int]], [[4404], [0, 0]])

        await fresh(wait: 1)
        owner = Owner()
        _ = await approvalTurn(ag, ses, "approve-smart", owner: owner)
        check("smart denied: only once and deny", owner.offered.first?.request.choices, [.once, .deny])
        check("  a choice the server did not offer is not even built", HA.respondParams(owner.offered.first!.request, .always) == nil, true)

        await fresh(wait: 1)
        owner = Owner()
        _ = await approvalTurn(ag, ses, "approve-bidi", owner: owner)
        let raw = owner.offered.first?.request.command ?? ""
        check("a hostile command reaches the owner raw, and the display marks it", HA.display(raw).plain.unicodeScalars.contains { $0.value == 0x202E }, false)
        check("  the raw text did hold the override", raw.unicodeScalars.contains { $0.value == 0x202E }, true)

        await fresh(wait: 1)
        owner = Owner()
        _ = await approvalTurn(ag, ses, "approve-long", owner: owner)
        check("a command over the ceiling reaches the owner, which cannot allow it", HA.display(owner.offered.first?.request.command ?? "").tier, .tooLong)

        // ── the ninth request: declined, not left to wait
        // (the queue's own cap is covered in the pure tests; here the owner's refusal is what the transport sees)

        // ── an answer that gets no reply: unknown, never retried (the answer timeout is Limits.rpcTimeout, 30 s by default)
        print("approvals: an answer nobody confirms")
        var quick = HermesChat.Limits.standard
        quick.rpcTimeout = 1.0
        for mode in ["none", "slow"] {
            await fresh(wait: 5, ["respond_mode": mode])
            owner = Owner()
            var ou: HA.AnswerOutcome?
            var took = 0.0
            run = await approvalTurn(ag, ses, "approve-once", owner: owner, limits: quick) { _ in
                _ = await waitFor(8) { owner.offered.count == 1 }
                let t0 = Date()
                ou = await owner.click(0, .once)
                took = Date().timeIntervalSince(t0)
            }
            st = await state()
            check("answer_without_a_reply_is_unknown (respond_mode \(mode))", ou, .unknown)
            // The answer timeout is 1 s; the `slow` server replies after 3 s. A timer cannot fire early (0.1 s of slack for the
            // clock), and the reply is 1.9 s away from the timeout on a slow runner.
            check("  it came back at the timeout, not at the server's pace", took >= 0.9 && took < 2.9, true)
            check("  never retried: one approval.respond", responds(st).count, 1)
            check("  the chat says it may not have arrived", notes(run).contains("note:(Approval asked: the answer may not have reached Hermes.)"), true)
        }

        // ── a failed answer comes back as a fresh card once, and a later request.cancel still withdraws it
        print("approvals: re-offer")
        await fresh(wait: 4, ["respond_mode": "error"])
        owner = Owner()
        var rf = HermesChat.Limits.standard
        rf.pingInterval = 0.4
        var ofirst: HA.AnswerOutcome?
        run = await approvalTurn(ag, ses, "approve-timeout-late", owner: owner, limits: rf) { _ in
            _ = await waitFor(8) { owner.offered.count == 1 }
            ofirst = await owner.click(0, .once)
            // The server still lists it: it comes back at the next ping (0.4 s) while it waits 3 s for its own timeout; up to 8 s
            // are allowed for a slow runner, but the card must have been offered again before the server withdraws it.
            _ = await waitFor(8) { owner.offered.count == 2 }
        }
        st = await state()
        check("failed_answer_is_re_offered_once_while_the_server_lists_it: first answer failed", ofirst, .failed)
        check("  offered a second time", owner.offered.count, 2)
        check("  with the same request id", owner.offered.map { $0.request.requestID }, ["rq-1", "rq-1"])
        check("  the first click sent one call, the second card nothing", responds(st).count, 1)
        check("a_re_offered_request_registers_its_frame_id: the server's request.cancel withdraws it as a timeout (not a stale card)",
              owner.withdrawn.last.map { $0.0 == "rq-1" && $0.1 == .timeout }, true)

        // ── a click after the server withdrew the request, in a turn that is still alive
        print("approvals: click after request.cancel")
        await fresh(wait: 4)
        owner = Owner()
        var late2: HA.AnswerOutcome?
        run = await approvalTurn(ag, ses, "approve-cancel-alive", owner: owner) { _ in
            _ = await waitFor(8) { owner.offered.count == 1 }
            _ = await waitFor(8) { owner.withdrawn.count == 1 }
            late2 = await owner.click(0, .once)
        }
        st = await state()
        check("click_after_request_cancel_is_too_late (the turn was alive)", late2, .tooLate)
        check("  and sends nothing", responds(st).count, 0)

        // ── a choice the server did not offer, clicked through the transport
        print("approvals: a choice not offered")
        await fresh(wait: 2)
        owner = Owner()
        var notOffered: HA.AnswerOutcome?
        run = await approvalTurn(ag, ses, "approve-smart", owner: owner) { _ in
            _ = await waitFor { owner.offered.count == 1 }
            notOffered = await owner.click(0, .always)
        }
        st = await state()
        check("choice_not_offered_through_the_transport_is_not_taken", notOffered, .failed)
        check("  nothing was sent", responds(st).count, 0)
    }
}
