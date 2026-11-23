import Foundation

@main
enum AgyPlanGaugeTests {

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
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let futureISO = "2027-01-20T12:00:00Z"

        print("AgyPlanGauge.parse")

        let payload: [String: Any] = [
            "plan_tier": "Pro",
            "quota": [
                "gemini-weekly": [
                    "remaining_fraction": 0.75,
                    "reset_time": futureISO,
                    "reset_in_seconds": 500_000,
                ],
                "gemini-5h": [
                    "remaining_fraction": 0.40,
                    "reset_in_seconds": 3600,
                ],
                "disabled-bucket": [
                    "remaining_fraction": 0.0,
                    "disabled": true,
                ],
            ],
        ]

        let usage = AgyPlanGauge.parse(payload: payload, now: now)
        checkTrue("parse payload → non-nil", usage != nil)
        check("planTier → Pro", usage?.planTier ?? "", "Pro")
        checkTrue("2 active buckets (disabled skipped)", usage?.buckets.count == 2)

        let gem5h = usage?.buckets.first { $0.id == "gemini-5h" }
        let gemWeekly = usage?.buckets.first { $0.id == "gemini-weekly" }
        checkTrue("gemini-5h usedPct ~60", abs((gem5h?.usedPct ?? -1) - 60.0) < 0.01)
        checkTrue("gemini-5h isWeekly == false", gem5h?.isWeekly == false)
        checkTrue("gemini-weekly usedPct ~25", abs((gemWeekly?.usedPct ?? -1) - 25.0) < 0.01)
        checkTrue("gemini-weekly isWeekly == true", gemWeekly?.isWeekly == true)

        checkTrue("missing quota → nil", AgyPlanGauge.parse(payload: [:], now: now) == nil)
        checkTrue("empty quota → nil", AgyPlanGauge.parse(payload: ["quota": [:]], now: now) == nil)

        let badFrac: [String: Any] = ["quota": ["b": ["remaining_fraction": 1.5]]]
        checkTrue("remaining_fraction > 1 → nil", AgyPlanGauge.parse(payload: badFrac, now: now) == nil)

        let negFrac: [String: Any] = ["quota": ["b": ["remaining_fraction": -0.1]]]
        checkTrue("remaining_fraction < 0 → nil", AgyPlanGauge.parse(payload: negFrac, now: now) == nil)

        print("AgyPlanGauge.dominantPct & pillLabel & color")
        if let usage {
            checkTrue("dominantPct ~60", abs((AgyPlanGauge.dominantPct(usage, now: now) ?? -1) - 60.0) < 0.01)
            check("pillLabel → 'Agy 60%'", AgyPlanGauge.pillLabel(usage, now: now), "Agy 60%")
            check("color 60 → orange", AgyPlanGauge.color(usage, now: now), "#F59E0B")
        }
        check("nil usage → 'Agy —'", AgyPlanGauge.pillLabel(nil, now: now), "Agy —")
        check("nil usage → grey", AgyPlanGauge.color(nil, now: now), "#6B7079")

        print("AgyPlanGauge.effectivePct")
        let pastBucket = AgyQuotaBucket(id: "gemini-5h", usedPct: 85, resetsAt: now.addingTimeInterval(-10), isWeekly: false)
        let futureBucket = AgyQuotaBucket(id: "gemini-5h", usedPct: 85, resetsAt: now.addingTimeInterval(600), isWeekly: false)
        checkTrue("expired bucket → 0", AgyPlanGauge.effectivePct(pastBucket, now: now) == 0)
        checkTrue("future bucket → 85", AgyPlanGauge.effectivePct(futureBucket, now: now) == 85)

        print("AgyPlanGauge.bucketLabel")
        check("gemini-weekly → Gem 7d", AgyPlanGauge.bucketLabel(AgyQuotaBucket(id: "gemini-weekly", usedPct: 10, resetsAt: nil, isWeekly: true)), "Gem 7d")
        check("gemini-5h → Gem 5h", AgyPlanGauge.bucketLabel(AgyQuotaBucket(id: "gemini-5h", usedPct: 10, resetsAt: nil, isWeekly: false)), "Gem 5h")
        check("claude-weekly → Cld 7d", AgyPlanGauge.bucketLabel(AgyQuotaBucket(id: "claude-weekly", usedPct: 10, resetsAt: nil, isWeekly: true)), "Cld 7d")

        print("AgyPlanGauge.merge")
        let t1 = now.addingTimeInterval(3600)
        let t2 = now.addingTimeInterval(7200)
        let cur = AgyPlanUsage(
            buckets: [AgyQuotaBucket(id: "gemini-5h", usedPct: 40, resetsAt: t1, isWeekly: false)],
            planTier: "Pro",
            updatedAt: now
        )
        let stale = AgyPlanUsage(
            buckets: [AgyQuotaBucket(id: "gemini-5h", usedPct: 20, resetsAt: t1, isWeekly: false)],
            planTier: nil,
            updatedAt: now.addingTimeInterval(10)
        )
        let mergedStale = AgyPlanGauge.merge(cur, with: stale)
        checkTrue("same window lower pct keeps 40", mergedStale.buckets[0].usedPct == 40)
        check("keeps existing planTier", mergedStale.planTier ?? "", "Pro")

        let newerWindow = AgyPlanUsage(
            buckets: [AgyQuotaBucket(id: "gemini-5h", usedPct: 5, resetsAt: t2, isWeekly: false)],
            planTier: "Ultra",
            updatedAt: now.addingTimeInterval(20)
        )
        let mergedNewer = AgyPlanGauge.merge(cur, with: newerWindow)
        checkTrue("newer window resets pct to 5", mergedNewer.buckets[0].usedPct == 5)
        check("updates planTier to Ultra", mergedNewer.planTier ?? "", "Ultra")

        if failures > 0 {
            print("\n\(failures) failure(s).")
            exit(1)
        }
        print("\nAll AgyPlanGauge tests passed.")
    }
}
