#if !APPSTORE
import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - Music Controller

/// Observes Apple Music state via distributed notifications and provides playback controls.
/// Singleton, @MainActor, GitHub build only.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published var trackTitle: String?
    @Published var artist: String?
    @Published var album: String?
    @Published var artwork: NSImage?
    @Published var isPlaying: Bool = false
    @Published var currentApp: String?

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.music")
    private var dismissTimer: Timer?

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains("integration_music")
    }

    private init() {
        // playerInfo fires whenever Music state changes (play/pause/track change).
        // Extract Sendable String? values before crossing into @MainActor.
        let tok1 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
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

        // Track Music launch — read current state only if granted and pill active
        let tok2 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == "com.apple.Music" else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isPillActive,
                      UserDefaults.standard.bool(forKey: "coucou.musicAutomationGranted") else { return }
                self.fetchAndApply()
            }
        }
        notifTokens.append(tok2)

        // Clear state when Music quits
        let tok3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == "com.apple.Music" else { return }
            Task { @MainActor [weak self] in self?.clearState() }
        }
        notifTokens.append(tok3)

        // Observe activeIntegrations — pill activated → initial read; deactivated → clear
        AppState.shared.$activeIntegrations
            .sink { [weak self] integrations in
                guard let self else { return }
                if integrations.contains("integration_music") {
                    if self.isMusicRunning(),
                       UserDefaults.standard.bool(forKey: "coucou.musicAutomationGranted") {
                        self.fetchAndApply()
                    }
                } else {
                    self.clearState()
                }
            }
            .store(in: &cancellables)

        // Observe NowPlayingMediaRemote (supports Apple Music, YouTube in browsers, etc.)
        NowPlayingMediaRemote.shared.$title
            .combineLatest(NowPlayingMediaRemote.shared.$isPlaying, NowPlayingMediaRemote.shared.$artwork)
            .removeDuplicates { prev, cur in
                prev.0 == cur.0 && prev.1 == cur.1 && prev.2 == cur.2
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title, playing, art in
                guard let self else { return }
                self.handleNowPlayingUpdate(
                    title: title,
                    playing: playing,
                    art: art,
                    artist: NowPlayingMediaRemote.shared.artist,
                    album: NowPlayingMediaRemote.shared.album,
                    app: NowPlayingMediaRemote.shared.appName
                )
            }
            .store(in: &cancellables)
    }

    private func handleNowPlayingUpdate(title: String?, playing: Bool, art: NSImage?, artist: String?, album: String?, app: String?) {
        if let title = title, !title.isEmpty, playing {
            dismissTimer?.invalidate()
            dismissTimer = nil

            self.trackTitle = Self.shortTitle(title)
            self.artist = artist.map { Self.shortArtist($0) }
            self.album = album
            if art != nil {
                self.artwork = art
            }
            self.isPlaying = true
            self.currentApp = app

            let wasPlaying = AppState.shared.musicPlaying
            AppState.shared.musicPlaying = true
            self.syncTaskName()

            if !wasPlaying {
                NotificationCenter.default.post(name: .musicReveal, object: nil)
            }
        } else {
            self.isPlaying = false

            // Only schedule dismiss if music is currently shown
            guard AppState.shared.musicPlaying else { return }

            // Do not restart timer if already scheduled
            if dismissTimer != nil { return }

            // 1.0 second delay after pause as requested
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.dismissTimer = nil
                    if !NowPlayingMediaRemote.shared.isPlaying {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            AppState.shared.musicPlaying = false
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                            guard let self else { return }
                            if !AppState.shared.musicPlaying {
                                self.trackTitle = nil
                                self.artist = nil
                                self.album = nil
                                self.artwork = nil
                                self.currentApp = nil
                                self.syncTaskName()
                                if AppState.shared.focusId == "integration_music" {
                                    AppState.shared.focusId = AppState.shared.mainPillId
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func expandToMusicCard() {
        guard let title = trackTitle, !title.isEmpty else { return }
        if !AppState.shared.activeIntegrations.contains("integration_music") {
            AppState.shared.activeIntegrations.insert("integration_music")
            AppState.shared.loadIntegrationTasks()
        }
        AppState.shared.focusId = "integration_music"
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.islandController?.fsm.openedExternally()
            appDelegate.islandController?.expand(to: .overview)
        }
    }

    // MARK: - Private helpers

    private func isMusicRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
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

    private func handlePlayerInfo(playerState: String?, name: String?, artist inputArtist: String?, album inputAlbum: String?) {
        guard isPillActive else { return }
        let playing = playerState == "Playing"
        handleNowPlayingUpdate(
            title: name,
            playing: playing,
            art: self.artwork,
            artist: inputArtist,
            album: inputAlbum,
            app: "Apple Music"
        )
    }

    private func fetchAndApply() {
        Task {
            let result = await runAppleScript("""
                tell application id "com.apple.Music"
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
            """)
            guard case .success(let values) = result, values.count >= 4 else { return }
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
        dismissTimer?.invalidate()
        dismissTimer = nil
        if !NowPlayingMediaRemote.shared.isPlaying {
            trackTitle = nil; artist = nil; album = nil; artwork = nil
            isPlaying = false
            currentApp = nil
            AppState.shared.musicPlaying = false
            syncTaskName()
        }
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == "integration_music" }) else { return }
        let title = trackTitle ?? ""
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: "integration_music")?.name ?? "Apple Music")
            : title
    }

    // MARK: - Playback controls

    func getVolume() async -> Int? {
        guard isMusicRunning() else { return nil }
        let result = await runAppleScript(#"tell application id "com.apple.Music" to return sound volume"#)
        if case .success(let vals) = result, let str = vals.first, let v = Int(str) { return v }
        return nil
    }

    func playPause() {
        if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to playpause"#) }
        } else {
            NowPlayingMediaRemote.shared.playPause()
        }
    }

    func play() {
        if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to play"#) }
        } else {
            NowPlayingMediaRemote.shared.playPause()
        }
    }

    func pause() {
        if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to pause"#) }
        } else {
            NowPlayingMediaRemote.shared.playPause()
        }
    }

    func setVolume(_ pct: Int) {
        let clamped = max(0, min(100, pct))
        Task { await runAppleScript(#"tell application id "com.apple.Music" to set sound volume to \#(clamped)"#) }
    }

    func nextTrack() {
        if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to next track"#) }
        } else {
            NowPlayingMediaRemote.shared.nextTrack()
        }
    }

    func previousTrack() {
        if isMusicRunning() {
            Task { await runAppleScript(#"tell application id "com.apple.Music" to back track"#) }
        } else {
            NowPlayingMediaRemote.shared.previousTrack()
        }
    }

    func adjustVolume(by delta: Int) {
        Task {
            let result = await runAppleScript(
                #"tell application id "com.apple.Music" to set sound volume to (sound volume + \#(delta))"#
            )
            _ = result
        }
    }

    func playArtist(_ name: String) async -> Bool {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = await runAppleScript("""
            tell application id "com.apple.Music"
                try
                    set tr to (first track of library playlist 1 whose artist contains "\(escaped)")
                    play tr
                    return "ok"
                on error
                    return "notfound"
                end try
            end tell
        """)
        if case .success(let vals) = result, vals.first == "ok" { return true }
        return false
    }

    func playSearch(_ query: String) async -> Bool {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = await runAppleScript("""
            tell application id "com.apple.Music"
                try
                    set tr to (first track of library playlist 1 whose name contains "\(escaped)" or artist contains "\(escaped)")
                    play tr
                    return "ok"
                on error
                    return "notfound"
                end try
            end tell
        """)
        if case .success(let vals) = result, vals.first == "ok" { return true }
        return false
    }

    func playPlaylist(_ name: String) async -> Bool {
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let result = await runAppleScript(#"tell application id "com.apple.Music" to play playlist "\#(escaped)""#)
        if case .success(_) = result { return true }
        return false
    }

    func openMusic() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
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
                            AppState.shared.musicAutomationDenied = true
                            UserDefaults.standard.set(false, forKey: "coucou.musicAutomationGranted")
                        }
                        cont.resume(returning: .denied)
                    } else {
                        cont.resume(returning: .error)
                    }
                    return
                }
                Task { @MainActor in
                    UserDefaults.standard.set(true, forKey: "coucou.musicAutomationGranted")
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
