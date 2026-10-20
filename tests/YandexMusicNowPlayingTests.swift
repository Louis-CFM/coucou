import Foundation

@main
enum YandexMusicNowPlayingTests {

    static var failures = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got)")
            print("    expected: \(expected)")
            failures += 1
        }
    }

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func snapshot(bundle: String = "ru.yandex.desktop.music", parent: String = "",
                         name: String = "", title: String = "Song", artist: String = "Artist",
                         album: String = "Album", id: String = "") -> YandexMusicSnapshot {
        YandexMusicSnapshot(bundleId: bundle, parentBundleId: parent, appName: name,
                            title: title, artist: artist, album: album,
                            duration: 200, elapsed: 10, timestamp: 1_700_000_000, rate: 1,
                            playing: true, contentId: id)
    }

    static func main() {
        // ── parse ──────────────────────────────────────────────────────────────
        print("YandexMusicNowPlaying.parse")
        check("ready, available",     YandexMusicNowPlaying.parse(line: #"{"ready":true,"available":true}"#),
              .ready(available: true))
        check("ready, unavailable",   YandexMusicNowPlaying.parse(line: #"{"ready":true,"available":false}"#),
              .ready(available: false))
        check("nothing playing",      YandexMusicNowPlaying.parse(line: #"{"none":true}"#), .nothing)

        let full = #"{"bundle":"ru.yandex.desktop.music","parent":"","name":"Яндекс Музыка","title":"Песня","artist":"Исполнитель","album":"Альбом","duration":201.5,"elapsed":12.25,"timestamp":1700000000.5,"rate":1,"playing":true,"id":"abc-1"}"#
        check("full snapshot", YandexMusicNowPlaying.parse(line: full),
              .snapshot(YandexMusicSnapshot(
                bundleId: "ru.yandex.desktop.music", parentBundleId: "", appName: "Яндекс Музыка",
                title: "Песня", artist: "Исполнитель", album: "Альбом",
                duration: 201.5, elapsed: 12.25, timestamp: 1_700_000_000.5, rate: 1,
                playing: true, contentId: "abc-1")))
        check("missing keys default", YandexMusicNowPlaying.parse(line: #"{"title":"Only"}"#),
              .snapshot(YandexMusicSnapshot(
                bundleId: "", parentBundleId: "", appName: "", title: "Only", artist: "", album: "",
                duration: 0, elapsed: 0, timestamp: 0, rate: 0, playing: false, contentId: "")))
        check("garbage is nil",       YandexMusicNowPlaying.parse(line: "not json"), nil)
        check("empty line is nil",    YandexMusicNowPlaying.parse(line: ""), nil)
        check("json array is nil",    YandexMusicNowPlaying.parse(line: "[1,2]"), nil)

        // ── isYandex ───────────────────────────────────────────────────────────
        print("\nYandexMusicNowPlaying.isYandex")
        checkTrue("desktop bundle id",      YandexMusicNowPlaying.isYandex(snapshot()))
        checkTrue("iPad app bundle id",     YandexMusicNowPlaying.isYandex(snapshot(bundle: "ru.yandex.mobile.music")))
        checkTrue("helper-suffixed id",     YandexMusicNowPlaying.isYandex(snapshot(bundle: "ru.yandex.desktop.music.helper")))
        checkTrue("parent bundle id",       YandexMusicNowPlaying.isYandex(snapshot(bundle: "com.other.helper", parent: "ru.yandex.desktop.music")))
        checkTrue("display name, Russian",  YandexMusicNowPlaying.isYandex(snapshot(bundle: "", name: "Яндекс Музыка")))
        checkTrue("display name, English",  YandexMusicNowPlaying.isYandex(snapshot(bundle: "", name: "Yandex Music")))
        checkTrue("Spotify is not Yandex",  !YandexMusicNowPlaying.isYandex(snapshot(bundle: "com.spotify.client", name: "Spotify")))
        checkTrue("Apple Music is not",     !YandexMusicNowPlaying.isYandex(snapshot(bundle: "com.apple.Music", name: "Music")))
        checkTrue("other Yandex app is not", !YandexMusicNowPlaying.isYandex(snapshot(bundle: "ru.yandex.desktop.disk", name: "Яндекс Диск")))

        // ── trackId ────────────────────────────────────────────────────────────
        print("\nYandexMusicNowPlaying.trackId")
        check("content id wins",       YandexMusicNowPlaying.trackId(snapshot(id: "abc-1")), "abc-1")
        let hashed = YandexMusicNowPlaying.trackId(snapshot())
        checkTrue("hash has prefix and 16 hex digits",
                  hashed.hasPrefix("yandex:") && hashed.dropFirst(7).count == 16
                  && hashed.dropFirst(7).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        check("hash is stable",        YandexMusicNowPlaying.trackId(snapshot()), hashed)
        checkTrue("title changes it",  YandexMusicNowPlaying.trackId(snapshot(title: "Other")) != hashed)
        checkTrue("artist changes it", YandexMusicNowPlaying.trackId(snapshot(artist: "Other")) != hashed)
        checkTrue("album changes it",  YandexMusicNowPlaying.trackId(snapshot(album: "Other")) != hashed)
        checkTrue("fields don't blur", YandexMusicNowPlaying.trackId(snapshot(title: "ab", artist: "c"))
                  != YandexMusicNowPlaying.trackId(snapshot(title: "b", artist: "ac")))

        // ── shortTitle / shortArtist ───────────────────────────────────────────
        print("\nYandexMusicNowPlaying.shortTitle")
        check("cut at ' - '",        YandexMusicNowPlaying.shortTitle("Песня - Remastered 2011"), "Песня")
        check("strip (…)",           YandexMusicNowPlaying.shortTitle("Песня (Live)"), "Песня")
        check("strip […]",           YandexMusicNowPlaying.shortTitle("Song [Deluxe]"), "Song")
        check("strip both groups",   YandexMusicNowPlaying.shortTitle("Song (Live) [Remix]"), "Song")
        check("dash then group",     YandexMusicNowPlaying.shortTitle("Песня - Remastered (Live)"), "Песня")
        check("only a group stays",  YandexMusicNowPlaying.shortTitle("(Intro)"), "(Intro)")
        check("plain title stays",   YandexMusicNowPlaying.shortTitle("Just a Song"), "Just a Song")
        check("empty stays empty",   YandexMusicNowPlaying.shortTitle(""), "")

        print("\nYandexMusicNowPlaying.shortArtist")
        check("feat.",               YandexMusicNowPlaying.shortArtist("A feat. B"), "A")
        check("ft., any case",       YandexMusicNowPlaying.shortArtist("A Ft. B"), "A")
        check("plain artist stays",  YandexMusicNowPlaying.shortArtist("Земфира"), "Земфира")
        check("empty stays empty",   YandexMusicNowPlaying.shortArtist(""), "")

        // ── scripts ────────────────────────────────────────────────────────────
        print("\nScripts")
        checkTrue("watch script prints and quits with 'once'",
                  YandexMusicNowPlaying.watchScript.contains(#"argv[0] === "once""#)
                  && YandexMusicNowPlaying.watchScript.contains("getppid"))
        checkTrue("command script checks the bundle ids",
                  YandexMusicNowPlaying.commandScript.contains("argv.slice(2)")
                  && YandexMusicNowPlaying.commandScript.contains(#"return "other""#))

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
