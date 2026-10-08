#if !APPSTORE
import SwiftUI

struct CodexQuotaRow: View {
    let window: CodexUsageWindow

    private var label: String {
        guard let minutes = window.windowDurationMins else {
            return window.id == "primary" ? String(localized: "codex.usage.primary") : String(localized: "codex.usage.secondary")
        }
        if minutes == 10_080 { return String(localized: "plan.week") }
        if minutes % 60 == 0 { return String(format: String(localized: "codex.usage.hours %lld"), Int64(minutes / 60)) }
        return String(format: String(localized: "codex.usage.minutes %lld"), Int64(minutes))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in HStack(spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color(hex: ClaudePlanGauge.color(for: window.isExpired ? nil : window.usedPercent)))
                    .frame(width: max(0, 50 * min(100, window.usedPercent) / 100))
            }
            .frame(width: 50, height: 4)
            Text(String(format: String(localized: "codex.usage.used-remaining %lld %lld"),
                        Int64(min(100, max(0, window.usedPercent)).rounded()), Int64(window.remainingPercent.rounded())))
                .font(.system(size: 10)).monospacedDigit().foregroundColor(.secondary)
            Spacer(minLength: 0)
            if window.isExpired {
                Text(String(localized: "codex.usage.reset-refresh")).font(.system(size: 10)).foregroundColor(.secondary)
            } else if let reset = window.resetsAt {
                Text(reset, style: .relative).font(.system(size: 10)).foregroundColor(.secondary)
                    .help(reset.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text(String(localized: "codex.usage.reset-unknown")).font(.system(size: 10)).foregroundColor(.secondary)
            }
        } }
    }
}

struct CodexAgentsUsageView: View {
    @ObservedObject private var info = CodexAgentsInfo.shared
    @ObservedObject private var state = AppState.shared
    private var task: AgentTask? { state.tasks.first { $0.id == "agent_codex" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(String(localized: "codex.usage.title")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(String(localized: "Refresh")) { Task { await refresh() } }
                    .disabled(info.isRefreshing)
                if info.isRefreshing { ProgressView().controlSize(.small) }
            }
            Toggle(String(localized: "plan.show-in-notch"), isOn: $state.showCodexPlanInNotch)
            if info.isStale { Text(String(localized: "codex.usage.stale")).font(.system(size: 11)).foregroundColor(.secondary) }
            ForEach(info.limits) { window in CodexQuotaRow(window: window) }
            if info.limits.isEmpty { Text(String(localized: "codex.usage.unavailable")).font(.system(size: 11)).foregroundColor(.secondary) }
            Divider()
            Text(String(localized: "codex.tokens.account")).font(.system(size: 11, weight: .semibold))
            Text(info.lifetimeTokens.map { String(format: String(localized: "codex.tokens.lifetime %lld"), $0) }
                 ?? String(localized: "codex.tokens.unavailable"))
                .font(.system(size: 11)).foregroundColor(.secondary)
            ForEach(Array(info.dailyTokens.suffix(7))) { day in
                HStack {
                    Text(day.date)
                    Spacer()
                    Text(String(format: String(localized: "codex.tokens.count %lld"), day.tokens)).monospacedDigit()
                }.font(.system(size: 11)).foregroundColor(.secondary)
            }
            Text(String(localized: "codex.tokens.thread")).font(.system(size: 11, weight: .semibold))
            if let usage = info.threadTokens, info.threadId == task?.codexThreadId {
                Text(String(format: String(localized: "codex.tokens.thread-counts %lld %lld %lld"), usage.input, usage.output, usage.total))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                Text(usage.source).font(.system(size: 10)).foregroundColor(.secondary)
                if let threadId = info.threadId {
                    Text(String(format: String(localized: "codex.tokens.thread-id %@"), String(threadId.prefix(8))))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
            } else {
                Text(String(localized: "codex.tokens.thread-unavailable")).font(.system(size: 11)).foregroundColor(.secondary)
            }
            if let updated = info.updatedAt {
                Text(String(format: String(localized: "codex.usage.updated %@"), updated.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            if let error = info.error {
                Text(error).font(.system(size: 11)).foregroundColor(.secondary).textSelection(.enabled)
            }
        }
        .task { await refresh() }
        .onChange(of: task?.codexThreadId) { _, _ in Task { await refresh() } }
    }

    private func refresh() async {
        await info.refresh(threadId: task?.codexThreadId, rolloutPath: task?.codexRolloutPath)
    }
}
#endif
