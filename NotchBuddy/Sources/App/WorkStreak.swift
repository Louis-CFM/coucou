import Foundation

/// How long you have been working with your agents without a break, so Mochi gets sleepy after
/// a long stretch (heavy eyes, the odd yawn while he waits) and fresh again after a break.
///
/// Only timestamps of the agents' hook events are kept, in memory: no timer runs, nothing is
/// saved. A break is twenty minutes with no agent activity, or away from the keyboard and mouse.
struct WorkStreak {
    /// A pause at least this long is a break: the streak starts over.
    static let breakGap: TimeInterval = 20 * 60
    /// Mochi gets sleepy after this long…
    static let sleepyAfter: TimeInterval = 2 * 3600
    /// …and very sleepy after this long.
    static let verySleepyAfter: TimeInterval = 3 * 3600

    private(set) var start: Date?
    private(set) var last: Date?

    /// An agent did something. `userIdle`: seconds since the last keyboard or mouse event.
    mutating func activity(at now: Date, userIdle: TimeInterval) {
        if !isGoing(at: now, userIdle: userIdle) { start = now }
        last = now
    }

    /// How sleepy Mochi is, from 0 (fresh) to 1, as MochiMood.tired.
    mutating func tiredness(at now: Date, userIdle: TimeInterval) -> Double {
        guard isGoing(at: now, userIdle: userIdle), let start else {
            start = nil
            last = nil
            return 0
        }
        let worked = now.timeIntervalSince(start)
        if worked >= Self.verySleepyAfter { return 1 }
        if worked >= Self.sleepyAfter { return 0.7 }
        return 0
    }

    private func isGoing(at now: Date, userIdle: TimeInterval) -> Bool {
        guard start != nil, let last else { return false }
        return now.timeIntervalSince(last) < Self.breakGap && userIdle < Self.breakGap
    }
}
