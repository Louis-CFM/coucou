import SwiftUI
import CoreGraphics
import QuartzCore

// A neutral placeholder mascot: a rounded little whale drawn with Canvas. It reacts to the
// agent state (colour, eyes, spout, badge) and to a few emotes. No artwork is embedded.

enum EyeShape: String {
    case dot, wide, line, happy, closed, cross, tired, wink
}

/// What the whale looks like in each agent state.
struct MascotLook {
    let color: CGColor
    let eye: EyeShape
    let spout: Bool
    let bounce: Bool
    let badge: String?

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static func of(_ state: BotState) -> MascotLook {
        switch state {
        case .idle:      return MascotLook(color: rgb(148, 163, 184), eye: .dot,    spout: false, bounce: false, badge: nil)
        case .working:   return MascotLook(color: rgb(56, 140, 248),  eye: .dot,    spout: true,  bounce: false, badge: nil)
        case .thinking:  return MascotLook(color: rgb(139, 112, 240), eye: .dot,    spout: true,  bounce: false, badge: "…")
        case .searching: return MascotLook(color: rgb(45, 170, 190),  eye: .wide,   spout: true,  bounce: false, badge: nil)
        case .approval:  return MascotLook(color: rgb(245, 166, 35),  eye: .wide,   spout: false, bounce: true,  badge: "!")
        case .question:  return MascotLook(color: rgb(34, 190, 220),  eye: .dot,    spout: false, bounce: false, badge: "?")
        case .error:     return MascotLook(color: rgb(240, 80, 90),   eye: .cross,  spout: false, bounce: false, badge: nil)
        case .finished:  return MascotLook(color: rgb(52, 200, 140),  eye: .happy,  spout: false, bounce: false, badge: nil)
        case .ratelimit: return MascotLook(color: rgb(250, 140, 60),  eye: .tired,  spout: false, bounce: false, badge: nil)
        case .sleeping:  return MascotLook(color: rgb(120, 134, 160), eye: .closed, spout: false, bounce: false, badge: "z")
        case .dizzy:     return MascotLook(color: rgb(230, 110, 170), eye: .cross,  spout: false, bounce: false, badge: nil)
        }
    }
}

@MainActor
final class MascotEngine: ObservableObject {
    var isMini = false
    /// Overrides the colour of the current state (pills with a brand colour).
    var bodyColor: CGColor? = nil
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0

    private(set) var state: BotState = .idle
    private var look = MascotLook.of(.idle)
    private var color: (CGFloat, CGFloat, CGFloat) = (0.58, 0.64, 0.72)
    private var time: Double = Double.random(in: 0...10)
    private var nextBlink: Double = 0
    private var blinkUntil: Double = 0
    private var eyeOverride: EyeShape? = nil
    private var eyeOverrideUntil: Double = 0
    private var squash: CGFloat = 0
    private var squashVel: CGFloat = 0

    func setState(_ new: BotState, force: Bool = false) {
        guard force || new != state else { return }
        state = new
        look = MascotLook.of(new)
        if !force { kick(0.12) }
    }

    func triggerEmote(_ emote: BotEmote) {
        switch emote {
        case .love, .happy, .proud:  eyeOverride = .happy
        case .wink:                  eyeOverride = .wink
        case .surprised, .listening: eyeOverride = .wide
        case .yawn:                  eyeOverride = .closed
        case .annoyed:               eyeOverride = .line
        }
        eyeOverrideUntil = time + 1.4
        kick(0.18)
    }

    func slap() { kick(0.3) }
    func blink() { blinkUntil = time + 0.14 }

    /// A small squash that springs back.
    private func kick(_ amount: CGFloat) { squashVel = amount * 9 }

    /// One animation step of `dt` seconds.
    func update(dt: Double) {
        time += dt
        if time > nextBlink {
            blink()
            nextBlink = time + 2.5 + Double.random(in: 0...3)
        }
        let target = components(bodyColor ?? look.color)
        let k: CGFloat = 0.18
        color = (color.0 + (target.0 - color.0) * k,
                 color.1 + (target.1 - color.1) * k,
                 color.2 + (target.2 - color.2) * k)
        // Damped spring for the squash.
        squashVel += (-squash * 60 - squashVel * 7) * CGFloat(dt)
        squash += squashVel * CGFloat(dt)
    }

    private func components(_ c: CGColor) -> (CGFloat, CGFloat, CGFloat) {
        let comps = c.components ?? [0.5, 0.5, 0.5]
        if comps.count >= 3 { return (comps[0], comps[1], comps[2]) }
        return (comps[0], comps[0], comps[0])
    }

    // MARK: - Drawing

