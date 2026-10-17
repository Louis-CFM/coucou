#if !APPSTORE
import Foundation
import AppKit
import Combine
import Carbon

// MARK: - Music Controller

/// Observes Apple Music state via distributed notifications and provides playback controls.
/// Singleton, @MainActor, GitHub build only.
@MainActor
final class MusicController: ObservableObject {
    static let shared = MusicController()
    nonisolated private static let grantedKey = "coucou.musicAutomationGranted"
    @Published private(set) var automationGranted = UserDefaults.standard.bool(forKey: "coucou.musicAutomationGranted")
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var connectionFailed = false

    @Published var trackTitle: String?
    @Published var artist: String?
    @Published var album: String?

    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Int = 50
    @Published private(set) var shuffling = false
    @Published private(set) var repeatMode = "off"
    @Published private(set) var artwork: NSImage?
    private var positionAnchor: Double = 0
    private var positionDate = Date()
    private var refreshGeneration = 0
    private var artworkTask: Task<Void, Never>?
    private var artworkSearchTitle: String?
    private var artworkLookupKey: String?
    private var artworkCache: [String: NSImage] = [:]
    private var artworkAttempts: [String: Date] = [:]

    var isPlaying: Bool { AppState.shared.musicPlaying }
    var repeating: Bool { repeatMode != "off" }

    func position(at date: Date) -> Double {
        min(duration, max(0, positionAnchor + (isPlaying ? date.timeIntervalSince(positionDate) : 0)))
    }

    func refresh() {
        guard isPillActive, automationGranted, isMusicRunning() else { return }
        fetchAndApply()
    }

    /// Only a deliberate user action triggers the first system Automation prompt.
    func requestAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        connectionFailed = false
        Task {
            defer { isRequestingAccess = false }
            let result = await runAppleScript(#"tell application id "com.apple.Music" to return sound volume"#)
            if case .error = result { connectionFailed = true }
            refresh()
        }
    }

    func seek(to seconds: Double) {
        guard duration > 0, seconds.isFinite, isMusicRunning() else { return }
        let target = min(duration, max(0, seconds))
        Task {
            await runAppleScript("tell application id \"com.apple.Music\" to set player position to \(target)")
            refresh()
        }
    }

    func setShuffling(_ enabled: Bool) {
        guard isMusicRunning() else { return }
        Task {
            await runAppleScript("tell application id \"com.apple.Music\" to set shuffle enabled to \(enabled ? "true" : "false")")
            refresh()
        }
    }

