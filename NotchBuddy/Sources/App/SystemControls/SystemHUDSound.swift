#if !APPSTORE
import AVFoundation
import QuartzCore

/// The sound of a volume key: one of Coucou's own sounds ("pop" by default, "tick" or
/// "blip"), higher as the volume rises.
///
/// Swallowing the key also swallowed the "pop" macOS plays when the volume changes (System
/// Settings → Sound → Play feedback when volume is changed), so this gives it back, in
/// Coucou's voice. On by default when that macOS setting is on; its own switch and the choice
/// of sound in Settings → Volume & brightness. Silent while Coucou's sounds are off (the
/// header's speaker), when muted or at 0.
///
/// Its own small pool of players rather than SoundEngine's: the pitch follows the level,
/// which needs players made with `enableRate` (SoundEngine's are shared with every other sound).
@MainActor
final class SystemHUDSound {
    static let shared = SystemHUDSound()

    /// The Coucou sounds that fit a volume step: short and dry.
    enum Choice: String, CaseIterable, Identifiable {
        /// The nearest to macOS's own volume pop.
        case pop
        case tick
        case blip
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    static let enabledKey = "systemHUD.sound"
    static let choiceKey = "systemHUD.soundName"
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

    static var choice: Choice {
        UserDefaults.standard.string(forKey: choiceKey).flatMap(Choice.init(rawValue:)) ?? .pop
    }

    private var pool: [AVAudioPlayer] = []
    /// The sound the pool was loaded with: another choice reloads it.
    private var loaded: Choice?
    private var lastPlay: CFTimeInterval = 0

    private init() {}

    /// From Settings: keeps the choice and plays it once, at the middle pitch, to hear it.
    func choose(_ choice: Choice) {
        UserDefaults.standard.set(choice.rawValue, forKey: Self.choiceKey)
        play(level: 0.5)
    }

    /// After a volume step: the sound at the new volume, its pitch from the level.
    func playVolumeStep(level: Double, muted: Bool) {
        guard Self.isEnabled, !muted, level > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastPlay >= Self.minInterval else { return }
        lastPlay = now
        play(level: level)
    }

    private func play(level: Double) {
        guard AppState.shared.soundEnabled else { return }
        let choice = Self.choice
        if loaded != choice { load(choice) }
        guard let player = pool.first(where: { !$0.isPlaying }) ?? pool.first else { return }
        player.currentTime = 0
        player.rate = Float(SystemHUDLogic.soundRate(level: level))
        player.volume = SoundEngine.shared.volume
        player.play()
    }

    /// The user's own file from the custom sounds folder if there is one, like every other
    /// Coucou sound, else the built-in one. Loaded at the first press, and again only when
    /// another sound is chosen.
    private func load(_ choice: Choice) {
        pool.removeAll()
        loaded = choice
        let name = choice.rawValue
        let url = SoundEngine.customURL(for: name)
            ?? Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds")
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
