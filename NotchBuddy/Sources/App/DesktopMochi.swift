import AppKit
import SwiftUI
import Combine

// MARK: - Desktop bot view state

/// Observable bridge so DesktopMochiController can update view-level state without
/// coupling to SwiftUI @State.
@MainActor
final class DesktopBotViewState: ObservableObject {
    /// When true the TimelineView is paused (screen sleep/lock).
    @Published var paused: Bool = false
    /// Bot center in the same coord space as AppState.mousePosition (y-down from screen top).
    /// Updated every poll frame; Canvas reads it inside TimelineView, no @Published needed.
    var lookOrigin: CGPoint = .zero
}

// MARK: - Desktop bot view

/// Full Mochi character rendered inside the desktop floating panel.
/// Mirrors BotCanvasView but uses the controller-owned engine and look-origin override.
struct DesktopBotView: View {
    @ObservedObject var appState: AppState
    /// Engine owned by DesktopMochiController; the controller calls methods on it directly.
    let engine: BotEngine
    @ObservedObject var viewState: DesktopBotViewState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: viewState.paused)) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt  = min(0.05, now - engine.lastTime)

                // Eye tracking based on the panel's own screen position
                engine.lookX = tanh((appState.mousePosition.x - viewState.lookOrigin.x) / 260)
                engine.lookY = -tanh((appState.mousePosition.y - viewState.lookOrigin.y) / 200)

                // Desktop Mochi is always the "main" Mochi — always dressed
                engine.setOutfit(appState.resolvedOutfit, animated: true)

                // Dance when music plays (same rules as compact mode)
                let dancing: Bool = {
                    #if !APPSTORE
                    guard appState.musicPlaying else { return false }
                    guard appState.activeIntegrations.contains("integration_music") else { return false }
                    let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                    return allowed.contains(appState.effectiveState)
                    #else
                    return false
                    #endif
                }()
                engine.setDancing(dancing)
                engine.update(dt: dt)

                var c = ctx
                engine.applyDance(&c, size: size)

                // Rigid roll when outfit is present (matches BotCanvasView)
                if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                    let center = engine.bodyCenter(size: size)
                    var rigidCtx = c
                    rigidCtx.translateBy(x: center.x, y: center.y)
                    rigidCtx.rotate(by: .radians(engine.roll))
                    rigidCtx.translateBy(x: -center.x, y: -center.y)
                    engine.drawHandsBehind(context: rigidCtx, size: size)
                    engine.drawOutfitBehind(context: rigidCtx, size: size)
                    engine.draw(context: rigidCtx, size: size)
                    engine.drawOutfitFront(context: rigidCtx, size: size)
                } else {
                    engine.drawHandsBehind(context: c, size: size)
                    engine.drawOutfitBehind(context: c, size: size)
                    engine.draw(context: c, size: size)
                    engine.drawOutfitFront(context: c, size: size)
                }
                engine.drawHandsAndExtras(context: c, size: size)
            }
        }
        .onChange(of: appState.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onAppear {
            engine.setState(appState.effectiveState, force: true)
            engine.setOutfit(appState.resolvedOutfit, animated: false)
        }
    }
}

// MARK: - Desktop Mochi controller

/// Manages the "Mochi on the desktop" floating panel.
///
/// Life cycle:
/// - **Install from drag**: `IslandWindowController.finishDrag` calls `install(ghostPanel:at:)`.
/// - **Launch restore**: `AppDelegate` observes `.greetComplete` → `launchFlyIfNeeded()`.
/// - **Alert**: hookExpand notification → surprised emote → `retractForAlert()` (panel gone,
///   flag stays true) → alert resolved → `launchFlyIfNeeded()` restores it.
/// - **User flies home**: double-click → `flyHome()` → full teardown.
@MainActor
final class DesktopMochiController {
    static let shared = DesktopMochiController()
    private init() { observeScreenSleep() }

    private var panel: NSPanel?
    private var engine: BotEngine?
    private var viewState: DesktopBotViewState?
    private var frameTimer: Timer?

    // Drag repositioning
    private var isDragging = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginAtStart: NSPoint = .zero

    // Sleep detection
    private var lastAgentActive: Date = .distantPast
    private var isSleeping = false

    // Screen sleep
    private var screenSleeping = false

