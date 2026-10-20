import Foundation

// MARK: - Yandex Music · Now Playing (pure)
//
// Yandex Music's Mac app has no AppleScript dictionary, but it is an Electron app and publishes its
// track through `navigator.mediaSession`, which Chromium hands to macOS Now Playing. Since macOS 15.4
// only Apple's own processes may read MediaRemote, so Coucou asks `/usr/bin/osascript` (which is
// one) to read it from JavaScript for Automation. This file holds the two scripts and the parsing of
// what they print. Foundation only, no #if: the test script compiles it on its own.

/// What macOS says is playing right now, from whichever app owns Now Playing.
struct YandexMusicSnapshot: Equatable, Sendable {
    let bundleId: String
    let parentBundleId: String
    let appName: String
    let title: String
    let artist: String
    let album: String
    let duration: Double    // seconds, 0 = unknown
    let elapsed: Double     // seconds, as of `timestamp`
    let timestamp: Double   // unix seconds when `elapsed` was sampled, 0 = unknown
    let rate: Double
    let playing: Bool
    let contentId: String
}

/// One line printed by the watcher script.
enum YandexMusicHelperLine: Equatable, Sendable {
    case ready(available: Bool)
    case nothing                        // {"none":true}
    case snapshot(YandexMusicSnapshot)
}

enum YandexMusicNowPlaying {
    /// Desktop app, and the iPad app that runs on Apple silicon (unverified).
    static let bundleIds = ["ru.yandex.desktop.music", "ru.yandex.mobile.music"]

    /// Now Playing belongs to a single app at a time: is it Yandex Music? Electron may report the
    /// renderer helper (`ru.yandex.desktop.music.helper…`) with the app as its parent.
    static func isYandex(_ s: YandexMusicSnapshot) -> Bool {
        if bundleIds.contains(s.bundleId) || bundleIds.contains(s.parentBundleId) { return true }
        if s.bundleId.hasPrefix("ru.yandex.desktop.music.") { return true }
        return s.appName == "Яндекс Музыка" || s.appName == "Yandex Music"
    }

    // MARK: Parsing

    static func parse(line: String) -> YandexMusicHelperLine? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let ready = json["ready"] as? Bool, ready {
            return .ready(available: (json["available"] as? Bool) ?? false)
        }
        if let none = json["none"] as? Bool, none { return .nothing }

