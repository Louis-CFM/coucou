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

    // Confused recovery timer (set by handleDizzy)
    private var confusedRecoveryTimer: DispatchWorkItem?

    // Voice result auto-dismiss timer
    #if !APPSTORE
    private var voiceResultWork: DispatchWorkItem?
    /// True only while Coucou listens for the answer to a question it asked.
    private var isInConversation = false
    /// Context (last action, on-device model session) is kept a little after a turn so
    /// "OK Coucou, et Stripe aussi" still works; this resets it.
    private var voiceContextExpiry: DispatchWorkItem?
    private var conversationContext = ConversationContext()
    private var consecutiveFailures = 0
    private var hasSpokenPasCompris = false
    #endif

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
        dropView.onDragEntered = { [weak self] loc in
            Task { @MainActor in
                let iLoc = self?.windowToIsland(loc) ?? CGPoint(x: 320, y: 88)
                AppState.shared.fileDragOver = true
                // enterZone sets isActive=true BEFORE hookExpand triggers re-render,
                // so IslandContainer sees isActive=true when state.view becomes .upload.
                UploadSequenceEngine.shared.enterZone(x: iLoc.x, y: iLoc.y)
                NotificationCenter.default.post(name: .hookExpand, object: IslandView.upload)
                NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(1))
            }
        }
        dropView.onDragUpdated = { [weak self] loc in
            Task { @MainActor in
                let iLoc = self?.windowToIsland(loc) ?? CGPoint(x: 320, y: 88)
                UploadSequenceEngine.shared.updateCursor(x: iLoc.x, y: iLoc.y)
            }
        }
        dropView.onDragExited = {
            Task { @MainActor in
                AppState.shared.fileDragOver = false
                // Do NOT collapse — drag session still active; island stays open.
                NotificationCenter.default.post(name: .botMorphTo, object: CGFloat(0))
                UploadSequenceEngine.shared.exitZone()
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
        startKeyMonitor()
        startLocalKeyMonitor()
        startHotKeys()
        wireFSM()
        #if !APPSTORE
        VoiceActionRunner.shared.configureLive()
        #endif

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
                if from == .coucou {
                    // Fire interrupt first so canvas collapse starts before mode change
                    NotificationCenter.default.post(name: .greetingInterrupt, object: nil)
                } else if from == .hidden {
                    if self.silentNextReveal {
                        self.silentNextReveal = false
                    } else {
                        SoundEngine.shared.play("peek")
                    }
                } else if from == .listening {
                    // Voice session ended — no peek sound, just compact
                    #if !APPSTORE
                    VoiceEngine.shared.cancelListening()
                    #endif
                }
                // setMode BEFORE changing view: onChange(of: state.view) guards on .expanded,
                // so setting view while already compact won't trigger a spurious open animation.
                self.setMode(.compact)
                // Reset view when leaving .coucou or .listening so stale views
                // (e.g. .voiceResult) never linger on a collapsed island.
                if from == .coucou || from == .listening { self.state.view = self.defaultView() }
                // Start 60s hide timer if mouse is not currently over the island
                if !self.wasInIsland { self.fsm.mouseLeft() }

            case .home:
                self.expand(to: self.defaultView())
                // Start collapse timer if mouse not currently hovering
                if !self.wasInIsland {
                    self.fsm.mouseLeft()
                }

            case .coucou:
                self.expand(to: .greeting)

            case .listening:
                // Island stays compact; caption panel handles display.
                #if !APPSTORE
                let screen = IslandWindowController.islandScreen()
                VoiceCaptionManager.shared.show(on: screen, notchHeight: AppState.shared.notchHeight)
                #endif
            }
        }

        // FSM observes greetComplete notification
        NotificationCenter.default.addObserver(
            forName: .greetComplete, object: nil, queue: .main
        ) { [weak self] _ in
            self?.fsm.greetComplete()
        }

        fsm.isHeldOpen = { AppState.shared.pendingApproval != nil }

        // Voice: wake phrase detected → open listening island
        #if !APPSTORE
        NotificationCenter.default.addObserver(
            forName: .voiceWoke, object: nil, queue: .main
        ) { [weak self] note in
            let isDirect = (note.object as? String) == "direct"
            Task { @MainActor [weak self] in
                // Genuine wake phrase (not programmatic re-listen) → clear any pending question
                AppState.shared.voiceActive = true
                self?.voiceContextExpiry?.cancel()
                if !isDirect {
                    VoiceActionRunner.shared.pendingQuestion = nil
                    // The island stays compact now: the tick says "I heard OK Coucou".
                    if AppState.shared.soundEnabled { SoundEngine.shared.play("tick") }
                }
                self?.fsm.voiceWoke()
            }
        }
        // Voice: command session ended — run intent, show result for 2 s, then collapse.
        NotificationCenter.default.addObserver(
            forName: .voiceFinished, object: nil, queue: .main
        ) { [weak self] note in
            let transcript = note.object as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                if transcript.isEmpty {
                    if VoiceActionRunner.shared.pendingQuestion != nil {
                        // Re-listen timed out with no answer → show cancellation message
                        let result = await VoiceActionRunner.shared.handleAnswer(
                            "", availablePills: PillCatalog.available)
                        AppState.shared.voiceResult = result
                        self.expand(to: .voiceResult)
                        self.scheduleVoiceDismiss(delay: 1.5)
                    } else if self.isInConversation {
                        // No answer to Coucou's question: stop listening.
                        self.closeVoiceTurn()
                    } else {
                        self.fsm.voiceFinished()
                    }
                } else {
                    await self.handleVoiceCommand(transcript)
                }
            }
        }
        #endif
    }

    // MARK: - Polling loop
    // 60 Hz while the island is on screen, Mochi is on the desktop, a drag is under way or the
    // pointer is near the island; 8 Hz (with timer tolerance) while it is hidden and the pointer
    // is elsewhere, so a hidden island costs next to nothing (CLAUDE.md: 0 % CPU when hidden).

    private static let fastPoll: TimeInterval = 1.0 / 60.0
    private static let idlePoll: TimeInterval = 1.0 / 8.0
    private var pollInterval: TimeInterval = 0

    private func startPolling(interval: TimeInterval = IslandWindowController.fastPoll) {
        frameTimer?.invalidate()
        pollInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop: already on the main actor, no Task per tick.
            MainActor.assumeIsolated { self?.pollFrame() }
        }
        timer.tolerance = interval == Self.idlePoll ? 0.04 : 0
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    /// Picks the polling rate for the next ticks (see startPolling).
    private func adjustPollRate(mouse: NSPoint, panelFrame: NSRect) {
        let nearIsland = panelFrame.insetBy(dx: -120, dy: -120).contains(mouse)
        let busy = state.mode != .hidden || state.mochiOnDesktop || inAttachDrag || attachDragStart != nil
            || fsm.state != .hidden || nearIsland
        let wanted = busy ? Self.fastPoll : Self.idlePoll
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
            // If in coucou: tell greeting to stay open (tc → infinity)
            if fsm.state == .coucou {
                NotificationCenter.default.post(name: .greetingHover, object: nil)
            }
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

        // Ghost Mochi follows cursor + window highlight during drag (60 Hz, no throttle)
        if inAttachDrag {
            updateDragGhost()
            updateWindowHighlight()
        }

        adjustPollRate(mouse: mouse, panelFrame: pf)
    }

    private var lastMouse: CGPoint = .zero

    // MARK: - Bot-head hover (love emote — mirrors prototype botHover())

    private func botHoverIn(mousePos: CGPoint) {
        guard state.mode == .expanded, state.stateOverride == nil else { return }
        guard CACurrentMediaTime() - lastLoveTime > 6 else { return }
        botHoverStartPos = mousePos
        NotificationCenter.default.post(name: .botBlink, object: nil)
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1.08))
        SoundEngine.shared.play("hover")
        scheduleLoveTimer()
    }

    private func botHoverOut() {
        botHoverTimer?.cancel()
        NotificationCenter.default.post(name: .botSetTgEs, object: CGFloat(1))
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
        #if !APPSTORE
        VoiceSpeaker.shared.stop()
        if isInConversation || AppState.shared.voiceActive {
            // Closing the island ends the voice exchange (speech was just cut, so its
            // "finished" callback will not come): reset everything that it would have.
            isInConversation = false
            voiceResultWork?.cancel()
            voiceResultWork = nil
            VoiceEngine.shared.endConversation()
            VoiceCaptionManager.shared.hide(after: 0)
            AppState.shared.voiceResult = nil
            AppState.shared.voiceActive = false
        }
        #endif
        // Keep the FSM in step with what is on screen (home/coucou → petit now).
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
            #if !APPSTORE
            performJumpToTerminal()
            #endif

        case .attachFrontWindow:
            #if !APPSTORE
            performAttachFrontWindow()
            #endif

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

        case .desktopToggle:
            DesktopMochiController.shared.flyOutOrHome()

        case .wardrobeToggle:
            if state.mode == .expanded && state.view == .wardrobe {
                collapse()
            } else {
                islandPanel.makeKey()
                expand(to: .wardrobe)
            }

        case .talkToCoucou:
            #if !APPSTORE
            VoiceSpeaker.shared.stop()
            VoiceEngine.shared.startListeningDirectly()
            #endif
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

    #if !APPSTORE
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
    #endif

    // MARK: - Keyboard (Escape closes)

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                guard let self = self else { return }
                if event.keyCode == 53 { // Escape
                    // Escape typed in another app (Claude Code's own interrupt, an editor…)
                    // never folds a pending approval away: only Escape in the notch does.
                    if self.state.mode == .expanded && !self.state.isPinned {
                        self.collapse()
                    }
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

        // Music started playing: reveal silently (no peek sound)
        NotificationCenter.default.addObserver(forName: .musicReveal, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.silentNextReveal = true
            self.fsm.reveal()
            self.silentNextReveal = false
        }

        // Collapse requests from views (OK button, etc.)
        NotificationCenter.default.addObserver(forName: .islandCollapse, object: nil, queue: .main) { [weak self] _ in
            self?.collapse()
        }

        // Wardrobe open/close from desktop Mochi right-click (does NOT post .hookExpand)
        NotificationCenter.default.addObserver(forName: .openWardrobeFromDesktop, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.state.mode == .expanded && self.state.view == .wardrobe {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    self.state.view = .overview
                }
            } else {
                self.expand(to: .wardrobe)
            }
        }

        // .botDizzy — posted by BotEngine.slap() on 3rd hit; show confused view + recover after 3.3s
        NotificationCenter.default.addObserver(forName: .botDizzy, object: nil, queue: .main) { [weak self] _ in
            self?.handleDizzy()
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
                // Drag only starts when clicking directly on the bot head
                guard self.isBotHit(event.locationInWindow) else { return }
                // Notch Mochi is invisible when on desktop — no drag, no slap
                guard !self.state.mochiOnDesktop else { return }
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

                #if !APPSTORE
                let windowCtx = self.windowContextAtPoint(mouse)
                let inNotchZone = self.window?.frame.contains(mouse) == true

                if let ctx = windowCtx {
                    // Drop on a window → attach context as before
                    self.hideDragGhost()
                    self.state.promptContext = ctx
                    SoundEngine.shared.play("approve")
                    NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
                    self.expand(to: .prompt)
                } else if !inNotchZone {
                    // Drop outside notch zone → install Mochi on the desktop.
                    // Prevent hideDragGhost from closing the ghost panel so we can promote it.
                    let ghost = self.dragGhostPanel
                    self.dragGhostPanel = nil   // nil first so hideDragGhost skips close
                    self.hideDragGhost()        // resets isDraggingBot, closes highlight panel
                    DesktopMochiController.shared.install(ghostPanel: ghost, at: mouse)
                } else {
                    // Drop back in notch zone → Mochi returns to notch
                    self.hideDragGhost()
                }
                #else
                let inNotchZoneAS = self.window?.frame.contains(mouse) == true
                if !inNotchZoneAS {
                    let ghost = self.dragGhostPanel
                    self.dragGhostPanel = nil
                    self.hideDragGhost()
                    DesktopMochiController.shared.install(ghostPanel: ghost, at: mouse)
                } else {
                    self.hideDragGhost()
                }
                #endif
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

        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard self.wasInIsland, self.isBotHit(event.locationInWindow) else { return }
                guard !self.state.mochiOnDesktop else { return }
                if self.state.mode == .expanded && self.state.view == .wardrobe {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        self.state.view = .overview
                    }
                } else {
                    self.expand(to: .wardrobe)
                }
            }
            return event
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

    // MARK: - Drag ghost window (Mochi follows cursor during drag)

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
        return state.tasks.isEmpty ? .empty : .overview
    }

    func baseMode() -> IslandMode {
        guard state.isPresent else { return .hidden }
        return state.tasks.isEmpty ? .hidden : .compact
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

    // MARK: - Dizzy recovery (triggered by BotEngine.slap via .botDizzy)

    private func handleDizzy() {
        let prevView = state.view
        state.stateOverride = .dizzy
        expand(to: .confused)
        confusedRecoveryTimer?.cancel()
        let recovery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state.stateOverride = nil
            if self.state.view == .confused {
                let fallback = self.state.tasks.isEmpty ? IslandView.empty : .overview
                self.state.view = (prevView == .confused) ? fallback : prevView
            }
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        }
        confusedRecoveryTimer = recovery
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.3, execute: recovery)
    }

    // MARK: - Bot hit test (for slap trigger)

    private func isBotHit(_ windowPoint: CGPoint) -> Bool {
        let s = AppState.shared
        let panelH = window?.frame.height ?? 320
        let panelW = window?.frame.width  ?? 720
        let (islandW, fixedH) = islandSize(mode: s.mode, view: s.view,
                                            progress: s.uploadProgress, nw: notchW, nh: notchH)
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
                                                  islandW: islandW, islandH: islandH,
                                                  uploadProgress: s.uploadProgress, hasNotch: s.hasNotch)
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

    /// Screen the island currently sits on (Settings window, desktop Mochi flights).
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
                                      progress: s.uploadProgress, nw: nw, nh: nh)
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

