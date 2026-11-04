import SwiftUI

// What a chat shows for an agent: one block per turn, with the speaker's name and colour, over the rows of the
// turn (text, tool steps, notes). The user's message stays a `ChatBubble`. In both builds, no flag.

/// The fold state of the turns of this app session. Not observable on purpose: a toggle changes one block's own
/// state and redraws no other turn.
@MainActor enum ChatFolds {
    static var memory = ChatFoldMemory<UUID>()
}

/// What a tap on a file edit does: the owner of the chat shows the diff. nil by default: in the Hermes chat and the shared
/// chat there is no edit, and nothing here is tappable.
typealias ChatOpenEdit = @MainActor (ChatEdit) -> Void

private struct ChatOpenEditKey: EnvironmentKey {
    static var defaultValue: ChatOpenEdit? { nil }
}

extension EnvironmentValues {
    var chatOpenEdit: ChatOpenEdit? {
        get { self[ChatOpenEditKey.self] }
        set { self[ChatOpenEditKey.self] = newValue }
    }
}

// MARK: - The block of one agent turn

/// Header (dot, name, label), the work of the turn (steps and interim sentences: rows, a live box while it runs, or
/// one summary row once finished), then the answer as a card. Equatable and used with `.equatable()`: a message that
/// does not change is not laid out again while another one streams. The layout rules are pure (`ChatTurnLayout`).
struct AgentTurnBlock: View, Equatable {
    let speaker: ChatSpeaker
    let showsHeader: Bool
    let segments: [ChatSegment]
    /// No text yet: the typing dots take the place of the rows.
    var typing = false
    /// The turn is still running: the last group is drawn live and the open text is held as body. A running turn
    /// with nothing alive on screen (only a note, say) shows the dots in its own block.
    var running = false
    var label: ChatTurnHeader.Label = .none
    /// The message this block draws: what the user opened is remembered under it for the app session.
    var messageID: UUID? = nil

    /// Folded groups that start open (a snapshot or a preview); the user's clicks do the rest.
    @State private var expanded: Set<Int>
    @State private var touched: Bool
    /// Where the answers of this chat come from: Hermes agents hand over files with directives that become rows.
    @Environment(\.chatMedia) private var media

    init(speaker: ChatSpeaker, showsHeader: Bool, segments: [ChatSegment], typing: Bool = false, running: Bool = false,
         label: ChatTurnHeader.Label = .none, messageID: UUID? = nil, initiallyExpanded: Set<Int> = []) {
        self.speaker = speaker
        self.showsHeader = showsHeader
        self.segments = segments
        self.typing = typing
        self.running = running
        self.label = label
        self.messageID = messageID
        let remembered = messageID.flatMap { ChatFolds.memory.entry(for: $0) }
        _expanded = State(initialValue: remembered?.expanded ?? initiallyExpanded)
        _touched = State(initialValue: remembered?.touched ?? !initiallyExpanded.isEmpty)
    }

    nonisolated static func == (a: AgentTurnBlock, b: AgentTurnBlock) -> Bool {
        a.speaker == b.speaker && a.showsHeader == b.showsHeader && a.segments == b.segments
            && a.typing == b.typing && a.running == b.running && a.label == b.label
    }

    private var color: Color { Color(hex: speaker.colorHex) }

    /// The items of a block, one chunk each; items that are moments and follow one another share a chunk. A chunk is
    /// identified by the id of its first item, exactly as each item always was, so the rows of the Hermes chat and of the
    /// shared chat (one item per chunk) keep their SwiftUI identity.
    private struct Chunk: Identifiable {
        struct Row: Identifiable {
            let id: Int
            let index: Int
        }
        let id: Int
        var rows: [Row]
    }

    private static func chunks(of items: [ChatTurnLayout.Item]) -> [Chunk] {
        var out: [Chunk] = []
        for (index, item) in items.enumerated() {
            if case .moment = item, let last = out.last, case .moment = items[last.rows[last.rows.count - 1].index] {
                out[out.count - 1].rows.append(Chunk.Row(id: item.id, index: index))
            } else {
                out.append(Chunk(id: item.id, rows: [Chunk.Row(id: item.id, index: index)]))
            }
        }
        return out
    }

