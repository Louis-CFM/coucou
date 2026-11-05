import Foundation

@main
enum HermesTickerTests {
    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") } else { print("  ✗ \(label)"); failures += 1 }
    }

    static func step(_ id: Int, _ tool: String, _ label: String, _ status: ChatStep.Status = .running) -> ChatSegment {
        ChatSegment(id: id, kind: .step(ChatStep(callId: "c\(id)", tool: tool, label: label, detail: "RESULT SECRET", status: status)))
    }
    static func text(_ id: Int, _ t: String, _ role: ChatSegment.TextRole) -> ChatSegment {
        ChatSegment(id: id, kind: .text(t, role: role))
    }

    static func main() {
        print("HermesTicker.lines")
        checkTrue("1 no rows, no lines", HermesTicker.lines(from: []).isEmpty)
        checkTrue("2 a step is its tool and its preview",
                  HermesTicker.lines(from: [step(0, "terminal", "ls -la")]) == ["terminal · ls -la"])
        checkTrue("3 a step with no preview is its tool",
                  HermesTicker.lines(from: [step(0, "web_search", "")]) == ["web_search"])
        checkTrue("3b a preview equal to the tool is not repeated",
                  HermesTicker.lines(from: [step(0, "todo", "todo")]) == ["todo"])
        checkTrue("4 a finished step keeps its line and shows no result",
                  HermesTicker.lines(from: [step(0, "terminal", "ls", .done)]) == ["terminal · ls"])
        checkTrue("5 text still being written is left out",
                  HermesTicker.lines(from: [text(0, "Let me chec", .open)]).isEmpty)
        checkTrue("6 a sealed progress sentence is a line",
                  HermesTicker.lines(from: [text(0, "Looking at the logs.", .interim), step(1, "terminal", "tail")])
                    == ["Looking at the logs.", "terminal · tail"])
        checkTrue("7 markdown and several paragraphs become one clean line",
                  HermesTicker.lines(from: [text(0, "**Done** with `x`.\n\nSecond paragraph", .answer)]) == ["Done with x."])
        checkTrue("8 notes and the hidden steps row are not activity",
                  HermesTicker.lines(from: [ChatSegment(id: 0, kind: .note("Approval needed")),
                                            ChatSegment(id: 1, kind: .hiddenSteps)]).isEmpty)
        checkTrue("9 a long sentence is cut", (HermesTicker.lines(from: [text(0, String(repeating: "a", count: 900), .interim)]).first?.count ?? 999) <= 200)
        let many = (0..<250).map { step($0, "t", "n\($0)") }
        let capped = HermesTicker.lines(from: many)
        checkTrue("10 the lines are capped, newest kept", capped.count == HermesTicker.maxLines && capped.last == "t · n249")

        print("the answer line (M1): the rows carry it, nothing is derived from the returned text")
        let whole = "Let me check the logs. All good: 3 warnings, no error."
        let turnRows = [text(0, "Let me check the logs.", .interim), step(1, "terminal", "tail -n 50 app.log", .done),
                        text(2, "All good: 3 warnings, no error.", .answer)]
        var card = HermesCard()
        let t1 = card.start()
        card.rows(t1, HermesTicker.lines(from: turnRows))
        card.end(t1, finished: true)
        checkTrue("15 text before a tool, final equal to the whole text: the last line is the answer, nothing added",
                  card.lines == ["Let me check the logs.", "terminal · tail -n 50 app.log", "All good: 3 warnings, no error."]
                  && !whole.isEmpty)
        var capped1 = HermesCard()
        let tc = capped1.start()
        capped1.rows(tc, HermesTicker.lines(from: turnRows + [ChatSegment(id: 3, kind: .note("Stopped at the length limit"))]))
        capped1.end(tc, finished: true)
        checkTrue("16 a cap or interrupted note is not a line, the answer stays last", capped1.lines.last == "All good: 3 warnings, no error." && capped1.lines.count == 3)
        var noComplete = HermesCard()
        let tn = noComplete.start()
        noComplete.rows(tn, HermesTicker.lines(from: [text(0, "Only the deltas, sealed at the end.", .answer)]))
        noComplete.end(tn, finished: true)
        checkTrue("17 no complete text from the server: the sealed deltas row is the answer", noComplete.lines == ["Only the deltas, sealed at the end."])

        print("index rule (M2)")
        checkTrue("18 no rows: the index reads as nothing shown yet", HermesTicker.stepIndex(forCount: 0) == -1)
        checkTrue("19 rows: the index is the last", HermesTicker.stepIndex(forCount: 1) == 0 && HermesTicker.stepIndex(forCount: 7) == 6)
        // The view as a pure machine: onAppear reads the index of an empty list, then the first row arrives.
        var shown = HermesTicker.stepIndex(forCount: 0)
        var shownLast: String? = nil
        let first = HermesTicker.tickerPlan(count: 1, shownIndex: shown, shownLast: shownLast, last: "terminal · ls", transitioning: false)
        checkTrue("20 the first row of the first turn is drawn", first == .show(0))
        if case .show(let i) = first { shown = i; shownLast = "terminal · ls" }
        let second = HermesTicker.tickerPlan(count: 2, shownIndex: shown, shownLast: shownLast, last: "done.", transitioning: false)
        checkTrue("21 the second row animates", second == .animate(1))
        checkTrue("22 nothing changed, nothing to do", HermesTicker.tickerPlan(count: 2, shownIndex: 1, shownLast: "done.", last: "done.", transitioning: false) == .nothing)

        print("ticker plan (m1, m3)")
        checkTrue("23 the list emptied while rows are shown: back to the placeholder",
                  HermesTicker.tickerPlan(count: 0, shownIndex: 4, shownLast: "x", last: nil, transitioning: false) == .placeholder)
        checkTrue("24 already on the placeholder: nothing",
                  HermesTicker.tickerPlan(count: 0, shownIndex: -1, shownLast: nil, last: nil, transitioning: false) == .nothing)
        checkTrue("25 during a transition nothing is decided (the end of the transition asks again)",
                  HermesTicker.tickerPlan(count: 0, shownIndex: 4, shownLast: "x", last: nil, transitioning: true) == .nothing
                  && HermesTicker.tickerPlan(count: 9, shownIndex: 4, shownLast: "x", last: "y", transitioning: true) == .nothing)
        checkTrue("26 past the cap the count stays, the last line changes: the card advances",
                  HermesTicker.tickerPlan(count: 60, shownIndex: 59, shownLast: "terminal · cmd 68", last: "terminal · cmd 69", transitioning: false) == .animate(59))
        checkTrue("27 a list shorter than what is shown starts over",
                  HermesTicker.tickerPlan(count: 2, shownIndex: 5, shownLast: "x", last: "y", transitioning: false) == .show(1))
        checkTrue("28 the signature changes with the last line at a constant count",
                  HermesTicker.Signature(count: 60, last: "a") != HermesTicker.Signature(count: 60, last: "b")
                  && HermesTicker.Signature(count: 2, last: "a") == HermesTicker.Signature(count: 2, last: "a"))

        print("turn life cycle of the card")
        var c = HermesCard()
        checkTrue("29 a new card is empty", c.lines.isEmpty)
        let a = c.start()
        checkTrue("30 start: empty", c.lines.isEmpty)
        c.rows(a, ["one"]); c.rows(a, ["one", "two"])
        checkTrue("31 rows replace the lines", c.lines == ["one", "two"])
        c.end(a, finished: true)
        checkTrue("32 end with success keeps the rows", c.lines == ["one", "two"])
        let b = c.start()
        checkTrue("33 the next turn starts from scratch", c.lines.isEmpty)
        c.rows(b, ["x"])
        c.end(b, finished: false)
        checkTrue("34 a failed or cancelled turn leaves no row", c.lines.isEmpty)
        let d = c.start()
        c.rows(d, ["y"])
        c.clear()
        checkTrue("35 clearing the conversation empties the card at once", c.lines.isEmpty)
        c.rows(d, ["late"])
        c.end(d, finished: true)
        checkTrue("36 the cleared turn writes nothing late, not even when it ends with success", c.lines.isEmpty)
        let e = c.start()
        c.rows(e, ["after the clear"])
        checkTrue("37 a turn started after the clear writes", c.lines == ["after the clear"])

        var two = HermesCard()
        let older = two.start()
        two.rows(older, ["old 1", "old 2"])
        let newer = two.start()
        two.rows(newer, ["new 1"])
        two.rows(older, ["old 1", "old 2", "old 3"])
        checkTrue("38 two turns: the newest owns the card, the older one does not write", two.lines == ["new 1"])
        two.end(older, finished: false)
        checkTrue("39 the older turn failing leaves the newest rows alone (cancelled turn unwinding after a new send)", two.lines == ["new 1"])
        two.rows(newer, ["new 1", "new 2"])
        two.end(newer, finished: true)
        checkTrue("40 the newest ends with success: its answer stays", two.lines == ["new 1", "new 2"])

        var fall = HermesCard()
        let o2 = fall.start()
        let n2 = fall.start()
        fall.rows(n2, ["n"])
        fall.end(n2, finished: false)
        checkTrue("41 the newest fails while an older one runs: no stale row", fall.lines.isEmpty)
        fall.rows(o2, ["o"])
        checkTrue("42 the older turn is then the newest running one and writes", fall.lines == ["o"])

        var unwinding = HermesCard()
        let cancelled = unwinding.start()
        unwinding.rows(cancelled, ["row of the cancelled turn"])
        let resent = unwinding.start()
        checkTrue("43 a message sent while the cancelled turn still unwinds starts the card from scratch", unwinding.lines.isEmpty)
        unwinding.end(cancelled, finished: false)
        unwinding.rows(resent, ["fresh"])
        checkTrue("44 the unwinding turn ending later changes nothing", unwinding.lines == ["fresh"])

        print("N1: only the turn that wrote the lines may empty them")
        var n1 = HermesCard()
        let n1Old = n1.start()
        n1.rows(n1Old, ["old 1"])
        let n1New = n1.start()
        n1.rows(n1New, ["NEW ANSWER"])
        n1.end(n1New, finished: true)
        n1.end(n1Old, finished: false)
        checkTrue("45 the older turn failing after the newest finished leaves the answer", n1.lines == ["NEW ANSWER"])
        var n1b = HermesCard()
        let n1bOld = n1b.start()
        let n1bNew = n1b.start()
        n1b.rows(n1bNew, ["NEW ANSWER"])
        n1b.end(n1bNew, finished: true)
        n1b.end(n1bOld, finished: false)
        checkTrue("46 the same when the older turn was cancelled without ever writing", n1b.lines == ["NEW ANSWER"])
        var n1c = HermesCard()
        let n1cTurn = n1c.start()
        n1c.rows(n1cTurn, ["mine"])
        n1c.end(n1cTurn, finished: false)
        checkTrue("47 a turn that wrote the lines still empties them when it fails", n1c.lines.isEmpty)

        print("n3: the numbering survives the removal of the agent")
        var gone = HermesCard()
        let g0 = gone.start()
        gone.rows(g0, ["row"])
        gone.discard()
        checkTrue("48 a removed agent shows nothing", gone.lines.isEmpty)
        let g1 = gone.start()
        checkTrue("49 the next turn does not restart at the number of the old one", g1 != g0)
        gone.rows(g1, ["fresh"])
        gone.end(g0, finished: false)
        checkTrue("50 the old turn unwinding later does not touch the new turn", gone.lines == ["fresh"])
        gone.rows(g0, ["late"])
        checkTrue("51 the old turn writes nothing after the removal", gone.lines == ["fresh"])

        print("media directives")
        checkTrue("media-1 the directives leave the ticker: the sentence, then one label", {
            let t = "Primeiro áudio. 6s.\n\n[[audio_as_voice]]\nMEDIA:/Users/a/.hermes/x/her-new-photos.ogg"
            let lines = HermesTicker.lines(from: [text(0, t, .answer)])
            return lines == ["Primeiro áudio. 6s.", "Voice message"]
        }())
        checkTrue("media-2 a text that is only a file shows only its label, never a path", {
            let lines = HermesTicker.lines(from: [text(0, "MEDIA:/Users/a/report.pdf", .answer)])
            return lines == ["File: report.pdf"]
        }())
        checkTrue("media-3 several files make one line", {
            HermesTicker.lines(from: [text(0, "MEDIA:/a.png\nMEDIA:/b.png", .answer)]) == ["2 files"]
        }())

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All HermesTicker tests passed.")
    }
}
