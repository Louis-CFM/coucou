import SwiftUI

#if !APPSTORE

/// The body of the reply view of a cmux session: the turns of the session on screen, drawn by the same list the Hermes
/// chat uses. It observes one object, the screen of the shown session, so an event redraws this view and not the
/// header, the chips or the field. The scroll rule is the one the reply view always had.
struct CmuxTimelineBody: View {
    @ObservedObject var screen: CmuxTimelineScreen
    let speaker: ChatSpeaker
    /// Follow the newest row unless the user scrolled up. Owned by `CmuxPromptView` (a send pins it again).
    @Binding var pinned: Bool

    var body: some View {
        if screen.messages.isEmpty && !screen.running {
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ChatTurnList(messages: screen.messages, speaker: { _ in speaker },
                                 streamingLast: screen.running, typing: screen.running)
                        .padding(.vertical, 2)
                }
                .pinnedScrollTracking($pinned) { scrollToEnd(proxy) }
                .onChange(of: screen.revision) { _, _ in if pinned { scrollToEnd(proxy) } }
                .onAppear { pinned = true; scrollToEnd(proxy) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if screen.running { proxy.scrollTo("typing", anchor: .bottom) }
        else if let last = screen.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

extension FileDiff {
    /// The diff card of an edit whose full diff is gone from the store (50 per pill, an idle hour): the true counts, one
    /// hunk made of the lines the row kept and a last context line. Built only when such a row is tapped.
    static func rebuilt(from edit: ChatEdit) -> FileDiff {
        var lines = edit.preview.map { line -> DiffLine in
            let kind: DiffLine.Kind
            switch line.kind {
            case .context: kind = .context
            case .added: kind = .added
            case .removed: kind = .removed
            }
            return DiffLine(kind: kind, text: line.text, origLine: -1, newLine: -1)
        }
        if !lines.isEmpty { lines.append(DiffLine(kind: .context, text: "…", origLine: -1, newLine: -1)) }
        return FileDiff(path: edit.path, added: edit.added, removed: edit.removed,
                        hunks: lines.isEmpty ? [] : [DiffHunk(origStart: 1, newStart: 1, lines: lines)],
                        tooLarge: edit.tooLarge, isNewFile: edit.isNewFile)
    }
}

#endif
