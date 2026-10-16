import Foundation

/// Someone in a call. You are always "me"; the others get "Person 2", "Person 3"… until renamed.
struct NoteSpeaker: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Index in the window's speaker colors.
    var color: Int
    var isMe = false
}

/// One turn of speech.
struct NoteLine: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var speaker: String
    /// Seconds from the start of the recording.
    var start: Double
    var end: Double
    var text: String
    /// The words as Parakeet heard them, kept when the line was corrected (by Claude or by you).
    var raw: String? = nil
}

struct NoteTodo: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var owner: String?
    var due: String?
    var done = false
}

/// A call noted by the Notetaker.
struct Note: Codable, Hashable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case recording, processing, ready, failed
    }

    var id = UUID()
    var title: String
    /// Set once you rename the note: the summary then keeps your title.
    var titleEdited: Bool?
    var start: Date
    var end: Date?
    /// The call app seen when the recording started ("Zoom", "Google Chrome").
    var app: String?
    var status: Status = .recording
    var speakers: [NoteSpeaker] = []
    var lines: [NoteLine] = []
    var summary: String?
    var keyPoints: [String] = []
    var todos: [NoteTodo] = []
    var error: String?

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }

    func speaker(_ id: String) -> NoteSpeaker? { speakers.first { $0.id == id } }

    /// Each speaker's share of the talking, from the length of their lines.
    var shares: [String: Double] {
        var time: [String: Double] = [:]
        for line in lines { time[line.speaker, default: 0] += max(0.1, line.end - line.start) }
        let total = time.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return time.mapValues { $0 / total }
    }
}

/// A word with its place in the audio.
struct TimedWord: Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A stretch of audio where one voice speaks, from the diarizer.
struct SpeakerTurn: Hashable, Sendable {
    var speaker: String
    var start: Double
    var end: Double
    /// The voice's fingerprint on this stretch (empty when unknown).
    var embedding: [Float] = []
}

/// Builds the transcript of a call from the two recordings (tests/NoteModelsTests.swift):
/// the microphone is you, the Mac's sound is the others, told apart by the diarizer.
enum NoteBuilder {
    /// Words further apart than this start a new line.
    static let pause = 1.4
    /// A line never gets longer than this, so the transcript stays readable.
    static let maxLineSeconds = 40.0

    static let meID = "me"

    /// The others' words, each given to the voice speaking at that moment (or the nearest one).
    static func assign(_ words: [TimedWord], to turns: [SpeakerTurn], fallback: String) -> [(speaker: String, word: TimedWord)] {
        words.map { word -> (speaker: String, word: TimedWord) in
            let mid = (word.start + word.end) / 2
            if let turn = turns.first(where: { mid >= $0.start && mid <= $0.end }) {
                return (speaker: turn.speaker, word: word)
            }
            let nearest = turns.min { distance(mid, $0) < distance(mid, $1) }
            if let nearest, distance(mid, nearest) < 2 { return (speaker: nearest.speaker, word: word) }
            return (speaker: fallback, word: word)
        }
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }

    /// Consecutive words of the same speaker, close in time, make one line.
    static func lines(from words: [(speaker: String, word: TimedWord)]) -> [NoteLine] {
        var out: [NoteLine] = []
        for (speaker, word) in words {
            if var last = out.last, last.speaker == speaker, word.start - last.end < pause,
               word.end - last.start < maxLineSeconds {
                last.text += " " + word.text
                last.end = word.end
                out[out.count - 1] = last
            } else {
                out.append(NoteLine(speaker: speaker, start: word.start, end: word.end, text: word.text))
            }
        }
        return out
    }

