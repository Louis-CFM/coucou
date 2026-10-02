import Foundation

/// Reads the Spotify Mac app. No account and no API key.
final class SpotifyPoller: @unchecked Sendable {
    static let shared = SpotifyPoller()
    private var timer: DispatchSourceTimer?
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
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Self.run(name.script)
            self.poll()
        }
    }

    private func poll() {
        let enabled = DispatchQueue.main.sync {
            AppState.shared.activeIntegrations.contains("integration_spotify")
        }
        guard enabled else { return }
        let now = Self.parse(Self.run(Self.nowPlayingScript))
        DispatchQueue.main.async { AppState.shared.spotifyNow = now }
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
      return stateText & linefeed & nm & linefeed & ar & linefeed & art
    end tell
    """

    private static func parse(_ output: String) -> SpotifyNow? {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let state = lines.first, state == "playing" || state == "paused" else { return nil }
        let title = lines.count > 1 ? lines[1] : ""
        guard !title.isEmpty else { return nil }
        let artist = lines.count > 2 ? lines[2] : ""
        let art = lines.count > 3 ? lines[3] : ""
        return SpotifyNow(
            title: title,
            artist: artist,
            isPlaying: state == "playing",
            artworkURL: URL(string: art)
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
    case playPause, next, previous

    var script: String {
        switch self {
        case .playPause: return "tell application \"Spotify\" to playpause"
        case .next: return "tell application \"Spotify\" to next track"
        case .previous: return "tell application \"Spotify\" to previous track"
        }
    }
}
