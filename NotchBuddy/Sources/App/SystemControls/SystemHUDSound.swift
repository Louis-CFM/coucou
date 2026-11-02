#if !APPSTORE
import AVFoundation
import QuartzCore

/// The sound of a volume key: Coucou's "blip", higher as the volume rises.
///
/// Swallowing the key also swallowed the "pop" macOS plays when the volume changes (System
/// Settings → Sound → Play feedback when volume is changed), so this gives it back, in
/// Coucou's voice. On by default when that macOS setting is on; its own switch in Settings
/// → Volume & brightness. Silent while Coucou's sounds are off (the header's speaker), when
/// muted or at 0.
///
/// Its own small pool of players rather than SoundEngine's: the pitch follows the level,
/// which needs players made with `enableRate` (SoundEngine's are shared with every other sound).
@MainActor
final class SystemHUDSound {
    static let shared = SystemHUDSound()
    static let soundName = "blip"
    static let enabledKey = "systemHUD.sound"
    /// Coucou's sounds play very low (SoundEngine.volume, 0.12 by default): they sit in the
    /// background. This one is feedback, like macOS's pop, and it plays at the volume just
    /// chosen: five times louder, still following Coucou's Volume slider in proportion.
    private static let gain: Float = 5
    /// Held down, a key repeats quickly: at most one sound this often.
    private static let minInterval: CFTimeInterval = 0.07

    static var isEnabled: Bool {
        if let on = UserDefaults.standard.object(forKey: enabledKey) as? Bool { return on }
        // Not set yet: like macOS (the global "Play feedback when volume is changed").
        let macOSFeedback = UserDefaults.standard.object(forKey: "com.apple.sound.beep.feedback") as? Int
        return macOSFeedback == 1
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
    }

    private var pool: [AVAudioPlayer] = []
    private var lastPlay: CFTimeInterval = 0

    private init() {}

    /// After a volume step: the blip at the new volume, its pitch from the level.
    func playVolumeStep(level: Double, muted: Bool) {
        guard Self.isEnabled, AppState.shared.soundEnabled, !muted, level > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastPlay >= Self.minInterval else { return }
        lastPlay = now

        if pool.isEmpty { load() }
        guard let player = pool.first(where: { !$0.isPlaying }) ?? pool.first else { return }
        player.currentTime = 0
        player.rate = Float(SystemHUDLogic.soundRate(level: level))
        player.volume = min(1, SoundEngine.shared.volume * Self.gain)
        player.play()
    }

    /// The user's own blip from the custom sounds folder if there is one, like every other
    /// Coucou sound, else the built-in one. Loaded at the first press only.
    private func load() {
        let url = SoundEngine.customURL(for: Self.soundName)
            ?? Bundle.main.url(forResource: Self.soundName, withExtension: "wav", subdirectory: "sounds")
        guard let url else { return }
        for _ in 0..<3 {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.enableRate = true   // before prepareToPlay, or the rate is ignored
            player.prepareToPlay()
            pool.append(player)
        }
    }
}
#endif
