#if !APPSTORE
import AppKit
import ApplicationServices
import SwiftUI

// A regular Claude Desktop chat (not a Code session) runs no hook, so Coucou never hears that a
// reply is done (#686). This watcher fills the gap, experimental and off by default: when you
// leave the Claude app while it is still writing (its "Stop response" button is on screen),
// the Claude Desktop pill shows Claude at work ("Claude is writing…"), and Coucou looks once a
// second, through the Accessibility API, for that button to go away. Then Mochi jumps and the
// pill says the reply is ready. Leaving right after sending, before the button shows, Coucou
// keeps looking for it for a few seconds instead of giving up. Nothing runs while Claude is in
// front, while it isn't writing, or when the setting is off; no text of the chat is read, only
// whether the stop button is there.

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
    /// Left Claude right after sending: the stop button may not be there yet. Looked for every
    /// half second, this many times (5 s), before deciding Claude isn't writing.
    private let startAttempts = 10
    private var attempts = 0
    /// The pill is showing "writing" because of this watcher (not a Code session's hooks):
    /// only then does the watcher put it back.
    private var showingWriting = false
    /// The pill was added by this watcher (not declared in Active pills): it goes after the reply.
    private var addedPill = false
    private var resetWork: DispatchWorkItem?

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
        if Self.isWriting(app) {
            watchReply(pid: pid)
            return
        }
        // Not writing yet, or not writing at all: look again for a few seconds (#686 missed
        // a reply when Claude was left right after sending, before its stop button showed).
        attempts = 0
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                let watcher = ClaudeDesktopChatWatcher.shared
                watcher.attempts += 1
                guard Self.enabled, watcher.attempts <= watcher.startAttempts,
                      NSRunningApplication(processIdentifier: pid)?.isTerminated == false else {
                    watcher.stopPolling()
                    return
                }
                guard Self.isWriting(AXUIElementCreateApplication(pid)) else { return }
                watcher.timer?.invalidate()
                watcher.timer = nil
                watcher.watchReply(pid: pid)
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Claude is writing: the pill says so, and Coucou waits for the stop button to go.
    private func watchReply(pid: pid_t) {
        polls = 0
        let label = Self.stopButtonLabel(AXUIElementCreateApplication(pid)) ?? "?"
        appendAppLog("nb.log", "[ClaudeDesktop] reply in progress (button: \(escapedForLog(label))), watching")
        showWriting()
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
              NSRunningApplication(processIdentifier: pid)?.isTerminated == false else {
            appendAppLog("nb.log", "[ClaudeDesktop] stopped watching (setting off, Claude quit, or \(polls) s)")
            stopPolling()
            return
        }
        let app = AXUIElementCreateApplication(pid)
        if let label = Self.stopButtonLabel(app) {
            // Once a minute: still the same button?
            if polls % 60 == 0 { appendAppLog("nb.log", "[ClaudeDesktop] still writing after \(polls) s (button: \(escapedForLog(label)))") }
            return
        }
        timer?.invalidate()
        timer = nil
        replyFinished()
    }

    /// Stops looking. Back in Claude, setting off, Claude quit, reply too long: the pill drops
    /// "writing" (you see the reply yourself, or there is nothing more to tell).
    func stopPolling() {
        timer?.invalidate()
        timer = nil
        guard showingWriting else { return }
        appendAppLog("nb.log", "[ClaudeDesktop] stopped watching, pill back to rest")
        showingWriting = false
        settlePill(after: 0)
    }

    // MARK: - The pill

    /// "Claude is writing…" on the pill, Mochi at work, the way a Code session shows. Not over a
    /// Code session of the Claude app that is busy on the same pill: its hooks own it then.
    private func showWriting() {
        let state = AppState.shared
        resetWork?.cancel()
        resetWork = nil
        if !state.tasks.contains(where: { $0.id == Self.pillId }) {
            let def = PillCatalog.definition(for: Self.pillId)
            state.addTask(AgentTask(id: Self.pillId, name: def?.name ?? "Claude Desktop",
                                    color: def?.color ?? "#D97757", state: .idle, steps: [], source: .agent))
            addedPill = true
        }
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
              [.idle, .finished, .sleeping].contains(state.tasks[idx].state) else { return }
        state.tasks[idx].state = .working
        state.tasks[idx].steps = [String(localized: "claude-desktop.writing")]
        state.tasks[idx].stepIndex = 0
        state.tasks[idx].pillBadge = nil
        showingWriting = true
        // Hidden island: out in its compact form, like any agent starting work.
        if state.mode == .hidden { NotificationCenter.default.post(name: .hookReveal, object: nil) }
    }

    private func replyFinished() {
        appendAppLog("nb.log", "[ClaudeDesktop] reply finished")
        let state = AppState.shared
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        if state.soundEnabled { SoundEngine.shared.play("finish") }
        if let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) {
            if showingWriting { state.tasks[idx].state = .finished }
            state.tasks[idx].pillBadge = .finished
            state.tasks[idx].steps = [String(localized: "claude-desktop.reply-ready")]
            state.tasks[idx].stepIndex = 0
        }
        guard showingWriting else { return }
        showingWriting = false
        // "Reply ready" stays a while, like a finished session, then the pill rests.
        settlePill(after: 8)
    }

    /// The pill back at rest after `delay`: idle, or gone if this watcher added it. Left alone if
    /// a Code session's hooks took it meanwhile (it is no longer in the state set here).
    private func settlePill(after delay: TimeInterval) {
        resetWork?.cancel()
        let added = addedPill
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                let watcher = ClaudeDesktopChatWatcher.shared
                watcher.resetWork = nil
                let state = AppState.shared
                guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
                      [.working, .finished].contains(state.tasks[idx].state) else { return }
                if added {
                    watcher.addedPill = false
                    state.removeTask(id: Self.pillId)
                } else {
                    state.tasks[idx].state = .idle
                    state.tasks[idx].steps = []
                }
            }
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - The stop button

    /// Claude is writing while its stop button is on screen.
    nonisolated static func isWriting(_ app: AXUIElement) -> Bool {
        stopButtonLabel(app) != nil
    }

    /// The label of the stop button on screen, nil when there is none. Breadth-first through
    /// the windows, capped, reading only roles and button labels (the label goes to the log,
    /// to tell which button was taken for the stop button; nothing of the chat is read).
    nonisolated static func stopButtonLabel(_ app: AXUIElement) -> String? {
        var queue: [AXUIElement] = children(of: app, attribute: kAXWindowsAttribute)
        var visited = 0
        while !queue.isEmpty, visited < 6_000 {
            let element = queue.removeFirst()
            visited += 1
            if string(element, kAXRoleAttribute) == (kAXButtonRole as String) {
                let labels = [string(element, kAXDescriptionAttribute),
                              string(element, kAXTitleAttribute),
                              string(element, kAXHelpAttribute)]
                if ClaudeDesktopChat.isStopLabel(labels) {
                    return labels.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
                }
            }
            queue.append(contentsOf: children(of: element, attribute: kAXChildrenAttribute))
        }
        return nil
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
