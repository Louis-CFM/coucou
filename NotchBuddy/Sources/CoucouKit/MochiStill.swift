import SwiftUI

/// Mochi in a fixed pose: one frame of BotEngine, no animation, no timer.
/// For surfaces that can't animate (widgets, lists on the iPhone). The Mac
/// island keeps its animated BotCanvasView / MiniBotCanvasView.
struct MochiStill: View {
    var state: BotState = .idle
    /// Overrides the state's eyes (e.g. .closed for a sleeping agent).
    var eye: EyeShape? = nil
    /// Body color; white by default, like the mockups.
    var bodyHex: String = "#FFFFFF"
    var showBadge: Bool = true
    /// Where he looks and how his eyes are, for a still that isn't always the same.
    var pose: MochiPose = .neutral

    var body: some View {
        Canvas { context, size in
            let engine = BotEngine()
            engine.isMini = true
            engine.bodyColor = cgColorFromHex(bodyHex)
            engine.state = state
            engine.cfg = BotStates[state]!
            engine.yaw = pose.yaw
            engine.pitch = pose.pitch
            engine.tilt = pose.tilt
            engine.open = pose.open
            if let eye = eye ?? pose.eye {
                engine.permanentEye = eye
                engine.eyeOverride = eye
                engine.eyeOverrideUntil = .greatestFiniteMagnitude
            }
            engine.draw(context: context, size: size)
            if showBadge, let badge = engine.cfg.badge {
                engine.badge = badge
                engine.badgeS = 1
                engine.drawHandsAndExtras(context: context, size: size)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// One frame of the little life the Mac's mini Mochi have: looking around,
/// blinking, a happy squint. Widgets can't animate, so each refresh of the
/// timeline picks a new pose per Mochi; the system cross-fades between them.
struct MochiPose: Equatable, Sendable {
    var yaw: CGFloat = 0
    var pitch: CGFloat = 0
    var tilt: CGFloat = 0
    var open: CGFloat = 1
    var eye: EyeShape? = nil

    static let neutral = MochiPose()

    static let idlePoses: [MochiPose] = [
        MochiPose(),
        MochiPose(yaw: -0.45),
        MochiPose(yaw: 0.45),
        MochiPose(yaw: -0.3, pitch: -0.25),
        MochiPose(yaw: 0.35, pitch: 0.2, tilt: 0.08),
        MochiPose(pitch: -0.3, tilt: -0.06),
        MochiPose(eye: .closed),                 // blink
        MochiPose(yaw: 0.2, eye: .happy),
        MochiPose(yaw: -0.5, tilt: -0.1),
        MochiPose(yaw: 0.15, pitch: 0.25),
    ]

    /// A pose that differs per Mochi and per tick, the same every time for a
    /// given pair (so a widget redraw doesn't jump).
    static func idle(id: String, tick: Int) -> MochiPose {
        var hash: UInt64 = 5381
        for byte in id.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        hash = (hash &* 31) &+ UInt64(truncatingIfNeeded: tick &* 7919)
        hash ^= hash >> 13
        return idlePoses[Int(hash % UInt64(idlePoses.count))]
    }
}

extension Color {
    /// Background for a white Mochi on an agent's color. Very light colors
    /// (VS Code's is near-white) would hide him, so they get a dark gray tile.
    static func mochiTile(hex: String) -> Color {
        guard let c = cgColorFromHex(hex), let comps = c.components, comps.count >= 3 else {
            return Color(hex: hex)
        }
        let luminance = 0.2126 * comps[0] + 0.7152 * comps[1] + 0.0722 * comps[2]
        return luminance > 0.7 ? Color(white: 0.32) : Color(hex: hex)
    }
}
