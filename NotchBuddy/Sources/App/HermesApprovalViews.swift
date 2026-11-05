import SwiftUI

// MARK: - The approval card of a Hermes agent
//
// Same card as the one every other agent gets (`CardBackground`, `AgentWho`, the button shapes), with the answers of
// a Hermes request: Deny, a selector of how long Allow lasts (once, the session, always) and one Allow button.
// Nothing here knows `AppState` or the queue: the card draws a value and calls closures, so it renders offscreen.
// Nothing answers by itself: no default button, no key, no timer. The buttons are the only way out.

/// What the card draws for one request.
struct HermesApprovalCardModel: Equatable {
    var task: AgentTask?
    var requestID: String
    var display: HermesApprovalDisplay
    var choices: Set<HermesApproval.Choice>
    var scope: HermesApproval.Scope
    /// Requests waiting behind this one.
    var waitingBehind: Int
    /// The reading view (the island grew to show the whole text).
    var reading: Bool
    /// The end of the text was on screen.
    var reachedEnd: Bool
    /// Set when Hermes withdrew the request: the sentence shown instead of the answers.
    var withdrawn: String?
    /// What Session and Always grant on the server (the description of the request); nil when it cannot be named.
    var grant: String? = nil
    /// Hermes redacted part of the command (a mask in the text): the card says so.
    var masked: Bool = false
}

/// What a click does. The strings are `HermesApproval.decision` buttons: "deny", "once", "session", "always".
struct HermesApprovalCardActions {
    var answer: (String) -> Void
    var select: (HermesApproval.Scope) -> Void
    var setReading: (Bool) -> Void
    var reachedEnd: () -> Void
}

private enum HermesCardColor {
    static let amber = Color(hex: "#F5A524")
    static let red = Color(hex: "#F4505E")
    static let mute = Color(hex: "#8E939C")
    static let faint = Color(hex: "#6B7079")
    static let text = Color(hex: "#E8E9EC")
}

/// The text of a command as `HermesApproval.display` made it. Marks keep their own colour; nothing is interpreted:
/// an `AttributedString` built from plain strings holds no Markdown and no format specifiers.
struct HermesCommandText: View {
    let runs: [HermesApprovalDisplay.Run]

