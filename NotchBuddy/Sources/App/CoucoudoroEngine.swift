import Foundation

// MARK: - Coucoudoro clock

/// Work and rest lengths, in seconds. A phase runs until its deadline, then the next one starts.
struct CoucoudoroConfig: Equatable, Sendable {
    var work: TimeInterval
    var rest: TimeInterval
}

enum CoucoudoroPhase: Equatable, Sendable {
    case idle, work, rest
}

/// The moment a phase begins.
enum CoucoudoroEvent: Equatable, Sendable {
    case restStarts, workStarts
}

/// The session, anchored to a deadline so a late tick does not drift.
struct CoucoudoroSnapshot: Equatable, Sendable {
    var phase: CoucoudoroPhase
    var paused: Bool
    var deadline: Date?
    /// Seconds left, frozen while paused. The deadline is cleared until resume.
    var pausedRemaining: TimeInterval?
    var notice: CoucoudoroEvent?

    static let idle = CoucoudoroSnapshot(phase: .idle, paused: false, deadline: nil,
                                    pausedRemaining: nil, notice: nil)
}

/// The countdown. Pure: no clock of its own, no pill, no defaults.
enum CoucoudoroEngine {
    /// Lengths under a second are pulled up to one second.
    static func sanitize(_ raw: CoucoudoroConfig) -> CoucoudoroConfig {
        CoucoudoroConfig(work: max(raw.work, 1),
                    rest: max(raw.rest, 1))
    }

    /// A fresh work phase, from the full work length, whatever came before.
    static func start(config raw: CoucoudoroConfig, now: Date) -> (CoucoudoroSnapshot, [CoucoudoroEvent]) {
        let config = sanitize(raw)
        let deadline = now.addingTimeInterval(config.work)
        let snap = CoucoudoroSnapshot(phase: .work, paused: false,
                                 deadline: deadline,
                                 pausedRemaining: nil, notice: .workStarts)
        return (snap, [.workStarts])
    }

    static func stop() -> CoucoudoroSnapshot { .idle }

    static func pause(_ s: CoucoudoroSnapshot, now: Date) -> CoucoudoroSnapshot {
        guard s.phase != .idle, !s.paused else { return s }
        var n = s
        n.paused = true
        n.pausedRemaining = max(0, s.deadline?.timeIntervalSince(now) ?? 0)
        n.deadline = nil
        return n
    }

    static func resume(_ s: CoucoudoroSnapshot, now: Date) -> CoucoudoroSnapshot {
        guard s.paused else { return s }
        var n = s
        let left = max(0, s.pausedRemaining ?? 0)
        n.paused = false
        n.pausedRemaining = nil
        n.deadline = now.addingTimeInterval(left)
        return n
    }

    /// Move the session to `now`. A phase runs until its deadline, then the next one
    /// starts and is announced once. If the Mac slept, missed phases are not replayed:
    /// only the phase that contains `now`.
    static func tick(_ s: CoucoudoroSnapshot, config raw: CoucoudoroConfig, now: Date) -> (CoucoudoroSnapshot, [CoucoudoroEvent]) {
        guard s.phase != .idle, !s.paused, let deadline = s.deadline else { return (s, []) }
        guard now >= deadline else { return (s, []) }
        let config = sanitize(raw)
        let landed = land(from: s.phase, phaseEnd: deadline, now: now, config: config)
        var n = s
        n.phase = landed.phase
        n.deadline = landed.deadline
        n.notice = landed.event
        return (n, [landed.event])
    }

    static func remaining(_ s: CoucoudoroSnapshot, now: Date) -> TimeInterval? {
        if s.paused { return s.pausedRemaining }
        guard s.phase != .idle, let deadline = s.deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// "25:00". Minutes grow past 99 without a leading zero.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        let m = whole / 60
        let s = whole % 60
        if m >= 100 { return String(format: "%d:%02d", m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Phases

    /// From a phase that ended at `phaseEnd`, the phase that contains `now`.
    /// The next deadline stays on the original schedule (`phaseEnd` plus whole lengths),
    /// not `now` plus a length, so a late tick does not stretch the session.
    private static func land(from phase: CoucoudoroPhase, phaseEnd: Date, now: Date,
                             config: CoucoudoroConfig) -> (phase: CoucoudoroPhase, deadline: Date, event: CoucoudoroEvent) {
        let work = max(1, Int(config.work.rounded()))
        let rest = max(1, Int(config.rest.rounded()))
        switch phase {
        case .work:
            let restEnd = phaseEnd.addingTimeInterval(TimeInterval(rest))
            if now < restEnd { return (.rest, restEnd, .restStarts) }
            let over = seconds(now.timeIntervalSince(restEnd))
            let cycle = work + rest
            let cycles = over / cycle
            let into = over % cycle
            let origin = restEnd.addingTimeInterval(TimeInterval(cycles * cycle))
            if into < work {
                return (.work, origin.addingTimeInterval(TimeInterval(work)), .workStarts)
            }
            return (.rest, origin.addingTimeInterval(TimeInterval(work + rest)), .restStarts)
        case .rest:
            let workEnd = phaseEnd.addingTimeInterval(TimeInterval(work))
            if now < workEnd { return (.work, workEnd, .workStarts) }
            let over = seconds(now.timeIntervalSince(workEnd))
            let cycle = work + rest
            let cycles = over / cycle
            let into = over % cycle
            let origin = workEnd.addingTimeInterval(TimeInterval(cycles * cycle))
            // After that work, the cycle is rest then work.
            if into < rest {
                return (.rest, origin.addingTimeInterval(TimeInterval(rest)), .restStarts)
            }
            return (.work, origin.addingTimeInterval(TimeInterval(rest + work)), .workStarts)
        case .idle:
            return (.work, phaseEnd.addingTimeInterval(TimeInterval(work)), .workStarts)
        }
    }

    private static func seconds(_ interval: TimeInterval) -> Int {
        max(0, Int(interval.rounded(.down)))
    }
}

// MARK: - Stored lengths

/// Minutes in UserDefaults, the same store as the other integration settings.
enum CoucoudoroSettings {
    static let pillId = "integration_coucoudoro"

    static let workKey = "coucoudoroWorkMinutes"
    static let restKey = "coucoudoroRestMinutes"

    static let defaultWork = 25
    static let defaultRest = 5

    /// Work and rest are each 1…60 minutes. A saved value outside that clamps here.
    static let workBounds = 1...60
    static let restBounds = 1...60

    static func clampWork(_ minutes: Int) -> Int {
        min(max(minutes, workBounds.lowerBound), workBounds.upperBound)
    }

    static func clampRest(_ minutes: Int) -> Int {
        min(max(minutes, restBounds.lowerBound), restBounds.upperBound)
    }

    static var workMinutes: Int { clampWork(storedMinutes(workKey, fallback: defaultWork)) }
    static var restMinutes: Int { clampRest(storedMinutes(restKey, fallback: defaultRest)) }

    static var config: CoucoudoroConfig {
        CoucoudoroConfig(work: TimeInterval(workMinutes * 60),
                    rest: TimeInterval(restMinutes * 60))
    }

    /// A saved length, or the default when none was saved.
    private static func storedMinutes(_ key: String, fallback: Int) -> Int {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }
}