// MARK: - Voice command handling

#if !APPSTORE
extension IslandWindowController {

    /// Run the intent derived from `transcript`, show VoiceResultView, then continue conversation or collapse.
    @MainActor
    func handleVoiceCommand(_ transcript: String) async {
        let t0     = Date()
        let pills  = PillCatalog.available
        let runner = VoiceActionRunner.shared

        // Propagate recognition locale so responses are in the spoken language.
        runner.commandLocale = VoiceEngine.shared.speechLocale

        // ── Conversation end phrase ────────────────────────────────────────────────
        let normTranscript = WakePhrase.normalise(transcript)
        if isInConversation && TurnEndPolicy.conversationEndPhrases.contains(normTranscript) {
            VoiceTranscriptHistory.shared.record(transcript: transcript, note: "end", origin: .end)
            closeVoiceTurn()
            return
        }

        // ── Short noise / spurious activation guard (conversation mode only) ────────
        // A transcript shorter than 2 words that isn't a pill name or known command
        // is almost certainly a false activation. Silently re-listen without feedback.
        if isInConversation {
            let normWords = normTranscript.split(separator: " ").map(String.init)
            if normWords.count < 2 {
                let isPillName = pills.contains { IntentParser.normalise($0.name) == normTranscript }
                let isKnown    = IntentParser.parse(normTranscript, pills: pills) != .unknown
                if !isPillName && !isKnown {
                    // Never log the words themselves (VOICE.md: no transcript on disk).
                    appendAppLog("nb.log", "[Voice] ignoring short spurious transcript")
                    VoiceTranscriptHistory.shared.record(transcript: transcript, note: "—", origin: .ignored)
                    closeVoiceTurn()
                    return
                }
            }
        }

        // ── Follow-up answer to a pending question ─────────────────────────────────
        if runner.pendingQuestion != nil {
            let result = await runner.handleAnswer(transcript, availablePills: pills)
            VoiceTranscriptHistory.shared.record(transcript: transcript, note: result.message, origin: .answer)
            if result.outcome != .success {
                NotificationCenter.default.post(name: .botDizzy, object: nil)
            }
            VoiceCaptionManager.shared.setUserLine(transcript)
            VoiceCaptionManager.shared.appendResponse(result.message)
            AppState.shared.voiceResult = result
            speakAndContinueConversation(result)
            return
        }

        // ── Multi-action: removals before additions ───────────────────────────────
        if var intents = IntentParser.parseMultiAction(transcript, pills: pills), intents.count >= 2 {
            // Sort: removals first
            intents.sort { a, b in
                let isRemoveA: Bool
                switch a {
                case .pillRemove, .pillRemoveMultiple: isRemoveA = true
                default: isRemoveA = false
                }
                let isRemoveB: Bool
                switch b {
                case .pillRemove, .pillRemoveMultiple: isRemoveB = true
                default: isRemoveB = false
                }
                return isRemoveA && !isRemoveB
            }
            VoiceTranscriptHistory.shared.record(
                transcript: transcript,
                note: intents.map { String(describing: $0) }.joined(separator: " + "),
                origin: .multi)
            var parts: [String] = []
            var anyFailure = false
            var lastSuccess: VoiceIntent? = nil
            for intent in intents {
                let r = await runner.run(intent, availablePills: pills, rawTranscript: transcript)
                parts.append(r.message)
                if case .failure = r.outcome { anyFailure = true }
                // .question in multi-action: treat as failure (no re-listen in combined flow).
                if case .question = r.outcome { anyFailure = true }
                if case .success = r.outcome { lastSuccess = intent }
            }
            if let last = lastSuccess { conversationContext.update(last) }
            let combined = VoiceActionResult(
                outcome: anyFailure ? .failure : .success,
                message: parts.joined(separator: " · ")
            )
            if anyFailure {
                NotificationCenter.default.post(name: .botDizzy, object: nil)
            }
            VoiceCaptionManager.shared.setUserLine(transcript)
            VoiceCaptionManager.shared.appendResponse(combined.message)
            AppState.shared.voiceResult = combined
            speakAndContinueConversation(combined)
            return
        }

        // ── Relative context resolution ────────────────────────────────────────────
        let intent: VoiceIntent
        let transcriptOrigin: TranscriptOrigin
        if conversationContext.lastIntent != nil,
           let resolved = conversationContext.resolveRelative(transcript, pills: pills) {
            intent = resolved
            transcriptOrigin = .context
        } else {
            intent = IntentParser.parse(transcript, pills: pills)
            transcriptOrigin = .parser
        }

        // ── Single command ─────────────────────────────────────────────────────────
        let locale = VoiceEngine.shared.speechLocale
        let tParseEnd = Date()
        let parseMs   = Int(tParseEnd.timeIntervalSince(t0) * 1000)

        // Update caption user line immediately
        VoiceCaptionManager.shared.setUserLine(transcript)

        var result = await runner.run(intent, availablePills: pills, rawTranscript: transcript)
        var effectiveIntent = intent
        VoiceTranscriptHistory.shared.record(transcript: transcript, intent: intent, origin: transcriptOrigin)

        let tActionEnd = Date()
        let actionMs   = Int(tActionEnd.timeIntervalSince(tParseEnd) * 1000)

        // Incomplete phrase ("je veux que tu ajoutes…", nothing named): ask which pill
        // and listen for it, instead of guessing or saying "pas compris".
        var askedBack = false
        if case .unknown = intent, let ask = runner.askIfIncomplete(transcript) {
            result = ask
            askedBack = true
        }

        // If unknown, try VoiceBrain (macOS 26 + Apple Intelligence) with streaming TTS.
        if case .unknown = intent, !askedBack {
            let tBrain0  = Date()
            let brainWarm = VoiceBrain.shared.isSessionReady
            var brainUsed = false

            // A stale "finished speaking" handler from the previous turn would re-open
            // the mic between two streamed sentences: drop it before streaming.
            VoiceSpeaker.shared.onDidFinish = nil

            let brain = await VoiceBrain.shared.resolveWithStreaming(
                transcript, pills: pills
            ) { sentence, hasActions in
                // When the model is acting (tool call), its text is not spoken: the real
                // outcome comes from VoiceActionRunner below ("C'est fait" must not be
                // said before the action ran, or when it failed / needs a question).
                if !hasActions { VoiceSpeaker.shared.enqueue(sentence, locale: locale) }
                VoiceCaptionManager.shared.appendResponse(sentence)
            }

            let brainMs = Int(Date().timeIntervalSince(tBrain0) * 1000)
            appendAppLog("nb.log",
                "[Voice] turn: parse=\(parseMs)ms action=\(actionMs)ms brain=\(brainMs)ms (\(brainWarm ? "warm" : "cold"))")

            if let brain {
                if !brain.intents.isEmpty {
                    // Run the actions the model asked for: removals before additions.
                    var sorted = brain.intents
                    sorted.sort { a, b in
                        let ra: Bool = { switch a { case .pillRemove, .pillRemoveMultiple: return true; default: return false } }()
                        let rb: Bool = { switch b { case .pillRemove, .pillRemoveMultiple: return true; default: return false } }()
                        return ra && !rb
                    }
                    effectiveIntent = sorted[0]
                    var parts: [String] = []
                    var anyFailure = false
                    var questionResult: VoiceActionResult? = nil
                    for bi in sorted {
                        let r = await runner.run(bi, availablePills: pills, rawTranscript: transcript)
                        parts.append(r.message)
                        switch r.outcome {
                        case .success:
                            effectiveIntent = bi
                            VoiceTranscriptHistory.shared.record(transcript: transcript, intent: bi, origin: .brain)
                        case .failure:
                            anyFailure = true
                        case .question:
                            questionResult = r
                        }
                    }
                    // Same path as a parser command below: short spoken confirmation,
                    // or the question ("laquelle j'enlève ?") with its re-listen.
                    VoiceCaptionManager.shared.clearResponse()
                    result = questionResult ?? VoiceActionResult(
                        outcome: anyFailure ? .failure : .success,
                        message: parts.joined(separator: " · "))
                } else if !brain.text.isEmpty {
                    result = VoiceActionResult(outcome: .success, message: brain.text)
                    brainUsed = true
                }
            }

            if brainUsed {
                // TTS sentences already enqueued via streaming. Enter conversation and
                // continue once the speaker queue drains.
                conversationContext.update(effectiveIntent)
                consecutiveFailures = 0
                AppState.shared.voiceResult = result
                _enterConversationAfterStreamedSpeech()
                return
            }

            appendAppLog("nb.log", "[Voice] turn: parse=\(parseMs)ms action=\(actionMs)ms brain=\(brainMs)ms (\(brainWarm ? "warm" : "cold")) — no result")
        } else {
            appendAppLog("nb.log", "[Voice] turn: parse=\(parseMs)ms action=\(actionMs)ms (parser)")
        }

        // Mid-conversation, a phrase with no command in it (talking to someone else,
        // "on s'en fout c'est"…) is dropped silently: no dizzy Mochi, no "pas compris".
        // Two in a row end the conversation.
        if case .unknown = effectiveIntent, result.outcome == .failure {
            if isInConversation {
                // Second miss (or noise while waiting for an answer): stop there.
                appendAppLog("nb.log", "[Voice] answer had no command in it, ignored")
                closeVoiceTurn()
                return
            }
            // First miss right after "OK Coucou": ask once, like a person would
            // ("Pardon, tu peux répéter ?"), then listen for the repeat.
            let again = VoiceActionResult(
                outcome: .success,
                message: VoiceActionRunner.localizedString("voice.ask-repeat", locale: runner.commandLocale))
            VoiceCaptionManager.shared.appendResponse(again.message)
            AppState.shared.voiceResult = again
            speakAndContinueConversation(again)
            return
        }

        // Mochi reaction + consecutive failure tracking
        switch result.outcome {
        case .success:
            conversationContext.update(effectiveIntent)
            consecutiveFailures = 0
        case .failure:
            NotificationCenter.default.post(name: .botDizzy, object: nil)
            if isInConversation { consecutiveFailures += 1 }
        case .question:
            break   // Mochi will show listening after re-open
        }

        // After 2 consecutive failures in conversation mode: end without speaking
        if isInConversation && consecutiveFailures >= 2 {
            consecutiveFailures = 0
            endConversation(speaking: false)
            return
        }

        // Update caption with result; island stays compact (no expand).
        VoiceCaptionManager.shared.appendResponse(result.message)
        AppState.shared.voiceResult = result

        if case .question = result.outcome {
            // Speak the question aloud, then re-listen once speech finishes.
            // Give 5 s initial silence so the user has time to read/hear the question.
            let speaker = VoiceSpeaker.shared
            if VoiceSettings.speakEnabled {
                speaker.speak(result.message, locale: locale)
                speaker.onDidFinish = { [weak self] in
                    Task { @MainActor in
                        guard self != nil else { return }
                        VoiceEngine.shared.startListeningDirectly(firstWordTimeout: 5.0)
                    }
                }
            } else {
                voiceResultWork?.cancel()
                voiceResultWork = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard self != nil else { return }
                    VoiceEngine.shared.startListeningDirectly(firstWordTimeout: 5.0)
                }
            }
        } else {
            speakAndContinueConversation(result)
        }
    }

    @MainActor
    private func showVoiceResult(_ result: VoiceActionResult, emote: BotEmote? = nil) {
        if let emote = emote {
            NotificationCenter.default.post(name: .triggerEmote, object: emote)
        } else if result.outcome == .failure {
            NotificationCenter.default.post(name: .botDizzy, object: nil)
        }
        AppState.shared.voiceResult = result
        expand(to: .voiceResult)
        scheduleVoiceDismiss(delay: 2.0)
    }

    /// Speak the result, then stop listening — unless the answer is a question, in which
    /// case listen once for the reply. Coucou cannot tell whether I am talking to it or
    /// to someone else, so it only keeps the mic open when it asked something.
    @MainActor
    private func speakAndContinueConversation(_ result: VoiceActionResult) {
        let asks = Self.isQuestion(result)
        let speaker = VoiceSpeaker.shared
        if VoiceSettings.speakEnabled {
            speaker.speak(result.message, locale: VoiceEngine.shared.speechLocale)
            speaker.onDidFinish = { [weak self] in
                Task { @MainActor in self?.finishVoiceTurn(expectAnswer: asks) }
            }
        } else {
            // No speech: leave the caption up a moment, then finish.
            voiceResultWork?.cancel()
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.finishVoiceTurn(expectAnswer: asks) }
            }
            voiceResultWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
        }
    }

    /// After the on-device model's streamed answer: same rule once the speech drains.
    @MainActor
    private func _enterConversationAfterStreamedSpeech() {
        let asks = Self.isQuestion(AppState.shared.voiceResult)
        let speaker = VoiceSpeaker.shared
        if speaker.isSpeaking {
            speaker.onDidFinish = { [weak self] in
                Task { @MainActor in self?.finishVoiceTurn(expectAnswer: asks) }
            }
        } else {
            finishVoiceTurn(expectAnswer: asks)
        }
    }

    /// A question Coucou asked: an explicit follow-up, or an answer ending with "?".
    private static func isQuestion(_ result: VoiceActionResult?) -> Bool {
        guard let result else { return false }
        if case .question = result.outcome { return true }
        let t = result.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix("?") || t.hasSuffix("？") || t.hasSuffix("؟")
    }

    /// Listen once for the reply to Coucou's question, or close the turn.
    @MainActor
    private func finishVoiceTurn(expectAnswer: Bool) {
        // One follow-up only: the reply to a question closes the turn after it is handled
        // (unless that reply leads to another question, e.g. "which one do I remove?").
        if expectAnswer && VoiceEngine.shared.isEnabled {
            isInConversation = true
            VoiceBrain.shared.beginConversation()
            if AppState.shared.soundEnabled { SoundEngine.shared.play("tick") }
            VoiceEngine.shared.startConversationTurn()
        } else {
            closeVoiceTurn()
        }
    }

    /// Stop listening and let the island settle. The context (last action, model session)
    /// stays 90 s so a new "OK Coucou, et Stripe aussi" still understands "aussi".
    @MainActor
    private func closeVoiceTurn() {
        isInConversation = false
        consecutiveFailures = 0
        hasSpokenPasCompris = false
        VoiceEngine.shared.endConversation()
        VoiceCaptionManager.shared.endConversation()
        scheduleVoiceDismiss(delay: 0.3)
        voiceContextExpiry?.cancel()
        let expiry = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.conversationContext.reset()
                VoiceBrain.shared.endConversation()
            }
        }
        voiceContextExpiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: expiry)
    }

    /// Kept for the paths that still call it (collapse, end phrase): close and forget.
    @MainActor
    private func endConversation(speaking: Bool) {
        closeVoiceTurn()
    }

    @MainActor
    private func scheduleVoiceDismiss(delay: TimeInterval) {
        voiceResultWork?.cancel()
        VoiceCaptionManager.shared.hide(after: delay)
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            AppState.shared.voiceResult = nil
            AppState.shared.voiceActive = false
            // Reset view before collapsing so shouldIgnoreWake never sees a stale .voiceResult.
            AppState.shared.view = self.defaultView()
            self.fsm.voiceFinished()
        }
        voiceResultWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