    /// Without headphones, the others' voices come out of the speakers and into the microphone too.
    /// A line of yours whose words the others' recording also has, at the same moment, is that echo.
    static func removingEcho(mine: [NoteLine], others: [NoteLine]) -> [NoteLine] {
        mine.filter { line in
            let words = tokens(line.text)
            guard words.count >= 2 else {
                // A lone word: echo only if the others said exactly it at that moment.
                return !others.contains { overlaps($0, line, margin: 0.8) && tokens($0.text).contains(words.first ?? "") }
            }
            let near = others.filter { overlaps($0, line, margin: 1.5) }.flatMap { tokens($0.text) }
            guard !near.isEmpty else { return true }
            let pool = Set(near)
            let shared = words.filter { pool.contains($0) }.count
            return Double(shared) / Double(words.count) < 0.6
        }
    }

    private static func overlaps(_ a: NoteLine, _ b: NoteLine, margin: Double) -> Bool {
        a.start < b.end + margin && b.start < a.end + margin
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The echo found word by word: three or more of your words in a row that the others said in
    /// the same order at the same moment (one word heard differently, or missed, does not break it).
    /// Catches what the audio check lets through, when the speakers are very loud.
    static func removingEchoWords(_ mine: [TimedWord], others: [TimedWord],
                                  window: Double = 1.2, minRun: Int = 3) -> [TimedWord] {
        let a = mine.map { tokens($0.text).joined() }
        let b = others.map { tokens($0.text).joined() }
        var echo = [Bool](repeating: false, count: mine.count)
        var i = 0
        while i < mine.count {
            var span = 0
            if !a[i].isEmpty {
                for j in others.indices where b[j] == a[i] && abs(others[j].start - mine[i].start) <= window {
                    var x = i + 1, y = j + 1, run = 1
                    while x < mine.count && y < others.count {
                        if a[x] == b[y] {
                            run += 1; x += 1; y += 1
                        } else if y + 1 < others.count && a[x] == b[y + 1] {
                            y += 1          // a word the microphone missed
                        } else if x + 1 < mine.count && a[x + 1] == b[y] {
                            x += 1          // a word the microphone heard in more
                        } else if x + 1 < mine.count && y + 1 < others.count && a[x + 1] == b[y + 1] {
                            x += 1; y += 1  // a word heard differently
                        } else {
                            break
                        }
                    }
                    guard run >= minRun else { continue }
                    // The rest of their sentence, heard too differently to match, is the echo as well:
                    // your words that follow without a pause while they are still speaking.
                    var k = max(j, y - 1)
                    while k + 1 < others.count && others[k + 1].start - others[k].end < 0.6 { k += 1 }
                    let until = others[min(k, others.count - 1)].end + 0.3
                    while x < mine.count && mine[x].start <= until && mine[x].start - mine[x - 1].end < 0.6 { x += 1 }
                    span = max(span, x - i)
                }
            }
            if span > 0 {
                for k in i..<(i + span) { echo[k] = true }
                i += span
            } else {
                i += 1
            }
        }
        return zip(mine, echo).filter { !$0.1 }.map(\.0)
    }

    /// A voice heard only in short bits ("Yeah.", "Sure.", the end of a sentence) is almost always
    /// someone already there: such bits are too short for the diarizer to recognise the voice, and
    /// it makes a new person of them. Each bit goes to the closest real voice (by fingerprint,
    /// else the nearest in time). A voice is real once it speaks 3 s in a row, or long enough overall.
    static let fragmentLongest = 3.0

    static func mergingFragments(_ turns: [SpeakerTurn]) -> [SpeakerTurn] {
        var total: [String: Double] = [:], longest: [String: Double] = [:]
        for turn in turns {
            let length = turn.end - turn.start
            total[turn.speaker, default: 0] += length
            longest[turn.speaker] = max(longest[turn.speaker] ?? 0, length)
        }
        guard total.count > 1 else { return turns }
        let all = total.values.reduce(0, +)
        let solid = Set(total.keys.filter { (longest[$0] ?? 0) >= fragmentLongest || (total[$0] ?? 0) >= max(20, all * 0.1) })
        guard !solid.isEmpty, solid.count < total.count else { return turns }

        // Each real voice's fingerprint: the mean of its turns', longer turns counting more.
        var centroids: [String: [Float]] = [:]
        for speaker in solid {
            var sum: [Float] = []
            for turn in turns where turn.speaker == speaker && !turn.embedding.isEmpty {
                let unit = normalized(turn.embedding)
                let weight = Float(turn.end - turn.start)
                if sum.isEmpty { sum = [Float](repeating: 0, count: unit.count) }
                guard unit.count == sum.count else { continue }
                for k in sum.indices { sum[k] += unit[k] * weight }
            }
            if !sum.isEmpty { centroids[speaker] = normalized(sum) }
        }
        let solidTurns = turns.filter { solid.contains($0.speaker) }
        return turns.map { turn in
            guard !solid.contains(turn.speaker) else { return turn }
            var turn = turn
            if !turn.embedding.isEmpty, centroids.count == solid.count {
                let unit = normalized(turn.embedding)
                if let best = centroids.max(by: { dot(unit, $0.value) < dot(unit, $1.value) }) {
                    turn.speaker = best.key
                    return turn
                }
            }
            let mid = (turn.start + turn.end) / 2
            if let nearest = solidTurns.min(by: { distance(mid, $0) < distance(mid, $1) }) {
                turn.speaker = nearest.speaker
            }
            return turn
        }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1 }
        var sum: Float = 0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }

