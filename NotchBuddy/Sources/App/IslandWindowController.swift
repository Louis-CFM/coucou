import AppKit
import Combine
import SwiftUI

@MainActor
final class IslandWindowController: NSWindowController {

    private var islandPanel: IslandPanel!
    private var state: AppState { AppState.shared }

    // State machine (replaces all hover/absence/auto-close timers)
    let fsm = IslandStateMachine()

    private var wasInIsland = false
    private var frameTimer: Timer?
    private var keyMonitor: Any?
    private var viewSubscription: AnyCancellable?
    private var displaySubscription: AnyCancellable?
    private var autoCloseSubscription: AnyCancellable?
    private var openOnHoverSubscription: AnyCancellable?

    // Suppress peek sound on next reveal (e.g. musicReveal)
    var silentNextReveal = false

    // Finished-pin timer
    private var finishedPinTimer: DispatchWorkItem?

    // Bot-head hover (love emote — mirrors prototype botHover())
    private var hoverTimer: DispatchWorkItem?
    private var botHoverTimer: DispatchWorkItem?
    private var botHovering: Bool = false
    private var lastLoveTime: Double = 0
    private var botHoverStartPos: CGPoint = .zero

    // Window attach drag (M8)
    private var attachDragStart: NSPoint? = nil
    private var pendingIslandClick = false   // any island click → expand on mouseUp
    private var inAttachDrag = false
    private var dragGhostPanel: NSPanel? = nil
    private var dragGhostSize: CGFloat = 0
    private var ghostCurrentOrigin: NSPoint = .zero
    private var highlightPanel: NSPanel? = nil
    private var highlightWindowPid: pid_t = 0

    // Notch real dimensions (set on init)
    private var notchW: CGFloat = IslandConst.notchWidth
    private var notchH: CGFloat = IslandConst.notchHeight
    private var hasNotch = true

    // Island-local key monitor (active only when island is key window)
    private var localKeyMonitor: Any?

    convenience init() {
        let screen = Self.targetScreen(for: AppState.shared.islandDisplay)
        Self.currentScreen = screen
        let geometry = Self.screenGeometry(for: screen)
        let nW = geometry.width
        let nH = geometry.height

        let panelW: CGFloat = 720
        let panelH: CGFloat = 560
        let sf = screen.frame
        let panel = IslandPanel(
            contentRect: NSRect(x: sf.midX - panelW/2, y: sf.maxY - panelH,
                                width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.notchWidth  = nW
        panel.notchHeight = nH

        self.init(window: panel)
        self.islandPanel = panel
        self.notchW = nW
        self.notchH = nH
        self.hasNotch = geometry.hasNotch
        setupPanel(screen: screen)
    }

    private func setupPanel(screen: NSScreen) {
        guard let panel = window as? IslandPanel else { return }
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        // Propagate real notch dimensions to AppState
        AppState.shared.notchWidth  = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch

        let contentSize = panel.contentRect(forFrameRect: panel.frame).size

        // Apple-recommended pattern: put NSHostingView and drag destination as siblings
        // inside a common superview, rather than embedding one inside the other.
        let container = NSView(frame: NSRect(origin: .zero, size: contentSize))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: IslandRootView()
            .environmentObject(AppState.shared)
            .environment(\.layoutDirection, .leftToRight))
        hosting.frame = NSRect(origin: .zero, size: contentSize)
        hosting.autoresizingMask = [.width, .height]

        // FileDropNSView sits below the hosting view (hitTest returns nil → no mouse interference).
        // AppKit routes NSDraggingDestination events to registered views independently of hitTest.
        let dropView = FileDropNSView(frame: NSRect(origin: .zero, size: contentSize))
        dropView.autoresizingMask = [.width, .height]
        dropView.onDragEntered = { _ in
            Task { @MainActor in
                AppState.shared.fileDragOver = true
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.upload)
            }
        }
        dropView.onDragUpdated = { _ in }
        dropView.onDragExited = {
            Task { @MainActor in
                AppState.shared.fileDragOver = false
                // Do NOT collapse — drag session still active; island stays open.
            }
        }
        dropView.onFilesDropped = { urls in
            Task { @MainActor in
                await FileDropHandler.handle(urls: urls, state: AppState.shared)
            }
        }

        container.addSubview(hosting)    // z-bottom: SwiftUI + mouse events
        container.addSubview(dropView)   // z-top: drag only (hitTest→nil, transparent to mouse)
        panel.contentView = container

        startPolling()
        observeScreenForPolling()
        startKeyMonitor()
        startLocalKeyMonitor()
        startHotKeys()
        wireFSM()

        // Make panel key whenever the prompt/chat view becomes active
        // (nonactivatingPanel never auto-becomes key, but TextField needs it)
        viewSubscription = state.$view
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newView in
                guard let self else { return }
                if newView == .prompt {
                    self.islandPanel.makeKey()
                }
            }

