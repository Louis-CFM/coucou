import Foundation
import AVFoundation

// The audio player of a chat row: it must open and play an Ogg Opus voice note (the real format of a Hermes voice
// message), WAVE, and refuse what is not audio. Playback runs at volume 0; where the machine has no output (a CI runner)
// the play steps are reported as skipped, the open steps are not.

private let oggOpusBase64 = "T2dnUwACAAAAAAAAAADzCjMUAAAAANbe9xsBE09wdXNIZWFkAQE4AcBdAAAAAABPZ2dTAAAAAAAAAAAAAPMKMxQBAAAAGp22gwE+T3B1c1RhZ3MNAAAATGF2ZjYyLjEyLjEwMgEAAAAdAAAAZW5jb2Rlcj1MYXZjNjIuMjguMTAyIGxpYm9wdXNPZ2dTAAS4cQAAAAAAAPMKMxQCAAAAgsFX6R8oJzYgLC8xLy0vHyYnIiMlKCotKioqLzIkHjEzKSYlaIA92WXNTKZiuKxHhnB4Jt+NC+QkO2PpsmO3AOz4Rl50AV/vh7DZ+GiRZj7CSNgCoAQGRixTpVB5HptU/oiGBXpMLaey658QdgHloCuInGiDmEUHc6JAhVJzcb1UN2jT7sNLY40mX+CBQ1tPLFlkmKkUMEgDOtNYm8uyuHVo1b636Fzs9WixwAUafAs9XN3hAx+evMlNMnPUpa1TmpGssuHeww03aK4PUXdrzFEiRHL/EkCyp/rmA3JxPpbL2tLwWLgLFb9bRDUiREJ44iwx3Shoqre4mb9E5+/XkxX6vl4h55JvkDmmD+89oU4XdCxhZa0xCSmC3Xxmt3OyDrT2+mipmCzWMWcC7FNF+ZhXmsBcVPi5KAXpN/uLL2hKxwcPZSuGj3We9hl+vZOHqDFuSuZoq8jSiS7sZ35q2dJCnVEEA3QTT/zkNYdAePg/MSRmvV+6JbK9nNphGZJRQHo342is8OUaT1HjiUfJfovSmD14ESgcFSxBRxohcKqq5FwsTHLINC71qbfSf9SPp2itok/FRbesN0fRVkXOhuxt6qApeCCPTh4MrLqe3+uuR0S0rk90OLLaJjgXrMr8aLbbLViqLR4LyZQ/W4L9P50MrpVpIGQpek7aD3aIlWi2liLmJLreiYAKT5qtdBaqHh/nRf/JOuv3PQj+QV1aVz5YiFWHaLU5x6PF3mqBwR2uwbjAj7moc4thSfqZcvBrwxZJN27bgqdOZYlkaLXvb/RQEmhcPMZ76AqWfouO4HDFRnNpkadQwqAsLIp9bWi112f5coTPizf4EOgb87DfkRQlv68KGuhtq4YI9sjBfsESaLUV0cLXkxv94zvpCu48MDQAm1bUkJTAv+cSI/EVJ1v7gEST4Gi1YZ6AXRyEKChFLJfsb8wPs92KLIFkG3A4BxjUac6OBMvAXYNDtl9otu5wKSwbyx7KNosKyEEUtt6cF9JQ8dfYj8TDx24Mnpyzorxvr0oBlghottHU19ObT4S+CDC+5z1TNpmUwwNRbzkqi9Pv7X7GvOb++KOb3PpIXQ202BhotdMEhgUv9G5EzUhsBkvCPr3T1UzM81PcsaYZKfRYVDbuZ8XlHc82/fRosGu8H+cJfqn6kBKfoicUM3+vrKEa+4ITbC/yKPOvcA2F68D2BMkQrcVosOXLaUXiQjlrD0e1gnHo5xgY+XdS/sTePZBtcJauHzgAV0uURJ4O1uVos9E70HiLXct/VUbcw3/RF59pV3U6qJyRV4PCH42B5ohGkFNfh0otmsoC1x/Tz2ixbt99p10OFAVGQYDo1/ms6fulFU7N8HyNvV9Fqz9Do2ktR+oJJ1etWr6GaOsCcdfZaAV7rGiQqFxxw0fgLf8n2K3MYik57Z1VJKhGErZJFqZd7EPMaATaQ25ROGWq6yC0mK0TMmkR+5qvESegq7rwfjj9aIIu2upGv4zjbLCxraozer4ynTUxdhYuCtCwaFc71j08oO+FQx8TCE9JW2jmPPazDGi3+WWY6RVrFEOqSIg8lGphJ5XXS289VEtxb1s33Vk4ca4sak/lo/AmWGOth50LtUOQIWi5U57NxpxmU7ObTCZqHwhj6k/8peYeO4ZaBs1YBca4qxsyMCAkPehDaLiwQzmbRHI2DlU+6mFf651Nv14vDokgJwOnBqvMJVORz3cnenloBnFo8LPBAwmaetz+ithWwWVGm0B0qrDtcVeAkkqKF//tq06r"

