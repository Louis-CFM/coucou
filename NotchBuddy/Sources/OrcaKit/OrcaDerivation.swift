import CryptoKit
import Foundation

/// Pure derivation of an `OrcaSnapshot` from the last good raw data (docs/api.md, "Derivações").
enum OrcaDerivation {
    static let attentionWindow: TimeInterval = 24 * 3600

    static func key(for worktreeId: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(worktreeId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    static func derive(raw: OrcaRawState, sources: [OrcaSource: OrcaSourceHealth], lastCompleteCycleAt: Int?,
                       pollInterval: TimeInterval, includeRemote: Bool = true,
                       now: Date = Date(), calendar: Calendar = .current) -> OrcaSnapshot {
        let nowSec = Int(now.timeIntervalSince1970)
        let todayStart = Int(calendar.startOfDay(for: now).timeIntervalSince1970)
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            .map { Int($0.timeIntervalSince1970) } ?? todayStart + 86400

        let visible = raw.worktrees.filter { w in
            guard w.isArchived != true else { return false }
            return includeRemote || !isRemote(w)
        }
        let remoteIds = Set(raw.worktrees.filter(isRemote).compactMap(\.worktreeId))
        let workers: [RawWorker] = raw.workers.filter { w in
            if includeRemote { return true }
            if let h = w.projection?.host?.id, h != "local" { return false }
            if let id = w.projection?.workspace?.id, remoteIds.contains(id) { return false }
            return true
        }
        let activityById = Dictionary(raw.worktrees.compactMap { w in
            w.worktreeId.map { ($0, lastActivity(of: w)) }
        }, uniquingKeysWith: { a, _ in a })

        func summary(_ w: RawWorker) -> OrcaWorkerSummary {
            OrcaWorkerSummary(
                taskId: w.taskId, outcome: outcome(of: w), stage: w.projection?.stage?.detail,
                requiresAction: w.projection?.attention?.requiresAction == true,
                updatedAt: workerUpdate(w, fallback: w.projection?.workspace?.id.flatMap { activityById[$0] ?? nil }))
        }
        let summaries = workers.map { (worker: $0, summary: summary($0)) }
        let workersByWorkspace = Dictionary(grouping: summaries) { $0.worker.projection?.workspace?.id ?? "" }

        var workspaces: [OrcaWorkspace] = []
        var doneToday = Set<String>()
        for w in visible {
            let id = w.worktreeId ?? "\(w.repo ?? "")/\(w.displayName ?? "")"
            let agents = (w.agents ?? []).map { a in
                OrcaAgent(type: a.agentType, state: a.state, since: a.stateStartedAt.map(seconds), tool: a.toolName,
                          last: OrcaFormatting.oneLine(a.lastAssistantMessage, limit: 160))
            }
            let ws = (workersByWorkspace[id] ?? []).map(\.summary)
            let activity = lastActivity(of: w)
            let recent = activity.map { Double(nowSec - $0) <= attentionWindow } ?? false
            let wantsYou = w.unread == true
                || agents.contains { $0.state != "working" && $0.state != "done" }
                || ws.contains { $0.requiresAction }
            let attention = wantsYou && recent
            let pr = w.linkedPR.map { OrcaPullRequest(number: $0.number, state: $0.state) }
            let state: OrcaWorkspaceState
            if ws.contains(where: { $0.outcome == "failed" }) { state = .failed }
            else if attention { state = .attention }
            else if agents.contains(where: \.isWorking) { state = .running }
            else if w.workspaceStatus == "in-review" || pr?.isOpen == true { state = .review }
            else if w.workspaceStatus == "completed" || (!agents.isEmpty && agents.allSatisfy { $0.state == "done" }) { state = .done }
            else { state = .idle }

            let finishedToday = ws.contains { ($0.outcome == "succeeded" || $0.outcome == "failed") && inDay($0.updatedAt, todayStart, tomorrowStart) }
                || agents.contains { $0.state == "done" && inDay($0.since, todayStart, tomorrowStart) }
            if finishedToday { doneToday.insert(id) }

            workspaces.append(OrcaWorkspace(
                key: key(for: id), repo: w.repo ?? "", name: w.displayName ?? "",
                branch: w.branch.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst(11)) : $0 },
                state: state, workspaceStatus: w.workspaceStatus,
                comment: OrcaFormatting.oneLine(w.comment, limit: 120), unread: w.unread == true, pr: pr,
                liveTerminals: w.liveTerminalCount ?? 0, lastActivityAt: activity, isActive: isActive(w),
                isRemote: isRemote(w), needsAttention: attention, agents: agents, workers: ws))
        }
        // Workers whose workspace is not in the list (removed/archived) still count as done today.
        let known = Set(raw.worktrees.compactMap(\.worktreeId))
        for item in summaries where (item.summary.outcome == "succeeded" || item.summary.outcome == "failed")
            && inDay(item.summary.updatedAt, todayStart, tomorrowStart) {
            let id = item.worker.projection?.workspace?.id ?? item.worker.taskId ?? ""
            if !known.contains(id) { doneToday.insert(id) }
        }

        workspaces.sort {
            $0.state.priority != $1.state.priority ? $0.state.priority < $1.state.priority
                : ($0.lastActivityAt ?? 0) > ($1.lastActivityAt ?? 0)
        }

        var counts = OrcaCounts()
        counts.active = workspaces.filter(\.isActive).count
        counts.running = workspaces.filter(\.hasRunningAgent).count
        counts.runningAgents = workspaces.reduce(0) { $0 + $1.agents.filter(\.isWorking).count }
        counts.attention = workspaces.filter(\.needsAttention).count
        counts.remote = workspaces.filter(\.isRemote).count
        counts.doneToday = doneToday.count

        var workerCounts = OrcaWorkerCounts()
        for item in summaries {
            switch item.summary.outcome {
            case "succeeded": workerCounts.succeeded += 1
            case "failed": workerCounts.failed += 1
            default: if item.worker.projection?.liveness?.verdict != "exited" { workerCounts.running += 1 }
            }
            if item.summary.requiresAction { workerCounts.requiresAction += 1 }
        }

        let stale = lastCompleteCycleAt.map { Double(nowSec - $0) > 3 * pollInterval } ?? true
        let runtime = raw.status
        return OrcaSnapshot(
            generatedAt: nowSec, stale: stale,
            orca: OrcaRuntimeInfo(ok: (sources[.status]?.ok ?? false) && runtime?.state == "ready" && runtime?.reachable != false,
                                  version: runtime?.appVersion),
            counts: counts, workers: workerCounts,
            usage: usage(raw.rateLimits, now: now, calendar: calendar),
            workspaces: workspaces, sources: sources)
    }

