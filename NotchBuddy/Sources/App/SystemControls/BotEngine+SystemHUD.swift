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

    /// How long the level's face stays after a press: the card's time on screen, plus its closing.
    static let faceDuration: Double = 2.0
}

extension BotEngine {
    /// A volume or brightness key, in Mochi's own moves: a little hop up when the level
    /// rises, a squash when it falls (the same tweens as his greeting and his landings),
    /// and the face of the level (SystemHUDLogic.mood): asleep at 0, tired, himself, happy,
    /// starry at 100 %, eyes shut when muted. Everything goes back to normal by itself.
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

        // The level's face, held while the card is up and renewed at each press.
        let eye: EyeShape?
        switch reaction.mood {
        case .empty:  eye = .closed
        case .low:    eye = .tired
        case .normal: eye = nil
        case .high:   eye = .happy
        case .max:    eye = .star
        case .muted:  eye = .closed
        }
        if let eye {
            eyeOverride = eye
            eyeOverrideUntil = CACurrentMediaTime() + SystemHUDReaction.faceDuration
        } else if eyeOverrideUntil > CACurrentMediaTime(),
                  let current = eyeOverride, [.closed, .tired, .happy, .star].contains(current) {
            // Back in the middle band: his own eyes again, at once.
            eyeOverrideUntil = 0
        }
        if reaction.mood == .max && reaction.direction > 0 { emit(.spark, count: 4) }
        if reaction.mood == .empty || reaction.mood == .muted { emit(.z, count: 1) }
    }
}
#endif
