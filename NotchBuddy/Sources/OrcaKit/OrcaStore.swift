import Foundation
import Observation

/// Observable view of Orca state, read straight from the `orca` CLI (no daemon).
/// Polling is a sleeping Task: nothing runs between cycles, and `stop()` cancels it entirely.
/// The cadence follows `OrcaPollPolicy` (fast while the island is on screen, slow otherwise); the CLI
/// work and the derivation run in `OrcaCollector` (an actor), only the snapshot assignment is on the main actor.
@MainActor
@Observable
public final class OrcaStore {
    public private(set) var snapshot: OrcaSnapshot = .empty
    public private(set) var isPolling = false

    /// Drop remote workspaces (and their workers) from the derived snapshot.
    public var includeRemote = true {
        didSet { if oldValue != includeRemote { Task { await rederive() } } }
    }

    @ObservationIgnored private let collector: OrcaCollector
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var interval: TimeInterval
    @ObservationIgnored private var tick: TimeInterval = OrcaPollPolicy.idleInterval
    @ObservationIgnored private var lastFullAt: Date?

    public init(runner: any OrcaCommandRunning = ProcessCommandRunner(),
                pollInterval: TimeInterval = OrcaCollector.defaultInterval) {
        collector = OrcaCollector(runner: runner, pollInterval: pollInterval)
        interval = max(pollInterval, OrcaCollector.minInterval)
    }

    public var pollInterval: TimeInterval { interval }

    public func setPollInterval(_ value: TimeInterval) {
        interval = max(value, OrcaCollector.minInterval)
        let c = collector, i = interval
        Task { await c.setPollInterval(i) }
    }

    /// Time between two cycles right now (policy-driven).
    public var tickInterval: TimeInterval { tick }

    /// Tells the store what the app is doing; a faster cadence restarts the loop (immediate refresh).
    public func setActivity(islandVisible: Bool, asleep: Bool) {
        let next = OrcaPollPolicy.interval(islandVisible: islandVisible, asleep: asleep)
        guard next != tick else { return }
        tick = next
        if task != nil { stop(); start() }
    }

    public func start() {
        guard task == nil else { return }
        isPolling = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.cycle()
                let seconds = self.tick
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isPolling = false
    }

    /// One immediate full collection cycle (all sources).
    public func refresh() async {
        lastFullAt = Date()
        let next = await collector.collect(includeRemote: includeRemote)
        if next != snapshot { snapshot = next }
    }

    /// One policy tick: a fast cycle (`worktree ps` only), or a full one when it is due.
    private func cycle() async {
        if OrcaPollPolicy.isFullCycleDue(lastFullAt: lastFullAt) {
            await refresh()
        } else {
            let next = await collector.collectFast(includeRemote: includeRemote)
            if next != snapshot { snapshot = next }
        }
    }

    private func rederive() async {
        let next = await collector.snapshot(includeRemote: includeRemote)
        if next != snapshot { snapshot = next }
    }
}