    /// The whole transcript: your lines (echo removed) and the others', in time order, with the
    /// speakers named in the order they first speak.
    static func build(mine: [TimedWord], others: [TimedWord], turns: [SpeakerTurn],
                      meName: String, personName: (Int) -> String) -> (speakers: [NoteSpeaker], lines: [NoteLine]) {
        let myLines = lines(from: mine.map { (speaker: meID, word: $0) })
        let theirLines = lines(from: assign(others, to: turns, fallback: "others"))
        let all = (removingEcho(mine: myLines, others: theirLines) + theirLines).sorted { $0.start < $1.start }
        var speakers: [NoteSpeaker] = []
        if !myLines.isEmpty || others.isEmpty {
            speakers.append(NoteSpeaker(id: meID, name: meName, color: 0, isMe: true))
        }
        var ids: [String: String] = [:]
        var renamed: [NoteLine] = []
        for var line in all {
            if line.speaker != meID {
                if let id = ids[line.speaker] {
                    line.speaker = id
                } else {
                    let number = speakers.filter { !$0.isMe }.count + 2
                    let id = "p\(number)"
                    ids[line.speaker] = id
                    speakers.append(NoteSpeaker(id: id, name: personName(number), color: number - 1))
                    line.speaker = id
                }
            }
            renamed.append(line)
        }
        return (speakers, renamed)
    }

    /// One recording for everyone (people around the same Mac, no call): the diarizer tells the
    /// voices apart and they are all "Person 1", "Person 2"…
    static func buildRoom(words: [TimedWord], turns: [SpeakerTurn],
                          personName: (Int) -> String) -> (speakers: [NoteSpeaker], lines: [NoteLine]) {
        let raw = lines(from: assign(words, to: turns, fallback: "others"))
        var speakers: [NoteSpeaker] = []
        var ids: [String: String] = [:]
        let named = raw.map { line -> NoteLine in
            var line = line
            if let id = ids[line.speaker] {
                line.speaker = id
            } else {
                let number = speakers.count + 1
                let id = "p\(number)"
                ids[line.speaker] = id
                speakers.append(NoteSpeaker(id: id, name: personName(number), color: number))
                line.speaker = id
            }
            return line
        }
        return (speakers, named)
    }

    // MARK: - Markdown

