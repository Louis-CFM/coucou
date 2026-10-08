import Foundation

// The last turn of an agent session, for the iPhone: the prompt you sent, what
// the agent did (commands, reads, searches, edits with their diffs) and its
// final answer. The Mac builds it from the hook events it already receives
// (TurnRecorder) and writes it, encrypted, to the private iCloud zone. Only
// the latest turn per session is kept.

struct TurnAction: Codable, Equatable, Sendable {
    var tool: String          // "Bash", "Edit", "Read"…
    var summary: String       // the command, file or pattern
    var output: String = ""   // what a command printed (trimmed)
    var failed: Bool = false
    var date: Date
    /// Index in `files` when this action changed a file.
    var fileIndex: Int? = nil
}

struct TurnDiffLine: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case context, added, removed, gap }
    var kind: Kind
    var text: String
}

struct TurnFile: Codable, Equatable, Sendable {
    var path: String
    var added: Int
    var removed: Int
    var isNew: Bool
    var lines: [TurnDiffLine]
    /// Some lines were left out to keep the turn small.
    var truncated: Bool = false

    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct TurnSnapshot: Codable, Equatable, Sendable {
    var pillId: String
    var sessionId: String
    var project: String
    var prompt: String
    var actions: [TurnAction]
    var files: [TurnFile]
    var finalMessage: String
    var startedAt: Date
    var endedAt: Date?

    static let recordType = "Turn"

    static func recordName(for pillId: String) -> String { "turn-\(pillId)" }

    static func pillId(fromRecordName name: String) -> String? {
        name.hasPrefix("turn-") ? String(name.dropFirst("turn-".count)) : nil
    }
}

extension TurnFile {
    /// The diff lines of a FileDiff (DiffEngine), hunks separated by a gap line.
    init(diff: FileDiff, maxLines: Int) {
        var lines: [TurnDiffLine] = []
        var truncated = diff.tooLarge
        for (index, hunk) in diff.hunks.enumerated() {
            if index > 0 { lines.append(TurnDiffLine(kind: .gap, text: "")) }
            for line in hunk.lines {
                guard lines.count < maxLines else { truncated = true; break }
                let kind: TurnDiffLine.Kind
                switch line.kind {
                case .added: kind = .added
                case .removed: kind = .removed
                case .context: kind = .context
                }
                lines.append(TurnDiffLine(kind: kind, text: String(line.text.prefix(400))))
            }
        }
        self.init(path: diff.path, added: diff.added, removed: diff.removed,
                  isNew: diff.isNewFile, lines: lines, truncated: truncated)
    }
}
