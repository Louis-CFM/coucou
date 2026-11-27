import Foundation

// Checks what Botan's screen shows for the island's picture, and that its button only ever answers
// the request still pending (docs/BOTAN_LINK.md). Compiled by scripts/test-botan-link.sh with the pure
// NotchBuddy/Sources/CoucouKit/BotanLinkScreen.swift.

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { failures += 1; print("FAIL line \(line): \(what)") }
}

@main
struct BotanLinkTests {
    static func main() {
        let working = BotanSessionIn(pillId: "integration_claude", agent: "Claude Code", state: "working",
                                     statusText: "Refactoring the wordmark", project: "/Users/louis/Developer/botan")
        let finished = BotanSessionIn(pillId: "agent_codex", agent: "Codex", state: "finished",
                                      finalLine: "Done. 4 files changed.\nAll tests pass.", project: "/Users/louis/Developer/portfo/")
        let failed = BotanSessionIn(pillId: "n8n_brief", agent: "n8n", state: "error", statusText: "HTTP 429 on step 3",
                                    project: "Morning brief", isWorkflow: true)
        let approval = BotanApprovalIn(requestId: "4F2A9C1E-0000-4000-8000-000000000001", agent: "Claude Code",
                                       project: "botan", tool: "Bash", command: "npm run build")
        let question = BotanQuestionIn(requestId: "9B7D3E10-0000-4000-8000-000000000002", agent: "Claude Code", project: "botan",
                                       question: "Which colorway first?", options: ["Ink", "Alloy", "Frost", "Cherry"])

        // What the screen shows
        do {
            let rest = BotanLinkScreen.screen(sessions: [], approval: nil, question: nil)
            check(rest.line == "idle|BOTAN|Mochi is here.|Nothing running on your Mac.", "nothing running: \(rest.line)")
            check(rest.request == nil && rest.token == nil, "nothing to answer")

            let w = BotanLinkScreen.screen(sessions: [working], approval: nil, question: nil)
            check(w.line == "working|CLAUDE CODE · BOTAN|Refactoring the wordmark|botan", "working: \(w.line)")

            let f = BotanLinkScreen.screen(sessions: [finished], approval: nil, question: nil)
            check(f.line == "finished|CODEX · PORTFO|Done. 4 files changed. All tests pass.|portfo", "finished: \(f.line)")

            let e = BotanLinkScreen.screen(sessions: [working, finished, failed], approval: nil, question: nil)
            check(e.line == "error|N8N · MORNING BRIEF|HTTP 429 on step 3|", "an error comes first: \(e.line)")

            let order = BotanLinkScreen.screen(sessions: [finished, working], approval: nil, question: nil)
            check(order.line.hasPrefix("working|"), "work in progress before work done")

            let a = BotanLinkScreen.screen(sessions: [failed], approval: approval, question: question)
            check(a.line == "#4f2a9c1e approval|CLAUDE CODE · BOTAN|Run npm run build?|Bash", "approval first: \(a.line)")
            check(a.token == "4f2a9c1e", "token")

            let q = BotanLinkScreen.screen(sessions: [working], approval: nil, question: question)
            check(q.line == "#9b7d3e10 question|CLAUDE CODE · BOTAN|Which colorway first?|Ink;Alloy;Frost;Cherry", "question: \(q.line)")

            var many = question
            many.count = 2
            check(BotanLinkScreen.screen(sessions: [working], approval: nil, question: many).line.hasPrefix("working|"),
                  "two questions at once stay on the Mac")
            var multi = question
            multi.multiSelect = true
            check(!BotanLinkScreen.fits(multi), "several picks stay on the Mac")
            var five = question
            five.options.append("Sand")
            check(!BotanLinkScreen.fits(five), "five choices stay on the Mac")
            var long = question
            long.options[0] = String(repeating: "x", count: 60)
            check(!BotanLinkScreen.fits(long), "a choice too long for the screen stays on the Mac")
            var semi = question
            semi.options[0] = "a;b"
            check(!BotanLinkScreen.fits(semi), "a choice with the separator stays on the Mac")

            let edit = BotanApprovalIn(requestId: "x", agent: "Claude Code", project: "", tool: "Edit",
                                       command: "/Users/louis/Developer/botan/src/Button.tsx")
            check(BotanLinkScreen.screen(sessions: [], approval: edit, question: nil).line == "#x approval|CLAUDE CODE|Edit Button.tsx?|Edit",
                  "an edit shows the file name")
        }

        // Fields: one line each, no separator, cut to the firmware's size on a character boundary
        do {
            check(BotanLinkScreen.field("a|b\nc", 20) == "a/b c", "separator and newline")
            let cut = BotanLinkScreen.field(String(repeating: "é", count: 80), 95)
            check(cut.utf8.count <= 95 && cut.hasSuffix("…"), "cut: \(cut.utf8.count) bytes")
            check(String(data: cut.data(using: .utf8)!, encoding: .utf8) == cut, "cut on a character boundary")
            let long = BotanSessionIn(pillId: "p", agent: "Claude Code", state: "working",
                                      statusText: String(repeating: "word ", count: 60), project: "x")
            let line = BotanLinkScreen.screen(sessions: [long], approval: nil, question: nil).line
            check(line.utf8.count < 300, "a line fits the firmware's buffer: \(line.utf8.count)")
            check(line.split(separator: "|", omittingEmptySubsequences: false).count == 4, "four fields")
        }

        // The button
        do {
            let a = BotanLinkScreen.screen(sessions: [], approval: approval, question: nil)
            check(BotanLinkScreen.decision(for: "approve|#4f2a9c1e", screen: a) == .allow(requestId: approval.requestId), "approve")
            check(BotanLinkScreen.decision(for: "approve|#4f2a9c1e\n", screen: a) == .allow(requestId: approval.requestId), "trailing newline")
            if case .ignore = BotanLinkScreen.decision(for: "approve|#00000000", screen: a) {} else { check(false, "another token is ignored") }
            if case .ignore = BotanLinkScreen.decision(for: "approve", screen: a) {} else { check(false, "no token, no decision") }
            check(BotanLinkScreen.decision(for: "deny|#4f2a9c1e", screen: a) == .deny(requestId: approval.requestId), "double press denies")
            if case .ignore = BotanLinkScreen.decision(for: "deny|#00000000", screen: a) {} else { check(false, "deny with another token") }
            if case .ignore = BotanLinkScreen.decision(for: "deny", screen: a) {} else { check(false, "no token, no deny") }
            if case .ignore = BotanLinkScreen.decision(for: "press", screen: a) {} else { check(false, "a plain press decides nothing") }
            if case .ignore = BotanLinkScreen.decision(for: "tick", screen: a) {} else { check(false, "the heartbeat decides nothing") }
            check(BotanLinkScreen.isTick("tick\n") && !BotanLinkScreen.isTick("approve|#4f2a9c1e"), "heartbeat")

            // The request changed between the screen and the press: the old token answers nothing.
            let b = BotanLinkScreen.screen(sessions: [], approval: BotanApprovalIn(requestId: "AAAABBBB-1", agent: "Claude Code",
                                                                                  project: "", tool: "Bash", command: "rm -rf build"),
                                           question: nil)
            if case .ignore = BotanLinkScreen.decision(for: "approve|#4f2a9c1e", screen: b) {} else { check(false, "old screen") }

            let rest = BotanLinkScreen.screen(sessions: [working], approval: nil, question: nil)
            if case .ignore = BotanLinkScreen.decision(for: "approve|#4f2a9c1e", screen: rest) {} else { check(false, "nothing waiting") }
            if case .ignore = BotanLinkScreen.decision(for: "approve|#4f2a9c1e", screen: nil) {} else { check(false, "nothing shown") }

            let q = BotanLinkScreen.screen(sessions: [], approval: nil, question: question)
            check(BotanLinkScreen.decision(for: "choose|2|Frost|#9b7d3e10", screen: q) == .answer(requestId: question.requestId, label: "Frost"),
                  "choose")
            if case .ignore = BotanLinkScreen.decision(for: "choose|2|Alloy|#9b7d3e10", screen: q) {} else { check(false, "label must match its place") }
            if case .ignore = BotanLinkScreen.decision(for: "choose|7|Frost|#9b7d3e10", screen: q) {} else { check(false, "no such place") }
            if case .ignore = BotanLinkScreen.decision(for: "approve|#9b7d3e10", screen: q) {} else { check(false, "approve on a question") }
            if case .ignore = BotanLinkScreen.decision(for: "deny|#9b7d3e10", screen: q) {} else { check(false, "deny on a question") }
            if case .ignore = BotanLinkScreen.decision(for: "choose|2|Frost|#4f2a9c1e", screen: q) {} else { check(false, "token of another screen") }
        }

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("Botan link: all checks passed")
    }
}
