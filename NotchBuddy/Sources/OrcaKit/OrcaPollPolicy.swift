import Foundation

/// When to ask the `orca` CLI for fresh data. The CLI has no watch/stream/subscribe mode
/// (see docs/orca-polling.md), so the notch polls; this type is the whole rate policy, kept pure.
public enum OrcaPollPolicy {
    /// Island on screen (compact or open) and the Mac awake: counters need to feel live.
    public static let activeInterval: TimeInterval = 2.5
    /// Island hidden, or the Mac / screen asleep: just enough to notice work starting.
    public static let idleInterval: TimeInterval = 15
    /// Slow sources (accounts, workers, status) are re-read at most this often, whatever the tick.
    public static let fullRefreshInterval: TimeInterval = 15

    public static func interval(islandVisible: Bool, asleep: Bool) -> TimeInterval {
        islandVisible && !asleep ? activeInterval : idleInterval
    }

    /// Fast ticks read only `worktree ps` (all the counters and the list need); a full cycle
    /// (all four sources) runs when none ran yet or the last one is `fullRefreshInterval` old.
    public static func isFullCycleDue(lastFullAt: Date?, now: Date = Date(),
                                      fullInterval: TimeInterval = fullRefreshInterval) -> Bool {
        guard let lastFullAt else { return true }
        // Half a fast tick of slack so a 15 s cadence is not pushed to 17.5 s by timer jitter.
        return now.timeIntervalSince(lastFullAt) >= fullInterval - activeInterval / 2
    }
}
