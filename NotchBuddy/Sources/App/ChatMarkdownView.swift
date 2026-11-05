import SwiftUI

// MARK: - Markdown renderer for chat assistant messages

/// Equatable on what it draws, and used with `.equatable()`: while a text streams, only the block that grows is
/// parsed and laid out again.
struct ChatMarkdownView: View, Equatable {
    enum Style: Equatable {
        /// The answer: bright text.
        case answer
        /// Text written between tools: same layout, dimmer.
        case interim
        /// Interim text inside the unfolded list of steps: the same colours, smaller.
        case folded
        /// The answer of an agent turn: one soft card with sections. `verdict`: the first paragraph is the conclusion
        /// of a turn that did work.
        case card(verdict: Bool)
    }

    let markdown: String
    var style: Style = .answer
    /// The text is still arriving: a half written marker is held back or closed (`ChatMarkdown.parse`).
    var streaming = false

    nonisolated static func == (a: ChatMarkdownView, b: ChatMarkdownView) -> Bool {
        a.markdown == b.markdown && a.style == b.style && a.streaming == b.streaming
    }

    private var isAnswer: Bool { style == .answer }
    private var textColor: Color { Color(hex: isAnswer ? "#C9CDD4" : "#8A8F98") }
    private var boldColor: Color { Color(hex: isAnswer ? "#F1F2F4" : "#C9CDD4") }
    /// The interim text of the unfolded list is smaller than the one of the live box.
    private var bodySize: CGFloat { style == .folded ? 11.5 : 12.5 }

    @Environment(\.chatMedia) private var media

