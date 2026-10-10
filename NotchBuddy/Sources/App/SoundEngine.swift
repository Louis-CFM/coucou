import AVFoundation
import AppKit

/// Preloaded WAV players with near-zero latency.
/// Volume default 0.12 (matches prototype: gain ×6 then vol=0.12).
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled: Bool = true
    var volume: Float = 0.12 {
        didSet { players.values.forEach { $0.forEach { $0.volume = volume } } }
    }

    // Pool of 3 players per sound to allow overlapping playback
    private var players: [String: [AVAudioPlayer]] = [:]

    private init() {
        preload()
    }

    static let soundNames = ["peek","open","close","hover","blip","slap","annoyed","dizzy","greet",
                             "work","finish","error","approval","question","approve","gulp","tick",
                             "send","love","pop","proud","wink","yawn","attach","think","search",
                             "rate","sleep","greeting"]

    /// Your own sounds: a file named like a built-in sound (e.g. finish.wav, approval.mp3) in this
    /// folder replaces it. ~/Library/Application Support/NotchBuddy/Sounds (in the App Store build,
    /// the same path inside the app's container).
    static var customFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NotchBuddy/Sounds", isDirectory: true)
    }
    private static let customExtensions = ["wav", "aiff", "aif", "caf", "m4a", "mp3"]

    /// The custom file for a sound, if the user dropped one in the folder.
    static func customURL(for name: String) -> URL? {
        guard let dir = customFolder else { return nil }
        for ext in customExtensions {
            let url = dir.appendingPathComponent(name).appendingPathExtension(ext)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Names of the built-in sounds currently replaced by a custom file.
    private(set) var customized: [String] = []

    private func preload() {
        var pools: [String: [AVAudioPlayer]] = [:]
        var custom: [String] = []
        for name in Self.soundNames {
            let own = Self.customURL(for: name)
            // A custom file that can't be decoded falls back to the built-in sound.
            var pool = own.map { makePool($0) } ?? []
            if pool.isEmpty {
                guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") else { continue }
                pool = makePool(url)
            } else {
                custom.append(name)
            }
            if !pool.isEmpty { pools[name] = pool }
        }
        players = pools
        customized = custom
    }

    private func makePool(_ url: URL) -> [AVAudioPlayer] {
        var pool: [AVAudioPlayer] = []
        for _ in 0..<3 {
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.volume = volume
                p.prepareToPlay()
                pool.append(p)
            }
        }
        return pool
    }

    /// Re-reads the sounds (after the user changed the custom folder).
    func reload() { preload() }

    /// Creates the custom folder if needed and shows it in the Finder.
    func revealCustomFolder() {
        guard let dir = Self.customFolder else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Fade out all currently-playing instances of `name` over `duration` seconds,
    /// then stop and reset them so they can be reused.
    func fadeOut(_ name: String, duration: TimeInterval) {
        guard let pool = players[name] else { return }
        for player in pool where player.isPlaying {
            player.setVolume(0, fadeDuration: duration)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak player] in
                guard let p = player else { return }
                p.stop()
                p.currentTime = 0
                p.volume = self.volume
            }
        }
    }

    func play(_ name: String) {
        guard enabled && AppState.shared.soundEnabled else { return }
        guard let pool = players[name] else { return }
        // Find a player that is not currently playing
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        player.currentTime = 0
        player.volume = volume
        player.play()
    }
}
