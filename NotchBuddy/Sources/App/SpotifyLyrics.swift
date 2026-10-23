#if !APPSTORE
import Foundation
import Combine

// MARK: - Spotify Lyrics

/// One timed line of an LRC file.
struct LyricLine: Equatable, Sendable {
    let time: Double    // seconds
    let text: String
}

/// What LRCLIB knows about a track.
enum SpotifyLyrics: Equatable, Sendable {
    case synced([LyricLine])
    case unsynced       // only plain lyrics: nothing to follow the song with
    case instrumental
    case notFound

    /// Index of the line being sung at `position`, nil before the first one.
    static func currentIndex(in lines: [LyricLine], at position: Double) -> Int? {
        // Show a line a touch early: reading lags behind hearing
        let p = position + 0.25
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= p { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Parses "[mm:ss.xx] text" lines. Several stamps on one line repeat it; metadata tags are skipped.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                let parts = tag.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) else { continue }
                times.append(m * 60 + s)
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { lines.append(LyricLine(time: t, text: text)) }
        }
        return lines.sorted { $0.time < $1.time }
    }
}

/// Finds lyrics for the Spotify track on LRCLIB (lrclib.net: public, no account, no key).
/// Off by default; asks only while the lyrics are on screen, once per track.
@MainActor
final class SpotifyLyricsStore: ObservableObject {
    static let shared = SpotifyLyricsStore()
    nonisolated static let enabledKey = "coucou.spotifyLyricsEnabled"

    /// The card shows the lyrics instead of the artwork and progress rows.
    @Published var showing = false {
        didSet { if showing { load() } }
    }
    @Published private(set) var lyrics: SpotifyLyrics?
    @Published private(set) var loading = false
    /// LRCLIB couldn't be reached for this track: not a verdict, it is asked again.
    @Published private(set) var failed = false

    private var cache: [String: SpotifyLyrics] = [:]
    private var cacheOrder: [String] = []
    private var loadingId: String?
    private var cancellables = Set<AnyCancellable>()

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// Lyrics open, synced and the song playing: the closed island keeps showing them.
    var isFollowing: Bool {
        guard isEnabled, showing, SpotifyController.shared.isPlaying,
              case .synced = lyrics else { return false }
        return true
    }

    private init() {
        SpotifyController.shared.$track
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in
                // The publisher fires before the property is set: read once it is
                Task { @MainActor [weak self] in self?.trackChanged() }
            }
            .store(in: &cancellables)
    }

    private func trackChanged() {
        guard let track = SpotifyController.shared.track else {
            lyrics = nil
            return
        }
        lyrics = cache[track.id]
        failed = false
        if showing { load() }
    }

    private func load() {
        guard isEnabled, let track = SpotifyController.shared.track else { return }
        if let cached = cache[track.id] { lyrics = cached; return }
        // Ads and podcasts have no lyrics
        guard !track.isAd, !track.id.hasPrefix("spotify:episode:"), !track.title.isEmpty else {
            lyrics = .notFound
            return
        }
        guard loadingId != track.id else { return }
        loadingId = track.id
        lyrics = nil
        loading = true
        failed = false
        let id = track.id
        Task {
            let found = await Self.fetch(title: track.title, artist: track.artist,
                                         album: track.album, duration: track.duration)
            if loadingId == id { loadingId = nil; loading = false }
            guard SpotifyController.shared.track?.id == id else { return }
            guard let found else {
                // A network failure is not a verdict: ask again in a moment, same song only
                failed = true
                try? await Task.sleep(for: .seconds(20))
                if showing, failed, SpotifyController.shared.track?.id == id { load() }
                return
            }
            cache(found, for: id)
            lyrics = found
        }
    }

    private func cache(_ value: SpotifyLyrics, for id: String) {
        cache[id] = value
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > 30 {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    // MARK: - LRCLIB

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Exact match first (LRCLIB allows ±2 s on the duration), then a search.
    /// nil only when LRCLIB couldn't be reached at all.
    nonisolated private static func fetch(title: String, artist: String, album: String,
                                          duration: Double) async -> SpotifyLyrics? {
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        // Plain lyrics only: a search may still find a synced copy
        var plain: SpotifyLyrics?
        // A failed exact match is no reason to stop: LRCLIB answers 503 to a song it is
        // looking up for the first time, while the search already has it.
        let exact = await requestTwice(get.url!)
        if case .success(let data) = exact,
           let data, let record = try? JSONDecoder().decode(Record.self, from: data),
           let lyrics = lyrics(from: record) {
            if lyrics != .unsynced { return lyrics }
            plain = lyrics
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard case .success(let data) = await requestTwice(search.url!) else {
            if case .failure = exact { return nil }
            return plain
        }
        let records = data.flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        // Same song only: a duration far off is another version
        let close = records.filter { abs(($0.duration ?? 0) - duration) <= 3 || duration <= 0 }
        let best = close.first { $0.syncedLyrics?.isEmpty == false }
            ?? close.first { $0.instrumental == true }
            ?? close.first
        return best.flatMap(lyrics(from:)) ?? plain ?? .notFound
    }

    nonisolated private static func lyrics(from record: Record) -> SpotifyLyrics? {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics {
            let lines = SpotifyLyrics.parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if record.plainLyrics?.isEmpty == false { return .unsynced }
        return nil
    }

    /// One more try after a moment when the first one fails (503 while LRCLIB warms up).
    nonisolated private static func requestTwice(_ url: URL) async -> Result<Data?, Error> {
        let first = await request(url)
        guard case .failure = first else { return first }
        try? await Task.sleep(for: .milliseconds(1500))
        return await request(url)
    }

    /// success(nil) is a 404: LRCLIB answered, it just doesn't know the song.
    nonisolated private static func request(_ url: URL) async -> Result<Data?, Error> {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Coucou (https://github.com/Louis-CFM/coucou)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .success(nil) }
            guard status == 200 else { return .failure(URLError(.badServerResponse)) }
            return .success(data)
        } catch {
            return .failure(error)
        }
    }
}
#endif
