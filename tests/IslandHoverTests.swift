import Foundation

@main
enum IslandHoverTests {
    @MainActor
    static func main() async throws {
        // Off (default): hovering only peeks, as before.
        let off = IslandStateMachine()
        off.mouseEntered()
        precondition(off.state == .petit)

        // On: hovering a hidden island opens it, leaving folds it after the short delay.
        let on = machine()
        on.mouseEntered()
        precondition(on.state == .home && on.openedByHover)
        on.mouseLeft()
        precondition(on.state == .home)        // folds after the grace period, not at once
        try await waitFor(.petit, on, timeout: 5)
        precondition(!on.openedByHover)

        // Coming back before the delay keeps it open.
        let back = machine()
        back.mouseEntered()
        back.mouseLeft()
        back.mouseEntered()
        try await Task.sleep(for: .milliseconds(600))   // well past the 0.3 s grace period
        precondition(back.state == .home)

        // A click inside turns it into a normal open island: the auto-close delay applies.
        let clicked = machine()
        clicked.homeToPetitDelay = 3
        clicked.mouseEntered()
        clicked.userInteracted()
        clicked.mouseLeft()
        try await Task.sleep(for: .milliseconds(600))   // past the hover grace, far from 3 s
        precondition(clicked.state == .home)
        clicked.homeToPetitDelay = 0.05
        try await waitFor(.petit, clicked, timeout: 5)

        // A pending approval holds the island: hover never opens or folds it on its own.
        let held = machine()
        held.isHeldOpen = { true }
        held.mouseEntered()
        precondition(held.state == .home && !held.openedByHover)
        held.mouseLeft()
        try await Task.sleep(for: .milliseconds(600))
        precondition(held.state == .home)

        // An island opened by an alert keeps the normal delay even with hover on.
        let alert = machine()
        alert.homeToPetitDelay = 3
        alert.openedExternally()
        alert.mouseEntered()
        alert.mouseLeft()
        try await Task.sleep(for: .milliseconds(600))
        precondition(alert.state == .home)

        print("Island open on hover: 6 cases passed")
    }

    @MainActor
    private static func machine() -> IslandStateMachine {
        let m = IslandStateMachine()
        m.openOnHover = true
        m.hoverCloseDelay = 0.3
        return m
    }

    @MainActor
    private static func waitFor(_ s: IslandStateMachine.State, _ m: IslandStateMachine, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while m.state != s && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(m.state == s, "state \(m.state) after \(timeout) s, expected \(s)")
    }
}
