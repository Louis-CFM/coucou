import Foundation

/// Reads the Spotify Mac app. No account and no API key.
final class SpotifyPoller: @unchecked Sendable {
    static let shared = SpotifyPoller()
    private var timer: DispatchSourceTimer?
    private var knownTrack = ""
    private var hasTrackBaseline = false
    private init() {}

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 3)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    func command(_ name: SpotifyCommand) {
        Task { @MainActor in self.applyOptimistic(name) }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run(name.script)
            self.poll()
        }
    }

    @MainActor
    private func applyOptimistic(_ name: SpotifyCommand) {
        guard var now = AppState.shared.spotifyNow else { return }
        switch name {
        case .playPause:
            if now.isPlaying { now.position = now.elapsed(at: Date()) }
            now.isPlaying.toggle()
            now.fetchedAt = Date()
        case .shuffle:
            now.isShuffling.toggle()
        case .repeatPlayback:
            now.isRepeating.toggle()
        case .seek(let seconds):
            now.position = max(0, seconds)
            now.fetchedAt = Date()
        case .next, .previous:
            break
        }
        AppState.shared.spotifyNow = now
    }

    private func poll() {
        let enabled = DispatchQueue.main.sync {
            AppState.shared.activeIntegrations.contains("integration_spotify")
        }
        guard enabled else { return }
        let now = Self.parse(Self.run(Self.nowPlayingScript))
        Task { @MainActor in self.publish(now) }
    }

    @MainActor
    private func publish(_ now: SpotifyNow?) {
        AppState.shared.spotifyNow = now
        guard let now else { return }
        let key = now.title + "\n" + now.artist
        if !hasTrackBaseline {
            hasTrackBaseline = true
            knownTrack = key
            return
        }
        guard key != knownTrack else { return }
        knownTrack = key
        AppState.shared.revealSpotifyPlayer()
    }

    private static let nowPlayingScript = """
    if application "Spotify" is not running then
      return "stopped"
    end if
    tell application "Spotify"
      if player state is playing then
        set stateText to "playing"
      else if player state is paused then
        set stateText to "paused"
      else
        return "stopped"
      end if
      set nm to name of current track
      set ar to artist of current track
      set art to ""
      try
        set art to artwork url of current track
      end try
      set posMs to 0
      try
        set posMs to round (player position * 1000) rounding down
      end try
      set durMs to 0
      try
        set durMs to duration of current track
      end try
      set shuf to "0"
      if shuffling then set shuf to "1"
      set rep to "0"
      if repeating then set rep to "1"
      return stateText & linefeed & nm & linefeed & ar & linefeed & art & linefeed & (posMs as integer) & linefeed & (durMs as integer) & linefeed & shuf & linefeed & rep
    end tell
    """

    private static func parse(_ output: String) -> SpotifyNow? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let state = lines.first, state == "playing" || state == "paused" else { return nil }
        let title = lines.count > 1 ? lines[1] : ""
        guard !title.isEmpty else { return nil }
        let artist = lines.count > 2 ? lines[2] : ""
        let art = lines.count > 3 ? lines[3] : ""
        let position = (Double(lines.count > 4 ? lines[4] : "") ?? 0) / 1000
        // The dictionary says seconds. Spotify actually returns milliseconds.
        let duration = (Double(lines.count > 5 ? lines[5] : "") ?? 0) / 1000
        return SpotifyNow(
            title: title,
            artist: artist,
            isPlaying: state == "playing",
            artworkURL: URL(string: art),
            position: position,
            duration: duration,
            isShuffling: lines.count > 6 && lines[6] == "1",
            isRepeating: lines.count > 7 && lines[7] == "1",
            fetchedAt: Date()
        )
    }

    private static func run(_ script: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum SpotifyCommand {
    case playPause, next, previous, shuffle, repeatPlayback
    case seek(TimeInterval)

    var script: String {
        switch self {
        case .playPause: return "tell application \"Spotify\" to playpause"
        case .next: return "tell application \"Spotify\" to next track"
        case .previous: return "tell application \"Spotify\" to previous track"
        case .shuffle: return "tell application \"Spotify\" to set shuffling to not shuffling"
        case .repeatPlayback: return "tell application \"Spotify\" to set repeating to not repeating"
        case .seek(let seconds):
            let text = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
            return "tell application \"Spotify\" to set player position to \(text)"
        }
    }
}
