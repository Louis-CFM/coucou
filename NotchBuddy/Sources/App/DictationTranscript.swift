import Foundation

/// The words of one dictation, kept whole when Apple's recognizer loses some of them
/// (tests/FlowKeyLogicTests.swift).
///
/// On a long dictation the recognizer can:
/// - start over after a pause: the next result holds only the new words;
/// - drop a stretch it had already given, in the middle of a later result.
/// Taken as is, either loses what was said. So each result is merged with the words seen before:
/// a result that looks like a fresh start closes the text so far, and a word heard earlier that no
/// newer word covers in time is kept where it was.
struct DictationTranscript: Equatable {
    /// One word (or a few) with its place in the audio, in seconds.
    struct Piece: Equatable, Sendable {
        var start: Double
        var end: Double
        var text: String
    }

    /// Text closed by a fresh start of the recognizer.
    private(set) var committed = ""
    /// The words of the stretch in progress.
    private(set) var pieces: [Piece] = []
    /// Their text: the recognizer's own (formatted) string, unless words had to be put back.
    private(set) var current = ""

    var text: String { Self.join(committed, current) }

    /// A newer word closer than this to an older one, in time, replaces it.
    static let tolerance = 0.25

    /// - Parameters:
    ///   - formatted: the result's text as the recognizer wrote it.
    ///   - pieces: its words with their times (all zero when the recognizer gives no times).
    mutating func absorb(_ formatted: String, pieces new: [Piece]) {
        if Self.isRestart(previous: current, new: formatted) {
            committed = Self.join(committed, current)
            pieces = new
            current = formatted
            return
        }
        let timed = !new.isEmpty && new.contains { $0.end > $0.start }
        guard timed, let last = new.last else {
            pieces = new
            current = formatted
            return
        }
        // Earlier words the new result left out, that no new word covers: put them back. Only words
        // that had a time of their own (partial results often come without), and never words the new
        // text already says (times can shift between results).
        let kept = pieces.filter { old in
            old.end > old.start
                && old.end <= last.start + Self.tolerance
                && !new.contains { Self.close(old, $0) }
        }
        let alreadySaid = !kept.isEmpty
            && Self.normalized(formatted).contains(Self.normalized(kept.map(\.text).joined(separator: " ")))
        if kept.isEmpty || alreadySaid {
            pieces = new
            current = formatted
        } else {
            pieces = (kept + new).sorted { $0.start < $1.start }
            current = pieces.map(\.text).joined(separator: " ")
        }
    }

    /// Plain text only (no times): a fresh start closes the text so far, anything else replaces it.
    mutating func absorb(_ formatted: String) { absorb(formatted, pieces: []) }

    /// A result is a fresh start when the text so far had a few words, the new one has less than half
    /// as many, and it does not start with the same word. A correction of the last words, or a
    /// recognizer that keeps everything, never looks like that.
    static func isRestart(previous: String, new: String) -> Bool {
        let p = previous.split(whereSeparator: \.isWhitespace)
        let n = new.split(whereSeparator: \.isWhitespace)
        guard p.count >= 3, !n.isEmpty, n.count * 2 <= p.count else { return false }
        return p[0].lowercased() != n[0].lowercased()
    }

    /// Lowercase letters and digits, single spaces: "Salut, Coucou !" → "salut coucou".
    static func normalized(_ s: String) -> String {
        let kept = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func close(_ a: Piece, _ b: Piece) -> Bool {
        a.start < b.end + tolerance && b.start < a.end + tolerance
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}
