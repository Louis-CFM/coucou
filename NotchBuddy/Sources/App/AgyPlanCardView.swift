#if !APPSTORE
import SwiftUI

// MARK: - Antigravity Plan Card View

struct AgyPlanCardView: View {
    let usage: AgyPlanUsage?   // nil = installed, no data yet

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: AgyPlanGauge.color(usage, now: now)))
                    .frame(width: 7, height: 7)
                Text("Antigravity plan")
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
                if let buckets = usage?.buckets, !buckets.isEmpty {
                    ForEach(buckets.prefix(3), id: \.id) { bucket in
                        GaugeRowView(
                            label: AgyPlanGauge.bucketLabel(bucket),
                            window: bucket.resetsAt.map { PlanWindow(usedPct: bucket.usedPct, resetsAt: $0) },
                            now: now,
                            weekly: bucket.isWeekly
                        )
                    }
                } else {
                    GaugeRowView(label: String(localized: "plan.5hours"), window: nil, now: now)
                    GaugeRowView(label: String(localized: "plan.week"), window: nil, now: now, weekly: true)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return String(localized: "plan.waiting") }
        let diff = now.timeIntervalSince(usage.updatedAt)
        let age: String
        if diff < 60 {
            age = String(localized: "plan.just-now")
        } else {
            let mins = Int(diff / 60)
            if mins < 60 {
                age = String(format: String(localized: "plan.mins-ago %lld"), Int64(mins))
            } else {
                age = String(format: String(localized: "plan.hours-ago %lld"), Int64(mins / 60))
            }
        }
        if let tier = usage.planTier, !tier.isEmpty {
            return "\(tier) · \(age)"
        }
        return age
    }
}
#endif
