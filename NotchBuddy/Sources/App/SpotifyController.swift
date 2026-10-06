#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Spotify Controller

/// Observes Spotify state via distributed notifications and provides playback controls.
/// Singleton, @MainActor, GitHub build only. Mirrors MusicController.
@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()

    @Published var trackTitle: String?
    @Published var artist: String?
    @Published var album: String?
    /// Spotify sound volume, 0…100.
    @Published var volume: Int = 50
    @Published var isRunning: Bool = false

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.spotify")
    private let volumeStep = 10

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains("integration_spotify")
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil
            || FileManager.default.fileExists(atPath: "/Applications/Spotify.app")
    }

    private init() {
        // PlaybackStateChanged fires on play/pause/track change.
        let tok1 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let info        = notif.userInfo
            let playerState = info?["Player State"] as? String
            let name        = info?["Name"]          as? String
            let artist      = info?["Artist"]        as? String
            let album       = info?["Album"]         as? String
            Task { @MainActor [weak self] in
                self?.handlePlayerInfo(playerState: playerState, name: name, artist: artist, album: album)
            }
        }
        notifTokens.append(tok1)

        let tok2 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == "com.spotify.client" else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRunning = true
                guard self.isPillActive,
                      UserDefaults.standard.bool(forKey: "coucou.spotifyAutomationGranted") else { return }
                self.fetchAndApply()
            }
        }
        notifTokens.append(tok2)

        let tok3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == "com.spotify.client" else { return }
            Task { @MainActor [weak self] in self?.clearState() }
        }
        notifTokens.append(tok3)

        isRunning = isSpotifyRunning()

        AppState.shared.$activeIntegrations
            .sink { [weak self] integrations in
                guard let self else { return }
                self.isRunning = self.isSpotifyRunning()
                if integrations.contains("integration_spotify") {
                    if self.isRunning,
                       UserDefaults.standard.bool(forKey: "coucou.spotifyAutomationGranted") {
                        self.fetchAndApply()
                    }
                } else {
                    self.clearState()
                }
            }
            .store(in: &cancellables)
    }

    private func isSpotifyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    private static func shortTitle(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
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

    private func handlePlayerInfo(playerState: String?, name: String?, artist inputArtist: String?, album inputAlbum: String?) {
        guard isPillActive else { return }

        let playing = playerState == "Playing"
        let wasPlaying = AppState.shared.spotifyPlaying

        trackTitle = name.map { Self.shortTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        artist     = inputArtist.map { Self.shortArtist($0) }.flatMap { $0.isEmpty ? nil : $0 }
        album      = inputAlbum

        AppState.shared.spotifyPlaying = playing
        syncTaskName()

        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func fetchAndApply() {
        Task {
            let result = await runAppleScript("""
                tell application id "com.spotify.client"
                    set ps to player state as string
                    set vol to sound volume as string
                    if ps is "stopped" then return {ps, "", "", "", vol}
                    try
                        set tr to current track
                        set n to name of tr
                    on error
                        return {ps, "", "", "", vol}
                    end try
                    set ar to ""
                    set al to ""
                    try
                        set ar to artist of tr
                    end try
                    try
                        set al to album of tr
                    end try
                    return {ps, n, ar, al, vol}
                end tell
            """)
            guard case .success(let values) = result, values.count >= 4 else { return }
            isRunning = true
            let playing    = values[0] == "playing"
            let wasPlaying = AppState.shared.spotifyPlaying
            trackTitle = values[1].isEmpty ? nil : Self.shortTitle(values[1])
            artist     = values[2].isEmpty ? nil : Self.shortArtist(values[2])
            album      = values[3].isEmpty ? nil : values[3]
            if values.count >= 5, let v = Int(values[4]) {
                volume = min(100, max(0, v))
            }
            AppState.shared.spotifyPlaying = playing
            syncTaskName()
            if playing && !wasPlaying {
                NotificationCenter.default.post(name: .musicReveal, object: nil)
            }
        }
    }

    private func clearState() {
        trackTitle = nil; artist = nil; album = nil
        AppState.shared.spotifyPlaying = false
        isRunning = false
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == "integration_spotify" }) else { return }
        let title = trackTitle ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: "integration_spotify")?.name ?? "Spotify")
            : title
    }

    // MARK: - Playback controls

    func playPause() {
        guard ensureRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.spotify.client" to playpause"#) }
    }

    func nextTrack() {
        guard ensureRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.spotify.client" to next track"#) }
    }

    func previousTrack() {
        guard ensureRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.spotify.client" to previous track"#) }
    }

    func volumeUp() {
        setVolume(volume + volumeStep)
    }

    func volumeDown() {
        setVolume(volume - volumeStep)
    }

    func setVolume(_ value: Int) {
        guard ensureRunning() else { return }
        let clamped = min(100, max(0, value))
        volume = clamped
        Task {
            await runAppleScript("tell application id \"com.spotify.client\" to set sound volume to \(clamped)")
        }
    }

    /// Launch Spotify if needed, then bring it to the front.
    @discardableResult
    func openSpotify() -> Bool {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            app.activate(options: .activateIgnoringOtherApps)
            isRunning = true
            if isPillActive { fetchAndApply() }
            return true
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, _ in
                Task { @MainActor in
                    self?.isRunning = app != nil
                    if app != nil, self?.isPillActive == true {
                        // Give Spotify a moment to accept Apple Events.
                        try? await Task.sleep(nanoseconds: 800_000_000)
                        self?.fetchAndApply()
                    }
                }
            }
            return true
        }
        let path = URL(fileURLWithPath: "/Applications/Spotify.app")
        guard FileManager.default.fileExists(atPath: path.path) else { return false }
        NSWorkspace.shared.openApplication(at: path, configuration: config) { [weak self] app, _ in
            Task { @MainActor in
                self?.isRunning = app != nil
                if app != nil, self?.isPillActive == true {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self?.fetchAndApply()
                }
            }
        }
        return true
    }

    /// Launch Spotify when a control needs it; returns false if not installed.
    @discardableResult
    private func ensureRunning() -> Bool {
        if isSpotifyRunning() {
            isRunning = true
            return true
        }
        return openSpotify()
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - AppleScript runner

    enum ScriptResult { case success([String]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            queue.async {
                let script = NSAppleScript(source: source)!
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == -1743 {
                        Task { @MainActor in
                            AppState.shared.spotifyAutomationDenied = true
                            UserDefaults.standard.set(false, forKey: "coucou.spotifyAutomationGranted")
                        }
                        cont.resume(returning: .denied)
                    } else {
                        cont.resume(returning: .error)
                    }
                    return
                }
                Task { @MainActor in
                    UserDefaults.standard.set(true, forKey: "coucou.spotifyAutomationGranted")
                    AppState.shared.spotifyAutomationDenied = false
                }
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
