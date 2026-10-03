import SwiftUI
import CoreGraphics

// MARK: - Outfit property on BotEngine

extension BotEngine {
    // Stored with objc associated object to avoid modifying BotEngine.swift
    // Instead we'll add a simple stored property via a wrapper — but since BotEngine is a class,
    // we just add it directly in this extension using a computed wrapper backed by a static dict.
    // Actually for Swift, stored properties in extensions aren't allowed.
    // So we use a trick: a static NSMapTable or we just put it in the class.
    // We'll patch BotEngine.swift to add the property.
}

// MARK: - Outfit drawing helpers (free functions, callable from static preview too)

/// Computes the body-space context transform matching BotEngine.draw().
/// Call this to replicate the same coordinate space for accessory drawing.
func outfitBodyTransform(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                          tilt: CGFloat, sx: CGFloat, sy: CGFloat) -> GraphicsContext {
    var ctx = context
    ctx.translateBy(x: cx, y: cy)
    if tilt != 0 { ctx.rotate(by: .radians(tilt)) }
    ctx.scaleBy(x: sx, y: sy)
    return ctx
}

/// Draw outfit accessories that go ABOVE the body (hats, glasses, bow, scarf, etc.)
/// Called after body is drawn. Context is in world space; we re-apply body transform.
func drawOutfitFrontStatic(
    context: GraphicsContext,
    outfit: Outfit,
    cx: CGFloat, cy: CGFloat,
    tilt: CGFloat, sx: CGFloat, sy: CGFloat,
    yaw: CGFloat, pitch: CGFloat, roll: CGFloat, morph: CGFloat,
    R: CGFloat, rx: CGFloat, ry: CGFloat,
    isMini: Bool, bodyColor: CGColor?
) {
    guard !isMini, outfit != .none, outfit != .auto else { return }
    // Skip behind-body outfit
    if outfit == .bunnyEars { return }

    // Fade out during mailbox morph, heavy roll, or when body is tiny
    let morphFade  = 1 - min(1, max(0, (morph - 0.3) / 0.2))
    let rollFade   = 1 - min(1, max(0, (abs(roll) - 1.2) / 0.5))
    let opacity    = morphFade * rollFade
    guard opacity > 0.01 else { return }

    var ctx = outfitBodyTransform(context: context, cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy)
    ctx.opacity = Double(opacity)

    // Hat x-shift follows yaw (head rotation); hat x-scale foreshortens
    let hatXShift  = sin(yaw) * rx * 0.28
    let hatXScale  = cos(yaw)

    // Eye-level y (same formula as drawEyes)
    let eyeY: CGFloat = sin(0.12) * ry   // ≈ 0.12 * ry slightly below center

    switch outfit {

    case .partyHat:
        guard R > 14 else { return }
        drawPartyHat(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale)

    case .beanie:
        guard R > 14 else { return }
        drawBeanie(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale, sy: sy)

    case .crown:
        guard R > 14 else { return }
        drawCrown(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale)

    case .topHat:
        guard R > 14 else { return }
        drawTopHat(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale)

    case .cap:
        guard R > 14 else { return }
        drawCap(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale, yaw: yaw)

    case .sunglasses:
        drawSunglasses(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: sin(yaw) * rx * 0.05, xScale: abs(cos(yaw)), eyeY: eyeY)

    case .roundGlasses:
        drawRoundGlasses(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: sin(yaw) * rx * 0.05, xScale: abs(cos(yaw)), eyeY: eyeY)

    case .bow:
        guard R > 14 else { return }
        drawBow(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale)

    case .scarf:
        drawScarf(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)

    case .witchHat:
        guard R > 14 else { return }
        drawWitchHat(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale)

    case .pumpkin:
        guard bodyColor == nil else { return }   // never recolor integration pills
        drawPumpkinDetails(ctx: &ctx, R: R, rx: rx, ry: ry)

    case .santaHat:
        guard R > 14 else { return }
        drawSantaHat(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale)

    case .heartsHeadband:
        guard R > 14 else { return }
        drawHeartsHeadband(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale)

    case .strawHat:
        guard R > 14 else { return }
        drawStrawHat(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift, xScale: hatXScale, yaw: yaw)

    default: break
    }
}

