import Foundation

// MARK: - Harness

@main
enum ChatTurnTests {
    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("ChatSpeakers.showsHeader")
        let alfred = ChatSpeaker(name: "Alfred", colorHex: "#F97316")
        let steve = ChatSpeaker(name: "Steve", colorHex: "#22C55E")
        let anthropic = ChatSpeaker(name: "Anthropic", colorHex: "#E07950")
        let google = ChatSpeaker(name: "Google", colorHex: "#4285F4")

        checkTrue("1 first message of the list", ChatSpeakers.showsHeader(previous: nil, speaker: alfred))
        checkTrue("2 after a user message",
                  ChatSpeakers.showsHeader(previous: (isUser: true, speaker: nil), speaker: alfred))
        checkTrue("3 after a message of the same speaker: no header",
                  !ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred), speaker: alfred))
        checkTrue("4 after another speaker (provider switched)",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: anthropic), speaker: google))
        checkTrue("4b after another agent",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred), speaker: steve))
        checkTrue("5 a rename between two messages",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred),
                                           speaker: ChatSpeaker(name: "Alfredo", colorHex: alfred.colorHex)))
        checkTrue("5b a colour change between two messages",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: alfred),
                                           speaker: ChatSpeaker(name: alfred.name, colorHex: "#3B82F6")))
        checkTrue("an assistant message with no known previous speaker shows a header",
                  ChatSpeakers.showsHeader(previous: (isUser: false, speaker: nil), speaker: alfred))

        print("ChatStreaming.shows")
        checkTrue("6 the last message of a running turn streams", ChatStreaming.shows(streamingLast: true, isLast: true, isNotice: false))
        checkTrue("6b an earlier message does not", !ChatStreaming.shows(streamingLast: true, isLast: false, isNotice: false))
        checkTrue("6c nothing streams when the turn is over", !ChatStreaming.shows(streamingLast: false, isLast: true, isNotice: false))
        checkTrue("6d an error sentence appended while a sibling turn runs never streams",
                  !ChatStreaming.shows(streamingLast: true, isLast: true, isNotice: true))

        print("ChatSegment")
        let seg = ChatSegment(id: 0, kind: .text("hi", role: .answer))
        checkTrue("a segment is equatable", seg == ChatSegment(id: 0, kind: .text("hi", role: .answer)))
        checkTrue("a segment differs by role", seg != ChatSegment(id: 0, kind: .text("hi", role: .interim)))
        let step = ChatStep(callId: "1", tool: "terminal", label: "ls", detail: nil, status: .running)
        checkTrue("a step is equatable", step == ChatStep(callId: "1", tool: "terminal", label: "ls", detail: nil, status: .running))

        print("ChatSegment: the timeline kinds")
        let editRow = ChatSegment(id: 1, kind: .edit(ChatEdit(callId: "e", tool: "Edita", symbol: "pencil", name: "A.swift", path: "/A.swift",
                                                              added: 12, removed: 3, isNewFile: false, tooLarge: false, preview: [], diffId: nil)))
        let momentRow = ChatSegment(id: 2, kind: .moment(ChatMoment(kind: .permission, callId: "k", text: "t", more: 0, outcome: .waiting)))
        checkTrue("56 isStepRow: an edit is a step row, a moment is not",
                  editRow.isStepRow && !momentRow.isStepRow && !ChatSegment(id: 3, kind: .note("n")).isStepRow
                  && ChatSegment(id: 4, kind: .hiddenSteps).isStepRow)
        if case .edit(let e) = editRow.kind {
            checkTrue("56b an edit as a step: tool, name, counts, done", e.asStep.tool == "Edita" && e.asStep.label == "A.swift"
                      && e.asStep.detail == "+12 −3" && e.asStep.status == .done)
        }
        checkTrue("56c a moment ranks forward and knows when it waits",
                  ChatMoment.rank(of: .waiting) < ChatMoment.rank(of: .inTerminal) && ChatMoment.rank(of: .inTerminal) < ChatMoment.rank(of: .handled)
                  && ChatMoment.rank(of: .handled) < ChatMoment.rank(of: .denied) && ChatMoment.rank(of: .allowed) == ChatMoment.rank(of: .answered("x")))
        if case .moment(let m) = momentRow.kind {
            checkTrue("56d staysVisible", m.staysVisible && m.waitsForUser)
        }

        builderCases()
        builderCasesReview()
        builderCasesRound3()

        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed."); exit(1)
    }

    // MARK: - ChatTurnBuilder

    static func check(_ label: String, _ got: [String], _ want: [String]) {
        if got == want { print("  ✓ \(label)") } else { print("  ✗ \(label)\n      got  \(got)\n      want \(want)"); failures += 1 }
    }

    static func check(_ label: String, _ got: Int, _ want: Int) {
        if got == want { print("  ✓ \(label)") } else { print("  ✗ \(label): got \(got), want \(want)"); failures += 1 }
    }

    /// One short string per segment: "role:text", "step:id|tool|label|detail|status", "note:text", "hidden".
    static func desc(_ b: ChatTurnBuilder) -> [String] {
        b.segments.map { s in
            switch s.kind {
            case .text(let t, let role): return "\(role):\(t)"
            case .step(let st): return "step:\(st.callId)|\(st.tool)|\(st.label)|\(st.detail ?? "-")|\(st.status)"
            case .note(let n): return "note:\(n)"
            case .hiddenSteps: return "hidden"
            case .edit(let e): return "edit:\(e.callId)"
            case .moment(let m): return "moment:\(m.callId)"
            }
        }
    }

    static func run(_ events: [ChatTurnEvent]) -> ChatTurnBuilder {
        var b = ChatTurnBuilder()
        for e in events { b.apply(e) }
        return b
    }

    static func builderCases() {
        print("ChatTurnBuilder")
        check("6 deltas only, then ended: one answer with the joined text",
              desc(run([.text("Hello "), .text("from "), .text("mark."), .ended(ok: true)])), ["answer:Hello from mark."])
        check("6b the answer is not an open text while it streams",
              desc(run([.text("Hel")])), ["open:Hel"])
        check("7 text then tool start: the text is interim, a running step follows",
              desc(run([.text("Checking."), .toolStarted(id: "a", tool: "terminal", label: "ls")])),
              ["interim:Checking.", "step:a|terminal|ls|-|running"])
        check("8 text, start, finish, text, end",
              desc(run([.text("Checking."), .toolStarted(id: "a", tool: "terminal", label: "ls"),
                        .toolFinished(id: "a", detail: nil), .text("\n\nDone."), .ended(ok: true)])),
              ["interim:Checking.", "step:a|terminal|ls|-|done", "answer:Done."])
        check("9 two rounds",
              desc(run([.text("One."), .toolStarted(id: "a", tool: "t1", label: "x"), .toolFinished(id: "a", detail: nil),
                        .text("\n\nTwo."), .toolStarted(id: "b", tool: "t2", label: "y"), .toolFinished(id: "b", detail: nil),
                        .text("\n\nFinal."), .ended(ok: true)])),
              ["interim:One.", "step:a|t1|x|-|done", "interim:Two.", "step:b|t2|y|-|done", "answer:Final."])
        check("10 blank lines at the start of a new segment are dropped, the end ones too",
              desc(run([.toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "a", detail: nil),
                        .text("\n"), .text("\n  \nAnswer\n\n"), .ended(ok: true)])),
              ["step:a|t|x|-|done", "answer:Answer"])
        check("10b whitespace alone never makes a segment",
              desc(run([.text("\n\n"), .text("  ")])), [])
        check("11 parallel tools: two running, each finish closes its own id",
              desc(run([.toolStarted(id: "a", tool: "t1", label: "x"), .toolStarted(id: "b", tool: "t2", label: "y"),
                        .toolFinished(id: "b", detail: nil)])),
              ["step:a|t1|x|-|running", "step:b|t2|y|-|done"])
        check("12 a finish with an unknown id changes nothing",
              desc(run([.toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "zz", detail: "d")])),
              ["step:a|t|x|-|running"])
        check("13 the same start twice is one step",
              desc(run([.toolStarted(id: "a", tool: "t", label: "x"), .toolStarted(id: "a", tool: "t", label: "x")])),
              ["step:a|t|x|-|running"])
        check("13b the summary of a finish is kept",
              desc(run([.toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "a", detail: "3 files in 1.2s")])),
              ["step:a|t|x|3 files in 1.2s|done"])
        check("14 interim(alreadyStreamed) with an open text: it becomes interim, text unchanged",
              desc(run([.text("Looking."), .interim("Looking.", alreadyStreamed: true)])), ["interim:Looking."])
        check("15 interim(alreadyStreamed) after a tool start sealed the text: no change",
              desc(run([.text("Looking."), .toolStarted(id: "a", tool: "t", label: "x"), .interim("Looking.", alreadyStreamed: true)])),
              ["interim:Looking.", "step:a|t|x|-|running"])
        check("15b interim(alreadyStreamed) arriving first is an interim, then a start changes nothing",
              desc(run([.text("Looking."), .interim("Looking.", alreadyStreamed: true),
                        .toolStarted(id: "a", tool: "t", label: "x")])),
              ["interim:Looking.", "step:a|t|x|-|running"])
        check("16 interim(not streamed): a new interim; the same text again: no duplicate",
              desc(run([.interim("Plan.", alreadyStreamed: false), .interim("Plan.", alreadyStreamed: false)])),
              ["interim:Plan."])
        check("16b interim(not streamed) after an open text keeps the order",
              desc(run([.text("A."), .interim("B.", alreadyStreamed: false)])), ["interim:A.", "interim:B."])
        check("17 finalText with an open text: that segment becomes the answer with the server's text",
              desc(run([.text("Progress and answer"), .finalText("Answer", alreadyDelivered: false)])), ["answer:Answer"])
        check("18 finalText(alreadyDelivered) equal to the last interim text and no open text: it becomes the answer",
              desc(run([.interim("Same.", alreadyStreamed: false), .finalText("Same.", alreadyDelivered: true)])), ["answer:Same."])
        check("19 finalText with no open text, not delivered: appended as the answer",
              desc(run([.text("Progress."), .toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "a", detail: nil),
                        .finalText("Answer.", alreadyDelivered: false)])),
              ["interim:Progress.", "step:a|t|x|-|done", "answer:Answer."])
        check("20 finalText(\"\") changes nothing",
              desc(run([.text("Hi"), .finalText("", alreadyDelivered: false)])), ["open:Hi"])
        let running: [ChatTurnEvent] = [.text("Go."), .toolStarted(id: "a", tool: "t", label: "x"), .toolStarted(id: "b", tool: "t", label: "y"),
                                        .toolFinished(id: "b", detail: nil)]
        check("21 ended(ok: false) stops a running step",
              desc(run(running + [.ended(ok: false)])), ["interim:Go.", "step:a|t|x|-|stopped", "step:b|t|y|-|done"])
        check("21b ended(ok: true) finishes a running step",
              desc(run(running + [.ended(ok: true)])), ["interim:Go.", "step:a|t|x|-|done", "step:b|t|y|-|done"])
        check("21c ended twice changes nothing more",
              desc(run(running + [.ended(ok: false), .ended(ok: true)])), ["interim:Go.", "step:a|t|x|-|stopped", "step:b|t|y|-|done"])
        let dirty = "line one\nline two\u{07}\ttab\u{202E}\u{200B}" + String(repeating: "x", count: 500)
        let longTool = String(repeating: "T", count: 100)
        let b22 = run([.toolStarted(id: "a", tool: longTool, label: dirty)])
        if case .step(let st)? = b22.segments.first?.kind {
            check("22 label: 120 characters", st.label.count, 120)
            checkTrue("22 label: one line, no control or format character left",
                      !st.label.contains { $0.isNewline } && !st.label.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x202E || $0.value == 0x200B })
            checkTrue("22 label: newline and tab became spaces", st.label.hasPrefix("line one line two tab"))
            check("22 tool: 40 characters", st.tool.count, 40)
        } else { print("  ✗ 22 no step"); failures += 1 }
        let b22d = run([.toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "a", detail: String(repeating: "d", count: 300))])
        if case .step(let st)? = b22d.segments.first?.kind { check("22 detail: 80 characters", st.detail?.count ?? -1, 80) }
        else { print("  ✗ 22 no step"); failures += 1 }
        var many = ChatTurnBuilder()
        for i in 1...60 { many.apply(.toolStarted(id: "s\(i)", tool: "t", label: "l\(i)")) }
        check("23 sixty steps: no hidden row yet", many.segments.filter { $0.kind == .hiddenSteps }.count, 0)
        many.apply(.toolStarted(id: "s61", tool: "t", label: "l61"))
        func stepCount(_ b: ChatTurnBuilder) -> Int { b.segments.filter { if case .step = $0.kind { return true }; return false }.count }
        check("23 step 61 removes the oldest: 60 steps", stepCount(many), 60)
        check("23 ... and leaves exactly one hidden row", many.segments.filter { $0.kind == .hiddenSteps }.count, 1)
        checkTrue("23 ... at the place of the removed step", many.segments.first?.kind == .hiddenSteps)
        if case .step(let st)? = many.segments.dropFirst().first?.kind { checkTrue("23 ... the oldest step is gone", st.callId == "s2") }
        many.apply(.toolStarted(id: "s62", tool: "t", label: "l62"))
        check("23 step 62 adds no second hidden row", many.segments.filter { $0.kind == .hiddenSteps }.count, 1)
        check("23 ... still 60 steps", stepCount(many), 60)
        var big = ChatTurnBuilder()
        let chunk = String(repeating: "y", count: 100_000)
        big.apply(.text(chunk)); big.apply(.text(chunk)); big.apply(.text(chunk))
        big.apply(.toolStarted(id: "a", tool: "t", label: "x")); big.apply(.text("more"))
        check("24 the text of a turn is cut at maxTextChars", big.plainText.count, ChatTurnBuilder.maxTextChars)
        let ids = big.segments.map(\.id)
        checkTrue("24 segment ids are unique and increasing", ids == ids.sorted() && Set(ids).count == ids.count)
        check("25 two equal notes in a row are one",
              desc(run([.note("n"), .note("n")])), ["note:n"])
        check("25b different notes stay",
              desc(run([.note("n"), .note("m"), .note("n")])), ["note:n", "note:m", "note:n"])
        var again = run([.text("a"), .toolStarted(id: "a", tool: "t", label: "x")])
        let lastId = again.segments.last?.id ?? -1
        again.reset()
        check("26 reset empties the builder", desc(again), [])
        again.apply(.text("b"))
        checkTrue("26 the next id does not collide with a segment of the old turn", (again.segments.first?.id ?? -1) > lastId)
        let b27 = run([.text("First."), .toolStarted(id: "a", tool: "terminal", label: "SECRETLABEL"), .toolFinished(id: "a", detail: "SECRETDETAIL"),
                       .note("a note"), .text("Second."), .ended(ok: true)])
        check("27 plainText joins the text segments with a blank line", [b27.plainText], ["First.\n\nSecond."])
        checkTrue("27 ... and holds no label, detail or note",
                  !b27.plainText.contains("SECRETLABEL") && !b27.plainText.contains("SECRETDETAIL") && !b27.plainText.contains("a note"))
        check("28 a note arriving while a text is open seals that text (it was written before the request)",
              desc(run([.text("I need to run it."), .note("needs approval"), .text("Done.")])),
              ["interim:I need to run it.", "note:needs approval", "open:Done."])
    }

    // MARK: - Review fixes (Hera / Aegis, commit 2)

    static func textRows(_ b: ChatTurnBuilder) -> Int {
        b.segments.filter { if case .text = $0.kind { return true }; return false }.count
    }

    static func builderCasesReview() {
        print("ChatTurnBuilder: review fixes")
        // Hera M2: a sentence streamed in part, then sent whole with already_streamed false, is one row.
        check("30 open text then interim(not streamed): the open text becomes the interim row with the server's text",
              desc(run([.text("Let me che"), .interim("Let me check the page.", alreadyStreamed: false),
                        .toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "a", detail: nil),
                        .text("\n\nDone."), .finalText("Done.", alreadyDelivered: false), .ended(ok: true)])),
              ["interim:Let me check the page.", "step:a|t|x|-|done", "answer:Done."])
        check("30b interim equal to the open text, not streamed: it is sealed, a later answer does not replace it",
              desc(run([.text("Checking."), .interim("Checking.", alreadyStreamed: false), .text("Answer"),
                        .finalText("Answer", alreadyDelivered: false)])),
              ["interim:Checking.", "answer:Answer"])
        check("30c the server's version wins over the streamed prefix",
              desc(run([.text("abc"), .interim("abcdef", alreadyStreamed: false)])), ["interim:abcdef"])
        check("30d with no open text the interim is appended",
              desc(run([.interim("Plan.", alreadyStreamed: false)])), ["interim:Plan."])
        // Hera m1: an id used again after its completion is a new step.
        check("31 the same call id after its completion is a second step and the text before it is interim",
              desc(run([.text("First."), .toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "a", detail: nil),
                        .text("\n\nAgain."), .toolStarted(id: "a", tool: "t", label: "x"), .toolFinished(id: "a", detail: "ok"),
                        .text("\n\nAnswer."), .ended(ok: true)])),
              ["interim:First.", "step:a|t|x|-|done", "interim:Again.", "step:a|t|x|ok|done", "answer:Answer."])
        check("31b a second start while the first still runs stays ignored",
              desc(run([.toolStarted(id: "a", tool: "t", label: "x"), .toolStarted(id: "a", tool: "t", label: "y")])),
              ["step:a|t|x|-|running"])
        // Hera m3: delivered match on collapsed whitespace, only against the last text row.
        check("32 delivered final text equal to the last interim up to whitespace becomes the answer",
              desc(run([.interim("Final  words.", alreadyStreamed: false), .finalText("Final words.", alreadyDelivered: true)])),
              ["answer:Final words."])
        check("32b ... but only against the last text row",
              desc(run([.interim("Same.", alreadyStreamed: false), .toolStarted(id: "a", tool: "t", label: "x"),
                        .toolFinished(id: "a", detail: nil), .interim("Other.", alreadyStreamed: false),
                        .finalText("Same.", alreadyDelivered: true)])),
              ["interim:Same.", "step:a|t|x|-|done", "interim:Other.", "answer:Same."])
        // Aegis M1 / Hera m4: the rows of a turn are capped and no text is lost.
        var chatty = ChatTurnBuilder()
        var expected = ""
        for i in 0..<20_000 {
            let piece = "x\(i % 10)"
            expected += piece
            chatty.apply(.text(piece))
            chatty.apply(.toolStarted(id: "t\(i)", tool: "t", label: "l"))
        }
        chatty.apply(.text("The end."))
        chatty.apply(.ended(ok: true))
        expected += "The end."
        checkTrue("33 one character and one tool, 20 000 times: text rows stay under the cap", textRows(chatty) <= ChatTurnBuilder.maxTextRows)
        checkTrue("33 ... and the whole turn stays a few hundred rows (\(chatty.segments.count))",
                  chatty.segments.count <= ChatTurnBuilder.maxTextRows + ChatTurnBuilder.maxSteps + 4)
        check("33 ... no character of the text is lost or moved", [chatty.plainText.filter { !$0.isWhitespace }], [expected.filter { !$0.isWhitespace }])
        if case .text(let t, let role)? = chatty.segments.last(where: { if case .text = $0.kind { return true }; return false })?.kind {
            checkTrue("33 ... the last text row is the answer and holds the end of the answer", role == .answer && t.hasSuffix("The end."))
        } else { print("  ✗ 33 no text row"); failures += 1 }
        // Hera n2: ids stay increasing in list order.
        var stepsOnly = ChatTurnBuilder()
        for i in 0..<100 { stepsOnly.apply(.text("t\(i)")); stepsOnly.apply(.toolStarted(id: "s\(i)", tool: "t", label: "l")) }
        let ids = stepsOnly.segments.map(\.id)
        checkTrue("35 ids are unique and increasing in list order, with the hidden row in place", ids == ids.sorted() && Set(ids).count == ids.count)
        // Hera n3: the tool name is cleaned before the empty test.
        check("36 a tool name made only of format characters makes no row",
              desc(run([.toolStarted(id: "a", tool: "\u{200B}\u{202E}", label: "x"), .toolStarted(id: "b", tool: "  ", label: "x")])), [])
        // Aegis L1: the call id is capped by scalars.
        let hugeId = "a" + String(repeating: "\u{0301}", count: 120_000)
        let b37 = run([.toolStarted(id: hugeId, tool: "t", label: "x")])
        if case .step(let st)? = b37.segments.first?.kind {
            checkTrue("37 an id of 240 001 bytes is kept under 512 bytes", st.callId.utf8.count <= 512)
        } else { print("  ✗ 37 no step"); failures += 1 }
        check("37b ... and a finish with the same id still pairs",
              desc(run([.toolStarted(id: hugeId, tool: "t", label: "x"), .toolFinished(id: hugeId, detail: nil)])).map { String($0.suffix(4)) },
              ["done"])
        // Hera n1: nothing runs after the end.
        check("34 events after the end are ignored",
              desc(run([.text("a"), .toolStarted(id: "a", tool: "t", label: "x"), .ended(ok: true), .text("b"),
                        .toolStarted(id: "b", tool: "t", label: "x"), .note("n"), .interim("i", alreadyStreamed: false),
                        .finalText("f", alreadyDelivered: false), .toolFinished(id: "a", detail: "late")])),
              ["interim:a", "step:a|t|x|-|done"])
        check("34b the end carries the notes, after the open text became the answer and the running step stopped",
              desc(run([.text("a"), .toolStarted(id: "a", tool: "t", label: "x"), .text("b"), .ended(ok: false, notes: ["cut", "cut"])])),
              ["interim:a", "step:a|t|x|-|stopped", "answer:b", "note:cut"])
        check("34c a note already in the rows is not added again",
              desc(run([.note("n"), .toolStarted(id: "a", tool: "t", label: "x"), .ended(ok: true, notes: ["n"])])),
              ["note:n", "step:a|t|x|-|done"])
        var latched = run([.ended(ok: true)])
        latched.reset()
        latched.apply(.text("x"))
        check("34d reset opens the builder again", desc(latched), ["open:x"])
        // Hera M1: one predicate for a message with something to show.
        checkTrue("38 nothing to show: no content and no rows", !ChatVisibility.isShown(content: "", segments: []))
        checkTrue("38b content alone", ChatVisibility.isShown(content: "hi", segments: []))
        checkTrue("38c a turn that starts with a tool has rows and no content",
                  ChatVisibility.isShown(content: "", segments: run([.toolStarted(id: "a", tool: "t", label: "x")]).segments))
    }

    // MARK: - Round 3 (Hera re-review N1, N4, N5)

    static func builderCasesRound3() {
        print("StepPublishBudget")
        var b8 = StepPublishBudget()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        check("40 a burst of 8 in one instant goes out at once, all 8", (0..<8).filter { _ in b8.take(at: t0) }.count, 8)
        var b100 = StepPublishBudget()
        check("40b a burst of 100 in one instant gives at most the budget", (0..<100).filter { _ in b100.take(at: t0) }.count, StepPublishBudget.perSecond)
        checkTrue("40c ... still refused a moment later, inside the window", !b100.take(at: t0.addingTimeInterval(0.5)))
        checkTrue("40d ... and publishes again once the window has slid", b100.take(at: t0.addingTimeInterval(1.01)))
        var spread = StepPublishBudget()
        let spreadOK = (0..<30).filter { spread.take(at: t0.addingTimeInterval(Double($0) * 0.2)) }.count
        check("40e one every 0.2 s is never refused", spreadOK, 30)
        var half = StepPublishBudget()
        for _ in 0..<10 { _ = half.take(at: t0) }
        check("40f the window slides: 10 used at t0, 5 more at once at t0+0.5, then none", (0..<10).filter { _ in half.take(at: t0.addingTimeInterval(0.5)) }.count, 5)

        print("ChatTurnBuilder: round 3")
        // N4: a prefix in either direction is the same sentence.
        check("41 streamed text longer than the server's interim text is one row holding the server's text",
              desc(run([.text("Let me check the page. And"), .interim("Let me check the page.", alreadyStreamed: false)])),
              ["interim:Let me check the page."])
        check("41b ... whitespace collapsed",
              desc(run([.text("Let  me check\nthe page. And"), .interim("Let me check the page.", alreadyStreamed: false)])),
              ["interim:Let me check the page."])
        check("41c two different sentences stay two rows",
              desc(run([.text("A."), .interim("B.", alreadyStreamed: false)])), ["interim:A.", "interim:B."])
        check("41d the server's text longer than the open text still wins",
              desc(run([.text("abc"), .interim("abcdef", alreadyStreamed: false)])), ["interim:abcdef"])
        // N5: skipped only when no step followed the equal row.
        check("42 an equal interim after a step is a row of its own",
              desc(run([.interim("Same.", alreadyStreamed: false), .toolStarted(id: "a", tool: "t", label: "x"),
                        .toolFinished(id: "a", detail: nil), .interim("Same.", alreadyStreamed: false)])),
              ["interim:Same.", "step:a|t|x|-|done", "interim:Same."])
        check("42b ... and with no step between, it is still skipped",
              desc(run([.interim("Same.", alreadyStreamed: false), .interim("Same.", alreadyStreamed: false)])), ["interim:Same."])
        check("42c a note between does not make it a new sentence",
              desc(run([.interim("Same.", alreadyStreamed: false), .note("n"), .interim("Same.", alreadyStreamed: false)])),
              ["interim:Same.", "note:n"])
    }
}
