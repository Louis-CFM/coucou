import Foundation

@main
enum AgentSessionsTests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func checkEq<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

        print("AgentSessions.apply — lifecycle of one session")
        do {
            var r: [AgentSessionRow] = []
            r = AgentSessions.apply(r, event: "SessionStart", sessionId: "a", project: "SamticsOS", line: nil, now: at(0))
            checkEq("started", r.first?.status, .started)
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "a", project: "SamticsOS", line: "fix the HUD", now: at(1))
            checkEq("thinking", r.first?.status, .thinking)
            checkEq("line = prompt", r.first?.line, "fix the HUD")
            r = AgentSessions.apply(r, event: "PreToolUse", sessionId: "a", project: "SamticsOS", line: "Editing agents.py", now: at(2))
            checkEq("working", r.first?.status, .working)
            r = AgentSessions.apply(r, event: "Notification", sessionId: "a", project: "SamticsOS", line: "Run the tests?", now: at(3))
            checkEq("question → waiting", r.first?.status, .waiting)
            r = AgentSessions.apply(r, event: "Stop", sessionId: "a", project: "SamticsOS", line: "Done.", now: at(4))
            checkEq("finished", r.first?.status, .finished)
            checkEq("line = final message", r.first?.line, "Done.")
            r = AgentSessions.apply(r, event: "SessionEnd", sessionId: "a", project: "SamticsOS", line: nil, now: at(5))
            checkTrue("SessionEnd removes it", r.isEmpty)
        }

        print("AgentSessions.apply — several sessions")
        do {
            var r: [AgentSessionRow] = []
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "a", project: "SamticsOS", line: "one", now: at(0))
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "b", project: "Wisor", line: "two", now: at(10))
            checkEq("two rows", r.count, 2)
            checkEq("newest first", r.first?.id, "b")
            r = AgentSessions.apply(r, event: "StopFailure", sessionId: "a", project: "SamticsOS", line: nil, now: at(20))
            checkEq("a moves to the top", r.first?.id, "a")
            checkEq("a errored", r.first?.status, .error)
            checkEq("a keeps its line", r.first?.line, "one")
            checkEq("b untouched", r.last?.status, .thinking)
        }

        print("AgentSessions.apply — edge cases")
        do {
            var r: [AgentSessionRow] = []
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "unknown", project: "x", line: "y", now: at(0))
            checkTrue("no session id → ignored", r.isEmpty)
            r = AgentSessions.apply(r, event: "Notification", sessionId: "c", project: "x", line: "Rate limit reached", now: at(0))
            checkTrue("non-question notification does not create a row", r.isEmpty)
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "c", project: "x", line: "y", now: at(0))
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "d", project: "x", line: "y", now: at(AgentSessions.maxAge + 1))
            checkEq("rows older than maxAge are pruned", r.map(\.id), ["d"])
            var many: [AgentSessionRow] = []
            for i in 0..<20 {
                many = AgentSessions.apply(many, event: "SessionStart", sessionId: "s\(i)", project: "p", line: nil, now: at(Double(i)))
            }
            checkEq("capped at maxRows", many.count, AgentSessions.maxRows)
            checkEq("cap keeps the newest", many.first?.id, "s19")
        }

        print("AgentSessions.apply — titles and injected prompts")
        do {
            var r: [AgentSessionRow] = []
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "e", project: "SamticsOS", title: "cocou samtics", line: "fix the notch", now: at(0))
            checkEq("title stored", r.first?.title, "cocou samtics")
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "e", project: "SamticsOS", title: nil, line: "<agent-message from=x>", now: at(1))
            checkEq("injected prompt keeps the previous line", r.first?.line, "fix the notch")
            checkEq("missing title keeps the previous one", r.first?.title, "cocou samtics")
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "f", project: "SamticsOS", line: "<task-notification>", now: at(2))
            checkEq("new session with injected prompt has an empty line", r.first?.line, "")
        }

        print("AgentSessions.apply — notification types, long lines, visible()")
        do {
            var r: [AgentSessionRow] = []
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "g", project: "p", line: "go", now: at(0))
            r = AgentSessions.apply(r, event: "Notification", sessionId: "g", project: "p", line: "Claude needs your permission", notificationType: "permission_prompt", now: at(1))
            checkEq("permission_prompt → waiting", r.first?.status, .waiting)
            r = AgentSessions.apply(r, event: "UserPromptSubmit", sessionId: "h", project: "p", line: "go", now: at(2))
            r = AgentSessions.apply(r, event: "Notification", sessionId: "h", project: "p", line: "Anything else?", notificationType: "auth_success", now: at(3))
            checkEq("typed non-waiting notification keeps status", r.first?.status, .thinking)
            r = AgentSessions.apply(r, event: "Stop", sessionId: "h", project: "p", line: String(repeating: "x", count: 5000), now: at(4))
            checkEq("lines capped at maxLine", r.first?.line.count, AgentSessions.maxLine)
            checkEq("visible() hides rows older than maxAge", AgentSessions.visible(r, now: at(AgentSessions.maxAge + 10)).count, 0)
            checkEq("visible() keeps fresh rows", AgentSessions.visible(r, now: at(10)).count, 2)
        }

        print("AgentSessions.ago")
        do {
            checkEq("now", AgentSessions.ago(at(0), now: at(30)), "now")
            checkEq("5m", AgentSessions.ago(at(0), now: at(300)), "5m")
            checkEq("2h", AgentSessions.ago(at(0), now: at(7200)), "2h")
            checkEq("3d", AgentSessions.ago(at(0), now: at(3 * 86400)), "3d")
        }

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll AgentSessions tests passed.")
    }
}
