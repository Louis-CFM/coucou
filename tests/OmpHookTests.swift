import Foundation

@main
enum OmpHookTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label): got \(got), expected \(expected)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ got: Bool) {
        if got {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            failures += 1
        }
    }

    static func main() {
        // Hook path
        check("hook path", OmpHook.hookPath(home: "/Users/test"),
              "/Users/test/.omp/agent/hooks/pre/coucou.ts")

        // Ownership detection
        checkTrue("nil content is not ours", !OmpHook.owns(content: nil))
        checkTrue("empty content is not ours", !OmpHook.owns(content: ""))
        checkTrue("foreign content is not ours",
                  !OmpHook.owns(content: "import net from 'node:net'; export default () => {};"))
        checkTrue("our source is ours", OmpHook.owns(content: OmpHook.source))

        // The agent tag matches the coucou_agent validation (lowercase, digits,
        // hyphens, ≤ 24 chars) and the pill id the server routes to.
        check("agent name", OmpHook.agentName, "oh-my-pi")
        let name = OmpHook.agentName
        checkTrue("agent name passes Coucou validation",
                  !name.isEmpty && name.count <= 24 &&
                  name.allSatisfy { c in
                      (c.isASCII && c.isLetter && c.isLowercase) || (c.isASCII && c.isNumber) || c == "-"
                  })

        // The hook file is self-contained: every event omp listens to is mapped,
        // the payload carries the fields the server reads, and all three
        // platforms' socket paths are present.
        let src = OmpHook.source
        for needle in [
            "pi.on(\"session_start\"",
            "pi.on(\"before_agent_start\"",
            "pi.on(\"tool_call\"",
            "pi.on(\"tool_result\"",
            "pi.on(\"agent_end\"",
            "pi.on(\"session_shutdown\"",
            "\"SessionStart\"",
            "\"UserPromptSubmit\"",
            "\"PreToolUse\"",
            "\"PostToolUseFailure\"",
            "\"PostToolUse\"",
            "\"Stop\"",
            "\"SessionEnd\"",
            "coucou_agent",
            "\"oh-my-pi\"",
            "session_id",
            "tool_name",
            "tool_input",
            "prompt",
            "getSessionId",
            "getCwd",
            "nb.sock",
            "coucou.sock",
            "\\\\pipe\\\\coucou-",
        ] {
            checkTrue("source contains \(needle)", src.contains(needle))
        }

        // never-block guarantees: timeouts on every attempt, errors swallowed
        checkTrue("connect timeout set", src.contains("CONNECT_TIMEOUT_MS"))
        checkTrue("events are queued, not awaited", src.contains("queue.push"))

        if failures == 0 {
            print("OmpHook: all tests passed")
        } else {
            print("OmpHook: \(failures) test(s) failed")
            exit(1)
        }
    }
}
