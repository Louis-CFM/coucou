import Foundation

@main
enum PillSessionRegistryTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let claude = "integration_claude"

    static func display(_ session: String, _ project: String, _ cwd: String = "")
        -> PillSessionRegistry.Display {
        PillSessionRegistry.Display(session: session, projectName: project, cwd: cwd)
    }

    static func main() {

        // ── one session alone: the pill follows it all the way ──────────────────
        print("\nSingle session")
        do {
            var reg = PillSessionRegistry()
            reg.note(pill: claude, display: display("a", "coucou", "/tmp/coucou"), working: false)
            check("one live session", reg.liveCount(pill: claude) == 1)
            check("not working after SessionStart", reg.workingCount(pill: claude) == 0)

            reg.note(pill: claude, display: display("a", "coucou", "/tmp/coucou"), working: true)
            check("working after a tool call", reg.workingCount(pill: claude) == 1)

            check("Stop reaches the pill", reg.endTurn(pill: claude, session: "a") == .pill)
            check("still live between turns", reg.liveCount(pill: claude) == 1)
            check("SessionEnd reaches the pill",
                  reg.endSession(pill: claude, session: "a") == .pill)
            check("pill is empty", reg.liveCount(pill: claude) == 0)
        }

        // ── two sessions on one pill: this is the defect ────────────────────────
        // Negative cases: an implementation that always answers .pill fails here.
        print("\nTwo sessions behind one pill")
        do {
            var reg = PillSessionRegistry()
            reg.note(pill: claude, display: display("a", "coucou", "/a"), working: true)
            reg.note(pill: claude, display: display("b", "lokil", "/b"), working: true)
            check("both live", reg.liveCount(pill: claude) == 2)
            check("both working", reg.workingCount(pill: claude) == 2)

            check("A's Stop must not touch the pill while B works",
                  reg.endTurn(pill: claude, session: "a") == .sessionOnly)
            check("B still working", reg.workingCount(pill: claude) == 1)
            check("A's SessionEnd must not remove the card",
                  reg.endSession(pill: claude, session: "a") == .sessionOnly)
            check("B alone now", reg.liveCount(pill: claude) == 1)

            check("B's Stop reaches the pill", reg.endTurn(pill: claude, session: "b") == .pill)
            check("B's SessionEnd reaches the pill",
                  reg.endSession(pill: claude, session: "b") == .pill)
        }

        // ── a resting sibling does not hold the pill back ───────────────────────
        print("\nResting sibling")
        do {
            var reg = PillSessionRegistry()
            reg.note(pill: claude, display: display("a", "coucou"), working: true)
            reg.note(pill: claude, display: display("b", "lokil"), working: true)
            _ = reg.endTurn(pill: claude, session: "b")
            check("A's Stop reaches the pill once B rests",
                  reg.endTurn(pill: claude, session: "a") == .pill)
            check("A's SessionEnd still spares B's card",
                  reg.endSession(pill: claude, session: "a") == .sessionOnly)
        }

        // ── name and cwd: owned by one session, handed over when it leaves ──────
        print("\nDisplay ownership")
        do {
            var reg = PillSessionRegistry()
            reg.note(pill: claude, display: display("a", "coucou", "/a"), working: true)
            reg.note(pill: claude, display: display("b", "lokil", "/b"), working: true)
            check("oldest session owns the name", reg.displayOwner(of: claude)?.session == "a")
            check("name is A's", reg.displayOwner(of: claude)?.projectName == "coucou")
            check("A may write the card", reg.ownsDisplay(pill: claude, session: "a"))
            check("B may not rename the card under A",
                  !reg.ownsDisplay(pill: claude, session: "b"))

            // B keeps working; the name must not flip.
            reg.note(pill: claude, display: display("b", "lokil", "/b"), working: true)
            check("name still A's after more B events",
                  reg.displayOwner(of: claude)?.projectName == "coucou")

            _ = reg.endSession(pill: claude, session: "a")
            check("B inherits the display", reg.displayOwner(of: claude)?.session == "b")
            check("name is now B's", reg.displayOwner(of: claude)?.projectName == "lokil")
            check("cwd is now B's", reg.displayOwner(of: claude)?.cwd == "/b")
            check("B may write the card now", reg.ownsDisplay(pill: claude, session: "b"))
        }

        // ── empty cwd must not erase a known one ────────────────────────────────
        print("\nPartial payloads")
        do {
            var reg = PillSessionRegistry()
            reg.note(pill: claude, display: display("a", "coucou", "/a"), working: true)
            reg.note(pill: claude, display: display("a", "coucou", ""), working: false)
            check("cwd kept when the event carries none",
                  reg.displayOwner(of: claude)?.cwd == "/a")
            check("working flag is sticky inside a turn", reg.workingCount(pill: claude) == 1)
        }

        // ── pills are independent ──────────────────────────────────────────────
        print("\nSeparate pills")
        do {
            var reg = PillSessionRegistry()
            reg.note(pill: claude, display: display("a", "coucou"), working: true)
            reg.note(pill: "agent_cursor", display: display("b", "lokil"), working: true)
            check("Cursor's Stop reaches its own pill",
                  reg.endTurn(pill: "agent_cursor", session: "b") == .pill)
            check("Claude untouched", reg.workingCount(pill: claude) == 1)
            check("an unknown pill is empty", reg.liveCount(pill: "agent_codex") == 0)
        }

        // ── sessions we never saw start ─────────────────────────────────────────
        print("\nUntracked sessions")
        do {
            var reg = PillSessionRegistry()
            check("a Stop from nowhere reaches the pill",
                  reg.endTurn(pill: claude, session: "ghost") == .pill)
            check("it owns nothing", reg.liveCount(pill: claude) == 0)
            check("a SessionEnd from nowhere reaches the pill",
                  reg.endSession(pill: claude, session: "ghost") == .pill)

            reg.note(pill: claude, display: display("a", "coucou"), working: true)
            check("a Stop from nowhere spares a working session",
                  reg.endTurn(pill: claude, session: "ghost") == .sessionOnly)
            check("a SessionEnd from nowhere spares a live session",
                  reg.endSession(pill: claude, session: "ghost") == .sessionOnly)
        }

        // ── a Stop that never arrives must not hold the other session back ─────
        print("\nTurn silence")
        do {
            var reg = PillSessionRegistry()
            let start = Date(timeIntervalSince1970: 1_000_000)
            reg.note(pill: claude, display: display("a", "coucou"), working: true, now: start)
            reg.note(pill: claude, display: display("b", "lokil"), working: true, now: start)

            let soon = start.addingTimeInterval(PillSessionRegistry.maxTurnSilence - 60)
            reg.note(pill: claude, display: display("b", "lokil"), working: true, now: soon)
            check("A still working just under the limit",
                  reg.endTurn(pill: claude, session: "b", now: soon) == .sessionOnly)

            let late = start.addingTimeInterval(PillSessionRegistry.maxTurnSilence + 60)
            reg.note(pill: claude, display: display("b", "lokil"), working: true, now: late)
            check("silent A no longer counts as working",
                  reg.workingCount(pill: claude) == 1)
            check("B's Stop reaches the pill again",
                  reg.endTurn(pill: claude, session: "b", now: late) == .pill)
            check("A is still live", reg.liveCount(pill: claude) == 2)
            check("A still owns the display", reg.displayOwner(of: claude)?.session == "a")
        }

        // ── a SessionEnd that never arrives must not pin the card forever ──────
        print("\nSilence sweep")
        do {
            var reg = PillSessionRegistry()
            let start = Date(timeIntervalSince1970: 1_000_000)
            reg.note(pill: claude, display: display("a", "coucou"), working: true, now: start)
            reg.note(pill: claude, display: display("b", "lokil"), working: true, now: start)

            let later = start.addingTimeInterval(PillSessionRegistry.maxSilence + 60)
            reg.note(pill: claude, display: display("b", "lokil"), working: true, now: later)
            check("silent A swept", reg.liveCount(pill: claude) == 1)
            check("B owns the display", reg.displayOwner(of: claude)?.session == "b")
            check("B's SessionEnd clears the pill",
                  reg.endSession(pill: claude, session: "b", now: later) == .pill)
        }

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
