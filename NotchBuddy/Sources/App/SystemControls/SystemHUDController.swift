#if !APPSTORE
import AppKit
import Combine
import SwiftUI

/// What the HUD shows. Read by SystemHUDView.
@MainActor
final class SystemHUDModel: ObservableObject {
    @Published var target: SystemHUDTarget = .volume
    @Published var level: Double = 0
    @Published var muted = false
    @Published var visible = false
    @Published var notchWidth: CGFloat = IslandConst.notchWidth
    @Published var notchHeight: CGFloat = IslandConst.notchHeight

    var mood: SystemHUDMood { SystemHUDLogic.mood(level: level, muted: muted) }
    /// Like the compact island: the notch plus two 80-point wings.
    var width: CGFloat { notchWidth + 160 }
    /// The notch's height, plus the strip under it with the icon and the bar.
    var height: CGFloat { notchHeight + SystemHUDController.stripHeight }
}

/// Volume and brightness keys → Coucou's own HUD in the notch.
///
/// Off by default (Settings → General → Volume and brightness keys). When on, the media
/// key tap hands each press here: the change is applied and shown in a small panel at the
/// top of the island's screen. A press is left to macOS (its own HUD) whenever Coucou
/// can't apply it, or while the island is open, so an approval or a card is never covered.
@MainActor
final class SystemHUDController {
    static let shared = SystemHUDController()
    static let enabledKey = "systemHUDEnabled"
    static let stripHeight: CGFloat = 30
    /// How long the HUD stays after the last press.
    static let showDuration: Duration = .milliseconds(1600)

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Each kind of key can be left to macOS on its own (all on by default).
    static func isEnabled(_ target: SystemHUDTarget) -> Bool {
        UserDefaults.standard.object(forKey: "systemHUD.\(target.rawValue)") as? Bool ?? true
    }

    static func setEnabled(_ on: Bool, for target: SystemHUDTarget) {
        UserDefaults.standard.set(on, forKey: "systemHUD.\(target.rawValue)")
    }

    let model = SystemHUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?
    private var modeWatch: AnyCancellable?

    private init() {
        // An approval or a card opening the island while the HUD shows: the HUD goes at once.
        modeWatch = AppState.shared.$mode
            .filter { $0 == .expanded }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hideNow() }
            }
    }

    /// At launch: starts the tap if the setting is on. Never prompts.
    func startIfEnabled() {
        guard Self.isEnabled else { return }
        start(prompt: false)
    }

    /// From Settings.
    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on { start(prompt: true) } else { stop() }
    }

    private func start(prompt: Bool) {
        MediaKeyTap.shared.onAction = { [weak self] action in
            self?.perform(action) ?? false
        }
        if MediaKeyTap.shared.start() { return }
        // No Accessibility yet: ask (from Settings only), then start as soon as it's given.
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        waitForTrust()
    }

    private func stop() {
        trustTask?.cancel()
        trustTask = nil
        MediaKeyTap.shared.stop()
        MediaKeyTap.shared.onAction = nil
        hideNow()
    }

    /// Checks every 2 s for up to 2 minutes, then gives up until the next launch or toggle.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, Self.isEnabled else { return }
                if AXIsProcessTrusted() {
                    MediaKeyTap.shared.start()
                    self?.trustTask = nil
                    return
                }
            }
        }
    }

    // MARK: - Applying a key

    /// Applies the action; false leaves the key to macOS.
    func perform(_ action: SystemHUDAction) -> Bool {
        // The island is open (an approval, a question, a card): macOS shows its own HUD.
        guard AppState.shared.mode != .expanded, Self.isEnabled(action.target) else { return false }
        switch action {
        case .toggleMute:
            guard let device = SystemVolume.defaultOutputDevice(),
                  let muted = SystemVolume.isMuted(device),
                  SystemVolume.setMuted(!muted, of: device) else { return false }
            show(.volume, level: SystemVolume.volume(of: device) ?? 0, muted: !muted)

        case .step(.volume, let direction, let fine):
            guard let device = SystemVolume.defaultOutputDevice(),
                  let level = SystemVolume.volume(of: device) else { return false }
            let muted = SystemVolume.isMuted(device) ?? false
            let next = SystemHUDLogic.volumeStep(level: level, muted: muted, direction: direction, fine: fine)
            guard SystemVolume.setVolume(next.level, of: device) else { return false }
            if next.muted != muted { _ = SystemVolume.setMuted(next.muted, of: device) }
            show(.volume, level: next.level, muted: next.muted)

        case .step(.display, let direction, let fine):
            let screen = DisplayBrightness.shared
            guard let level = screen.level() else { return false }
            let next = SystemHUDLogic.stepped(level, direction: direction, fine: fine)
            guard screen.setLevel(next) else { return false }
            show(.display, level: next, muted: false)

        case .step(.keyboard, let direction, let fine):
            let keyboard = KeyboardBacklight.shared
            guard let level = keyboard.level() else { return false }
            let next = SystemHUDLogic.stepped(level, direction: direction, fine: fine)
            guard keyboard.setLevel(next) else { return false }
            show(.keyboard, level: next, muted: false)
        }
        return true
    }

    /// Settings → Show a preview: the HUD at the current volume, without changing anything.
    func preview() {
        let device = SystemVolume.defaultOutputDevice()
        let level = device.flatMap { SystemVolume.volume(of: $0) } ?? 0.5
        let muted = device.flatMap { SystemVolume.isMuted($0) } ?? false
        show(.volume, level: level, muted: muted)
    }

    // MARK: - The panel

    private func show(_ target: SystemHUDTarget, level: Double, muted: Bool) {
        let app = AppState.shared
        model.notchWidth = app.notchWidth
        model.notchHeight = app.notchHeight
        model.target = target
        model.level = level
        model.muted = muted

        let panel = self.panel ?? makePanel()
        let screen = IslandWindowController.islandScreen().frame
        let size = CGSize(width: model.width, height: model.height)
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                              width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        model.visible = true

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.showDuration)
            guard !Task.isCancelled else { return }
            self?.model.visible = false
            // Let the closing animation play, then take the panel off screen:
            // Mochi's timeline pauses and the HUD costs nothing until the next key.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
        }
    }

    private func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        model.visible = false
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: model.width, height: model.height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Just above the island (mainMenu + 3), so the HUD shows over a compact island.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: SystemHUDView(model: model))
        self.panel = panel
        return panel
    }
}
#endif
