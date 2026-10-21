import AppKit

/// Plays a handful of macOS system sounds for the events that matter (approval, question,
/// finish, error). Every other cue is silent. No sound ships with the app; a file named like a
/// cue (e.g. approval.wav) in the custom folder overrides the system sound.
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled: Bool = true
    var volume: Float = 0.12 {
        didSet { sounds.values.forEach { $0.volume = volume } }
    }

    private var sounds: [String: NSSound] = [:]

    private init() {
        preload()
    }

    /// Cue name → macOS system sound name. Cues missing from this table stay silent.
    private static let systemSounds: [String: String] = [
        "approval": "Ping",
        "question": "Pop",
        "finish": "Glass",
        "error": "Basso",
        "approve": "Tink",
    ]

    static let soundNames = Array(systemSounds.keys).sorted()

    /// Your own sounds: a file named like a cue (e.g. finish.wav, approval.mp3) in this folder
    /// replaces the system sound. ~/Library/Application Support/OrcaNotch/Sounds
    static var customFolder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OrcaNotch/Sounds", isDirectory: true)
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

    /// Names of the cues currently replaced by a custom file.
    private(set) var customized: [String] = []

    private func preload() {
        var loaded: [String: NSSound] = [:]
        var custom: [String] = []
        for (name, systemName) in Self.systemSounds {
            if let url = Self.customURL(for: name), let sound = NSSound(contentsOf: url, byReference: false) {
                loaded[name] = sound
                custom.append(name)
            } else if let sound = NSSound(named: NSSound.Name(systemName)) {
                loaded[name] = sound
            }
        }
        loaded.values.forEach { $0.volume = volume }
        sounds = loaded
        customized = custom.sorted()
    }

    /// Re-reads the sounds (after the user changed the custom folder).
    func reload() { preload() }

    /// Creates the custom folder if needed and shows it in the Finder.
    func revealCustomFolder() {
        guard let dir = Self.customFolder else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Stops `name`; system sounds are short, so there is nothing to fade.
    func fadeOut(_ name: String, duration: TimeInterval) {
        sounds[name]?.stop()
    }

    func play(_ name: String) {
        guard enabled && AppState.shared.soundEnabled else { return }
        guard let sound = sounds[name] else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }
}
