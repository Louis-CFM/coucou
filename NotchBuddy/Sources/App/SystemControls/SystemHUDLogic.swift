#if !APPSTORE
import Foundation

// System HUD — pure logic, no AppKit: decodes the Mac's media keys and decides what
// each press does. Kept free of AppKit so scripts/test-system-hud.sh can test it with swiftc.
// GitHub build only: the HUD relies on private frameworks the App Store refuses.

/// The media keys the system HUD handles (NX_KEYTYPE_* in IOKit/hidsystem/ev_keymap.h).
enum MediaKey: Int, CaseIterable, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    /// Keyboard backlight keys: only on Macs that still have them (before 2021).
    case illuminationUp = 21
    case illuminationDown = 22
}

/// One media key event, decoded from an NSSystemDefined event's data1.
struct MediaKeyPress: Equatable, Sendable {
    let key: MediaKey
    let isDown: Bool
    let isRepeat: Bool
}

/// What the HUD controls.
enum SystemHUDTarget: String, Sendable {
    case volume, display, keyboard
}

/// What a key press asks for.
enum SystemHUDAction: Equatable, Sendable {
    /// One step up (+1) or down (-1); `fine` is a quarter step (⇧⌥, like macOS).
    case step(SystemHUDTarget, direction: Int, fine: Bool)
    case toggleMute

    var target: SystemHUDTarget {
        switch self {
        case .step(let target, _, _): return target
        case .toggleMute: return .volume
        }
    }
}

enum SystemHUDLogic {
    /// NSEvent.subtype of media key events (NX_SUBTYPE_AUX_CONTROL_BUTTONS).
    static let auxControlButtonsSubtype = 8
    /// macOS moves volume and brightness in 16 steps, 64 with ⇧⌥.
    static let coarseSteps = 16.0
    static let fineSteps = 64.0

    /// Decodes data1 of a media key event: key code in the high 16 bits, then the
    /// key state (0x0A down, 0x0B up) and a repeat bit in the low 16 bits.
    static func decode(data1: Int) -> MediaKeyPress? {
        let code = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        let state = (flags & 0xFF00) >> 8
        guard let key = MediaKey(rawValue: code), state == 0x0A || state == 0x0B else { return nil }
        return MediaKeyPress(key: key, isDown: state == 0x0A, isRepeat: (flags & 0x1) != 0)
    }

    /// The action for a press, or nil when the HUD leaves it to macOS.
    /// - Volume keys: the volume; ⇧⌥ for quarter steps.
    /// - Brightness keys: the screen; ⌥ alone moves the keyboard backlight instead
    ///   (MacBooks since 2021 have no backlight keys); ⇧⌥ for quarter steps of the screen.
    /// - Backlight keys (older Macs): the keyboard; ⇧⌥ for quarter steps.
    /// Only key-down acts (held keys repeat); mute ignores repeats so it doesn't flicker.
    static func action(for press: MediaKeyPress, option: Bool, shift: Bool) -> SystemHUDAction? {
        guard press.isDown else { return nil }
        let fine = option && shift
        switch press.key {
        case .soundUp:   return .step(.volume, direction: 1, fine: fine)
        case .soundDown: return .step(.volume, direction: -1, fine: fine)
        case .mute:      return press.isRepeat ? nil : .toggleMute
        case .brightnessUp, .brightnessDown:
            let direction = press.key == .brightnessUp ? 1 : -1
            if option && !shift { return .step(.keyboard, direction: direction, fine: false) }
            return .step(.display, direction: direction, fine: fine)
        case .illuminationUp:   return .step(.keyboard, direction: 1, fine: fine)
        case .illuminationDown: return .step(.keyboard, direction: -1, fine: fine)
        }
    }

    /// The level one step away from `value` (0…1), snapped to the step grid like macOS,
    /// so 0.53 + one step is 9/16, not 0.5925.
    static func stepped(_ value: Double, direction: Int, fine: Bool) -> Double {
        let steps = fine ? fineSteps : coarseSteps
        let current = value.isFinite ? min(max(value, 0), 1) : 0
        let index = (current * steps).rounded() + Double(direction.signum())
        return min(max(index / steps, 0), 1)
    }

    /// A volume key, like macOS: one step, and any step that leaves some sound unmutes.
    static func volumeStep(level: Double, muted: Bool, direction: Int, fine: Bool) -> (level: Double, muted: Bool) {
        let next = stepped(level, direction: direction, fine: fine)
        return (next, next > 0 ? false : muted)
    }

    /// The level as the card writes it: whole percent, 0 when muted.
    static func percent(level: Double, muted: Bool) -> Int {
        muted ? 0 : Int((min(max(level, 0), 1) * 100).rounded())
    }

    /// The volume sound's playback rate: low at the bottom, high at the top (0.8 at 0, 1.4 at
    /// 100 %), so the sound says the level. Rate changes pitch and length together; 0.8…1.4
    /// keeps the sound short and inside AVAudioPlayer's 0.5…2 range.
    static func soundRate(level: Double) -> Double {
        let value = level.isFinite ? min(max(level, 0), 1) : 0
        return 0.8 + 0.6 * value
    }

    /// How Mochi looks at the level, in five bands plus mute: asleep at 0, tired up to 30 %,
    /// himself in the middle, happy from 70 %, starry at 100 %, eyes shut when muted.
    static func mood(level: Double, muted: Bool) -> SystemHUDMood {
        if muted { return .muted }
        let value = level.isFinite ? level : 0
        if value <= 0 { return .empty }
        if value >= 1 { return .max }
        if value <= 0.3 { return .low }
        if value >= 0.7 { return .high }
        return .normal
    }
}

enum SystemHUDMood: Equatable, Sendable {
    case empty, low, normal, high, max, muted
}
#endif
