import Foundation

// MARK: - SpotterGeneration + spotterIsExpectedError tests
//
// Pure test — no AppKit, no AVFoundation. Compiles with:
//   swiftc -o /tmp/spotter-gen-tests \
//     NotchBuddy/Sources/App/Voice/SpotterGeneration.swift \
//     tests/SpotterGenerationTests.swift

@main
enum SpotterGenerationTests {

    static var pass = 0
    static var fail = 0

    static func main() {

        // ── Generation counter basics ─────────────────────────────────────────

        var gen = SpotterGeneration()
        check("initial current is 0",   gen.current, 0)
        check("isValid(0) before bump", gen.isValid(0), true)

        let g1 = gen.bump()
        check("bump returns 1",         g1, 1)
        check("current is 1",           gen.current, 1)
        check("isValid(1) after bump",  gen.isValid(1), true)
        check("isValid(0) after bump",  gen.isValid(0), false)

        let g2 = gen.bump()
        check("second bump returns 2",  g2, 2)
        check("isValid(2)",             gen.isValid(2), true)
        check("isValid(1) stale",       gen.isValid(1), false)
        check("isValid(0) stale",       gen.isValid(0), false)

        // ── beginWindow / endWindow simulation ───────────────────────────────
        //
        // Scenario: task A starts (gen=1), window ends/cancelled (gen=2),
        // task B starts (gen=3). A's callback arrives — must be ignored.

        var s = SpotterGeneration()
        let genA = s.bump()                // beginWindow A → gen 1
        check("genA == 1",                 genA, 1)

        s.bump()                           // endWindow → gen 2 (invalidates A)
        check("genA stale after endWindow", s.isValid(genA), false)

        let genB = s.bump()                // beginWindow B → gen 3
        check("genB == 3",                 genB, 3)
        check("genB valid",                s.isValid(genB), true)
        check("genA still stale",          s.isValid(genA), false)

        // ── spotterIsExpectedError ────────────────────────────────────────────

        // 1110: no-speech timeout (normal window close, never a backoff failure)
        let err1110 = NSError(domain: "kAFAssistantErrorDomain", code: 1110)
        check("1110 is expected",          spotterIsExpectedError(err1110), true)

        // NSUserCancelledError (3072): task.cancel() from endWindow
        let errCancel = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        check("NSUserCancelledError is expected", spotterIsExpectedError(errCancel), true)

        // A real recognition error (e.g. 1700 = recognition failed)
        let errReal = NSError(domain: "kAFAssistantErrorDomain", code: 1700)
        check("code 1700 is NOT expected", spotterIsExpectedError(errReal), false)

        // Different domain, same code as 1110
        let errWrongDomain = NSError(domain: "com.apple.avfoundation", code: 1110)
        check("wrong domain + 1110 is NOT expected", spotterIsExpectedError(errWrongDomain), false)

        // ── 20-second restart scenario ────────────────────────────────────────
        //
        // Task A opened, window times out after 20 s (endWindow called → gen bumped),
        // task B opened immediately. Task A's 1110 callback arrives → stale + expected.
        // Task B must remain valid.

        var s2 = SpotterGeneration()
        let genA2 = s2.bump()              // beginWindow A
        s2.bump()                          // endWindow (20s later) — invalidates A
        let genB2 = s2.bump()              // beginWindow B

        // Simulate A's 1110 callback arriving now:
        let stale  = !s2.isValid(genA2)    // true → should be ignored
        let normal = spotterIsExpectedError(err1110)  // true → not a backoff error
        check("20s restart: A's callback is stale",   stale, true)
        check("20s restart: 1110 is expected error",  normal, true)
        check("20s restart: B still valid",           s2.isValid(genB2), true)

        // ── Late partial from A containing "ok coucou" ───────────────────────
        //
        // After endWindow, A sends a partial with a wake phrase. Because genA is
        // stale, the callback must be dropped before wake detection.

        var s3 = SpotterGeneration()
        let genA3 = s3.bump()              // beginWindow A
        s3.bump()                          // endWindow
        let genB3 = s3.bump()              // beginWindow B

        let latePartialFromA = s3.isValid(genA3)  // false → callback dropped
        check("late partial from A → stale (dropped)",       latePartialFromA, false)
        check("B unaffected by A's late partial",            s3.isValid(genB3), true)

        // ── Summary ──────────────────────────────────────────────────────────
        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else         { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        if got == want { print("✓  \(label)"); pass += 1 }
        else           { print("✗  \(label) — got \(got), want \(want)"); fail += 1 }
    }
}
