import SwiftUI
import CoreGraphics

// MARK: - Main character choice

enum BotCharacter: String, CaseIterable, Identifiable {
    case mochi
    case cat

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mochi: return "Mochi"
        case .cat:   return "Orange cat"
        }
    }
}

private enum CatPalette {
    static let furTop    = Color(red: 1.000, green: 0.702, blue: 0.318)   // #FFB351
    static let furBottom = Color(red: 0.937, green: 0.451, blue: 0.106)   // #EF731B
    static let stripe    = Color(red: 0.741, green: 0.325, blue: 0.055)   // #BD530E
    static let cream     = Color(red: 1.000, green: 0.945, blue: 0.863)   // #FFF1DC
    static let innerEar  = Color(red: 1.000, green: 0.706, blue: 0.659)   // #FFB4A8
    static let nose      = Color(red: 0.910, green: 0.475, blue: 0.541)   // #E8798A
    static let mouth     = Color(red: 0.353, green: 0.165, blue: 0.098)   // #5A2A19
}

// MARK: - Cat drawing (main bot only; Mochi drawing is untouched)

extension BotEngine {

    var isCatActive: Bool { character == .cat && !isMini && bodyColor == nil }

    /// Ears and tail — drawn before the body so the body covers their roots.
    func drawCatBehind(ctx: GraphicsContext, R: CGFloat) {
        let fade = 1 - min(1, morph * 2)
        guard fade > 0.01 else { return }
        var c = ctx
        c.opacity = Double(fade)

        let now = CGFloat(CACurrentMediaTime())
        let droop: CGFloat = (state == .sleeping) ? 0.16 : 0
        let lean = sin(yaw) * 0.10 * R
        // A short ear flick every few seconds
        let flick = pow(max(0, sin(now * 0.8)), 24) * 0.07 * R

        for sd in [-1.0, 1.0] {
            let s = CGFloat(sd)
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: s * x * R, y: y * R) }

            let tipShift = (sd > 0 ? flick : 0)
            var outer = Path()
            outer.move(to: pt(1.00, -0.42))
            outer.addLine(to: CGPoint(x: s * 0.84 * R + lean + s * droop * R * 0.4, y: (-1.22 + droop) * R + tipShift))
            outer.addLine(to: pt(0.26, -0.84))
            outer.closeSubpath()

            var inner = Path()
            inner.move(to: pt(0.84, -0.56))
            inner.addLine(to: CGPoint(x: s * 0.77 * R + lean + s * droop * R * 0.4, y: (-1.00 + droop) * R + tipShift))
            inner.addLine(to: pt(0.44, -0.80))
            inner.closeSubpath()

