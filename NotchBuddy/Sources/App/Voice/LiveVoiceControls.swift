#if !APPSTORE
import AppKit

// MARK: - LiveMusicControl

final class LiveMusicControl: MusicControlling, @unchecked Sendable {
    var isMusicRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").count > 0
    }
    var isSpotifyRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").count > 0
    }

    @MainActor func play() {
        if isMusicRunning   { MusicController.shared.play() }
        else                { SpotifyController.shared.play() }
    }
    @MainActor func pause() {
        if isMusicRunning   { MusicController.shared.pause() }
        else                { SpotifyController.shared.pause() }
    }
    @MainActor func nextTrack() {
        if isMusicRunning   { MusicController.shared.nextTrack() }
        else                { SpotifyController.shared.nextTrack() }
    }
    @MainActor func previousTrack() {
        if isMusicRunning   { MusicController.shared.previousTrack() }
        else                { SpotifyController.shared.previousTrack() }
    }
    @MainActor func volumeUp() {
        if isMusicRunning   { MusicController.shared.adjustVolume(by: +25) }
        else                { SpotifyController.shared.adjustVolume(by: +25) }
    }
    @MainActor func volumeDown() {
        if isMusicRunning   { MusicController.shared.adjustVolume(by: -25) }
        else                { SpotifyController.shared.adjustVolume(by: -25) }
    }
    @MainActor func setVolume(_ pct: Int) {
        if isMusicRunning   { MusicController.shared.setVolume(pct) }
        else                { SpotifyController.shared.setVolume(pct) }
    }
    @MainActor func playSearch(_ name: String) async -> Bool {
        guard isMusicRunning else { return false }
        return await MusicController.shared.playSearch(name)
    }
    @MainActor func playPlaylist(_ name: String) async -> Bool {
        guard isMusicRunning else { return false }
        return await MusicController.shared.playPlaylist(name)
    }
    @MainActor func launchAndPlay() async {
        if !isMusicRunning {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if isMusicRunning { MusicController.shared.play() }
    }
    @MainActor func launchSpotify() async {
        guard !isSpotifyRunning else { SpotifyController.shared.play(); return }
        let url = URL(fileURLWithPath: "/Applications/Spotify.app")
        NSWorkspace.shared.open(url)
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        if isSpotifyRunning { SpotifyController.shared.play() }
    }
    @MainActor func openSearch(_ name: String) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.apple.com/search?term=\(encoded)") else { return }
        // Open in Apple Music app, not the browser
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - LivePillControl

@MainActor
final class LivePillControl: PillControlling {
    func activeIds()  -> Set<String> { AppState.shared.activeIntegrations }
    func mainPillId() -> String      { AppState.shared.mainPillId }
    func activeCount() -> Int        { AppState.shared.activeIntegrations.count }
    func toggleIntegration(_ id: String) { AppState.shared.toggleIntegration(id) }
    func setMainPill(_ id: String)       { AppState.shared.setMainPill(id) }
}

// MARK: - Configuration

extension VoiceActionRunner {
    func configureLive() {
        music = LiveMusicControl()
        pills = LivePillControl()
    }
}
#endif
