#if !APPSTORE
import Foundation
import AppKit
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
    /// Music sound volume, 0…100.
    @Published var volume: Int = 50

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.music")
    private let volumeStep = 10
    private var lastEmoteTitle: String?

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
        let wasPlaying = AppState.shared.musicPlaying

        let prevTitle = trackTitle
        trackTitle = name.map { Self.shortTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        artist     = inputArtist.map { Self.shortArtist($0) }.flatMap { $0.isEmpty ? nil : $0 }
        album      = inputAlbum

        AppState.shared.musicPlaying = playing
        syncTaskName()

        // Reveal on play-start or track change
        if playing && (!wasPlaying || (trackTitle != nil && trackTitle != prevTitle)) {
            NotificationCenter.default.post(name: .musicReveal, object: trackTitle)
            if trackTitle != lastEmoteTitle {
                lastEmoteTitle = trackTitle
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            }
        }
        refreshVolume()
    }

    private func refreshVolume() {
        Task {
            let result = await runAppleScript(
                #"tell application id "com.apple.Music" to get sound volume as string"#
            )
            guard case .success(let values) = result, let raw = values.first, let v = Int(raw) else { return }
            volume = min(100, max(0, v))
        }
    }

    private func fetchAndApply() {
        Task {
            let result = await runAppleScript("""
                tell application id "com.apple.Music"
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
            let playing    = values[0] == "playing"
            let wasPlaying = AppState.shared.musicPlaying
            let prevTitle  = trackTitle
            trackTitle = values[1].isEmpty ? nil : Self.shortTitle(values[1])
            artist     = values[2].isEmpty ? nil : Self.shortArtist(values[2])
            album      = values[3].isEmpty ? nil : values[3]
            if values.count >= 5, let v = Int(values[4]) {
                volume = min(100, max(0, v))
            }
            AppState.shared.musicPlaying = playing
            syncTaskName()
            if playing && (!wasPlaying || (trackTitle != nil && trackTitle != prevTitle)) {
                NotificationCenter.default.post(name: .musicReveal, object: trackTitle)
                if trackTitle != lastEmoteTitle {
                    lastEmoteTitle = trackTitle
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
                }
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
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: "integration_music")?.name ?? "Apple Music")
            : title
    }

    // MARK: - Playback controls

    func playPause() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to playpause"#) }
    }

    func nextTrack() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to next track"#) }
    }

    func previousTrack() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to back track"#) }
    }

    func volumeUp() { setVolume(volume + volumeStep) }
    func volumeDown() { setVolume(volume - volumeStep) }

    func setVolume(_ value: Int) {
        guard isMusicRunning() else { return }
        let clamped = min(100, max(0, value))
        volume = clamped
        Task {
            await runAppleScript("tell application id \"com.apple.Music\" to set sound volume to \(clamped)")
        }
    }

    func openMusic() {
        _ = AppLauncher.open(
            bundleId: "com.apple.Music",
            fallbackPath: "/System/Applications/Music.app"
        )
    }

    func openAutomationSettings() {
        _ = AppLauncher.openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
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
