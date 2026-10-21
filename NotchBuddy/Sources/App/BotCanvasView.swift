import SwiftUI
import AppKit

/// SwiftUI wrapper: TimelineView drives a Canvas that calls MascotEngine.draw().
struct BotCanvasView: View {
    @ObservedObject var state: AppState
    var particleOverhang: CGFloat = 0
    /// Not drawn while true.
    var paused: Bool = false

    // One engine per view instance (main bot)
    @StateObject private var engine = MascotEngine()

    var body: some View {
        TimelineView(.animation(paused: state.mode == .hidden || paused)) { timeline in
            // The Canvas must capture the frame's date: a closure that doesn't change from
            // one tick to the next is not redrawn.
            let frame = timeline.date
            Canvas { context, size in
                _ = frame
                let look = lookXY(state: state)
                engine.lookX = look.x
                engine.lookY = look.y
                if state.showingPlanDetail {
                    let hex = state.planDetailIsCodex
                        ? CodexPlanGauge.color(state.codexPlanUsage)
                        : ClaudePlanGauge.color(for: state.claudePlanUsage.flatMap { ClaudePlanGauge.dominantPct($0) })
                    engine.bodyColor = cgColorFromHex(hex)
                } else {
                    // Integration pills have a fixed brand colour; agents use the state's colour.
                    engine.bodyColor = (state.focusTask?.isIntegration == true)
                        ? cgColorFromHex(state.focusTask!.color)
                        : nil
                }
                engine.update(dt: 0.05)
                engine.draw(context: context, size: size)
            }
        }
        .onChange(of: state.effectiveState) { _, newState in
            engine.setState(newState)
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerEmote)) { notif in
            if let emote = notif.object as? BotEmote { engine.triggerEmote(emote) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .triggerSlap)) { _ in
            engine.slap()
        }
        .onReceive(NotificationCenter.default.publisher(for: .botBlink)) { _ in
            engine.blink()
        }
        .onAppear {
            engine.setState(state.effectiveState, force: true)
        }
    }

    /// Where the mascot looks (the pointer), both axes at once: the island geometry and the
    /// screen are looked up once per frame instead of twice each.
    private func lookXY(state: AppState) -> (x: CGFloat, y: CGFloat) {
        let (islandW, islandH) = islandSize(mode: state.mode, view: state.view,
                                             nw: state.notchWidth, nh: state.notchHeight)
        let screen = IslandWindowController.islandScreen().frame
        let desktopTop = IslandWindowController.desktopTop
        // The pointer read now, not from the island poll (which slows down far from it).
        let mouse = DesktopSpace.topDown(NSEvent.mouseLocation, desktopTop: desktopTop)
        func botPoint(islandH: CGFloat) -> CGPoint {
            let (botCx, botCy, _, _) = botPosition(mode: state.mode, view: state.view,
                                                    islandW: islandW, islandH: islandH)
            return DesktopSpace.topDown(CGPoint(x: screen.midX - islandW / 2 + botCx,
                                                y: screen.maxY - botCy),
                                        desktopTop: desktopTop)
        }
        let botX = botPoint(islandH: islandH)
        // The chat view grows with the conversation: vertical look uses its real height.
        let actualH: CGFloat = (state.mode == .expanded && state.view == .prompt)
            ? min(300, 240 + CGFloat(state.chatHistory.count) * 40)
            : islandH
        let botY = actualH == islandH ? botX : botPoint(islandH: actualH)
        return (tanh((mouse.x - botX.x) / 260),
                -tanh((mouse.y - botY.y) / 200))
    }
}

/// Mini mascot canvas (for agent pills/column)
struct MiniBotCanvasView: View {
    let task: AgentTask
    @StateObject private var engine: MascotEngine

    init(task: AgentTask) {
        self.task = task
        _engine = StateObject(wrappedValue: {
            let e = MascotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(task.color)
            return e
        }())
    }

    @Environment(\.islandViewActive) private var viewActive

    var body: some View {
        // Paused in island views that are not shown.
        TimelineView(.animation(paused: !viewActive)) { timeline in
            let frame = timeline.date   // redraw on every tick
            Canvas { context, size in
                _ = frame
                engine.update(dt: 0.05)
                engine.draw(context: context, size: size)
            }
        }
        .onChange(of: task.state) { _, newState in
            engine.setState(newState)
        }
        // A colour picked in Settings has to reach a mascot that is already on screen.
        .onChange(of: task.color) { _, newColor in
            engine.bodyColor = cgColorFromHex(newColor)
        }
        .onAppear {
            engine.setState(task.state, force: true)
        }
    }
}
