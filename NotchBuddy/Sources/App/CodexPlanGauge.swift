#if !APPSTORE
import SwiftUI

// MARK: - Codex plan usage

struct CodexPlanUsage {
    var fiveHour: PlanWindow?
    var sevenDay: PlanWindow?
    var resetCredits: Int?         // free full resets available
    var resetCreditExpiresAt: Date? // soonest expiry among them
    var planType: String?
    var updatedAt: Date

    var planUsage: PlanUsage { PlanUsage(fiveHour: fiveHour, sevenDay: sevenDay, updatedAt: updatedAt) }
}

// MARK: - Parsing (fetched by the shared Codex connection)

enum CodexPlanGauge {

    /// Parses an `account/rateLimits/read` result.
    static func parse(result: [String: Any]) -> CodexPlanUsage? {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = buckets?["codex"] as? [String: Any] ?? result["rateLimits"] as? [String: Any] else { return nil }
        var usage = CodexPlanUsage(planType: limits["planType"] as? String, updatedAt: Date())
        // primary/secondary are not fixed to a window: sort them by duration.
        for value in CodexAgentsInfo.parseLimits(result) {
            guard let reset = value.resetsAt else { continue }
            let window = PlanWindow(usedPct: min(100, value.usedPercent), resetsAt: reset)
            if let mins = value.windowDurationMins, mins <= 24 * 60 {
                usage.fiveHour = window
            } else {
                usage.sevenDay = window
            }
        }
        if let resets = result["rateLimitResetCredits"] as? [String: Any] {
            usage.resetCredits = CodexAgentsInfo.integer(resets["availableCount"]).flatMap { Int(exactly: $0) }
            let expiries = (resets["credits"] as? [[String: Any]] ?? [])
                .filter { $0["status"] as? String == "available" }
                .compactMap { CodexAgentsInfo.integer($0["expiresAt"]) }
            usage.resetCreditExpiresAt = expiries.min().map { Date(timeIntervalSince1970: Double($0)) }
        }
        guard usage.fiveHour != nil || usage.sevenDay != nil else { return nil }
        return usage
    }

    static func pillLabel(_ usage: CodexPlanUsage?) -> String {
        guard let usage, let pct = ClaudePlanGauge.dominantPct(usage.planUsage) else { return "Codex —" }
        return "Codex \(Int(pct.rounded()))%"
    }

    static func color(_ usage: CodexPlanUsage?) -> String {
        ClaudePlanGauge.color(for: usage.flatMap { ClaudePlanGauge.dominantPct($0.planUsage) })
    }
}

// MARK: - Codex Plan Card View

private let resetExpiryFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.locale = .current
    fmt.setLocalizedDateFormatFromTemplate("MMMd")
    return fmt
}()

struct CodexPlanCardView: View {
    @ObservedObject private var info = CodexAgentsInfo.shared
    private var usage: CodexPlanUsage? { info.planUsage } // nil = loading or unavailable

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: info.isStale(at: now) ? "#6B7079" : CodexPlanGauge.color(usage)))
                    .frame(width: 7, height: 7)
                Text(String(localized: "Codex plan"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Gauge rows
            VStack(alignment: .leading, spacing: 5) {
                if usage?.fiveHour != nil {
                    GaugeRowView(label: String(localized: "5 hours"), window: usage?.fiveHour, now: now)
                }
                GaugeRowView(label: String(localized: "Week"), window: usage?.sevenDay, now: now, weekly: true)
                HStack(spacing: 5) {
                    Text(String(localized: "Resets"))
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 40, alignment: .leading)
                    Text(resetsText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .task {
            let task = AppState.shared.tasks.first { $0.id == "agent_codex" }
            await info.refresh(threadId: task?.codexThreadId, rolloutPath: task?.codexRolloutPath)
        }
        // Update countdown every 30s, only while visible
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return info.isRefreshing ? String(localized: "Asking Codex…") : String(localized: "codex.usage.unavailable") }
        if info.isStale(at: now) { return String(localized: "codex.usage.stale") }
        let plan = usage.planType.map { "\($0) · " } ?? ""
        let diff = now.timeIntervalSince(usage.updatedAt)
        if diff < 60 { return plan + String(localized: "just now") }
        let mins = Int(diff / 60)
        if mins < 60 { return plan + String(format: String(localized: "%lld min ago"), Int64(mins)) }
        return plan + String(format: String(localized: "%lld h ago"), Int64(mins / 60))
    }

    private var resetsText: String {
        guard let count = usage?.resetCredits else { return "—" }
        var text = String(format: String(localized: "%lld available"), Int64(count))
        if count > 0, let exp = usage?.resetCreditExpiresAt {
            text += String(format: String(localized: " · until %@"), resetExpiryFormatter.string(from: exp))
        }
        return text
    }
}
#endif
