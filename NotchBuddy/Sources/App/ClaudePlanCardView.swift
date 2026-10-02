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
                Text("Claude plan")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(subtitleText)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Gauge rows
            VStack(alignment: .leading, spacing: 5) {
                GaugeRowView(label: "5 hours", window: usage?.fiveHour, now: now)
                GaugeRowView(label: "Week",    window: usage?.sevenDay,  now: now, weekly: true)
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        // Update countdown every second, only while visible
        .background(
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Color.clear.onChange(of: ctx.date) { _, d in now = d }
            }
        )
    }

    private var subtitleText: String {
        guard let usage else { return "Waiting for a Claude Code reply" }
        let diff = now.timeIntervalSince(usage.updatedAt)
        if diff < 60 { return "Updated just now" }
        let mins = Int(diff / 60)
        if mins < 60 { return "Updated \(mins) min ago" }
        let hrs = mins / 60
        return "Updated \(hrs) h ago"
    }
}

// MARK: - Gauge Row

private struct GaugeRowView: View {
    let label: String
    let window: PlanWindow?
    let now: Date
    var weekly: Bool = false

    var body: some View {
        HStack(spacing: 7) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
                .frame(width: 42, alignment: .leading)
            if let w = window {
                let pct = ClaudePlanGauge.effectivePct(w)
                let accent = Color(hex: ClaudePlanGauge.color(for: pct))
                // Thin bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 4)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(accent)
                            .frame(width: geo.size.width * CGFloat(pct / 100), height: 4)
                    }
                }
                .frame(height: 4)
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .monospacedDigit()
                    .frame(width: 30, alignment: .trailing)
                Text(resetLabel(w))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1)
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func resetLabel(_ w: PlanWindow) -> String {
        let secs = w.resetsAt.timeIntervalSince(now)
        guard secs > 0 else { return "Resetting…" }
        if weekly {
            // "Resets Mon 9:00"
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE H:mm"
            return "Resets \(fmt.string(from: w.resetsAt))"
        } else {
            // "Resets in 1 h 20" or "Resets in 45 min"
            let h = Int(secs / 3600)
            let m = Int((secs.truncatingRemainder(dividingBy: 3600)) / 60)
            if h > 0 { return "Resets in \(h) h \(m) min" }
            return "Resets in \(m) min"
        }
    }
}
