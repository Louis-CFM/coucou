#if !APPSTORE
import AppKit
import Combine
import SwiftUI

// MARK: - VoiceCaptionState

/// Holds the two text lines shown in the caption capsule.
/// Mutated only from @MainActor (VoiceCaptionManager).
final class VoiceCaptionState: ObservableObject {
    @Published var userLine: String = ""
    @Published var responseLine: String = ""
    @Published var isVisible: Bool = false
    /// Live words while the mic is open for a command (mirrors VoiceEngine).
    @Published var liveLine: String = ""
    @Published var isListening: Bool = false
}

// MARK: - VoiceCaptionManager
//
// Manages a borderless, non-activating NSPanel positioned below the notch center.
// Shows a compact capsule with:
//   – user transcript (gray, top line)
//   – AI response    (white, bottom line, streams in)
// Fades in/out in 0.2s. Auto-hides 2s after endConversation().
//
// Usage:
//   VoiceCaptionManager.shared.show(on: screen, notchHeight: 36)
//   VoiceCaptionManager.shared.setUserLine("Ajoute GitHub")
//   VoiceCaptionManager.shared.appendResponse("D'accord.")
//   VoiceCaptionManager.shared.endConversation()

@MainActor
final class VoiceCaptionManager {
    static let shared = VoiceCaptionManager()

    let state = VoiceCaptionState()

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var subs: Set<AnyCancellable> = []

    private let captionWidth:  CGFloat = 360
    private let captionHeight: CGFloat = 76   // 1 line heard + 2 lines of answer
    private let notchGap:      CGFloat = 6

    private init() {
        // Only these two engine properties: observing the whole engine would redraw
        // the caption on every mic level change.
        let engine = VoiceEngine.shared
        engine.$commandTranscript
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                MainActor.assumeIsolated { self?.state.liveLine = t }
            }
            .store(in: &subs)
        // Follow the island: it can open or close while I am talking.
        let app = AppState.shared
        app.$mode.combineLatest(app.$view)
            .removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition(animated: true) }
            }
            .store(in: &subs)
        engine.$isListeningForCommand
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state.isListening = on
                    if on { self.state.liveLine = "" }
                }
            }
            .store(in: &subs)
    }

    // MARK: - Show / hide

    func show(on screen: NSScreen, notchHeight: CGFloat) {
        guard VoiceSettings.captionEnabled else { return }
        hideTask?.cancel()
        hideTask = nil

        if panel == nil { _buildPanel() }
        self.screen = screen
        reposition(animated: false)

        guard let p = panel else { return }
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }

        state.isVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
    }

    func hide(after delay: TimeInterval = 0) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self._fadeOut() }
        }
    }

    // MARK: - Content updates

    func setUserLine(_ text: String) {
        state.userLine = text
        state.responseLine = ""
    }

    func appendResponse(_ chunk: String) {
        if state.responseLine.isEmpty {
            state.responseLine = chunk
        } else {
            state.responseLine += " " + chunk
        }
    }

    func clearResponse() {
        state.responseLine = ""
    }

    /// Call when the conversation ends. Panel fades out after 2s.
    func endConversation() {
        hide(after: 2.0)
    }

    // MARK: - Private

    private func _buildPanel() {
        let view = NSHostingView(rootView: VoiceCaptionView(state: state))
        view.frame = NSRect(x: 0, y: 0, width: captionWidth, height: captionHeight)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: captionWidth, height: captionHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        // Same level as the island, so the caption is never hidden behind it.
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.contentView = view
        p.alphaValue = 0
        panel = p
    }

    private var screen: NSScreen?

    /// Just under the visible island (compact, open or hidden), centred on it.
    /// The island window is a fixed panel: its visible height comes from islandSize().
    private func reposition(animated: Bool) {
        guard let p = panel, let screen else { return }
        let app = AppState.shared
        let (_, fixedH) = islandSize(mode: app.mode, view: app.view, progress: app.uploadProgress,
                                     nw: app.notchWidth, nh: app.notchHeight)
        var islandH = fixedH
        if app.mode == .expanded && app.view == .prompt {
            islandH = min(300, 240 + CGFloat(app.chatHistory.count) * 40)
        }
        let visibleH = max(islandH, app.notchHeight)
        let sf = screen.frame
        let origin = NSPoint(x: sf.midX - captionWidth / 2,
                             y: sf.maxY - visibleH - notchGap - captionHeight)
        if animated && p.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                p.animator().setFrameOrigin(origin)
            }
        } else {
            p.setFrameOrigin(origin)
        }
    }

    private func _fadeOut() {
        state.isVisible = false
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in self.panel?.orderOut(nil) }
        })
    }
}

// MARK: - VoiceCaptionView

struct VoiceCaptionView: View {
    @ObservedObject var state: VoiceCaptionState

    /// While the mic is open: what I am saying, live. Afterwards: what I said + the answer.
    private var heard: String {
        guard state.isListening else { return state.userLine }
        return state.liveLine.isEmpty ? String(localized: "voice.caption-listening") : state.liveLine
    }
    private var answer: String { state.isListening ? "" : state.responseLine }

    var body: some View {
        VStack(spacing: 0) {
            if !heard.isEmpty || !answer.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if !heard.isEmpty {
                        Text(verbatim: heard)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if !answer.isEmpty {
                        Text(verbatim: answer)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.92))
                )
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: heard.isEmpty && answer.isEmpty)
        .frame(width: 360, height: 76, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
#endif
