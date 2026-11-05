import Foundation

// What an agent writes when it wants to hand over a file: a line `MEDIA:/path` and the tags `[[audio_as_voice]]` and
// `[[as_document]]` (the Hermes gateways read them and upload the file; the text is only an instruction). This file
// finds them in an answer so the chat can draw a row instead of the raw text. Foundation only, in both builds, no flag.
//
// Display time only: the stored text and the history sent back to the server are never touched. Nothing here is
// stored, logged or sent, and nothing is fetched: the path is a claim of the agent, read as untrusted text.
//
// Coucou accepts a deliberate, deterministic subset of what the gateways accept (the app cannot ask whether a file
// exists): `MEDIA:` in upper case only; a path that starts with `/`, `~/`, `X:\` or `X:/`; a known extension, or the tag
// alone on its line. What does not fit stays text, so a line that was not a directive is never hidden.

enum ChatAttachmentKind: Equatable { case voice, audio, image, video, document }

enum ChatAttachmentSource: Equatable {
    /// A path on the machine of the agent.
    case agentPath(String)
    /// A web address the agent named. Never fetched by the app: a click goes through the link rules.
    case remote(String)
}

struct ChatAttachment: Equatable, Identifiable {
    let id: Int                        // position in the text, in order of appearance: stable while the text streams
    let kind: ChatAttachmentKind
    let source: ChatAttachmentSource
    let name: String                   // last path component, cleaned for display only
}

struct ChatMediaExtraction: Equatable {
    /// The text with every recognised directive removed.
    var text: String
    var attachments: [ChatAttachment]
    /// The same text with one line `slotLine(id)` where each directive was, each between blank lines: what the card
    /// parses, so a row sits exactly where the directive sat.
    var marked: String
}

enum ChatMediaDirectives {
    // Same list as the Hermes gateways, `MEDIA_DELIVERY_EXTS` in gateway/platforms/base.py.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "3gp"]
    static let audioExtensions: Set<String> = ["mp3", "m2a", "wav", "ogg", "opus", "m4a", "flac"]
    static let otherExtensions: Set<String> = [
        "tiff", "svg", "pdf", "docx", "doc", "odt", "rtf", "txt", "md", "epub", "xlsx", "xls", "ods", "csv", "tsv", "json",
        "xml", "yaml", "yml", "kmz", "kml", "geojson", "gpx", "pptx", "ppt", "odp", "key", "zip", "tar", "gz", "tgz", "bz2",
        "xz", "7z", "rar", "apk", "ipa", "html", "htm",
    ]
    fileprivate static let knownExtensions = imageExtensions.union(videoExtensions).union(audioExtensions).union(otherExtensions)

    static let maxPathChars = 1024
    static let maxNameChars = 120
    /// The longest extension of the known list (`geojson`).
    static let maxExtensionLength = 7
    /// What one answer may turn into rows; further directives stay text. And how many `MEDIA:` keywords are examined at
    /// most per line and per text, so no input can make the scan long (the rest of the line or text stays as it is).
    static let maxAttachments = 12
    static let maxCandidatesPerLine = 24
    static let maxCandidatesPerText = 64
    /// A text longer than this (UTF-8 bytes) is shown as it is: the cap on characters alone leaves megabytes of
    /// combining marks, and no answer that hands over a file is this long.
    static let maxTextBytes = 1 << 20

    static func isKnownExtension(_ ext: String) -> Bool { knownExtensions.contains(ext.lowercased()) }

    /// Characters that end a bare path after its extension (the gateway lookahead), besides white space.
    private static let boundaryChars: Set<Character> = Set("`\"'*_,;:)]}[").union(Set("（）〈〉《》：，。；！？、\u{201C}\u{201D}\u{2018}\u{2019}【】"))
    private static let wrapChars: Set<Character> = ["\"", "'", "*", "_"]
    private static let mediaTag = Array("MEDIA:")
    private static let voiceTag = Array("[[audio_as_voice]]")
    private static let documentTag = Array("[[as_document]]")
    private static let eos = Array("<|eos|>")

    // MARK: Slot lines

    /// The line of the marked text that stands for attachment `id`. Private use characters: the agent text is cleaned
    /// of them first, so a slot line can only come from here.
    static func slotLine(_ id: Int) -> String { "\u{E000}\(id)\u{E001}" }

    static func slotID(of line: String) -> Int? {
        guard line.hasPrefix("\u{E000}"), line.hasSuffix("\u{E001}") else { return nil }
        return Int(line.dropFirst().dropLast())
    }

    // MARK: Extraction