    // MARK: - Rules

    static func isRemote(_ w: RawWorktree) -> Bool { (w.hostId ?? "local") != "local" }

    static func isActive(_ w: RawWorktree) -> Bool {
        w.isArchived != true && (w.status == "active" || w.status == "working" || w.terminalVerdict == "live")
    }

    /// Workers expose outcome `succeeded`/`failed`/`in_progress`; everything else is `running`.
    static func outcome(of w: RawWorker) -> String {
        switch w.projection?.outcome {
        case "succeeded": "succeeded"
        case "failed": "failed"
        default: "running"
        }
    }

    static func seconds(_ ms: Double) -> Int { Int(ms / 1000) }

    /// `lastActivityAt`, or `lastOutputAt` if more recent (epoch seconds).
    static func lastActivity(of w: RawWorktree) -> Int? {
        [w.lastActivityAt, w.lastOutputAt].compactMap { $0 }.max().map(seconds)
    }

    /// worker-list has no "updated at"; use the latest liveness observation, else the workspace activity.
    static func workerUpdate(_ w: RawWorker, fallback: Int?) -> Int? {
        let observed = [w.projection?.liveness?.observedAt, w.projection?.evidence?.lastObservedAt].compactMap { $0 }.max()
        return observed.map(seconds) ?? fallback
    }

    static func inDay(_ t: Int?, _ start: Int, _ end: Int) -> Bool {
        guard let t else { return false }
        return t >= start && t < end
    }

    static func usage(_ limits: [String: RawRateLimit], now: Date, calendar: Calendar) -> [OrcaProviderUsage] {
        func window(_ w: RawRateLimit.RawWindow?) -> OrcaUsageWindow? {
            guard let w, let pct = w.usedPercent else { return nil }
            let reset = w.resetsAt.map(seconds)
            return OrcaUsageWindow(pct: pct, resetsAt: reset,
                                   resetText: reset.map { OrcaFormatting.resetText(resetsAt: $0, now: now, calendar: calendar) })
        }
        return limits.compactMap { name, l -> OrcaProviderUsage? in
            let provider = l.provider ?? name
            let (s, wk) = (window(l.session), window(l.weekly))
            guard s != nil || wk != nil else { return nil }
            return OrcaProviderUsage(provider: provider, label: OrcaFormatting.providerLabel(provider), session: s, weekly: wk)
        }.sorted { $0.provider < $1.provider }
    }
}