/// Draw outfit accessories that go BEHIND the body (bunnyEars).
/// Called before draw(). Context is world space.
func drawOutfitBehindStatic(
    context: GraphicsContext,
    outfit: Outfit,
    cx: CGFloat, cy: CGFloat,
    tilt: CGFloat, sx: CGFloat, sy: CGFloat,
    yaw: CGFloat, roll: CGFloat, morph: CGFloat,
    R: CGFloat, rx: CGFloat, ry: CGFloat,
    isMini: Bool
) {
    guard !isMini, outfit == .bunnyEars else { return }
    let morphFade = 1 - min(1, max(0, (morph - 0.3) / 0.2))
    let rollFade  = 1 - min(1, max(0, (abs(roll) - 1.2) / 0.5))
    let opacity   = morphFade * rollFade
    guard opacity > 0.01, R > 14 else { return }

    var ctx = outfitBodyTransform(context: context, cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy)
    ctx.opacity = Double(opacity)
    let hatXShift = sin(yaw) * rx * 0.28
    drawBunnyEars(ctx: &ctx, R: R, rx: rx, ry: ry, xShift: hatXShift)
}

// MARK: - Individual outfit drawers

private func drawPartyHat(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                           xShift: CGFloat, xScale: CGFloat) {
    let bW = rx * 0.95 * xScale    // brim width half
    let bH = R * 0.12              // brim height
    let bY = -ry + R * 0.02       // sits just on top of body

    // Brim (ellipse)
    var brim = Path()
    brim.addEllipse(in: CGRect(x: xShift - bW, y: bY - bH * 0.5, width: bW * 2, height: bH))
    ctx.fill(brim, with: .color(Color(hex: "#EC4899")))
    ctx.stroke(brim, with: .color(Color.black.opacity(0.08)), lineWidth: 1)

    // Cone (triangle)
    let tipX = xShift + sin(0) * R * 0.05
    let tipY = bY - R * 1.1
    var cone = Path()
    cone.move(to: CGPoint(x: tipX, y: tipY))
    cone.addLine(to: CGPoint(x: xShift - bW, y: bY))
    cone.addLine(to: CGPoint(x: xShift + bW, y: bY))
    cone.closeSubpath()
    ctx.fill(cone, with: .linearGradient(
        Gradient(colors: [Color(hex: "#F472B6"), Color(hex: "#EC4899")]),
        startPoint: CGPoint(x: tipX, y: tipY),
        endPoint: CGPoint(x: xShift, y: bY)
    ))
    ctx.stroke(cone, with: .color(Color.black.opacity(0.06)), lineWidth: 0.8)

    // Stripes on cone
    for i in 1...3 {
        let t = CGFloat(i) / 4.0
        let y = outfitLerp(tipY, bY, t)
        let hw = bW * t
        var stripe = Path()
        stripe.move(to: CGPoint(x: xShift - hw, y: y))
        stripe.addLine(to: CGPoint(x: xShift + hw, y: y))
        ctx.stroke(stripe, with: .color(Color.white.opacity(0.35)), lineWidth: R * 0.04)
    }

    // Star at tip
    let starS = R * 0.18
    var starCtx = ctx
    starCtx.translateBy(x: tipX, y: tipY - starS * 0.5)
    starCtx.fill(outfitStarShape(outer: starS, inner: starS * 0.42),
                 with: .color(Color(hex: "#FDE047")))
}