    // Music supports off → all → one, unlike Spotify's boolean repeat control.
    func cycleRepeat() {
        guard isMusicRunning() else { return }
        let next = repeatMode == "off" ? "all" : (repeatMode == "all" ? "one" : "off")
        Task {
            await runAppleScript("tell application id \"com.apple.Music\" to set song repeat to \(next)")
            refresh()
        }
    }

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.music")

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
                      self.automationGranted else { return }
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
                       self.automationGranted {
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

        refreshGeneration += 1
        let changedTrack = trackTitle != name.map { Self.shortTitle($0) }
            || artist != inputArtist.map { Self.shortArtist($0) }
            || album != inputAlbum
        positionAnchor = changedTrack ? 0 : position(at: Date())
        positionDate = Date()
        if changedTrack { duration = 0; artwork = nil }
        let playing = playerState == "Playing"
        let wasPlaying = AppState.shared.musicPlaying

        trackTitle = name.map { Self.shortTitle($0) }.flatMap { $0.isEmpty ? nil : $0 }
        artist     = inputArtist.map { Self.shortArtist($0) }.flatMap { $0.isEmpty ? nil : $0 }
        album      = inputAlbum

        AppState.shared.musicPlaying = playing
        syncTaskName()
        refresh()

        // Reveal only on transition from not-playing → playing
        if playing && !wasPlaying {
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func fetchAndApply() {
        refreshGeneration += 1
        let generation = refreshGeneration
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
                    set d to 0
                    set pos to 0
                    set art to ""
                    try
                        set d to duration of tr
                        set pos to player position
                    end try
                    try
                        set art to raw data of artwork 1 of tr
                    on error
                        try
                            set art to data of artwork 1 of tr
                        end try
                    end try
                    return {ps, n, ar, al, d as string, pos as string, sound volume as string, shuffle enabled as string, song repeat as string, art}
                end tell
            """)
            guard generation == refreshGeneration, isPillActive, isMusicRunning(),
                  case .success(let values) = result, values.count >= 4 else { return }
            let playing    = values[0] == "playing"
            let wasPlaying = AppState.shared.musicPlaying
            let nextTitle = values[1].isEmpty ? nil : Self.shortTitle(values[1])
            let nextArtist = values[2].isEmpty ? nil : Self.shortArtist(values[2])
            let nextAlbum = values[3].isEmpty ? nil : values[3]
            if trackTitle != nextTitle || artist != nextArtist || album != nextAlbum { artwork = nil }
            artworkSearchTitle = values[1].isEmpty ? nil : values[1]
            trackTitle = nextTitle
            artist = nextArtist
            album = nextAlbum
            duration = values.count > 4 ? Double(values[4].replacingOccurrences(of: ",", with: ".")) ?? 0 : 0
            positionAnchor = values.count > 5 ? Double(values[5].replacingOccurrences(of: ",", with: ".")) ?? 0 : 0
            positionDate = Date()
            if values.count > 8 {
                volume = Int(values[6]) ?? volume
                shuffling = values[7] == "true"
                repeatMode = values[8]
            }
            if values.count > 9, let data = Data(base64Encoded: values[9]),
               let image = NSImage(data: data) {
                artwork = image
            }
            loadArtworkIfNeeded()
            AppState.shared.musicPlaying = playing
            syncTaskName()
            if playing && !wasPlaying {
                NotificationCenter.default.post(name: .musicReveal, object: nil)
            }
        }
    }

    // Streaming tracks may expose no artwork through Music's scripting dictionary.
    // Fall back to Apple's public catalog, only accepting matching artist and title.
    private struct CatalogResponse: Decodable {
        struct Track: Decodable {
            let artistName: String?
            let trackName: String?
            let artworkUrl100: String?
        }
        let results: [Track]
    }

    private func loadArtworkIfNeeded() {
        guard artwork == nil, let title = trackTitle, let artist, !artist.isEmpty else { return }
        let requestedAlbum = album
        let searchTitle = artworkSearchTitle ?? title
        let key = "\(artist)|\(searchTitle)|\(requestedAlbum ?? "")"
        if let cached = artworkCache[key] { artwork = cached; return }
        guard artworkLookupKey != key else { return }
        if let attempt = artworkAttempts[key], Date().timeIntervalSince(attempt) < 30 { return }
        if artworkAttempts.count >= 32 { artworkAttempts.removeAll() }
        artworkAttempts[key] = Date()
        artworkTask?.cancel()
        artworkLookupKey = key
        artworkTask = Task {
            defer { if artworkLookupKey == key { artworkLookupKey = nil } }
            do {
                var url = URLComponents(string: "https://itunes.apple.com/search")!
                url.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(title)"),
                                  URLQueryItem(name: "entity", value: "song"),
                                  URLQueryItem(name: "limit", value: "10")]
                var tracks: [CatalogResponse.Track] = []
                if let searchURL = url.url {
                    var request = URLRequest(url: searchURL)
                    request.timeoutInterval = 8
                    if let (data, response) = try? await URLSession.shared.data(for: request),
                       (response as? HTTPURLResponse)?.statusCode == 200,
                       let decoded = try? JSONDecoder().decode(CatalogResponse.self, from: data) {
                        tracks = decoded.results
                    }
                }
                try Task.checkCancellation()
                func normalized(_ value: String) -> String {
                    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let match = tracks.first(where: {
                    normalized($0.artistName ?? "") == normalized(artist)
                        && normalized($0.trackName ?? "") == normalized(searchTitle)
                })
                let artworkURL: URL?
                if let direct = match?.artworkUrl100.flatMap(URL.init(string:)) {
                    artworkURL = direct
                } else {
                    artworkURL = try await Self.webCatalogArtwork(title: searchTitle, artist: artist)
                }
                guard let artworkURL else { return }
                let (imageData, imageResponse) = try await URLSession.shared.data(from: artworkURL)
                try Task.checkCancellation()
                guard (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                      trackTitle == title, self.artist == artist, album == requestedAlbum,
                      artworkSearchTitle == searchTitle,
                      isPillActive, let image = NSImage(data: imageData) else { return }
                if artworkCache.count >= 16 { artworkCache.removeAll() }
                artworkCache[key] = image
                if artwork == nil { artwork = image }
            } catch {
                // Keep the local music-note placeholder when offline or not in the catalog.
            }
        }
    }

    /// Apple Music's catalog includes releases missing from the older iTunes search index.
    /// Its public page embeds structured data; if that format changes, fail closed.
    private static func webCatalogArtwork(title: String, artist: String) async throws -> URL? {
        var components = URLComponents(string: "https://music.apple.com/us/search")
        components?.queryItems = [URLQueryItem(name: "term", value: "\(artist) \(title)")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return nil }
        return catalogArtwork(in: html, title: title, artist: artist)
    }

    nonisolated static func catalogArtwork(in html: String, title: String, artist: String) -> URL? {
        guard let expression = try? NSRegularExpression(
            pattern: #"<script\b[^>]*id=["']serialized-server-data["'][^>]*>([\s\S]*?)</script>"#),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let data = String(html[range]).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        func artists(_ value: String) -> Set<String> {
            Set(value.components(separatedBy: CharacterSet(charactersIn: "&,"))
                .map { normalized($0) }.filter { !$0.isEmpty })
        }
        func find(_ value: Any) -> URL? {
            if let object = value as? [String: Any] {
                let descriptor = object["contentDescriptor"] as? [String: Any]
                if descriptor?["kind"] as? String == "song",
                   let candidateTitle = object["title"] as? String,
                   normalized(candidateTitle) == normalized(title) {
                    let links = object["subtitleLinks"] as? [[String: Any]]
                    let linkedArtists = links?.compactMap { $0["title"] as? String }.joined(separator: " & ")
                    let subtitle = object["subtitle"] as? String
                    let candidateArtist = linkedArtists ?? subtitle?.components(separatedBy: "·").last
                    if let candidateArtist, artists(candidateArtist) == artists(artist),
                       let artwork = object["artwork"] as? [String: Any],
                       let dictionary = artwork["dictionary"] as? [String: Any],
                       let template = dictionary["url"] as? String {
                        let resolved = template.replacingOccurrences(of: "{w}", with: "100")
                            .replacingOccurrences(of: "{h}", with: "100")
                            .replacingOccurrences(of: "{f}", with: "jpg")
                        if let url = URL(string: resolved), url.scheme == "https",
                           let host = url.host, host.hasSuffix(".mzstatic.com") { return url }
                    }
                }
                for child in object.values { if let url = find(child) { return url } }
            } else if let array = value as? [Any] {
                for child in array { if let url = find(child) { return url } }
            }
            return nil
        }
        return find(root)
    }

    private func clearState() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkLookupKey = nil
        refreshGeneration += 1
        duration = 0; positionAnchor = 0; artwork = nil
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

    func getVolume() async -> Int? {
        guard isMusicRunning() else { return nil }
        let result = await runAppleScript(#"tell application id "com.apple.Music" to return sound volume"#)
        if case .success(let vals) = result, let str = vals.first, let v = Int(str) { return v }
        return nil
    }

    func playPause() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to playpause"#) }
    }

    func play() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to play"#) }
    }

    func pause() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to pause"#) }
    }

    func setVolume(_ pct: Int) {
        guard isMusicRunning() else { return }
        let clamped = max(0, min(100, pct))
        volume = clamped
        Task { await runAppleScript(#"tell application id "com.apple.Music" to set sound volume to \#(clamped)"#) }
    }

    func nextTrack() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to next track"#) }
    }

    func previousTrack() {
        guard isMusicRunning() else { return }
        Task { await runAppleScript(#"tell application id "com.apple.Music" to back track"#) }
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

    enum ScriptResult: Sendable { case success([String]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String) async -> ScriptResult {
        let result: ScriptResult = await withCheckedContinuation { cont in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(returning: .error)
                    return
                }
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    cont.resume(returning: code == -1743 ? .denied : .error)
                    return
                }
                // Extract values on this queue before resuming (avoids NSAppleEventDescriptor Sendable issues)
                var values: [String] = []
                let count = desc.numberOfItems
                if count > 0 {
                    for i in 1...count {
                        if i == 10, let item = desc.atIndex(i),
                           item.descriptorType != typeUnicodeText,
                           item.descriptorType != typeUTF8Text {
                            values.append(item.data.base64EncodedString())
                        } else {
                            values.append(desc.atIndex(i)?.stringValue ?? "")
                        }
                    }
                } else {
                    values = [desc.stringValue ?? ""]
                }
                cont.resume(returning: .success(values))
            }
        }
        switch result {
        case .success:
            automationGranted = true
            AppState.shared.musicAutomationDenied = false
            UserDefaults.standard.set(true, forKey: Self.grantedKey)
        case .denied:
            automationGranted = false
            AppState.shared.musicAutomationDenied = true
            UserDefaults.standard.set(false, forKey: Self.grantedKey)
        case .error:
            break
        }
        return result
    }
}
#endif