    // Lifecycle subscriptions (cleared on full teardown)
    private var cancellables: Set<AnyCancellable> = []
    // Alert-return subscriptions: survive retractForAlert(), cleared on full teardown
    private var alertCancellables: Set<AnyCancellable> = []
    private var hookExpandObserver: Any?

    // Event monitors
    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?
    private var rightClickMonitor: Any?

    // UserDefaults keys
    private static let posXKey    = "desktopMochiX"
    private static let posYKey    = "desktopMochiY"
    private static let enabledKey = "mochiOnDesktop"

    /// Square side of the desktop Mochi panel (pt).
    static let panelSize: CGFloat = 120

    // MARK: - Install (from drag-drop)

    /// Promote `ghostPanel` (the drag ghost) or create a fresh panel as the desktop Mochi,
    /// centered on `screenPoint`. Called by `IslandWindowController.finishDrag`.
    func install(ghostPanel: NSPanel?, at screenPoint: NSPoint) {
        let s = DesktopMochiController.panelSize

        let p: NSPanel
        if let ghost = ghostPanel {
            p = ghost
        } else {
            p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
        }

        let origin = clampToVisibleFrame(NSPoint(x: screenPoint.x - s/2, y: screenPoint.y - s/2))
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        p.setFrame(NSRect(origin: origin, size: CGSize(width: s, height: s)), display: true)

        activatePanel(p)
        SoundEngine.shared.play("pop")
        engine?.triggerEmote(.happy, duration: 0.6, silent: true)
    }

    // MARK: - Launch fly (app-start restore or alert return)