    var body: some View {
        // The directives of an agent that hands over files (`MEDIA:/path`, `[[audio_as_voice]]`) are taken out of the
        // text at display time: the card draws a row where each one was, everything else shows the text without them.
        let extraction: ChatMediaExtraction? = media.enabled ? ChatMediaDirectives.extractCached(markdown, streaming: streaming) : nil
        let isCard: Bool = { if case .card = style { return true }; return false }()
        let shownText = extraction.map { isCard ? $0.marked : $0.text } ?? markdown
        let blocks = ChatMarkdown.parse(shownText, streaming: streaming)
        Group {
            if case .card(let verdict) = style {
                card(blocks, verdict: verdict, attachments: extraction?.attachments ?? [])
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        blockView(block, isFirst: index == 0)
                    }
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let safe = safeWebURL(url.absoluteString) else { return .discarded }
            NSWorkspace.shared.open(safe)
            return .handled
        })
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock, isFirst: Bool) -> some View {
        switch block {
        case .heading(let level, let text):
            LinkedText(inlineAttributed(text))
                .font(.system(size: Self.headingSize(level), weight: level <= 2 ? .bold : .semibold))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.top, isFirst ? 0 : 4)

        case .paragraph(let text):
            LinkedText(inlineAttributed(text))
                .font(.system(size: bodySize))
                .lineSpacing(2)
                .foregroundColor(textColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .codeBlock(let lang, let code):
            ChatCodeBlock(lang: lang, code: code)

        case .listItem(let prefix, let text, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text(verbatim: prefix)
                    .font(.system(size: 12.5).monospacedDigit())
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(minWidth: prefix.count > 2 ? Self.longMarkerWidth : Self.markerWidth, alignment: .leading)
                LinkedText(inlineAttributed(text))
                    .font(.system(size: bodySize))
                    .lineSpacing(2)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .taskItem(let checked, let text, let indent):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: checked ? "#22C55E" : "#6B7079"))
                    .frame(minWidth: Self.markerWidth, alignment: .leading)
                    .padding(.top, 1)
                LinkedText(inlineAttributed(text))
                    .font(.system(size: bodySize))
                    .lineSpacing(2)
                    .foregroundColor(textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 12)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color(hex: "#4B5563"))
                    .frame(width: 2)
                    .clipShape(Capsule())
                LinkedText(inlineAttributed(text))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#8A8F98"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Divider().opacity(0.3)

        case .table(let header, let align, let rows):
            ChatTableView(header: header, align: align, rows: rows,
                          bodyAttributed: { inlineAttributed($0) },
                          headerAttributed: { inlineAttributed($0, bold: Color(hex: "#F1F2F4")) },
                          bodyColor: textColor)

        case .hiddenRows(let count):
            Text("Rows hidden: \(count)")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .textSelection(.enabled)
        }
    }

    // MARK: Card

    /// The answer card: the sections of `ChatAnswerRules` drawn inside one soft container. Each item is an Equatable
    /// view, so while the text streams only the open last item is laid out again.
    private func card(_ blocks: [MDBlock], verdict: Bool, attachments: [ChatAttachment]) -> some View {
        let items = ChatAnswerRules.sections(blocks: blocks, streaming: streaming, verdict: verdict, attachments: attachments.count)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                ChatCardItemView(item: item,
                                 top: ChatCardItemView.gap(before: item, after: index > 0 ? items[index - 1] : nil),
                                 open: streaming && index == items.count - 1,
                                 attachment: { if case .attachment(let id) = item { return attachments.first { $0.id == id } }; return nil }())
                    .equatable()
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    /// The text of bullet, task and numbered items starts at one left edge per level.
    private static let markerWidth: CGFloat = 16
    private static let longMarkerWidth: CGFloat = 24

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 15
        case 2: return 14
        case 3: return 13
        default: return 12.5
        }
    }

    /// Markdown inline syntax (`AttributedString`), then one pass over the runs for the colours: inline code,
    /// bold and links. A link is only ever opened through `safeWebURL` (the `openURL` action above).
    private func inlineAttributed(_ text: String, bold: Color? = nil) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        // Override and isolate characters inside inline code are dropped for display (code blocks are cleaned by the parser).
        let shownText = ChatMarkdown.withoutBidiControlsInCodeSpans(text)
        var attributed = (try? AttributedString(markdown: shownText, options: options)) ?? AttributedString(shownText)
        let strong = bold ?? boldColor
        for run in Array(attributed.runs) {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { attributed[run.range].foregroundColor = strong }
                if intent.contains(.code) {
                    attributed[run.range].font = .system(size: 11.5, design: .monospaced)
                    attributed[run.range].foregroundColor = Color(hex: "#E8E9EC")
                    attributed[run.range].backgroundColor = Color.white.opacity(0.1)
                }
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Color(hex: "#60A5FA")
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

// MARK: - Links

/// Text with markdown links. Hovering it shows the real host of each link that can open (the standard help
/// tooltip; none at all when the text has no link). Each link is judged in its context (`linkGroups`): the text around it
/// up to the nearest whitespace is the label. A destination that is not known to open at once asks first
/// (`LinkConfirmation`); a link whose destination `safeWebURL` rejects loses its click. The text itself looks the same
/// in every case.
private struct LinkedText: View {
    let attributed: AttributedString

    init(_ attributed: AttributedString) { self.attributed = attributed }

    var body: some View {
        var shown = attributed
        let runs = Array(attributed.runs)
        let groups = linkGroups(runs.map { LinkRun(text: String(attributed[$0.range].characters), destination: $0.link?.absoluteString) })
        var labels: [String: String] = [:]       // destination -> its label as drawn, for the dialog
        for group in groups {
            for position in group.runs {
                if group.outcome == .discard { shown[runs[position].range].link = nil }
            }
            for destination in group.destinations where labels[destination] == nil { labels[destination] = group.label }
        }
        let opens = linkDestinationsThatOpen(groups)
        let tooltip = linkTooltip(destinations: groups.flatMap { $0.destinations })
        return Group {
            if tooltip.isEmpty { Text(shown) } else { Text(shown).help(tooltip) }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let safe = safeWebURL(url.absoluteString) else { return .discarded }
            // Only a destination known to open at once opens; anything else, a missed lookup included, asks.
            if opens.contains(url.absoluteString) {
                NSWorkspace.shared.open(safe)
                return .handled
            }
            LinkConfirmation.ask(destination: safe, label: labels[url.absoluteString] ?? "")
            return .handled
        })
    }
}

