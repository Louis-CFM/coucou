#if !APPSTORE
import AppKit
import ApplicationServices
import SwiftUI

// A regular Claude Desktop chat (not a Code session) runs no hook, so Coucou never hears that a
// reply is done (#686). This watcher fills the gap, experimental and off by default: when you
// leave the Claude app while it is still writing (its "Stop response" button is on screen),
// Coucou looks once a second, through the Accessibility API, for that button to go away. Then
// Mochi jumps and the Claude Desktop pill says the reply is ready. Nothing runs while Claude is
// in front, while it isn't writing, or when the setting is off; no text of the chat is read,
// only whether the stop button is there.

@MainActor
final class ClaudeDesktopChatWatcher {
    static let shared = ClaudeDesktopChatWatcher()
    static let bundleId = "com.anthropic.claudefordesktop"
    static let pillId = "agent_claude-desktop"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeDesktopChatWatch") }
        set {
            UserDefaults.standard.set(newValue, forKey: "claudeDesktopChatWatch")
            if !newValue { shared.stopPolling() }
        }
    }

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var polls = 0
    /// A reply longer than this (in polls of one second) is given up on: no endless polling.
    private let maxPolls = 1_800

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                            object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            guard app?.bundleIdentifier == Self.bundleId, let pid else { return }
            MainActor.assumeIsolated { ClaudeDesktopChatWatcher.shared.claudeLeft(pid: pid) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                            object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundleId else { return }
            // You're back in Claude: you see the reply yourself.
            MainActor.assumeIsolated { ClaudeDesktopChatWatcher.shared.stopPolling() }
        })
    }

    private func claudeLeft(pid: pid_t) {
        guard Self.enabled, AXIsProcessTrusted(), timer == nil else { return }
        let app = AXUIElementCreateApplication(pid)
        // Electron builds its accessibility tree only when asked.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard Self.isWriting(app) else { return }
        polls = 0
        appendAppLog("nb.log", "[ClaudeDesktop] reply in progress, watching")
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ClaudeDesktopChatWatcher.shared.poll(pid: pid) }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll(pid: pid_t) {
        polls += 1
        guard Self.enabled, polls < maxPolls,
              NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { stopPolling(); return }
        let app = AXUIElementCreateApplication(pid)
        guard !Self.isWriting(app) else { return }
        stopPolling()
        replyFinished()
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func replyFinished() {
        appendAppLog("nb.log", "[ClaudeDesktop] reply finished")
        let state = AppState.shared
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        if state.soundEnabled { SoundEngine.shared.play("finish") }
        if let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            state.tasks[idx].pillBadge = .finished
            state.tasks[idx].steps = [String(localized: "claude-desktop.reply-ready")]
        }
    }

    // MARK: - The stop button

    /// Claude is writing while its stop button is on screen. Breadth-first through the windows,
    /// capped, reading only roles and button labels.
    nonisolated static func isWriting(_ app: AXUIElement) -> Bool {
        var queue: [AXUIElement] = children(of: app, attribute: kAXWindowsAttribute)
        var visited = 0
        while !queue.isEmpty, visited < 6_000 {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == (kAXButtonRole as String),
               ClaudeDesktopChat.isStopLabel([string(element, kAXDescriptionAttribute),
                                              string(element, kAXTitleAttribute),
                                              string(element, kAXHelpAttribute)]) {
                return true
            }
            queue.append(contentsOf: children(of: element, attribute: kAXChildrenAttribute))
        }
        return false
    }

    nonisolated private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
#endif

#if !APPSTORE
/// Settings → Agents → Claude Desktop chats.
struct ClaudeDesktopChatSettingsSection: View {
    @State private var on = ClaudeDesktopChatWatcher.enabled
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        GroupBox(String(localized: "claude-desktop.chat.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "claude-desktop.chat.toggle"), isOn: $on)
                    .onChange(of: on) { _, v in
                        ClaudeDesktopChatWatcher.enabled = v
                        if v && !AXIsProcessTrusted() {
                            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                            trusted = AXIsProcessTrustedWithOptions(options)
                        }
                    }
                Text(String(localized: "claude-desktop.chat.footer"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if on && !trusted {
                    Text(String(localized: "claude-desktop.chat.needs-accessibility"))
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(6)
        }
        .onAppear { trusted = AXIsProcessTrusted() }
    }
}
#endif
