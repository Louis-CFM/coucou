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

        // Resting bar auto-hide: a hover peek hides after the short delay once the pointer leaves.
        let peek = IslandStateMachine()
        peek.petitToHiddenDelay = 30
        peek.hoverPeekHideDelay = { 0.1 }
        peek.mouseEntered()
        precondition(peek.state == .petit && peek.peekedByHover)
        peek.mouseLeft()
        try await waitFor(.hidden, peek, timeout: 2)

        // Without the delay (setting off or a notch screen), the peek keeps the normal delay.
        let normalPeek = IslandStateMachine()
        normalPeek.petitToHiddenDelay = 30
        normalPeek.mouseEntered()
        normalPeek.mouseLeft()
        try await Task.sleep(for: .milliseconds(500))
        precondition(normalPeek.state == .petit)

        // A compact island revealed by agent work keeps the normal delay.
        let work = IslandStateMachine()
        work.petitToHiddenDelay = 30
        work.hoverPeekHideDelay = { 0.1 }
        work.reveal()
        precondition(!work.peekedByHover)
        work.mouseEntered()
        work.mouseLeft()
        try await Task.sleep(for: .milliseconds(500))
        precondition(work.state == .petit)

        // Work arriving during a hover peek turns it into a normal compact island.
        let peekThenWork = IslandStateMachine()
        peekThenWork.petitToHiddenDelay = 30
        peekThenWork.hoverPeekHideDelay = { 0.1 }
        peekThenWork.mouseEntered()
        peekThenWork.mouseLeft()
        peekThenWork.reveal()
        try await Task.sleep(for: .milliseconds(500))
        precondition(peekThenWork.state == .petit && !peekThenWork.peekedByHover)

        // A hover-opened island folds to a peek that also hides quickly.
        let hoverOpen = machine()
        hoverOpen.petitToHiddenDelay = 30
        hoverOpen.hoverPeekHideDelay = { 0.1 }
        hoverOpen.mouseEntered()
        hoverOpen.mouseLeft()
        try await waitFor(.petit, hoverOpen, timeout: 2)
        precondition(hoverOpen.peekedByHover)
        hoverOpen.mouseLeft()   // the controller calls this when the fold lands with the pointer outside
        try await waitFor(.hidden, hoverOpen, timeout: 2)

        print("Island open on hover and peek auto-hide: 11 cases passed")
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
