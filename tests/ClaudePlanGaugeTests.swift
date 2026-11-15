import Foundation

@main
enum ClaudePlanGaugeTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        let futureEpoch: Double = Date().timeIntervalSince1970 + 7200  // 2 hours from now
        let pastEpoch:   Double = Date().timeIntervalSince1970 - 100   // already passed

        // ── parse ──────────────────────────────────────────────────────────────
        print("ClaudePlanGauge.parse")

        let full: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 23.5, "resets_at": futureEpoch],
            "seven_day": ["used_percentage": 67.0, "resets_at": futureEpoch],
        ]]
        let usage = ClaudePlanGauge.parse(payload: full)
        checkTrue("parse full payload → non-nil",     usage != nil)
        checkTrue("five_hour usedPct 23.5",           usage?.fiveHour?.usedPct == 23.5)
        checkTrue("seven_day usedPct 67.0",           usage?.sevenDay?.usedPct == 67.0)

        // Missing rate_limits → nil
        checkTrue("missing rate_limits → nil",        ClaudePlanGauge.parse(payload: [:]) == nil)

        // Absurd pct (>200) → nil window  (150 is now clamped to 100)
        let badPct: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 250.0, "resets_at": futureEpoch],
        ]]
        let badUsage = ClaudePlanGauge.parse(payload: badPct)
        checkTrue("absurd pct (250) → nil window",    badUsage?.fiveHour == nil)

        // pct 150 → clamped to 100 (not rejected)
        let clampPct: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 150.0, "resets_at": futureEpoch],
        ]]
        let clampUsage = ClaudePlanGauge.parse(payload: clampPct)
        checkTrue("pct 150 → clamped to 100",         clampUsage?.fiveHour?.usedPct == 100.0)

        // pct 201 → rejected
        let tooBig: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 201.0, "resets_at": futureEpoch],
        ]]
        checkTrue("pct 201 → nil window",             ClaudePlanGauge.parse(payload: tooBig)?.fiveHour == nil)

        // resets_at > 400 days → rejected
        let farFuture = Date().timeIntervalSince1970 + 401 * 86400
        let msEpoch: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 50.0, "resets_at": farFuture],
        ]]
        checkTrue("resets_at > 400d → nil window",    ClaudePlanGauge.parse(payload: msEpoch)?.fiveHour == nil)

        // Negative pct → nil window
        let negPct: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": -5.0, "resets_at": futureEpoch],
        ]]
        checkTrue("negative pct → nil window",        ClaudePlanGauge.parse(payload: negPct)?.fiveHour == nil)

        // Int pct accepted
        let intPct: [String: Any] = ["rate_limits": [
            "five_hour": ["used_percentage": 42, "resets_at": Int(futureEpoch)],
        ]]
        let intUsage = ClaudePlanGauge.parse(payload: intPct)
        checkTrue("Int pct parsed",                   intUsage?.fiveHour?.usedPct == 42.0)

        // ── effectivePct (expired window) ─────────────────────────────────────
        print("ClaudePlanGauge.effectivePct")

        let expiredWindow = PlanWindow(usedPct: 80, resetsAt: Date(timeIntervalSince1970: pastEpoch))
        let futureWindow  = PlanWindow(usedPct: 80, resetsAt: Date(timeIntervalSince1970: futureEpoch))
        checkTrue("expired window → 0",               ClaudePlanGauge.effectivePct(expiredWindow) == 0)
        checkTrue("future window → original pct",     ClaudePlanGauge.effectivePct(futureWindow)  == 80)

        // ── dominantPct ────────────────────────────────────────────────────────
        print("ClaudePlanGauge.dominantPct")

        let both  = PlanUsage(fiveHour: PlanWindow(usedPct: 30, resetsAt: Date(timeIntervalSince1970: futureEpoch)),
                              sevenDay: PlanWindow(usedPct: 70, resetsAt: Date(timeIntervalSince1970: futureEpoch)),
                              updatedAt: Date())
        let fhOnly = PlanUsage(fiveHour: PlanWindow(usedPct: 55, resetsAt: Date(timeIntervalSince1970: futureEpoch)),
                               sevenDay: nil, updatedAt: Date())
        let empty  = PlanUsage(fiveHour: nil, sevenDay: nil, updatedAt: Date())

        checkTrue("dominant picks higher (70)",       ClaudePlanGauge.dominantPct(both) == 70)
        checkTrue("dominant with one window (55)",    ClaudePlanGauge.dominantPct(fhOnly) == 55)
        checkTrue("dominant with no windows → nil",   ClaudePlanGauge.dominantPct(empty) == nil)

        // ── color ──────────────────────────────────────────────────────────────
        print("ClaudePlanGauge.color")

        check("nil → grey",    ClaudePlanGauge.color(for: nil),  "#6B7079")
        check("0 → green",     ClaudePlanGauge.color(for: 0),    "#22C55E")
        check("49 → green",    ClaudePlanGauge.color(for: 49),   "#22C55E")
        check("50 → orange",   ClaudePlanGauge.color(for: 50),   "#F59E0B")
        check("79 → orange",   ClaudePlanGauge.color(for: 79),   "#F59E0B")
        check("80 → red",      ClaudePlanGauge.color(for: 80),   "#F4505E")
        check("100 → red",     ClaudePlanGauge.color(for: 100),  "#F4505E")

        // ── pillLabel ──────────────────────────────────────────────────────────
        print("ClaudePlanGauge.pillLabel")

        check("nil usage → 'Claude plan'",             ClaudePlanGauge.pillLabel(nil),    "Claude plan")
        check("no windows → 'Claude plan'",            ClaudePlanGauge.pillLabel(empty),  "Claude plan")
        check("70 pct → 'Claude 70%'",                 ClaudePlanGauge.pillLabel(both),   "Claude 70%")
        check("55 pct → 'Claude 55%'",                 ClaudePlanGauge.pillLabel(fhOnly), "Claude 55%")

        // ── merge ──────────────────────────────────────────────────────────────
        // Several Claude Code sessions relay their own, possibly stale, rate_limits.
        print("ClaudePlanGauge.merge")

        let window = Date(timeIntervalSince1970: futureEpoch)
        let nextWindow = Date(timeIntervalSince1970: futureEpoch + 18000)
        let current = PlanUsage(fiveHour: PlanWindow(usedPct: 34, resetsAt: window),
                                sevenDay: PlanWindow(usedPct: 44, resetsAt: window),
                                updatedAt: Date())

        let stale = PlanUsage(fiveHour: PlanWindow(usedPct: 33, resetsAt: window),
                              sevenDay: PlanWindow(usedPct: 38, resetsAt: window),
                              updatedAt: Date())
        let afterStale = ClaudePlanGauge.merge(current, with: stale)
        checkTrue("same window, lower pct → keeps 5h 34",  afterStale.fiveHour?.usedPct == 34)
        checkTrue("same window, lower pct → keeps 7d 44",  afterStale.sevenDay?.usedPct == 44)

        let higher = PlanUsage(fiveHour: PlanWindow(usedPct: 35, resetsAt: window),
                               sevenDay: nil, updatedAt: Date())
        let afterHigher = ClaudePlanGauge.merge(current, with: higher)
        checkTrue("same window, higher pct → 5h 35",       afterHigher.fiveHour?.usedPct == 35)
        checkTrue("missing window → keeps 7d 44",          afterHigher.sevenDay?.usedPct == 44)

        let reset = PlanUsage(fiveHour: PlanWindow(usedPct: 2, resetsAt: nextWindow),
                              sevenDay: nil, updatedAt: Date())
        let afterReset = ClaudePlanGauge.merge(current, with: reset)
        checkTrue("newer window → 5h 2 after reset",       afterReset.fiveHour?.usedPct == 2)

        let older = PlanUsage(fiveHour: PlanWindow(usedPct: 90, resetsAt: window),
                              sevenDay: nil, updatedAt: Date())
        let afterOlder = ClaudePlanGauge.merge(afterReset, with: older)
        checkTrue("older window → ignored, 5h stays 2",    afterOlder.fiveHour?.usedPct == 2)

        checkTrue("no current → takes incoming",
                  ClaudePlanGauge.merge(nil, with: stale).sevenDay?.usedPct == 38)

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
