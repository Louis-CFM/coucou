import SwiftUI

// MARK: - Code view
//
// While Claude Code works, a small editor: the file it just changed (the file's own
// lines around the edit, removed lines in red, added in green) and under it the last
// command with what it printed, next to Mochi and the phases of the turn.
// Opened from the overview's left card; data in AppState.codeSessions (CodeSession.swift).

struct CodeSessionView: View {
    @ObservedObject var state: AppState

    private static let codeRows = 11

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            if let task = state.focusTask, let session = state.codeSessions[task.id], session.hasContent {
                HStack(alignment: .top, spacing: 12) {
                    CodePhasesView(session: session, color: task.color)
                        .frame(width: 104, alignment: .leading)
                        .padding(.top, 66)
                    CodeEditorView(session: session, maxRows: session.command == nil ? Self.codeRows : Self.codeRows - 4)
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
            }
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(Color(hex: "#5F646D"))
                    .frame(width: 16, height: 16)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Back"))
            .padding(.top, 10)
            .padding(.leading, 10)
        }
        .onExitCommand(perform: back)
    }

    private func back() {
        withAnimation(.easeIn(duration: 0.16)) { state.view = .overview }
    }
}

// MARK: - Phases

private struct CodePhasesView: View {
    let session: CodeSession
    let color: String

    private static let labels: [(CodePhase, String, String)] = [
        (.read, "Read", "doc.text"),
        (.edit, "Edit", "pencil"),
        (.bash, "Bash", "terminal"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: color)).frame(width: 7, height: 7)
                Text(session.project)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(verbatim: "Claude Code")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .padding(.bottom, 6)
            ForEach(Self.labels, id: \.0) { phase, label, icon in
                let active = !session.finished && session.current == phase
                row(label: label, icon: icon, state: active ? .active : session.seen.contains(phase) ? .done : .todo)
            }
            row(label: "Done", icon: "checkmark.circle", state: session.finished ? .done : .todo)
        }
    }

    private enum RowState { case done, active, todo }

    private func row(label: String, icon: String, state: RowState) -> some View {
        HStack(spacing: 6) {
            Group {
                switch state {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundColor(Color(hex: "#22C55E"))
                case .active:
                    ProgressView().controlSize(.mini).tint(Color(hex: "#F5F6F8"))
                case .todo:
                    Image(systemName: icon).foregroundColor(Color(hex: "#454850"))
                }
            }
            .font(.system(size: 11))
            .frame(width: 14, height: 14)
            Text(LocalizedStringKey(label))
                .font(.system(size: 11.5, weight: state == .active ? .semibold : .regular))
                .foregroundColor(state == .todo ? Color(hex: "#6B7079") : Color(hex: "#F5F6F8"))
        }
    }
}

// MARK: - Editor

private struct CodeEditorView: View {
    let session: CodeSession
    let maxRows: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tab
            if let edit = session.edit, !edit.pending {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(CodeView.fit(CodeView.rows(for: edit), max: maxRows).enumerated()), id: \.offset) { _, row in
                        CodeRowView(row: row)
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
            if let command = session.command {
                CodeTerminalView(command: command)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: "#0D0E11"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static let chips: [String: (String, String)] = [
        "ts": ("TS", "#3B82F6"), "tsx": ("TS", "#3B82F6"), "js": ("JS", "#EAB308"), "jsx": ("JS", "#EAB308"),
        "swift": ("SW", "#F97316"), "py": ("PY", "#38BDF8"), "rs": ("RS", "#F97316"), "go": ("GO", "#22D3EE"),
        "md": ("MD", "#9CA3AF"), "json": ("{}", "#A3A3A3"), "css": ("CS", "#A78BFA"), "html": ("<>", "#FB923C"),
        "sh": ("SH", "#86EFAC"), "yml": ("YM", "#F472B6"), "yaml": ("YM", "#F472B6"), "toml": ("TM", "#FBBF24"),
        "php": ("PH", "#818CF8"),
    ]

    private var tab: some View {
        HStack(spacing: 6) {
            if let edit = session.edit {
                let name = (edit.file as NSString).lastPathComponent
                let (label, color) = Self.chips[(name as NSString).pathExtension.lowercased()] ?? ("·", "#6B7079")
                Text(verbatim: label)
                    .font(.system(size: 8, weight: .bold).monospaced())
                    .foregroundColor(Color(hex: color))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color(hex: color).opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(verbatim: name)
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: edit.file)
                    .font(.system(size: 10).monospaced())
                    .foregroundColor(Color(hex: "#5F646D"))
                    .lineLimit(1)
                    .truncationMode(.head)
            } else {
                Text(verbatim: "terminal")
                    .font(.system(size: 11).monospaced())
                    .foregroundColor(Color(hex: "#8E939C"))
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.white.opacity(0.03))
    }
}

private struct CodeRowView: View {
    let row: CodeRow

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: row.number.map(String.init) ?? "")
                .font(.system(size: 10).monospaced())
                .foregroundColor(Color(hex: "#454850"))
                .frame(width: 30, alignment: .trailing)
                .padding(.trailing, 6)
            Text(verbatim: row.kind == .added ? "+" : row.kind == .removed ? "−" : " ")
                .font(.system(size: 10.5).monospaced())
                .foregroundColor(row.kind == .added ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                .frame(width: 12, alignment: .leading)
            Text(CodeHighlight.line(row.text, dimmed: row.kind == .removed))
                .font(.system(size: 10.5).monospaced())
                .strikethrough(row.kind == .removed, color: Color(hex: "#F4505E").opacity(0.6))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 14)
        .background(background)
        .overlay(alignment: .leading) {
            if row.kind != .context {
                Rectangle().fill(row.kind == .added ? Color(hex: "#22C55E") : Color(hex: "#F4505E")).frame(width: 2)
            }
        }
    }

