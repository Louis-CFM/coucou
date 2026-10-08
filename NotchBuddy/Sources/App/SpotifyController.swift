#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Spotify Controller

/// The track Spotify has loaded, as its notification and AppleScript describe it.
struct SpotifyTrack: Equatable, Sendable {
    let id: String          // spotify:track:…, spotify:episode:…, spotify:ad:…, spotify:local:…
    let title: String
    let artist: String
    let album: String
    let duration: Double    // seconds
    var artworkURL: String?

    var isAd: Bool { id.hasPrefix("spotify:ad:") }

    /// open.spotify.com page for tracks and episodes (ads and local files have none).
    var webURL: URL? {
        let parts = id.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" || parts[1] == "episode" else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

/// Observes Spotify through its distributed notification and drives it over AppleScript.
/// Singleton, @MainActor, GitHub build only (the App Store sandbox would need an Apple Events exception).
/// Nothing runs on a timer: state arrives with Spotify's notification, the card extrapolates the position.
@MainActor
final class SpotifyController: ObservableObject {
    static let shared = SpotifyController()
    nonisolated static let pillId   = "integration_spotify"
    nonisolated static let bundleId = "com.spotify.client"
    nonisolated static let green    = "#1DB954"

    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var isPlaying = false
    /// Position (seconds) at `positionDate`; while playing, the real position runs on from there.
    @Published private(set) var positionAnchor: Double = 0
    @Published private(set) var positionDate = Date()
    @Published private(set) var shuffling = false
    @Published private(set) var repeating = false
    @Published private(set) var volume: Int = 50
    @Published private(set) var artwork: NSImage?
    @Published private(set) var automationDenied = false

    nonisolated private static let grantedKey = "coucou.spotifyAutomationGranted"

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.spotify")
    private var artworkCache: [String: NSImage] = [:]
    private var artworkCacheOrder: [String] = []
    private var artworkLoadingId: String?
    private var pendingVolume: Int?
    private var volumeTask: Task<Void, Never>?

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    private var automationGranted: Bool {
        UserDefaults.standard.bool(forKey: Self.grantedKey)
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) != nil
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleId }
    }

    /// Where playback is now, extrapolated from the last anchor.
    func position(at date: Date) -> Double {
        let elapsed = isPlaying ? date.timeIntervalSince(positionDate) : 0
        let p = positionAnchor + max(0, elapsed)
        guard let d = track?.duration, d > 0 else { return p }
        return min(p, d)
    }

    private init() {
        // Spotify posts this on play, pause and track change. Seeks inside Spotify don't post it,
        // so the card re-reads the position when it appears.
        let tok1 = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notif in
            // Extract Sendable values before crossing into @MainActor.
            let info     = notif.userInfo
            let state    = info?["Player State"]      as? String
            let trackId  = info?["Track ID"]          as? String
            let name     = info?["Name"]              as? String
            let artist   = info?["Artist"]            as? String
            let album    = info?["Album"]             as? String
            let duration = (info?["Duration"]          as? NSNumber)?.doubleValue
            let position = (info?["Playback Position"] as? NSNumber)?.doubleValue
            Task { @MainActor [weak self] in
                self?.handleNotification(state: state, trackId: trackId, name: name, artist: artist,
                                         album: album, durationMs: duration, position: position)
            }
        }
        notifTokens.append(tok1)

