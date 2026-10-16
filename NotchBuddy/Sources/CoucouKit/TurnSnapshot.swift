import Foundation
import CryptoKit

/// An opaque target captured when the user sends an instruction. Root session
/// IDs and resumable Codex thread IDs are deliberately separate.
enum SessionInstructionIdentity {
    static let version = 1

    static func make(pillId: String, sessionId: String, threadId: String?, cwd: String, turnId: String? = nil) -> String? {
        guard !pillId.isEmpty, !sessionId.isEmpty, sessionId != "unknown", cwd.hasPrefix("/") else { return nil }
        guard pillId != "agent_codex" || !(threadId ?? "").isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode([String(version), pillId, sessionId, threadId ?? "", cwd, turnId ?? ""]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func accepts(_ identity: String, current: String?, createdAt: Date, text: String,
                        busy: Bool, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return !identity.isEmpty && identity == current && age >= -60 && age < 600
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= 8000 && !busy
    }

    static func notificationKey(state: String, targetIdentity: String, questionFingerprint: String) -> String {
        if state == "finished" || state == "error" {
            return targetIdentity.isEmpty ? state : "\(state)-\(targetIdentity)"
        }
        return questionFingerprint.isEmpty ? state : "q-\(questionFingerprint)"
    }
}

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
    var threadId: String? = nil
    var turnId: String? = nil

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