private func drawBeanie(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                         xShift: CGFloat, xScale: CGFloat, sy: CGFloat) {
    let bW  = rx * 1.05 * xScale
    let bY  = -ry + R * 0.08
    let bH  = R * 0.85

    // Main beanie body (rounded rect sitting on head)
    var cap = Path()
    cap.addRoundedRect(in: CGRect(x: xShift - bW, y: bY - bH, width: bW * 2, height: bH + R * 0.1),
                       cornerSize: CGSize(width: bW * 0.6, height: bW * 0.6))
    ctx.fill(cap, with: .linearGradient(
        Gradient(colors: [Color(hex: "#60A5FA"), Color(hex: "#3B82F6")]),
        startPoint: CGPoint(x: xShift, y: bY - bH),
        endPoint: CGPoint(x: xShift, y: bY)
    ))
    ctx.stroke(cap, with: .color(Color.black.opacity(0.08)), lineWidth: 1)

    // Rib band at bottom
    var band = Path()
    band.addRoundedRect(in: CGRect(x: xShift - bW, y: bY - R * 0.22, width: bW * 2, height: R * 0.22),
                        cornerSize: CGSize(width: R * 0.05, height: R * 0.05))
    ctx.fill(band, with: .color(Color(hex: "#2563EB")))

    // Pompon (bounces with sy — slight spring)
    let pomponY = bY - bH - R * 0.14 * sy
    let pomponR = R * 0.22
    var pompon = Path()
    pompon.addEllipse(in: CGRect(x: xShift - pomponR, y: pomponY - pomponR,
                                  width: pomponR * 2, height: pomponR * 2))
    ctx.fill(pompon, with: .color(.white))
    ctx.stroke(pompon, with: .color(Color.black.opacity(0.06)), lineWidth: 0.8)
}

private func drawCrown(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                        xShift: CGFloat, xScale: CGFloat) {
    let w   = rx * 1.1 * xScale
    let bY  = -ry + R * 0.04
    let h   = R * 0.5

    // Crown base
    var base = Path()
    base.addRect(CGRect(x: xShift - w, y: bY - R * 0.12, width: w * 2, height: R * 0.12))
    ctx.fill(base, with: .color(Color(hex: "#EAB308")))

    // Crown points (3 triangles)
    for i in 0..<3 {
        let t = CGFloat(i) / 2.0 - 0.5   // -0.5, 0, 0.5
        let px = xShift + t * w * 1.0
        var pt = Path()
        pt.move(to: CGPoint(x: px - w * 0.3, y: bY - R * 0.12))
        pt.addLine(to: CGPoint(x: px,         y: bY - h))
        pt.addLine(to: CGPoint(x: px + w * 0.3, y: bY - R * 0.12))
        pt.closeSubpath()
        ctx.fill(pt, with: .color(Color(hex: "#EAB308")))
    }

    // Gold outline
    var outline = Path()
    outline.move(to: CGPoint(x: xShift - w, y: bY))
    // left point
    outline.addLine(to: CGPoint(x: xShift - w * 0.68, y: bY - R * 0.12))
    outline.addLine(to: CGPoint(x: xShift - w * 0.5,  y: bY - h))
    outline.addLine(to: CGPoint(x: xShift - w * 0.18, y: bY - R * 0.12))
    // center point
    outline.addLine(to: CGPoint(x: xShift,             y: bY - h))
    outline.addLine(to: CGPoint(x: xShift + w * 0.18,  y: bY - R * 0.12))
    // right point
    outline.addLine(to: CGPoint(x: xShift + w * 0.5,  y: bY - h))
    outline.addLine(to: CGPoint(x: xShift + w * 0.68,  y: bY - R * 0.12))
    outline.addLine(to: CGPoint(x: xShift + w,         y: bY))
    ctx.stroke(outline, with: .color(Color(hex: "#CA8A04")), lineWidth: 1)

    // Gems: ruby center, sapphire sides
    for (dx, gemColor) in [(-w * 0.5, Color(hex: "#3B82F6")), (0.0, Color(hex: "#EF4444")), (w * 0.5, Color(hex: "#3B82F6"))] {
        var gem = Path()
        gem.addEllipse(in: CGRect(x: xShift + dx - R * 0.06, y: bY - R * 0.11, width: R * 0.12, height: R * 0.10))
        ctx.fill(gem, with: .color(gemColor))
    }
}

