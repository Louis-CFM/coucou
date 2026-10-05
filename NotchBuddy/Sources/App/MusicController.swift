#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Music player

/// A music app Coucou can follow. Both post a distributed notification with the same
/// userInfo keys ("Player State", "Name", "Artist", "Album") and speak AppleScript.
enum MusicPlayer: String {
    case appleMusic
    case spotify

    var bundleId: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify:    return "com.spotify.client"
        }
    }

    var name: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .spotify:    return "Spotify"
        }
    }

    var notificationName: NSNotification.Name {
        switch self {
        case .appleMusic: return NSNotification.Name("com.apple.Music.playerInfo")
        case .spotify:    return NSNotification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var previousTrackCommand: String {
        switch self {
        case .appleMusic: return "back track"
        case .spotify:    return "previous track"
        }
    }

    /// Automation is granted per target app, so each player keeps its own flag.
    var automationGrantedKey: String {
        switch self {
        case .appleMusic: return "coucou.musicAutomationGranted"
        case .spotify:    return "coucou.spotifyAutomationGranted"
        }
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    var automationGranted: Bool {
        UserDefaults.standard.bool(forKey: automationGrantedKey)
    }

    static func from(bundleId: String?) -> MusicPlayer? {
        [MusicPlayer.appleMusic, .spotify].first { $0.bundleId == bundleId }
    }
}

// MARK: - Music Controller

/// Follows whichever of Apple Music or Spotify last started playing, and provides
/// playback controls for it. Singleton, @MainActor, GitHub build only.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published var trackTitle: String?
    @Published var artist: String?
    @Published var album: String?
    @Published private(set) var player: MusicPlayer {
        didSet { UserDefaults.standard.set(player.rawValue, forKey: "coucou.musicPlayer") }
    }

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.music")

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains("integration_music")
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "coucou.musicPlayer").flatMap(MusicPlayer.init(rawValue:))
        player = saved ?? (MusicPlayer.spotify.isRunning && !MusicPlayer.appleMusic.isRunning ? .spotify : .appleMusic)

        // Each player posts on play/pause/track change.
        // Extract Sendable String? values before crossing into @MainActor.
        for source in [MusicPlayer.appleMusic, .spotify] {
            let tok = DistributedNotificationCenter.default().addObserver(
                forName: source.notificationName,
                object: nil,
                queue: .main
            ) { [weak self] notif in
                let info        = notif.userInfo
                let playerState = info?["Player State"] as? String
                let name        = info?["Name"]          as? String
                let artist      = info?["Artist"]        as? String
                let album       = info?["Album"]         as? String
                Task { @MainActor [weak self] in
                    self?.handlePlayerInfo(from: source, playerState: playerState, name: name, artist: artist, album: album)
                }
            }
            notifTokens.append(tok)
        }

        // Track player launch — read current state only if granted and pill active
        let tok2 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, MusicPlayer.from(bundleId: bundleId) == self.player else { return }
                guard self.isPillActive, self.player.automationGranted else { return }
                self.fetchAndApply()
            }
        }
        notifTokens.append(tok2)

        // Clear state when the followed player quits
        let tok3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor [weak self] in
                guard let self, MusicPlayer.from(bundleId: bundleId) == self.player else { return }
                self.clearState()
            }
        }
        notifTokens.append(tok3)

        // Observe activeIntegrations — pill activated → initial read; deactivated → clear
        AppState.shared.$activeIntegrations
            .sink { [weak self] integrations in
                guard let self else { return }
                if integrations.contains("integration_music") {
                    self.syncTaskName()
                    if self.player.isRunning, self.player.automationGranted {
                        self.fetchAndApply()
                    }
                } else {
                    self.clearState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Metadata cleaners

    private static func shortTitle(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        // Cut at first " - "
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
        // Strip trailing (...) or [...] groups repeatedly
        var changed = true
        while changed {
            changed = false
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let last = t.last, (last == ")" || last == "]") else { break }
            let open: Character = last == ")" ? "(" : "["
            if let idx = t.lastIndex(of: open) {
                let candidate = String(t[..<idx]).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { s = candidate; changed = true }
            } else { break }
        }
        let result = s.trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? raw : result
    }

    private static func shortArtist(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let lower = raw.lowercased()
        for tag in [" feat.", " ft."] {
            if let r = lower.range(of: tag) {
                let result = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                return result.isEmpty ? raw : result
            }
        }
        return raw
    }

    private func handlePlayerInfo(from source: MusicPlayer, playerState: String?, name: String?, artist inputArtist: String?, album inputAlbum: String?) {
        guard isPillActive else { return }

        let playing = playerState == "Playing"
        // Follow whichever app starts playing; ignore the other one pausing in the background.
        if source != player {
            guard playing else { return }
            player = source
            AppState.shared.musicAutomationDenied = false   // the denial was for the other app
        }
        let wasPlaying = AppState.shared.musicPlaying

        trackTitle = name.map { Self.shortTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        artist     = inputArtist.map { Self.shortArtist($0) }.flatMap { $0.isEmpty ? nil : $0 }
        album      = inputAlbum

        AppState.shared.musicPlaying = playing
        syncTaskName()

        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func fetchAndApply() {
        let target = player
        Task {
            let result = await runAppleScript("""
                tell application id "\(target.bundleId)"
                    set ps to player state as string
                    if ps is "stopped" then return {ps, "", "", ""}
                    try
                        set tr to current track
                        set n to name of tr
                    on error
                        return {ps, "", "", ""}
                    end try
                    set ar to ""
                    set al to ""
                    try
                        set ar to artist of tr
                    end try
                    try
                        set al to album of tr
                    end try
                    return {ps, n, ar, al}
                end tell
            """, for: target)
            guard case .success(let values) = result, values.count >= 4, target == player else { return }
            let playing    = values[0] == "playing"
            let wasPlaying = AppState.shared.musicPlaying
            trackTitle = values[1].isEmpty ? nil : Self.shortTitle(values[1])
            artist     = values[2].isEmpty ? nil : Self.shortArtist(values[2])
            album      = values[3].isEmpty ? nil : values[3]
            AppState.shared.musicPlaying = playing
            syncTaskName()
            if playing && !wasPlaying {
                NotificationCenter.default.post(name: .musicReveal, object: nil)
            }
        }
    }

    private func clearState() {
        trackTitle = nil; artist = nil; album = nil
        AppState.shared.musicPlaying = false
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == "integration_music" }) else { return }
        let title = trackTitle ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty ? player.name : title
    }

    // MARK: - Playback controls

    func playPause() {
        sendCommand("playpause")
    }

    func nextTrack() {
        sendCommand("next track")
    }

    func previousTrack() {
        sendCommand(player.previousTrackCommand)
    }

    private func sendCommand(_ command: String) {
        let target = player
        guard target.isRunning else { return }
        Task { await runAppleScript(#"tell application id "\#(target.bundleId)" to \#(command)"#, for: target) }
    }

    func openMusic() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == player.bundleId }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - AppleScript runner

    enum ScriptResult { case success([String]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String, for target: MusicPlayer) async -> ScriptResult {
        let grantedKey = target.automationGrantedKey
        return await withCheckedContinuation { cont in
            queue.async {
                let script = NSAppleScript(source: source)!
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == -1743 {
                        Task { @MainActor in
                            AppState.shared.musicAutomationDenied = true
                            UserDefaults.standard.set(false, forKey: grantedKey)
                        }
                        cont.resume(returning: .denied)
                    } else {
                        cont.resume(returning: .error)
                    }
                    return
                }
                Task { @MainActor in
                    UserDefaults.standard.set(true, forKey: grantedKey)
                    AppState.shared.musicAutomationDenied = false
                }
                // Extract values on this queue before resuming (avoids NSAppleEventDescriptor Sendable issues)
                var values: [String] = []
                let count = desc.numberOfItems
                if count > 0 {
                    for i in 1...count {
                        values.append(desc.atIndex(i)?.stringValue ?? "")
                    }
                } else {
                    values = [desc.stringValue ?? ""]
                }
                cont.resume(returning: .success(values))
            }
        }
    }
}
#endif