        // Spotify launched: read its state once, only if we already may
        let tok2 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == SpotifyController.bundleId else { return }
            Task { @MainActor [weak self] in
                guard let self, self.automationGranted else { return }
                self.refresh()
            }
        }
        notifTokens.append(tok2)

        // Spotify quit: nothing is playing anymore
        let tok3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == SpotifyController.bundleId else { return }
            Task { @MainActor [weak self] in self?.clearState() }
        }
        notifTokens.append(tok3)

        // Pill turned on → read the current track (this is when macOS asks for Automation, right
        // after the user's own click). At launch, only if already granted. Pill turned off → clear.
        var wasActive: Bool? = nil
        AppState.shared.$activeIntegrations
            .sink { [weak self] integrations in
                guard let self else { return }
                let active = integrations.contains(Self.pillId)
                defer { wasActive = active }
                guard active else { self.clearState(); return }
                guard wasActive != true else { return }
                if wasActive == false || self.automationGranted {
                    // The publisher fires before the property is set: read once it is
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - State

    private func handleNotification(state: String?, trackId: String?, name: String?, artist: String?,
                                    album: String?, durationMs: Double?, position: Double?) {
        guard isPillActive else { return }
        if state == "Stopped" { clearState(); return }

        if let trackId, !trackId.isEmpty {
            let same = track?.id == trackId
            let newTrack = SpotifyTrack(
                id: trackId,
                title: Self.shortTitle(name ?? ""),
                artist: Self.shortArtist(artist ?? ""),
                album: album ?? "",
                duration: (durationMs ?? 0) / 1000,
                artworkURL: same ? track?.artworkURL : nil
            )
            setTrack(newTrack)
        }
        if let position { anchor(position) }
        setPlaying(state == "Playing")

        // The notification carries no artwork, shuffle, repeat or volume: read them when we may,
        // otherwise find the artwork through Spotify's public oEmbed.
        if automationGranted {
            refresh()
        } else if let track, artwork == nil {
            loadArtwork(for: track)
        }
    }

    private func setTrack(_ newTrack: SpotifyTrack) {
        let changed = track?.id != newTrack.id
        track = newTrack
        if changed {
            artwork = artworkCache[newTrack.id]
        }
        syncTaskName()
    }

    private func setPlaying(_ playing: Bool) {
        let wasPlaying = isPlaying
        if playing != wasPlaying {
            // Freeze or restart the clock at the current position
            anchor(position(at: Date()))
        }
        isPlaying = playing
        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func anchor(_ position: Double) {
        positionAnchor = max(0, position)
        positionDate = Date()
    }

    private func clearState() {
        track = nil
        artwork = nil
        isPlaying = false
        anchor(0)
        syncTaskName()
    }

    private func syncTaskName() {
        guard let idx = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        let title = track?.isAd == true ? "Advertisement" : (track?.title ?? "")
        AppState.shared.tasks[idx].name = title.isEmpty
            ? (PillCatalog.definition(for: Self.pillId)?.name ?? "Spotify")
            : title
    }

    // MARK: - Reading Spotify

    /// Reads track, position, shuffle, repeat, volume and artwork URL. Never launches Spotify.
    /// The first call is what makes macOS ask for Automation.
    func refresh() {
        guard isPillActive, isRunning else { return }
        Task {
            let result = await runAppleScript("""
                tell application id "com.spotify.client"
                    set ps to player state as string
                    if ps is "stopped" then return {ps}
                    try
                        set tr to current track
                        set tid to id of tr
                    on error
                        return {"stopped"}
                    end try
                    set n to ""
                    set ar to ""
                    set al to ""
                    set du to 0
                    set au to ""
                    set pp to 0
                    try
                        set n to name of tr
                    end try
                    try
                        set ar to artist of tr
                    end try
                    try
                        set al to album of tr
                    end try
                    try
                        set du to duration of tr
                    end try
                    try
                        set au to artwork url of tr
                    end try
                    try
                        set pp to player position
                    end try
                    return {ps, tid, n, ar, al, du, pp, shuffling, repeating, sound volume, au}
                end tell
            """)
            guard case .success(let v) = result, let ps = v.first?.text else { return }
            guard isPillActive else { return }
            if ps == "stopped" || v.count < 11 { clearState(); return }

            let artworkURL = v[10].text.isEmpty ? nil : v[10].text
            let newTrack = SpotifyTrack(
                id: v[1].text,
                title: Self.shortTitle(v[2].text),
                artist: Self.shortArtist(v[3].text),
                album: v[4].text,
                duration: v[5].number / 1000,
                artworkURL: artworkURL
            )
            setTrack(newTrack)
            anchor(v[6].number)
            setPlaying(ps == "playing")
            shuffling = v[7].flag
            repeating = v[8].flag
            if pendingVolume == nil { volume = Int(v[9].number.rounded()) }
            if artwork == nil { loadArtwork(for: newTrack) }
        }
    }

    // MARK: - Artwork

    private func loadArtwork(for track: SpotifyTrack) {
        if let cached = artworkCache[track.id] { artwork = cached; return }
        guard artworkLoadingId != track.id else { return }
        artworkLoadingId = track.id
        let id = track.id
        let direct = track.artworkURL
        let page = track.webURL
        Task {
            defer { if artworkLoadingId == id { artworkLoadingId = nil } }
            var imageURL = direct.flatMap(Self.spotifyImageURL)
            if imageURL == nil, let page {
                imageURL = await Self.oEmbedThumbnail(for: page)
            }
            guard let imageURL,
                  let (data, response) = try? await URLSession.shared.data(from: imageURL),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            cacheArtwork(image, for: id)
            if self.track?.id == id { artwork = image }
        }
    }

    private func cacheArtwork(_ image: NSImage, for id: String) {
        artworkCache[id] = image
        artworkCacheOrder.removeAll { $0 == id }
        artworkCacheOrder.append(id)
        while artworkCacheOrder.count > 12 {
            artworkCache[artworkCacheOrder.removeFirst()] = nil
        }
    }

    /// Only Spotify's own image CDN: the URL comes from another app.
    nonisolated private static func spotifyImageURL(_ string: String) -> URL? {
        guard let url = safeWebURL(string), url.scheme == "https",
              let host = url.host?.lowercased(),
              host == "i.scdn.co" || host.hasSuffix(".scdn.co") || host.hasSuffix(".spotifycdn.com")
        else { return nil }
        return url
    }

    /// Spotify's public oEmbed gives the cover without any account or Automation permission.
    nonisolated private static func oEmbedThumbnail(for page: URL) async -> URL? {
        var comps = URLComponents(string: "https://open.spotify.com/oembed")!
        comps.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        guard let url = comps.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumb = json["thumbnail_url"] as? String else { return nil }
        return spotifyImageURL(thumb)
    }

    // MARK: - Playback controls

    func playPause() {
        guard isRunning else { return }
        setPlaying(!isPlaying)   // optimistic; Spotify's notification confirms
        command("playpause")
    }

    func nextTrack() {
        guard isRunning else { return }
        command("next track")
    }

    func previousTrack() {
        guard isRunning else { return }
        command("previous track")
    }

    func seek(to seconds: Double) {
        guard isRunning, let track, !track.isAd else { return }
        let target = min(max(0, seconds), max(0, track.duration - 1))
        anchor(target)
        command("set player position to \(Int(target.rounded()))", refreshAfter: false)
    }

    func setShuffling(_ on: Bool) {
        guard isRunning else { return }
        shuffling = on
        command("set shuffling to \(on)", refreshAfter: false)
    }

    func setRepeating(_ on: Bool) {
        guard isRunning else { return }
        repeating = on
        command("set repeating to \(on)", refreshAfter: false)
    }

    /// Coalesced: a slider drag sends at most one Apple Event every 120 ms.
    func setVolume(_ value: Int) {
        guard isRunning else { return }
        let v = min(100, max(0, value))
        volume = v
        pendingVolume = v
        guard volumeTask == nil else { return }
        volumeTask = Task {
            while let v = pendingVolume {
                pendingVolume = nil
                await runAppleScript(#"tell application id "com.spotify.client" to set sound volume to \#(v)"#)
                try? await Task.sleep(for: .milliseconds(120))
            }
            volumeTask = nil
        }
    }

    private func command(_ verb: String, refreshAfter: Bool = true) {
        Task {
            let result = await runAppleScript(#"tell application id "com.spotify.client" to \#(verb)"#)
            guard refreshAfter, case .success = result else { return }
            // Let Spotify settle on the new track before reading it back
            try? await Task.sleep(for: .milliseconds(350))
            refresh()
        }
    }

    func openSpotify() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.bundleId }) {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    func openDownloadPage() {
        NSWorkspace.shared.open(URL(string: "https://www.spotify.com/download/")!)
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Metadata cleaners (same rules as Apple Music)

    private static func shortTitle(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        // Cut at first " - " ("Song - Remastered 2011")
        if let r = s.range(of: " - ") {
            s = String(s[..<r.lowerBound])
        }
        // Strip trailing (...) or [...] groups repeatedly
        while true {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard let last = t.last, last == ")" || last == "]" else { break }
            let open: Character = last == ")" ? "(" : "["
            guard let idx = t.lastIndex(of: open) else { break }
            let candidate = String(t[..<idx]).trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty else { break }
            s = candidate
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

    // MARK: - AppleScript runner

    /// One item of an AppleScript result, read three ways so callers pick the one they expect.
    struct ScriptValue: Sendable {
        let text: String
        let number: Double
        let flag: Bool
    }

    enum ScriptResult: Sendable { case success([ScriptValue]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String) async -> ScriptResult {
        let grantedKey = Self.grantedKey
        let result: ScriptResult = await withCheckedContinuation { cont in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(returning: .error); return
                }
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    cont.resume(returning: code == -1743 ? .denied : .error)
                    return
                }
                // Extract values on this queue (NSAppleEventDescriptor isn't Sendable)
                func value(_ d: NSAppleEventDescriptor?) -> ScriptValue {
                    ScriptValue(text: d?.stringValue ?? "", number: d?.doubleValue ?? 0, flag: d?.booleanValue ?? false)
                }
                let count = desc.numberOfItems
                let values = count > 0 ? (1...count).map { value(desc.atIndex($0)) } : [value(desc)]
                cont.resume(returning: .success(values))
            }
        }
        switch result {
        case .success:
            UserDefaults.standard.set(true, forKey: grantedKey)
            automationDenied = false
        case .denied:
            UserDefaults.standard.set(false, forKey: grantedKey)
            automationDenied = true
        case .error:
            break
        }
        return result
    }
}
#endif
