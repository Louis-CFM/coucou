import SwiftUI

// MARK: - Claude Plan Card View

struct ClaudePlanCardView: View {
    let usage: PlanUsage?   // nil = installed, no data yet

    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                let dominant = usage.flatMap { ClaudePlanGauge.dominantPct($0) }
                Circle()
                    .fill(Color(hex: ClaudePlanGauge.color(for: dominant)))
                    .frame(width: 7, height: 7)
                Text(String(localized: "plan.card.title"))
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
                GaugeRowView(label: String(localized: "plan.5hours"), window: usage?.fiveHour, now: now)
                GaugeRowView(label: String(localized: "plan.week"),   window: usage?.sevenDay,  now: now, weekly: true)
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        // Update countdown every 30s, only while visible
        .background(
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return String(localized: "plan.waiting") }
        let diff = now.timeIntervalSince(usage.updatedAt)
        if diff < 60 { return String(localized: "plan.just-now") }
        let mins = Int(diff / 60)
        if mins < 60 { return String(format: String(localized: "plan.mins-ago %lld"), Int64(mins)) }
        return String(format: String(localized: "plan.hours-ago %lld"), Int64(mins / 60))
    }
}

// MARK: - Gauge Row

// DateFormatter created once for the weekly reset label
private let weeklyResetFormatter: DateFormatter = {
    let fmt = DateFormatter()
    fmt.dateFormat = "EEE H:mm"
    return fmt
}()

private struct GaugeRowView: View {
    let label: String
    let window: PlanWindow?
    let now: Date
    var weekly: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
                .frame(width: 40, alignment: .leading)
            if let w = window {
                let pct = ClaudePlanGauge.effectivePct(w)
                let accent = Color(hex: ClaudePlanGauge.color(for: pct))
                // Fixed-width bar (~50pt)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 50, height: 4)
                    Capsule()
                        .fill(accent)
                        .frame(width: max(0, 50 * CGFloat(pct / 100)), height: 4)
                }
                .frame(width: 50, height: 4)
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8))
                    .foregroundColor(Color(hex: "#6B7079"))
                Text(resetLabel(w))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .fixedSize()
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                Spacer()
            }
        }
    }

    private func resetLabel(_ w: PlanWindow) -> String {
        let secs = w.resetsAt.timeIntervalSince(now)
        guard secs > 0 else { return String(localized: "plan.resetting") }
        if weekly {
            return weeklyResetFormatter.string(from: w.resetsAt)
        } else {
            let h = Int(secs / 3600)
            let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
            if h > 0 { return String(format: String(localized: "plan.reset-in-hm %lld %lld"), Int64(h), Int64(m)) }
            return String(format: String(localized: "plan.reset-in-m %lld"), Int64(m))
        }
    }
}
