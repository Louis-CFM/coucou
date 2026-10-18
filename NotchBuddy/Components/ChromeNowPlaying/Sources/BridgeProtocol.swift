import Foundation

struct BridgeEvent: Decodable, Sendable {
    let type: String
    let active: Bool?
    let pid: Int32?
    let source: String?
    let bundleIdentifier: String?
    let title: String?
    let artist: String?
    let duration: Double?
    let position: Double?
    let timestamp: Double?
    let rate: Double?
    let playing: Bool?
    let identity: String?
    let artworkRevision: UInt64?
    let artwork: String?
    let controlsKnown: Bool?
    let canPrevious: Bool?
    let canNext: Bool?
    let canSeek: Bool?
    let requestID: String?
    let accepted: Bool?
    let message: String?

    func validate() throws {
        guard ["ready", "snapshot", "error", "command"].contains(type) else { throw BridgeProtocolError.invalid }
        for value in [duration, position, timestamp, rate].compactMap({ $0 }) {
            guard value.isFinite, value >= 0 else { throw BridgeProtocolError.invalid }
        }
        guard (requestID?.utf8.count ?? 0) <= 64 else { throw BridgeProtocolError.invalid }
        guard (duration ?? 0) <= 604800, (position ?? 0) <= 604800 else { throw BridgeProtocolError.invalid }
        if type == "snapshot", active == true {
            guard let pid, pid > 0, let source, !source.isEmpty, let bundleIdentifier,
                !bundleIdentifier.isEmpty, !["com.apple.Music", "com.spotify.client"].contains(bundleIdentifier),
                title != nil, artist != nil,
                duration != nil, position != nil, timestamp != nil, playing != nil,
                let rate, rate <= 16, identity != nil, artworkRevision != nil
            else { throw BridgeProtocolError.invalid }
        }
        for value in [title, artist, source, bundleIdentifier, message].compactMap({ $0 }) {
            guard value.utf16.count <= 2048 else { throw BridgeProtocolError.invalid }
        }
        guard (identity?.utf16.count ?? 0) <= 16384,
            (artwork?.utf8.count ?? 0) <= 5_592_408
        else { throw BridgeProtocolError.oversized }
    }
}

/// UI state deliberately excludes the large base64 artwork payload.
struct PlaybackSnapshot: Sendable {
    let pid: Int32
    let source: String
    let bundleIdentifier: String
    let title: String
    let artist: String
    let duration: Double
    let position: Double
    let timestamp: Double
    let rate: Double
    let playing: Bool
    let identity: String
    let controlsKnown: Bool
    let canPrevious: Bool
    let canNext: Bool
    let canSeek: Bool

    init?(_ event: BridgeEvent) {
        guard event.active == true, let pid = event.pid, let source = event.source,
            let bundleIdentifier = event.bundleIdentifier, let title = event.title,
            let artist = event.artist, let duration = event.duration,
            let position = event.position, let timestamp = event.timestamp,
            let rate = event.rate, let playing = event.playing, let identity = event.identity
        else { return nil }
        self.pid = pid
        self.source = source
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.artist = artist
        self.duration = duration
        self.position = position
        self.timestamp = timestamp
        self.rate = rate
        self.playing = playing
        self.identity = identity
        self.controlsKnown = event.controlsKnown == true
        self.canPrevious = event.canPrevious == true
        self.canNext = event.canNext == true
        self.canSeek = event.canSeek == true
    }
    /// Ordinary progress is not confirmation that a track-navigation command worked.
    func confirmsNavigation(from previous: PlaybackSnapshot, command: String) -> Bool {
        guard pid == previous.pid, bundleIdentifier == previous.bundleIdentifier else { return false }
        if identity != previous.identity { return true }
        return command == "previous" && previous.position > 3 && position < 2
    }
}

enum BridgeProtocolError: Error { case oversized, invalid, truncated }

/// Bounded bytes, not per-chunk UTF-8 strings: handles split Unicode and split JSON.
struct BridgeLineDecoder {
    static let limit = 6 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [BridgeEvent] {
        guard data.count <= Self.limit, buffer.count <= Self.limit - data.count else {
            buffer.removeAll()
            throw BridgeProtocolError.oversized
        }
        buffer.append(data)
        var events: [BridgeEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            let value = try JSONDecoder().decode(BridgeEvent.self, from: line)
            try value.validate()
            events.append(value)
        }
        return events
    }
    mutating func finish() throws {
        guard buffer.isEmpty else { throw BridgeProtocolError.truncated }
    }
}

actor BridgeParser {
    private var decoder = BridgeLineDecoder()
    func append(_ data: Data) throws -> [BridgeEvent] { try decoder.append(data) }
    func finish() throws { try decoder.finish() }
}