/// The system confirmation of a link that is not known to go where its label says. Cancel has Escape and Return; `Open`
/// has no key at all. Closing the dialog any other way opens nothing. Shown only from a click on a link, after the click
/// handler has returned (so SwiftUI is not inside the modal loop); hook connections are on other queues and are not held.
@MainActor
enum LinkConfirmation {
    private static var asking = false

    static func ask(destination: URL, label: String) {
        guard !asking else { return }
        asking = true
        DispatchQueue.main.async {
            defer { asking = false }
            NSApp.activate(ignoringOtherApps: true)
            // The host first and alone, then a short plain label: nothing in the label can push the host out of sight.
            let parts = linkDialogParts(destination: destination.absoluteString, label: label)
            let alert = NSAlert()
            alert.messageText = String(localized: "Open \(parts.host)?")
            alert.informativeText = String(localized: "It goes to \(parts.host). The link is shown as “\(parts.label)”.")
            alert.alertStyle = .warning
            let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
            let open = alert.addButton(withTitle: String(localized: "Open"))
            // One key per button: Escape on Cancel, Return cancelled by the monitor below, nothing on Open.
            cancel.keyEquivalent = "\u{1b}"
            open.keyEquivalent = ""
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Only a Return typed in the dialog itself; a key for any other window of the app goes on untouched.
                guard event.window === alert.window, event.keyCode == 36 || event.keyCode == 76 else { return event }
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                return nil
            }
            defer { if let monitor { NSEvent.removeMonitor(monitor) } }
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(destination) }
        }
    }
}

// MARK: - Code block

/// Header strip (language, Copy) over the code. Long lines scroll sideways; each line is cut for display at
/// `maxCodeLineChars`, Copy gives the whole code.
private struct ChatCodeBlock: View {
    let lang: String
    let code: String
    /// Inside the answer card: a rounder inset.
    var card = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !lang.isEmpty {
                    Text(verbatim: lang)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                CopyButton(text: code)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: shown)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#C8CDD4"))
                    .fixedSize(horizontal: true, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0D0E12"))
        .clipShape(RoundedRectangle(cornerRadius: card ? 10 : 8))
        .overlay(RoundedRectangle(cornerRadius: card ? 10 : 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var shown: String {
        let limit = ChatMarkdown.maxCodeLineChars
        guard code.utf8.count > limit else { return code }
        return code.components(separatedBy: "\n").map { line in
            line.utf8.count > limit ? String(line.prefix(limit)) + "…" : line
        }.joined(separator: "\n")
    }
}

// MARK: - Table

private struct ChatTableView: View {
    let header: [String]
    let align: [MDAlign]
    let rows: [[String]]
    let bodyAttributed: (String) -> AttributedString
    let headerAttributed: (String) -> AttributedString
    let bodyColor: Color

    private static let maxColumnWidth: CGFloat = 220

    private func alignment(_ column: Int) -> Alignment {
        guard column < align.count else { return .leading }
        switch align[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        guard column < align.count else { return .leading }
        switch align[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                        LinkedText(headerAttributed(cell))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#F1F2F4"))
                            .multilineTextAlignment(textAlignment(column))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Self.maxColumnWidth, alignment: alignment(column))
                            .frame(maxWidth: .infinity, alignment: alignment(column))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.06))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Color.white.opacity(0.06).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            LinkedText(bodyAttributed(cell))
                                .font(.system(size: 12.5))
                                .foregroundColor(bodyColor)
                                .multilineTextAlignment(textAlignment(column))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .frame(maxWidth: Self.maxColumnWidth, alignment: alignment(column))
                                .frame(maxWidth: .infinity, alignment: alignment(column))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }
                }
            }
            // The frame hugs the table, not the width of the chat.
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
    }
}

// MARK: - Copy button

private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundColor(copied ? Color(hex: "#22C55E") : Color(hex: "#6B7079"))
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - The answer card

private extension StatusKind {
    var color: Color {
        switch self {
        case .good: return Color(hex: "#22C55E")
        case .warn: return Color(hex: "#F5A524")
        case .bad: return Color(hex: "#F4505E")
        case .mute: return Color(hex: "#8E939C")
        }
    }
}