private func drawTopHat(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                         xShift: CGFloat, xScale: CGFloat) {
    let bW  = rx * 1.1 * xScale
    let brimW = bW * 1.35
    let bY  = -ry + R * 0.03
    let h   = R * 0.75

    // Hat body
    var body = Path()
    body.addRect(CGRect(x: xShift - bW, y: bY - h, width: bW * 2, height: h))
    ctx.fill(body, with: .linearGradient(
        Gradient(colors: [Color(hex: "#1C1917"), Color(hex: "#292524")]),
        startPoint: CGPoint(x: xShift, y: bY - h),
        endPoint: CGPoint(x: xShift, y: bY)
    ))

    // Brim
    var brim = Path()
    brim.addRoundedRect(in: CGRect(x: xShift - brimW, y: bY - R * 0.13, width: brimW * 2, height: R * 0.13),
                        cornerSize: CGSize(width: R * 0.05, height: R * 0.05))
    ctx.fill(brim, with: .color(Color(hex: "#1C1917")))

    // Hat band (dark red ribbon)
    var band = Path()
    band.addRect(CGRect(x: xShift - bW, y: bY - R * 0.22, width: bW * 2, height: R * 0.12))
    ctx.fill(band, with: .color(Color(hex: "#991B1B")))

    // Outline
    ctx.stroke(body, with: .color(Color.black.opacity(0.3)), lineWidth: 1)
    ctx.stroke(brim, with: .color(Color.black.opacity(0.2)), lineWidth: 0.8)

    // Highlight strip
    var highlight = Path()
    highlight.addRect(CGRect(x: xShift - bW + 2, y: bY - h + 3, width: R * 0.08, height: h - 4))
    ctx.fill(highlight, with: .color(Color.white.opacity(0.06)))
}

