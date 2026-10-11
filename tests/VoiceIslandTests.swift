import Foundation

@main
enum VoiceIslandTests {
    @MainActor
    static func main() async throws {
        // Helpers to reach states via FSM methods (state is private(set))
        func petit() -> IslandStateMachine { let m = IslandStateMachine(); m.mouseEntered(); return m }
        func home()  -> IslandStateMachine { let m = IslandStateMachine(); m.click(); return m }

        // voiceWoke from any state → listening
        do {
            let m = IslandStateMachine()
            m.voiceWoke()
            precondition(m.state == .listening, "voiceWoke from hidden → listening")
        }
        do {
            let m = petit()
            m.voiceWoke()
            precondition(m.state == .listening, "voiceWoke from petit → listening")
        }
        do {
            let m = home()
            m.voiceWoke()
            precondition(m.state == .listening, "voiceWoke from home → listening")
        }

        // voiceFinished returns to previous state
        do {
            let m = IslandStateMachine()                 // prev = hidden
            m.voiceWoke(); m.voiceFinished()
            precondition(m.state == .petit, "voiceFinished from hidden-prev → petit")
        }
        do {
            let m = petit()                               // prev = petit
            m.voiceWoke(); m.voiceFinished()
            precondition(m.state == .petit, "voiceFinished from petit-prev → petit")
        }
        do {
            let m = home()                                // prev = home
            m.voiceWoke(); m.voiceFinished()
            precondition(m.state == .home, "voiceFinished from home-prev → home")
        }

        // voiceFinished is a no-op when not in listening
        do {
            let m = home()
            m.voiceFinished()
            precondition(m.state == .home, "voiceFinished not in listening → no-op")
        }

        // collapse while listening → petit
        do {
            let m = IslandStateMachine()
            m.voiceWoke(); m.collapse()
            precondition(m.state == .petit, "collapse while listening → petit")
        }

        // click while listening → home: the island opens, voice keeps running
        do {
            let m = IslandStateMachine()
            m.voiceWoke(); m.click()
            precondition(m.state == .home, "click while listening → home")
        }

        // mouseLeft while listening → stays listening (no timer scheduled)
        do {
            let m = IslandStateMachine()
            m.voiceWoke(); m.mouseLeft()
            precondition(m.state == .listening, "mouseLeft while listening → stays listening")
        }

        // mouseEntered while listening → no-op
        do {
            let m = IslandStateMachine()
            m.voiceWoke(); m.mouseEntered()
            precondition(m.state == .listening, "mouseEntered while listening → no-op")
        }

        // transition sequence home → listening → home
        do {
            let m = home()
            var seq: [(IslandStateMachine.State, IslandStateMachine.State)] = []
            m.onTransition = { from, to in seq.append((from, to)) }
            m.voiceWoke(); m.voiceFinished()
            precondition(seq.count == 2, "home→listening→home: 2 transitions, got \(seq.count)")
            precondition(seq[0] == (.home, .listening), "first: home→listening")
            precondition(seq[1] == (.listening, .home),  "second: listening→home")
        }

        // double voiceWoke → idempotent
        do {
            let m = IslandStateMachine()
            m.voiceWoke()
            var extra = 0
            m.onTransition = { _, _ in extra += 1 }
            m.voiceWoke()
            precondition(extra == 0, "double voiceWoke → no extra transition")
        }

        // voiceFinished from home-prev schedules the home-collapse timer
        do {
            let m = home()
            m.homeToPetitDelay = 0.05   // 50 ms for a fast test
            m.voiceWoke(); m.voiceFinished()
            precondition(m.state == .home, "voiceFinished home-prev → home immediately")
            try await Task.sleep(for: .milliseconds(200))
            precondition(m.state == .petit, "home auto-collapsed after homeToPetitDelay")
        }

        print("\nAll VoiceIslandTests passed.")
    }
}
