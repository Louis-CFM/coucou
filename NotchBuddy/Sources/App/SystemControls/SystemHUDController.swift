#if !APPSTORE
import AppKit
import SwiftUI

/// What the level card shows. Read by SystemLevelCard, SystemLevelHeaderPill and BotPlacement.
@MainActor
final class SystemHUDModel: ObservableObject {
    @Published var target: SystemHUDTarget = .volume
    @Published var level: Double = 0
    @Published var muted = false
    /// The header pill: shown instead of the card while the island is open on one of the
    /// few views a switch would break (an upload, the voice, the chat…).
    @Published var lineVisible = false
}

/// Volume and brightness keys, shown the way Coucou shows an upload: the island opens on a
/// low card (IslandView.level) and Mochi rides its track at the level, with the level's face.
///
/// Off by default (Settings → Volume & brightness). When on, the media key tap hands each
/// press here: the change is applied, then shown, and the macOS HUD never appears unless
/// Coucou can't apply the change. Where it shows depends on the island:
/// - hidden or compact: it opens silently on the card, and goes back 1.6 s after the last press;
/// - open: the card takes the view's place for that time (home, a Claude session, an
///   approval — Claude waits for minutes — a question…), then that view comes back;
/// - open on one of the few views a switch breaks (`keptViews`): that stays as it is; Mochi
///   reacts and the value shows in a pill in the island's header (SystemLevelHeaderPill).
@MainActor
final class SystemHUDController {
    static let shared = SystemHUDController()
    static let enabledKey = "systemHUDEnabled"
    /// How long the card stays after the last press.
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

    /// How the current press is shown, and so how to put things back afterwards.
    private enum Presentation {
        /// The island was hidden or compact: it opened on the card and goes back to that mode.
        case opened(from: IslandMode)
        /// The island was open: the card took the view's place, and the view comes back.
        case swapped(from: IslandView)
        /// The island was open on a view that must stay: only the header pill shows.
        case line
    }
    private var presentation: Presentation?

    /// Open views the card never stands in for, because leaving them breaks something:
    /// an upload in progress is cancelled (IslandContainer ends the upload sequence on any
    /// other view), the voice stops listening, the greeting is cut, and the chat or a mail
    /// being written loses its text field's focus — so does a new session's prompt (.launch).
    private static let keptViews: Set<IslandView> = [
        .upload, .uploading, .choose, .listening, .voiceResult, .greeting, .prompt, .launch, .mail,
    ]
    private var hideTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?

    private init() {}

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
        finish()
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
        // The island is open on something else (an approval, a question, a card): macOS
        // shows its own HUD. Open on the level card: it simply follows.
        // No island to show it in: the key stays with macOS, never applied without feedback.
        guard island != nil, Self.isEnabled(action.target) else { return false }
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
            SystemHUDSound.shared.playVolumeStep(level: next.level, muted: next.muted)

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

    /// Settings → Show a preview: the card at the current volume, changing nothing.
    func preview() {
        let device = SystemVolume.defaultOutputDevice()
        let level = device.flatMap { SystemVolume.volume(of: $0) } ?? 0.5
        let muted = device.flatMap { SystemVolume.isMuted($0) } ?? false
        show(.volume, level: level, muted: muted, direction: 1)
    }

    // MARK: - The level card

    /// The island, handed over by AppDelegate at launch.
    weak var island: IslandWindowController?

    private func show(_ target: SystemHUDTarget, level: Double, muted: Bool, direction: Int) {
        model.target = target
        model.level = level
        model.muted = muted

        let app = AppState.shared
        if presentation == nil, let island {
            if app.mode != .expanded {
                // Open on the card, from wherever the island was, without the open / close
                // sounds a volume key would otherwise make every time.
                presentation = .opened(from: app.mode)
                silently {
                    island.fsm.openedExternally()
                    island.expand(to: .level)
                }
            } else if !Self.keptViews.contains(app.view) {
                presentation = .swapped(from: app.view)
                app.view = .level
            } else {
                presentation = .line
            }
        }
        if case .line = presentation { model.lineVisible = true }

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

    /// After the last press, things go back to how they were. Not if something else took the
    /// island meanwhile (an approval or a question replaced the card): then it is theirs.
    private func finish() {
        hideTask?.cancel()
        hideTask = nil
        model.lineVisible = false
        guard let shown = presentation else { return }
        presentation = nil
        let app = AppState.shared
        guard let island, app.mode == .expanded, app.view == .level else { return }

        switch shown {
        case .line:
            return
        case .swapped(let view):
            // Back where it was, unless that is gone meanwhile (an approval or a question
            // answered from the terminal): then wherever the island would open now.
            let gone = (view == .approval && app.pendingApproval == nil)
                || (view == .question && app.pendingQuestion == nil)
            app.view = gone ? island.defaultView() : view
        case .opened(let before):
            // The pointer on it: the card gives way to home, and the island folds as usual.
            if pointerOnIsland() {
                app.view = island.defaultView()
                return
            }
            silently {
                // home → petit: the island state machine folds it to compact (its own path)…
                island.fsm.collapse()
                // …and back to hidden if it was hidden.
                if before == .hidden {
                    island.fsm.hiddenExternally()
                    island.setMode(.hidden)
                }
            }
            // The card leaves the view only once folded, so the open island never resizes to it.
            app.view = island.defaultView()
        }
    }

    /// Runs island changes without the open / close / peek sounds.
    private func silently(_ change: () -> Void) {
        let sounds = SoundEngine.shared.enabled
        SoundEngine.shared.enabled = false
        change()
        SoundEngine.shared.enabled = sounds
    }

    private func pointerOnIsland() -> Bool {
        let app = AppState.shared
        let (w, h) = islandSize(mode: app.mode, view: app.view, nw: app.notchWidth, nh: app.notchHeight)
        return IslandWindowController.islandScreenRect(size: CGSize(width: w, height: h))
            .contains(NSEvent.mouseLocation)
    }
}
#endif