        func text(_ key: String) -> String { (json[key] as? String) ?? "" }
        func number(_ key: String) -> Double { (json[key] as? NSNumber)?.doubleValue ?? 0 }
        return .snapshot(YandexMusicSnapshot(
            bundleId: text("bundle"),
            parentBundleId: text("parent"),
            appName: text("name"),
            title: text("title"),
            artist: text("artist"),
            album: text("album"),
            duration: number("duration"),
            elapsed: number("elapsed"),
            timestamp: number("timestamp"),
            rate: number("rate"),
            playing: (json["playing"] as? Bool) ?? false,
            contentId: text("id")
        ))
    }

    /// Stable id for the track: the player's own content id, else a hash of what we can read.
    static func trackId(_ s: YandexMusicSnapshot) -> String {
        if !s.contentId.isEmpty { return s.contentId }
        // FNV-1a (64 bit): the same song gets the same id on every launch
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(s.artist)\u{1f}\(s.album)\u{1f}\(s.title)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hex = String(hash, radix: 16)
        return "yandex:" + String(repeating: "0", count: 16 - hex.count) + hex
    }

    // MARK: Metadata cleaners (same rules as Apple Music and Spotify)

    static func shortTitle(_ raw: String) -> String {
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

    static func shortArtist(_ raw: String) -> String {
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

    // MARK: Scripts

    /// Run as `osascript -l JavaScript -e <script> [once]`. Prints one JSON line when Now Playing
    /// changes (every line with `once`, then exits). Checks every 1 s while playing, 2 s otherwise,
    /// and quits when Coucou is gone (its parent becomes launchd).
    static let watchScript = #"""
    ObjC.import("Foundation");
    function run(argv) {
      const out = $.NSFileHandle.fileHandleWithStandardOutput;
      const say = (o) => out.writeData($(JSON.stringify(o) + "\n").dataUsingEncoding($.NSUTF8StringEncoding));
      const loaded = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
      const R = $.NSClassFromString("MRNowPlayingRequest");
      if (!loaded || R.isNil()) { say({ ready: true, available: false }); return; }
      ObjC.bindFunction("getppid", ["int", []]);
      const once = argv[0] === "once";
      if (!once) say({ ready: true, available: true });
      const str = (v) => (v === undefined || v === null || v.isNil()) ? "" : (ObjC.unwrap(v) || "");
      const num = (v) => (v === undefined || v === null || v.isNil()) ? 0 : (Number(ObjC.unwrap(v)) || 0);
      let last = "";
      while (true) {
        let o = { none: true };
        try {
          const item = R.localNowPlayingItem;
          const path = R.localNowPlayingPlayerPath;
          if (!item.isNil()) {
            const info = item.nowPlayingInfo;
            const client = path.isNil() ? null : path.client;
            const ok = client && !client.isNil();
            const ts = info.valueForKey("kMRMediaRemoteNowPlayingInfoTimestamp");
            o = {
              bundle: ok ? str(client.bundleIdentifier) : "",
              parent: ok ? str(client.parentApplicationBundleIdentifier) : "",
              name: ok ? str(client.displayName) : "",
              title: str(info.valueForKey("kMRMediaRemoteNowPlayingInfoTitle")),
              artist: str(info.valueForKey("kMRMediaRemoteNowPlayingInfoArtist")),
              album: str(info.valueForKey("kMRMediaRemoteNowPlayingInfoAlbum")),
              duration: num(info.valueForKey("kMRMediaRemoteNowPlayingInfoDuration")),
              elapsed: num(info.valueForKey("kMRMediaRemoteNowPlayingInfoElapsedTime")),
              timestamp: (ts === undefined || ts.isNil()) ? 0 : ts.timeIntervalSince1970,
              rate: num(info.valueForKey("kMRMediaRemoteNowPlayingInfoPlaybackRate")),
              playing: R.localIsPlaying === true,
              id: str(info.valueForKey("kMRMediaRemoteNowPlayingInfoContentItemIdentifier")),
            };
          }
        } catch (e) { o = { none: true }; }
        const s = JSON.stringify(o);
        if (once || s !== last) { say(o); last = s; }
        if (once || $.getppid() === 1) return;   // Coucou gone: quit
        delay(o.playing ? 1 : 2);
      }
    }
    """#

    /// Run as `osascript -l JavaScript -e <script> <command> <value> <bundle ids…>`, where command
    /// is play, pause, toggle, next, previous or seek. Prints ok, failed, unknown, unavailable or
    /// other. The bundle ids are a safety rule: a command only goes out when Yandex Music owns Now
    /// Playing, so it can never pause Spotify or another app by mistake.
    static let commandScript = #"""
    ObjC.import("Foundation");
    function run(argv) {   // argv: [command, value, ...allowedBundleIds]
      $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/").load;
      const R = $.NSClassFromString("MRNowPlayingRequest");
      if (R.isNil()) return "unavailable";
      const path = R.localNowPlayingPlayerPath;
      const client = path.isNil() ? null : path.client;
      const ok = client && !client.isNil();
      const bid = ok ? (ObjC.unwrap(client.bundleIdentifier) || "") : "";
      const parent = ok ? (ObjC.unwrap(client.parentApplicationBundleIdentifier) || "") : "";
      const ids = argv.slice(2);
      if (!ids.some((i) => bid === i || parent === i || bid.indexOf(i + ".") === 0)) return "other";
      ObjC.bindFunction("MRMediaRemoteSendCommand", ["bool", ["int", "id"]]);
      ObjC.bindFunction("MRMediaRemoteSetElapsedTime", ["void", ["double"]]);
      if (argv[0] === "seek") { $.MRMediaRemoteSetElapsedTime(Number(argv[1]) || 0); return "ok"; }
      const codes = { play: 0, pause: 1, toggle: 2, next: 4, previous: 5 };
      if (!(argv[0] in codes)) return "unknown";
      return $.MRMediaRemoteSendCommand(codes[argv[0]], $.NSDictionary.dictionary) ? "ok" : "failed";
    }
    """#
}