            let style = StrokeStyle(lineWidth: R * 0.14, lineCap: .round, lineJoin: .round)
            c.stroke(outer, with: .color(CatPalette.furBottom), style: style)
            c.fill(outer, with: .linearGradient(
                Gradient(colors: [CatPalette.furTop, CatPalette.furBottom]),
                startPoint: CGPoint(x: 0, y: -1.2 * R), endPoint: CGPoint(x: 0, y: -0.4 * R)))
            c.stroke(inner, with: .color(CatPalette.innerEar), style: StrokeStyle(lineWidth: R * 0.08, lineCap: .round, lineJoin: .round))
            c.fill(inner, with: .color(CatPalette.innerEar))
        }

        // Tail on the right, wagging
        let wag = sin(now * (state == .sleeping ? 0.9 : 2.6)) * 0.14 * R
        var tail = Path()
        tail.move(to: CGPoint(x: 0.82 * R, y: 0.50 * R))
        tail.addQuadCurve(to: CGPoint(x: 1.34 * R + wag * 0.4, y: -0.06 * R + wag),
                          control: CGPoint(x: 1.46 * R, y: 0.62 * R))
        c.stroke(tail, with: .color(CatPalette.stripe), style: StrokeStyle(lineWidth: R * 0.30, lineCap: .round))
        c.stroke(tail, with: .color(CatPalette.furBottom), style: StrokeStyle(lineWidth: R * 0.22, lineCap: .round))
    }

    /// Orange fur with tabby stripes. State colour is kept as a light tint so states stay readable.
    func drawCatBody(ctx: GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        var c = ctx
        c.fill(path, with: .linearGradient(
            Gradient(colors: [CatPalette.furTop, CatPalette.furBottom]),
            startPoint: CGPoint(x: rx * 0.5, y: -ry * 0.9),
            endPoint: CGPoint(x: -rx * 0.4, y: ry * 0.95)))

        let effectiveTint = tint * (1 - morph) * 0.4
        if effectiveTint > 0.01 {
            let tc = Color(red: col.0, green: col.1, blue: col.2)
            c.fill(path, with: .linearGradient(
                Gradient(stops: [.init(color: tc.opacity(Double(effectiveTint)), location: 0),
                                 .init(color: tc.opacity(0), location: 1)]),
                startPoint: CGPoint(x: 0, y: ry), endPoint: CGPoint(x: 0, y: -ry)))
        }

        if morph < 0.5 {
            var s = c
            s.clip(to: path)
            s.opacity = Double(1 - morph * 2)
            let dx = sin(yaw) * rx * 0.5
            // Forehead stripes
            for i in -1...1 {
                let x = CGFloat(i) * 0.26 * R + dx
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: -ry * 1.02))
                stripe.addQuadCurve(to: CGPoint(x: x + CGFloat(i) * 0.03 * R, y: -ry * 0.46),
                                    control: CGPoint(x: x + CGFloat(i) * 0.08 * R, y: -ry * 0.74))
                s.stroke(stripe, with: .color(CatPalette.stripe.opacity(0.85)),
                         style: StrokeStyle(lineWidth: R * 0.09, lineCap: .round))
            }
            // Cheek stripes
            for sd in [-1.0, 1.0] {
                for j in 0..<2 {
                    let y = ry * (0.10 + CGFloat(j) * 0.20)
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: CGFloat(sd) * rx * 1.02 + dx, y: y))
                    stripe.addLine(to: CGPoint(x: CGFloat(sd) * rx * 0.80 + dx, y: y + ry * 0.05))
                    s.stroke(stripe, with: .color(CatPalette.stripe.opacity(0.85)),
                             style: StrokeStyle(lineWidth: R * 0.08, lineCap: .round))
                }
            }
        }

        c.fill(path, with: .radialGradient(
            Gradient(stops: [.init(color: .clear, location: 0),
                             .init(color: .clear, location: 0.6),
                             .init(color: Color.black.opacity(0.18), location: 1)]),
            center: .zero, startRadius: R * 0.15, endRadius: R * 1.25))
        c.fill(path, with: .radialGradient(
            Gradient(stops: [.init(color: Color.white.opacity(0.35), location: 0),
                             .init(color: .clear, location: 1)]),
            center: CGPoint(x: rx * 0.34, y: -ry * 0.46), startRadius: 0, endRadius: R * 0.42))
    }

    /// Cream muzzle, nose and mouth (before the eyes) — clipped to the body.
    func drawCatMuzzle(ctx: GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard morph < 0.5 else { return }
        var c = ctx
        c.clip(to: path)
        c.opacity = Double(1 - morph * 2)
        let dx = sin(yaw) * rx * 0.85
        let dy = -sin(pitch + roll) * ry * 0.35
        let squash = max(0.45, cos(yaw))

        var muzzle = Path()
        muzzle.addEllipse(in: CGRect(x: dx - 0.34 * R * squash, y: dy + 0.24 * R, width: 0.68 * R * squash, height: 0.46 * R))
        c.fill(muzzle, with: .color(CatPalette.cream))

        var nose = Path()
        let nx = dx, ny = dy + 0.34 * R, nw = 0.10 * R * squash
        nose.move(to: CGPoint(x: nx - nw, y: ny))
        nose.addLine(to: CGPoint(x: nx + nw, y: ny))
        nose.addLine(to: CGPoint(x: nx, y: ny + 0.08 * R))
        nose.closeSubpath()
        c.fill(nose, with: .color(CatPalette.nose))
        c.stroke(nose, with: .color(CatPalette.nose), style: StrokeStyle(lineWidth: R * 0.03, lineJoin: .round))

        var mouth = Path()
        let my = ny + 0.08 * R
        mouth.move(to: CGPoint(x: nx, y: my))
        mouth.addLine(to: CGPoint(x: nx, y: my + 0.05 * R))
        mouth.addQuadCurve(to: CGPoint(x: nx - 0.13 * R * squash, y: my + 0.06 * R),
                           control: CGPoint(x: nx - 0.06 * R * squash, y: my + 0.14 * R))
        mouth.move(to: CGPoint(x: nx, y: my + 0.05 * R))
        mouth.addQuadCurve(to: CGPoint(x: nx + 0.13 * R * squash, y: my + 0.06 * R),
                           control: CGPoint(x: nx + 0.06 * R * squash, y: my + 0.14 * R))
        c.stroke(mouth, with: .color(CatPalette.mouth),
                 style: StrokeStyle(lineWidth: max(1, R * 0.025), lineCap: .round))
    }

    /// Whiskers extend past the body, so they use the unclipped context (after the eyes).
    func drawCatWhiskers(ctx: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard morph < 0.3 else { return }
        var c = ctx
        c.opacity = Double(1 - morph / 0.3)
        let dx = sin(yaw) * rx * 0.85
        let dy = -sin(pitch + roll) * ry * 0.35
        let now = CGFloat(CACurrentMediaTime())
        for sd in [-1.0, 1.0] {
            for i in 0..<3 {
                let s = CGFloat(sd)
                let y0 = dy + (0.42 + CGFloat(i) * 0.07) * R
                let twitch = sin(now * 1.7 + CGFloat(i)) * 0.012 * R
                var w = Path()
                w.move(to: CGPoint(x: dx + s * 0.30 * R, y: y0))
                w.addLine(to: CGPoint(x: dx + s * 0.98 * R, y: y0 + (CGFloat(i) - 1) * 0.09 * R + twitch))
                c.stroke(w, with: .color(Color.white.opacity(0.9)),
                         style: StrokeStyle(lineWidth: max(1, R * 0.02), lineCap: .round))
            }
        }
    }
}