        // Screen choice changed in Settings: move right away (explicit user action).
        displaySubscription = state.$islandDisplay
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] choice in
                self?.moveToTargetScreen(choice: choice)
            }

        // Screen plugged/unplugged, lid closed, arrangement or resolution changed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.moveToTargetScreen(choice: AppState.shared.islandDisplay) }
        }
    }

    // MARK: - Screen choice

    private func moveToTargetScreen(choice: IslandDisplayChoice) {
        guard !inAttachDrag, attachDragStart == nil else { return }
        relocate(to: Self.targetScreen(for: choice))
    }

    /// Recomputes the resting geometry for `screen` and moves the panel to its top centre.
    /// Always re-applied, even on the same screen: its menu bar or resolution may have changed.
    private func relocate(to screen: NSScreen) {
        guard let panel = window as? IslandPanel else { return }
        let geometry = Self.screenGeometry(for: screen)
        notchW = geometry.width
        notchH = geometry.height
        hasNotch = geometry.hasNotch
        panel.notchWidth  = notchW
        panel.notchHeight = notchH
        AppState.shared.notchWidth  = notchW
        AppState.shared.notchHeight = notchH
        AppState.shared.hasNotch = hasNotch
        Self.currentScreen = screen

        let sf = screen.frame
        let size = panel.frame.size
        panel.setFrame(NSRect(x: sf.midX - size.width/2, y: sf.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        // notchWidth/hasNotch are not @Published: tell the views to resize the island.
        NotificationCenter.default.post(name: .islandScreenChanged, object: nil)
        state.objectWillChange.send()
    }

    /// Follow-the-mouse mode: hop to the cursor's screen while the island is not open,
    /// so an approval or a chat never jumps away mid-click.
    private func followMouseIfNeeded(_ mouse: NSPoint) {
        guard state.islandDisplay == .followMouse,
              state.mode != .expanded, !inAttachDrag, attachDragStart == nil else { return }
        if let current = Self.currentScreen, current.frame.contains(mouse) { return }
        guard let target = NSScreen.screens.first(where: { $0.frame.contains(mouse) }),
              target != Self.currentScreen else { return }
        relocate(to: target)
    }

    // MARK: - FSM wiring

    private func wireFSM() {
        // Apply the persisted preference immediately and keep live edits in sync.
        autoCloseSubscription = state.$autoCloseInterval.sink { [weak self] delay in
            self?.fsm.homeToPetitDelay = delay
        }
        openOnHoverSubscription = state.$openOnHover.sink { [weak self] on in
            self?.fsm.openOnHover = on
        }

        fsm.onTransition = { [weak self] from, to in
            guard let self else { return }
            switch to {
            case .hidden:
                self.setMode(.hidden)

            case .petit:
                if from == .hidden {
                } else if from == .hidden {
                    if self.silentNextReveal {
                        self.silentNextReveal = false
                    } else {
                        SoundEngine.shared.play("peek")
                    }
                }
                // setMode BEFORE changing view: onChange(of: state.view) guards on .expanded,
                // so setting view while already compact won't trigger a spurious open animation.
                self.setMode(.compact)
                // Start 60s hide timer if mouse is not currently over the island
                if !self.wasInIsland { self.fsm.mouseLeft() }

            case .home:
                self.expand(to: self.defaultView())
                // Start collapse timer if mouse not currently hovering
                if !self.wasInIsland {
                    self.fsm.mouseLeft()
                }

            }
        }

        // An approval stays open until I click.
        fsm.isHeldOpen = { AppState.shared.pendingApproval != nil }
        fsm.keepsCompact = { AppState.shared.orcaKeepsIslandVisible }
    }

    // MARK: - Polling loop
    // 60 Hz while the island is on screen, a drag is under way or the
    // pointer is near the island; 8 Hz (with timer tolerance) while it is hidden and the pointer
    // is elsewhere, so a hidden island costs next to nothing (CLAUDE.md: 0 % CPU when hidden).

    private static let fastPoll: TimeInterval = 1.0 / 60.0
    private static let nearPoll: TimeInterval = 1.0 / 20.0
    private static let idlePoll: TimeInterval = 1.0 / 8.0
    private var pollInterval: TimeInterval = 0

    /// Screen asleep or locked: nothing to hover, the poll stops entirely.
    private var screenOff = false

    private func startPolling(interval: TimeInterval = IslandWindowController.fastPoll) {
        frameTimer?.invalidate()
        frameTimer = nil
        pollInterval = interval
        guard !screenOff else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop: already on the main actor, no Task per tick.
            MainActor.assumeIsolated { self?.pollFrame() }
        }
        // A few ms of slack lets macOS group our wakeups with others; hover is unaffected.
        timer.tolerance = interval == Self.idlePoll ? 0.04 : interval == Self.nearPoll ? 0.01 : 0.004
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    /// Picks the polling rate for the next ticks (see startPolling).
    /// Three rates for a hidden or resting island: 60 Hz close to the island itself, 20 Hz in the
    /// wide band around the panel (a pointer flicked up still reaches the close zone
    /// within one tick), 8 Hz elsewhere. Before, the whole band ran at 60 Hz, so a hidden
    /// island polled at 60 Hz most of the time.
    private func adjustPollRate(mouse: NSPoint, panelFrame: NSRect, islandRect: NSRect) {
        let island = islandRect.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        let nearIsland = island.insetBy(dx: -200, dy: -160).contains(mouse)
        let inBand = panelFrame.insetBy(dx: -120, dy: -120).contains(mouse)
        // The resting (compact) island is treated like the hidden one: the mascot reads the
        // pointer itself every frame, so only hover and clicks need this poll, and those
        // only near the island. 60 Hz while open, dragging or close to it.
        let busy = state.mode == .expanded || inAttachDrag || attachDragStart != nil
            || fsm.state == .home || nearIsland
        let wanted = busy ? Self.fastPoll : inBand ? Self.nearPoll : Self.idlePoll
        if wanted != pollInterval { startPolling(interval: wanted) }
    }

    private func pollFrame() {
        guard let panel = window as? IslandPanel else { return }

        let mouse = NSEvent.mouseLocation
        followMouseIfNeeded(mouse)

        // Convert mouse to panel-local coords (macOS: origin bottom-left)
        let pf = panel.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)

        // Island rect in panel coords
        let islandRect = panel.currentIslandFrame(nw: notchW, nh: notchH)
        // On a screen without a notch, the resting bar must not intercept clicks
        // in the app window immediately below the menu bar.
        let hoverRect = !hasNotch && state.mode != .expanded
            ? islandRect : islandRect.insetBy(dx: -6, dy: -6)
        let inIsland = hoverRect.contains(local)

        // Toggle click-through
        let shouldAcceptMouse = inIsland || inAttachDrag || attachDragStart != nil
        if panel.ignoresMouseEvents == shouldAcceptMouse {
            panel.ignoresMouseEvents = !shouldAcceptMouse
            if shouldAcceptMouse, let cv = panel.contentView {
                panel.invalidateCursorRects(for: cv)
            }
        }

        // Mouse in desktop space (y-down from the menu-bar screen top) for Bot look-at
        let newPos = DesktopSpace.topDown(mouse, desktopTop: Self.desktopTop)
        let cur = AppState.shared.mousePosition
        if abs(newPos.x - cur.x) > 1 || abs(newPos.y - cur.y) > 1 {
            AppState.shared.mousePosition = newPos
        }

        // AppState can hide the island by itself (last task ended): keep the FSM in step.
        if state.mode == .hidden && fsm.state == .petit { fsm.hiddenExternally() }

        // Feed FSM hover enter/leave
        // Update the hit test before feeding the FSM: its transitions read wasInIsland
        // (a hover-opened island must not start its close timer while the pointer is on it).
        let previouslyInIsland = wasInIsland
        wasInIsland = inIsland
        if inIsland && !previouslyInIsland {
            guard !inAttachDrag else { return }
            fsm.mouseEntered()
        }
        if !inIsland && previouslyInIsland {
            fsm.mouseLeft()
        }

        // Bot-head hover (love emote)
        let overBot = state.mode == .expanded && state.stateOverride == nil && isBotHit(local)
        if overBot && !botHovering { botHoverIn(mousePos: NSEvent.mouseLocation) }
        if !overBot && botHovering { botHoverOut() }
        botHovering = overBot
        if botHovering {
            let m = NSEvent.mouseLocation
            let dist = hypot(m.x - botHoverStartPos.x, m.y - botHoverStartPos.y)
            if dist > 40 {
                botHoverStartPos = m
                botHoverTimer?.cancel()
                scheduleLoveTimer()
            }
        }

        // Ghost mascot follows cursor + window highlight during drag (60 Hz, no throttle)
        if inAttachDrag {
            updateDragGhost()
            updateWindowHighlight()
        }

        adjustPollRate(mouse: mouse, panelFrame: pf, islandRect: islandRect)
    }

    /// Screen asleep or locked: stop polling; back at the idle rate when it wakes.
    private func observeScreenForPolling() {
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pausePollingForScreenOff() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumePollingAfterScreenOff() }
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.pausePollingForScreenOff() }
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumePollingAfterScreenOff() }
        }
    }

    private func pausePollingForScreenOff() {
        screenOff = true
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func resumePollingAfterScreenOff() {
        guard screenOff else { return }
        screenOff = false
        startPolling(interval: Self.idlePoll)
    }

    private var lastMouse: CGPoint = .zero
    private var lastHighlightMouse: CGPoint = .zero
    private var lastHighlightScan: CFTimeInterval = 0

    // MARK: - Bot-head hover (love emote — mirrors prototype botHover())

    private func botHoverIn(mousePos: CGPoint) {
        guard state.mode == .expanded, state.stateOverride == nil else { return }
        guard CACurrentMediaTime() - lastLoveTime > 6 else { return }
        botHoverStartPos = mousePos
        NotificationCenter.default.post(name: .botBlink, object: nil)
        SoundEngine.shared.play("hover")
        scheduleLoveTimer()
    }

    private func botHoverOut() {
        botHoverTimer?.cancel()
    }

    private func scheduleLoveTimer() {
        botHoverTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.botHovering, self.state.stateOverride == nil else { return }
            guard CACurrentMediaTime() - self.lastLoveTime > 6 else { return }
            self.lastLoveTime = CACurrentMediaTime()
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.love)
            SoundEngine.shared.play("love")
        }
        botHoverTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9, execute: item)
    }

    private func scheduleHover(after delay: TimeInterval, action: @escaping () -> Void) {
        hoverTimer?.cancel()
        let item = DispatchWorkItem(block: action)
        hoverTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Mode transitions

    private func modeLevel(_ m: IslandMode) -> Int {
        switch m { case .hidden: return 0; case .compact: return 1; case .expanded: return 2 }
    }

    func setMode(_ mode: IslandMode) {
        let prev = state.mode
        guard mode != prev else { return }
        let shrinking = modeLevel(mode) < modeLevel(prev)
        let anim: Animation = shrinking
            ? .timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
            : .spring(response: 0.5, dampingFraction: 0.72)
        withAnimation(anim) { state.mode = mode }
        if mode == .expanded { SoundEngine.shared.play("open") }
        if prev == .expanded {
            SoundEngine.shared.play("close")
            if fsm.isHeldOpen?() != true { state.isPinned = false }
            HookServer.shared.restoreAlertFocus()
        }
    }

    func expand(to view: IslandView) {
        state.view = view
        if state.mode == .expanded {
            // Already expanded — just switch view
        } else {
            setMode(.expanded)
        }
        state.lastActivity = .now
    }

    func collapse(allowPendingApproval: Bool = false) {
        let keepsApprovalPending = allowPendingApproval && state.pendingApproval != nil
        guard fsm.isHeldOpen?() != true || keepsApprovalPending else { return }
        if !keepsApprovalPending { state.isPinned = false }
        finishedPinTimer?.cancel()
        // Keep the FSM in step with what is on screen (home → petit now).
        fsm.collapse()
        setMode(.compact)
        window?.resignKey()
    }

    // MARK: - Global hot keys (Carbon)

    private func startHotKeys() {
        HotKeyCenter.shared.start { [weak self] action in
            self?.handleHotKey(action)
        }
    }

    func handleHotKey(_ action: ShortcutAction) {
        switch action {
        case .toggleIsland:
            if state.mode == .expanded {
                collapse(allowPendingApproval: true)
            } else {
                islandPanel.makeKey()
                fsm.openedExternally()
                expand(to: defaultView())
            }

        case .openChat:
            islandPanel.makeKey()
            expand(to: .prompt)

        case .goToAlert:
            if state.pendingApproval != nil {
                islandPanel.makeKey()
                fsm.openedExternally()
                expand(to: .approval)
            } else if state.pendingQuestion != nil {
                islandPanel.makeKey()
                expand(to: .question)
            } else {
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
                SoundEngine.shared.play("error")
            }

        case .jumpToTerminal:
            performJumpToTerminal()

        case .attachFrontWindow:
            performAttachFrontWindow()

        case .nextPill:
            cyclePill(by: +1)

        case .prevPill:
            cyclePill(by: -1)

        case .muteToggle:
            state.soundEnabled.toggle()
            if state.soundEnabled { SoundEngine.shared.play("tick") }
            NotificationCenter.default.post(
                name: .triggerEmote,
                object: state.soundEnabled ? BotEmote.happy : BotEmote.annoyed)

        }
    }

    // MARK: - Island-local shortcuts

    private func startLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.islandPanel.isKeyWindow else { return event }
            return self.handleIslandKey(event) ? nil : event
        }
    }

    @discardableResult
    private func handleIslandKey(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let cmd = raw == .command

        // ⌘→ — next pill
        if cmd && event.keyCode == 124 { cyclePill(by: +1); return true }
        // ⌘← — previous pill
        if cmd && event.keyCode == 123 { cyclePill(by: -1); return true }
        // ⌘↓ — navigate list down
        if cmd && event.keyCode == 125 { navigateCard(by: +1); return true }
        // ⌘↑ — navigate list up
        if cmd && event.keyCode == 126 { navigateCard(by: -1); return true }
        // ⌘O — open selected card item
        if cmd && event.keyCode == 31  { openCardSelection(); return true }
        // ⌘E — toggle diff
        if cmd && event.keyCode == 14 && state.view == .overview {
            NotificationCenter.default.post(name: .islandToggleDiff, object: nil)
            return true
        }
        // ⌘↩ — send chat message
        if cmd && event.keyCode == 36 && state.view == .prompt {
            NotificationCenter.default.post(name: .islandSendMessage, object: nil)
            return true
        }
        // ⌘K — new conversation
        if cmd && event.keyCode == 40 && state.view == .prompt {
            NotificationCenter.default.post(name: .islandNewConversation, object: nil)
            return true
        }
        // ⌘, — open Settings
        if cmd && event.keyCode == 43 {
            NotificationCenter.default.post(name: .openFullSettings, object: nil)
            return true
        }
        // ⌘P — pin / unpin
        if cmd && event.keyCode == 35 {
            state.isPinned.toggle()
            return true
        }
        // ⌘1–⌘9 — switch to pill by number
        let digitCodes: [UInt16: Int] = [18:1,19:2,20:3,21:4,23:5,22:6,26:7,28:8,25:9]
        if cmd, let n = digitCodes[event.keyCode] {
            switchToPill(number: n); return true
        }
        // ⎋ Escape — focused views (.onExitCommand) have first crack; fall back to collapse
        if event.keyCode == 53 && raw.isEmpty {
            let consumed = NSApp.sendAction(Selector(("cancelOperation:")), to: nil, from: nil)
            let canCollapse = !state.isPinned || state.pendingApproval != nil
            if !consumed && state.mode == .expanded && canCollapse {
                collapse(allowPendingApproval: true)
            }
            return true
        }
        return false
    }

    // MARK: - Pill cycling helpers

    private func cyclePill(by delta: Int) {
        guard !state.tasks.isEmpty else { return }
        let ids = state.tasks.map { $0.id }
        let cur = ids.firstIndex(of: state.focusId ?? "") ?? 0
        state.setFocus(ids[(cur + delta + ids.count) % ids.count])
        state.cardSelection = nil
        expand(to: .overview)
    }

    private func switchToPill(number: Int) {
        guard number >= 1, number <= state.tasks.count else { return }
        state.setFocus(state.tasks[number - 1].id)
        state.cardSelection = nil
        expand(to: .overview)
    }

    private func navigateCard(by delta: Int) {
        guard state.cardItemCount > 0 else { return }
        state.cardSelection = ShortcutLogic.navigate(
            selection: state.cardSelection, delta: delta, itemCount: state.cardItemCount)
    }

    private func openCardSelection() {
        guard state.cardSelection != nil else { return }
        NotificationCenter.default.post(name: .islandActivateCardSelection, object: nil)
    }

    // MARK: - Terminal jump

    private func performJumpToTerminal() {
        guard state.focusTask != nil else {
            SoundEngine.shared.play("error")
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
            return
        }
        if !TerminalTarget.activate(sessionBundleId: state.focusTask?.sessionBundleId) {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
        collapse(allowPendingApproval: true)
    }

    private func performAttachFrontWindow() {
        guard let app = state.lastExternalApp else {
            SoundEngine.shared.play("error"); return
        }
        guard let ctx = WindowContextCapture.captureActive(from: app) else {
            SoundEngine.shared.play("error"); return
        }
        state.promptContext = ctx
        SoundEngine.shared.play("approve")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        islandPanel.makeKey()
        expand(to: .prompt)
    }

    // MARK: - Keyboard (Escape closes)

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Every key typed anywhere lands here: only Escape goes further (no Task per key).
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                guard let self = self else { return }
                // Escape typed in another app (Claude Code's own interrupt, an editor…)
                // never folds a pending approval away: only Escape in the notch does.
                if self.state.mode == .expanded && !self.state.isPinned {
                    self.collapse()
                }
            }
        }

        // Hook server expand requests (alerts only)
        NotificationCenter.default.addObserver(forName: .hookExpand, object: nil, queue: .main) { [weak self] note in
            guard let self, let view = note.object as? IslandView else { return }
            self.fsm.openedExternally()
            self.expand(to: view)
        }

        // Hook server compact reveal (non-alert work events: session start, tool use, etc.)
        NotificationCenter.default.addObserver(forName: .hookReveal, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.fsm.reveal()
        }

        // Collapse requests from views (OK button, etc.)
        NotificationCenter.default.addObserver(forName: .islandCollapse, object: nil, queue: .main) { [weak self] _ in
            self?.collapse()
        }

        // Eye tracking at the mouse's own rate: The mascot's look target follows every mouse move
        // instead of the island poll (8 to 20 Hz away from the island, which made the head step).
        // Nothing runs while the mouse is still, and a hidden island skips the work.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { IslandWindowController.trackMouseLook() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            MainActor.assumeIsolated { IslandWindowController.trackMouseLook() }
            return event
        }

        // Window attach drag.
        // Uses MainActor.assumeIsolated (synchronous) to avoid race with pollFrame().
        // Global mouseUp is the reliable fallback when cursor is outside our panel frame.
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard self.wasInIsland else { return }
                self.fsm.userInteracted()
                self.pendingIslandClick = true
                self.hoverTimer?.cancel()
                self.botHoverTimer?.cancel()
                self.botHovering = false
                // Drag only starts when clicking directly on the mascot
                guard self.isBotHit(event.locationInWindow) else { return }
                self.attachDragStart = NSEvent.mouseLocation
                // Post slap only when expanded
                guard self.state.mode == .expanded else { return }
                NotificationCenter.default.post(name: .triggerSlap, object: nil)
            }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard let start = self.attachDragStart, !self.inAttachDrag else { return }
                let m = NSEvent.mouseLocation
                guard hypot(m.x - start.x, m.y - start.y) > 3 else { return }
                self.inAttachDrag = true
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.love)
                self.showDragGhost()
            }
            return event
        }

        // mouseUp — local (cursor still in panel) + global (cursor moved outside panel frame)
        let finishDrag: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.inAttachDrag else { return }
                let mouse = NSEvent.mouseLocation
                self.inAttachDrag = false
                self.attachDragStart = nil
                self.state.stateOverride = nil

                let windowCtx = self.windowContextAtPoint(mouse)

                if let ctx = windowCtx {
                    // Drop on a window → attach context as before
                    self.hideDragGhost()
                    self.state.promptContext = ctx
                    SoundEngine.shared.play("approve")
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
                    self.expand(to: .prompt)
                } else {
                    // Dropped nowhere useful: the mascot returns to the notch
                    self.hideDragGhost()
                }
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let hadPendingClick = self.pendingIslandClick
                let wasDragging     = self.inAttachDrag
                self.pendingIslandClick = false
                if wasDragging {
                    finishDrag()
                } else {
                    self.attachDragStart = nil
                    if hadPendingClick && self.state.mode != .expanded {
                        if self.fsm.state == .home {
                            // FSM already thinks it's open (e.g. the view folded it): just reopen.
                            self.expand(to: self.defaultView())
                        } else {
                            self.fsm.click()   // FSM petit/hidden→home; onTransition calls expand(to:)
                        }
                    }
                }
            }
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
            finishDrag()
        }

        // Track last external app for window context capture
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != ourBundle {
                self.state.lastExternalApp = app
            }
        }
    }

    // MARK: - Drag ghost window (the mascot follows the cursor during drag)

    private func showDragGhost() {
        guard dragGhostPanel == nil else { return }
        // Same size as compact bot: diameter=20 → canvasSize≈33, scale 2× for grab comfort
        let canvasSize: CGFloat = 40 / 0.6      // ~67
        dragGhostSize = canvasSize

        let mouse = NSEvent.mouseLocation
        let s = dragGhostSize
        ghostCurrentOrigin = NSPoint(x: mouse.x - s/2, y: mouse.y - s/2)

        let panel = NSPanel(
            contentRect: NSRect(x: ghostCurrentOrigin.x, y: ghostCurrentOrigin.y, width: s, height: s),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true

        let hosting = NSHostingView(
            rootView: GhostBotView(canvasSize: canvasSize)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: s, height: s)
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFront(nil)
        dragGhostPanel = panel
        AppState.shared.isDraggingBot = true

        // Fade + scale-in handled by GhostBotView SwiftUI animation;
        // also fade in the window itself for extra smoothness
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hideDragGhost() {
        dragGhostPanel?.close()
        dragGhostPanel = nil
        highlightPanel?.close()
        highlightPanel = nil
        highlightWindowPid = 0
        AppState.shared.isDraggingBot = false
    }

    private func updateDragGhost() {
        guard let panel = dragGhostPanel else { return }
        let s = dragGhostSize
        let mouse = NSEvent.mouseLocation
        // Direct follow — bot is "held", no trailing lag
        ghostCurrentOrigin = NSPoint(x: mouse.x - s/2, y: mouse.y - s/2)
        panel.setFrameOrigin(ghostCurrentOrigin)
    }

    // MARK: - Window highlight overlay (white border on target window during drag)

    private func updateWindowHighlight() {
        let mouse = NSEvent.mouseLocation
        // Listing every window is costly: skip while the pointer stays put (a window
        // moving under a still pointer is caught within a quarter second).
        let now = CACurrentMediaTime()
        if hypot(mouse.x - lastHighlightMouse.x, mouse.y - lastHighlightMouse.y) < 2,
           now - lastHighlightScan < 0.25 { return }
        lastHighlightMouse = mouse
        lastHighlightScan = now
        guard let (appKitBounds, pid) = windowBoundsAtScreenPoint(mouse) else {
            // Fade out + close if no window under cursor
            if let old = highlightPanel {
                let captured = old
                highlightPanel = nil
                highlightWindowPid = 0
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.12
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    captured.animator().alphaValue = 0
                }, completionHandler: { captured.close() })
            }
            return
        }

        if pid == highlightWindowPid, let existing = highlightPanel {
            // Same window — just track position (windows rarely move, instant is fine)
            existing.setFrame(appKitBounds, display: false)
        } else {
            // New window — close old immediately, fade-in new
            highlightPanel?.close()
            highlightPanel = nil
            highlightWindowPid = pid

            let panel = NSPanel(
                contentRect: appKitBounds,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel.ignoresMouseEvents = true

            let hosting = NSHostingView(rootView:
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.75), lineWidth: 3)
                    .shadow(color: Color.white.opacity(0.5), radius: 16)
                    .padding(2)
                    .ignoresSafeArea()
            )
            hosting.frame = CGRect(origin: .zero, size: appKitBounds.size)
            hosting.autoresizingMask = [.width, .height]
            panel.contentView = hosting
            panel.alphaValue = 0
            panel.orderFront(nil)
            highlightPanel = panel

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func windowBoundsAtScreenPoint(_ screenPoint: NSPoint) -> (CGRect, pid_t)? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        let screenMaxY = screen.frame.maxY
        let cgPoint = CGPoint(x: screenPoint.x, y: screenMaxY - screenPoint.y)

        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        for info in list {
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            guard CGRect(x: x, y: y, width: w, height: h).contains(cgPoint) else { continue }
            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != ourBundle,
                  app.activationPolicy == .regular else { continue }
            // CG → AppKit: flip Y
            return (CGRect(x: x, y: screenMaxY - y - h, width: w, height: h), pid)
        }
        return nil
    }

    // MARK: - Window context at screen point (for drag-attach)

    func windowContextAtPoint(_ screenPoint: NSPoint) -> PromptContext? {
        let screen = window?.screen ?? NSScreen.main
        // CGWindowList uses top-left origin; NSEvent.mouseLocation uses bottom-left
        let screenMaxY = screen?.frame.maxY ?? NSScreen.main!.frame.maxY
        let cgPoint = CGPoint(x: screenPoint.x, y: screenMaxY - screenPoint.y)

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let ourBundle = Bundle.main.bundleIdentifier ?? ""

        for info in windowList {
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            guard CGRect(x: x, y: y, width: w, height: h).contains(cgPoint) else { continue }

            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != ourBundle,
                  app.activationPolicy == .regular else { continue }

            return WindowContextCapture.captureActive(from: app)
        }
        return nil
    }

    // MARK: - Coordinate conversion: window (AppKit, y-up) → island coords (y-down, 0,0 = island top-left)

    func windowToIsland(_ loc: CGPoint) -> CGPoint {
        let panelH = window?.frame.height ?? 320
        let panelW = window?.frame.width  ?? 720
        let islandLeft = (panelW - IslandConst.expandedWidth) / 2
        // Island is glued to panel top; its bottom in AppKit = panelH - 176
        return CGPoint(
            x: loc.x - islandLeft,
            y: panelH - loc.y                // AppKit y is from bottom; island y from top
        )
    }

    // MARK: - Helpers

    func defaultView() -> IslandView {
        if state.pendingApproval != nil { return .approval }
        return .overview   // the Orca workspace list; `.empty` renders the same
    }

    func baseMode() -> IslandMode {
        guard state.isPresent else { return .hidden }
        return state.tasks.isEmpty && !state.orcaKeepsIslandVisible ? .hidden : .compact
    }

    // MARK: - Activity reset (call on any user interaction in island)

    func resetActivity() {
        state.lastActivity = .now
    }

    // MARK: - Finished task pin (5.2s)

    func pinForFinished(taskId: String) {
        state.isPinned = true
        finishedPinTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.removeTask(id: taskId)
            self.state.isPinned = false
            self.collapse()
        }
        finishedPinTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2, execute: item)
    }

    // MARK: - Bot hit test (for slap trigger)

    private func isBotHit(_ windowPoint: CGPoint) -> Bool {
        let s = AppState.shared
        let panelH = window?.frame.height ?? 320
        let panelW = window?.frame.width  ?? 720
        let (islandW, fixedH) = islandSize(mode: s.mode, view: s.view,
                                            nw: notchW, nh: notchH)
        // Chat view resizes dynamically — must match IslandContainer.chatPromptHeight
        let islandH: CGFloat
        if s.mode == .expanded && s.view == .prompt {
            let base: CGFloat = 240
            let perMsg: CGFloat = 40
            islandH = min(300, base + CGFloat(s.chatHistory.count) * perMsg)
        } else {
            islandH = fixedH
        }
        let islandMinX = (panelW - islandW) / 2
        let (cx, cy, diameter, _) = botPosition(mode: s.mode, view: s.view,
                                                  islandW: islandW, islandH: islandH, hasNotch: s.hasNotch)
        let radius = (diameter / 0.6) / 2
        // botPosition cy is from island TOP; panel AppKit coords have y=0 at bottom
        // island top in AppKit coords = panelH (island glued to top of panel/screen)
        let botX = islandMinX + cx
        let botY = panelH - cy
        let dx = windowPoint.x - botX
        let dy = windowPoint.y - botY
        return dx*dx + dy*dy <= radius * radius
    }

    // MARK: - Notch detection (static)

    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    /// Top of the menu-bar screen in AppKit coordinates: origin of `DesktopSpace`.
    static var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// The mascot's look target from the current mouse position (see the mouse-moved monitors).
    static func trackMouseLook() {
        let app = AppState.shared
        guard app.mode != .hidden else { return }
        let pos = DesktopSpace.topDown(NSEvent.mouseLocation, desktopTop: desktopTop)
        let cur = app.mousePosition
        if abs(pos.x - cur.x) > 1 || abs(pos.y - cur.y) > 1 { app.mousePosition = pos }
    }

    /// Screen the island currently sits on.
    private(set) static var currentScreen: NSScreen?

    static func islandScreen() -> NSScreen {
        if let s = currentScreen, NSScreen.screens.contains(s) { return s }
        return notchScreen() ?? NSScreen.main!
    }

    /// Screen matching the user's choice; falls back to the notch screen, then the main one.
    static func targetScreen(for choice: IslandDisplayChoice) -> NSScreen {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let candidates = screens.map {
            IslandDisplayCandidate(uuid: displayUUID($0), hasNotch: $0.safeAreaInsets.top > 0,
                                   containsMouse: $0.frame.contains(mouse))
        }
        if let i = IslandDisplayResolver.index(for: choice, in: candidates) { return screens[i] }
        return notchScreen() ?? NSScreen.main ?? screens[0]
    }

    /// Stable display UUID (the NSScreenNumber can change after a reboot or a replug).
    static func displayUUID(_ screen: NSScreen) -> String? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screenGeometry(for screen: NSScreen) -> IslandScreenGeometry {
        let visibleMenuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // visibleFrame includes the menu bar only while it is visible. Keep a
        // small resting bar when menus auto-hide or the app is in full screen.
        let menuBarHeight = visibleMenuBarHeight > 0
            ? visibleMenuBarHeight : NSStatusBar.system.thickness
        return IslandScreenGeometry(
            screenWidth: screen.frame.width, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            menuBarHeight: menuBarHeight
        )
    }

    nonisolated func cleanup() {
        // Called explicitly before release if needed
    }
}