    private var background: Color {
        switch row.kind {
        case .added:   return Color(hex: "#22C55E").opacity(0.12)
        case .removed: return Color(hex: "#F4505E").opacity(0.12)
        case .context: return .clear
        }
    }
}

private struct CodeTerminalView: View {
    let command: CodeCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: "$").foregroundColor(Color(hex: "#22C55E"))
                Text(verbatim: command.command.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if command.status == .running {
                    Text(verbatim: "…").foregroundColor(Color(hex: "#8E939C"))
                }
            }
            ForEach(Array(command.tail.suffix(2).enumerated()), id: \.offset) { _, line in
                tailLine(line)
            }
            if command.status == .failed && command.tail.isEmpty {
                Text(verbatim: "✗ failed").foregroundColor(Color(hex: "#F4505E"))
            }
        }
        .font(.system(size: 10.5).monospaced())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
    }

    @ViewBuilder
    private func tailLine(_ text: String) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let badge = ["PASS", "FAIL"].first(where: { trimmed.hasPrefix($0 + " ") || trimmed == $0 }) {
            HStack(spacing: 6) {
                Text(verbatim: badge)
                    .font(.system(size: 9, weight: .bold).monospaced())
                    .foregroundColor(.black)
                    .padding(.horizontal, 4)
                    .background(badge == "PASS" ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(verbatim: String(trimmed.dropFirst(badge.count)).trimmingCharacters(in: .whitespaces))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
            }
        } else {
            Text(verbatim: trimmed).foregroundColor(Self.tone(trimmed)).lineLimit(1).truncationMode(.tail)
        }
    }

    private static func tone(_ text: String) -> Color {
        let lower = text.lowercased()
        if text.contains("✓") || text.contains("✔") || lower.contains("passed") { return Color(hex: "#86EFAC") }
        if text.contains("✗") || text.contains("✘") || lower.contains("fail") || lower.contains("error") { return Color(hex: "#FCA5A5") }
        return Color(hex: "#8E939C")
    }
}

// MARK: - Highlighting

/// A light, language-agnostic colouring: comments, strings, numbers, keywords, types, calls.
enum CodeHighlight {
    private static let pattern = try! NSRegularExpression(pattern:
        #"(//.*|^\s*#.*)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`)|\b(\d+(?:\.\d+)?)\b|\b(const|let|var|func|function|return|import|export|from|if|else|guard|for|while|class|struct|enum|new|async|await|def|fn|pub|use|type|interface|impl|match|in|of|true|false|nil|null|None|self)\b|\b([A-Z][A-Za-z0-9_]*)\b|\b([a-z_][A-Za-z0-9_]*)(?=\()"#)

    private static let colors = ["#5C6370", "#98C379", "#D19A66", "#C678DD", "#E5C07B", "#61AFEF"]

    static func line(_ text: String, dimmed: Bool) -> AttributedString {
        var out = AttributedString(text)
        out.foregroundColor = dimmed ? Color(hex: "#FCA5A5").opacity(0.7) : Color(hex: "#ABB2BF")
        guard !dimmed else { return out }
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let group = (1...6).first(where: { match.range(at: $0).location != NSNotFound }),
                  let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].foregroundColor = Color(hex: colors[group - 1])
        }
        return out
    }
}
