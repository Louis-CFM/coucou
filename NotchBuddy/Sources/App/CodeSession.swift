import Foundation

// MARK: - Code view data
//
// What the code view shows of a Claude Code session: the last edit (with the file's
// own lines around it), the last command and what it printed, and the phases of the
// turn. Foundation only, so it can be tested without AppKit (scripts/test-code-view.sh).

enum CodePhase: String, CaseIterable, Sendable {
    case read, edit, bash
}

/// The file's lines around an edit.
struct CodeSnippet: Equatable, Sendable {
    /// Line number (1-based) of `lines[0]`.
    var start: Int
    var lines: [String]
    /// Where the edited block begins in `lines`, and how many lines it spans.
    var at: Int
    var len: Int
}

struct CodeEdit: Equatable, Sendable {
    var isWrite: Bool
    var path: String
    /// Relative to the session's folder when it lies inside it.
    var file: String
    var removed: String
    var added: String
    var snippet: CodeSnippet? = nil
}

struct CodeCommand: Equatable, Sendable {
    enum Status: Sendable { case running, ok, failed }
    var command: String
    var tail: [String] = []
    var status: Status = .running
}

struct CodeRow: Equatable, Sendable {
    enum Kind: Sendable { case context, added, removed }
    var kind: Kind
    var number: Int?
    var text: String
}

struct CodeSession: Equatable, Sendable {
    var project: String
    /// The folder the session started in: paths are shown relative to it and read only from inside it.
    var root: String
    var edit: CodeEdit?
    var command: CodeCommand?
    var seen: [CodePhase] = []
    var current: CodePhase?
    var finished = false

    init(project: String, root: String) {
        self.project = project
        self.root = root
    }

    var hasContent: Bool { edit != nil || command != nil }

    mutating func beginTurn() {
        edit = nil
        command = nil
        seen = []
        current = nil
        finished = false
    }

    mutating func endTurn() { finished = true }

    mutating func toolStarted(tool: String, input: [String: Any], cwd: String) {
        finished = false
        if let phase = CodeView.phase(of: tool) {
            current = phase
            if !seen.contains(phase) { seen.append(phase) }
        }
        let str = { (key: String) in input[key] as? String ?? "" }
        let path = str("file_path")
        let file = CodeView.relative(path, root: root, cwd: cwd)
        switch tool {
        case "Edit":
            edit = CodeEdit(isWrite: false, path: path, file: file, removed: str("old_string"), added: str("new_string"))
        case "MultiEdit":
            // The first edit stands for the call: the pane has room for a handful of lines.
            let first = (input["edits"] as? [[String: Any]])?.first ?? [:]
            edit = CodeEdit(isWrite: false, path: path, file: file,
                            removed: first["old_string"] as? String ?? "", added: first["new_string"] as? String ?? "")
        case "Write":
            edit = CodeEdit(isWrite: true, path: path, file: file, removed: "", added: str("content"))
        case "Bash":
            if !str("command").isEmpty { command = CodeCommand(command: str("command")) }
        default:
            break
        }
    }

    mutating func toolFinished(tool: String, response: Any?, failed: Bool, error: String?) {
        guard tool == "Bash", command != nil else { return }
        command?.status = failed ? .failed : .ok
        var tail = CodeView.tail(of: response)
        if tail.isEmpty, let line = error?.split(separator: "\n").first {
            tail = [String(line.prefix(CodeView.tailWidth))]
        }
        command?.tail = tail
    }
}

enum CodeView {
    static let tailLines = 3
    static let tailWidth = 160
    static let maxFileBytes = 2 * 1024 * 1024
    static let maxLineLength = 200

    private static let phases: [String: CodePhase] = [
        "Read": .read, "Glob": .read, "Grep": .read, "LS": .read, "WebFetch": .read, "WebSearch": .read,
        "Edit": .edit, "MultiEdit": .edit, "Write": .edit, "NotebookEdit": .edit,
        "Bash": .bash,
    ]

    static func phase(of tool: String) -> CodePhase? { phases[tool] }

    /// `path` relative to the session's folder, else to the shell's current one, else as it is.
    static func relative(_ path: String, root: String, cwd: String) -> String {
        for base in [root, cwd] where !base.isEmpty && path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return path
    }

    /// The last few non-empty lines a command printed (stdout, else stderr), without colour codes.
    static func tail(of response: Any?) -> [String] {
        let text: String
        if let s = response as? String {
            text = s
        } else if let o = response as? [String: Any],
                  let s = ["stdout", "stderr"].lazy.compactMap({ o[$0] as? String })
                      .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            text = s
        } else {
            return []
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripANSI(String($0)).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.suffix(tailLines).map { String($0.prefix(tailWidth)) }
    }

    /// Drops `ESC [ … letter` colour and cursor sequences.
    static func stripANSI(_ line: String) -> String {
        line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// The lines of `text` around the first `find`, with `context` lines on each side.
    static func snippet(in text: String, find: String, context: Int) -> CodeSnippet? {
        guard !find.isEmpty, let range = text.range(of: find) else { return nil }
        let first = text[..<range.lowerBound].filter { $0 == "\n" }.count
        var block = find
        while block.hasSuffix("\n") { block.removeLast() }
        let len = block.filter { $0 == "\n" }.count + 1
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        let from = max(0, first - context)
        let to = min(all.count, first + len + context)
        guard from < to else { return nil }
        return CodeSnippet(start: from + 1, lines: all[from..<to].map { String($0.prefix(maxLineLength)) },
                           at: first - from, len: len)
    }

    /// Reads the snippet from disk: only a regular file inside `root`, links resolved, up to 2 MB.
    static func readSnippet(path: String, root: String, find: String, context: Int = 3) -> CodeSnippet? {
        guard !root.isEmpty, !path.isEmpty else { return nil }
        let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard file.hasPrefix(base + "/"),
              let attrs = try? FileManager.default.attributesOfItem(atPath: file),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= maxFileBytes,
              let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        return snippet(in: text, find: find, context: context)
    }

    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var t = text
        if t.hasSuffix("\n") { t.removeLast() }
        return t.components(separatedBy: "\n")
    }

    /// The editor pane's rows for one edit, in file order.
    static func rows(for edit: CodeEdit) -> [CodeRow] {
        let removed = lines(edit.removed)
        let added = lines(edit.added)
        guard !edit.isWrite, let snip = edit.snippet else {
            let firstNumber: Int? = edit.isWrite ? 1 : nil
            return removed.map { CodeRow(kind: .removed, number: nil, text: $0) }
                + added.enumerated().map { i, text in CodeRow(kind: .added, number: firstNumber.map { $0 + i }, text: text) }
        }
        var rows: [CodeRow] = []
        for (i, text) in snip.lines.enumerated() {
            if i == snip.at {
                rows += removed.enumerated().map { CodeRow(kind: .removed, number: snip.start + snip.at + $0.offset, text: $0.element) }
            }
            let inBlock = i >= snip.at && i < snip.at + snip.len
            rows.append(CodeRow(kind: inBlock ? .added : .context, number: snip.start + i, text: text))
        }
        return rows
    }

    /// Keeps the changed rows and as much context as fits, dropping the far context first.
    static func fit(_ rows: [CodeRow], max: Int) -> [CodeRow] {
        var from = 0
        var to = rows.count
        while to - from > max {
            if rows[from].kind == .context {
                from += 1
            } else {
                to -= 1
            }
        }
        return Array(rows[from..<to])
    }
}
