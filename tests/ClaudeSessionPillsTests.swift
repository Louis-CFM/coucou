import Foundation

@main
enum ClaudeSessionPillsTests {

    static var failures = 0

    static func check(_ label: String, _ got: String?, _ expected: String?) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let later = t0.addingTimeInterval(ClaudeSessionPills.staleAfter + 1)
        let main = ClaudeSessionPills.mainId

        // ── one session per pill ───────────────────────────────────────────────
        print("ClaudeSessionPills.pill")
        var pills = ClaudeSessionPills()
        check("first session gets the main pill", pills.pill(for: "aaaaaaaa-1", now: t0), main)
        check("same session keeps it", pills.pill(for: "aaaaaaaa-1", now: t0), main)
        check("parallel session gets its own pill", pills.pill(for: "bbbbbbbb-2", now: t0), "claude_bbbbbbbb")
        check("and keeps it", pills.pill(for: "bbbbbbbb-2", now: t0), "claude_bbbbbbbb")
        check("a third one too", pills.pill(for: "cccccccc-3", now: t0), "claude_cccccccc")

        // ── ending sessions ────────────────────────────────────────────────────
        print("ClaudeSessionPills.end")
        check("ending the main session frees the main pill", pills.end("aaaaaaaa-1"), main)
        check("ending an extra session returns its pill", pills.end("cccccccc-3"), "claude_cccccccc")
        check("unknown session returns nothing", pills.end("zzzz"), nil)
        check("extra session keeps its pill after main frees", pills.pill(for: "bbbbbbbb-2", now: t0), "claude_bbbbbbbb")
        check("next new session takes the free main pill", pills.pill(for: "dddddddd-4", now: t0), main)

        // ── quiet sessions ─────────────────────────────────────────────────────
        print("ClaudeSessionPills — quiet sessions")
        var quiet = ClaudeSessionPills()
        _ = quiet.pill(for: "aaaaaaaa-1", now: t0)
        check("a quiet main session is taken over", quiet.pill(for: "bbbbbbbb-2", now: later), main)
        check("it comes back on its own pill", quiet.pill(for: "aaaaaaaa-1", now: later), "claude_aaaaaaaa")

        var waiting = ClaudeSessionPills()
        _ = waiting.pill(for: "aaaaaaaa-1", now: t0)
        check("a main pill waiting on the user is never taken over",
              waiting.pill(for: "bbbbbbbb-2", now: t0.addingTimeInterval(10 * ClaudeSessionPills.workingStaleAfter)) {
                  $0 == main ? .waitingOnUser : .idle
              }, "claude_bbbbbbbb")

        var working = ClaudeSessionPills()
        _ = working.pill(for: "aaaaaaaa-1", now: t0)
        check("a long Bash run keeps its main pill",
              working.pill(for: "bbbbbbbb-2", now: later) { $0 == main ? .working : .idle }, "claude_bbbbbbbb")
        let muchLater = t0.addingTimeInterval(ClaudeSessionPills.workingStaleAfter + 1)
        check("a session stuck working for hours gives it up",
              working.pill(for: "cccccccc-3", now: muchLater) { $0 == main ? .working : .idle }, main)

        var prune = ClaudeSessionPills()
        _ = prune.pill(for: "aaaaaaaa-1", now: t0)
        _ = prune.pill(for: "bbbbbbbb-2", now: t0)
        _ = prune.pill(for: "cccccccc-3", now: later)
        check("nothing is pruned before the delay", prune.pruneStale(now: t0).first, nil)
        check("a working extra pill is kept", prune.pruneStale(now: later) { _ in .working }.first, nil)
        check("a quiet extra pill is pruned", prune.pruneStale(now: later).sorted().joined(separator: ","), "claude_bbbbbbbb")
        check("an extra pill waiting on the user is kept",
              prune.pruneStale(now: muchLater.addingTimeInterval(ClaudeSessionPills.workingStaleAfter)) {
                  $0 == "claude_cccccccc" ? .waitingOnUser : .idle
              }.first, nil)

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
