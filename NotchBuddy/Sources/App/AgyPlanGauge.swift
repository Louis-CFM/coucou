import Foundation

// MARK: - Antigravity quota bucket

struct AgyQuotaBucket: Codable, Equatable, Sendable {
    let id: String
    let usedPct: Double   // 0–100, clamped
    let resetsAt: Date?
    let isWeekly: Bool
}

// MARK: - Antigravity plan usage

struct AgyPlanUsage: Codable, Equatable, Sendable {
    var buckets: [AgyQuotaBucket]
    var planTier: String?
    var updatedAt: Date
}

// MARK: - Parsing + helpers (Foundation-only, no AppKit/SwiftUI)

enum AgyPlanGauge {

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private nonisolated(unsafe) static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Parses `quota` and `plan_tier` from an Antigravity statusLine payload dict.
    /// Returns nil if `quota` is absent or has no usable buckets.
    static func parse(payload: [String: Any], now: Date = Date()) -> AgyPlanUsage? {
        guard let quota = payload["quota"] as? [String: Any] else { return nil }
        var parsed: [AgyQuotaBucket] = []

        for (bucketId, raw) in quota {
            guard let d = raw as? [String: Any] else { continue }
            if d["disabled"] as? Bool == true { continue }

            guard let usedPct = parseUsedPct(d) else { continue }
            let resetInSecs = parseDouble(d["reset_in_seconds"])
            let resetsAt = parseResetDate(d, resetInSecs: resetInSecs, now: now)
            let isWeekly = inferIsWeekly(id: bucketId, resetsAt: resetsAt, resetInSecs: resetInSecs, now: now)

            parsed.append(AgyQuotaBucket(
                id: bucketId,
                usedPct: usedPct,
                resetsAt: resetsAt,
                isWeekly: isWeekly
            ))
        }

        guard !parsed.isEmpty else { return nil }
        parsed.sort { $0.id < $1.id }

        let rawTier = (payload["plan_tier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tier = (rawTier?.isEmpty == false) ? rawTier : nil
        return AgyPlanUsage(buckets: parsed, planTier: tier, updatedAt: now)
    }

    private static func parseDouble(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        return nil
    }

    private static func parseUsedPct(_ d: [String: Any]) -> Double? {
        if let frac = parseDouble(d["remaining_fraction"]) {
            guard frac >= 0, frac <= 1.0 else { return nil }
            return min(100, max(0, (1.0 - frac) * 100.0))
        }
        if let pct = parseDouble(d["used_percentage"]) {
            guard pct >= 0, pct <= 200 else { return nil }
            return min(100, pct)
        }
        return nil
    }

    private static func parseResetDate(_ d: [String: Any], resetInSecs: Double?, now: Date) -> Date? {
        if let iso = d["reset_time"] as? String {
            if let dt = isoFractionalFormatter.date(from: iso) ?? isoFormatter.date(from: iso) {
                return dt
            }
        }
        if let secs = resetInSecs, secs > 0, secs <= 400 * 86400 {
            return now.addingTimeInterval(secs)
        }
        return nil
    }

    private static func inferIsWeekly(id: String, resetsAt: Date?, resetInSecs: Double?, now: Date) -> Bool {
        let lower = id.lowercased()
        if lower.contains("weekly") || lower.contains("7d") || lower.contains("week") {
            return true
        }
        if let secs = resetInSecs, secs > 24 * 3600 {
            return true
        }
        if let resetsAt, resetsAt.timeIntervalSince(now) > 24 * 3600 {
            return true
        }
        return false
    }

    /// Merges an incoming update with the current usage so stale sessions never move a gauge back.
    static func merge(_ current: AgyPlanUsage?, with incoming: AgyPlanUsage) -> AgyPlanUsage {
        guard let current else { return incoming }
        var byId: [String: AgyQuotaBucket] = Dictionary(uniqueKeysWithValues: current.buckets.map { ($0.id, $0) })
        for bucket in incoming.buckets {
            if let existing = byId[bucket.id] {
                byId[bucket.id] = latest(existing, bucket)
            } else {
                byId[bucket.id] = bucket
            }
        }
        let merged = byId.values.sorted { $0.id < $1.id }
        return AgyPlanUsage(
            buckets: merged,
            planTier: incoming.planTier ?? current.planTier,
            updatedAt: incoming.updatedAt
        )
    }

    private static func latest(_ current: AgyQuotaBucket, _ incoming: AgyQuotaBucket) -> AgyQuotaBucket {
        if let curReset = current.resetsAt, let incReset = incoming.resetsAt,
           abs(incReset.timeIntervalSince(curReset)) > 1 {
            return incReset > curReset ? incoming : current
        }
        return incoming.usedPct >= current.usedPct ? incoming : current
    }

    /// Effective % for display: 0 if the reset time is in the past.
    static func effectivePct(_ bucket: AgyQuotaBucket, now: Date = Date()) -> Double {
        if let resetsAt = bucket.resetsAt, resetsAt <= now { return 0 }
        return bucket.usedPct
    }

    /// Highest effective % across all buckets. nil if no buckets.
    static func dominantPct(_ usage: AgyPlanUsage, now: Date = Date()) -> Double? {
        usage.buckets.map { effectivePct($0, now: now) }.max()
    }

    /// Bucket with the highest effective %.
    static func dominantBucket(_ usage: AgyPlanUsage, now: Date = Date()) -> AgyQuotaBucket? {
        usage.buckets.max { effectivePct($0, now: now) < effectivePct($1, now: now) }
    }

    /// Hex color for a given usage (nil → grey).
    static func color(_ usage: AgyPlanUsage?, now: Date = Date()) -> String {
        ClaudePlanGauge.color(for: usage.flatMap { dominantPct($0, now: now) })
    }

    /// Label shown in the island pill chip.
    static func pillLabel(_ usage: AgyPlanUsage?, now: Date = Date()) -> String {
        guard let usage, let pct = dominantPct(usage, now: now) else { return "Agy —" }
        return "Agy \(Int(pct.rounded()))%"
    }

    /// Short human-readable label for a quota bucket row.
    static func bucketLabel(_ bucket: AgyQuotaBucket) -> String {
        let parts = bucket.id
            .split { $0 == "-" || $0 == "_" }
            .map { String($0).lowercased() }
        if parts.isEmpty { return bucket.id }

        let group: String
        switch parts[0] {
        case "gemini": group = "Gem"
        case "claude": group = "Cld"
        case "gpt", "openai": group = "GPT"
        default: group = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        }

        let windowTag = bucket.isWeekly ? "7d" : "5h"
        return "\(group) \(windowTag)"
    }
}
