import Foundation

// MARK: - Plan window

struct PlanWindow: Codable, Equatable {
    let usedPct: Double   // 0–100, clamped
    let resetsAt: Date
}

// MARK: - Plan usage

struct PlanUsage: Codable {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var updatedAt: Date
}

// MARK: - Parsing + helpers (Foundation-only, no AppKit/SwiftUI)

enum ClaudePlanGauge {

    /// Parses rate_limits from a statusline payload dict. Returns nil if absent/malformed.
    static func parse(payload: [String: Any]) -> PlanUsage? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let fh = parseWindow(limits["five_hour"])
        let sd = parseWindow(limits["seven_day"])
        guard fh != nil || sd != nil else { return nil }
        return PlanUsage(fiveHour: fh, sevenDay: sd, updatedAt: Date())
    }

    private static func parseWindow(_ raw: Any?) -> PlanWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        let rawPct: Double
        if let v = d["used_percentage"] as? Double { rawPct = v }
        else if let v = d["used_percentage"] as? Int { rawPct = Double(v) }
        else { return nil }
        guard rawPct >= 0, rawPct <= 200 else { return nil }
        let pct = min(100, rawPct)   // clamp 100–200 down to 100
        let rawEpoch: Double
        if let v = d["resets_at"] as? Double { rawEpoch = v }
        else if let v = d["resets_at"] as? Int { rawEpoch = Double(v) }
        else { return nil }
        guard rawEpoch > 0 else { return nil }
        // Reject if more than 400 days in the future (likely milliseconds, not seconds)
        let maxEpoch = Date().timeIntervalSince1970 + 400 * 86400
        guard rawEpoch <= maxEpoch else { return nil }
        return PlanWindow(usedPct: pct, resetsAt: Date(timeIntervalSince1970: rawEpoch))
    }

    /// Parses the account usage endpoint (`/api/oauth/usage`), the source behind Claude Code's
    /// `/usage`. It counts everything on the account: Claude Code, the Claude desktop app and
    /// claude.ai. Shape: `{"five_hour": {"utilization": 12.0, "resets_at": "2026-…Z"}, "seven_day": …}`.
    static func parseAccountUsage(_ json: [String: Any], now: Date = Date()) -> PlanUsage? {
        let fh = parseAccountWindow(json["five_hour"])
        let sd = parseAccountWindow(json["seven_day"])
        guard fh != nil || sd != nil else { return nil }
        return PlanUsage(fiveHour: fh, sevenDay: sd, updatedAt: now)
    }

    private static func parseAccountWindow(_ raw: Any?) -> PlanWindow? {
        guard let d = raw as? [String: Any] else { return nil }
        let rawPct: Double
        if let v = d["utilization"] as? Double { rawPct = v }
        else if let v = d["utilization"] as? Int { rawPct = Double(v) }
        else { return nil }
        guard rawPct >= 0, rawPct <= 200 else { return nil }
        guard let s = d["resets_at"] as? String, let date = parseISODate(s) else { return nil }
        return PlanWindow(usedPct: min(100, rawPct), resetsAt: date)
    }

    /// ISO 8601 with or without fractional seconds. The API sends microseconds
    /// ("…05:00:00.358469+00:00"), which ISO8601DateFormatter does not always accept, so the
    /// fraction is dropped (sub-second precision does not matter for a reset time).
    static func parseISODate(_ s: String) -> Date? {
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: trimmed)
    }

    /// Reads the OAuth access token from Claude Code's credentials JSON
    /// (`{"claudeAiOauth": {"accessToken": …, "expiresAt": <ms>}}`). nil if missing or expired:
    /// Coucou never refreshes the token itself, that would sign Claude Code out.
    static func accessToken(fromCredentials data: Data, now: Date = Date()) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let ms = (oauth["expiresAt"] as? Double) ?? (oauth["expiresAt"] as? Int).map(Double.init),
           Date(timeIntervalSince1970: ms / 1000) <= now { return nil }
        return token
    }

    /// Effective % for display: 0 if the reset time is in the past.
    static func effectivePct(_ w: PlanWindow) -> Double {
        w.resetsAt <= Date() ? 0 : w.usedPct
    }

    /// The higher of the two effective percentages. nil if both windows absent.
    static func dominantPct(_ usage: PlanUsage) -> Double? {
        let p1 = usage.fiveHour.map { effectivePct($0) }
        let p2 = usage.sevenDay.map { effectivePct($0) }
        switch (p1, p2) {
        case (.none, .none): return nil
        case (let x?, .none): return x
        case (.none, let y?): return y
        case (let x?, let y?): return max(x, y)
        }
    }

    /// Hex color for a given percentage (nil → grey).
    static func color(for pct: Double?) -> String {
        guard let p = pct else { return "#6B7079" }
        if p < 50  { return "#22C55E" }
        if p < 80  { return "#F59E0B" }
        return "#F4505E"
    }

    /// Label shown in the island pill chip.
    static func pillLabel(_ usage: PlanUsage?) -> String {
        guard let usage, let pct = dominantPct(usage) else { return "Claude plan" }
        return "Claude \(Int(pct.rounded()))%"
    }
}