/// Inline text of the card: the markdown the app already reads (bold, code, links) plus the marks of
/// `ChatAnswerRules` (status words, amounts, dates and times) when `marks` is true. The marks only change colour,
/// weight and size: the characters are the agent's, in order. A link is only ever opened through `safeWebURL`.
private enum ChatCardText {
    static func attributed(_ text: String, size: CGFloat, marks: Bool, strong: Color = Color(hex: "#F1F2F4")) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        options.failurePolicy = .returnPartiallyParsedIfPossible
        let shownText = ChatMarkdown.withoutBidiControlsInCodeSpans(text)
        var attributed = (try? AttributedString(markdown: shownText, options: options)) ?? AttributedString(shownText)
        for run in Array(attributed.runs) {
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    attributed[run.range].foregroundColor = strong
                    attributed[run.range].font = .system(size: size, weight: .semibold)
                }
                if intent.contains(.code) {
                    attributed[run.range].font = .system(size: size - 1, design: .monospaced)
                    attributed[run.range].foregroundColor = Color(hex: "#E8E9EC")
                    attributed[run.range].backgroundColor = Color.white.opacity(0.1)
                }
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Color(hex: "#60A5FA")
                attributed[run.range].underlineStyle = .single
            }
        }
        if marks {
            for mark in ChatAnswerRules.marks(in: attributed) {
                switch mark.kind {
                case .status(_, let kind):
                    attributed[mark.range].foregroundColor = kind.color
                    attributed[mark.range].font = .system(size: size - 0.5, weight: .semibold)
                case .amount:
                    attributed[mark.range].foregroundColor = strong
                    attributed[mark.range].font = .system(size: size, weight: .semibold).monospacedDigit()
                case .time:
                    attributed[mark.range].foregroundColor = strong
                    attributed[mark.range].font = .system(size: size, weight: .medium).monospacedDigit()
                }
            }
        }
        return attributed
    }
}

/// A status word as a capsule. Status words are fixed English words of the agents' platforms: verbatim.
private struct StatusCapsule: View {
    let word: String
    let kind: StatusKind
    var size: CGFloat = 10.5
    var dot = true
    /// The word of a table cell is the only place it is drawn: it can be selected and copied. The strip repeats words
    /// of the body and stays out of the selection.
    var selectable = false

    var body: some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(kind.color).frame(width: 5, height: 5) }
            if selectable { label.textSelection(.enabled) } else { label }
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(kind.color.opacity(0.15))
        .clipShape(Capsule())
        .fixedSize()
    }

    private var label: some View {
        Text(verbatim: word)
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(kind.color)
            .lineLimit(1)
    }
}

/// The status words of a section under its lead: the first four, then a grey `+N`. Not selectable and hidden from
/// VoiceOver: the same words are in the text below.
private struct StatusStrip: View {
    let words: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(limit: 4)
            row(limit: 3)
            row(limit: 2)
            row(limit: 1)
        }
        .accessibilityHidden(true)
    }

    private func row(limit: Int) -> some View {
        let shown = Array(words.prefix(limit))
        let rest = words.count - shown.count
        return HStack(spacing: 6) {
            ForEach(shown, id: \.self) { word in
                StatusCapsule(word: word, kind: ChatAnswerRules.statusOnly(word)?.kind ?? .mute)
            }
            if rest > 0 { StatusCapsule(word: "+\(rest)", kind: .mute, dot: false) }
        }
        .fixedSize()
    }
}

/// One thing the card draws. Equatable on its inputs and used with `.equatable()`: it is the unit that is skipped
/// while a later block of the same answer streams.
private struct ChatCardItemView: View, Equatable {
    let item: CardItem
    /// Space above, decided from the previous item.
    let top: CGFloat
    /// The last item of a text that is still arriving: drawn as plain body, no marks.
    let open: Bool
    /// The attachment of an `.attachment` item.
    var attachment: ChatAttachment? = nil

    nonisolated static func == (a: ChatCardItemView, b: ChatCardItemView) -> Bool {
        a.item == b.item && a.top == b.top && a.open == b.open && a.attachment == b.attachment
    }

