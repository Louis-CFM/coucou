import Foundation

/// The key logic of Flow dictation, with nothing from AppKit in it (tests/FlowKeyLogicTests.swift).
///
/// - Hold the key: Coucou listens. Release it: the words are pasted where you type.
/// - Two quick taps: hands-free, until the next tap.
///   With `oneTap` (a Flow setting), one short press is enough.
/// - Esc, or another key pressed while the key is held (a shortcut such as ⌥E), cancels.
///
/// Listening starts on the first press, so a word said right away is not lost; a press too short
/// to be a hold waits a moment for the second tap (without `oneTap`), and is dropped if none comes.
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
    var oneTap = false

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
        if oneTap { phase = .locked; return .lock }
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

/// A custom shortcut held like one key (tests/FlowKeyLogicTests.swift): one to six keys, by their
/// virtual key codes. It goes down once all its keys are held and no other, and up as soon as one
/// of them is released.
struct FlowChord: Equatable {
    static let maxKeys = 6

    enum Edge: Equatable { case none, down, up }

    let keys: Set<UInt16>
    private(set) var held: Set<UInt16> = []
    private(set) var isDown = false

    init(keys: Set<UInt16>) { self.keys = keys }

    mutating func press(_ code: UInt16) -> Edge {
        held.insert(code)
        guard !isDown, !keys.isEmpty, held == keys else { return .none }
        isDown = true
        return .down
    }

    mutating func release(_ code: UInt16) -> Edge {
        guard held.remove(code) != nil else { return .none }
        guard isDown, keys.contains(code) else { return .none }
        isDown = false
        return .up
    }

    /// Keys that are no longer down although their release never came (a password field hides
    /// the keys from Coucou): forgotten, and the chord goes up if one of them was in it.
    mutating func forget(where gone: (UInt16) -> Bool) -> Edge {
        let lost = held.filter(gone)
        guard !lost.isEmpty else { return .none }
        held.subtract(lost)
        guard isDown, !lost.isDisjoint(with: keys) else { return .none }
        isDown = false
        return .up
    }

    /// Whether the press of this key (one that types, not a modifier) belongs to the shortcut and
    /// must not reach the app in front: the chord is held, or the key comes on top of the
    /// shortcut's own modifiers. Plain typing (no modifier of the shortcut held) always goes through.
    func swallows(_ code: UInt16) -> Bool {
        guard keys.contains(code) else { return false }
        if isDown { return true }
        let next = held.union([code])
        guard next.isSubset(of: keys) else { return false }
        if next == keys { return true }
        return !held.isDisjoint(with: FlowShortcutRules.realModifiers)
    }

    mutating func reset() {
        held = []
        isDown = false
    }
}

/// What a custom shortcut may be, and the modifier keys in the events' flags.
enum FlowShortcutRules {
    /// ⌘ ⇧ ⌥ ⌃ on the left, then on the right, and fn.
    static let leftModifiers: Set<UInt16> = [55, 56, 58, 59]
    static let rightModifiers: Set<UInt16> = [54, 60, 61, 62]
    static let fn: UInt16 = 63
    static let modifiers: Set<UInt16> = leftModifiers.union(rightModifiers).union([fn])
    static let shifts: Set<UInt16> = [56, 60]
    /// The modifiers that keep a key from typing (⇧ only makes it a capital).
    static let realModifiers: Set<UInt16> = modifiers.subtracting(shifts)
    /// F1…F20 and the keys that never type: alone, they make a fine shortcut.
    static let silentKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                          105, 107, 113, 106, 64, 79, 80, 90,
                                          114, 115, 119, 116, 121]
    /// Esc cancels (a dictation, the recording), ↩ saves the recording, Caps Lock stays on once pressed.
    static let forbidden: Set<UInt16> = [53, 57, 36, 76]

    enum Problem: Equatable { case tooMany, forbiddenKey, needsModifier, tooCommon }

    static func problem(_ keys: Set<UInt16>) -> Problem? {
        if keys.count > FlowChord.maxKeys { return .tooMany }
        if !keys.isDisjoint(with: forbidden) { return .forbiddenKey }
        let typing = keys.subtracting(modifiers).subtracting(silentKeys)
        if !typing.isEmpty, keys.isDisjoint(with: realModifiers) { return .needsModifier }
        if keys.count == 1, let only = keys.first, leftModifiers.contains(only) { return .tooCommon }
        return nil
    }

    /// The device-dependent bit of a modifier key in an event's flags (fn: the function flag).
    static func modifierBit(_ code: UInt16) -> UInt64? {
        switch code {
        case 59: return 0x0000_0001   // left ⌃
        case 56: return 0x0000_0002   // left ⇧
        case 60: return 0x0000_0004   // right ⇧
        case 55: return 0x0000_0008   // left ⌘
        case 54: return 0x0000_0010   // right ⌘
        case 58: return 0x0000_0020   // left ⌥
        case 61: return 0x0000_0040   // right ⌥
        case 62: return 0x0000_2000   // right ⌃
        case 63: return 0x0080_0000   // fn
        default: return nil
        }
    }
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