    /// The note as Markdown: title, date, summary, key points, to-dos, then the transcript.
    static func markdown(_ note: Note, labels: MarkdownLabels) -> String {
        var out = "# \(note.title)\n\n"
        let date = note.start.formatted(date: .complete, time: .shortened)
        let minutes = max(1, Int((note.duration / 60).rounded()))
        out += "_\(date) · \(minutes) min_"
        if !note.speakers.isEmpty {
            out += "  \n_" + note.speakers.map(\.name).joined(separator: ", ") + "_"
        }
        out += "\n\n"
        if let summary = note.summary, !summary.isEmpty {
            out += "## \(labels.summary)\n\n\(summary)\n\n"
        }
        if !note.keyPoints.isEmpty {
            out += "## \(labels.keyPoints)\n\n" + note.keyPoints.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if !note.todos.isEmpty {
            out += "## \(labels.todos)\n\n"
            out += note.todos.map { todo in
                var line = "- [\(todo.done ? "x" : " ")] \(todo.text)"
                let extra = [todo.owner, todo.due].compactMap { $0 }.filter { !$0.isEmpty }
                if !extra.isEmpty { line += " (\(extra.joined(separator: ", ")))" }
                return line
            }.joined(separator: "\n") + "\n\n"
        }
        if !note.lines.isEmpty {
            out += "## \(labels.transcript)\n\n"
            out += note.lines.map { line in
                let name = note.speaker(line.speaker)?.name ?? line.speaker
                return "**\(name)** (\(clock(line.start))) : \(line.text)"
            }.joined(separator: "\n\n") + "\n"
        }
        return out
    }

    struct MarkdownLabels: Sendable {
        var summary: String
        var keyPoints: String
        var todos: String
        var transcript: String
    }

    /// 75 → "1:15", 3725 → "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The transcript as plain text for the summary: "Name: words" per line.
    static func plainTranscript(_ note: Note) -> String {
        note.lines.map { line in
            "\(note.speaker(line.speaker)?.name ?? line.speaker): \(line.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Summary

    struct Summary: Sendable, Equatable {
        var title: String?
        var summary: String
        var keyPoints: [String]
        var todos: [NoteTodo]
    }

    /// Reads the model's JSON answer ({"title", "summary", "key_points", "todos": [{"text", "owner", "due"}]}),
    /// even wrapped in a code block or with text around it. nil when there is no JSON in it.
    static func parseSummary(_ reply: String) -> Summary? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let data = String(reply[open...close]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let points = (json["key_points"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        let todos: [NoteTodo] = (json["todos"] as? [Any] ?? []).compactMap { item in
            if let text = item as? String, !text.isEmpty { return NoteTodo(text: text) }
            guard let dict = item as? [String: Any], let text = dict["text"] as? String, !text.isEmpty else { return nil }
            func field(_ key: String) -> String? {
                guard let v = dict[key] as? String, !v.isEmpty, v.lowercased() != "null" else { return nil }
                return v
            }
            return NoteTodo(text: text, owner: field("owner"), due: field("due"))
        }
        guard !summary.isEmpty || !points.isEmpty || !todos.isEmpty else { return nil }
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Summary(title: title?.isEmpty == true ? nil : title, summary: summary, keyPoints: points, todos: todos)
    }
}

// MARK: - Correcting the transcript

/// Speech recognition mishears names, brands and accented speech ("UG charging" for "EV charging").
/// Claude reads the whole call and fixes those words; what it sends back is checked so it can only
/// fix a line, never rewrite it (tests/NoteModelsTests.swift).
extension NoteBuilder {
    struct Correction: Sendable, Equatable {
        /// Line number in the request → the line as it was said.
        var lines: [Int: String]
        /// Name shown in the transcript ("Person 2") → the person's name.
        var speakers: [String: String]
    }

    /// Hesitations, left out when comparing a line with its correction.
    static let fillers: Set<String> = ["uh", "um", "umm", "uhm", "er", "erm", "ah", "eh", "hmm", "mmm", "mm", "euh", "bah", "hum"]

    /// Lines of the transcript cut in parts of about `words` words, for long calls.
    static func batches(_ lines: [NoteLine], words: Int = 2_500) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start = 0, count = 0
        for (index, line) in lines.enumerated() {
            count += line.text.split(separator: " ").count
            if count >= words {
                out.append(start..<(index + 1))
                start = index + 1
                count = 0
            }
        }
        if start < lines.count { out.append(start..<lines.count) }
        return out
    }

    /// "[12] Person 2: words", one per line.
    static func numberedTranscript(_ note: Note, range: Range<Int>) -> String {
        range.map { index in
            let line = note.lines[index]
            return "[\(index)] \(note.speaker(line.speaker)?.name ?? line.speaker): \(line.text)"
        }.joined(separator: "\n")
    }

    /// Reads {"lines": {"12": "…"}, "speakers": {"Person 2": "Pratap"}}, even with text around it.
    static func parseCorrection(_ reply: String) -> Correction? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let data = String(reply[open...close]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var lines: [Int: String] = [:]
        for (key, value) in json["lines"] as? [String: Any] ?? [:] {
            let digits = key.filter(\.isNumber)
            guard let index = Int(digits), let text = value as? String else { continue }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines[index] = t }
        }
        var speakers: [String: String] = [:]
        for (key, value) in json["speakers"] as? [String: Any] ?? [:] {
            guard let name = value as? String else { continue }
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { speakers[key] = n }
        }
        return Correction(lines: lines, speakers: speakers)
    }

    /// Whether a corrected line is still the same line: a few words fixed, hesitations gone,
    /// not something else written instead.
    static func plausibleFix(_ original: String, _ fixed: String) -> Bool {
        let before = Array(tokens(original).filter { !fillers.contains($0) }.joined(separator: " "))
        let after = Array(tokens(fixed).joined(separator: " "))
        guard !after.isEmpty else { return false }
        guard !before.isEmpty else { return after.count <= 12 }
        let longest = max(before.count, after.count)
        return Double(editDistance(before, after)) <= max(6, Double(longest) * 0.45)
    }

    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] : 1 + min(previous[j - 1], previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// The note with the plausible fixes, and the people named where the call says who they are.
    /// A speaker you renamed keeps your name; a name must be said somewhere in the call.
    static func applying(_ correction: Correction, to note: Note, personName: (Int) -> String) -> (note: Note, fixed: Int) {
        var note = note
        var fixed = 0
        for (index, text) in correction.lines where note.lines.indices.contains(index) {
            let line = note.lines[index]
            guard text != line.text, plausibleFix(line.text, text) else { continue }
            if note.lines[index].raw == nil { note.lines[index].raw = line.text }
            note.lines[index].text = text
            fixed += 1
        }
        let spoken = note.lines.map { $0.raw ?? $0.text }.joined(separator: " ").lowercased()
            + " " + note.lines.map(\.text).joined(separator: " ").lowercased()
        for (shown, name) in correction.speakers {
            guard name.count <= 40, name.split(separator: " ").count <= 3,
                  spoken.contains(name.lowercased()),
                  !note.speakers.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  let index = note.speakers.firstIndex(where: { $0.name == shown && !$0.isMe }) else { continue }
            let speaker = note.speakers[index]
            // Only "Person 2" and the like: never a name you gave.
            guard let number = Int(speaker.id.dropFirst()), speaker.name == personName(number) else { continue }
            note.speakers[index].name = name
        }
        return (note, fixed)
    }

    /// The words a correction of yours brought in, worth remembering for the next calls: names,
    /// brands, acronyms, technical words ("UG charging" → "EV charging" teaches "EV").
    static func newTerms(old: String, new: String) -> [String] {
        let before = Set(tokens(old))
        var seen = Set<String>()
        var out: [String] = []
        for raw in new.split(whereSeparator: { $0.isWhitespace }) {
            let word = raw.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "+#")))
            let key = tokens(word).joined()
            guard !key.isEmpty, !before.contains(key), !fillers.contains(key), seen.insert(key).inserted else { continue }
            let distinctive = word.contains { $0.isUppercase || $0.isNumber } || word.contains(".") || word.count >= 7
            if distinctive && word.count >= 2 { out.append(word) }
        }
        return out
    }
}