    /// Hermes can run tools in parallel: only the last running step shimmers, the others show a static row.
    private var shimmerId: Int? {
        segments.last { if case .step(let s) = $0.kind { return s.status == .running }; return false }?.id
    }

    var body: some View {
        let items = ChatTurnLayout.items(segments: segments, running: running, media: media.enabled)
        VStack(alignment: .leading, spacing: 9) {
            if showsHeader { header }
            ForEach(Self.chunks(of: items)) { chunk in
                if chunk.rows.count == 1 {
                    itemView(items[chunk.rows[0].index], index: chunk.rows[0].index, items: items)
                } else {
                    // The moments of a turn that sit together are one quiet list, each row identified by its item id.
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(chunk.rows) { row in itemView(items[row.index], index: row.index, items: items) }
                    }
                }
            }
            if ChatTurnLayout.showsOwnDots(items: items, running: running, typing: typing) { TypingDotsView() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: speaker.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
                .lineLimit(1)
                .truncationMode(.tail)
            switch label {
            case .working: Text("working…").font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            case .answered: Text("answered").font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C")).lineLimit(1)
            case .waitingForYou: Text("waiting for you").font(.system(size: 12, weight: .medium)).foregroundColor(Color(hex: "#F5A524")).lineLimit(1)
            case .none: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func isExpanded(_ id: Int, _ items: [ChatTurnLayout.Item]) -> Bool {
        expanded.contains(id) || (!touched && ChatTurnLayout.startsExpanded(items))
    }

    private func toggle(_ id: Int, _ items: [ChatTurnLayout.Item]) {
        if !touched {
            touched = true
            if ChatTurnLayout.startsExpanded(items) {
                for case .group(let group, .folded) in items { expanded.insert(group.id) }
            }
        }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        if let messageID { ChatFolds.memory.set(.init(expanded: expanded, touched: true), for: messageID) }
    }

    /// A card is a report (verdict style for its first paragraph) when work with steps comes before it.
    private func hasWork(before index: Int, in items: [ChatTurnLayout.Item]) -> Bool {
        items[..<index].contains { item in
            guard case .group(let group, _) = item else { return false }
            return group.rows.contains {
                switch $0.kind {
                case .step, .edit: return true
                default: return false
                }
            }
        }
    }

    @ViewBuilder private func itemView(_ item: ChatTurnLayout.Item, index: Int, items: [ChatTurnLayout.Item]) -> some View {
        switch item {
        case .group(let group, let mode):
            switch mode {
            case .rows:
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.rows) { row in workRow(row) }
                }
            case .live:
                liveBox(group, items: items)
            case .folded:
                let open = isExpanded(group.id, items)
                VStack(alignment: .leading, spacing: 6) {
                    ChatStepsSummaryRow(summary: ChatWorkSummary(group: group), expanded: open) { toggle(group.id, items) }
                    if open {
                        ChatStepsList(rows: group.rows).equatable()
                    } else if case let files = ChatWorkSummary.files(group: group), !files.isEmpty {
                        ChatFilesStrip(files: files)
                    }
                }
            }
        case .card(let id, let text, let open):
            if text.contains("```coucou-mail") {
                // A mail plan (MailPlan.swift) is not shown as raw JSON: its prose is the card, the plan a card of its own.
                let parsed = MailPlanParser.extract(text)
                VStack(alignment: .leading, spacing: 6) {
                    if !parsed.prose.isEmpty {
                        ChatMarkdownView(markdown: parsed.prose, style: .card(verdict: hasWork(before: index, in: items)), streaming: open)
                            .equatable()
                    }
                    #if !APPSTORE
                    if let plan = parsed.plan, let messageID {
                        MailPlanCard(plan: plan, messageId: messageID)
                    } else if let error = parsed.error {
                        Text(String(format: String(localized: "mail.plan.error %@"), error))
                            .font(.system(size: 10.5))
                            .foregroundColor(Color(hex: "#F5A524"))
                    }
                    #endif
                }
            } else {
                ChatMarkdownView(markdown: text, style: .card(verdict: hasWork(before: index, in: items)), streaming: open)
                    .equatable()
                    .transformEnvironment(\.chatMedia) {
                        $0.scope = "\(messageID?.uuidString ?? "")-\(id)"
                        $0.colorHex = speaker.colorHex
                    }
            }
        case .note(_, let text):
            Text(verbatim: text)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .moment(_, let moment):
            ChatMomentRow(moment: moment).equatable()
        }
    }

    /// The box of a running turn: the current step, its number, the interim sentence. The dots show only while no
    /// step runs and no text is on screen (the model is thinking between tools).
    @ViewBuilder private func liveBox(_ group: ChatTurnLayout.WorkGroup, items: [ChatTurnLayout.Item]) -> some View {
        // A call that waits for the user is shown by its moment: its step is not the live one, and nothing is typing.
        let awaiting = ChatTurnLayout.awaitingKeys(items)
        let live = ChatWorkSummary.liveStep(group: group, awaiting: awaiting)
        let textOnScreen = items.contains { if case .card = $0 { return true }; return false }
        let waitsForUser = items.contains { if case .moment(_, let m) = $0 { return m.waitsForUser }; return false }
        let sentence = ChatWorkSummary.liveSentence(group: group)
        let files = ChatWorkSummary.files(group: group)
        let drawsBox = live != nil || sentence != nil || !waitsForUser
        let box = ChatLiveStepBox(step: live?.step, shimmer: live?.segmentId == shimmerId && live?.step.status == .running,
                                  number: live?.number, sentence: sentence,
                                  waiting: live?.step.status != .running && !textOnScreen && !waitsForUser)
            .equatable()
        if files.isEmpty {
            if drawsBox { box }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if drawsBox { box }
                ChatFilesStrip(files: files)
            }
        }
    }