    private let body13 = Color(hex: "#C9CDD4")
    private let bright = Color(hex: "#F1F2F4")
    private let title = Color(hex: "#F5F6F8")

    /// Space above an item, by the item before it. A hairline carries its own space; so does a heading below.
    static func gap(before item: CardItem, after previous: CardItem?) -> CGFloat {
        guard let previous else { return 0 }
        if case .hairline = previous { return 0 }
        switch item {
        case .attachment: return 12
        case .hairline, .section, .verdict: return 0
        case .ask: return 12
        case .block(let block, _):
            switch block {
            case .paragraph:
                if case .attachment = previous { return 12 }
                return 10
            case .heading(let level, _): return level <= 2 ? 16 : 14
            case .listItem, .taskItem:
                // A heading carries its own space below, a table its padding, a list item its own.
                if case .block(let before, _) = previous {
                    switch before { case .listItem, .taskItem, .heading, .table: return 0; default: break }
                }
                return 6
            case .table:
                if case .block(.heading, _) = previous { return 0 }
                return 6
            case .quote, .hiddenRows: return 6
            case .codeBlock: return 2
            case .rule: return 0
            }
        }
    }

    var body: some View {
        content.padding(.top, top)
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .hairline:
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1).padding(.vertical, 13)
        case .attachment:
            if let attachment { ChatAttachmentRow(attachment: attachment) }
        case .verdict(let text):
            LinkedText(ChatCardText.attributed(text, size: 14.5, marks: !open))
                .font(.system(size: 14.5)).lineSpacing(5).foregroundColor(bright)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .section(let lead, let lines):
            // Computed here, in the Equatable item: once when the paragraph closes, not while a later block streams.
            let strip = ChatAnswerRules.showsStatusStrip ? ChatAnswerRules.statusStrip(lines: lines) : []
            VStack(alignment: .leading, spacing: 0) {
                LinkedText(ChatCardText.attributed(lead, size: 13.5, marks: false, strong: title))
                    .font(.system(size: 13.5, weight: .semibold)).foregroundColor(title)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !strip.isEmpty { StatusStrip(words: strip).padding(.top, 7) }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(ChatAnswerRules.bodyTexts(lines: lines).enumerated()), id: \.offset) { _, line in
                        bodyText(line, marks: true)
                    }
                }
                .padding(.top, 8)
            }
        case .ask(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 14)).foregroundColor(Color(hex: "#F5A524"))
                    .accessibilityHidden(true)
                LinkedText(ChatCardText.attributed(text, size: 13, marks: true))
                    .font(.system(size: 13)).lineSpacing(4).foregroundColor(bright)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: "#F5A524").opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#F5A524").opacity(0.25), lineWidth: 1))
        case .block(let block, let closed):
            blockView(block, marks: closed)
        }
    }

    private func bodyText(_ text: String, marks: Bool, color: Color? = nil) -> some View {
        LinkedText(ChatCardText.attributed(text, size: 13, marks: marks && !open))
            .font(.system(size: 13)).lineSpacing(4).foregroundColor(color ?? body13)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    @ViewBuilder private func blockView(_ block: MDBlock, marks: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            bodyText(text, marks: marks)
        case .heading(let level, let text):
            LinkedText(ChatCardText.attributed(text, size: level <= 2 ? 15 : 13.5, marks: false, strong: title))
                .font(.system(size: level <= 2 ? 15 : 13.5, weight: level <= 2 ? .bold : .semibold))
                .foregroundColor(title)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.bottom, 8)
        case .listItem(let prefix, let text, let indent):
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: prefix)
                    .font(.system(size: 13).monospacedDigit()).foregroundColor(Color(hex: "#6B7079"))
                    .frame(minWidth: prefix.count > 2 ? 24 : 6.5, alignment: .leading)
                bodyText(text, marks: marks)
            }
            .padding(.leading, CGFloat(indent) * 12).padding(.bottom, 4)
        case .taskItem(let checked, let text, let indent):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12)).foregroundColor(Color(hex: checked ? "#22C55E" : "#6B7079"))
                    .padding(.top, 2)
                bodyText(text, marks: marks)
            }
            .padding(.leading, CGFloat(indent) * 12).padding(.bottom, 4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color(hex: "#4B5563")).frame(width: 2).clipShape(Capsule())
                bodyText(text, marks: marks, color: Color(hex: "#8A8F98"))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            EmptyView()
        case .codeBlock(let lang, let code):
            ChatCodeBlock(lang: lang, code: code, card: true).padding(.bottom, 12)
        case .table(let header, let align, let rows):
            ChatCardTable(header: header, align: align, rows: rows, marks: marks).padding(.bottom, 12)
        case .hiddenRows(let count):
            Text("Rows hidden: \(count)")
                .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).textSelection(.enabled)
        }
    }
}

