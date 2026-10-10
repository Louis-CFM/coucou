import SwiftUI

/// SwiftUI wrapper: TimelineView drives a Canvas that calls BotEngine.draw().
/// Uses a shared engine per-task; the main bot uses AppState's shared engine.
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// When set, overrides island-based eye-tracking (used by desktop Mochi).
    /// CGPoint in the same coord space as state.mousePosition (DesktopSpace, y-down).
    var lookOriginOverride: CGPoint? = nil

    // One engine per view instance (main bot)
    @StateObject private var engine = BotEngine()

    var body: some View {
        TimelineView(.animation(paused: state.mode == .hidden && state.volumeHUD == nil)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let dtRaw = min(0.05, now - engine.lastTime)
                let dt = dtRaw
                engine.lookX = lookX(state: state, size: size)
                engine.lookY = lookY(state: state, size: size)
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
                #if !APPSTORE
                if state.showingPlanDetail {
                    let hex = state.planDetailIsCodex
                        ? CodexPlanGauge.color(state.codexPlanUsage)
                        : ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
                    engine.bodyColor = cgColorFromHex(hex)
                } else {
                    engine.bodyColor = (state.focusTask?.isIntegration == true)
                        ? cgColorFromHex(state.focusTask!.color)
                        : nil
                }
                #else
                engine.bodyColor = (state.focusTask?.isIntegration == true)
                    ? cgColorFromHex(state.focusTask!.color)
                    : nil
                #endif

                // Compute shouldDance per-frame (no observer lag)
                let dancing: Bool = {
                    #if !APPSTORE
                    let active = AppState.shared.activeIntegrations
                    let music = AppState.shared.musicPlaying && active.contains("integration_music")
                    let spotify = SpotifyController.shared.isPlaying && active.contains(SpotifyController.pillId)
                    guard music || spotify else { return false }
                    let allowed: Set<BotState> = [.idle, .working, .thinking, .searching, .finished]
                    guard allowed.contains(state.effectiveState) else { return false }
                    if state.mode == .compact { return true }
                    guard state.mode == .expanded && state.view == .overview else { return false }
                    return (music && state.focusId == "integration_music")
                        || (spotify && state.focusId == SpotifyController.pillId)
                    #else
                    return false
                    #endif
                }()
                engine.setDancing(dancing)
                let isWardrobe = state.mode == .expanded && state.view == .wardrobe
                let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
                let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
                engine.setOutfit(showOutfit ? state.resolvedOutfit : .none,
                                 animated: state.view != .wardrobe)

                #if !APPSTORE
                if state.view == .listening {
                    engine.listeningLevel  = CGFloat(VoiceEngine.shared.micLevel)
                    engine.listeningHasWords = !VoiceEngine.shared.commandTranscript.isEmpty
                }
                #endif

                engine.update(dt: dt)
                var ctx = context
                engine.applyDance(&ctx, size: size)
                // Rigid-roll: when Mochi wears an outfit (presence > 0.05) and is rolling,
                // rotate the entire body+accessories context around the body center so the
                // whole character genuinely turns. Particles/badge (drawHandsAndExtras) are
                // drawn outside the rotated context and do not spin.
                if engine.outfit != .none && engine.outfitPresence > 0.05 && abs(engine.roll) > 0.001 {
                    let center = engine.bodyCenter(size: size)
                    var rigidCtx = ctx
                    rigidCtx.translateBy(x: center.x, y: center.y)
                    rigidCtx.rotate(by: .radians(engine.roll))
                    rigidCtx.translateBy(x: -center.x, y: -center.y)
                    engine.drawHandsBehind(context: rigidCtx, size: size)
                    engine.drawOutfitBehind(context: rigidCtx, size: size)
                    engine.draw(context: rigidCtx, size: size)
                    engine.drawOutfitFront(context: rigidCtx, size: size)
                } else {
                    engine.drawHandsBehind(context: ctx, size: size)
                    engine.drawOutfitBehind(context: ctx, size: size)
                    engine.draw(context: ctx, size: size)
                    engine.drawOutfitFront(context: ctx, size: size)
                }
                engine.drawHandsAndExtras(context: ctx, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onChange(of: state.view) { oldView, newView in
            // Morph up when upload view is active
            if state.mode == .expanded && newView == .upload {
                engine.anim("morph", keys: [TweenKey(target: 1, duration: 550, ease: Ease.inOut)])
            } else if newView != .upload && newView != .uploading && engine.morph > 0.01 {
                // Any other view (not mid-gulp): morph back
                engine.anim("morph", keys: [TweenKey(target: 0, duration: 550, ease: Ease.inOut)])
            }
            #if !APPSTORE
            if newView == .listening {
                engine.enterListening()
            } else if oldView == .listening {
                engine.exitListening(hadCommand: !VoiceEngine.shared.commandTranscript.isEmpty)
            }
            #endif
        }
        .onChange(of: state.mode) { _, newMode in
            // Hard-reset morph when island collapses
            if newMode != .expanded {
                engine.tweens.removeValue(forKey: "morph")
                engine.locks.remove("morph")
                engine.morph = 0
            }
        }
        // Volume key: hop, with eyes that follow the level.
        .onChange(of: state.volumeHUD?.bump) { _, bump in
            guard bump != nil, let hud = state.volumeHUD else { return }
            let eye: EyeShape? = hud.muted ? .line
                : hud.level <= 0.001 ? .closed
                : hud.level >= 0.999 ? .wide
                : hud.level > 0.66 ? .happy
                : nil
            engine.volumeHop(eye: eye)
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
            let isWardrobe = state.mode == .expanded && state.view == .wardrobe
            let isFocusMain = state.focusId == state.mainPillId || state.focusId == nil
            let showOutfit = isFocusMain || state.mode != .expanded || isWardrobe
            engine.setOutfit(showOutfit ? state.resolvedOutfit : .none, animated: false)
        }
    }

    private func lookX(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return tanh((state.mousePosition.x - origin.x) / 260)
        }
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                islandW: islandW, islandH: islandH,
                                                uploadProgress: state.uploadProgress)
        let bot = islandBotPoint(islandW: islandW, botCx: botCx, botCy: botCy)
        return tanh((state.mousePosition.x - bot.x) / 260)
    }

    /// Bot centre in DesktopSpace, like state.mousePosition. The island is centred at the
    /// top of its screen, which can be any display, anywhere in the arrangement.
    private func islandBotPoint(islandW: CGFloat, botCx: CGFloat, botCy: CGFloat) -> CGPoint {
        let screen = IslandWindowController.islandScreen().frame
        return DesktopSpace.topDown(CGPoint(x: screen.midX - islandW / 2 + botCx,
                                            y: screen.maxY - botCy),
                                    desktopTop: IslandWindowController.desktopTop)
    }

    private func lookY(state: AppState, size: CGSize) -> CGFloat {
        if let origin = lookOriginOverride {
            return -tanh((state.mousePosition.y - origin.y) / 200)
        }
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             progress: state.uploadProgress,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                islandW: islandW, islandH: actualH,
                                                uploadProgress: state.uploadProgress)
        let bot = islandBotPoint(islandW: islandW, botCx: botCx, botCy: botCy)
        return -tanh((state.mousePosition.y - bot.y) / 200)
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
        // The colour is set once, when the engine is made: a colour picked in
        // Settings has to reach a mini Mochi that is already on screen.
        .onChange(of: task.color) { _, newColor in
            engine.bodyColor = cgColorFromHex(newColor)
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
