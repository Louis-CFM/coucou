import SwiftUI
import UIKit

/// The last turn of a session: your prompt, what the agent did, the files it
/// changed (tap for the diff) and its answer.
struct LastTurnView: View {
    let turn: TurnSnapshot
    let working: Bool
    @State private var showAllActions = false

    private let collapsedCount = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !turn.prompt.isEmpty { promptCard }
            if !turn.actions.isEmpty { actionsCard }
            if !turn.files.isEmpty { filesCard }
            answerCard
        }
    }

    // MARK: Prompt

    /// A background task finishing reaches Claude as a "<task-notification>"
    /// prompt: shown by its summary rather than as raw XML.
    private var taskSummary: String? {
        guard turn.prompt.hasPrefix("<task-notification>") else { return nil }
        if let start = turn.prompt.range(of: "<summary>"), let end = turn.prompt.range(of: "</summary>"),
           start.upperBound <= end.lowerBound {
            return String(turn.prompt[start.upperBound..<end.lowerBound])
        }
        return "A background task finished"
    }

    private var promptCard: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let summary = taskSummary {
                ExpandableText(text: turn.prompt, collapsedLines: 0, title: summary, monospaced: true)
                    .padding(12)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 16))
            } else {
                ExpandableText(text: turn.prompt, collapsedLines: 6)
                    .padding(12)
                    .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
            }
            Text("\(taskSummary == nil ? "You" : "Background task") · \(turn.startedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Actions

    private var actionsCard: some View {
        let actions = showAllActions ? turn.actions : Array(turn.actions.prefix(collapsedCount))
        return card(title: "What it did · \(turn.actions.count)") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    ActionRow(action: action, file: action.fileIndex.flatMap { turn.files.indices.contains($0) ? turn.files[$0] : nil })
                }
                if turn.actions.count > collapsedCount {
                    Button(showAllActions ? "Show less" : "Show all \(turn.actions.count)") {
                        withAnimation { showAllActions.toggle() }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 8)
                }
            }
        }
    }

    // MARK: Files

    private var filesCard: some View {
        card(title: "Files changed · \(turn.files.count)") {
            VStack(spacing: 0) {
                ForEach(Array(turn.files.enumerated()), id: \.offset) { index, file in
                    NavigationLink {
                        FileDiffView(file: file)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: file.isNew ? "doc.badge.plus" : "doc.text")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).font(.callout.weight(.semibold))
                                Text(file.path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 6)
                            Text("+\(file.added)").font(.caption.monospacedDigit()).foregroundStyle(.green)
                            Text("−\(file.removed)").font(.caption.monospacedDigit()).foregroundStyle(.red)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < turn.files.count - 1 { Divider() }
                }
            }
        }
    }

    // MARK: Answer

    @ViewBuilder private var answerCard: some View {
        if !turn.finalMessage.isEmpty {
            card(title: "Claude's answer") {
                ExpandableText(text: turn.finalMessage, collapsedLines: 10, markdown: true)
            }
        } else if working || turn.endedAt == nil {
            card(title: "Claude's answer") {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Still working…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
    }
}

/// One tool call; a command opens to show what it printed.
private struct ActionRow: View {
    let action: TurnAction
    let file: TurnFile?
    @State private var open = false

    private var icon: String {
        switch action.tool {
        case "Bash": "terminal"
        case "Read": "doc.text.magnifyingglass"
        case "Edit", "MultiEdit": "pencil"
        case "Write": "doc.badge.plus"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if !action.output.isEmpty { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: action.failed ? "exclamationmark.triangle.fill" : icon)
                        .font(.footnote)
                        .foregroundStyle(action.failed ? Color.red : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(action.tool).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(file?.name ?? action.summary)
                            .font(action.tool == "Bash" ? .footnote.monospaced() : .footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(open ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 4)
                    if let file {
                        Text("+\(file.added) −\(file.removed)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    } else if !action.output.isEmpty {
                        Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(action.output)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(Color(white: 0.06), in: RoundedRectangle(cornerRadius: 10))
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A changed file, line by line: removed in red, added in green.
struct FileDiffView: View {
    let file: TurnFile
    /// Shown full screen, where the iPhone can turn sideways for long lines.
    var fullScreen = false
    @State private var showFullScreen = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
                if file.truncated {
                    Text("Some lines were left out to keep it light.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color.black)
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 6) {
                    Text("+\(file.added)").foregroundStyle(.green)
                    Text("−\(file.removed)").foregroundStyle(.red)
                }
                .font(.footnote.monospacedDigit().weight(.semibold))
            }
            ToolbarItem(placement: fullScreen ? .topBarLeading : .topBarTrailing) {
                if fullScreen {
                    Button("Done") { dismiss() }
                } else {
                    Button { showFullScreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel("Full screen")
                }
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            NavigationStack { FileDiffView(file: file, fullScreen: true) }
                .onAppear { Self.allowLandscape(true) }
                .onDisappear { Self.allowLandscape(false) }
        }
    }

    /// Lets the screen turn while the full-screen diff is open; back to portrait after.
    private static func allowLandscape(_ allowed: Bool) {
        OrientationLock.mask = allowed ? .allButUpsideDown : .portrait
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if !allowed { scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) }
    }

    @ViewBuilder private func row(_ line: TurnDiffLine) -> some View {
        switch line.kind {
        case .gap:
            Text("⋯")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        case .added, .removed, .context:
            HStack(spacing: 0) {
                Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                    .frame(width: 18)
                    .foregroundStyle(line.kind == .added ? Color.green : line.kind == .removed ? Color.red : Color.secondary)
                Text(line.text.isEmpty ? " " : line.text)
                    .foregroundStyle(line.kind == .context ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 16)
            }
            .font(.caption.monospaced())
            .padding(.vertical, 1)
            .padding(.leading, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(line.kind == .added ? Color.green.opacity(0.14)
                        : line.kind == .removed ? Color.red.opacity(0.14) : Color.clear)
        }
    }
}

/// Long text folded to a few lines, with "Show more" / "Show less".
/// collapsedLines 0 shows only the title until opened.
struct ExpandableText: View {
    let text: String
    var collapsedLines: Int
    var title: String? = nil
    var monospaced = false
    var markdown = false
    @State private var open = false

    /// Short texts are shown whole, without a button.
    private var isLong: Bool {
        collapsedLines == 0 || text.count > collapsedLines * 60 || text.filter(\.isNewline).count >= collapsedLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Label(title, systemImage: "gearshape.2")
                    .font(.callout.weight(.semibold))
            }
            if open || collapsedLines > 0 {
                content
                    .lineLimit(open || !isLong ? nil : collapsedLines)
            }
            if isLong {
                Button(open ? "Show less" : (collapsedLines == 0 ? "Show details" : "Show more")) {
                    withAnimation(.easeOut(duration: 0.2)) { open.toggle() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if markdown {
            Text(LocalizedStringKey(text))
                .font(.callout)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(monospaced ? .caption.monospaced() : .callout)
                .foregroundStyle(monospaced ? Color.secondary : Color.primary)
                .textSelection(.enabled)
        }
    }
}
