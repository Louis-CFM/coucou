#if !APPSTORE
import AppKit
import SwiftUI

/// A file (a ⌘⇧2 thumbnail, a capture, anything from Finder) dropped on a session in the island
/// goes into that session's prompt: Coucou brings its terminal forward and types the path, as a
/// drag onto the terminal would. Claude Code takes it as a file, an image path as the image.
/// GitHub build: typing into another app needs the Accessibility permission.
@MainActor
enum SessionDrop {
    /// The sessions offered while a file is dragged over the island: three at most.
    static func targets(_ state: AppState) -> [AgentTask] {
        Array(state.tasks.filter { !$0.isIntegration && $0.sessionBundleId != nil }.prefix(3))
    }

    /// Where each target sits, in the island's hosting view (top-left origin).
    static var frames: [String: CGRect] = [:]

    /// The target under the pointer, in the same coordinates.
    static func hit(_ point: CGPoint, state: AppState) -> String? {
        guard state.view == .upload else { return nil }
        let ids = Set(targets(state).map(\.id))
        return frames.first { ids.contains($0.key) && $0.value.insetBy(dx: -4, dy: -4).contains(point) }?.key
    }

    static func send(_ urls: [URL], to taskId: String, state: AppState) {
        guard let task = state.tasks.first(where: { $0.id == taskId }) else { return }
        let text = LaunchScript.dropText(urls.map(\.path))
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.compactMap(\.bundleIdentifier))
        let app = TerminalTarget.pick(sessionBundleId: task.sessionBundleId, running: running)
            .flatMap { id in apps.first { $0.bundleIdentifier == id } }
        state.fileDragOver = false
        state.dropSessionTarget = nil
        UploadSequenceEngine.shared.exitZone()
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
        appendAppLog("nb.log", "[Drop] \(urls.count) file(s) into \(task.name)")
        Task { @MainActor in
            _ = app?.activate()
            try? await Task.sleep(for: .milliseconds(250))
            if paste(text) {
                SoundEngine.shared.play("send")
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            } else {
                state.noteMessage = String(localized: "drop.session.copied")
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.note)
            }
        }
    }

    /// Types the text with ⌘V, then gives the clipboard back. False without the Accessibility
    /// permission: the text then stays on the clipboard.
    private static func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let saved = CapturePaste.snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = FlowPaste.vKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            guard board.changeCount == count else { return }
            board.clearContents()
            guard !saved.isEmpty else { return }
            board.writeObjects(saved.map { entry in
                let item = NSPasteboardItem()
                for (type, data) in entry { item.setData(data, forType: type) }
                return item
            })
        }
        return true
    }
}

/// The sessions on the right of the drop card: drop the file on one to send it to its prompt.
struct SessionDropTargets: View {
    @ObservedObject var state: AppState

    var body: some View {
        let targets = SessionDrop.targets(state)
        if !targets.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("drop.session.title")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                ForEach(targets) { task in
                    let on = state.dropSessionTarget == task.id
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: task.color)).frame(width: 7, height: 7)
                        Text(verbatim: task.name)
                            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundColor(on ? Color(hex: "#34D399") : Color(hex: "#D5D7DB"))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .frame(width: 150, alignment: .leading)
                    .background(on ? Color(hex: "#22C55E").opacity(0.16) : Color.white.opacity(0.07))
                    .overlay(Capsule().stroke(on ? Color(hex: "#22C55E").opacity(0.7) : Color.clear, lineWidth: 1))
                    .clipShape(Capsule())
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { SessionDrop.frames[task.id] = $0 }
                }
            }
            .animation(.easeOut(duration: 0.12), value: state.dropSessionTarget)
        }
    }
}
#endif
