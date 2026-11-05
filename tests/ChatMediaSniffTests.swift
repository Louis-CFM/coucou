import Foundation

// The type of a fetched file comes from its first bytes, never from its name or the server header.

@main
struct ChatMediaSniffTests {
    nonisolated(unsafe) static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
    static func pad(_ b: [UInt8], _ n: Int = 32) -> [UInt8] { b + [UInt8](repeating: 0, count: max(0, n - b.count)) }
    static let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]
    static func riff(_ tag: String) -> [UInt8] { bytes("RIFF") + [0x24, 0, 0, 0] + bytes(tag) }
    static let bmp: [UInt8] = bytes("BM") + [0x36, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0, 40, 0, 0, 0]

    static func main() {
        print("ChatMediaSniff")
        let f = ChatMediaSniff.format(of:)

        checkTrue("each magic number is accepted", {
            f(pad(png)) == .png && f(pad([0xFF, 0xD8, 0xFF, 0xE0])) == .jpeg && f(pad(bytes("GIF89a"))) == .gif
                && f(pad(riff("WEBP"))) == .webp && f(pad(riff("WAVE"))) == .wav && f(pad(riff("AVI "))) == .avi
                && f(pad(bmp)) == .bmp && f(pad(bytes("OggS"))) == .ogg && f(pad(bytes("fLaC"))) == .flac
                && f(pad(bytes("ID3"))) == .mp3 && f(pad([0xFF, 0xFB, 0x90, 0x00])) == .mp3
                && f(pad([0, 0, 0, 0x20] + bytes("ftypM4A "))) == .mp4 && f(pad([0x1A, 0x45, 0xDF, 0xA3])) == .matroska
                && f(pad(bytes("%PDF-1.7"))) == .pdf && f(pad(bytes("PK\u{03}\u{04}"))) == .zip
        }())
        checkTrue("an unknown file, and a file shorter than the header", {
            f(pad(bytes("<html><script>"))) == .unknown && f([]) == .unknown && f([0x89, 0x50]) == .unknown
                && f(bytes("OgS")) == .unknown && f(bytes("BM")) == .unknown
        }())
        checkTrue("a bare BM without a bitmap header is not a bitmap", f(pad(bytes("BM hello there, how are you"))) == .unknown)
        checkTrue("an ogg name with PNG bytes is demoted to a document", {
            let r = ChatMediaSniff.verifiedKind(claimed: .voice, head: pad(png))
            let a = ChatMediaSniff.verifiedKind(claimed: .audio, head: pad(png))
            return r.kind == .document && r.format == .png && a.kind == .document
        }())
        checkTrue("a png name with html or a script is demoted", {
            ["<!doctype html><script>alert(1)</script>", "#!/bin/sh\nrm -rf ~", "<svg onload=alert(1)>"].allSatisfy {
                ChatMediaSniff.verifiedKind(claimed: .image, head: pad(bytes($0))).kind == .document
            }
        }())
        checkTrue("a real file keeps its claimed kind", {
            ChatMediaSniff.verifiedKind(claimed: .image, head: pad(png)).kind == .image
                && ChatMediaSniff.verifiedKind(claimed: .voice, head: pad(bytes("OggS"))).kind == .voice
                && ChatMediaSniff.verifiedKind(claimed: .audio, head: pad([0, 0, 0, 0x20] + bytes("ftypM4A "))).kind == .audio
                && ChatMediaSniff.verifiedKind(claimed: .video, head: pad([0, 0, 0, 0x20] + bytes("ftypisom"))).kind == .video
        }())
        checkTrue("a zip named pdf is a document, as a zip", {
            let r = ChatMediaSniff.verifiedKind(claimed: .document, head: pad(bytes("PK\u{03}\u{04}")))
            return r.kind == .document && r.format == .zip && r.format.fileExtension == "zip"
        }())
        checkTrue("a video claim with image bytes is demoted; an image claim with audio bytes too", {
            ChatMediaSniff.verifiedKind(claimed: .video, head: pad(png)).kind == .document
                && ChatMediaSniff.verifiedKind(claimed: .image, head: pad(bytes("OggS"))).kind == .document
        }())
        // Aegis C8: the byte order mark of UTF-16 text is not an MP3 frame.
        checkTrue("a UTF-16 byte order mark is not MP3; real frames (MPEG 1 and 2, layers II and III) still are", {
            f(pad([0xFF, 0xFE, 0x61, 0x00, 0x2C, 0x00])) == .unknown && f(pad([0xFE, 0xFF, 0x00, 0x61])) == .unknown
                && f(pad([0xFF, 0xFB, 0x90, 0x00])) == .mp3 && f(pad([0xFF, 0xFA, 0x90, 0x00])) == .mp3
                && f(pad([0xFF, 0xF3, 0x90, 0x00])) == .mp3 && f(pad([0xFF, 0xFD, 0x90, 0x00])) == .mp3
        }())
        // Aegis B3: what the bytes of a file with no signature are as text.
        checkTrue("plain text: valid UTF-8 with no NUL is text, markup when it starts with <, anything else is binary", {
            let t = { (d: Data) in ChatMediaSniff.plainText(of: d) }
            return t(Data("a,b\n1,2\n".utf8)) == .text && t(Data("Olá, mundo — ✓".utf8)) == .text && t(Data()) == .text
                && t(Data("<html><script>alert(1)</script>".utf8)) == .markup && t(Data("  \n\t<svg onload=1>".utf8)) == .markup
                && t(Data([0xEF, 0xBB, 0xBF] + Array("<?xml version=\"1.0\"?>".utf8))) == .markup
                && t(Data([0x61, 0, 0x62])) == .binary && t(Data([0x61, 0xFF, 0x62])) == .binary
                && t(Data([0xFF, 0xFE, 0x61, 0x00])) == .binary && t(Data([0xC3])) == .binary && t(Data([0xED, 0xA0, 0x80])) == .binary
        }())
        checkTrue("the temporary extension is ours: nothing the system would run", {
            let all: [ChatMediaSniff.Format] = [.png, .jpeg, .gif, .webp, .bmp, .ogg, .mp3, .wav, .flac, .mp4, .matroska, .avi, .pdf, .zip, .unknown]
            let safe: Set<String> = ["png", "jpg", "gif", "webp", "bmp", "ogg", "mp3", "wav", "flac", "m4a", "mkv", "avi", "pdf", "zip", "bin"]
            return all.allSatisfy { safe.contains($0.fileExtension) }
        }())

        print(failures == 0 ? "\nAll ChatMediaSniff tests passed." : "\n\(failures) ChatMediaSniff test(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
