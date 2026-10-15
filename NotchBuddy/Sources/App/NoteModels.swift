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
