import Foundation

/// The key logic of Flow dictation, with nothing from AppKit in it (tests/FlowKeyLogicTests.swift).
///
/// - Hold the key: Coucou listens. Release it: the words are pasted where you type.
/// - Two quick taps: hands-free, until the next tap.
/// - Esc, or another key pressed while the key is held (a shortcut such as ⌥E), cancels.
///
/// Listening starts on the first press, so a word said right away is not lost; a press too short
/// to be a hold waits a moment for the second tap, and is dropped if none comes.
struct FlowKeyLogic: Equatable {
    enum Phase: Equatable {
        case idle
        case holding(since: Double)
        case tapWait(until: Double)
        case locked
    }

    enum Action: Equatable {
        case none
        /// Open the microphone and show the pill.
        case start
        /// Hands-free: keep listening after the key is released.
        case lock
        /// Stop listening and paste what was said.
        case finish
        /// Stop listening and paste nothing.
        case cancel
        /// The last listen was dropped (too short) and a new one begins.
        case restart
    }

    /// A press shorter than this is a tap.
    static let holdThreshold = 0.30
    /// The second tap of a double tap comes within this.
    static let doubleTapWindow = 0.40

    private(set) var phase: Phase = .idle

    var isActive: Bool { phase != .idle }

    mutating func keyDown(at t: Double) -> Action {
        switch phase {
        case .idle:
            phase = .holding(since: t)
            return .start
        case .holding:
            return .none                      // key repeat
        case .tapWait(let until):
            if t <= until { phase = .locked; return .lock }
            phase = .holding(since: t)        // the wait ran out unnoticed: start afresh
            return .restart
        case .locked:
            phase = .idle
            return .finish
        }
    }

    mutating func keyUp(at t: Double) -> Action {
        guard case .holding(let since) = phase else { return .none }
        if t - since >= Self.holdThreshold {
            phase = .idle
            return .finish
        }
        phase = .tapWait(until: t + Self.doubleTapWindow)
        return .none
    }

    /// Another key while the key is held, or between the two taps: it was a shortcut, not dictation.
    mutating func otherKey() -> Action {
        switch phase {
        case .holding, .tapWait:
            phase = .idle
            return .cancel
        case .idle, .locked:
            return .none
        }
    }

    mutating func escape() -> Action {
        guard phase != .idle else { return .none }
        phase = .idle
        return .cancel
    }

    /// Called when the double-tap window may have run out.
    mutating func tick(at t: Double) -> Action {
        guard case .tapWait(let until) = phase, t > until else { return .none }
        phase = .idle
        return .cancel
    }

    /// Hands-free straight away (the pill's microphone button).
    mutating func lock() { phase = .locked }

    /// The listen ended on its own (no microphone, nothing heard…).
    mutating func reset() { phase = .idle }
}

/// Frequency bands for the pill's dots: graves on the left, aigus on the right.
enum FlowBands {
    static let count = 9
    static let lowHz: Double = 90
    static let highHz: Double = 7000

    /// The `count + 1` band edges in Hz, spaced evenly on a log scale.
    static func edges(count: Int = count, low: Double = lowHz, high: Double = highHz) -> [Double] {
        (0...count).map { low * pow(high / low, Double($0) / Double(count)) }
    }

    /// The FFT bins [from, to) of each band, for `fftSize` samples at `sampleRate`. Each band has at least one bin.
    static func binRanges(fftSize: Int, sampleRate: Double, count: Int = count) -> [Range<Int>] {
        let binHz = sampleRate / Double(fftSize)
        let maxBin = fftSize / 2
        let e = edges(count: count)
        var out: [Range<Int>] = []
        var last = 1
        for i in 0..<count {
            let from = max(last, Int((e[i] / binHz).rounded(.down)))
            let to = min(maxBin, max(from + 1, Int((e[i + 1] / binHz).rounded(.up))))
            out.append(from..<to)
            last = to
        }
        return out
    }

    /// A band's power in dB → 0…1 for the dot's height: silence stays low, a normal voice fills it.
    static func level(db: Double, floor: Double = -78, ceiling: Double = -30) -> Double {
        min(1, max(0, (db - floor) / (ceiling - floor)))
    }
}