    @ViewBuilder private func workRow(_ segment: ChatSegment) -> some View {
        switch segment.kind {
        case .text(let text, _):
            ChatMarkdownView(markdown: text, style: .interim).equatable().padding(.vertical, 4)
        case .step(let step):
            ChatStepRow(step: step, shimmer: segment.id == shimmerId)
        case .hiddenSteps:
            Text("Earlier steps hidden")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
        case .edit(let edit):
            ChatEditRow(edit: edit, showsPreview: false).equatable()
        case .moment(let moment):
            ChatMomentRow(moment: moment).equatable()
        case .note:
            EmptyView()
        }
    }
}

// MARK: - Summary row, expanded list, live box

/// A quiet capsule: the family of `ContextChip`, one step softer.
private struct QuietChip<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.white.opacity(0.07))
            .clipShape(Capsule())
    }
}

/// The folded group: the count, the tools with their counts (names are server text, verbatim) and a chevron. The
/// whole row is the click target. Tool chips drop to `+N` when the width is short.
struct ChatStepsSummaryRow: View {
    let summary: ChatWorkSummary
    let expanded: Bool
    let toggle: () -> Void

    private var countText: String {
        summary.more ? String(localized: "\(summary.count)+ steps") : String(localized: "\(summary.count) steps")
    }