// MARK: - IslandPanel

final class IslandPanel: NSPanel {
    var notchWidth:  CGFloat = IslandConst.notchWidth
    var notchHeight: CGFloat = IslandConst.notchHeight

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow panel to sit in the menu bar / notch area — don't let macOS push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    func currentIslandFrame(nw: CGFloat, nh: CGFloat) -> CGRect {
        let s = AppState.shared
        let (w, fixedH) = islandSize(mode: s.mode, view: s.view,
                                      nw: nw, nh: nh)
        let h: CGFloat
        if s.mode == .expanded && s.view == .prompt {
            let base: CGFloat = 240
            let perMsg: CGFloat = 40
            h = min(300, base + CGFloat(s.chatHistory.count) * perMsg)
        } else {
            h = fixedH
        }
        return CGRect(x: (frame.width - w) / 2, y: frame.height - h, width: w, height: h)
    }
}

// MARK: - Ghost bot view (animated scale-in on appear)

struct GhostBotView: View {
    let canvasSize: CGFloat
    @State private var scale: CGFloat = 0.35

    var body: some View {
        BotCanvasView(state: AppState.shared)
            .frame(width: canvasSize, height: canvasSize)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    scale = 1.0
                }
            }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let triggerEmote     = Notification.Name("orcaNotch.triggerEmote")
    static let triggerSlap      = Notification.Name("orcaNotch.triggerSlap")
    static let botBlink         = Notification.Name("orcaNotch.botBlink")
    static let islandAction     = Notification.Name("orcaNotch.islandAction")
    static let islandCollapse      = Notification.Name("orcaNotch.islandCollapse")
    static let islandSendMessage   = Notification.Name("orcaNotch.islandSendMessage")
    static let islandNewConversation = Notification.Name("orcaNotch.islandNewConversation")
    static let islandToggleDiff           = Notification.Name("orcaNotch.islandToggleDiff")
    static let islandActivateCardSelection = Notification.Name("orcaNotch.islandActivateCardSelection")
    static let openFullSettings    = Notification.Name("orcaNotch.openFullSettings")
    static let hookReveal       = Notification.Name("orcaNotch.hookReveal")
    // Island moved to another screen (resting size may differ: notch vs bar)
    static let islandScreenChanged = Notification.Name("orcaNotch.islandScreenChanged")
}

// MARK: - islandSize (takes real notch dimensions)

func islandSize(mode: IslandMode, view: IslandView,
                nw: CGFloat = IslandConst.notchWidth,
                nh: CGFloat = IslandConst.notchHeight) -> (CGFloat, CGFloat) {
    switch mode {
    case .hidden:   return (nw, nh)
    case .compact:  return (nw + 160, nh)
    case .expanded:
        let layout = IslandConst.viewLayouts[view]!
        if view == .question, let h = QuestionLayout.height {
            return (IslandConst.expandedWidth, h)
        }
        return (IslandConst.expandedWidth, layout.height)
    }
}
