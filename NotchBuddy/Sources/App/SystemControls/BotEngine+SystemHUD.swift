#if !APPSTORE
import Foundation
import QuartzCore

extension Notification.Name {
    /// A volume or brightness key moved a level: Mochi in the island reacts (object: SystemHUDReaction).
    static let botSystemLevel = Notification.Name("notchBuddy.botSystemLevel")
}

/// What Mochi reacts to when a volume or brightness key is pressed.
struct SystemHUDReaction: Sendable {
    /// +1 up, -1 down, 0 for mute.
    let direction: Int
    let mood: SystemHUDMood
}

extension BotEngine {
    /// A volume or brightness key, in Mochi's own moves: a little hop up when the level
    /// rises, a squash when it falls (the same tweens as his greeting and his landings),
    /// and for a moment the eyes of the level: happy at the top, tired at the bottom,
    /// shut when muted. Everything goes back to normal by itself.
    func reactToSystemLevel(_ reaction: SystemHUDReaction) {
        if reaction.direction > 0 {
            anim("oy", keys: [
                TweenKey(target: -0.08, duration: 110, ease: Ease.out),
                TweenKey(target: 0,     duration: 220, ease: Ease.back),
            ])
            anim("sy", keys: [
                TweenKey(target: 1.08, duration: 90,  ease: Ease.out),
                TweenKey(target: 1,    duration: 240, ease: Ease.back),
            ])
            anim("sx", keys: [
                TweenKey(target: 0.94, duration: 90,  ease: Ease.out),
                TweenKey(target: 1,    duration: 240, ease: Ease.back),
            ])
        } else if reaction.direction < 0 {
            anim("oy", keys: [
                TweenKey(target: 0.04, duration: 90,  ease: Ease.out),
                TweenKey(target: 0,    duration: 220, ease: Ease.back),
            ])
            anim("sy", keys: [
                TweenKey(target: 0.86, duration: 80,  ease: Ease.out),
                TweenKey(target: 1,    duration: 260, ease: Ease.back),
            ])
            anim("sx", keys: [
                TweenKey(target: 1.10, duration: 80,  ease: Ease.out),
                TweenKey(target: 1,    duration: 260, ease: Ease.back),
            ])
        } else {
            blink()
        }

        let eye: EyeShape?
        switch reaction.mood {
        case .normal: eye = nil
        case .max:    eye = .happy
        case .min:    eye = .tired
        case .muted:  eye = .closed
        }
        if let eye {
            eyeOverride = eye
            eyeOverrideUntil = CACurrentMediaTime() + 1.4
        }
        if reaction.mood == .max && reaction.direction > 0 { emit(.spark, count: 3) }
        if reaction.mood == .muted { emit(.z, count: 1) }
    }
}
#endif
