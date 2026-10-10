import Foundation

// MARK: - WakeWindowBackoff tests
//
// Pure test — no AppKit, no VoiceEngine. Compiles with:
//   swiftc -o /tmp/voice-backoff-tests \
//     NotchBuddy/Sources/App/Voice/WakeWindowBackoff.swift \
//     tests/WakeWindowBackoffTests.swift

@main
enum WakeWindowBackoffTests {

    static var pass = 0
    static var fail = 0

    static func main() {
        let cfg = WakeWindowBackoff(fastThreshold: 1.0, maxFastFails: 3, base: 0.5, maxDelay: 5.0)

        // ── Backoff delays grow exponentially, capped at maxDelay ─────────────
        var b = cfg
        let r1 = b.windowEnded(elapsed: 0.1, wasError: true)
        check("streak 1 → delay 0.50s",  r1, .delay(0.5))
        check("streak after 1st fast",   b.streak, 1)

        let r2 = b.windowEnded(elapsed: 0.1, wasError: true)
        check("streak 2 → delay 1.00s",  r2, .delay(1.0))

        let r3 = b.windowEnded(elapsed: 0.1, wasError: true)
        check("streak 3 → stop",         r3, .stop)

        // ── Normal-length window resets streak ────────────────────────────────
        var b2 = cfg
        _ = b2.windowEnded(elapsed: 0.1, wasError: true)
        _ = b2.windowEnded(elapsed: 0.1, wasError: true)
        let rNorm = b2.windowEnded(elapsed: 2.0, wasError: false)   // normal duration
        check("normal end → open",        rNorm, .open)
        check("streak reset after normal", b2.streak, 0)

        // ── reset() clears streak ─────────────────────────────────────────────
        var b3 = cfg
        _ = b3.windowEnded(elapsed: 0.1, wasError: true)
        _ = b3.windowEnded(elapsed: 0.1, wasError: true)
        b3.reset()
        check("streak after reset",       b3.streak, 0)
        let rAfterReset = b3.windowEnded(elapsed: 0.1, wasError: true)
        check("first fail after reset → delay 0.50s", rAfterReset, .delay(0.5))

        // ── maxDelay cap ──────────────────────────────────────────────────────
        var b4 = WakeWindowBackoff(fastThreshold: 1.0, maxFastFails: 100, base: 0.5, maxDelay: 5.0)
        for _ in 0..<9 { _ = b4.windowEnded(elapsed: 0.1, wasError: true) }
        let rCap = b4.windowEnded(elapsed: 0.1, wasError: true)
        // streak 10 → 0.5 * 2^9 = 256 → capped at 5.0
        check("delay capped at maxDelay", rCap, .delay(5.0))

        // ── Rapid fast-fails: at most maxFastFails opens before .stop ─────────
        // Simulate a spotter that always fails instantly. Count how many .open/.delay
        // actions are returned before .stop (== how many windows would be opened).
        var b5 = cfg
        var opens = 0
        for _ in 0..<20 {
            let action = b5.windowEnded(elapsed: 0.05, wasError: true)
            switch action {
            case .open:         opens += 1
            case .delay:        opens += 1   // a delayed open still opens
            case .stop:         break
            }
            if case .stop = action { break }
        }
        // First call: streak becomes 1 → .delay (1 open scheduled)
        // Second call: streak becomes 2 → .delay (1 more open scheduled)
        // Third call: streak becomes 3 → .stop (no more)
        // Total opens before stop: 2 (streak 1 and 2 each produce a delayed open)
        check("at most maxFastFails-1 delayed opens before stop", opens, 2)

        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else         { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        if got == want { print("✓  \(label)"); pass += 1 }
        else           { print("✗  \(label) — got \(got), want \(want)"); fail += 1 }
    }
}