    private var attributed: AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .plain: break
            case .visible: piece.foregroundColor = HermesCardColor.faint
            case .escape: piece.foregroundColor = HermesCardColor.amber
            }
            out.append(piece)
        }
        return out
    }

    var body: some View {
        // Never a line limit and a fixed vertical size: the text takes the height it needs, so no layout can end it in "…".
        // What is too long to fit is cut before it gets here (`closedPreview`), and counted on the card.
        Text(attributed)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(HermesCardColor.text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The agent name and one line of words, like `AgentWho`, for text that is already localized or comes from the server:
/// the words are drawn as they are (no Markdown, no key lookup). The name gives way first; the words are never cut.
struct HermesWho: View {
    let task: AgentTask?
    let label: String
    var color: Color = HermesCardColor.mute

    var body: some View {
        HStack(spacing: 7) {
            if let task {
                Circle().fill(Color(hex: task.color)).frame(width: 8, height: 8)
                Text(task.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).layoutPriority(-1)
            }
            Text(verbatim: label).font(.system(size: 12)).foregroundColor(color).fixedSize()
        }
    }
}

/// The count of people waiting behind the shown request.
private struct HermesWaitingChip: View {
    let count: Int
    var body: some View {
        Text("\(count) waiting")
            .font(.system(size: 11.5)).foregroundColor(Color(hex: "#F1F2F4"))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Color.white.opacity(0.1)).clipShape(Capsule())
    }
}

/// The shape of `CodeBlock` (same font, padding, fill, stroke and radius), around any content.
private struct HermesBlockFrame<Content: View>: View {
    var vertical: CGFloat = 5
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 10).padding(.vertical, vertical)
            .background(Color.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// The scope of an allow: once, for the session, always. A segment the server did not offer is not drawn.
struct HermesScopePicker: View {
    let scope: HermesApproval.Scope
    let offered: Set<HermesApproval.Choice>
    let select: (HermesApproval.Scope) -> Void

    private func segment(_ s: HermesApproval.Scope, _ title: LocalizedStringKey, lock: Bool = false) -> some View {
        let on = scope == s
        let danger = s == .always
        return Button { select(s) } label: {
            HStack(spacing: 4) {
                if lock { Image(systemName: "lock.fill").font(.system(size: 8.5)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .foregroundColor(on ? (danger ? Color.white : Color(hex: "#F5F6F8")) : (danger ? HermesCardColor.red.opacity(0.85) : HermesCardColor.mute))
            .background(on ? (danger ? HermesCardColor.red.opacity(0.85) : Color.white.opacity(0.17)) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    var body: some View {
        HStack(spacing: 2) {
            segment(.once, "Scope: once")
            if offered.contains(.session) { segment(.session, "Scope: session") }
            if offered.contains(.always) {
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 14).padding(.horizontal, 2)
                segment(.always, "Scope: always", lock: true)
            }
        }
        .padding(2).background(Color.white.opacity(0.07)).clipShape(Capsule())
        .fixedSize()
    }
}

/// The buttons of the closed card and the line that says what is hidden. The buttons keep their width; the line takes the rest
/// and may take a second line (the height of the buttons holds two lines of 11.5 pt), so in no language is it cut. The titles
/// come in as text so the layout can be checked with each language's words.
struct HermesClosedActions: View {
    let deny: String
    let whole: String
    let count: String
    let onDeny: () -> Void
    let onWhole: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SecondaryButton(verbatim: deny, action: onDeny).fixedSize()
            PrimaryButton(verbatim: whole, action: onWhole).fixedSize()
            Text(verbatim: count).font(.system(size: 11.5)).foregroundColor(HermesCardColor.mute)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .focusable(false)
    }
}

/// The red allow of "always": a capsule of the size of `PrimaryButton`.
private struct HermesDangerButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(HermesCardColor.red).foregroundColor(.white).clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

struct HermesApprovalCard: View {
    let model: HermesApprovalCardModel
    let actions: HermesApprovalCardActions

    /// The words next to the agent name. "needs permission" normally; while Session or Always is selected, what it grants
    /// (the description of the request, on one line); when Hermes masked part of the command, that. Never the command.
    private var whoLine: (text: String, color: Color) {
        if model.withdrawn != nil { return (String(localized: "withdrew the request"), HermesCardColor.mute) }
        if model.masked { return (String(localized: "Hermes may have hidden part of this command."), HermesCardColor.amber) }
        if let grant = model.grant {
            switch model.scope {
            case .once: break
            case .session: return (String(localized: "Allow for the session: \(grant)"), HermesCardColor.text)
            case .always: return (String(localized: "Always allow: \(grant)"), HermesCardColor.red)
            }
        }
        return (String(localized: "needs permission"), HermesCardColor.mute)
    }

    private var showsGrant: Bool { model.withdrawn == nil && !model.masked && model.grant != nil && model.scope != .once }

    var body: some View {
        ZStack {
            CardBackground(wash: model.withdrawn == nil ? .amber : .soft)
            content
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        if let sentence = model.withdrawn {
            VStack(alignment: .leading, spacing: 5) {
                who
                HermesBlockFrame { HermesCommandText(runs: model.display.closedPreview(rows: 1).runs) }
                    .opacity(0.45)
                Text(verbatim: sentence).font(.system(size: 13)).foregroundColor(Color(hex: "#C9CCD2"))
            }
        } else {
            switch model.display.tier {
            case .inline: inlineBody
            case .reading:
                if model.reading { readingBody } else { closedBody }
            case .tooLong: tooLongBody
            }
        }
    }

    // MARK: Pieces

    private var who: some View {
        HStack(spacing: 7) {
            HermesWho(task: model.task, label: whoLine.text, color: whoLine.color)
            Spacer(minLength: 0)
            // The grant line needs the room of the chip.
            if model.waitingBehind > 0 && !showsGrant { HermesWaitingChip(count: model.waitingBehind) }
        }
    }

    private var canAllow: Bool { HermesApproval.mayAnswer(.once, display: model.display, reachedEnd: model.reachedEnd) }

    /// Deny, the selector, the allow button. Allow is dim and dead (disabled, not only unclickable) until the text was read
    /// where that is required.
    private var answers: some View {
        HStack(spacing: 8) {
            SecondaryButton("Deny") { actions.answer("deny") }
            // With only "once" on offer there is nothing to choose: no selector.
            if model.choices.contains(.session) || model.choices.contains(.always) {
                HermesScopePicker(scope: model.scope, offered: model.choices, select: actions.select)
                    .opacity(canAllow ? 1 : 0.32)
                    .disabled(!canAllow)
            }
            Group {
                switch model.scope {
                case .once: PrimaryButton("Allow") { actions.answer("once") }
                case .session: PrimaryButton("Allow for the session") { actions.answer("session") }
                case .always: HermesDangerButton(title: "Allow always") { actions.answer("always") }
                }
            }
            .fixedSize()
            .opacity(canAllow ? 1 : 0.32)
            .disabled(!canAllow)
        }
        .focusable(false)
    }

    private func fade(_ view: some View, on: Bool) -> some View {
        view.mask(LinearGradient(stops: on
                                 ? [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .black.opacity(0.15), location: 1)]
                                 : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
    }

    /// What the closed card says about the part it does not show: how many lines, or that the start only is shown.
    private func countLine(_ preview: HermesApprovalDisplay.Preview) -> String {
        let n = model.display.sourceScalarCount
        let characters = String(localized: "\(n) characters in all")
        if preview.cut { return String(localized: "Start only") + " · " + characters }
        if preview.hiddenLines > 0 { return String(localized: "+\(preview.hiddenLines) lines") + " · " + characters }
        return characters
    }

    // MARK: Bodies

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            who
            HermesBlockFrame { HermesCommandText(runs: model.display.runs).frame(maxWidth: .infinity, alignment: .leading) }
            answers
        }
    }

    /// The closed card of a long command: the start (cut where it says it is cut), what is hidden, and the way to the whole
    /// text. No allow here.
    private var closedBody: some View {
        let preview = model.display.closedPreview(rows: 2)
        return VStack(alignment: .leading, spacing: 5) {
            who
            HermesBlockFrame(vertical: 4) {
                fade(HermesCommandText(runs: preview.runs).frame(maxWidth: .infinity, alignment: .leading), on: true)
            }
            HermesClosedActions(deny: String(localized: "Deny"), whole: String(localized: "See whole command"), count: countLine(preview),
                                onDeny: { actions.answer("deny") }, onWhole: { actions.setReading(true) })
        }
    }

    /// Over the ceiling: not answerable in the notch. The start, one sentence, Deny. Nothing that allows.
    private var tooLongBody: some View {
        let preview = model.display.closedPreview(rows: 2)
        return VStack(alignment: .leading, spacing: 5) {
            who
            HermesBlockFrame(vertical: 4) {
                fade(HermesCommandText(runs: preview.runs).frame(maxWidth: .infinity, alignment: .leading), on: true)
            }
            HStack(spacing: 10) {
                let n = model.display.sourceScalarCount
                Text("Too long to approve here (\(n) characters).")
                    .font(.system(size: 13)).foregroundColor(Color(hex: "#F1F2F4")).lineLimit(1)
                SecondaryButton("Deny") { actions.answer("deny") }
            }
            .focusable(false)
        }
    }

    /// The island grew: the whole text in a block that scrolls, the answers at the bottom.
    private var readingBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                HermesWho(task: model.task, label: whoLine.text, color: whoLine.color)
                Spacer(minLength: 0)
                if model.waitingBehind > 0 && !showsGrant { HermesWaitingChip(count: model.waitingBehind) }
                Button { actions.setReading(false) } label: {
                    HStack(spacing: 4) {
                        // The grant line needs the room of the word.
                        if !showsGrant { Text("Collapse").font(.system(size: 12, weight: .medium)) }
                        Image(systemName: "chevron.up").font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "#F1F2F4"))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.1)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityLabel(Text("Collapse"))
            }
            HermesReadingBlock(runs: model.display.runs, onReachedEnd: actions.reachedEnd)
                .id(model.requestID)
            answers
        }
    }
}

// MARK: - The reading block

/// A command in a block that scrolls. It tells when its end was on screen, from the geometry of the content: a text
/// that fits is at its end at once, a longer one when the last line was scrolled into view.
struct HermesReadingBlock: View {
    let runs: [HermesApprovalDisplay.Run]
    let onReachedEnd: () -> Void

    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var top: CGFloat = 0

    private struct ContentInfo: Equatable, Sendable { var top: CGFloat; var height: CGFloat }
    private struct ContentKey: PreferenceKey {
        static let defaultValue = ContentInfo(top: 0, height: 0)
        static func reduce(value: inout ContentInfo, nextValue: () -> ContentInfo) { value = nextValue() }
    }
    private struct ViewportKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    private static let space = "hermesReadingBlock"

    private func check() {
        guard viewportHeight > 0, contentHeight > 0 else { return }
        if top + contentHeight <= viewportHeight + 1.5 { onReachedEnd() }
    }

    var body: some View {
        ScrollView(.vertical) {
            HermesCommandText(runs: runs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentKey.self,
                                           value: ContentInfo(top: g.frame(in: .named(Self.space)).minY, height: g.size.height))
                })
        }
        .coordinateSpace(name: Self.space)
        .background(GeometryReader { g in Color.clear.preference(key: ViewportKey.self, value: g.size.height) })
        .onPreferenceChange(ContentKey.self) { info in
            contentHeight = info.height
            top = info.top
            check()
        }
        .onPreferenceChange(ViewportKey.self) { h in
            viewportHeight = h
            check()
        }
        .background(Color.white.opacity(0.07))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