@main
@MainActor
struct ChatMediaPlayerTests {
    static var failures = 0
    static var skipped = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func tempFile(_ name: String, _ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-player-\(UUID().uuidString)-" + name)
        try? data.write(to: url)
        return url
    }

    /// A 0.5 s mono 16 bit sine in a WAVE container.
    static func wav() -> Data {
        let rate = 24000, count = rate / 2
        var pcm = Data()
        for i in 0..<count {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
            pcm.append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
        }
        func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        func le16(_ n: Int) -> [UInt8] { (0..<2).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        var d = Data("RIFF".utf8) + Data(le32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + Data(le32(16))
        d += Data(le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)) + Data("data".utf8) + Data(le32(pcm.count)) + pcm
        return d
    }

    /// A WAVE of 8 bit PCM with that many channels at that rate and 2 frames (the block align is one byte per channel, so
    /// 65 535 channels still fit the 16 bit field): the shape of Aegis A1, a few KB that took the app down on Play.
    static func wideWav(channels: Int, rate: Int) -> Data {
        func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        func le16(_ n: Int) -> [UInt8] { (0..<2).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        let pcm = Data(repeating: 0x80, count: 2 * channels)
        var d = Data("RIFF".utf8) + Data(le32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + Data(le32(16))
        d += Data(le16(1) + le16(channels) + le32(rate) + le32(rate * channels) + le16(channels) + le16(8)) + Data("data".utf8) + Data(le32(pcm.count)) + pcm
        return d
    }

    /// A 0.5 s 16 bit stereo sine.
    static func stereoWav() -> Data {
        let rate = 24000, count = rate / 2
        var pcm = Data()
        for i in 0..<count {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate)))
            for _ in 0..<2 { pcm.append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)]) }
        }
        func le32(_ n: Int) -> [UInt8] { (0..<4).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        func le16(_ n: Int) -> [UInt8] { (0..<2).map { UInt8((n >> (8 * $0)) & 0xFF) } }
        var d = Data("RIFF".utf8) + Data(le32(36 + pcm.count)) + Data("WAVEfmt ".utf8) + Data(le32(16))
        d += Data(le16(1) + le16(2) + le32(rate) + le32(rate * 4) + le16(4) + le16(16)) + Data("data".utf8) + Data(le32(pcm.count)) + pcm
        return d
    }

    static func crc8(_ d: [UInt8]) -> UInt8 { var c: UInt8 = 0; for b in d { c ^= b; for _ in 0..<8 { c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : c << 1 } }; return c }
    static func crc16(_ d: [UInt8]) -> UInt16 { var c: UInt16 = 0; for b in d { c ^= UInt16(b) << 8; for _ in 0..<8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x8005 : c << 1 } }; return c }

    /// A tiny valid mono 16 bit FLAC (one silent frame) whose STREAMINFO claims `totalSamples` samples at `rate`: what a
    /// crafted file looks like (Aegis M1 used a real 8 MB silent file of 11 200 s at 384 kHz).
    static func flac(rate: UInt64, totalSamples: UInt64) -> Data {
        var d: [UInt8] = Array("fLaC".utf8) + [0x80, 0, 0, 34] + [0x10, 0x00, 0x10, 0x00] + [0, 0, 0, 0, 0, 0]
        let packed: UInt64 = (rate << 44) | (15 << 36) | totalSamples
        for i in 0..<8 { d.append(UInt8((packed >> UInt64(56 - 8 * i)) & 0xFF)) }
        d += [UInt8](repeating: 0, count: 16)
        var frame: [UInt8] = [0xFF, 0xF8, 0xC0, 0x08, 0x00]
        frame.append(crc8(frame))
        frame += [0x00, 0x00, 0x00]
        let c = crc16(frame)
        frame += [UInt8(c >> 8), UInt8(c & 0xFF)]
        return Data(d + frame)
    }

    static func waitUntil(_ timeout: Double, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return cond()
    }

    static func main() async {
        print("ChatMediaPlayer")
        let ogg = tempFile("voice.ogg", Data(base64Encoded: oggOpusBase64)!)
        let wavURL = tempFile("tone.wav", wav())
        let junk = tempFile("junk.ogg", Data("<html><script>alert(1)</script>".utf8))
        let empty = tempFile("empty.wav", Data())
        defer { for u in [ogg, wavURL, junk, empty] { try? FileManager.default.removeItem(at: u) } }

        // What AVAudioPlayer does with the same Ogg Opus file on this machine, for the record.
        let legacy = try? AVAudioPlayer(contentsOf: ogg)
        print("  info AVAudioPlayer on the Ogg Opus file: opened \(legacy != nil), duration \(legacy?.duration ?? 0) s, prepareToPlay \(legacy?.prepareToPlay() ?? false)")

        // Ogg Opus needs the system to read it. Where it cannot (an older macOS, a CI image), the check says so instead
        // of failing: the app then shows a document row with Save, which is the fallback built for exactly that.
        if (try? AVAudioFile(forReading: ogg)) == nil {
            print("  skip 01 an Ogg Opus voice note opens: unsupported here (AVAudioFile cannot open a known good Ogg Opus file on this OS)")
            skipped += 1
            checkTrue("01b ...and the player agrees: it refuses the file, so the row becomes a document", ChatMediaPlayer.probe(ogg) == nil)
        } else {
            checkTrue("01 an Ogg Opus voice note opens and has a duration", {
                guard let d = ChatMediaPlayer.probe(ogg) else { return false }
                return d > 0.5 && d < 0.7
            }())
        }
        checkTrue("02 a WAVE file opens", { (ChatMediaPlayer.probe(wavURL) ?? 0) > 0.45 }())
        checkTrue("03 html named .ogg, an empty file and a missing file do not open", {
            ChatMediaPlayer.probe(junk) == nil && ChatMediaPlayer.probe(empty) == nil
                && ChatMediaPlayer.probe(URL(fileURLWithPath: "/nonexistent/x.ogg")) == nil
        }())

        // Aegis M1: a header that claims more frames than the engine counts crashed the app on Play.
        let huge = tempFile("huge.flac", flac(rate: 384_000, totalSamples: 4_300_800_000))
        let twoHours = tempFile("2h.flac", flac(rate: 48_000, totalSamples: 48_000 * 7_199))
        let overTwoHours = tempFile("3h.flac", flac(rate: 48_000, totalSamples: 48_000 * 7_201))
        let sane = tempFile("sane.flac", flac(rate: 48_000, totalSamples: 48_000 * 2))
        defer { for u in [huge, twoHours, overTwoHours, sane] { try? FileManager.default.removeItem(at: u) } }
        checkTrue("11 a file whose frame count does not fit the engine (4.3 billion frames at 384 kHz) is refused at open", {
            ChatMediaPlayer(url: huge) == nil && ChatMediaPlayer.probe(huge) == nil
        }())
        checkTrue("12 a sane crafted FLAC opens (the crafted header is valid), and the 2 hour cap is exact", {
            guard let d = ChatMediaPlayer.probe(sane), abs(d - 2) < 0.01 else { return false }
            guard let long = ChatMediaPlayer.probe(twoHours), abs(long - 7_199) < 0.01 else { return false }
            return ChatMediaPlayer.probe(overTwoHours) == nil
        }())
        checkTrue("13 the playable policy, pure", {
            let p = ChatMediaPlayer.isPlayable
            return p(48_000, 48_000) && p(345_600_000, 48_000) && !p(345_600_001, 48_000) && !p(0, 48_000) && !p(-5, 48_000)
                && !p(100, 0) && !p(100, .infinity) && !p(100, .nan)
                && !p(Int64(UInt32.max) + 1, 1_000_000) && !p(4_300_800_000, 384_000) && p(Int64(UInt32.max), 1_000_000)
        }())
        if let long = ChatMediaPlayer(url: twoHours) {
            long.volume = 0
            if long.play() {
                checkTrue("14 a file just under 2 hours starts without a trap (checked frame count) and stops", long.isPlaying)
                long.stop()
            } else {
                print("  skip 14 no audio output here")
                skipped += 1
            }
        }

        // Aegis A1: a format the engine dislikes is an Objective-C exception that ends the process. Only ordinary formats
        // (1 to 8 channels, 8 000 to 192 000 Hz, standard PCM) reach the engine; everything else is a document.
        checkTrue("15 the ordinary format policy, pure", {
            let ok = ChatMediaPlayer.isOrdinary
            return ok(1, 24_000, true) && ok(2, 44_100, true) && ok(8, 192_000, true) && ok(1, 8_000, true)
                && !ok(0, 24_000, true) && !ok(9, 24_000, true) && !ok(1025, 24_000, true) && !ok(65_535, 24_000, true)
                && !ok(1, 7_999, true) && !ok(1, 192_001, true) && !ok(1, 1, true) && !ok(1, 1_000_000, true)
                && !ok(1, .nan, true) && !ok(1, .infinity, true) && !ok(1, 24_000, false)
        }())
        var wide: [(String, URL)] = []
        for channels in [9, 1025, 65_535] { wide.append(("\(channels) channels", tempFile("wide\(channels).wav", wideWav(channels: channels, rate: 8000)))) }
        for rate in [1, 1_000_000] { wide.append(("\(rate) Hz", tempFile("rate\(rate).wav", wideWav(channels: 1, rate: rate)))) }
        defer { for (_, u) in wide { try? FileManager.default.removeItem(at: u) } }
        for (label, url) in wide {
            let opens = (try? AVAudioFile(forReading: url)) != nil
            print("  info \(label): AVAudioFile opens the file: \(opens)")
            checkTrue("16 a WAVE of \(label) is refused at open and never reaches the engine", ChatMediaPlayer(url: url) == nil && ChatMediaPlayer.probe(url) == nil)
        }
        let stereoURL = tempFile("stereo.wav", stereoWav())
        defer { try? FileManager.default.removeItem(at: stereoURL) }
        checkTrue("17 a one channel and a two channel file are still accepted", ChatMediaPlayer(url: wavURL) != nil && ChatMediaPlayer(url: stereoURL) != nil)
        for (name, url) in [("mono", wavURL), ("stereo", stereoURL)] {
            guard let p = ChatMediaPlayer(url: url) else { continue }
            p.volume = 0
            if p.play() {
                checkTrue("17b the \(name) file plays", p.isPlaying)
                p.stop()
            } else {
                print("  skip 17b \(name): no audio output here")
                skipped += 1
            }
        }
        checkTrue("18 the shim returns true for a block that runs and false for an Objective-C exception, and the process lives", {
            var ran = false
            let ok = CoucouTry { ran = true }
            let caught = CoucouTry { NSException(name: .invalidArgumentException, reason: "test", userInfo: nil).raise() }
            return ok && ran && !caught
        }())

        for (name, url) in [("Ogg Opus", ogg), ("WAVE", wavURL)] {
            guard let player = ChatMediaPlayer(url: url) else {
                if name == "WAVE" { checkTrue("04 \(name) player", false) } else { print("  skip 04 \(name) player: unsupported here"); skipped += 1 }
                continue
            }
            player.volume = 0
            final class Done: @unchecked Sendable { var finished = false }
            let done = Done()
            player.onFinish = { done.finished = true }
            guard player.play() else {
                print("  skip \(name): no audio output here (play returned false)")
                skipped += 1
                continue
            }
            checkTrue("05 \(name) plays", player.isPlaying)
            let moved = await waitUntil(1.0) { player.currentTime > 0.05 }
            checkTrue("06 \(name): the position moves while it plays", moved)
            player.pause()
            let held = player.currentTime
            checkTrue("07 \(name): pause keeps the position and stops the clock", !player.isPlaying && held > 0.05)
            try? await Task.sleep(nanoseconds: 250_000_000)
            checkTrue("08 \(name): nothing moves while paused", player.currentTime == held)
            player.play()
            let resumed = await waitUntil(1.0) { player.currentTime > held + 0.05 || done.finished }
            checkTrue("09 \(name): it resumes from where it stopped", resumed)
            let ended = await waitUntil(3.0) { done.finished }
            checkTrue("10 \(name): it ends by itself, back at 0, not playing", ended && !player.isPlaying && player.currentTime == 0)
            player.stop()
        }

        print(failures == 0 ? "\nAll ChatMediaPlayer tests passed\(skipped > 0 ? " (play steps skipped: \(skipped))" : "")." : "\n\(failures) ChatMediaPlayer test(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