    var body: some View {
        Button(action: toggle) {
            ViewThatFits(in: .horizontal) {
                chips(limit: 3)
                chips(limit: 2)
                chips(limit: 1)
                chips(limit: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: ([countText] + summary.tools.map { "\($0.tool) \($0.count)" }).joined(separator: ", ")))
        .accessibilityHint(Text(expanded ? "Hide steps" : "Show steps"))
    }

    private func chips(limit: Int) -> some View {
        let shown = summary.shown(limit: limit)
        return HStack(spacing: 6) {
            QuietChip {
                HStack(spacing: 5) {
                    countIcon
                    if summary.more { Text("\(summary.count)+ steps") } else { Text("\(summary.count) steps") }
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
            }
            ForEach(shown.tools, id: \.tool) { entry in
                QuietChip {
                    HStack(spacing: 4) {
                        Image(systemName: entry.symbol ?? ChatWorkSummary.symbol(for: entry.tool))
                            .font(.system(size: 9.5))
                            .foregroundColor(Color(hex: "#6B7079"))
                        Text(verbatim: entry.tool)
                            .font(.system(size: 11.5))
                            .foregroundColor(Color(hex: "#9398A1"))
                            .lineLimit(1)
                        Text(verbatim: "\(entry.count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                }
            }
            if shown.extra > 0 {
                QuietChip {
                    Text(verbatim: "+\(shown.extra)")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
            }
            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(hex: "#6B7079"))
                .padding(.leading, 2)
        }
        .fixedSize()
    }

    @ViewBuilder private var countIcon: some View {
        switch summary.state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(Color(hex: "#22C55E"))
        case .stopped:
            Image(systemName: "minus.circle.fill").font(.system(size: 10)).foregroundColor(Color(hex: "#6B7079"))
        case .running:
            Image(systemName: "ellipsis.circle").font(.system(size: 10)).foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

/// The unfolded group: today's step rows, and each interim sentence where it was written.
struct ChatStepsList: View, Equatable {
    let rows: [ChatSegment]

    nonisolated static func == (a: ChatStepsList, b: ChatStepsList) -> Bool { a.rows == b.rows }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                switch row.kind {
                case .step(let step):
                    ChatStepRow(step: step)
                case .text(let text, _):
                    ChatMarkdownView(markdown: text, style: .folded).equatable().padding(.vertical, 4)
                case .hiddenSteps:
                    Text("Earlier steps hidden")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                case .edit(let edit):
                    ChatEditRow(edit: edit, showsPreview: true).equatable()
                case .moment(let moment):
                    ChatMomentRow(moment: moment).equatable()
                case .note:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The running turn: one box with the current step (shimmering while it runs), its number, the interim sentence.
struct ChatLiveStepBox: View, Equatable {
    let step: ChatStep?
    let shimmer: Bool
    let number: Int?
    let sentence: String?
    let waiting: Bool

    nonisolated static func == (a: ChatLiveStepBox, b: ChatLiveStepBox) -> Bool {
        a.step == b.step && a.shimmer == b.shimmer && a.number == b.number && a.sentence == b.sentence && a.waiting == b.waiting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let step {
                HStack(spacing: 8) {
                    ChatStepRow(step: step, shimmer: shimmer)
                    if let n = number {
                        QuietChip {
                            Text("step \(n)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(Color(hex: "#9398A1"))
                                .lineLimit(1)
                        }
                        .fixedSize()
                    }
                }
            }
            if let sentence { ChatMarkdownView(markdown: sentence, style: .interim).equatable() }
            if waiting { TypingDotsView() }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Files and moments of a cmux turn

/// A file edit, drawn like a step: the done mark, the word, the file name, the counts. Open, its changed lines follow.
/// A tap opens the diff when the owner of the chat allows it.
struct ChatEditRow: View, Equatable {
    let edit: ChatEdit
    /// The changed lines under the row: in the open list. A short turn draws the row alone.
    var showsPreview = true
    @Environment(\.chatOpenEdit) private var open

    nonisolated static func == (a: ChatEditRow, b: ChatEditRow) -> Bool { a.edit == b.edit && a.showsPreview == b.showsPreview }

    var body: some View {
        if let open {
            Button { open(edit) } label: { content(tappable: true) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(edit.tool) \(edit.name)"))
                .accessibilityHint(Text("Open diff"))
        } else {
            content(tappable: false)
        }
    }

    private func content(tappable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(Color(hex: "#454850"))
                    .frame(width: 12, alignment: .center)
                Text(verbatim: edit.tool)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(verbatim: edit.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                EditCounts(added: edit.added, removed: edit.removed)
                Spacer(minLength: 0)
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            if showsPreview && !edit.preview.isEmpty {
                EditPreview(lines: edit.preview).padding(.leading, 18)
            }
        }
        .padding(.vertical, showsPreview && !edit.preview.isEmpty ? 4 : 0)
    }
}

/// `+12 −3`, in the colours of the diff card. A zero count is not drawn.
private struct EditCounts: View {
    let added: Int
    let removed: Int
    var body: some View {
        HStack(spacing: 4) {
            if added > 0 { Text(verbatim: "+\(added)").foregroundColor(Color(hex: "#22C55E")) }
            if removed > 0 { Text(verbatim: "−\(removed)").foregroundColor(Color(hex: "#F4505E")) }
        }
        .font(.system(size: 10, weight: .medium).monospaced())
        .lineLimit(1)
        .fixedSize()
    }
}

/// The changed lines of an edit, in the dark inset of the code blocks of the card, through the diff card's own line row.
private struct EditPreview: View {
    let lines: [ChatEditLine]

    private func diffLine(_ line: ChatEditLine) -> DiffLine {
        let kind: DiffLine.Kind
        switch line.kind {
        case .context: kind = .context
        case .added: kind = .added
        case .removed: kind = .removed
        }
        return DiffLine(kind: kind, text: line.text, origLine: -1, newLine: -1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                DiffLineRowView(line: diffLine(line), inset: 8)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0D0E12"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The files edited in a folded or running turn: one chip per file with its counts, at most three, then `+N`. Always
/// visible, so which files changed does not hide in the fold. A chip opens the newest diff of its file when the owner
/// of the chat allows it. Nothing when no file was edited.
struct ChatFilesStrip: View {
    let files: [ChatWorkSummary.FileCount]

    var body: some View {
        if !files.isEmpty {
            ViewThatFits(in: .horizontal) {
                chips(limit: 3, fixed: true)
                chips(limit: 2, fixed: true)
                chips(limit: 1, fixed: true)
                chips(limit: 1, fixed: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chips(limit: Int, fixed: Bool) -> some View {
        let shown = Array(files.prefix(limit))
        let extra = files.count - shown.count
        return HStack(spacing: 6) {
            ForEach(shown, id: \.path) { file in FileChip(file: file, fixed: fixed) }
            if extra > 0 {
                QuietChip {
                    Text(verbatim: "+\(extra)")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
            }
        }
        .modifier(StripFit(fixed: fixed))
    }
}

private struct StripFit: ViewModifier {
    let fixed: Bool
    func body(content: Content) -> some View {
        if fixed { content.fixedSize() } else { content }
    }
}

/// One file of the strip: the family of the tool chips, with a hairline so it reads as something to tap.
private struct FileChip: View {
    let file: ChatWorkSummary.FileCount
    let fixed: Bool
    @Environment(\.chatOpenEdit) private var open

    var body: some View {
        if let open {
            Button { open(file.latest) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: file.name))
                .accessibilityHint(Text("Open diff"))
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "pencil")
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#6B7079"))
            Text(verbatim: file.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1)
                .truncationMode(.middle)
            EditCounts(added: file.added, removed: file.removed)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.white.opacity(0.07))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// A permission or a question of the turn. Shown, never answerable: no row here is a button. What is open is the one
/// loud thing of a turn (amber), a denied request is quiet with its command struck, a question shows its answer.
struct ChatMomentRow: View, Equatable {
    let moment: ChatMoment

    nonisolated static func == (a: ChatMomentRow, b: ChatMomentRow) -> Bool { a.moment == b.moment }

    private let dim = Color(hex: "#6B7079")
    private let amber = Color(hex: "#F5A524")
    private let bad = Color(hex: "#F4505E")

    /// The step wording is "verb · detail": the verb is a word of ours, the detail text of the agent.
    private var parts: (verb: String, detail: String) {
        guard moment.kind == .permission, let r = moment.text.range(of: " · ") else { return (moment.text, "") }
        return (String(moment.text[..<r.lowerBound]), String(moment.text[r.upperBound...]))
    }

    var body: some View {
        switch moment.outcome {
        case .waiting, .inTerminal: openRow
        case .denied: deniedRow
        case .answered(let labels): questionOrQuiet(trailing: AnyView(answer(labels)))
        case .handled, .allowed: questionOrQuiet(trailing: AnyView(MomentCapsule(word: Text(wordOfOutcome), color: dim, dot: false)))
        }
    }

    private var wordOfOutcome: LocalizedStringKey {
        switch moment.outcome {
        case .waiting: return moment.kind == .question ? "waiting for your answer" : "waiting for your approval"
        case .inTerminal: return "waiting in the terminal"
        case .handled: return "answered in the terminal"
        case .allowed: return "allowed"
        case .denied: return "denied"
        case .answered: return ""
        }
    }

    /// Waiting for the card or for the terminal: the ask box of the card family at row size.
    private var openRow: some View {
        HStack(spacing: 8) {
            Image(systemName: moment.kind == .question ? "questionmark.bubble.fill" : "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(amber)
            if moment.kind == .permission {
                Text(verbatim: parts.verb)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(amber)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !parts.detail.isEmpty {
                    Text(verbatim: parts.detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "#F3D9A6"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                questionText(color: Color(hex: "#F3D9A6"))
            }
            Spacer(minLength: 8)
            MomentCapsule(word: Text(wordOfOutcome), color: amber)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(amber.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(amber.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var deniedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundColor(dim)
                .frame(width: 12, alignment: .center)
            Text(verbatim: parts.verb)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(dim)
                .lineLimit(1)
                .layoutPriority(1)
            if !parts.detail.isEmpty {
                Text(verbatim: parts.detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(dim)
                    .strikethrough(true, color: dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            MomentCapsule(word: Text("denied"), color: bad)
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .combine)
    }

    /// A question that was answered or settled, or a permission settled with no step to carry the word.
    @ViewBuilder private func questionOrQuiet(trailing: AnyView) -> some View {
        HStack(spacing: 6) {
            Image(systemName: moment.kind == .question ? "questionmark.bubble" : "lock.fill")
                .font(.system(size: moment.kind == .question ? 10 : 9))
                .foregroundColor(moment.kind == .question ? Color(hex: "#8E939C") : dim)
                .frame(width: 12, alignment: .center)
            if moment.kind == .question {
                questionText(color: Color(hex: "#C5C8CD"))
            } else {
                Text(verbatim: parts.verb)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(dim)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !parts.detail.isEmpty {
                    Text(verbatim: parts.detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .combine)
    }

    private func questionText(color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(verbatim: moment.text)
                .font(.system(size: 11.5))
                .foregroundColor(color)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if moment.more > 0 {
                Text(verbatim: "+\(moment.more)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(dim)
                    .fixedSize()
            }
        }
    }

    private func answer(_ labels: String) -> some View {
        Text(verbatim: "→ \(labels)")
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The word an outcome says, in the capsule of the card's status words.
private struct MomentCapsule: View {
    let word: Text
    let color: Color
    var dot = true

    var body: some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(color).frame(width: 5, height: 5) }
            word
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
        .fixedSize()
    }
}

// MARK: - One tool step

/// A tool call as a compact row: state glyph, the tool name, the server's one line preview. Tool names and
/// previews are server data: drawn verbatim, never looked up in the string catalog, never read as markdown.
struct ChatStepRow: View, Equatable {
    let step: ChatStep
    /// The running row of the turn that shimmers (one `TimelineView`); other running rows are static.
    var shimmer = false

    nonisolated static func == (a: ChatStepRow, b: ChatStepRow) -> Bool { a.step == b.step && a.shimmer == b.shimmer }

    private let dim = Color(hex: "#6B7079")

    var body: some View {
        HStack(spacing: 6) {
            glyph.frame(width: 12, alignment: .center)
            Text(verbatim: step.tool)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(dim)
                .lineLimit(1)
                .layoutPriority(1)
            if !step.label.isEmpty && step.label != step.tool {
                if step.status == .running && shimmer {
                    TickerShimmerText(text: step.label, size: 11.5)
                } else {
                    Text(verbatim: step.label)
                        .font(.system(size: 11.5))
                        .foregroundColor(dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if let detail = step.detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.system(size: 11.5))
                    .foregroundColor(dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(height: 18, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var glyph: some View {
        switch step.status {
        case .running:
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(hex: "#8E939C"))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 8, weight: .regular))
                .foregroundColor(Color(hex: "#454850"))
        case .stopped:
            Image(systemName: "minus")
                .font(.system(size: 8, weight: .regular))
                .foregroundColor(Color(hex: "#454850"))
        }
    }
}

// MARK: - The shared list body

/// The messages of a chat: the user's bubble, or the block of the agent, with a larger gap between turns than
/// between two paragraphs. The three chat lists (shared chat, Hermes chat, cmux reply) draw their body with this.
/// The scroll anchors stay as they were: `.id(message.id)` on each row and `"typing"` on the dots.
struct ChatTurnList: View {
    @Environment(\.chatMedia) private var media
    let messages: [ChatMessage]
    /// Who wrote an agent message; nil asks for the speaker who is about to answer (the typing dots).
    let speaker: (ChatMessage?) -> ChatSpeaker
    /// The last message is still arriving (a finished text is parsed as written).
    let streamingLast: Bool
    let typing: Bool

    private func visible(_ m: ChatMessage) -> Bool { m.isShown }

    var body: some View {
        let shown = messages.filter(visible)
        let position = Dictionary(shown.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let lastID = messages.last?.id
        // A message with no provider of its own (Hermes, cmux, an old message) has the speaker who is about to
        // answer: resolved once per pass instead of once per message.
        let fallback = speaker(nil)
        let who: (ChatMessage) -> ChatSpeaker = { $0.provider == nil ? fallback : speaker($0) }
        // The placeholder of the turn that waits is the last message, empty: the dots sit in its block, and its
        // scroll anchor sits below them.
        let pending = typing ? messages.last.flatMap { $0.role == .assistant && !visible($0) ? $0 : nil } : nil
        // A turn that already has rows and still runs shows its own live box: the "typing" anchor stays below it as a
        // row with no height, so `scrollTo("typing")` keeps working and no second set of dots is drawn.
        let runningSegments = shown.last.flatMap { $0.id == lastID && $0.role == .assistant ? $0.segments : nil }
        let rowsRun = ChatTurnLayout.anchorReplacesDots(typing: typing, streamingLast: streamingLast, lastSegments: runningSegments, media: media.enabled)
        // Spacing is padding on the rows (14 pt between turns), so a message with nothing to show can still carry
        // its scroll anchor as a zero height row without adding a gap.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(messages) { message in
                if let index = position[message.id] {
                    Group {
                        if message.role == .user {
                            ChatBubble(message: message)
                        } else {
                            let speaker = who(message)
                            let running = ChatStreaming.shows(
                                streamingLast: streamingLast, isLast: message.id == lastID, isNotice: message.isNotice)
                            AgentTurnBlock(
                                speaker: speaker,
                                showsHeader: header(for: speaker, after: index > 0 ? shown[index - 1] : nil, who: who),
                                segments: Self.segments(of: message, streaming: running),
                                running: running,
                                label: ChatTurnHeader.turnLabel(
                                    running: running,
                                    isNotice: message.isNotice,
                                    hasAnswer: ChatTurnHeader.hasAnswer(segments: message.segments, content: message.content),
                                    waitsForUser: ChatTurnLayout.waitsForUser(message.segments)),
                                messageID: message.id)
                                .equatable()
                        }
                    }
                    .padding(.top, index == 0 ? 0 : 14)
                    .id(message.id)
                } else if message.id != pending?.id {
                    Color.clear.frame(height: 0).id(message.id)
                }
            }
            if typing {
                if rowsRun {
                    Color.clear.frame(height: 0).id("typing")
                } else {
                    let speaker = pending.map(who) ?? fallback
                    AgentTurnBlock(speaker: speaker, showsHeader: header(for: speaker, after: shown.last, who: who),
                                   segments: [], typing: true, label: .working)
                        .equatable()
                        .padding(.top, shown.isEmpty ? 0 : 14)
                        .id("typing")
                    if let pending { Color.clear.frame(height: 0).id(pending.id) }
                }
            }
        }
    }

    private func header(for current: ChatSpeaker, after previous: ChatMessage?,
                        who: (ChatMessage) -> ChatSpeaker) -> Bool {
        guard let previous else { return ChatSpeakers.showsHeader(previous: nil, speaker: current) }
        let was: ChatSpeaker? = previous.role == .user ? nil : who(previous)
        return ChatSpeakers.showsHeader(previous: (isUser: previous.role == .user, speaker: was), speaker: current)
    }

    /// The rows of a message: its own segments, or one text made from `content` (every provider but Hermes, an
    /// error text, the cmux transcript). A text that is still arriving is `open`: held back and closed where needed.
    static func segments(of message: ChatMessage, streaming: Bool) -> [ChatSegment] {
        if !message.segments.isEmpty { return message.segments }
        return [ChatSegment(id: 0, kind: .text(message.content, role: streaming ? .open : .answer))]
    }
}
