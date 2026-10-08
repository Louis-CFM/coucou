import Foundation

// MARK: - Types

struct DiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed }
    var kind: Kind
    var text: String
    var origLine: Int   // 1-based; -1 for pure adds
    var newLine: Int    // 1-based; -1 for pure removes
}

struct DiffHunk: Equatable {
    var origStart: Int
    var newStart: Int
    var lines: [DiffLine]
}

struct FileDiff: Equatable {
    var id: Int = 0         // stable identifier assigned by AppState.appendSessionDiff
    var path: String
    var added: Int
    var removed: Int
    var hunks: [DiffHunk]
    var tooLarge: Bool
    var isNewFile: Bool     // true when produced by DiffEngine.fromNew (Write tool)

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    static let maxBytes = 200 * 1024
    static let maxLines = 4000
}

// MARK: - DiffEngine

enum DiffEngine {

    // MARK: Public API

    static func fromEdit(old: String, new: String, path: String) -> FileDiff {
        // Size guard
        if old.utf8.count + new.utf8.count > FileDiff.maxBytes {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        if oldLines.count + newLines.count > FileDiff.maxLines {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        // LCS is O(m*n) — bail out before quadratic blowup
        if oldLines.count * newLines.count > 1_000_000 {
            return countFallback(old: old, new: new, path: path, tooLarge: true)
        }
        let flat = buildDiffLines(oldLines: oldLines, newLines: newLines)
        let hunks = buildHunks(from: flat, context: 3)
        let added   = flat.filter { $0.kind == .added   }.count
        let removed = flat.filter { $0.kind == .removed }.count
        return FileDiff(path: path, added: added, removed: removed, hunks: hunks, tooLarge: false, isNewFile: false)
    }

    static func fromNew(content: String, path: String) -> FileDiff {
        // Size guard (same limits as fromEdit)
        if content.utf8.count > FileDiff.maxBytes {
            let lineCount = content.components(separatedBy: "\n").count
            return FileDiff(path: path, added: lineCount, removed: 0, hunks: [], tooLarge: true, isNewFile: true)
        }
        let lines = splitLines(content)
        if lines.count > FileDiff.maxLines {
            return FileDiff(path: path, added: lines.count, removed: 0, hunks: [], tooLarge: true, isNewFile: true)
        }
        let diffLines = lines.enumerated().map { (i, text) in
            DiffLine(kind: .added, text: text, origLine: -1, newLine: i + 1)
        }
        let hunk = diffLines.isEmpty ? nil : DiffHunk(origStart: 0, newStart: 1, lines: diffLines)
        return FileDiff(
            path: path,
            added: diffLines.count,
            removed: 0,
            hunks: hunk.map { [$0] } ?? [],
            tooLarge: false,
            isNewFile: true
        )
    }

    /// Codex patch input contains only the changed lines, never a full old file.
    static func fromCodexPatch(_ patch: String) -> [FileDiff] {
        guard patch.utf8.count <= FileDiff.maxBytes else { return [] }
        var result: [FileDiff] = []
        var path: String?, lines: [DiffLine] = [], isNew = false
        func flush() {
            guard let file = path else { return }
            result.append(FileDiff(path: file, added: lines.filter { $0.kind == .added }.count,
                          removed: lines.filter { $0.kind == .removed }.count,
                          hunks: lines.isEmpty ? [] : [DiffHunk(origStart: 0, newStart: 0, lines: lines)],
                          tooLarge: false, isNewFile: isNew))
            lines = []
        }
        let parts = patch.components(separatedBy: "\n")
        guard parts.count <= FileDiff.maxLines else { return [] }
        for line in parts {
            if line.hasPrefix("*** Add File: ") || line.hasPrefix("*** Update File: ") || line.hasPrefix("*** Delete File: ") {
                flush()
                path = String(line.dropFirst(line.firstIndex(of: ":")!.utf16Offset(in: line) + 2))
                isNew = line.hasPrefix("*** Add File: ")
            } else if line.hasPrefix("*** Move to: ") {
                path = String(line.dropFirst("*** Move to: ".count))
            } else if path != nil, let first = line.first, first == "+" || first == "-" || first == " " {
                lines.append(DiffLine(kind: first == "+" ? .added : first == "-" ? .removed : .context,
                             text: String(line.dropFirst()), origLine: -1, newLine: -1))
            }
        }
        flush()
        return result
    }

    /// Parse bounded native unified diffs. Counts come from hunks, never whole-file guesses.
    static func fromUnifiedDiff(_ diff: String, path fallback: String? = nil) -> [FileDiff] {
        guard diff.utf8.count <= FileDiff.maxBytes else { return [] }
        let parts = diff.components(separatedBy: "\n")
        guard parts.count <= FileDiff.maxLines else { return [] }
        var result: [FileDiff] = []
        var path = fallback, oldPath: String?, hunks: [DiffHunk] = [], lines: [DiffLine] = []
        var old = 0, new = 0, startOld = 0, startNew = 0, active = false
        var oldRemaining = 0, newRemaining = 0
        func flushHunk() {
            if !lines.isEmpty { hunks.append(DiffHunk(origStart: startOld, newStart: startNew, lines: lines)) }
            lines = []; active = false
        }
        func flushFile() {
            flushHunk()
            guard let file = path, !hunks.isEmpty else { return }
            let flat = hunks.flatMap(\.lines)
            result.append(FileDiff(path: file, added: flat.filter { $0.kind == .added }.count,
                                  removed: flat.filter { $0.kind == .removed }.count,
                                  hunks: hunks, tooLarge: false, isNewFile: oldPath == "/dev/null"))
            hunks = []
        }
        func fileName(_ raw: String) -> String {
            let text = raw.components(separatedBy: "\t")[0].trimmingCharacters(in: .newlines)
            return text.hasPrefix("a/") || text.hasPrefix("b/") ? String(text.dropFirst(2)) : text
        }
        for line in parts {
            if line.hasPrefix("diff --git ") { flushFile(); path = fallback; oldPath = nil }
            else if !active && line.hasPrefix("--- ") {
                // The previous hunk's declared counts distinguish file headers
                // from legitimate removed/added lines starting with -- or ++.
                flushFile(); path = fallback
                oldPath = fileName(String(line.dropFirst(4)))
            } else if !active && line.hasPrefix("+++ ") {
                let next = fileName(String(line.dropFirst(4)))
                path = fallback ?? (next == "/dev/null" ? oldPath : next)
            } else if line.hasPrefix("@@ ") {
                flushHunk()
                let fields = line.split(separator: " ")
                guard fields.count >= 4, fields[1].hasPrefix("-"), fields[2].hasPrefix("+"), fields[3] == "@@" else { continue }
                let before = fields[1].dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                let after = fields[2].dropFirst().split(separator: ",", omittingEmptySubsequences: false)
                guard let a = before.first.flatMap({ Int($0) }), let b = after.first.flatMap({ Int($0) }),
                      before.count <= 2, after.count <= 2,
                      let ac = before.count == 2 ? Int(before[1]) : 1,
                      let bc = after.count == 2 ? Int(after[1]) : 1,
                      a >= 0, b >= 0, ac >= 0, bc >= 0 else { continue }
                old = a; new = b; startOld = a; startNew = b
                oldRemaining = ac; newRemaining = bc; active = ac > 0 || bc > 0
            } else if active, let first = line.first, first == "+" || first == "-" || first == " " {
                let kind: DiffLine.Kind = first == "+" ? .added : first == "-" ? .removed : .context
                guard (kind == .added || oldRemaining > 0), (kind == .removed || newRemaining > 0) else { active = false; continue }
                lines.append(DiffLine(kind: kind, text: String(line.dropFirst()),
                                     origLine: kind == .added ? -1 : old, newLine: kind == .removed ? -1 : new))
                if kind != .added { old += 1; oldRemaining -= 1 }
                if kind != .removed { new += 1; newRemaining -= 1 }
                if oldRemaining == 0 && newRemaining == 0 { active = false }
            }
        }
        flushFile()
        return result
    }

    // MARK: - Line splitting

    private static func splitLines(_ text: String) -> [String] {
        // Normalize CRLF → LF
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var parts = normalized.components(separatedBy: "\n")
        // Drop trailing empty element that results from a trailing newline
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: - LCS-based diff

    private static func buildDiffLines(oldLines: [String], newLines: [String]) -> [DiffLine] {
        let m = oldLines.count
        let n = newLines.count

        // Build LCS DP table
        // dp[i][j] = LCS length of oldLines[0..<i] and newLines[0..<j]
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...max(1, m) {
            for j in 1...max(1, n) {
                guard i <= m && j <= n else { continue }
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to get matching pairs
        var matches: [(Int, Int)] = []  // (oldIdx 0-based, newIdx 0-based)
        var i = m, j = n
        while i > 0 && j > 0 {
            if oldLines[i - 1] == newLines[j - 1] {
                matches.append((i - 1, j - 1))
                i -= 1; j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        matches.reverse()

        // Build flat diff from LCS pairs
        var result: [DiffLine] = []
        var prevOld = -1
        var prevNew = -1

        for (oi, ni) in matches {
            // Removed lines between last match and this old match
            for k in (prevOld + 1)..<oi {
                result.append(DiffLine(kind: .removed, text: oldLines[k],
                                       origLine: k + 1, newLine: -1))
            }
            // Added lines between last match and this new match
            for k in (prevNew + 1)..<ni {
                result.append(DiffLine(kind: .added, text: newLines[k],
                                       origLine: -1, newLine: k + 1))
            }
            // Context line (the match)
            result.append(DiffLine(kind: .context, text: oldLines[oi],
                                   origLine: oi + 1, newLine: ni + 1))
            prevOld = oi
            prevNew = ni
        }

        // Remaining removes
        for k in (prevOld + 1)..<m {
            result.append(DiffLine(kind: .removed, text: oldLines[k],
                                   origLine: k + 1, newLine: -1))
        }
        // Remaining adds
        for k in (prevNew + 1)..<n {
            result.append(DiffLine(kind: .added, text: newLines[k],
                                   origLine: -1, newLine: k + 1))
        }

        return result
    }

    // MARK: - Hunk building

    private static func buildHunks(from lines: [DiffLine], context: Int) -> [DiffHunk] {
        guard !lines.isEmpty else { return [] }

        // Find indices of changed lines
        var changedIndices: [Int] = []
        for (i, line) in lines.enumerated() {
            if line.kind != .context { changedIndices.append(i) }
        }
        guard !changedIndices.isEmpty else { return [] }

        // Expand ±context around each changed line
        let ranges: [(Int, Int)] = changedIndices.map {
            (max(0, $0 - context), min(lines.count - 1, $0 + context))
        }

        // Merge overlapping ranges
        var merged: [(Int, Int)] = []
        for r in ranges {
            if let last = merged.last, r.0 <= last.1 + 1 {
                merged[merged.count - 1] = (last.0, max(last.1, r.1))
            } else {
                merged.append(r)
            }
        }

        // Build hunks
        var hunks: [DiffHunk] = []
        for (start, end) in merged {
            let hunkLines = Array(lines[start...end])
            let origStart = hunkLines.first(where: { $0.origLine > 0 })?.origLine ?? 1
            let newStart  = hunkLines.first(where: { $0.newLine > 0 })?.newLine  ?? 1
            hunks.append(DiffHunk(origStart: origStart, newStart: newStart, lines: hunkLines))
        }
        return hunks
    }

    // MARK: - Count fallback (tooLarge)

    private static func countFallback(old: String, new: String, path: String, tooLarge: Bool) -> FileDiff {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let added   = newLines.filter { !$0.isEmpty && !oldSet.contains($0) }.count
        let removed = oldLines.filter { !$0.isEmpty && !newSet.contains($0) }.count
        return FileDiff(path: path, added: added, removed: removed, hunks: [], tooLarge: tooLarge, isNewFile: false)
    }

    // MARK: - toOneLine

    /// Converts a possibly multi-line, markdown-formatted string to a single line of plain text.
    /// Uses only the first non-empty paragraph (stops at blank line, horizontal rule, or table row).
    /// Strips `**`, `__`, backticks, leading `#`, and leading bullet markers.
    static func toOneLine(_ text: String, maxChars: Int = 200) -> String {
        let lines = text.components(separatedBy: "\n")

        // Split into paragraphs. Separators: blank line, HR (3+ repeated -/*/_ chars), table row (starts with |).
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHR = trimmed.count >= 3 && (trimmed.allSatisfy { $0 == "-" } ||
                                               trimmed.allSatisfy { $0 == "*" } ||
                                               trimmed.allSatisfy { $0 == "_" })
            let isSep = trimmed.isEmpty || isHR || trimmed.hasPrefix("|")
            if isSep {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        // Find first paragraph that yields non-empty text after cleaning.
        for paraLines in paragraphs {
            var s = paraLines.joined(separator: "\n")
            s = s.replacingOccurrences(of: "**", with: "")
            s = s.replacingOccurrences(of: "__", with: "")
            s = s.replacingOccurrences(of: "`", with: "")
            let processed: [String] = s.components(separatedBy: "\n").compactMap { line in
                var l = line
                while l.hasPrefix("#") { l = String(l.dropFirst()) }
                l = l.trimmingCharacters(in: .whitespaces)
                // Strip leading bullet markers: -, *, •, or N. (ordered list)
                if l.hasPrefix("- ") || l.hasPrefix("* ") || l.hasPrefix("• ") {
                    l = String(l.dropFirst(2))
                } else if let m = l.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                    l = String(l[m.upperBound...])
                }
                let trimmed = l.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            let joined = processed.joined(separator: " ")
            let collapsed = joined.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !collapsed.isEmpty { return String(collapsed.prefix(maxChars)) }
        }
        return ""
    }
}

// MARK: - String diff step encoding

public extension String {
    /// Private-use character used as the diff step marker prefix.
    static let diffStepMarker = "\u{E001}"

    /// True if this step string encodes a file diff.
    var isDiffStep: Bool { hasPrefix(Self.diffStepMarker) }

    /// Parses a diff step string.
    /// Format: `"\u{E001}<filename>\t<added>:<removed>:<diffId>"`
    func parseDiffStep() -> (filename: String, added: Int, removed: Int, diffId: Int)? {
        guard isDiffStep else { return nil }
        let body = String(dropFirst())   // drop the marker character
        guard let tabIdx = body.firstIndex(of: "\t") else { return nil }
        let filename = String(body[body.startIndex..<tabIdx])
        let rest = String(body[body.index(after: tabIdx)...])
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let added  = Int(parts[0]),
              let removed = Int(parts[1]),
              let diffId  = Int(parts[2]) else { return nil }
        return (filename, added, removed, diffId)
    }

    /// Creates a diff step string from its components.
    static func makeDiffStep(filename: String, added: Int, removed: Int, diffId: Int) -> String {
        "\(diffStepMarker)\(filename)\t\(added):\(removed):\(diffId)"
    }
}