    private struct Found {
        var path: String
        var isRemote: Bool
        var forcedDocument: Bool
    }

    private enum Entry {
        case line(String)
        case drop
        case slot(Int)
    }

    /// What the whole text has used so far: the keywords examined, the rows made and the paths already seen.
    private struct Budget {
        var candidates = 0
        var attachments = 0
        var seen = Set<String>()
    }

    /// A span of inline code on one line. `crossing`: the span goes on over a line break.
    private struct CodeSpan {
        var range: Range<Int>
        var crossing: Bool
    }

    /// The same text and the same answer: computed once and shared by the card, the layout and the ticker. A handful of
    /// the latest texts is enough (one answer streams, a few others are on screen). Compared by value, never hashed.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(text: String, streaming: Bool, value: ChatMediaExtraction)] = []
        private var count = 0

        var computations: Int { lock.withLock { count } }

        func value(_ text: String, streaming: Bool) -> ChatMediaExtraction {
            let hit: ChatMediaExtraction? = lock.withLock {
                // The bytes, not Swift's `==`: that one treats canonically equivalent texts as equal, and two different
                // paths (U+F900 and U+8C48) would share an entry.
                guard let at = entries.firstIndex(where: { $0.streaming == streaming && ChatMediaDirectives.sameBytes($0.text, text) })
                else { return nil }
                let entry = entries.remove(at: at)
                entries.insert(entry, at: 0)
                return entry.value
            }
            if let hit { return hit }
            let value = ChatMediaDirectives.extract(text, streaming: streaming)
            lock.withLock {
                count += 1
                entries.insert((text, streaming, value), at: 0)
                if entries.count > 6 { entries.removeLast() }
            }
            return value
        }
    }

    private static let cache = Cache()

    /// The same UTF-8 bytes, one `memcmp` for a native string.
    private static func sameBytes(_ a: String, _ b: String) -> Bool {
        guard a.utf8.count == b.utf8.count else { return false }
        let fast: Bool? = a.utf8.withContiguousStorageIfAvailable { pa in
            b.utf8.withContiguousStorageIfAvailable { pb in memcmp(pa.baseAddress, pb.baseAddress, pa.count) == 0 }
        } ?? nil
        return fast ?? a.utf8.elementsEqual(b.utf8)
    }

    /// How many extractions were really computed (not served from the cache). For the tests.
    static var cacheComputations: Int { cache.computations }

    /// `extract`, remembered for the latest texts: the card, the layout of the turn and the ticker all ask for the same
    /// text. A text with no `MEDIA:`, `[[` or slot character is not remembered (it costs one scan), except a streaming
    /// one that ends in a character that could start one, which is computed and remembered like any other.
    static func extractCached(_ input: String, streaming: Bool) -> ChatMediaExtraction {
        guard input.utf8.count <= maxTextBytes, mayCarryDirectives(input, streaming: streaming) else { return ChatMediaExtraction(text: input, attachments: [], marked: input) }
        return cache.value(input, streaming: streaming)
    }

    /// One pass over the bytes: a `MEDIA:` or a `[[`, a private use slot character, or (streaming) a last character that
    /// could start one.
    private static func mayCarryDirectives(_ input: String, streaming: Bool) -> Bool {
        let found: Bool? = input.utf8.withContiguousStorageIfAvailable { b -> Bool in
            let n = b.count
            var i = 0
            while i < n {
                let byte = b[i]
                if byte == 0x4D, i + 5 < n, b[i + 1] == 0x45, b[i + 2] == 0x44, b[i + 3] == 0x49, b[i + 4] == 0x41, b[i + 5] == 0x3A { return true }
                if byte == 0x5B, i + 1 < n, b[i + 1] == 0x5B { return true }
                if byte == 0xEE, i + 2 < n, b[i + 1] == 0x80, b[i + 2] == 0x80 || b[i + 2] == 0x81 { return true }
                i += 1
            }
            return false
        }
        if found == true { return true }
        if found == nil, input.contains("MEDIA:") || input.contains("[[") { return true }
        return streaming && (input.last.map { "MEDIA:[".contains($0) } ?? false)
    }

    /// Whether a line has anything this parser could act on, looked at in one pass over its bytes.
    private static func lineMayHaveTag(_ line: String) -> Bool {
        let found: Bool? = line.utf8.withContiguousStorageIfAvailable { b -> Bool in
            let n = b.count
            var i = 0
            while i < n {
                let byte = b[i]
                if byte == 0x5B { return true }
                if byte == 0x4D, i + 5 < n, b[i + 1] == 0x45, b[i + 2] == 0x44, b[i + 3] == 0x49, b[i + 4] == 0x41, b[i + 5] == 0x3A { return true }
                i += 1
            }
            return false
        }
        return found ?? (line.contains("MEDIA:") || line.contains("["))
    }

    /// `streaming`: the text is still arriving. On its last line only, a complete `MEDIA:` that can still become a path
    /// and everything after it is held back (a row never appears with half a path), and so is a suffix that could still
    /// grow into one of the tags.
    static func extract(_ input: String, streaming: Bool) -> ChatMediaExtraction {
        guard input.utf8.count <= maxTextBytes, mayCarryDirectives(input, streaming: streaming) else { return ChatMediaExtraction(text: input, attachments: [], marked: input) }

        var text = input.utf8.contains(13)
            ? input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : input
        // The slot characters belong to this parser: none that the agent wrote survives, so a slot line can only come
        // from here.
        var cleanedSlots = false
        if text.utf8.contains(0xEE), text.unicodeScalars.contains(where: { $0.value == 0xE000 || $0.value == 0xE001 }) {
            text = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value != 0xE000 && $0.value != 0xE001 }))
            cleanedSlots = true
        }
        let plain = ChatMediaExtraction(text: cleanedSlots ? text : input, attachments: [], marked: cleanedSlots ? text : input)
        let lines = text.components(separatedBy: "\n")
        let mask = ChatMarkdown.codeLineMask(lines)

        var entries: [Entry] = []
        var attachments: [(found: Found, id: Int)] = []
        var budget = Budget()
        var paragraphs = Paragraphs(lines: lines, mask: mask)
        var voice = false, asDocument = false, changed = false
        // While the text streams, the paragraph that holds the end of it is not finished: a later line can turn an
        // earlier one into a table row or close a code span over it. A tag there is neither text nor a row until the
        // paragraph is complete, so a row never appears and then goes back to text.
        let open = streaming ? paragraphs.openParagraph : -1

        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            let skip = mask[index] || isQuoteLine(line) || isTableRow(line) || paragraphs.inTable(index)
            let hold = streaming && isLast && !skip
            guard !skip, budget.candidates < maxCandidatesPerText, lineMayHaveTag(line) || hold else { entries.append(.line(line)); continue }
            let result = process(Array(line), hold: hold, rows: paragraphs.id[index] != open || open < 0,
                                 spans: paragraphs.spans(of: index), budget: &budget)
            guard result.changed else { entries.append(.line(line)); continue }
            changed = true
            voice = voice || result.voice
            asDocument = asDocument || result.document
            var rest = String(result.rest)
            while let last = rest.last, last.isWhitespace { rest.removeLast() }
            if rest.allSatisfy(\.isWhitespace) || isBareListMarker(rest) { rest = "" }
            entries.append(rest.isEmpty ? .drop : .line(rest))
            for found in result.found {
                let id = attachments.count
                attachments.append((found, id))
                entries.append(.slot(id))
            }
        }
        guard changed else { return plain }

        let finished = attachments.map { item -> ChatAttachment in
            let base = baseKind(of: item.found)
            var kind = base
            if base == .audio && voice { kind = .voice }
            if base == .image && asDocument { kind = .document }
            if item.found.forcedDocument { kind = .document }
            return ChatAttachment(id: item.id, kind: kind,
                                  source: item.found.isRemote ? .remote(item.found.path) : .agentPath(item.found.path),
                                  name: displayName(of: item.found.path))
        }
        return ChatMediaExtraction(text: render(entries, withSlots: false), attachments: finished,
                                   marked: render(entries, withSlots: true))
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.drop(while: { $0 == " " }).hasPrefix(">")
    }

    /// A line that starts with a pipe is a row of a table: a tag in a cell stays text (taking it out would split the
    /// table). Rows without a leading pipe are found through the delimiter line of their paragraph (`Paragraphs`).
    private static func isTableRow(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("|")
    }

    /// A list marker (bullet, number, task box) with nothing after it: what a removal can leave behind.
    private static func isBareListMarker(_ text: String) -> Bool {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        if let first = t.first, "-*+".contains(first) {
            t = t.dropFirst()
        } else {
            let digits = t.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count <= 9, let mark = t.dropFirst(digits.count).first, mark == "." || mark == ")" else { return false }
            t = t.dropFirst(digits.count + 1)
        }
        guard t.isEmpty || t.first == " " else { return false }
        let rest = t.trimmingCharacters(in: .whitespaces)
        return rest.isEmpty || rest == "[ ]" || rest == "[x]" || rest == "[X]"
    }

    private static func baseKind(of found: Found) -> ChatAttachmentKind {
        if found.forcedDocument { return .document }
        let ext = extensionOf(found.path)
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        return .document
    }

    /// The lines after the removals: a run of blank lines that touches a removal collapses to one, and at the start or
    /// the end of the text to none. Blank lines elsewhere are kept as they are. With slots, each slot line sits alone
    /// between blank lines.
    private static func render(_ entries: [Entry], withSlots: Bool) -> String {
        var out: [String] = []
        var blanks = 0
        var touched = false
        var forced = false
        func flush(beforeContent: Bool) {
            if touched {
                // A run that held blank lines keeps one; a removed line between two lines of one paragraph leaves none.
                if beforeContent && !out.isEmpty && (blanks > 0 || forced) { out.append("") }
            } else {
                out.append(contentsOf: [String](repeating: "", count: blanks))
            }
            blanks = 0
            touched = false
            forced = false
        }
        for entry in entries {
            switch entry {
            case .line(let s):
                if s.allSatisfy(\.isWhitespace) { blanks += 1 } else { flush(beforeContent: true); out.append(s) }
            case .drop:
                touched = true
            case .slot(let id):
                touched = true
                if withSlots {
                    forced = true
                    flush(beforeContent: true)
                    out.append(slotLine(id))
                    touched = true
                    forced = true
                }
            }
        }
        flush(beforeContent: false)
        return out.joined(separator: "\n")
    }

    // MARK: Paragraphs (inline code can go over a line break)

    /// The paragraphs of the text (runs of lines with no blank line, fence or quote between them), and the spans of
    /// inline code found over each paragraph as a whole, so a span that opens on one line and closes on the next covers
    /// the tags in between. Built only for a paragraph that a line needing the parser belongs to.
    private struct Paragraphs {
        let lines: [String]
        var id: [Int] = []
        var ranges: [Range<Int>] = []
        var table: [Bool] = []
        var built: [Int: [[CodeSpan]]] = [:]

        init(lines: [String], mask: [Bool]) {
            self.lines = lines
            var current = -1
            var start = 0
            var isBreak = true
            id.reserveCapacity(lines.count)
            for (i, line) in lines.enumerated() {
                let breaks = mask[i] || isQuoteLine(line) || line.allSatisfy(\.isWhitespace)
                if breaks {
                    if !isBreak { ranges.append(start..<i) }
                    id.append(-1)
                    isBreak = true
                } else {
                    if isBreak { current += 1; start = i; isBreak = false }
                    id.append(current)
                }
            }
            if !isBreak { ranges.append(start..<lines.count) }
            table = ranges.map { range in
                range.contains { i in
                    let line = lines[i]
                    return line.utf8.contains(0x7C) && line.utf8.contains(0x2D)
                        && line.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " || $0 == "\t" }
                }
            }
        }

        /// The paragraph a streaming text has not finished: the one of its last line, and when that line is still blank
        /// (it may yet continue the paragraph above), the one above it. -1 when the end of the text is a real break.
        var openParagraph: Int {
            guard var last = lines.indices.last else { return -1 }
            if lines[last].allSatisfy(\.isWhitespace), last > 0 { last -= 1 }
            return id[last]
        }

        /// The code spans of one line, in line coordinates.
        mutating func spans(of index: Int) -> [CodeSpan] {
            let p = id[index]
            guard p >= 0 else { return [] }
            if built[p] == nil { built[p] = build(p) }
            return built[p]?[index - ranges[p].lowerBound] ?? []
        }

        private func build(_ p: Int) -> [[CodeSpan]] {
            let range = ranges[p]
            var joined: [Character] = []
            var starts: [Int] = []
            var lengths: [Int] = []
            for i in range {
                let chars = Array(lines[i])
                starts.append(joined.count)
                lengths.append(chars.count)
                joined.append(contentsOf: chars)
                joined.append("\n")
            }
            var perLine = [[CodeSpan]](repeating: [], count: range.count)
            for span in ChatMediaDirectives.codeSpans(joined) {
                var l = ChatMediaDirectives.lineIndex(of: span.range.lowerBound, in: starts)
                let crossing = span.range.upperBound > starts[l] + lengths[l]
                while l < starts.count, starts[l] < span.range.upperBound {
                    let lo = max(span.range.lowerBound, starts[l]) - starts[l]
                    let hi = min(span.range.upperBound, starts[l] + lengths[l]) - starts[l]
                    if hi > lo { perLine[l].append(CodeSpan(range: lo..<hi, crossing: crossing)) }
                    l += 1
                }
            }
            return perLine
        }

        /// A line with a pipe in a paragraph that has a delimiter line (`| --- | --- |`, pipes optional at the ends).
        func inTable(_ index: Int) -> Bool {
            let p = id[index]
            return p >= 0 && table[p] && lines[index].utf8.contains(0x7C)
        }
    }

    private static func lineIndex(of position: Int, in starts: [Int]) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= position { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: One line

    private struct LineResult {
        var rest: [Character] = []
        var found: [Found] = []
        var voice = false
        var document = false
        var changed = false
    }

    /// Spans of inline code: a run of backticks and the next run of the same length (delimiters included). One pass:
    /// the runs are listed once and each is paired with the next of its length, so no input makes it quadratic.
    private static func codeSpans(_ c: [Character]) -> [CodeSpan] {
        var runs: [(start: Int, length: Int)] = []
        var i = 0
        while i < c.count {
            guard c[i] == "`" else { i += 1; continue }
            var n = 0
            while i + n < c.count, c[i + n] == "`" { n += 1 }
            runs.append((i, n))
            i += n
        }
        guard !runs.isEmpty else { return [] }
        var next = [Int](repeating: -1, count: runs.count)
        var lastOfLength: [Int: Int] = [:]
        for r in stride(from: runs.count - 1, through: 0, by: -1) {
            next[r] = lastOfLength[runs[r].length] ?? -1
            lastOfLength[runs[r].length] = r
        }
        var spans: [CodeSpan] = []
        var r = 0
        while r < runs.count {
            let close = next[r]
            if close >= 0 {
                spans.append(CodeSpan(range: runs[r].start..<(runs[close].start + runs[close].length), crossing: false))
                // The runs inside the span are code, not delimiters.
                r = close + 1
            } else {
                r += 1
            }
        }
        return spans
    }

    private static func matches(_ c: [Character], at i: Int, _ tag: [Character]) -> Bool {
        guard i + tag.count <= c.count else { return false }
        for k in 0..<tag.count where c[i + k] != tag[k] { return false }
        return true
    }

    /// How many characters at the end of a line that is still arriving could still grow into a tag.
    private static func heldSuffix(_ c: [Character]) -> Int {
        var best = 0
        for length in stride(from: min(c.count, 17), through: 1, by: -1) {
            let start = c.count - length
            let suffix = Array(c[start...])
            let tagPrefix = voiceTag.starts(with: suffix) || documentTag.starts(with: suffix)
            var mediaPrefix = false
            if length <= 5, mediaTag.starts(with: suffix) {
                mediaPrefix = start == 0 || c[start - 1].isWhitespace || wrapChars.contains(c[start - 1])
            }
            if tagPrefix || mediaPrefix { best = length; break }
        }
        return best
    }

    /// What follows a complete `MEDIA:` on a line that is still arriving: whether it can still become a path or an
    /// address (nothing yet, a quote, a slash, `~/`, a drive letter, the start of `http://`). Prose that merely mentions
    /// `MEDIA:` is not held.
    private static func canBecomePath(_ c: [Character], from start: Int) -> Bool {
        var p = start
        while p < c.count, c[p] == " " || c[p] == "\t" { p += 1 }
        guard p < c.count else { return true }
        let first = c[p]
        if first == "/" || first == "`" || first == "\"" || first == "'" { return true }
        if first == "~" { return p + 1 >= c.count || c[p + 1] == "/" }
        if first.isASCII, first.isLetter {
            if p + 1 >= c.count { return true }
            if c[p + 1] == ":" { return p + 2 >= c.count || c[p + 2] == "/" || c[p + 2] == "\\" }
            let rest = String(c[p..<min(c.count, p + 8)]).lowercased()
            return "https://".hasPrefix(rest) || "http://".hasPrefix(rest) || rest.hasPrefix("http://") || rest.hasPrefix("https://")
        }
        return false
    }

    /// `rows`: false for a line of a paragraph that is still open: a tag that would be a row is taken out of the text
    /// and no row is made (the verdict comes when the paragraph is complete).
    private static func process(_ source: [Character], hold: Bool, rows: Bool, spans allSpans: [CodeSpan], budget: inout Budget) -> LineResult {
        var c = source
        var result = LineResult()
        var held = false
        if hold {
            let n = heldSuffix(c)
            if n > 0 { c.removeLast(n); held = true }
        }
        let spans = allSpans.compactMap { span -> CodeSpan? in
            guard span.range.lowerBound < c.count else { return nil }
            return CodeSpan(range: span.range.lowerBound..<min(span.range.upperBound, c.count), crossing: span.crossing)
        }
        var spanIndex = 0
        var out: [Character] = []
        var lineCandidates = 0

        // A line that is one inline code span holding one whole tag: the tag is delivered (the gateway does the same).
        // Not while the line is still arriving (the rest of the line may turn it into a sentence), and not for a span
        // that goes over a line break.
        if !hold, spans.count == 1, let span = spans.first, !span.crossing {
            let range = span.range
            let before = c[..<range.lowerBound], after = c[range.upperBound...]
            if before.allSatisfy(\.isWhitespace), after.allSatisfy(\.isWhitespace) {
                var n = 0
                while range.lowerBound + n < range.upperBound, c[range.lowerBound + n] == "`" { n += 1 }
                let inner = Array(c[(range.lowerBound + n)..<(range.upperBound - n)])
                let trimmed = Array(String(inner).trimmingCharacters(in: .whitespaces))
                if matches(trimmed, at: 0, mediaTag) {
                    budget.candidates += 1
                    if let tag = parseTag(trimmed, at: 0, wraps: 0, aloneOnLine: true), tag.end == trimmed.count {
                        let verdict = accept(tag.found, &budget)
                        if verdict != .full {
                            if verdict == .added, rows { result.found.append(tag.found) }
                            result.changed = true
                            return result
                        }
                    }
                }
            }
        }

        var i = 0
        while i < c.count {
            if spanIndex < spans.count, i == spans[spanIndex].range.lowerBound {
                out.append(contentsOf: c[spans[spanIndex].range])
                i = spans[spanIndex].range.upperBound
                spanIndex += 1
                continue
            }
            if matches(c, at: i, voiceTag) { result.voice = true; result.changed = true; i += voiceTag.count; continue }
            if matches(c, at: i, documentTag) { result.document = true; result.changed = true; i += documentTag.count; continue }
            if matches(c, at: i, mediaTag) {
                lineCandidates += 1
                budget.candidates += 1
                if lineCandidates > maxCandidatesPerLine || budget.candidates > maxCandidatesPerText {
                    // Enough looked at: the rest of the line stays as it is.
                    out.append(contentsOf: c[i...])
                    break
                }
                var wraps = 0
                while wraps < 3, wraps < out.count, wrapChars.contains(out[out.count - 1 - wraps]) { wraps += 1 }
                let alone = out.dropLast(wraps).allSatisfy(\.isWhitespace)
                if hold, canBecomePath(c, from: i + mediaTag.count) {
                    // From a complete tag to the end of the line: neither text nor a row until the line is complete.
                    out.removeLast(wraps)
                    result.changed = true
                    result.rest = out
                    return result
                }
                if let tag = parseTag(c, at: i, wraps: wraps, aloneOnLine: alone) {
                    let verdict = accept(tag.found, &budget)
                    if verdict != .full {      // past the limit of rows the tag stays text
                        out.removeLast(wraps)
                        if verdict == .added, rows { result.found.append(tag.found) }
                        result.changed = true
                        i = tag.end
                        // "a MEDIA:/x.png b" leaves one space, not two.
                        if out.last?.isWhitespace == true { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }
                        continue
                    }
                }
            }
            out.append(c[i])
            i += 1
        }
        if held { result.changed = true }
        result.rest = out
        return result
    }

    private enum Acceptance { case added, duplicate, full }

    /// Counts a tag against the budget of the text: a path seen before is a duplicate (both tags go, one row), and past
    /// `maxAttachments` rows the tag stays text.
    private static func accept(_ found: Found, _ budget: inout Budget) -> Acceptance {
        let key = dedupeKey(found)
        if budget.seen.contains(key) { return .duplicate }
        guard budget.attachments < maxAttachments else { return .full }
        budget.seen.insert(key)
        budget.attachments += 1
        return .added
    }

    /// The path with repeated slashes and `.` components collapsed: `/tmp/./a.png` and `/tmp//a.png` are one file.
    static func normalisedPath(_ path: String) -> String {
        // On a path that starts with a slash (a POSIX machine) a backslash is an ordinary character of a name; elsewhere
        // (a drive letter, a path that starts with a backslash) it separates.
        let posix = path.hasPrefix("/")
        let parts = path.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "/" || (!posix && $0 == "\\") }).filter { $0 != "." }
        let lead = path.hasPrefix("/") || path.hasPrefix("\\") ? "/" : ""
        return lead + parts.joined(separator: "/")
    }

    private static func dedupeKey(_ found: Found) -> String {
        found.isRemote ? "remote:" + found.path : "path:" + normalisedPath(found.path)
    }

    // MARK: One tag

    private static func isAnchored(_ c: ArraySlice<Character>) -> Bool {
        guard let first = c.first else { return false }
        if first == "/" { return true }
        let a = Array(c.prefix(3))
        if a.count >= 2, a[0] == "~", a[1] == "/" { return true }
        if a.count >= 3, a[0].isASCII, a[0].isLetter, a[1] == ":", a[2] == "/" || a[2] == "\\" { return true }
        return false
    }

    private static func isBoundary(_ c: [Character], at e: Int) -> Bool {
        if e >= c.count { return true }
        let ch = c[e]
        if ch.isWhitespace || boundaryChars.contains(ch) { return true }
        if matches(c, at: e, mediaTag) || matches(c, at: e, eos) { return true }
        if ch == ".", e + 1 >= c.count || c[e + 1].isWhitespace { return true }
        return false
    }

    /// `c[i...]` starts with `MEDIA:`. `wraps`: quote or emphasis characters before it that go with the tag. Returns the
    /// attachment and where the tag ends (its closing wrappers and a final full stop included), or nil: the line stays.
    private static func parseTag(_ c: [Character], at i: Int, wraps: Int, aloneOnLine: Bool) -> (found: Found, end: Int)? {
        var p = i + mediaTag.count
        while p < c.count, c[p] == " " || c[p] == "\t" { p += 1 }
        guard p < c.count else { return nil }

        let path: [Character]
        let end: Int
        var remote = false
        var forcedDocument = false

        if c[p] == "`" || c[p] == "\"" || c[p] == "'" {
            let quote = c[p]
            let limit = min(c.count, p + 2 + maxPathChars)
            guard let close = ((p + 1)..<limit).first(where: { c[$0] == quote }), close > p + 1 else { return nil }
            path = Array(c[(p + 1)..<close])
            end = close + 1
            if !isAnchored(path[...]) {
                guard isRemoteStart(path, at: 0) else { return nil }
                remote = true
            } else if !knownExtensions.contains(extensionOf(String(path))) {
                guard aloneOnLine, path.contains("/") else { return nil }
                forcedDocument = true
            }
        } else if isRemoteStart(c, at: p) {
            var e = p
            let limit = min(c.count, p + maxPathChars + 1)
            while e < limit, !c[e].isWhitespace, !urlStopChars.contains(c[e]) { e += 1 }
            while e > p, urlTrailChars.contains(c[e - 1]) { e -= 1 }
            path = Array(c[p..<e])
            end = e
            remote = true
        } else if isAnchored(c[p...]) {
            guard let e = bareEnd(c, from: p) else {
                // No known extension: only a tag alone on its line, as a file of unknown kind.
                guard aloneOnLine else { return nil }
                var last = c.count
                while last > p, c[last - 1].isWhitespace || wrapChars.contains(c[last - 1]) { last -= 1 }
                guard last - p <= maxPathChars else { return nil }
                let path = Array(c[p..<last])
                guard path.contains("/"), !String(path).contains("MEDIA:") else { return nil }
                return finish(path, end: c.count, remote: false, forced: true, c: c, wraps: wraps, consumeTail: false)
            }
            path = Array(c[p..<e])
            end = e
        } else {
            return nil
        }
        return finish(path, end: end, remote: remote, forced: forcedDocument, c: c, wraps: wraps, consumeTail: true)
    }

    private static let urlStopChars: Set<Character> = ["\"", "'", "`", "<", ">"]
    private static let urlTrailChars: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "*", "_"]

    private static func finish(_ path: [Character], end startEnd: Int, remote: Bool, forced: Bool, c: [Character],
                               wraps: Int, consumeTail: Bool) -> (found: Found, end: Int)? {
        let string = String(path)
        guard isAcceptable(string, remote: remote) else { return nil }
        var end = startEnd
        if consumeTail {
            if matches(c, at: end, eos) { end += eos.count }
            var k = 0
            while k < wraps, end < c.count, wrapChars.contains(c[end]) { end += 1; k += 1 }
            if end < c.count, c[end] == ".", end + 1 >= c.count || c[end + 1].isWhitespace { end += 1 }
        } else {
            end = c.count
        }
        return (Found(path: string, isRemote: remote, forcedDocument: forced), end)
    }

    private static func isRemoteStart(_ c: [Character], at p: Int) -> Bool {
        let head = String(c[p..<min(c.count, p + 8)]).lowercased()
        return head.hasPrefix("https://") || head.hasPrefix("http://")
    }

    /// The end of a bare path: the first known extension that is followed by a boundary (the gateway reads it the same
    /// way), at most `maxPathChars` long. The scan stops at the next `MEDIA:`: it never runs over another tag.
    private static func bareEnd(_ c: [Character], from p: Int) -> Int? {
        let limit = min(c.count, p + maxPathChars)
        var e = p + 2
        while e <= limit {
            if isBoundary(c, at: e) {
                var d = e - 1
                while d > p, c[d].isLetter || c[d].isNumber, e - d <= maxExtensionLength + 1 { d -= 1 }
                if d > p, c[d] == ".", knownExtensions.contains(String(c[(d + 1)..<e]).lowercased()) { return e }
            }
            if e < c.count, c[e] == "M", matches(c, at: e, mediaTag) { return nil }
            e += 1
        }
        return nil
    }

    private static func isAcceptable(_ path: String, remote: Bool) -> Bool {
        guard !path.isEmpty, path.count <= maxPathChars else { return false }
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return false }
        // A web address whose host cannot be shown (an IPv6 literal, an odd label) is not a row: it stays text.
        if remote { return safeWebURL(path) != nil && !shownRemote(path).isEmpty }
        let parts = path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" })
        return !parts.contains("..")
    }

    // MARK: Names

    static func extensionOf(_ path: String) -> String {
        let name = lastComponent(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    private static func lastComponent(_ path: String) -> String {
        var p = path
        if let q = p.firstIndex(where: { $0 == "?" || $0 == "#" }), p.lowercased().hasPrefix("http") { p = String(p[..<q]) }
        return String(p.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
    }

    /// Blank looking characters that are not white space for Unicode: braille blank, Hangul fillers, and the like.
    private static let blankScalars: Set<UInt32> = [0x2800, 0x3164, 0x115F, 0x1160, 0xFFA0, 0x17B4, 0x17B5, 0x180E]

    /// Marks that draw nothing: the combining grapheme joiner, the variation selectors, the null notehead and the other
    /// musical format characters. They are never a part of a name a person reads.
    private static func isInvisibleMark(_ v: UInt32) -> Bool {
        v == 0x034F || (0xFE00...0xFE0F).contains(v) || (0x180B...0x180D).contains(v) || (0xE0100...0xE01EF).contains(v)
            || v == 0x1D159 || (0x1D173...0x1D17A).contains(v)
    }

    /// A text as a person reads it in one line: format, control, separator and private use characters are gone (no
    /// direction override, no zero width, no line break), runs of white space and blank looking characters are one
    /// space, and it is cut at `limit` characters.
    static func readable(_ raw: String, limit: Int) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for u in raw.unicodeScalars {
            if u.value == 0x09 || u.value == 0x0A || u.value == 0x0D || blankScalars.contains(u.value) { pendingSpace = true; continue }
            if isInvisibleMark(u.value) { continue }
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                continue
            case .nonspacingMark, .enclosingMark:
                // An accent belongs to the letter before it. A mark with no letter to sit on (at the start, or after a
                // space) shows nothing, or lands on whatever is drawn next to the name.
                if pendingSpace || out.isEmpty { continue }
                out.append(u)
            case .spaceSeparator:
                pendingSpace = true
            default:
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(u)
            }
        }
        let name = String(out)
        return name.count > limit ? String(name.prefix(limit - 1)) + "…" : name
    }

    /// The file name as a person reads it: the last component of the path, exactly as the agent wrote it (never percent
    /// decoded), cleaned by `readable`.
    static func displayName(of path: String) -> String {
        readable(lastComponent(path), limit: maxNameChars)
    }

    // MARK: Remote row

    /// What the row of a web address draws: only the host, by the rule of the links of the chat (`linkShownHost`: ASCII,
    /// cut from the left), plus a port that is not the default one. Never the path or the query: those are the agent's
    /// words, and the confirmation that every click goes through shows the real destination.
    static func shownRemote(_ url: String) -> String {
        guard let host = linkShownHost(url) else { return "" }
        guard let parts = URL(string: url), let port = parts.port else { return host }
        let standard = parts.scheme?.lowercased() == "https" ? 443 : 80
        return port == standard ? host : "\(host):\(port)"
    }

    // MARK: Ticker label

    /// The one line the overview card shows for the attachments of an answer: a label, never a path.
    static func tickerLabel(for attachments: [ChatAttachment]) -> String? {
        guard let first = attachments.first else { return nil }
        if attachments.count > 1 { return String(localized: "\(attachments.count) files") }
        switch first.kind {
        case .voice: return String(localized: "Voice message")
        case .audio: return String(localized: "Audio")
        case .image: return String(localized: "Image")
        case .video: return String(localized: "Video")
        case .document: return String(localized: "File: \(first.name)")
        }
    }
}