/// The table of the card: a dark inset with a header band and hairline rows. When it fits, it fills the card and the
/// widest text column takes the spare width; when it does not, it scrolls sideways with the columns capped at 220.
private struct ChatCardTable: View {
    let header: [String]
    let align: [MDAlign]
    let rows: [[String]]
    let marks: Bool

    private static let maxColumnWidth: CGFloat = 220

    private func alignment(_ column: Int) -> Alignment {
        guard column < align.count else { return .leading }
        switch align[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        guard column < align.count else { return .leading }
        switch align[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// The widest leading aligned column takes the spare width.
    private var stretch: Int {
        var best = 0, bestLength = -1
        for column in header.indices {
            let length = rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
            let leading = column >= align.count || align[column] == .leading
            if leading, length > bestLength { best = column; bestLength = length }
        }
        return best
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            frame(grid(fits: true))
            ScrollView(.horizontal, showsIndicators: false) { frame(grid(fits: false)) }
        }
    }

    private func frame<Content: View>(_ content: Content) -> some View {
        content
            .background(Color.black.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func grid(fits: Bool) -> some View {
        let band = Text(verbatim: " ")
            .font(.system(size: 11, weight: .semibold))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.05))
        return Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
                    LinkedText(ChatCardText.attributed(cell, size: 11, marks: false))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .multilineTextAlignment(textAlignment(column))
                        .fixedSize(horizontal: !fits || column != stretch, vertical: true)
                        .modifier(CellWidth(fits: fits, stretch: column == stretch, alignment: alignment(column)))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        // The scrolling variant fills each column, so each cell paints its own band; the fitting one
                        // has columns wider than their header, so one band is drawn behind the whole row.
                        .background(fits ? Color.clear : Color.white.opacity(0.05))
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Color.white.opacity(0.06).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        bodyCell(cell, column: column, fits: fits)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
            }
        }
        .background(alignment: .top) { if fits { band } }
    }

    @ViewBuilder private func bodyCell(_ cell: String, column: Int, fits: Bool) -> some View {
        if marks, let status = ChatAnswerRules.statusOnly(cell) {
            StatusCapsule(word: status.word, kind: status.kind, size: 10, dot: false, selectable: true)
                .modifier(CellWidth(fits: fits, stretch: column == stretch, alignment: alignment(column)))
        } else {
            LinkedText(ChatCardText.attributed(cell, size: 12.5, marks: marks))
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#C9CDD4"))
                .multilineTextAlignment(textAlignment(column))
                .fixedSize(horizontal: !fits || column != stretch, vertical: true)
                .modifier(CellWidth(fits: fits, stretch: column == stretch, alignment: alignment(column)))
                .textSelection(.enabled)
        }
    }

    /// In the scrolling variant each column is capped at 220 and fills its cell; in the fitting one only the stretch
    /// column fills.
    private struct CellWidth: ViewModifier {
        let fits: Bool
        let stretch: Bool
        let alignment: Alignment

        func body(content: Content) -> some View {
            if fits {
                content.frame(maxWidth: stretch ? .infinity : nil, alignment: alignment)
            } else {
                content
                    .frame(maxWidth: ChatCardTable.maxColumnWidth, alignment: alignment)
                    .frame(maxWidth: .infinity, alignment: alignment)
            }
        }
    }
}
