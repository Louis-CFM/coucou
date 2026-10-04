import AppKit
import SwiftUI
import Combine

// MARK: - Desktop bot view state

/// Observable bridge so DesktopMochiController can update view-level state without
/// coupling to SwiftUI @State.
@MainActor
final class DesktopBotViewState: ObservableObject {
    /// Drop to 10 fps when sleeping (saves energy).
    @Published var isSleeping: Bool = false
    /// Pause entirely (screen sleep / lock).
    @Published var paused: Bool = false
    /// Bot center in the same coord space as AppState.mousePosition (y-down from screen top).
    /// Updated every poll frame; Canvas reads it inside TimelineView — @Published not needed.
    var lookOrigin: CGPoint = .zero
}

// MARK: - Desktop bot view

/// Full Mochi character rendered inside the desktop floating panel.
struct DesktopBotView: View {
    @ObservedObject var appState: AppState
    /// Engine owned by DesktopMochiController; controller calls methods on it directly.
    let engine: BotEngine
    @ObservedObject var viewState: DesktopBotViewState

    var body: some View {
        TimelineView(.animation(
            minimumInterval: viewState.isSleeping ? 1.0 / 10.0 : 1.0 / 30.0,
            paused: viewState.paused
        )) { timeline in
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

// MARK: - Motion sub-state (active while phase == .onDesktop)

/// A single hop in a wander sequence.
struct WanderHop {
    let fromX:    CGFloat
    let toX:      CGFloat
    let fromY:    CGFloat   // panel origin.y at hop start
    let toY:      CGFloat   // panel origin.y at hop end (same for same-surface, different for cross-surface)
    let hopHeight: CGFloat
    let duration:  TimeInterval
}

/// Physics / motion state for the desktop panel while `phase == .onDesktop`.
enum DesktopMotion {
    /// Panel placed by the user; gravity not yet applied.
    case free
    /// Timer-driven accelerated fall to a surface (t² easing).
    case falling(from: CGPoint, to: CGPoint, windowID: CGWindowID?,
                  startTime: TimeInterval, duration: TimeInterval)
    /// Sitting on a surface (window or screen bottom). Tracked at 4 Hz.
    case perched(windowID: CGWindowID?, relativeX: CGFloat, lastFrame: CGRect)
    /// Mid-wander hop sequence.
    case hopping(hops: [WanderHop], index: Int, startTime: TimeInterval, landingWindowID: CGWindowID?)
}

// MARK: - Desktop Mochi controller

/// Manages the "Mochi on the desktop" floating panel.
///
/// Life cycle:
/// - **Install from drag**: `IslandWindowController.finishDrag` calls `install(ghostPanel:at:)`.
/// - **Launch restore**: `AppDelegate` observes `.greetComplete` → `launchFlyIfNeeded()`.
/// - **Alert**: `pendingApproval`/`pendingQuestion` goes non-nil → surprised emote →
///   `retractForAlert()` (panel gone, flag stays true) → both nil → `launchFlyIfNeeded()`.
/// - **User flies home**: double-click → `flyHome()` → full teardown.
///
/// While on the desktop Mochi obeys gravity: he falls to the nearest window surface or the
/// screen bottom, perches there, and wanders every 25–70 s.
@MainActor
final class DesktopMochiController {
    static let shared = DesktopMochiController()
    private init() {
        observeScreenSleep()
        observeScreenLock()
        observeAlerts()   // permanent — lives for the lifetime of the singleton
    }

    private var panel: NSPanel?
    private var engine: BotEngine?
    private var viewState: DesktopBotViewState?
    private var frameTimer: Timer?

    // Alert state machine
    private var phase: DesktopPhase = .home

    // Desktop drag repositioning
    private var isDragging = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginAtStart: NSPoint = .zero

    // Deferred single-click slap
    private var pendingSlapWorkItem: DispatchWorkItem?

    // Sleep detection
    private var lastAgentActive: Date = .distantPast
    private var isSleeping = false

    // Screen sleep / lock
    private var screenSleeping = false

    // Lifecycle subscriptions (cleared on retractForAlert + fullTearDown)
    private var cancellables: Set<AnyCancellable> = []
    // Alert subscription — permanent, only released with the singleton
    private var alertSubscription: AnyCancellable?

    // Event monitors
    private var mouseDownMonitor:    Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor:      Any?
    private var globalMouseUpMonitor: Any?
    private var rightClickMonitor:   Any?

    // Gravity / perching / wander
    private var motion: DesktopMotion = .free
    private var wanderWorkItem: DispatchWorkItem?
    // Throttle full surface list to once per second (perch coverage check)
    private var lastCoverageCheckTime: TimeInterval = 0

    // UserDefaults keys
    private static let posXKey    = "desktopMochiX"
    private static let posYKey    = "desktopMochiY"
    private static let enabledKey = "mochiOnDesktop"

    static let panelSize: CGFloat = DesktopMochiLogic.panelSize

    // MARK: - Install (from drag-drop)

    /// Promote `ghostPanel` (the drag ghost) or create a fresh panel as the desktop Mochi,
    /// centered on `screenPoint`. Called by `IslandWindowController.finishDrag`.
    func install(ghostPanel: NSPanel?, at screenPoint: NSPoint) {
        guard panel == nil, phase == .home else { ghostPanel?.close(); return }
        let s = DesktopMochiController.panelSize

        let p: NSPanel
        if let ghost = ghostPanel {
            p = ghost
        } else {
            p = makeBlankPanel()
            p.setFrame(NSRect(x: screenPoint.x - s/2, y: screenPoint.y - s/2, width: s, height: s),
                       display: false)
        }

        // Build engine + hosting view (autoresizingMask lets it grow with the panel animation)
        let eng = BotEngine()
        eng.setState(AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        self.engine = eng

        let vs = DesktopBotViewState()
        vs.lookOrigin = lookOriginFor(panel: p)
        vs.paused = screenSleeping
        self.viewState = vs

        let hosting = NSHostingView(rootView:
            DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs))
        hosting.frame = CGRect(origin: .zero, size: p.frame.size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting

        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.ignoresMouseEvents = true
        if !p.isVisible { p.orderFront(nil) }

        // Sound on landing
        SoundEngine.shared.play("pop")

        // Animate from current (ghost) size to 120 × 120, centered on drop point
        let targetOrigin = clampToVisibleFrame(NSPoint(x: screenPoint.x - s/2, y: screenPoint.y - s/2))
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.17, 0.67, 0.38, 1.3)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                self.panel = p
                self.phase = .onDesktop
                AppState.shared.mochiOnDesktop = true
                UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
                self.persistPosition()
                // Alert may have fired during the animation (observeAlerts skipped: phase wasn't .onDesktop)
                let alertNow = AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil
                if DesktopMochiLogic.shouldRetractOnLanding(alertActive: alertNow) {
                    self.engine?.triggerEmote(.surprised)
                    self.phase = .retracting
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self else { return }
                        switch self.phase {
                        case .retracting:              self.retractForAlert()
                        case .alertResolvedDuringRetract: self.phase = .home; self.launchFlyIfNeeded()
                        default: break
                        }
                    }
                } else {
                    self.motion = .free
                    self.startPolling()
                    self.addEventMonitors()
                    self.observeLifecycle()
                    self.startGravity()
                }
            }
        })
    }

    // MARK: - Launch fly (app-start restore or alert return)

    /// Fly a new panel from the notch to the saved desktop position.
    /// Called by AppDelegate after `.greetComplete`, and by the alert-return path.
    func launchFlyIfNeeded() {
        guard UserDefaults.standard.bool(forKey: DesktopMochiController.enabledKey) else { return }
        guard phase == .home else { return }
        guard panel == nil else { return }
        // Alert active: don't fly yet — park in .atNotchForAlert so observeAlerts restores us when it clears
        if AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil {
            phase = .atNotchForAlert
            return
        }

        phase = .flyingOut
        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main!
        let startOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        let target = loadSavedPosition()

        let p = makeBlankPanel()
        p.setFrame(NSRect(origin: startOrigin, size: CGSize(width: s, height: s)), display: false)

        let eng = BotEngine()
        eng.setState(AppState.shared.effectiveState, force: true)
        eng.setOutfit(AppState.shared.resolvedOutfit, animated: false)
        self.engine = eng

        let vs = DesktopBotViewState()
        vs.lookOrigin = lookOriginFor(panel: p)
        vs.paused = screenSleeping
        self.viewState = vs

        let hosting = NSHostingView(rootView:
            DesktopBotView(appState: AppState.shared, engine: eng, viewState: vs))
        hosting.frame = CGRect(x: 0, y: 0, width: s, height: s)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        p.alphaValue = 0
        p.orderFront(nil)

        AppState.shared.mochiOnDesktop = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 1
            p.animator().setFrame(NSRect(origin: target, size: CGSize(width: s, height: s)), display: true)
        }, completionHandler: {
            Task { @MainActor in
                self.panel = p
                self.phase = .onDesktop
                UserDefaults.standard.set(true, forKey: DesktopMochiController.enabledKey)
                self.persistPosition()
                // Alert may have fired during the flight (observeAlerts skipped: phase was .flyingOut)
                let alertNow = AppState.shared.pendingApproval != nil || AppState.shared.pendingQuestion != nil
                if DesktopMochiLogic.shouldRetractOnLanding(alertActive: alertNow) {
                    self.engine?.triggerEmote(.surprised)
                    self.phase = .retracting
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                        guard let self else { return }
                        switch self.phase {
                        case .retracting:              self.retractForAlert()
                        case .alertResolvedDuringRetract: self.phase = .home; self.launchFlyIfNeeded()
                        default: break
                        }
                    }
                } else {
                    self.motion = .free
                    self.startPolling()
                    self.addEventMonitors()
                    self.observeLifecycle()
                    self.startGravity()
                }
            }
        })
    }

    // MARK: - Fly home (user-initiated: double-click)

    /// Animate panel to notch then fully tear down.
    func flyHome() {
        guard let p = panel else { return }
        phase = .home
        pendingSlapWorkItem?.cancel()
        cancelWander()
        stopPolling()
        removeEventMonitors()
        cancellables.removeAll()
        motion = .free
        isSleeping = false
        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main!
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                SoundEngine.shared.play("peek")
                self.fullTearDown()
            }
        })
    }

    // MARK: - Retract for alert (panel flies home; comes back after alert resolves)

    /// Close panel and show notch Mochi for the alert. UserDefaults flag stays true so
    /// `launchFlyIfNeeded` restores Mochi once the alert is dismissed.
    private func retractForAlert() {
        guard let p = panel else { return }
        cancelWander()
        stopPolling()
        removeEventMonitors()
        cancellables.removeAll()
        pendingSlapWorkItem?.cancel()
        motion = .free
        isSleeping = false

        let s = DesktopMochiController.panelSize
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main!
        let targetOrigin = NSPoint(x: screen.frame.midX - s/2, y: screen.frame.maxY - s)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().setFrame(NSRect(origin: targetOrigin, size: CGSize(width: s, height: s)),
                                  display: true)
        }, completionHandler: {
            Task { @MainActor in
                p.close()
                self.panel = nil
                self.engine = nil
                self.viewState = nil
                self.isDragging = false
                AppState.shared.mochiOnDesktop = false
                // UserDefaults flag stays TRUE so launchFlyIfNeeded works
                if self.phase == .alertResolvedDuringRetract {
                    self.phase = .home
                    self.launchFlyIfNeeded()
                } else {
                    self.phase = .atNotchForAlert
                }
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
        phase = .home
        cancelWander()
        cancellables.removeAll()
        pendingSlapWorkItem?.cancel()
        motion = .free
        panel?.close()
        panel = nil
        engine = nil
        viewState = nil
        isDragging = false
        isSleeping = false
        AppState.shared.mochiOnDesktop = false
        UserDefaults.standard.set(false, forKey: DesktopMochiController.enabledKey)
    }

    // MARK: - Panel factory

    private func makeBlankPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        return p
    }

    // MARK: - Gravity: fall to nearest surface

    /// Query visible windows, find the highest surface below Mochi's feet, and begin a
    /// timer-driven accelerated fall (t² easing) — or perch immediately if already there.
    ///
    /// - Parameter comingFrom: window ID we just left (occlusion / gone). If the best
    ///   landing target is that same window, stay put instead of starting another fall
    ///   (anti-loop guard).
    private func startGravity(comingFrom: CGWindowID? = nil) {
        guard phase == .onDesktop, let p = panel else { return }
        let windows = querySurfaces()
        let vf      = currentVisibleFrame()
        let pf      = p.frame

        let (targetY, windowID) = DesktopMochiLogic.surfaceBelow(
            panelFrame: pf, windows: windows, visibleFrame: vf)

        // Anti-loop: would land on the same window we just left → re-perch silently
        if let from = comingFrom, windowID == from {
            let wf = windows.first { $0.id == from }?.frame ?? .zero
            motion = .perched(windowID: from,
                               relativeX: pf.minX - wf.minX,
                               lastFrame: wf)
            setPollingInterval(DesktopMochiLogic.nextPollInterval(inMotion: false,
                                                                   sleeping: isSleeping))
            return
        }

        let dist = pf.minY - targetY   // fall distance (panel origin delta, always >= 0)

        if dist < 2 {
            // Already on surface (within rounding error)
            let wf = windowID.flatMap { id in windows.first { $0.id == id } }?.frame ?? .zero
            landOnSurface(at: CGPoint(x: pf.minX, y: targetY),
                           windowID: windowID, lastWindowFrame: wf, sound: false)
            return
        }

        let dur = DesktopMochiLogic.fallDuration(pixelDistance: dist)
        let from = CGPoint(x: pf.minX, y: pf.minY)
        let to   = CGPoint(x: pf.minX, y: targetY)
        motion   = .falling(from: from, to: to, windowID: windowID,
                              startTime: now(), duration: dur)
        setPollingInterval(DesktopMochiLogic.nextPollInterval(inMotion: true, sleeping: isSleeping))
    }

    /// Perch Mochi directly on a window found during a drag-drop (no fall animation).
    private func perchAtWindow(_ window: WindowSurface) {
        guard let p = panel else { return }
        let targetY = window.topY - DesktopMochiLogic.bodyBottomInset
        let relX    = p.frame.minX - window.frame.minX
        p.setFrameOrigin(NSPoint(x: p.frame.minX, y: targetY))
        persistPosition()
        engine?.squash()
        motion = .perched(windowID: window.id, relativeX: relX, lastFrame: window.frame)
        setPollingInterval(DesktopMochiLogic.nextPollInterval(inMotion: false, sleeping: isSleeping))
        scheduleWander()
    }

    /// Land after a fall or the last hop of a wander sequence.
    private func landOnSurface(at origin: CGPoint, windowID: CGWindowID?,
                                lastWindowFrame: CGRect, sound: Bool) {
        guard let p = panel else { return }
        p.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
        persistPosition()
        if sound { SoundEngine.shared.play("pop") }
        engine?.squash()
        let relX = windowID != nil ? origin.x - lastWindowFrame.minX : origin.x
        motion = .perched(windowID: windowID, relativeX: relX, lastFrame: lastWindowFrame)
        setPollingInterval(DesktopMochiLogic.nextPollInterval(inMotion: false, sleeping: isSleeping))
        scheduleWander()
    }

    // MARK: - Wander

    private func scheduleWander() {
        wanderWorkItem?.cancel()
        let delay = TimeInterval.random(
            in: DesktopMochiLogic.wanderMinInterval...DesktopMochiLogic.wanderMaxInterval)
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.tryWander() }
        }
        wanderWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelWander() {
        wanderWorkItem?.cancel()
        wanderWorkItem = nil
    }

    private func tryWander() {
        guard phase == .onDesktop, !isSleeping, !isDragging else { scheduleWander(); return }
        guard AppState.shared.effectiveState == .idle else { scheduleWander(); return }
        guard AppState.shared.pendingApproval == nil,
              AppState.shared.pendingQuestion == nil else { scheduleWander(); return }

        guard case .perched(let windowID, _, _) = motion else { scheduleWander(); return }

        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation
        guard hypot(mouse.x - p.frame.midX, mouse.y - p.frame.midY)
                > DesktopMochiLogic.wanderMouseStop else { scheduleWander(); return }

        let windows    = querySurfaces()
        let vf         = currentVisibleFrame()
        let baseY      = p.frame.minY   // current panel origin.y (body feet = baseY + bodyBottomInset)
        let bodyBottom = p.frame.minY + DesktopMochiLogic.bodyBottomInset
        let (boundsMinX, boundsMaxX) = surfaceBounds(windowID: windowID, windows: windows, visibleFrame: vf)

        // 1-in-4 chance: jump to a neighboring surface (real 2D distance ≤ 220 pt)
        if Double.random(in: 0...1) < DesktopMochiLogic.neighborChance {
            let candidates = windows.filter { w in
                w.id != windowID &&
                !DesktopMochiLogic.isEdgeCovered(surface: w, atX: p.frame.midX, windows: windows)
            }.filter { w in
                // Real 2D distance: from body-feet to landing spot
                let targetX = p.frame.minX.clamped(to: w.frame.minX ... max(w.frame.minX, w.frame.maxX - DesktopMochiLogic.panelSize))
                let dx = targetX + DesktopMochiLogic.panelSize / 2 - p.frame.midX
                let dy = w.topY - bodyBottom
                return hypot(dx, dy) <= DesktopMochiLogic.neighborMaxDist
            }
            if let target = candidates.randomElement() {
                let targetX = p.frame.minX.clamped(to: target.frame.minX ...
                              max(target.frame.minX, target.frame.maxX - DesktopMochiLogic.panelSize))
                let targetY = target.topY - DesktopMochiLogic.bodyBottomInset
                let hop = WanderHop(fromX: p.frame.minX,
                                     toX: targetX,
                                     fromY: baseY,
                                     toY: targetY,
                                     hopHeight: 30,
                                     duration: 0.5)
                motion = .hopping(hops: [hop], index: 0, startTime: now(), landingWindowID: target.id)
                setPollingInterval(DesktopMochiLogic.nextPollInterval(inMotion: true, sleeping: false))
                return
            }
        }

        // Normal same-surface wander
        var rng = SystemRandomNumberGenerator()
        let xs  = DesktopMochiLogic.planWander(rng: &rng,
                                                currentX: p.frame.minX,
                                                minX: boundsMinX,
                                                maxX: boundsMaxX)
        guard !xs.isEmpty else { scheduleWander(); return }

        var hops: [WanderHop] = []
        var prevX = p.frame.minX
        for toX in xs {
            hops.append(WanderHop(fromX: prevX, toX: toX,
                                    fromY: baseY, toY: baseY,
                                    hopHeight: DesktopMochiLogic.wanderHopHeight,
                                    duration: DesktopMochiLogic.wanderHopDuration))
            prevX = toX
        }
        motion = .hopping(hops: hops, index: 0, startTime: now(), landingWindowID: windowID)
        setPollingInterval(DesktopMochiLogic.nextPollInterval(inMotion: true, sleeping: false))
    }

    // MARK: - Lifecycle observation (active while panel is live on desktop)

    private func observeLifecycle() {
        cancellables.removeAll()

        // effectiveState → .finished: joy jump (only when on desktop, not retracting)
        Publishers.CombineLatest(AppState.shared.$stateOverride, AppState.shared.$tasks)
            .map { _, _ in AppState.shared.effectiveState }
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self, self.phase == .onDesktop else { return }
                if newState == .finished {
                    self.engine?.triggerEmote(.happy, duration: 1.2, silent: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Alert observation (permanent — installed once at init)

    private func observeAlerts() {
        alertSubscription = Publishers.CombineLatest(
            AppState.shared.$pendingApproval,
            AppState.shared.$pendingQuestion
        )
        .map { a, q in a != nil || q != nil }
        .removeDuplicates()
        .dropFirst()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] alertActive in
            guard let self else { return }

            if alertActive {
                guard self.phase == .onDesktop else { return }
                self.engine?.triggerEmote(.surprised)
                self.phase = .retracting
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self else { return }
                    switch self.phase {
                    case .retracting:
                        self.retractForAlert()
                    case .alertResolvedDuringRetract:
                        // Alert cleared before animation started — no need to retract
                        self.phase = .home
                        self.launchFlyIfNeeded()
                    default:
                        break
                    }
                }
            } else {
                switch self.phase {
                case .atNotchForAlert:
                    self.phase = .home
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.launchFlyIfNeeded()
                    }
                case .retracting:
                    // Alert resolved while waiting to retract — mark it
                    self.phase = .alertResolvedDuringRetract
                default:
                    break
                }
            }
        }
    }

    // MARK: - Polling (rate-adaptive)

    private func startPolling() {
        setPollingInterval(1.0 / 60.0)
    }

    private func stopPolling() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func setPollingInterval(_ interval: TimeInterval) {
        guard abs((frameTimer?.timeInterval ?? -1) - interval) > 0.001 else { return }
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.pollFrame() }
        }
        RunLoop.main.add(frameTimer!, forMode: .common)
    }

    // MARK: - Poll frame

    private func pollFrame() {
        guard let p = panel else { return }
        let mouse = NSEvent.mouseLocation

        // Advance motion (fall / hop), or check perch stability
        updateMotion(panel: p, mouse: mouse)

        // Click-through toggle based on current position
        let pf    = p.frame
        let local = CGPoint(x: mouse.x - pf.minX, y: mouse.y - pf.minY)
        let overBody   = DesktopMochiLogic.isOverBody(localPoint: local,
                                                       panelSize: DesktopMochiController.panelSize)
        let needsMouse = overBody || isDragging
        if p.ignoresMouseEvents == needsMouse {
            p.ignoresMouseEvents = !needsMouse
        }

        // Update eye-tracking origin every frame
        viewState?.lookOrigin = lookOriginFor(panel: p)

        // Sleep detection (only when perched / still)
        if case .perched = motion {
            updateSleep(panel: p, mouse: mouse)
        }
    }

    // MARK: - Motion tick

    private func updateMotion(panel p: NSPanel, mouse: NSPoint) {
        switch motion {
        case .free:
            break

        case .falling(let from, let to, let windowID, let t0, let dur):
            let elapsed = now() - t0
            let t = CGFloat(min(elapsed / dur, 1.0))
            // t² for accelerated (gravity-like) feel
            let y = from.y + (to.y - from.y) * t * t
            p.setFrameOrigin(NSPoint(x: from.x, y: y))
            if t >= 1.0 {
                let windows = querySurfaces()
                let wf = windowID.flatMap { id in windows.first { $0.id == id } }?.frame ?? .zero
                landOnSurface(at: to, windowID: windowID, lastWindowFrame: wf, sound: true)
            }

        case .perched(let windowID, let relX, let lastFrame):
            updatePerch(panel: p, windowID: windowID, relativeX: relX, lastFrame: lastFrame)

        case .hopping(let hops, let idx, let t0, let landingID):
            updateHop(panel: p, hops: hops, index: idx, startTime: t0,
                       landingWindowID: landingID, mouse: mouse)
        }
    }

    // MARK: - Perch tracking (4 Hz — single-window read; coverage at 1 Hz)

    private func updatePerch(panel p: NSPanel, windowID: CGWindowID?,
                               relativeX: CGFloat, lastFrame: CGRect) {
        guard let id = windowID else { return }  // screen-bottom perch: nothing to track

        // Fast single-window query at 4 Hz to check position
        guard let w = queryWindowInfo(id: id) else {
            // Window gone (closed / minimized)
            startGravity(comingFrom: id)
            return
        }

        // Coverage check: full surface list at most once per second
        let t = now()
        if t - lastCoverageCheckTime >= 1.0 {
            lastCoverageCheckTime = t
            let allWindows = querySurfaces()
            if DesktopMochiLogic.isEdgeCovered(surface: w, atX: p.frame.midX, windows: allWindows) {
                startGravity(comingFrom: id)
                return
            }
        }

        // Follow window if it moved or resized
        guard w.frame != lastFrame else { return }

        let newX = (w.frame.minX + relativeX).clamped(
            to: w.frame.minX ... max(w.frame.minX, w.frame.maxX - DesktopMochiLogic.panelSize))
        let newY = w.topY - DesktopMochiLogic.bodyBottomInset
        p.setFrameOrigin(NSPoint(x: newX, y: newY))
        persistPosition()
        viewState?.lookOrigin = lookOriginFor(panel: p)
        motion = .perched(windowID: id, relativeX: p.frame.minX - w.frame.minX, lastFrame: w.frame)

        // Boost to 60 Hz for 1 s after the window moves, then revert
        setPollingInterval(1.0 / 60.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, case .perched = self.motion else { return }
            self.setPollingInterval(
                DesktopMochiLogic.nextPollInterval(inMotion: false, sleeping: self.isSleeping))
        }
    }

    // MARK: - Hop tick (60 Hz)

    private func updateHop(panel p: NSPanel, hops: [WanderHop], index: Int,
                             startTime: TimeInterval, landingWindowID: CGWindowID?,
                             mouse: NSPoint) {
        guard index < hops.count else {
            let windows = querySurfaces()
            let wf = landingWindowID.flatMap { id in windows.first { $0.id == id } }?.frame ?? .zero
            landOnSurface(at: CGPoint(x: p.frame.minX, y: p.frame.minY),
                           windowID: landingWindowID, lastWindowFrame: wf, sound: false)
            return
        }
        let hop = hops[index]
        let elapsed = now() - startTime
        let t = CGFloat(min(elapsed / hop.duration, 1.0))

        // Lerp X + lerp Y base + parabolic arch
        let x = hop.fromX + (hop.toX - hop.fromX) * t
        let y = hop.fromY + (hop.toY - hop.fromY) * t
                + DesktopMochiLogic.hopY(t: t, height: hop.hopHeight)
        p.setFrameOrigin(NSPoint(x: x, y: y))

        guard t >= 1.0 else { return }

        let nextIdx = index + 1
        if nextIdx < hops.count {
            // Squash between hops; stop if mouse is too close
            engine?.squash()
            let dist = hypot(mouse.x - p.frame.midX, mouse.y - p.frame.midY)
            if dist < DesktopMochiLogic.wanderMouseStop {
                let windows = querySurfaces()
                let wf = landingWindowID.flatMap { id in windows.first { $0.id == id } }?.frame ?? .zero
                landOnSurface(at: CGPoint(x: hop.toX, y: hop.toY),
                               windowID: landingWindowID, lastWindowFrame: wf, sound: false)
                return
            }
            motion = .hopping(hops: hops, index: nextIdx,
                               startTime: now(), landingWindowID: landingWindowID)
        } else {
            let windows = querySurfaces()
            let wf = landingWindowID.flatMap { id in windows.first { $0.id == id } }?.frame ?? .zero
            landOnSurface(at: CGPoint(x: hop.toX, y: hop.toY),
                           windowID: landingWindowID, lastWindowFrame: wf, sound: false)
        }
    }

    // MARK: - Sleep detection

    private func updateSleep(panel p: NSPanel, mouse: NSPoint) {
        let agentActive = AppState.shared.effectiveState != .idle &&
                          AppState.shared.effectiveState != .sleeping
        if agentActive { lastAgentActive = .now }
        let dist     = hypot(mouse.x - p.frame.midX, mouse.y - p.frame.midY)
        let interval = Date.now.timeIntervalSince(lastAgentActive)
        let should   = DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: interval,
                                                      mouseDistanceToPanelCenter: dist)
        if should != isSleeping {
            isSleeping = should
            viewState?.isSleeping = should
            engine?.setState(isSleeping ? .sleeping : AppState.shared.effectiveState)
            if case .perched = motion {
                setPollingInterval(
                    DesktopMochiLogic.nextPollInterval(inMotion: false, sleeping: isSleeping))
            }
        }
    }

    // MARK: - Window surface query (CG → AppKit)

    /// Full surface list, ordered front-to-back (zIndex 0 = frontmost).
    private func querySurfaces() -> [WindowSurface] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        let mainH = primaryScreenHeight()

        return windowList.enumerated().compactMap { (index, info) in
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
                  let layer = info[kCGWindowLayer as String] as? Int32, layer == 0,
                  w >= DesktopMochiLogic.surfaceMinWidth else { return nil }

            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0 else { return nil }

            let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier != ourBundle,
                  app.activationPolicy == .regular else { return nil }

            guard let wid = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) })
            else { return nil }

            // CG (top-left origin, y-down) → AppKit (bottom-left origin, y-up)
            let appkitFrame = CGRect(x: x, y: mainH - y - h, width: w, height: h)
            return WindowSurface(id: wid, frame: appkitFrame, zIndex: index)
        }
    }

    /// Single-window read for perch tracking at 4 Hz.
    /// Uses CGWindowListCopyWindowInfo with optionIncludingWindow + relativeToWindow = id.
    private func queryWindowInfo(id: CGWindowID) -> WindowSurface? {
        // CGWindowListOption: optionOnScreenOnly (1) | optionIncludingWindow (8)
        let opt = CGWindowListOption(rawValue: 1 | 8)
        guard let list = CGWindowListCopyWindowInfo(opt, id) as? [[String: Any]] else { return nil }
        let mainH = primaryScreenHeight()
        for (index, info) in list.enumerated() {
            guard let wid = (info[kCGWindowNumber as String] as? Int).map({ CGWindowID($0) }),
                  wid == id,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let w = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat else { continue }
            let appkitFrame = CGRect(x: x, y: mainH - y - h, width: w, height: h)
            return WindowSurface(id: wid, frame: appkitFrame, zIndex: index)
        }
        return nil
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
                    self.cancelWander()
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

        // Local mouseUp (cursor still within panel)
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                let wasDragging = self.isDragging
                self.isDragging = false
                self.dragMouseStart = .zero
                if wasDragging {
                    self.handleDragRelease(at: NSEvent.mouseLocation)
                } else if event.window === self.panel {
                    self.handleClick(clickCount: event.clickCount)
                }
            }
            return event
        }

        // Global mouseUp (cursor moved outside panel during drag)
        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDragging else { return }
                self.isDragging = false
                self.dragMouseStart = .zero
                self.handleDragRelease(at: NSEvent.mouseLocation)
            }
        }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                guard event.window === self.panel else { return }
                NotificationCenter.default.post(name: .openWardrobeFromDesktop, object: nil)
            }
            return event
        }
    }

    // MARK: - Click / drag helpers

    private func handleClick(clickCount: Int) {
        if clickCount >= 2 {
            pendingSlapWorkItem?.cancel()
            flyHome()
        } else {
            pendingSlapWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.engine?.slap() }
            pendingSlapWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: item)
        }
    }

    private func handleDragRelease(at mouse: NSPoint) {
        let islandController = (NSApp.delegate as? AppDelegate)?.islandController
        let inNotchZone = islandController?.window?.frame.contains(mouse) == true

        if inNotchZone {
            flyHome()
            return
        }

        guard let p = panel else { return }

        // Perch candidate: check against body feet position (not panel bottom)
        let bodyBottom = CGPoint(x: p.frame.midX,
                                  y: p.frame.minY + DesktopMochiLogic.bodyBottomInset)
        let windows    = querySurfaces()
        if let w = DesktopMochiLogic.perchCandidate(bodyBottom: bodyBottom, windows: windows) {
            perchAtWindow(w)
            return
        }

        #if !APPSTORE
        if let ctx = islandController?.windowContextAtPoint(mouse) {
            // Attach window context; Mochi returns to pre-drag position
            AppState.shared.promptContext = ctx
            SoundEngine.shared.play("approve")
            engine?.triggerEmote(.happy, duration: 0.6, silent: true)
            let origin = clampToVisibleFrame(dragOriginAtStart)
            p.setFrameOrigin(origin)
            persistPosition()
            islandController?.expand(to: .prompt)
            startGravity()
            return
        }
        #endif
        // Elsewhere: keep new position, apply gravity
        persistPosition()
        startGravity()
    }

    private func removeEventMonitors() {
        if let m = mouseDownMonitor     { NSEvent.removeMonitor(m); mouseDownMonitor     = nil }
        if let m = mouseDraggedMonitor  { NSEvent.removeMonitor(m); mouseDraggedMonitor  = nil }
        if let m = mouseUpMonitor       { NSEvent.removeMonitor(m); mouseUpMonitor       = nil }
        if let m = globalMouseUpMonitor { NSEvent.removeMonitor(m); globalMouseUpMonitor = nil }
        if let m = rightClickMonitor    { NSEvent.removeMonitor(m); rightClickMonitor    = nil }
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

    // MARK: - Screen lock / unlock

    private func observeScreenLock() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = true
                self?.viewState?.paused = true
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenSleeping = false
                self?.viewState?.paused = false
            }
        }
    }

    // MARK: - Position helpers

    private func lookOriginFor(panel: NSPanel) -> CGPoint {
        let screen = panel.screen ?? NSScreen.main!
        return DesktopMochiLogic.lookOrigin(
            panelMinX:    panel.frame.minX,
            panelMinY:    panel.frame.minY,
            screenMinX:   screen.frame.minX,
            screenHeight: screen.frame.height,
            panelSize:    DesktopMochiController.panelSize)
    }

    private func clampToVisibleFrame(_ origin: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.min(by: {
            let da = hypot(origin.x - $0.visibleFrame.midX, origin.y - $0.visibleFrame.midY)
            let db = hypot(origin.x - $1.visibleFrame.midX, origin.y - $1.visibleFrame.midY)
            return da < db
        }) ?? NSScreen.main!
        let pt = DesktopMochiLogic.clampOrigin(
            CGPoint(x: origin.x, y: origin.y),
            panelSize:    DesktopMochiController.panelSize,
            visibleFrame: screen.visibleFrame,
            margin:       DesktopMochiLogic.clampMargin)
        return NSPoint(x: pt.x, y: pt.y)
    }

    private func currentVisibleFrame() -> CGRect {
        (panel?.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
    }

    /// Height of the primary screen (the one whose bottom-left corner is the origin of
    /// the global AppKit coordinate system). Used for CG ↔ AppKit Y-axis flips.
    private func primaryScreenHeight() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 0
    }

    private func surfaceBounds(windowID: CGWindowID?, windows: [WindowSurface],
                                visibleFrame: CGRect) -> (minX: CGFloat, maxX: CGFloat) {
        if let id = windowID, let w = windows.first(where: { $0.id == id }) {
            return (w.frame.minX, w.frame.maxX)
        }
        return (visibleFrame.minX, visibleFrame.maxX)
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
        let s      = DesktopMochiController.panelSize
        let margin = DesktopMochiLogic.clampMargin
        let vf     = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - s - margin, y: vf.minY + margin)
    }

    private func persistPosition() {
        guard let p = panel else { return }
        let o = p.frame.origin
        UserDefaults.standard.set(Double(o.x), forKey: DesktopMochiController.posXKey)
        UserDefaults.standard.set(Double(o.y), forKey: DesktopMochiController.posYKey)
    }

    // MARK: - Utilities

    private func now() -> TimeInterval { Date().timeIntervalSinceReferenceDate }
}

// MARK: - CGFloat clamping

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        if self < range.lowerBound { return range.lowerBound }
        if self > range.upperBound { return range.upperBound }
        return self
    }
}
