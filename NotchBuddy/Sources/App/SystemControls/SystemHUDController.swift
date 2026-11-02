#if !APPSTORE
import AppKit
import Combine
import SwiftUI

/// What the line under the island shows. Read by SystemLevelLine.
@MainActor
final class SystemHUDModel: ObservableObject {
    @Published var target: SystemHUDTarget = .volume
    @Published var level: Double = 0
    @Published var muted = false
    @Published var visible = false
}

/// Volume and brightness keys, shown the way Coucou shows everything: by Mochi.
///
/// Off by default (Settings → Volume & brightness). When on, the media key tap hands each
/// press here: the change is applied, the island comes out in its compact form if it was
/// hidden, Mochi hops or squashes with the level, and the vitals-style capsule under the
/// island says the value. Nothing new is drawn. A press is left to macOS (its own HUD)
/// whenever Coucou can't apply it, or while the island is open, so an approval or a card
/// is never disturbed.
@MainActor
final class SystemHUDController {
    static let shared = SystemHUDController()
    static let enabledKey = "systemHUDEnabled"
    /// How long Mochi and the line stay after the last press.
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
    /// True while the island is out only because of a key: it goes back to hidden after.
    private var raisedIsland = false
    private var hideTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?
    private var modeWatch: AnyCancellable?

    private init() {
        // An approval, a question or a card opening the island: the line goes at once, and
        // the island is no longer ours to fold.
        modeWatch = AppState.shared.$mode
            .filter { $0 == .expanded }
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.raisedIsland = false
                    self?.hideNow()
                }
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
            show(.volume, level: SystemVolume.volume(of: device) ?? 0, muted: !muted, direction: 0)

        case .step(.volume, let direction, let fine):
            guard let device = SystemVolume.defaultOutputDevice(),
                  let level = SystemVolume.volume(of: device) else { return false }
            let muted = SystemVolume.isMuted(device) ?? false
            let next = SystemHUDLogic.volumeStep(level: level, muted: muted, direction: direction, fine: fine)
            guard SystemVolume.setVolume(next.level, of: device) else { return false }
            if next.muted != muted { _ = SystemVolume.setMuted(next.muted, of: device) }
            show(.volume, level: next.level, muted: next.muted, direction: direction)

        case .step(.display, let direction, let fine):
            let screen = DisplayBrightness.shared
            guard let level = screen.level() else { return false }
            let next = SystemHUDLogic.stepped(level, direction: direction, fine: fine)
            guard screen.setLevel(next) else { return false }
            show(.display, level: next, muted: false, direction: direction)

        case .step(.keyboard, let direction, let fine):
            let keyboard = KeyboardBacklight.shared
            guard let level = keyboard.level() else { return false }
            let next = SystemHUDLogic.stepped(level, direction: direction, fine: fine)
            guard keyboard.setLevel(next) else { return false }
            show(.keyboard, level: next, muted: false, direction: direction)
        }
        return true
    }

    /// Settings → Show a preview: Mochi and the line at the current volume, changing nothing.
    func preview() {
        let device = SystemVolume.defaultOutputDevice()
        let level = device.flatMap { SystemVolume.volume(of: $0) } ?? 0.5
        let muted = device.flatMap { SystemVolume.isMuted($0) } ?? false
        show(.volume, level: level, muted: muted, direction: 1)
    }

    // MARK: - Showing it in the island

    private var island: IslandWindowController? {
        (NSApp.delegate as? AppDelegate)?.islandController
    }

    private func show(_ target: SystemHUDTarget, level: Double, muted: Bool, direction: Int) {
        model.target = target
        model.level = level
        model.muted = muted
        model.visible = true

        // Hidden island: out in its compact form, silently, the way music playing brings it out.
        if let island, island.fsm.state == .hidden {
            island.silentNextReveal = true
            island.fsm.reveal()
            island.silentNextReveal = false
            raisedIsland = true
        }
        NotificationCenter.default.post(
            name: .botSystemLevel,
            object: SystemHUDReaction(direction: direction,
                                      mood: SystemHUDLogic.mood(level: level, muted: muted)))

        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.showDuration)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// After the last press: the line goes, and an island the keys brought out goes back
    /// to hidden, unless something else now uses it (the pointer on it, an alert, a hover).
    private func finish() {
        hideNow()
        guard raisedIsland else { return }
        raisedIsland = false
        let app = AppState.shared
        guard let island, island.fsm.state == .petit, app.mode == .compact,
              app.pendingApproval == nil, app.pendingQuestion == nil,
              !pointerOnIsland() else { return }
        island.fsm.hiddenExternally()
        island.setMode(.hidden)
    }

    private func hideNow() {
        hideTask?.cancel()
        hideTask = nil
        model.visible = false
    }

    private func pointerOnIsland() -> Bool {
        let app = AppState.shared
        let (w, h) = islandSize(mode: .compact, view: app.view, nw: app.notchWidth, nh: app.notchHeight)
        return IslandWindowController.islandScreenRect(size: CGSize(width: w, height: h))
            .contains(NSEvent.mouseLocation)
    }
}
#endif