    /// Fly a new panel from the notch to the saved desktop position.
    /// Called by AppDelegate after `.greetComplete`, and by the alert-return sink.
    func launchFlyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: DesktopMochiController.enabledKey) else { return }
        guard panel == nil else { return }

        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main!
        let startOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        let target = loadSavedPosition()

        let p = NSPanel(
            contentRect: NSRect(origin: startOrigin, size: CGSize(width: s, height: s)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true

        // Build content now so the engine is ready during the animation
        let eng = BotEngine()
        eng.setState(AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        self.engine = eng

        let vs = DesktopBotViewState()
        vs.lookOrigin = lookOriginFor(panel: p)
        vs.paused = screenSleeping
        self.viewState = vs

        let hosting = NSHostingView(rootView:
            DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs)
        )
        hosting.frame = CGRect(x: 0, y: 0, width: s, height: s)
        p.contentView = hosting
        p.alphaValue = 0
        p.orderFront(nil)

        // Hide notch Mochi before animation begins
        AppState.shared.mochiOnDesktop = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: target, size: CGSize(width: s, height: s)), display: true)
        }, completionHandler: {
            Task { @MainActor in
                self.panel = p
                UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
                self.persistPosition()
                self.startPolling()
                self.addEventMonitors()
                self.observeLifecycle()
            }
        })
    }

    // MARK: - Fly home (user-initiated: double-click)

    /// Animate panel to notch then fully tear down.
    func flyHome() {
        guard let p = panel else { return }
        stopPolling()
        removeEventMonitors()
        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main!
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(
                NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)), display: true)
        }, completionHandler: {
            Task { @MainActor in
                SoundEngine.shared.play("peek")
                self.fullTearDown()
            }
        })
    }

    // MARK: - Retract for alert (panel flies home, comes back after alert resolves)

    /// Close panel and show notch Mochi for the alert. UserDefaults flag stays true so
    /// `launchFlyIfNeeded` restores Mochi once the alert is dismissed.
    private func retractForAlert() {
        guard let p = panel else { return }
        stopPolling()
        removeEventMonitors()
        cancellables.removeAll()   // lifecycle subs only; alertCancellables survive

        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main!
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(
                NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)), display: true)
        }, completionHandler: {
            Task { @MainActor in
                p.close()
                self.panel = nil
                self.engine = nil
                self.viewState = nil
                self.isDragging = false
                self.isSleeping = false
                // mochiOnDesktop → false so notch Mochi appears for the alert
                AppState.shared.mochiOnDesktop = false
                // UserDefaults flag stays TRUE so launchFlyIfNeeded works
            }
        })
    }

    // MARK: - Uninstall (immediate, no animation)

    func uninstall() {
        stopPolling()
        removeEventMonitors()
        fullTearDown()
    }

    private func fullTearDown() {
        if let obs = hookExpandObserver { NotificationCenter.default.removeObserver(obs); hookExpandObserver = nil }
        cancellables.removeAll()
        alertCancellables.removeAll()
        panel?.close()
        panel = nil
        engine = nil
        viewState = nil
        isDragging = false
        isSleeping = false
        AppState.shared.mochiOnDesktop = false
        UserDefaults.standard.set(false, forKey: DesktopMochiController.enabledKey)
    }

    // MARK: - Panel activation helper

    private func activatePanel(_ p: NSPanel) {
        let s = DesktopMochiController.panelSize

        let eng = BotEngine()
        eng.setState(AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        self.engine = eng

        let vs = DesktopBotViewState()
        vs.lookOrigin = lookOriginFor(panel: p)
        vs.paused = screenSleeping
        self.viewState = vs

        let hosting = NSHostingView(rootView:
            DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs)
        )
        hosting.frame = CGRect(x: 0, y: 0, width: s, height: s)
        p.contentView = hosting
        p.alphaValue = 1
        p.orderFront(nil)

        self.panel = p
        AppState.shared.mochiOnDesktop = true
        UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
        persistPosition()

        startPolling()
        addEventMonitors()
        observeLifecycle()
        observeAlertReturn()   // start watching for alerts (idempotent via hookExpandObserver)
    }

    // MARK: - Lifecycle observation (active while panel is live)

    private func observeLifecycle() {
        cancellables.removeAll()

        // .finished state → joy jump
        AppState.shared.$stateOverride
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if AppState.shared.effectiveState == .finished {
                    self.engine?.triggerEmote(.happy, duration: 1.2, silent: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Alert observation (survives retract/restore cycle)

    private func observeAlertReturn() {
        // Only register once; hookExpandObserver guards against duplicates
        guard hookExpandObserver == nil else { return }

        hookExpandObserver = NotificationCenter.default.addObserver(
            forName: .hookExpand, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.panel != nil else { return }
            // Surprised emote then fly home, leaving UserDefaults flag intact
            self.engine?.triggerEmote(.surprised)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.panel != nil else { return }
                self.retractForAlert()
            }
        }

        // When pendingApproval clears → fly back
        AppState.shared.$pendingApproval
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] approval in
                guard let self, approval == nil, self.panel == nil,
                      UserDefaults.standard.bool(forKey: DesktopMochiController.enabledKey)
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.launchFlyIfNeeded()
                }
            }
            .store(in: &alertCancellables)

        // When pendingQuestion clears → fly back
        AppState.shared.$pendingQuestion
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] question in
                guard let self, question == nil, self.panel == nil,
                      UserDefaults.standard.bool(forKey: DesktopMochiController.enabledKey)
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.launchFlyIfNeeded()
                }
            }
            .store(in: &alertCancellables)
    }

    // MARK: - 60 Hz polling

    private func startPolling() {
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollFrame() }
        }
        RunLoop.main.add(frameTimer!, forMode: .common)
    }

    private func stopPolling() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func pollFrame() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        let pf    = p.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)
        let s     = DesktopMochiController.panelSize

        // Toggle click-through
        let overBody  = isOverBody(local: local, size: s)
        let needsMouse = overBody || isDragging
        if p.ignoresMouseEvents == needsMouse {
            p.ignoresMouseEvents = !needsMouse
        }

        // Update eye-tracking origin every frame
        viewState?.lookOrigin = lookOriginFor(panel: p)

        // Sleep detection: 2 min no agent activity + mouse > 150 pt away
        let agentActive = AppState.shared.effectiveState != .idle &&
                          AppState.shared.effectiveState != .sleeping
        if agentActive { lastAgentActive = .now }
        let mouseNear = hypot(mouse.x - pf.midX, mouse.y - pf.midY) < 150
        let idle2min  = Date.now.timeIntervalSince(lastAgentActive) > 120
        let shouldSleep = idle2min && !mouseNear

        if shouldSleep != isSleeping {
            isSleeping = shouldSleep
            engine?.setState(isSleeping ? .sleeping : AppState.shared.effectiveState)
        }
    }

    private func isOverBody(local: CGPoint, size: CGFloat) -> Bool {
        let cx = size / 2, cy = size / 2
        let r: CGFloat = size * 0.24
        return (local.x - cx) * (local.x - cx) + (local.y - cy) * (local.y - cy) <= r * r
    }

    // MARK: - Event monitors

    private func addEventMonitors() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard event.window === self.panel else { return }
                self.dragMouseStart    = NSEvent.mouseLocation
                self.dragOriginAtStart = self.panel?.frame.origin ?? .zero
            }
            return event
        }

        mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let m = NSEvent.mouseLocation
                if !self.isDragging {
                    let dist = hypot(m.x - self.dragMouseStart.x, m.y - self.dragMouseStart.y)
                    guard self.dragMouseStart != .zero, dist > 3 else { return }
                    self.isDragging = true
                }
                guard let p = self.panel else { return }
                let dx = m.x - self.dragMouseStart.x
                let dy = m.y - self.dragMouseStart.y
                let newOrigin = self.clampToVisibleFrame(
                    NSPoint(x: self.dragOriginAtStart.x + dx, y: self.dragOriginAtStart.y + dy))
                p.setFrameOrigin(newOrigin)
                self.viewState?.lookOrigin = self.lookOriginFor(panel: p)
            }
            return event
        }

        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let wasDragging = self.isDragging
                self.isDragging = false
                self.dragMouseStart = .zero
                if wasDragging {
                    self.persistPosition()
                } else if event.window === self.panel {
                    if event.clickCount >= 2 {
                        self.flyHome()
                    } else {
                        self.engine?.slap()
                    }
                }
            }
            return event
        }

        // Global mouseUp fallback (cursor moved outside all panels during drag)
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDragging else { return }
                self.isDragging = false
                self.dragMouseStart = .zero
                self.persistPosition()
            }
        }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard event.window === self.panel else { return }
                if AppState.shared.mode == .expanded && AppState.shared.view == .wardrobe {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        AppState.shared.view = .overview
                    }
                } else {
                    NotificationCenter.default.post(name: .hookExpand, object: IslandView.wardrobe)
                }
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let m = mouseDownMonitor    { NSEvent.removeMonitor(m); mouseDownMonitor    = nil }
        if let m = mouseDraggedMonitor { NSEvent.removeMonitor(m); mouseDraggedMonitor = nil }
        if let m = mouseUpMonitor      { NSEvent.removeMonitor(m); mouseUpMonitor      = nil }
        if let m = rightClickMonitor   { NSEvent.removeMonitor(m); rightClickMonitor   = nil }
    }

    // MARK: - Screen sleep / wake

    private func observeScreenSleep() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.viewState?.paused = true
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.viewState?.paused = false
            }
        }
    }

    // MARK: - Position helpers

    private func lookOriginFor(panel: NSPanel) -> CGPoint {
        let s = DesktopMochiController.panelSize
        let screen  = panel.screen ?? NSScreen.main!
        let screenH = screen.frame.height
        let cx = panel.frame.minX + s / 2
        let cy = panel.frame.minY + s / 2
        return CGPoint(x: cx - screen.frame.minX, y: screenH - cy)
    }

    private func clampToVisibleFrame(_ origin: NSPoint) -> NSPoint {
        let s = DesktopMochiController.panelSize
        let margin: CGFloat = 24
        let screen = NSScreen.screens.min(by: {
            let da = hypot(origin.x - $0.visibleFrame.midX, origin.y - $0.visibleFrame.midY)
            let db = hypot(origin.x - $1.visibleFrame.midX, origin.y - $1.visibleFrame.midY)
            return da < db
        }) ?? NSScreen.main!
        let vf = screen.visibleFrame
        return NSPoint(
            x: min(max(origin.x, vf.minX + margin), vf.maxX - s - margin),
            y: min(max(origin.y, vf.minY + margin), vf.maxY - s - margin)
        )
    }

    private func loadSavedPosition() -> NSPoint {
        let ud = UserDefaults.standard
        guard ud.object(forKey: DesktopMochiController.posXKey) != nil else {
            return defaultPosition()
        }
        let x = CGFloat(ud.double(forKey: DesktopMochiController.posXKey))
        let y = CGFloat(ud.double(forKey: DesktopMochiController.posYKey))
        return clampToVisibleFrame(NSPoint(x: x, y: y))
    }

    private func defaultPosition() -> NSPoint {
        let s = DesktopMochiController.panelSize
        let margin: CGFloat = 24
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - s - margin, y: vf.minY + margin)
    }

    private func persistPosition() {
        guard let p = panel else { return }
        let o = p.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: DesktopMochiController.posXKey)
        UserDefaults.standard.set(Double(o.y), forKey: DesktopMochiController.posYKey)
    }
}
