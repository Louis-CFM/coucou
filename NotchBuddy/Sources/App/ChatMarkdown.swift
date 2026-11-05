import Foundation

// MARK: - Markdown block types

enum MDAlign: Equatable { case leading, center, trailing }

enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(lang: String, code: String)
    /// prefix: "•" for unordered, "1." / "2." etc for ordered; indent: nesting level (0-based)
    case listItem(prefix: String, text: String, indent: Int)
    case quote(text: String)
    case rule
    case taskItem(checked: Bool, text: String, indent: Int)
    case table(header: [String], align: [MDAlign], rows: [[String]])
    /// Right under a table that was cut at `maxTableRows`: how many rows are not shown.
    case hiddenRows(count: Int)
}

// MARK: - Parser (Foundation only)

enum ChatMarkdown {
    static let maxTableColumns = 12
    static let maxTableRows = 200
    /// Display only: the code view cuts each line here, Copy gives the whole code. The fence info string is cut at
    /// `maxLanguageChars`.
    static let maxCodeLineChars = 2000
    static let maxLanguageChars = 40
    static let maxIndentLevel = 6

    // MARK: Bidirectional controls

    private static func isBidiControl(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 0x202A && u.value <= 0x202E) || (u.value >= 0x2066 && u.value <= 0x2069)
    }

    /// Drops the embedding, override and isolate characters (U+202A to U+202E, U+2066 to U+2069): in a command they
    /// make what is shown differ from what is pasted. For display and for the Copy button only: never apply it to
    /// the stored text or to what is sent back to an agent.
    static func withoutBidiControls(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isBidiControl) else { return s }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s.unicodeScalars.filter { !isBidiControl($0) })
        return String(out)
    }

    /// The same, only inside inline code spans (a run of backticks and the next run of the same length). Text outside
    /// a span, and a span that never closes, are left as they are.
    static func withoutBidiControlsInCodeSpans(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: isBidiControl) else { return s }
        let chars = Array(s)
        var out = ""
        var unclosable = Set<Int>()      // opener lengths known to have no closer: a later opener cannot find one either
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else { out.append(chars[i]); i += 1; continue }
            // A backtick after an odd run of backslashes is escaped: it is text, not the start of a span.
            var slashes = 0
            while slashes < i, chars[i - 1 - slashes] == "\\" { slashes += 1 }
            if slashes % 2 == 1 { out.append("`"); i += 1; continue }
            var n = 0
            while i + n < chars.count, chars[i + n] == "`" { n += 1 }
            var close: Int?
            if !unclosable.contains(n) {
                var j = i + n
                while j < chars.count {
                    if chars[j] == "`" {
                        var m = 0
                        while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                        if m == n { close = j; break }
                        j += m
                    } else { j += 1 }
                }
                if close == nil { unclosable.insert(n) }
            }
            out += String(repeating: "`", count: n)
            if let close {
                out += withoutBidiControls(String(chars[(i + n)..<close])) + String(repeating: "`", count: n)
                i = close + n
            } else {
                i += n
            }
        }
        return out
    }

    /// `streaming: true` is for a text that is still arriving: it holds back a half written fence marker, shows a
    /// table from its header line on, and closes an open `**`, `` ` `` or `~~` of the last line. A finished text is
    /// parsed with `false` and shown as written.
    static func parse(_ input: String, streaming: Bool = false) -> [MDBlock] {
        // One line ending for everything below: CRLF and a lone CR become LF.
        let text = input.utf8.contains(13)
            ? input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : input
        var lines = text.components(separatedBy: "\n")
        if streaming, let last = lastContentIndex(lines), isHeldBack(lines, last) {
            lines.removeSubrange(last...)
        }
        let lastIdx = lastContentIndex(lines) ?? -1
        var blocks: [MDBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Fenced code block (``` or ~~~, at any indent)
            if let fence = openingFence(line) {
                var code: [String] = []
                i += 1
                while i < lines.count && !closes(lines[i], fence: fence) {
                    code.append(removeIndent(lines[i], upTo: fence.indent))
                    i += 1
                }
                // Display and Copy only: the blocks are made from the text each time, the text itself is not touched.
                blocks.append(.codeBlock(lang: withoutBidiControls(fence.lang), code: withoutBidiControls(code.joined(separator: "\n"))))
                i += 1
                continue
            }

            // ATX heading — MUST have space after the #s
            if let heading = headingLine(line) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                i += 1
                continue
                // else fall through to paragraph (a line of hashes only is a paragraph with its text)
            }

            // Table: a line with a pipe followed by its delimiter line
            if line.contains("|"), let t = parseTable(lines, from: i, lastIdx: lastIdx, streaming: streaming) {
                blocks.append(contentsOf: t.blocks)
                i = t.next
                continue
            }

            let stripped = line.trimmingCharacters(in: .whitespaces)

            // Horizontal rule
            if isRule(stripped) {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Blockquote: consecutive lines are one block
            if isQuoteLine(stripped) {
                var quoted: [String] = []
                while i < lines.count {
                    let s = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isQuoteLine(s) else { break }
                    quoted.append(quoteText(s))
                    i += 1
                }
                blocks.append(.quote(text: lineBreaks(quoted.joined(separator: "\n"))))
                continue
            }

            // List item (bullet, task or numbered): nesting by leading columns, tab = 4
            let columns = leadingColumns(line)
            let indent = min(columns / 2, maxIndentLevel)
            if let item = listItem(stripped, bare: streaming && i == lastIdx) {
                var text = item.text
                i += 1
                // Continuation: following non blank lines indented deeper than the marker, that start nothing else
                while i < lines.count {
                    let next = lines[i]
                    let nextStripped = next.trimmingCharacters(in: .whitespaces)
                    if nextStripped.isEmpty || leadingColumns(next) <= columns { break }
                    if listItem(nextStripped, bare: streaming && i == lastIdx) != nil || openingFence(next) != nil
                        || isRule(nextStripped) { break }
                    if next.contains("|"), parseTable(lines, from: i, lastIdx: lastIdx, streaming: streaming) != nil { break }
                    text += "\n" + nextStripped
                    i += 1
                }
                text = lineBreaks(text)
                switch item.kind {
                case .bullet: blocks.append(.listItem(prefix: "•", text: text, indent: indent))
                case .ordered(let number): blocks.append(.listItem(prefix: number + ".", text: text, indent: indent))
                case .task(let checked): blocks.append(.taskItem(checked: checked, text: text, indent: indent))
                }
                continue
            }

            // Blank line — skip
            if stripped.isEmpty {
                i += 1
                continue
            }

            // Paragraph: accumulate consecutive non-special lines
            var paragraphLines: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                let nextStripped = next.trimmingCharacters(in: .whitespaces)
                if nextStripped.isEmpty { break }
                if headingLine(next) != nil { break }
                if openingFence(next) != nil { break }
                if isQuoteLine(nextStripped) { break }
                if isRule(nextStripped) { break }
                if listItem(nextStripped, bare: streaming && i == lastIdx) != nil { break }
                if next.contains("|"), parseTable(lines, from: i, lastIdx: lastIdx, streaming: streaming) != nil { break }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(text: lineBreaks(paragraphLines.joined(separator: "\n"))))
        }
        if streaming { closeLastBlock(&blocks) }
        return blocks
    }

    // MARK: - Inline closing for a text that is still arriving

    /// For a block of a text that is still arriving: closes an open `**`, `` ` `` or `~~` (a `**` opened on an
    /// earlier line of the block is closed at the end), and shows an unfinished link `[text](par` of the last line
    /// as `text`. A `**` or `~~` that cannot open (followed by a space, or preceded by a letter, a digit or `/`:
    /// `src/**/*.ts`, `x ** 2`) is left alone. A marker with nothing after it yet is dropped. Returns the text
    /// unchanged when nothing is open.
    static func closeOpenInline(_ block: String) -> String {
        guard block.contains(where: { "*`~[".contains($0) }) else { return block }
        let text: String
        if let nl = block.lastIndex(of: "\n") {
            text = String(block[...nl]) + truncateUnfinishedLink(String(block[block.index(after: nl)...]))
        } else {
            text = truncateUnfinishedLink(block)
        }
        let chars = Array(text)
        var out: [Character] = []
        var codeFence = 0          // length of the open backtick run, 0 = not in code
        var boldOpenAt: Int?       // index in `out` of the opening `**`
        var strikeOpenAt: Int?
        var codeOpenAt: Int?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                // A code span does not carry over to the next line.
                codeFence = 0; codeOpenAt = nil
                out.append(c); i += 1; continue
            }
            if c == "\\", codeFence == 0, i + 1 < chars.count, chars[i + 1] != "\n" {
                out.append(c); out.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                var n = 0
                while i + n < chars.count && chars[i + n] == "`" { n += 1 }
                if codeFence == 0 { codeFence = n; codeOpenAt = out.count }
                else if codeFence == n { codeFence = 0; codeOpenAt = nil }
                out.append(contentsOf: chars[i..<(i + n)])
                i += n
                continue
            }
            if codeFence == 0, (c == "*" || c == "~"), i + 1 < chars.count, chars[i + 1] == c {
                let opens = canOpen(chars, at: i)
                if c == "*" { boldOpenAt = boldOpenAt != nil ? nil : (opens ? out.count : nil) }
                else { strikeOpenAt = strikeOpenAt != nil ? nil : (opens ? out.count : nil) }
                out.append(c); out.append(c); i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        if codeFence == 0 && boldOpenAt == nil && strikeOpenAt == nil { return String(out) }
        // Close in the reverse order of opening; a marker with nothing after it is dropped instead.
        var opens: [(at: Int, marker: String)] = []
        if let a = codeOpenAt { opens.append((a, String(repeating: "`", count: codeFence))) }
        if let a = boldOpenAt { opens.append((a, "**")) }
        if let a = strikeOpenAt { opens.append((a, "~~")) }
        opens.sort { $0.at > $1.at }
        for open in opens {
            let after = out[(open.at + open.marker.count)...]
            if after.allSatisfy({ $0 == " " || $0 == "\n" }) {
                out.removeSubrange(open.at...)
            } else {
                out.append(contentsOf: Array(open.marker))
            }
        }
        return String(out)
    }

    /// A doubled marker at `i` opens emphasis when something other than a space follows it (or nothing yet) and
    /// no letter, digit or `/` comes right before it.
    private static func canOpen(_ chars: [Character], at i: Int) -> Bool {
        if i + 2 < chars.count, chars[i + 2].isWhitespace { return false }
        if i > 0 { let p = chars[i - 1]; if p.isLetter || p.isNumber || p == "/" { return false } }
        return true
    }

    /// `see [docs](https://exa` → `see docs`. A `[text` with no `](` is left alone.
    private static func truncateUnfinishedLink(_ line: String) -> String {
        guard let open = line.range(of: "](", options: .backwards) else { return line }
        if line[open.upperBound...].contains(")") { return line }
        guard let bracket = line[..<open.lowerBound].lastIndex(of: "["),
              !line[line.index(after: bracket)..<open.lowerBound].contains("]") else { return line }
        let label = line[line.index(after: bracket)..<open.lowerBound]
        return String(line[..<bracket]) + label
    }

    private static func closeLastBlock(_ blocks: inout [MDBlock]) {
        guard let last = blocks.last else { return }
        switch last {
        case .paragraph(let t): blocks[blocks.count - 1] = .paragraph(text: closeOpenInline(t))
        case .heading(let l, let t): blocks[blocks.count - 1] = .heading(level: l, text: closeOpenInline(t))
        case .quote(let t): blocks[blocks.count - 1] = .quote(text: closeOpenInline(t))
        case .listItem(let p, let t, let n): blocks[blocks.count - 1] = .listItem(prefix: p, text: closeOpenInline(t), indent: n)
        case .taskItem(let c, let t, let n): blocks[blocks.count - 1] = .taskItem(checked: c, text: closeOpenInline(t), indent: n)
        case .table(let h, let a, var rows):
            if var row = rows.popLast(), let cell = row.popLast() {
                row.append(closeOpenInline(cell)); rows.append(row)
                blocks[blocks.count - 1] = .table(header: h, align: a, rows: rows)
            } else if rows.isEmpty, var header = Optional(h), let cell = header.popLast() {
                header.append(closeOpenInline(cell))
                blocks[blocks.count - 1] = .table(header: header, align: a, rows: rows)
            }
        case .codeBlock, .rule, .hiddenRows: break
        }
    }

    // MARK: - Line helpers

    private static func lastContentIndex(_ lines: [String]) -> Int? {
        lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A last line made only of one or two back ticks (or tildes): a fence marker still arriving.
    private static func isFenceMarkerInProgress(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.count == 1 || s.count == 2, let first = s.first, first == "`" || first == "~" else { return false }
        return s.allSatisfy { $0 == first }
    }

    /// The last content line of a text that is still arriving, when it is not yet something to show: a half fence
    /// marker, a line of hashes (a heading being typed), or dashes right under a line with pipes that has no leading
    /// pipe (a bullet, a rule, or the delimiter of a table; the next character tells).
    private static func isHeldBack(_ lines: [String], _ last: Int) -> Bool {
        let line = lines[last]
        if isFenceMarkerInProgress(line) { return true }
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.allSatisfy({ $0 == "#" }) { return true }
        guard last > 0, !s.contains("|"), s.contains("-"), isDelimiterInProgress(s) else { return false }
        let before = lines[last - 1].trimmingCharacters(in: .whitespaces)
        return before.contains("|") && !before.hasPrefix("|")
    }

    /// An ATX heading: hashes, a space (or the end), then a text. A line of hashes only is not one.
    private static func headingLine(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line.utf8 { if ch == 35 { level += 1 } else { break } }
        let rest = line.dropFirst(level)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (min(level, 6), text)
    }

    /// Leading spaces plus 4 per tab.
    private static func leadingColumns(_ line: String) -> Int {
        var n = 0
        for ch in line.utf8 {
            if ch == 32 { n += 1 } else if ch == 9 { n += 4 } else { break }
        }
        return n
    }

    /// Removes at most `indent` leading spaces: the indent of the opening fence.
    private static func removeIndent(_ line: String, upTo indent: Int) -> String {
        var run = 0
        for ch in line.utf8 { if ch == 32 && run < indent { run += 1 } else { break } }
        return run == 0 ? line : String(line.dropFirst(run))
    }

    /// `<br>`, `<br/>` and `<br />` become a newline, except inside an inline code span. No other HTML is read.
    private static func lineBreaks(_ s: String) -> String {
        guard s.contains("<") else { return s }
        let chars = Array(s)
        // Code spans: a backtick run closed by a run of the same length.
        var spans: [Range<Int>] = []
        var open: (start: Int, length: Int)?
        var i = 0
        while i < chars.count {
            guard chars[i] == "`" else { i += 1; continue }
            var n = 0
            while i + n < chars.count && chars[i + n] == "`" { n += 1 }
            if let o = open {
                if o.length == n { spans.append(o.start..<(i + n)); open = nil }
            } else { open = (i, n) }
            i += n
        }
        var out = ""
        var span = 0
        i = 0
        while i < chars.count {
            if span < spans.count, i >= spans[span].upperBound { span += 1; continue }
            let inCode = span < spans.count && spans[span].contains(i)
            if chars[i] == "<", !inCode, let length = brTagLength(chars, at: i) {
                out.append("\n"); i += length; continue
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    private static func brTagLength(_ chars: [Character], at i: Int) -> Int? {
        let head = String(chars[i..<min(i + 6, chars.count)]).lowercased()
        for tag in ["<br />", "<br/>", "<br>"] where head.hasPrefix(tag) { return tag.count }
        return nil
    }

    // MARK: Fences

    private struct Fence { let char: Character; let count: Int; let indent: Int; let lang: String }

    private static func openingFence(_ line: String) -> Fence? {
        let indent = leadingColumns(line)
        let s = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = s.first, first == "`" || first == "~" else { return nil }
        let count = s.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = s.dropFirst(count).trimmingCharacters(in: .whitespaces)
        // A backtick fence has no backtick in its info string: ```code``` on one line is inline code.
        if first == "`" && info.contains("`") { return nil }
        return Fence(char: first, count: count, indent: indent, lang: String(info.prefix(maxLanguageChars)))
    }

    private static func closes(_ line: String, fence: Fence) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard s.count >= fence.count else { return false }
        return s.allSatisfy { $0 == fence.char }
    }

    /// For each line, whether it is part of a fenced code block (the fence lines included). A fence that never closes
    /// holds the lines to the end, as `parse` reads it. The same fence rules as `parse`, written once.
    static func codeLineMask(_ lines: [String]) -> [Bool] {
        var mask = [Bool](repeating: false, count: lines.count)
        var i = 0
        while i < lines.count {
            guard let fence = openingFence(lines[i]) else { i += 1; continue }
            mask[i] = true
            i += 1
            while i < lines.count && !closes(lines[i], fence: fence) { mask[i] = true; i += 1 }
            if i < lines.count { mask[i] = true }
            i += 1
        }
        return mask
    }

    // MARK: Rules, quotes, lists

    /// 3 or more of the same `-`, `*` or `_`, spaces allowed between them, nothing else.
    private static func isRule(_ stripped: String) -> Bool {
        guard let first = stripped.first, first == "-" || first == "*" || first == "_" else { return false }
        var n = 0
        for ch in stripped {
            if ch == first { n += 1 } else if ch != " " && ch != "\t" { return false }
        }
        return n >= 3
    }

    private static func isQuoteLine(_ stripped: String) -> Bool {
        guard stripped.hasPrefix(">") else { return false }
        if stripped.count == 1 { return true }
        let second = stripped[stripped.index(after: stripped.startIndex)]
        return second == " " || second == ">"
    }

    /// The text of a quote line, with every leading `>` (one level) and the space after it removed.
    private static func quoteText(_ stripped: String) -> String {
        var s = Substring(stripped)
        while s.hasPrefix(">") { s = s.dropFirst(); if s.hasPrefix(" ") { s = s.dropFirst() } }
        return String(s)
    }

    private enum ItemKind { case bullet, ordered(String), task(checked: Bool) }

    /// A list item of an already stripped line: bullet, task (`- [ ] `, `- [x] `), or numbered (`1.` / `1)`), the
    /// marker followed by a space or a tab. `bare`: a marker alone is the empty item (a text still arriving).
    private static func listItem(_ s: String, bare: Bool = false) -> (kind: ItemKind, text: String)? {
        let utf8 = Array(s.utf8.prefix(12))
        guard let first = utf8.first else { return nil }
        if bare, let item = loneMarker(s) { return item }
        if (first == 45 || first == 42 || first == 43), utf8.count >= 2, utf8[1] == 32 || utf8[1] == 9 {   // - * +
            let text = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if text == "[ ]" || text.hasPrefix("[ ] ") { return (.task(checked: false), String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces)) }
            if text == "[x]" || text == "[X]" || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                return (.task(checked: true), String(text.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
            return (.bullet, text)
        }
        // Numbered: 1 to 9 digits, then `.` or `)`, then a space. Scanned by character, no regular expression.
        var digits = 0
        while digits < utf8.count, digits < 9, utf8[digits] >= 48, utf8[digits] <= 57 { digits += 1 }
        guard digits >= 1, digits < utf8.count, utf8[digits] == 46 || utf8[digits] == 41,
              digits + 1 < utf8.count, utf8[digits + 1] == 32 || utf8[digits + 1] == 9 else { return nil }
        let number = String(decoding: utf8[0..<digits], as: UTF8.self)
        return (.ordered(number), String(s.dropFirst(digits + 2)).trimmingCharacters(in: .whitespaces))
    }

    /// `-`, `*`, `+`, `1.` or `2)` alone on a line.
    private static func loneMarker(_ s: String) -> (kind: ItemKind, text: String)? {
        if s == "-" || s == "*" || s == "+" { return (.bullet, "") }
        let u = Array(s.utf8)
        guard u.count >= 2, u.count <= 10, u.last == 46 || u.last == 41,
              u.dropLast().allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return (.ordered(String(decoding: u.dropLast(), as: UTF8.self)), "")
    }

    // MARK: Tables

    /// Cells of a table line: optional leading and trailing pipe, `\|` is a literal pipe, cells trimmed.
    static func splitCells(_ line: String) -> [String] {
        let s = line.trimmingCharacters(in: .whitespaces)
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped {
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        if s.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if s.hasSuffix("|"), !s.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { lineBreaks($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The alignments of a delimiter line (`---`, `:--`, `:-:`, `--:` cells, `|` in the line), nil when it is not one
    /// or its cell count is not `count`.
    private static func delimiterAligns(_ line: String, count: Int) -> [MDAlign]? {
        guard line.contains("|") else { return nil }
        let cells = splitCells(line)
        guard cells.count == count else { return nil }
        var aligns: [MDAlign] = []
        for cell in cells {
            var core = Substring(cell)
            let left = core.hasPrefix(":")
            if left { core = core.dropFirst() }
            let right = core.hasSuffix(":")
            if right { core = core.dropLast() }
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            aligns.append(left && right ? .center : right ? .trailing : .leading)
        }
        return aligns
    }

    /// A delimiter line still being written: only `|`, `-`, `:` and spaces.
    private static func isDelimiterInProgress(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && s.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }
    }

    private static func parseTable(_ lines: [String], from i: Int, lastIdx: Int, streaming: Bool)
        -> (blocks: [MDBlock], next: Int)? {
        let header = splitCells(lines[i])
        guard !header.isEmpty, header.count <= maxTableColumns else { return nil }
        let leadingPipe = lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|")
        let leading = [MDAlign](repeating: .leading, count: header.count)
        if i + 1 < lines.count, let aligns = delimiterAligns(lines[i + 1], count: header.count) {
            var raw: [[String]] = []
            var hidden = 0
            var j = i + 2
            while j < lines.count {
                let row = lines[j]
                let stripped = row.trimmingCharacters(in: .whitespaces)
                if stripped.isEmpty || openingFence(row) != nil { break }
                if !row.contains("|") {
                    // Streaming, header without leading pipe: the last line is a row still being written.
                    guard streaming, !leadingPipe, j == lastIdx, !startsOtherBlock(stripped) else { break }
                }
                if raw.count < maxTableRows { raw.append(splitCells(row)) } else { hidden += 1 }
                j += 1
            }
            // A row longer than the header widens the table, up to the column cap.
            let width = min(max(header.count, raw.map { $0.count }.max() ?? 0), maxTableColumns)
            let widened = header + [String](repeating: "", count: width - header.count)
            let alignment = aligns + [MDAlign](repeating: .leading, count: width - aligns.count)
            var blocks: [MDBlock] = [.table(header: widened, align: alignment, rows: raw.map { fit($0, to: width) })]
            if hidden > 0 { blocks.append(.hiddenRows(count: hidden)) }
            return (blocks, j)
        }
        guard streaming, header.count >= 2 else { return nil }
        // Streaming: the header line is already a table; a half written delimiter line is not shown.
        let headerOnly = [MDBlock.table(header: header, align: leading, rows: [])]
        let after = lines.count - 1 - i
        if leadingPipe, after == 0 || (after == 1 && lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty) {
            return (headerOnly, i + 1)
        }
        if i + 1 == lastIdx, isDelimiterInProgress(lines[i + 1]), leadingPipe || lines[i + 1].contains("|"),
           lines.count - 1 - (i + 1) <= 1 {
            return (headerOnly, i + 2)
        }
        return nil
    }

    /// A line that opens a block of its own: not a table row in progress.
    private static func startsOtherBlock(_ stripped: String) -> Bool {
        headingLine(stripped) != nil || isQuoteLine(stripped) || isRule(stripped) || listItem(stripped, bare: true) != nil
    }

    private static func fit(_ cells: [String], to count: Int) -> [String] {
        if cells.count == count { return cells }
        if cells.count > count { return Array(cells.prefix(count)) }
        return cells + [String](repeating: "", count: count - cells.count)
    }
}
