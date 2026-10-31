#if !APPSTORE
import Foundation

struct CodexTurnPlan: Equatable {
    struct Step: Equatable {
        enum Status: String { case pending, inProgress, completed }
        var text: String
        var status: Status
    }
    var threadId: String
    var turnId: String
    var text = ""
    var explanation = ""
    var steps: [Step] = []

    var isEmpty: Bool { text.isEmpty && steps.isEmpty && explanation.isEmpty }

    mutating func update(_ params: [String: Any]) {
        guard let entries = params["plan"] as? [[String: Any]], entries.count <= 32 else { return }
        var parsed: [Step] = []
        for entry in entries {
            guard let text = entry["step"] as? String,
                  let raw = entry["status"] as? String, let status = Step.Status(rawValue: raw) else { return }
            parsed.append(Step(text: String(text.prefix(500)), status: status))
        }
        steps = parsed
        explanation = String((params["explanation"] as? String ?? "").prefix(2000))
    }
}

/// One owned turn only. Aggregate snapshots replace counts; item diffs fill gaps until a snapshot arrives.
struct CodexTurnDiffState {
    private var itemFiles: [FileDiff] = []
    private var snapshot: [FileDiff]?
    private(set) var moveSources: [String: String] = [:]

    private var revision = 0
    private var itemStarts: [String: Int] = [:]

    var files: [FileDiff] {
        var result = snapshot ?? []
        for diff in itemFiles {
            if let index = result.firstIndex(where: { $0.path == diff.path }) { result[index] = Self.adding(diff, to: result[index]) }
            else if result.count < 50 { result.append(diff) }
        }
        return result
    }

    mutating func itemStarted(_ id: String) {
        if !id.isEmpty, itemStarts.count < 512 { itemStarts[id] = revision }
    }

    mutating func recordItem(_ changes: [[String: Any]], cwd: String, itemId: String = "") -> [FileDiff] {
        let startedAt = itemStarts.removeValue(forKey: itemId)
        guard changes.count <= 50 else { return [] }
        // A newer aggregate already represents this item, including paths with no remaining changes.
        if let startedAt, startedAt < revision { return [] }
        var parsed: [FileDiff] = []
        for change in changes {
            guard let rawPath = change["path"] as? String, let text = change["diff"] as? String,
                  text.utf8.count <= FileDiff.maxBytes else { continue }
            let kind = change["kind"] as? [String: Any] ?? [:]
            guard let path = Self.path(kind["move_path"] as? String ?? rawPath, cwd: cwd) else { continue }
            if let source = Self.path(rawPath, cwd: cwd), source != path {
                for key in Array(moveSources.keys) where moveSources[key] == source { moveSources[key] = path }
                if moveSources.count < 50 { moveSources[source] = path }
                itemFiles = Self.moving(source, to: path, in: itemFiles)
                if let snapshot { self.snapshot = Self.moving(source, to: path, in: snapshot) }
            }
            var diffs = DiffEngine.fromUnifiedDiff(text, path: path)
            if diffs.isEmpty, ["add", "delete", "update"].contains(kind["type"] as? String ?? ""),
               (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.contains("@@ -0,0 +0,0 @@")) {
                diffs = [FileDiff(path: path, added: 0, removed: 0, hunks: [], tooLarge: false, isNewFile: kind["type"] as? String == "add")]
            }
            for diff in diffs {
                if let current = snapshot?.first(where: { $0.path == diff.path }) {
                    if startedAt == nil, current.hunks == diff.hunks, current.added == diff.added, current.removed == diff.removed { continue }
                }
                parsed.append(diff)
                if let index = itemFiles.firstIndex(where: { $0.path == path }) { itemFiles[index] = Self.adding(diff, to: itemFiles[index]) }
                else if itemFiles.count < 50 { itemFiles.append(diff) }
            }
        }
        return parsed
    }

