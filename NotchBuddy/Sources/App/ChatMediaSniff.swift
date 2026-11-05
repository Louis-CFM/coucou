import Foundation

// What a fetched file really is, decided from its first bytes. The name the agent gave and the type the server
// guessed are claims: a file that does not belong to the family its name claims is demoted to a plain document,
// which can be saved and never played or previewed. Pure, Foundation only, in both builds, no flag.

enum ChatMediaSniff {
    enum Format: Equatable {
        case png, jpeg, gif, webp, bmp
        case ogg, mp3, wav, flac
        case mp4          // the `ftyp` family: m4a audio and mp4 / mov video
        case matroska, avi
        case pdf, zip
        case unknown

        var isImage: Bool { [.png, .jpeg, .gif, .webp, .bmp].contains(self) }
        var isAudio: Bool { [.ogg, .mp3, .wav, .flac, .mp4].contains(self) }
        var isVideo: Bool { [.mp4, .matroska, .avi].contains(self) }

        /// The extension of the private temporary file: ours, never the agent's. Nothing the system would run.
        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .gif: return "gif"
            case .webp: return "webp"
            case .bmp: return "bmp"
            case .ogg: return "ogg"
            case .mp3: return "mp3"
            case .wav: return "wav"
            case .flac: return "flac"
            case .mp4: return "m4a"
            case .matroska: return "mkv"
            case .avi: return "avi"
            case .pdf: return "pdf"
            case .zip: return "zip"
            case .unknown: return "bin"
            }
        }
    }

    /// What the bytes of a file with no signature are, as text.
    enum PlainText: Equatable, Sendable {
        /// Not text: a NUL byte, or bytes that are not valid UTF-8 (UTF-16 text included).
        case binary
        /// Valid UTF-8 with no NUL.
        case text
        /// Text that starts with `<` (after white space and a byte order mark): markup a browser may draw.
        case markup
    }

    /// Reads a whole file (mapped, off the main actor in the store) and says what it is as text.
    static func plainText(of url: URL) -> PlainText {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return .binary }
        return plainText(of: data)
    }

    static func plainText(of data: Data) -> PlainText {
        if data.contains(0) { return .binary }
        guard let text = String(data: data, encoding: .utf8) else { return .binary }
        var head = text.unicodeScalars.prefix(512)[...]
        while let first = head.first, first == "\u{FEFF}" || first.properties.isWhitespace { head = head.dropFirst() }
        return head.first == "<" ? .markup : .text
    }

    /// How many bytes `format(of:)` needs to see.
    static let headBytes = 32

    static func format(of head: [UInt8]) -> Format {
        func starts(_ s: String, at i: Int = 0) -> Bool {
            let b = Array(s.utf8)
            return head.count >= i + b.count && Array(head[i..<(i + b.count)]) == b
        }
        if head.count >= 8, Array(head[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF { return .jpeg }
        if starts("GIF87a") || starts("GIF89a") { return .gif }
        if starts("RIFF"), head.count >= 12 {
            if starts("WEBP", at: 8) { return .webp }
            if starts("WAVE", at: 8) { return .wav }
            if starts("AVI ", at: 8) { return .avi }
        }
        if starts("BM"), head.count >= 18 {
            let dib = Int(head[14]) | Int(head[15]) << 8 | Int(head[16]) << 16 | Int(head[17]) << 24
            if [12, 40, 52, 56, 64, 108, 124].contains(dib) { return .bmp }
        }
        if starts("OggS") { return .ogg }
        if starts("fLaC") { return .flac }
        if starts("ID3") { return .mp3 }
        // `FF FE` is also the byte order mark of UTF-16 text, and the layer I frame it would be is not a file anyone has.
        if head.count >= 2, head[0] == 0xFF, head[1] != 0xFE, head[1] & 0xE0 == 0xE0, head[1] & 0x06 != 0 { return .mp3 }
        if starts("ftyp", at: 4) { return .mp4 }
        if head.count >= 4, Array(head[0..<4]) == [0x1A, 0x45, 0xDF, 0xA3] { return .matroska }
        if starts("%PDF-") { return .pdf }
        if starts("PK\u{03}\u{04}") || starts("PK\u{05}\u{06}") { return .zip }
        return .unknown
    }

    /// The kind the app may treat the file as, from what the agent claimed and what the bytes are. A claim the bytes do
    /// not support becomes `document`.
    static func verifiedKind(claimed: ChatAttachmentKind, head: [UInt8]) -> (kind: ChatAttachmentKind, format: Format) {
        let format = format(of: head)
        switch claimed {
        case .image: return (format.isImage ? .image : .document, format)
        case .voice: return (format.isAudio ? .voice : .document, format)
        case .audio: return (format.isAudio ? .audio : .document, format)
        case .video: return (format.isVideo ? .video : .document, format)
        case .document: return (.document, format)
        }
    }
}
