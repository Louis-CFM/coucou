import SwiftUI
import AppKit

/// Grip at the bottom edge of the chat card: drag to stretch the chat, double click to toggle between
/// the default height and the maximum. The height lives in `AppState` (see `ChatHeight`).
struct ChatResizeGrip: View {
    @ObservedObject var state: AppState
    @State private var hovering = false
    @State private var cursorPushed = false
    @State private var dragStartHeight: CGFloat?
    @State private var dragStartStored: CGFloat?
    /// True only while the gesture is alive: SwiftUI resets it when the gesture is cancelled too (no `onEnded`).
    @GestureState private var gestureAlive = false

    private var active: Bool { hovering || dragStartHeight != nil }

    var body: some View {
        if state.chatCanStretch {
            Capsule()
                .fill(Color.white.opacity(active ? 0.45 : 0.14))
                .frame(width: 36, height: 4)
                .frame(width: 140, height: 12)
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.15), value: active)
                .onHover { inside in
                    hovering = inside
                    // The panel grows now, before the mouse goes down, not inside the first drag tick.
                    if inside && !state.chatRoomRequested { state.chatRoomRequested = true }
                    updateCursor()
                }
                .onTapGesture(count: 2) { state.toggleChatStretch() }
                .gesture(
                    // Global space: the grip moves with the island while dragging, the window top does not.
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .updating($gestureAlive) { _, alive, _ in alive = true }
                        .onChanged { value in
                            if dragStartHeight == nil {
                                dragStartHeight = state.chatPromptHeight
                                dragStartStored = state.chatStretchedHeight
                                state.chatResizing = true
                                updateCursor()
                            }
                            let height = ChatHeight.dragged(start: dragStartHeight ?? state.chatPromptHeight,
                                                            translation: value.translation.height,
                                                            messageCount: state.promptMessageCount,
                                                            maximum: state.chatMaxHeight)
                            state.setChatStretch(height, persist: false)
                        }
                        .onEnded { _ in endDrag() }
                )
                // A cancelled gesture never calls `onEnded`, but it does reset `gestureAlive`.
                .onChange(of: gestureAlive) { _, alive in if !alive { endDrag() } }
                // The chat went away under the drag (an approval arrived, the island folded).
                .onChange(of: state.view) { _, _ in endDragIfChatIsGone() }
                .onChange(of: state.mode) { _, _ in endDragIfChatIsGone() }
                .help(String(localized: "Drag to resize the chat · double-click to expand or reduce"))
                .onDisappear {
                    endDrag()
                    hovering = false
                    updateCursor()
                }
        }
    }

    private func endDragIfChatIsGone() {
        if state.view != .prompt || state.mode != .expanded { endDrag() }
    }

    /// Safe to call more than once: only the first call after a drag started does anything.
    private func endDrag() {
        guard let start = dragStartHeight else { return }
        // A jitter of a double click keeps the stretch it had. The flag may already be cleared by the
        // mouse up monitor; the island then springs to a height it already has.
        state.setChatStretch(ChatHeight.committedAfterDrag(height: state.chatPromptHeight, start: start,
                                                           startStored: dragStartStored,
                                                           messageCount: state.promptMessageCount))
        state.chatResizing = false
        dragStartHeight = nil
        dragStartStored = nil
        updateCursor()
    }

    private func updateCursor() {
        if active && !cursorPushed {
            NSCursor.resizeUpDown.push()
            cursorPushed = true
        } else if !active && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

/// Keeps `pinned` true while the list follows its bottom, and false once the user scrolls away from it
/// (see `ChatScrollPolicy.pinned`). `onViewportChange` runs when the list gets taller or shorter while
/// pinned (the chat was stretched or reduced), so the newest text does not end up under the fold.
struct PinnedScrollTracking: ViewModifier {
    @Binding var pinned: Bool
    var onViewportChange: () -> Void

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: ChatScrollPolicy.Metrics.self) { g in
                ChatScrollPolicy.Metrics(offsetY: g.contentOffset.y, contentHeight: g.contentSize.height,
                                         viewportHeight: g.containerSize.height)
            } action: { old, new in
                let next = ChatScrollPolicy.pinned(after: pinned, from: old, to: new)
                if next != pinned { pinned = next }
                if next && old.viewportHeight != new.viewportHeight { onViewportChange() }
            }
    }
}

extension View {
    func pinnedScrollTracking(_ pinned: Binding<Bool>, onViewportChange: @escaping () -> Void = {}) -> some View {
        modifier(PinnedScrollTracking(pinned: pinned, onViewportChange: onViewportChange))
    }
}
