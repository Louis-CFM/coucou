import Foundation

// MARK: - WakeWindowBackoff
//
// Pure value-type backoff controller for wake-window reopening.
// No AppKit dependency — testable with standalone swiftc.
//
// Usage:
//   var backoff = WakeWindowBackoff()
//   switch backoff.windowEnded(elapsed: elapsed, wasError: wasError) {
//   case .open:       openWakeWindow()
//   case .delay(let d): schedule(openWakeWindow, after: d)
//   case .stop:       waitForNextVADSegment()
//   }
//   backoff.reset()  // call on new VAD segment or successful wake

struct WakeWindowBackoff {

    enum Action: Equatable {
        case open
        case delay(TimeInterval)
        case stop
    }

    // Tunables (kept in sync with scripts/test-voice-backoff.sh expectations)
    let fastThreshold: TimeInterval  // window lifetime < this → "fast fail"
    let maxFastFails:  Int           // max consecutive fast fails before .stop
    let base:          TimeInterval  // first backoff delay (streak = 1)
    let maxDelay:      TimeInterval  // cap

    private(set) var streak: Int = 0

    init(fastThreshold: TimeInterval = 1.0,
         maxFastFails:  Int          = 3,
         base:          TimeInterval = 0.5,
         maxDelay:      TimeInterval = 5.0) {
        self.fastThreshold = fastThreshold
        self.maxFastFails  = maxFastFails
        self.base          = base
        self.maxDelay      = maxDelay
    }

    /// Call when a wake window ends without detecting a wake word.
    /// `elapsed` = wall time since the window was opened.
    /// `wasError` = the session ended with an error (not a clean final result).
    mutating func windowEnded(elapsed: TimeInterval, wasError: Bool) -> Action {
        let fast = elapsed < fastThreshold
        guard fast else {
            // Normal-length window → reset streak, reopen immediately.
            streak = 0
            return .open
        }
        streak += 1
        guard streak < maxFastFails else {
            // Too many rapid failures this VAD segment.
            return .stop
        }
        let delay = min(base * pow(2.0, Double(streak - 1)), maxDelay)
        return .delay(delay)
    }

    /// Reset on new VAD segment or successful wake detection.
    mutating func reset() { streak = 0 }
}
