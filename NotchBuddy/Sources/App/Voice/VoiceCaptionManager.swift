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
    /// Capsule is expanded (full response readable, scrollable).
    @Published var isExpanded: Bool = false
}

// MARK: - VoiceCaptionManager
//
// Manages a borderless, non-activating NSPanel positioned below the notch center.
// Shows a compact capsule with:
//   – user transcript (gray, top line)
//   – AI response    (white, bottom line, streams in)
// Tap the capsule to expand (full response + scroll). Tap again or click elsewhere to close.
// Fades in/out in 0.2 s. Auto-hides 2 s after endConversation().
// Repositions with the island using the same open spring (0.5 s ease-out).
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

    private let captionWidth:        CGFloat = 360
    private let captionCompactHeight: CGFloat = 76    // 1 heard + 2 answer lines
    private let captionExpandedHeight: CGFloat = 240  // full response + scroll
    private let notchGap:             CGFloat = 6

    private var currentHeight: CGFloat { state.isExpanded ? captionExpandedHeight : captionCompactHeight }

    private init() {
        // Only these engine properties: observing the whole engine redraws on every mic frame.
        let engine = VoiceEngine.shared
        engine.$commandTranscript
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] t in
                MainActor.assumeIsolated { self?.state.liveLine = t }
            }
            .store(in: &subs)
        // Follow the island: it can open or close while speaking.
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
        // Collapse on tap-outside (global mouse-down while expanded).
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.state.isExpanded == true else { return }
                self?.setExpanded(false, animated: true)
            }
        }
    }

    // MARK: - Show / hide

    func show(on screen: NSScreen, notchHeight: CGFloat) {
        guard VoiceSettings.captionEnabled else { return }
        hideTask?.cancel()
        hideTask = nil
        state.isExpanded = false

        if panel == nil { _buildPanel() }
        self.screen = screen
        reposition(animated: false)

        guard let p = panel else { return }
        p.ignoresMouseEvents = false   // accept tap to expand
        if !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }

        state.isVisible = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 1
        }
    }

    func hide(after delay: TimeInterval = 0) {
        state.isExpanded = false
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

    /// Call when the conversation ends. Panel fades out after 2 s.
    func endConversation() {
        hide(after: 2.0)
    }

    // MARK: - Expand / collapse

    /// Called from VoiceCaptionView tap gesture.
    func toggleExpanded() {
        setExpanded(!state.isExpanded, animated: true)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard state.isExpanded != expanded else { return }
        state.isExpanded = expanded
        reposition(animated: animated)
    }

    // MARK: - Private

    private func _buildPanel() {
        let view = NSHostingView(rootView: VoiceCaptionView(state: state, manager: self))
        view.frame = NSRect(x: 0, y: 0, width: captionWidth, height: captionExpandedHeight)

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: captionWidth, height: captionExpandedHeight),
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
    /// Uses the same open spring duration as the island (easeOut 0.5 s).
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
        let h  = currentHeight
        // Panel grows upward: bottom at notchGap below the island, top at h above that.
        let origin = NSPoint(x: sf.midX - captionWidth / 2,
                             y: sf.maxY - visibleH - notchGap - h)
        let newFrame = NSRect(origin: origin, size: NSSize(width: captionWidth, height: h))

        if animated && p.isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                // Match the island's open spring (response 0.5, damping 0.72 ≈ easeOut 0.5 s).
                ctx.duration = 0.5
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().setFrame(newFrame, display: true)
            }
        } else {
            p.setFrame(newFrame, display: true)
        }
    }

    private func _fadeOut() {
        state.isVisible = false
        state.isExpanded = false
        guard let p = panel, p.isVisible else { return }
        p.ignoresMouseEvents = true
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
    let manager: VoiceCaptionManager

    /// While the mic is open: what I am saying, live. Afterwards: what I said + the answer.
    private var heard: String {
        guard state.isListening else { return state.userLine }
        return state.liveLine.isEmpty
            ? VoiceActionRunner.localizedString("voice.caption-listening", locale: VoiceSettings.answerLocale)
            : state.liveLine
    }
    private var answer: String { state.isListening ? "" : state.responseLine }

    // Show the expand indicator when the answer is long enough to be truncated.
    private var canExpand: Bool { !answer.isEmpty && answer.count > 80 }

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
                        if state.isExpanded {
                            ScrollView(.vertical, showsIndicators: false) {
                                Text(verbatim: answer)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 2)
                            }
                            .frame(maxHeight: 180)
                        } else {
                            HStack(alignment: .bottom, spacing: 4) {
                                Text(verbatim: answer)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if canExpand {
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.35))
                                        .padding(.bottom, 1)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: 360, alignment: .leading)
                .fixedSize(horizontal: false, vertical: !state.isExpanded)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.92))
                )
                .transition(.opacity)
                .onTapGesture { manager.toggleExpanded() }
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.75), value: state.isExpanded)
        .animation(.easeOut(duration: 0.2), value: heard.isEmpty && answer.isEmpty)
        .frame(width: 360, height: state.isExpanded ? 240 : 76, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
#endif