private func drawCap(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                      xShift: CGFloat, xScale: CGFloat, yaw: CGFloat) {
    let bW  = rx * 1.05 * xScale
    let bY  = -ry + R * 0.06
    let h   = R * 0.52

    // Cap dome
    var dome = Path()
    dome.addArc(center: CGPoint(x: xShift, y: bY - R * 0.05),
                radius: bW,
                startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
    dome.addLine(to: CGPoint(x: xShift + bW, y: bY))
    dome.addLine(to: CGPoint(x: xShift - bW, y: bY))
    dome.closeSubpath()
    ctx.fill(dome, with: .linearGradient(
        Gradient(colors: [Color(hex: "#E11D48"), Color(hex: "#BE123C")]),
        startPoint: CGPoint(x: xShift, y: bY - h),
        endPoint: CGPoint(x: xShift, y: bY)
    ))

    // Brim (only on the forward side, shifts with yaw)
    let brimDir = yaw >= 0 ? 1.0 : -1.0   // brim faces forward
    let brimX = xShift + CGFloat(brimDir) * bW * 0.6
    var brim = Path()
    brim.addRoundedRect(in: CGRect(x: brimX - bW * 0.7, y: bY - R * 0.1,
                                   width: bW * 1.4, height: R * 0.12),
                        cornerSize: CGSize(width: R * 0.04, height: R * 0.04))
    ctx.fill(brim, with: .color(Color(hex: "#9F1239")))
    ctx.stroke(brim, with: .color(Color.black.opacity(0.15)), lineWidth: 0.8)

    ctx.stroke(dome, with: .color(Color.black.opacity(0.08)), lineWidth: 1)

    // Button on top
    var btn = Path()
    btn.addEllipse(in: CGRect(x: xShift - R * 0.07, y: bY - h + R * 0.02,
                               width: R * 0.14, height: R * 0.1))
    ctx.fill(btn, with: .color(Color(hex: "#9F1239")))
}

private func drawSunglasses(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                              xShift: CGFloat, xScale: CGFloat, eyeY: CGFloat) {
    let lW  = R * MochiConst.eyeW * 1.6 * xScale    // lens half-width
    let lH  = R * MochiConst.eyeH * 0.9             // lens height
    let eyeSep = R * MochiConst.eyeSp * rx / R       // = MochiConst.eyeSp * rx

    // Tinted lenses at ~55% opacity so eyes show through
    for sd in [-1.0, 1.0] {
        let lx = xShift + CGFloat(sd) * eyeSep * xScale
        var lens = Path()
        lens.addRoundedRect(in: CGRect(x: lx - lW, y: eyeY - lH * 0.55,
                                       width: lW * 2, height: lH),
                            cornerSize: CGSize(width: lW * 0.35, height: lH * 0.35))
        ctx.fill(lens, with: .color(Color(hex: "#1C1917").opacity(0.55)))
        // Rim
        ctx.stroke(lens, with: .color(Color(hex: "#292524")), lineWidth: 1.2)
    }

    // Bridge
    let bridgeX1 = xShift - eyeSep * xScale + lW
    let bridgeX2 = xShift + eyeSep * xScale - lW
    var bridge = Path()
    bridge.move(to: CGPoint(x: bridgeX1, y: eyeY - lH * 0.1))
    bridge.addLine(to: CGPoint(x: bridgeX2, y: eyeY - lH * 0.1))
    ctx.stroke(bridge, with: .color(Color(hex: "#292524")), lineWidth: 1.5)

    // Lens highlight
    for sd in [-1.0, 1.0] {
        let lx = xShift + CGFloat(sd) * eyeSep * xScale
        var shine = Path()
        shine.addEllipse(in: CGRect(x: lx - lW * 0.5, y: eyeY - lH * 0.45,
                                    width: lW * 0.5, height: lH * 0.28))
        ctx.fill(shine, with: .color(Color.white.opacity(0.22)))
    }
}

private func drawRoundGlasses(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                                xShift: CGFloat, xScale: CGFloat, eyeY: CGFloat) {
    let lR  = R * MochiConst.eyeW * 0.85 * xScale   // lens radius
    let eyeSep = MochiConst.eyeSp * rx

    for sd in [-1.0, 1.0] {
        let lx = xShift + CGFloat(sd) * eyeSep * xScale
        var ring = Path()
        ring.addEllipse(in: CGRect(x: lx - lR, y: eyeY - lR * 0.9,
                                   width: lR * 2, height: lR * 1.8))
        ctx.stroke(ring, with: .color(Color(hex: "#92400E")), lineWidth: 1.5)
    }

    // Bridge
    let bridgeX1 = xShift - eyeSep * xScale + lR
    let bridgeX2 = xShift + eyeSep * xScale - lR
    var bridge = Path()
    bridge.move(to: CGPoint(x: bridgeX1, y: eyeY))
    bridge.addLine(to: CGPoint(x: bridgeX2, y: eyeY))
    ctx.stroke(bridge, with: .color(Color(hex: "#92400E")), lineWidth: 1.5)
}

private func drawBow(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                      xShift: CGFloat, xScale: CGFloat) {
    let bY  = -ry + R * 0.04
    let w   = R * 0.52 * xScale
    let h   = R * 0.34

    // Left wing
    var left = Path()
    left.move(to: CGPoint(x: xShift, y: bY))
    left.addQuadCurve(to: CGPoint(x: xShift - w, y: bY - h * 0.5),
                      control: CGPoint(x: xShift - w, y: bY - h))
    left.addQuadCurve(to: CGPoint(x: xShift, y: bY),
                      control: CGPoint(x: xShift - w, y: bY + h * 0.5))
    left.closeSubpath()

    // Right wing
    var right = Path()
    right.move(to: CGPoint(x: xShift, y: bY))
    right.addQuadCurve(to: CGPoint(x: xShift + w, y: bY - h * 0.5),
                       control: CGPoint(x: xShift + w, y: bY - h))
    right.addQuadCurve(to: CGPoint(x: xShift, y: bY),
                       control: CGPoint(x: xShift + w, y: bY + h * 0.5))
    right.closeSubpath()

    ctx.fill(left,  with: .color(Color(hex: "#F472B6")))
    ctx.fill(right, with: .color(Color(hex: "#F472B6")))
    ctx.stroke(left,  with: .color(Color.black.opacity(0.08)), lineWidth: 0.8)
    ctx.stroke(right, with: .color(Color.black.opacity(0.08)), lineWidth: 0.8)

    // Knot in center
    var knot = Path()
    knot.addEllipse(in: CGRect(x: xShift - R * 0.1, y: bY - R * 0.1,
                                width: R * 0.2, height: R * 0.2))
    ctx.fill(knot, with: .color(Color(hex: "#EC4899")))
}

private func drawScarf(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let scarfY = ry * 0.28   // lower body
    let bW     = rx * 1.08
    let scarfH = R * 0.28

    // Main wrap
    var wrap = Path()
    wrap.addRoundedRect(in: CGRect(x: -bW, y: scarfY - scarfH * 0.5,
                                   width: bW * 2, height: scarfH),
                        cornerSize: CGSize(width: scarfH * 0.5, height: scarfH * 0.5))
    ctx.fill(wrap, with: .linearGradient(
        Gradient(colors: [Color(hex: "#EF4444"), Color(hex: "#DC2626")]),
        startPoint: CGPoint(x: 0, y: scarfY - scarfH * 0.5),
        endPoint: CGPoint(x: 0, y: scarfY + scarfH * 0.5)
    ))

    // Stripe
    var stripe = Path()
    stripe.addRect(CGRect(x: -bW, y: scarfY - scarfH * 0.1, width: bW * 2, height: scarfH * 0.2))
    ctx.fill(stripe, with: .color(Color.white.opacity(0.35)))

    // Fringe end (hangs to the right, follows yaw slightly)
    let fX  = bW * 0.6 + sin(yaw) * R * 0.1
    var fringe = Path()
    fringe.addRoundedRect(in: CGRect(x: fX - R * 0.12, y: scarfY - scarfH * 0.4,
                                      width: R * 0.24, height: scarfH * 1.4),
                          cornerSize: CGSize(width: R * 0.06, height: R * 0.06))
    ctx.fill(fringe, with: .color(Color(hex: "#EF4444")))
    var fringe2 = Path()
    fringe2.addRoundedRect(in: CGRect(x: fX - R * 0.07, y: scarfY + scarfH * 0.3,
                                       width: R * 0.14, height: scarfH * 0.8),
                           cornerSize: CGSize(width: R * 0.04, height: R * 0.04))
    ctx.fill(fringe2, with: .color(Color(hex: "#DC2626")))

    ctx.stroke(wrap, with: .color(Color.black.opacity(0.08)), lineWidth: 0.8)
}

private func drawWitchHat(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                           xShift: CGFloat, xScale: CGFloat) {
    let bY  = -ry + R * 0.04
    let bW  = rx * 1.15 * xScale
    let bH  = R * 0.14
    let h   = R * 1.0

    // Brim
    var brim = Path()
    brim.addEllipse(in: CGRect(x: xShift - bW, y: bY - bH * 0.5, width: bW * 2, height: bH))
    ctx.fill(brim, with: .color(Color(hex: "#1C1917")))
    ctx.stroke(brim, with: .color(Color.black.opacity(0.2)), lineWidth: 0.8)

    // Cone
    let tipX = xShift + sin(0) * R * 0.08
    let tipY = bY - h
    var cone = Path()
    cone.move(to: CGPoint(x: tipX, y: tipY))
    cone.addLine(to: CGPoint(x: xShift - bW * 0.7, y: bY))
    cone.addLine(to: CGPoint(x: xShift + bW * 0.7, y: bY))
    cone.closeSubpath()
    ctx.fill(cone, with: .color(Color(hex: "#1C1917")))
    ctx.stroke(cone, with: .color(Color.black.opacity(0.15)), lineWidth: 0.8)

    // Golden buckle
    let buckleY = bY - h * 0.23
    let buckleW = bW * 0.38 * xScale
    let buckleH = R * 0.18
    var buckleOuter = Path()
    buckleOuter.addRoundedRect(in: CGRect(x: xShift - buckleW, y: buckleY - buckleH * 0.5,
                                          width: buckleW * 2, height: buckleH),
                               cornerSize: CGSize(width: buckleH * 0.3, height: buckleH * 0.3))
    ctx.fill(buckleOuter, with: .color(Color(hex: "#EAB308")))
    var buckleInner = Path()
    buckleInner.addRoundedRect(in: CGRect(x: xShift - buckleW * 0.58, y: buckleY - buckleH * 0.28,
                                           width: buckleW * 1.16, height: buckleH * 0.56),
                               cornerSize: CGSize(width: buckleH * 0.18, height: buckleH * 0.18))
    ctx.fill(buckleInner, with: .color(Color(hex: "#1C1917")))
}

// pumpkin: draws ribs + stem on the body (body color handled by drawBody override in BotEngine)
private func drawPumpkinDetails(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
    // Vertical ribs (3 light lines on body surface)
    for x in [-rx * 0.42, 0.0, rx * 0.42] {
        var rib = Path()
        rib.move(to: CGPoint(x: CGFloat(x), y: -ry * 0.8))
        rib.addLine(to: CGPoint(x: CGFloat(x), y: ry * 0.8))
        ctx.stroke(rib, with: .color(Color(hex: "#EA580C").opacity(0.45)), lineWidth: R * 0.06)
    }

    // Stem (green, on top)
    let stemX: CGFloat = R * 0.06
    let stemY = -ry + R * 0.02
    var stem = Path()
    stem.addRoundedRect(in: CGRect(x: stemX - R * 0.07, y: stemY - R * 0.28,
                                   width: R * 0.14, height: R * 0.28),
                        cornerSize: CGSize(width: R * 0.04, height: R * 0.04))
    ctx.fill(stem, with: .color(Color(hex: "#15803D")))

    // Leaf
    var leaf = Path()
    leaf.move(to: CGPoint(x: stemX + R * 0.07, y: stemY - R * 0.20))
    leaf.addQuadCurve(to: CGPoint(x: stemX + R * 0.32, y: stemY - R * 0.08),
                      control: CGPoint(x: stemX + R * 0.38, y: stemY - R * 0.28))
    leaf.addQuadCurve(to: CGPoint(x: stemX + R * 0.07, y: stemY - R * 0.20),
                      control: CGPoint(x: stemX + R * 0.12, y: stemY - R * 0.04))
    ctx.fill(leaf, with: .color(Color(hex: "#16A34A")))
}

private func drawSantaHat(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                           xShift: CGFloat, xScale: CGFloat) {
    let bY  = -ry + R * 0.04
    let bW  = rx * 1.1 * xScale
    let h   = R * 0.9

    // White band at base
    var band = Path()
    band.addEllipse(in: CGRect(x: xShift - bW, y: bY - R * 0.18, width: bW * 2, height: R * 0.18))
    ctx.fill(band, with: .color(.white))

    // Red cone
    let tipX = xShift + R * 0.15  // slight tilt to right
    let tipY = bY - h
    var cone = Path()
    cone.move(to: CGPoint(x: tipX, y: tipY))
    cone.addLine(to: CGPoint(x: xShift - bW, y: bY))
    cone.addLine(to: CGPoint(x: xShift + bW, y: bY))
    cone.closeSubpath()
    ctx.fill(cone, with: .linearGradient(
        Gradient(colors: [Color(hex: "#EF4444"), Color(hex: "#DC2626")]),
        startPoint: CGPoint(x: tipX, y: tipY),
        endPoint: CGPoint(x: xShift, y: bY)
    ))

    // Pompom
    let pomR = R * 0.2
    var pom = Path()
    pom.addEllipse(in: CGRect(x: tipX - pomR, y: tipY - pomR * 1.2,
                               width: pomR * 2, height: pomR * 2))
    ctx.fill(pom, with: .color(.white))
    ctx.stroke(pom, with: .color(Color.black.opacity(0.05)), lineWidth: 0.6)
}

private func drawBunnyEars(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                            xShift: CGFloat) {
    // Ears behind the body: two tall ovals poking above the head
    let earHW = R * 0.22
    let earH  = R * 0.85
    let earSep = rx * 0.52
    let earY  = -ry - earH * 0.65

    for sd in [-1.0, 1.0] {
        let ex = xShift + CGFloat(sd) * earSep

        // Outer ear
        var outer = Path()
        outer.addEllipse(in: CGRect(x: ex - earHW, y: earY, width: earHW * 2, height: earH))
        ctx.fill(outer, with: .color(Color(hex: "#F9F0F0")))
        ctx.stroke(outer, with: .color(Color.black.opacity(0.08)), lineWidth: 1)

        // Inner pink
        var inner = Path()
        inner.addEllipse(in: CGRect(x: ex - earHW * 0.5, y: earY + R * 0.1,
                                    width: earHW, height: earH * 0.65))
        ctx.fill(inner, with: .color(Color(hex: "#FCA5A5").opacity(0.7)))
    }
}

private func drawHeartsHeadband(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                                  xShift: CGFloat, xScale: CGFloat) {
    let bY  = -ry + R * 0.04
    let bW  = rx * 1.06 * xScale

    // Band
    var band = Path()
    band.addRoundedRect(in: CGRect(x: xShift - bW, y: bY - R * 0.14, width: bW * 2, height: R * 0.14),
                        cornerSize: CGSize(width: R * 0.04, height: R * 0.04))
    ctx.fill(band, with: .color(Color(hex: "#F472B6")))
    ctx.stroke(band, with: .color(Color.black.opacity(0.08)), lineWidth: 0.8)

    // Two hearts on top
    let heartS = R * 0.28
    for (dx, dy): (CGFloat, CGFloat) in [(-bW * 0.38, R * 0.06), (bW * 0.38, R * 0.06)] {
        var hCtx = ctx
        hCtx.translateBy(x: xShift + dx, y: bY - R * 0.22 + dy)
        hCtx.fill(outfitHeartShape(size: heartS), with: .color(Color(hex: "#F43F5E")))
        hCtx.stroke(outfitHeartShape(size: heartS),
                    with: .color(Color.black.opacity(0.08)), lineWidth: 0.6)
    }
}

private func drawStrawHat(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                           xShift: CGFloat, xScale: CGFloat, yaw: CGFloat) {
    let bY   = -ry + R * 0.03
    let bW   = rx * 1.25 * xScale  // brim is wider
    let hatW = rx * 1.0 * xScale
    let bH   = R * 0.12
    let h    = R * 0.38

    // Brim
    var brim = Path()
    brim.addEllipse(in: CGRect(x: xShift - bW, y: bY - bH * 0.5, width: bW * 2, height: bH))
    ctx.fill(brim, with: .color(Color(hex: "#D97706")))
    ctx.stroke(brim, with: .color(Color.black.opacity(0.1)), lineWidth: 0.8)

    // Crown
    var crown = Path()
    crown.addRoundedRect(in: CGRect(x: xShift - hatW, y: bY - h, width: hatW * 2, height: h + R * 0.04),
                         cornerSize: CGSize(width: hatW * 0.5, height: hatW * 0.5))
    ctx.fill(crown, with: .color(Color(hex: "#F59E0B")))
    ctx.stroke(crown, with: .color(Color.black.opacity(0.08)), lineWidth: 1)

    // Checkered band
    let bandY = bY - R * 0.18
    let bandH: CGFloat = R * 0.12
    let sqW  = R * 0.14
    let numSq = Int(hatW * 2 / sqW)
    for i in 0..<numSq {
        if i % 2 == 0 {
            let sqX = xShift - hatW + CGFloat(i) * sqW
            var sq = Path()
            sq.addRect(CGRect(x: sqX, y: bandY, width: sqW, height: bandH))
            ctx.fill(sq, with: .color(Color(hex: "#78350F")))
        }
    }
}

// MARK: - Shape helpers (local copies to avoid circular dependency)

private func outfitStarShape(outer ro: CGFloat, inner ri: CGFloat) -> Path {
    var p = Path()
    for i in 0..<10 {
        let r = i.isMultiple(of: 2) ? ro : ri
        let a = -.pi/2 + CGFloat(i) * .pi/5
        let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    p.closeSubpath()
    return p
}

private func outfitHeartShape(size s: CGFloat) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 0, y: s * 0.38))
    p.addCurve(to: CGPoint(x: 0, y: -s * 0.38),
               control1: CGPoint(x: -s * 1.05, y: -s * 0.15),
               control2: CGPoint(x: -s * 0.5,  y: -s * 0.95))
    p.addCurve(to: CGPoint(x: 0, y: s * 0.38),
               control1: CGPoint(x: s * 0.5,   y: -s * 0.95),
               control2: CGPoint(x: s * 1.05,  y: -s * 0.15))
    p.closeSubpath()
    return p
}

private func outfitLerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