    @discardableResult
    mutating func updateSnapshot(_ text: String, cwd: String) -> Bool {
        guard text.utf8.count <= FileDiff.maxBytes else { return false }
        let lines = text.components(separatedBy: "\n")
        guard lines.count <= FileDiff.maxLines else { return false }
        var parsed = DiffEngine.fromUnifiedDiff(text).compactMap { diff -> FileDiff? in
            guard let raw = Self.gitPath(diff.path, stripPrefix: true), let path = Self.path(raw, cwd: cwd) else { return nil }
            var result = diff; result.path = moveSources[path] ?? path
            return result
        }
        // Git emits no hunk for empty files and pure renames. Keep those real operations visible.
        var rawPath: String?, isNew = false, hasContentHunk = false
        func flush() {
            guard !hasContentHunk, let rawPath, let source = Self.path(rawPath, cwd: cwd) else { return }
            let path = moveSources[source] ?? source
            guard !parsed.contains(where: { $0.path == path }) else { return }
            parsed.append(FileDiff(path: path, added: 0, removed: 0, hunks: [], tooLarge: false, isNewFile: isNew))
        }
        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush(); isNew = false; rawPath = nil; hasContentHunk = false
                if let range = line.range(of: " \"b/", options: .backwards) {
                    rawPath = Self.gitPath(String(line[line.index(after: range.lowerBound)...]), stripPrefix: true)
                } else { rawPath = Self.unquotedHeaderPath(line) }
            } else if !hasContentHunk, line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                let raw = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
                if let name = Self.gitPath(raw, stripPrefix: false), name != "/dev/null" {
                    rawPath = name.hasPrefix("a/") || name.hasPrefix("b/") ? String(name.dropFirst(2)) : name
                }
            } else if line.hasPrefix("@@ ") {
                hasContentHunk = hasContentHunk || line.range(of: #"^@@ -[0-9]+,0 \+[0-9]+,0 @@"#, options: .regularExpression) == nil
            } else if line.hasPrefix("rename to ") {
                rawPath = Self.gitPath(String(line.dropFirst("rename to ".count)), stripPrefix: false)
            } else if line == "--- /dev/null" || line.hasPrefix("new file mode ") { isNew = true }
        }
        flush()
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !parsed.isEmpty else { return false }
        var unique: [FileDiff] = []
        for diff in parsed {
            if let index = unique.firstIndex(where: { $0.path == diff.path }) { unique[index] = diff }
            else if unique.count < 50 { unique.append(diff) }
        }
        if !text.isEmpty {
            let paths = Set(unique.map(\.path))
            unique += itemFiles.filter { $0.hunks.isEmpty && !$0.tooLarge && !paths.contains($0.path) }
        }
        snapshot = Array(unique.prefix(50))
        itemFiles = []
        revision += 1
        return true
    }

    private static func moving(_ source: String, to destination: String, in files: [FileDiff]) -> [FileDiff] {
        var result: [FileDiff] = []
        for var file in files {
            if file.path == source { file.path = destination }
            if let index = result.firstIndex(where: { $0.path == file.path }) { result[index] = adding(file, to: result[index]) }
            else { result.append(file) }
        }
        return result
    }

    // Later tool chunks remain visible until the next authoritative cumulative snapshot.
    private static func adding(_ next: FileDiff, to previous: FileDiff) -> FileDiff {
        var result = previous
        result.added += next.added; result.removed += next.removed
        let hunks = previous.hunks + next.hunks
        let lines = hunks.reduce(0) { $0 + $1.lines.count }
        let bytes = hunks.reduce(0) { $0 + $1.lines.reduce(0) { $0 + $1.text.utf8.count } }
        if !previous.tooLarge, !next.tooLarge, lines <= FileDiff.maxLines, bytes <= FileDiff.maxBytes { result.hunks = hunks }
        else { result.hunks = []; result.tooLarge = true }
        return result
    }

    private static func unquotedHeaderPath(_ line: String) -> String? {
        guard line.hasPrefix("diff --git a/") else { return nil }
        let paths = String(line.dropFirst("diff --git a/".count))
        // Equal before/after paths identify the separator even when the name contains " b/".
        if paths.count >= 3, (paths.count - 3).isMultiple(of: 2) {
            let middle = paths.index(paths.startIndex, offsetBy: (paths.count - 3) / 2)
            if paths[middle...].hasPrefix(" b/") {
                let after = paths.index(middle, offsetBy: 3)
                if paths[..<middle] == paths[after...] { return String(paths[after...]) }
            }
        }
        guard let separator = paths.range(of: " b/"),
              paths.range(of: " b/", range: separator.upperBound..<paths.endIndex) == nil else { return nil }
        return String(paths[separator.upperBound...])
    }

    /// Git C-quotes spaces/control bytes and UTF-8 octets in file headers.
    private static func gitPath(_ raw: String, stripPrefix: Bool) -> String? {
        guard raw.hasPrefix("\"") else { return raw }
        guard raw.hasSuffix("\"") else { return nil }
        let input = Array(raw.utf8.dropFirst().dropLast())
        var bytes: [UInt8] = [], index = 0
        let escapes: [UInt8: UInt8] = [34: 34, 92: 92, 97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13]
        while index < input.count {
            let byte = input[index]; index += 1
            if byte != 92 { bytes.append(byte); continue }
            guard index < input.count else { return nil }
            let next = input[index]; index += 1
            if let decoded = escapes[next] { bytes.append(decoded) }
            else if (48...55).contains(next) {
                var value = Int(next - 48), count = 1
                while count < 3, index < input.count, (48...55).contains(input[index]) {
                    value = value * 8 + Int(input[index] - 48); index += 1; count += 1
                }
                guard value <= 255 else { return nil }
                bytes.append(UInt8(value))
            } else { return nil }
        }
        guard let decoded = String(bytes: bytes, encoding: .utf8) else { return nil }
        return stripPrefix && (decoded.hasPrefix("a/") || decoded.hasPrefix("b/")) ? String(decoded.dropFirst(2)) : decoded
    }

    private static func path(_ raw: String, cwd: String) -> String? {
        guard !raw.isEmpty, raw != "/dev/null", raw.utf8.count <= 4096, !raw.contains("\0") else { return nil }
        return (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : URL(fileURLWithPath: cwd).appendingPathComponent(raw)).standardizedFileURL.path
    }
}
#endif
