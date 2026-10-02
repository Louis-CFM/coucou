import SwiftUI

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    var isVisible: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var idleBurst: IdleMicroAnimation?

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: state.mode == .hidden ? 1.0 / 20 : nil,
                                paused: state.mode == .hidden && idleBurst == nil)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dtRaw = min(0.05, now - engine.lastTime)
                let dt = dtRaw
                if let burst = idleBurst, Date().timeIntervalSince(state.lastMouseMove) > 1 {
                    let look = burst.look(at: now)
                    engine.lookX = look.x
                    engine.lookY = look.y
                } else if state.mode == .hidden && state.idleAnimationsEnabled && state.effectiveState == .idle {
                    engine.lookX = 0
                    engine.lookY = 0
                } else {
                    let look = lookDirection(state: state)
                    engine.lookX = look.x
                    engine.lookY = look.y
                }
                engine.particleOverhang = particleOverhang
                // Widen slot when file is hovering over the mailbox (morph > 0.5)
                // Open mouth (hover=0.20R) when file dragged over box; close when not
                if engine.morph > 0.3 {
                    engine.slotHTarget = state.fileDragOver ? 0.20 : 0
                } else {
                    engine.slotHTarget = 0
                    if engine.morph < 0.05 { engine.slotH = 0; engine.slotHVel = 0 }
                }
                // Integration pills have a fixed brand color → use it as bodyColor.
                // Claude Code tasks use state-based gradient (working=blue, thinking=purple, etc.).
                engine.bodyColor = (state.focusTask?.isIntegration == true)
                    ? cgColorFromHex(state.focusTask!.color)
                    : nil

                // Compute shouldDance per-frame (no observer lag)
                let dancing: Bool = {
                    #if !APPSTORE
                    guard AppState.shared.musicPlaying else { return false }
                    guard AppState.shared.activeIntegrations.contains("integration_music") else { return false }
                    let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                    guard allowed.contains(state.effectiveState) else { return false }
                    if state.mode == .compact { return true }
                    return state.mode == .expanded && state.view == .overview && state.focusId == "integration_music"
                    #else
                    return false
                    #endif
                }()
                engine.setDancing(dancing)

                engine.update(dt: dt)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.drawHandsBehind(context: ctx, size: size)
                engine.draw(context: ctx, size: size)
                engine.drawHandsAndExtras(context: ctx, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onChange(of: state.view) { _, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
            }
        }
        .onChange(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.tweens.removeValue(forKey: "morph")
                engine.locks.remove("morph")
                engine.morph = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if let emote = notif.object as? BotEmote {
                engine.triggerEmote(emote)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            engine.slap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            engine.blink()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botSetTgEs)) { notif in
            if let v = notif.object as? CGFloat {
                engine.tgEs = v
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGulp)) { _ in
            engine.gulp()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botMorphTo)) { notif in
            if let target = notif.object as? CGFloat {
                let dur: CGFloat = target > 0.5 ? 550 : 650
                engine.anim("morph", keys: [TweenKey(target: target, duration: dur, ease: Ease.inOut)])
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .botGreet)) { _ in
            engine.greet()
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
        }
        .task(id: idleAnimationsEligible) {
            await runIdleAnimations()
        }
    }

    private var idleAnimationsEligible: Bool {
        IdleMicroAnimation.isEligible(enabled: state.idleAnimationsEnabled,
                                      visible: isVisible && !state.isDraggingBot,
                                      resting: state.mode == .hidden || state.mode == .compact,
                                      idle: state.effectiveState == .idle,
                                      reduceMotion: reduceMotion)
    }

    @MainActor
    private func runIdleAnimations() async {
        guard idleAnimationsEligible else { return }
        defer {
            if idleBurst != nil { settleRestingEyes() }
            idleBurst = nil
        }
        do {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(Double.random(in: IdleMicroAnimation.pauseRange)))
                guard Date().timeIntervalSince(state.lastMouseMove) > 1 else { continue }
                let burst = IdleMicroAnimation.random(startTime: Date().timeIntervalSinceReferenceDate)
                engine.nextBlink = CACurrentMediaTime() + IdleMicroAnimation.duration + 3
                idleBurst = burst
                try await Task.sleep(for: .seconds(IdleMicroAnimation.blinkDelay))
                if burst.blinks && Date().timeIntervalSince(state.lastMouseMove) > 1 {
                    engine.blink()
                }
                try await Task.sleep(for: .seconds(IdleMicroAnimation.duration - IdleMicroAnimation.blinkDelay))
                settleRestingEyes()
                idleBurst = nil
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private func settleRestingEyes() {
        guard state.mode == .hidden && state.effectiveState == .idle else { return }
        engine.yaw = 0
        engine.pitch = 0
        engine.tgYaw = 0
        engine.tgPitch = 0
        engine.open = 1
        engine.tweens.removeValue(forKey: "open")
        engine.locks.remove("open")
    }

    private func lookDirection(state: AppState) -> CGPoint {
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                             islandW: islandW, islandH: actualH,
                                             uploadProgress: state.uploadProgress)
        return IslandGazeGeometry.direction(mouse: state.mousePosition,
                                            panelFrame: state.islandPanelFrame,
                                            islandWidth: islandW,
                                            botCenter: CGPoint(x: botCx, y: botCy))
    }
}

/// Mini bot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    var isDancing: Bool = false
    @StateObject private var engine: BotEngine

    init(task: AgentTask, isDancing: Bool = false) {
        self.task = task
        self.isDancing = isDancing
        _engine = StateObject(wrappedValue: {
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dt = min(0.05, now - engine.lastTime)
                engine.setDancing(isDancing)
                engine.update(dt: dt)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                engine.draw(context: ctx, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        .onAppear {
            engine.setState(task.state, force: true)
            if let emote = task.emote {
                engine.setPermanentEmote(emote)
            }
            // Direct eye override takes priority (e.g. .wide eyes for Research)
            if let eye = task.miniEye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
        }
    }
}

// MARK: - CGColor from hex string

func cgColorFromHex(_ hex: String) -> CGColor? {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard let val = UInt64(h, radix: 16) else { return nil }
    let r = CGFloat((val >> 16) & 0xFF) / 255
    let g = CGFloat((val >> 8)  & 0xFF) / 255
    let b = CGFloat( val        & 0xFF) / 255
    return CGColor(red: r, green: g, blue: b, alpha: 1)
}

extension CGColor {
    static func from(_ hex: String) -> CGColor {
        cgColorFromHex(hex) ?? CGColor(gray: 0.5, alpha: 1)
    }
}