    func draw(context: GraphicsContext, size: CGSize) {
        var ctx = context
        let R = min(size.width / 1.3, size.height / 1.0) / 2 * (isMini ? 1.05 : 0.9)
        let breathe = CGFloat(sin(time * 2)) * 0.015
        let bounce: CGFloat = look.bounce ? -abs(CGFloat(sin(time * 7))) * 0.12 : 0
        let sx = 1 + squash * 0.5 + breathe
        let sy = 1 - squash * 0.5 - breathe

        ctx.translateBy(x: size.width / 2, y: size.height / 2 + R * (0.04 + bounce))
        ctx.scaleBy(x: sx, y: sy)

        let body = Color(.sRGB, red: color.0, green: color.1, blue: color.2, opacity: 1)
        let dark = Color(.sRGB, red: color.0 * 0.72, green: color.1 * 0.72, blue: color.2 * 0.72, opacity: 1)
        let light = Color(.sRGB, red: min(1, color.0 + 0.25), green: min(1, color.1 + 0.25),
                          blue: min(1, color.2 + 0.25), opacity: 1)

        // Tail fin (right), waving a little.
        let wave = CGFloat(sin(time * 3.2)) * 0.12
        var tail = Path()
        tail.move(to: CGPoint(x: R * 0.78, y: R * 0.05))
        tail.addQuadCurve(to: CGPoint(x: R * 1.18, y: -R * (0.42 + wave)), control: CGPoint(x: R * 1.12, y: R * 0.12))
        tail.addQuadCurve(to: CGPoint(x: R * 0.98, y: -R * 0.05), control: CGPoint(x: R * 1.0, y: -R * (0.3 + wave)))
        tail.addQuadCurve(to: CGPoint(x: R * 1.18, y: R * 0.32), control: CGPoint(x: R * 1.22, y: R * 0.05))
        tail.addQuadCurve(to: CGPoint(x: R * 0.78, y: R * 0.22), control: CGPoint(x: R * 0.98, y: R * 0.28))
        tail.closeSubpath()
        ctx.fill(tail, with: .color(dark))

        // Body: a squircle, wider than tall.
        let bodyRect = CGRect(x: -R, y: -R * 0.62, width: R * 2, height: R * 1.24)
        let bodyPath = Path(roundedRect: bodyRect, cornerRadius: R * 0.62, style: .continuous)
        ctx.fill(bodyPath, with: .linearGradient(Gradient(colors: [light, body, dark]),
                                                  startPoint: CGPoint(x: 0, y: -R * 0.62),
                                                  endPoint: CGPoint(x: 0, y: R * 0.62)))
        // Belly.
        var belly = ctx
        belly.clip(to: bodyPath)
        belly.fill(Path(ellipseIn: CGRect(x: -R * 1.1, y: R * 0.18, width: R * 2.2, height: R * 0.9)),
                   with: .color(.white.opacity(0.28)))

        // Eyes follow the pointer a little.
        let ex = lookX * R * 0.07
        let eyeY = -R * 0.06 + lookY * R * 0.05
        let shape = (time < eyeOverrideUntil ? eyeOverride : nil) ?? look.eye
        let blinking = time < blinkUntil && shape == .dot
        drawEye(&ctx, shape: blinking ? .line : shape, at: CGPoint(x: -R * 0.3 + ex, y: eyeY), R: R, second: false)
        drawEye(&ctx, shape: blinking ? .line : shape, at: CGPoint(x: R * 0.12 + ex, y: eyeY), R: R, second: true)

        // Spout.
        if look.spout {
            for i in 0..<3 {
                let phase = (time * 0.9 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let h = CGFloat(phase) * R * 0.9
                let drift = CGFloat(i - 1) * R * 0.14 * CGFloat(phase)
                let r = R * 0.09 * CGFloat(1 - phase * 0.6)
                ctx.fill(Path(ellipseIn: CGRect(x: -R * 0.2 + drift - r, y: -R * 0.68 - h - r, width: r * 2, height: r * 2)),
                         with: .color(light.opacity(1 - phase)))
            }
        }

        // Badge.
        if let badge = look.badge, !isMini {
            ctx.fill(Path(ellipseIn: CGRect(x: R * 0.5, y: -R * 1.0, width: R * 0.62, height: R * 0.62)), with: .color(dark))
            ctx.draw(Text(badge).font(.system(size: R * 0.5, weight: .heavy, design: .rounded)).foregroundColor(.white),
                     at: CGPoint(x: R * 0.81, y: -R * 0.69))
        }
    }

    private func drawEye(_ ctx: inout GraphicsContext, shape: EyeShape, at p: CGPoint, R: CGFloat, second: Bool) {
        let ink = Color(red: 0.08, green: 0.09, blue: 0.12)
        let w = R * 0.13, h = R * 0.19
        let stroke = StrokeStyle(lineWidth: R * 0.05, lineCap: .round)
        switch shape {
        case .dot:
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)), with: .color(ink))
        case .wide:
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - w * 0.8, y: p.y - h * 0.8, width: w * 1.6, height: h * 1.6)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - w * 0.4, y: p.y - h * 0.4, width: w * 0.8, height: h * 0.8)), with: .color(ink))
        case .line, .tired:
            var l = Path()
            l.move(to: CGPoint(x: p.x - w * 0.8, y: p.y))
            l.addLine(to: CGPoint(x: p.x + w * 0.8, y: p.y + (shape == .tired ? h * 0.15 : 0)))
            ctx.stroke(l, with: .color(ink), style: stroke)
        case .closed:
            var a = Path()
            a.addArc(center: CGPoint(x: p.x, y: p.y - h * 0.2), radius: w * 0.8,
                     startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            ctx.stroke(a, with: .color(ink), style: stroke)
        case .happy:
            var a = Path()
            a.addArc(center: CGPoint(x: p.x, y: p.y + h * 0.35), radius: w * 0.85,
                     startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
            ctx.stroke(a, with: .color(ink), style: stroke)
        case .wink:
            drawEye(&ctx, shape: second ? .happy : .dot, at: p, R: R, second: second)
        case .cross:
            var x = Path()
            x.move(to: CGPoint(x: p.x - w * 0.7, y: p.y - w * 0.7)); x.addLine(to: CGPoint(x: p.x + w * 0.7, y: p.y + w * 0.7))
            x.move(to: CGPoint(x: p.x + w * 0.7, y: p.y - w * 0.7)); x.addLine(to: CGPoint(x: p.x - w * 0.7, y: p.y + w * 0.7))
            ctx.stroke(x, with: .color(ink), style: stroke)
        }
    }
}
