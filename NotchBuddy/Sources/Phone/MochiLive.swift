import QuartzCore
import SwiftUI

/// Mochi alive, as in the Mac's notch: he blinks, looks around and reacts to
/// his state (a hop when a task finishes). Same BotEngine as the Mac. Draws
/// only while on screen, at a capped frame rate.
struct MochiLive: View {
    let state: BotState
    var bodyHex: String = "#FFFFFF"
    /// Lower for small, numerous Mochi (list rows).
    var fps: Double = 30

    @StateObject private var engine = BotEngine()
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: !visible)) { timeline in
            Canvas { context, size in
                _ = timeline.date
                let dt = min(0.05, max(0, CACurrentMediaTime() - engine.lastTime))
                engine.update(dt: dt)
                engine.draw(context: context, size: size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear {
            engine.isMini = true
            engine.bodyColor = cgColorFromHex(bodyHex)
            engine.setState(state, force: true)
            visible = true
        }
        .onDisappear { visible = false }
        .onChange(of: state) { _, newState in engine.setState(newState) }
        .onChange(of: bodyHex) { _, hex in engine.bodyColor = cgColorFromHex(hex) }
        .accessibilityHidden(true)
    }
}