#endif

// MARK: - Notification names

extension Notification.Name {
    static let triggerEmote     = Notification.Name("notchBuddy.triggerEmote")
    static let triggerSlap      = Notification.Name("notchBuddy.triggerSlap")
    static let botDizzy         = Notification.Name("notchBuddy.botDizzy")
    static let botGreet         = Notification.Name("notchBuddy.botGreet")
    static let botBlink         = Notification.Name("notchBuddy.botBlink")
    static let botSetTgEs       = Notification.Name("notchBuddy.botSetTgEs")
    static let botGulp          = Notification.Name("notchBuddy.botGulp")
    static let botMorphTo       = Notification.Name("notchBuddy.botMorphTo")
    static let islandAction     = Notification.Name("notchBuddy.islandAction")
    static let islandCollapse      = Notification.Name("notchBuddy.islandCollapse")
    static let islandSendMessage   = Notification.Name("notchBuddy.islandSendMessage")
    static let islandNewConversation = Notification.Name("notchBuddy.islandNewConversation")
    static let islandToggleDiff           = Notification.Name("notchBuddy.islandToggleDiff")
    static let islandActivateCardSelection = Notification.Name("notchBuddy.islandActivateCardSelection")
    static let openFullSettings    = Notification.Name("notchBuddy.openFullSettings")
    static let hookReveal       = Notification.Name("notchBuddy.hookReveal")
    static let musicReveal      = Notification.Name("notchBuddy.musicReveal")
    // Greeting ↔ IslandWindowController
    static let greetComplete    = Notification.Name("notchBuddy.greetComplete")
    static let checkMondayRecap = Notification.Name("notchBuddy.checkMondayRecap")
    static let greetingHover    = Notification.Name("notchBuddy.greetingHover")
    static let greetingInterrupt = Notification.Name("notchBuddy.greetingInterrupt")
    static let openWardrobeFromDesktop = Notification.Name("notchBuddy.openWardrobeFromDesktop")
    // Island moved to another screen (resting size may differ: notch vs bar)
    static let islandScreenChanged = Notification.Name("notchBuddy.islandScreenChanged")
}

// MARK: - islandSize (takes real notch dimensions)

func islandSize(mode: IslandMode, view: IslandView,
                progress: Double = 0,
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
