import Foundation

@main
enum IslandAutoCloseTests {
    @MainActor
    static func main() async throws {
        // A configured 2-second delay replaces the default 15 seconds.
        let configured = openedMachine(delay: 2)
        let start = DispatchTime.now().uptimeNanoseconds
        configured.mouseLeft()
        try await waitForCompact(configured)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        precondition(elapsed >= 1.9 && elapsed < 5)
        print(String(format: "Configured 2-second close: %.3f s", elapsed))

        // Editing the setting during a pending countdown must replace its timer.
        let edited = openedMachine(delay: 15)
        edited.mouseLeft()
        edited.homeToPetitDelay = 0.05
        try await waitForCompact(edited, )

        // Increasing the delay must also cancel the previous, shorter timer.
        // (Margins sized for a slow CI runner: the check runs long after the
        // old 0.05 s timer would have fired and long before the new 3 s one.)
        let extended = openedMachine(delay: 0.05)
        extended.mouseLeft()
        extended.homeToPetitDelay = 3
        try await Task.sleep(for: .milliseconds(600))
        precondition(extended.state == .home)
        extended.homeToPetitDelay = 0.05
        try await waitForCompact(extended)

        // Returning to the island cancels the countdown; leaving starts it again.
        let hovered = openedMachine(delay: 0.05)
        hovered.mouseLeft()
        hovered.mouseEntered()
        try await Task.sleep(for: .milliseconds(100))
        precondition(hovered.state == .home)
        hovered.mouseLeft()
        try await waitForCompact(hovered, )

        // A setting edit while hovering must not start a countdown.
        let hoveredEdit = openedMachine(delay: 15)
        hoveredEdit.homeToPetitDelay = 0.05
        try await Task.sleep(for: .milliseconds(100))
        precondition(hoveredEdit.state == .home)
        hoveredEdit.mouseLeft()
        try await waitForCompact(hoveredEdit, )

        // Greeting timing is independent from the normal auto-close preference.
        let greeting = IslandStateMachine()
        greeting.greetAutoCollapseDelay = 1.5
        greeting.launch()
        greeting.greetComplete()
        greeting.homeToPetitDelay = 0.01
        try await Task.sleep(for: .milliseconds(400))
        precondition(greeting.state == .coucou)
        try await waitForCompact(greeting)

        // An unanswered approval holds the island open even after a delay edit.
        let heldOpen = openedMachine(delay: 0.05)
        var approvalPending = true
        heldOpen.isHeldOpen = { approvalPending }
        heldOpen.mouseLeft()
        heldOpen.homeToPetitDelay = 0.01
        try await Task.sleep(for: .milliseconds(100))
        precondition(heldOpen.state == .home)
        approvalPending = false
        heldOpen.mouseLeft()
        try await waitForCompact(heldOpen, )

        // An approval arriving during a countdown also blocks its replacement timer.
        let heldCountdown = openedMachine(delay: 0.2)
        var newApprovalPending = false
        heldCountdown.isHeldOpen = { newApprovalPending }
        heldCountdown.mouseLeft()
        newApprovalPending = true
        heldCountdown.homeToPetitDelay = 0.01
        try await Task.sleep(for: .milliseconds(100))
        precondition(heldCountdown.state == .home)
        newApprovalPending = false
        heldCountdown.mouseLeft()
        try await waitForCompact(heldCountdown, )

        print("Island auto-close: 8 cases passed")
    }

    @MainActor
    private static func openedMachine(delay: TimeInterval) -> IslandStateMachine {
        let machine = IslandStateMachine()
        machine.homeToPetitDelay = delay
        machine.mouseEntered()
        machine.click()
        precondition(machine.state == .home)
        return machine
    }

    @MainActor
    private static func waitForCompact(_ machine: IslandStateMachine,
                                       timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while machine.state != .petit && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(machine.state == .petit, "Auto-close did not fire within \(timeout) seconds")
    }
}
