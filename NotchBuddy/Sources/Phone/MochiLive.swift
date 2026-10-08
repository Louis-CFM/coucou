import QuartzCore
import SwiftUI

/// Mochi alive, as in the Mac's notch: he blinks, looks around and reacts to
/// his state (a hop when a task finishes). Same BotEngine as the Mac. Draws
/// only while on screen, at the screen's own rate (up to 120 Hz on ProMotion)
/// unless capped.
struct MochiLive: View {
    let state: BotState
    var bodyHex: String = "#FFFFFF"
    /// A cap for small, numerous Mochi (list rows); nil = the screen's rate.
    var fps: Double? = nil

    @StateObject private var engine = BotEngine()
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: fps.map { 1 / $0 }, paused: !visible)) { timeline in
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
