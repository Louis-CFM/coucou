import SwiftUI
import CoreGraphics

// MARK: - Shared eye-position helper

/// Projects both eyes to body-local screen space (same formula as BotEngine.drawEyes).
/// Returns one entry per visible eye: (ex, ey) = center in body-space, (fx, fy) = foreshortening.
func mochiEyePositions(yaw: CGFloat, pitch: CGFloat, rx: CGFloat, ry: CGFloat)
    -> [(ex: CGFloat, ey: CGFloat, fx: CGFloat, fy: CGFloat)] {
    var result: [(ex: CGFloat, ey: CGFloat, fx: CGFloat, fy: CGFloat)] = []
    for sd: Double in [-1.0, 1.0] {
        let eyeYaw = CGFloat(sd) * MochiConst.eyeSp + yaw
        var eyePitch = MochiConst.eyeP + pitch
        eyePitch = ((eyePitch + .pi).truncatingRemainder(dividingBy: .pi * 2) + .pi * 2)
            .truncatingRemainder(dividingBy: .pi * 2) - .pi
        let cp = cos(eyePitch)
        guard cos(eyeYaw) * cp > 0.04 else { continue }
        let ex = sin(eyeYaw) * cp * rx
        let ey = -sin(eyePitch) * ry
        let fx = max(0.18, cos(eyeYaw))
        let fy = max(0.18, cp)
        result.append((ex: ex, ey: ey, fx: fx, fy: fy))
    }
    return result
}

// MARK: - Body transform

/// Replicates the same coordinate space as BotEngine.draw(): translate → rotate → scale.
func outfitBodyTransform(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                          tilt: CGFloat, sx: CGFloat, sy: CGFloat) -> GraphicsContext {
    var ctx = context
    ctx.translateBy(x: cx, y: cy)
    if tilt != 0 { ctx.rotate(by: .radians(tilt)) }
    ctx.scaleBy(x: sx, y: sy)
    return ctx
}

// MARK: - Front dispatcher (after body draw)

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
    if outfit == .bunnyEars { return }

    let morphFade = 1 - min(1, max(0, (morph - 0.3) / 0.2))
    let rollFade  = 1 - min(1, max(0, (abs(roll) - 1.2) / 0.5))
    let opacity   = morphFade * rollFade
    guard opacity > 0.01 else { return }

    var ctx = outfitBodyTransform(context: context, cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy)
    ctx.opacity = Double(opacity)

    switch outfit {
    case .partyHat:
        guard R > 14 else { return }
        drawPartyHatFront(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw, sy: sy)
    case .beanie:
        guard R > 14 else { return }
        drawBeanie(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw, sy: sy)
    case .crown:
        guard R > 14 else { return }
        drawCrown(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    case .witchHat:
        guard R > 14 else { return }
        drawWitchHatFront(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    case .santaHat:
        guard R > 14 else { return }
        drawSantaHatFront(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw, sy: sy)
    case .bow:
        guard R > 14 else { return }
        drawBow(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    case .sunglasses:
        drawSunglasses(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw, pitch: pitch)
    case .roundGlasses:
        drawRoundGlasses(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw, pitch: pitch)
    case .scarf:
        drawScarf(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    case .pumpkin:
        drawPumpkinDetails(ctx: &ctx, R: R, rx: rx, ry: ry)
    default:
        break
    }
}

// MARK: - Behind dispatcher (before body draw)

func drawOutfitBehindStatic(
    context: GraphicsContext,
    outfit: Outfit,
    cx: CGFloat, cy: CGFloat,
    tilt: CGFloat, sx: CGFloat, sy: CGFloat,
    yaw: CGFloat, roll: CGFloat, morph: CGFloat,
    R: CGFloat, rx: CGFloat, ry: CGFloat,
    isMini: Bool
) {
    guard !isMini, outfit != .none, outfit != .auto else { return }
    guard [Outfit.bunnyEars, .partyHat, .witchHat, .santaHat].contains(outfit) else { return }

    let morphFade = 1 - min(1, max(0, (morph - 0.3) / 0.2))
    let rollFade  = 1 - min(1, max(0, (abs(roll) - 1.2) / 0.5))
    let opacity   = morphFade * rollFade
    guard opacity > 0.01 else { return }

    var ctx = outfitBodyTransform(context: context, cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy)
    ctx.opacity = Double(opacity)

    switch outfit {
    case .bunnyEars:
        guard R > 14 else { return }
        drawBunnyEars(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    case .partyHat:
        guard R > 14 else { return }
        drawPartyHatBrim(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    case .witchHat:
        guard R > 14 else { return }
        drawWitchHatBrim(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    case .santaHat:
        guard R > 14 else { return }
        drawSantaHatBrim(ctx: &ctx, R: R, rx: rx, ry: ry, yaw: yaw)
    default:
        break
    }
}

// MARK: - Hat mount helpers

/// y-position of the hat's brim plane in body-space (negative = upward, inside head).
private func hatBrimY(ry: CGFloat) -> CGFloat { -ry * 0.78 }

/// x-shift of hat center following head yaw.
private func hatXS(rx: CGFloat, yaw: CGFloat) -> CGFloat { sin(yaw) * rx * 0.35 }

/// Foreshortened brim half-width.
private func hatBrimW(rx: CGFloat, yaw: CGFloat, factor: CGFloat) -> CGFloat {
    rx * factor * abs(cos(yaw))
}

// MARK: - Party hat

private func drawPartyHatBrim(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let xS = hatXS(rx: rx, yaw: yaw)
    let bW = hatBrimW(rx: rx, yaw: yaw, factor: 1.10)
    let bH = bW * 0.20
    let bY = hatBrimY(ry: ry)
    var brim = Path()
    brim.addEllipse(in: CGRect(x: xS - bW, y: bY - bH * 0.5, width: bW * 2, height: bH))
    ctx.fill(brim, with: .linearGradient(
        Gradient(colors: [Color(hex: "#F472B6"), Color(hex: "#DB2777")]),
        startPoint: CGPoint(x: xS, y: bY - bH * 0.5),
        endPoint:   CGPoint(x: xS, y: bY + bH * 0.5)
    ))
    ctx.fill(brim, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.black.opacity(0.14), location: 0),
            .init(color: .clear, location: 0.55)
        ]),
        startPoint: CGPoint(x: xS, y: bY - bH * 0.5),
        endPoint:   CGPoint(x: xS, y: bY + bH * 0.5)
    ))
}

private func drawPartyHatFront(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                                yaw: CGFloat, sy: CGFloat) {
    let xS   = hatXS(rx: rx, yaw: yaw)
    let bW   = hatBrimW(rx: rx, yaw: yaw, factor: 1.10)
    let bH   = bW * 0.20
    let bY   = hatBrimY(ry: ry)
    let cH   = min(R * 0.88, R * 0.9)     // cone height ≤ 0.9R
    let tipX = xS + sin(yaw) * R * 0.05
    let tipY = bY - cH

    // Puffy bezier cone
    let lBase = CGPoint(x: xS - bW * 0.88, y: bY)
    let rBase = CGPoint(x: xS + bW * 0.88, y: bY)
    var cone = Path()
    cone.move(to: CGPoint(x: tipX, y: tipY))
    cone.addCurve(to: lBase,
                  control1: CGPoint(x: tipX - bW * 0.30, y: bY - cH * 0.58),
                  control2: CGPoint(x: lBase.x + bW * 0.14, y: bY - cH * 0.25))
    cone.addLine(to: rBase)
    cone.addCurve(to: CGPoint(x: tipX, y: tipY),
                  control1: CGPoint(x: rBase.x - bW * 0.14, y: bY - cH * 0.25),
                  control2: CGPoint(x: tipX + bW * 0.30, y: bY - cH * 0.58))
    cone.closeSubpath()

    ctx.fill(cone, with: .linearGradient(
        Gradient(colors: [Color(hex: "#F472B6"), Color(hex: "#DB2777")]),
        startPoint: CGPoint(x: tipX - bW * 0.28, y: tipY),
        endPoint:   CGPoint(x: xS, y: bY)
    ))
    // Top-left highlight
    ctx.fill(cone, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.35), location: 0),
            .init(color: .clear, location: 1)
        ]),
        startPoint: CGPoint(x: xS - bW * 0.18, y: tipY),
        endPoint:   CGPoint(x: xS + bW * 0.38, y: bY)
    ))

    // White dots scattered on cone
    let dots: [(CGFloat, CGFloat)] = [(0.30, 0.55), (0.60, 0.34), (-0.20, 0.72)]
    for (tx, ty) in dots {
        let dX = outfitLerp(tipX, xS, ty) + bW * tx * 0.42 * abs(cos(yaw))
        let dY = outfitLerp(tipY, bY - R * 0.04, ty)
        let dR = R * 0.055
        var d = Path()
        d.addEllipse(in: CGRect(x: dX - dR, y: dY - dR, width: dR * 2, height: dR * 2))
        ctx.fill(d, with: .color(Color.white.opacity(0.82)))
    }

    // Brim front face (top half, in front of body)
    var brimCtx = ctx
    brimCtx.clip(to: Path(CGRect(x: xS - bW - 2, y: bY - bH,
                                  width: bW * 2 + 4, height: bH)))
    var brim = Path()
    brim.addEllipse(in: CGRect(x: xS - bW, y: bY - bH * 0.5, width: bW * 2, height: bH))
    brimCtx.fill(brim, with: .linearGradient(
        Gradient(colors: [Color(hex: "#F472B6"), Color(hex: "#DB2777")]),
        startPoint: CGPoint(x: xS, y: bY - bH * 0.5),
        endPoint:   CGPoint(x: xS, y: bY + bH * 0.5)
    ))

    // Round white pompom at tip (spring with sy)
    let pR = R * 0.18 + (sy - 1) * R * 0.10
    var pom = Path()
    pom.addEllipse(in: CGRect(x: tipX - pR, y: tipY - pR * 1.30, width: pR * 2, height: pR * 2))
    ctx.fill(pom, with: .color(.white))
    ctx.fill(pom, with: .radialGradient(
        Gradient(stops: [
            .init(color: .clear, location: 0.50),
            .init(color: Color.black.opacity(0.10), location: 1)
        ]),
        center: CGPoint(x: tipX, y: tipY - pR * 0.40),
        startRadius: 0, endRadius: pR * 1.30
    ))
}

// MARK: - Beanie

private func drawBeanie(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                         yaw: CGFloat, sy: CGFloat) {
    let xS   = hatXS(rx: rx, yaw: yaw)
    let bW   = rx * 1.05 * abs(cos(yaw))
    let bY   = -ry + R * 0.04
    let capH = R * 0.76
    let ribH = R * 0.20

    // Cap body (puffy rounded top)
    var cap = Path()
    cap.addRoundedRect(
        in: CGRect(x: xS - bW, y: bY - capH, width: bW * 2, height: capH + ribH),
        cornerSize: CGSize(width: bW * 0.55, height: bW * 0.55)
    )
    ctx.fill(cap, with: .linearGradient(
        Gradient(colors: [Color(hex: "#93C5FD"), Color(hex: "#3B82F6")]),
        startPoint: CGPoint(x: xS - bW * 0.28, y: bY - capH),
        endPoint:   CGPoint(x: xS + bW * 0.28, y: bY)
    ))
    // Top-left highlight
    ctx.fill(cap, with: .radialGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.38), location: 0),
            .init(color: .clear, location: 1)
        ]),
        center: CGPoint(x: xS - bW * 0.32, y: bY - capH * 0.65),
        startRadius: 0, endRadius: bW * 0.72
    ))

    // Ribbed cuff band at bottom
    var band = Path()
    band.addRoundedRect(
        in: CGRect(x: xS - bW, y: bY - ribH, width: bW * 2, height: ribH + R * 0.06),
        cornerSize: CGSize(width: R * 0.06, height: R * 0.06)
    )
    ctx.fill(band, with: .color(Color(hex: "#1D4ED8")))
    // Rib texture (3 lines)
    for t: CGFloat in [0.28, 0.56, 0.82] {
        let lineY = (bY - ribH) + ribH * t
        var rib = Path()
        rib.move(to: CGPoint(x: xS - bW + R * 0.06, y: lineY))
        rib.addLine(to: CGPoint(x: xS + bW - R * 0.06, y: lineY))
        ctx.stroke(rib, with: .color(Color(hex: "#1E40AF").opacity(0.55)),
                   style: StrokeStyle(lineWidth: R * 0.035, lineCap: .round))
    }

    // White pompom (springs vertically with sy)
    let pR = R * 0.22 + (sy - 1) * R * 0.14
    let pY = bY - capH - R * 0.08 + (sy - 1) * R * 0.06
    var pom = Path()
    pom.addEllipse(in: CGRect(x: xS - pR, y: pY - pR, width: pR * 2, height: pR * 2))
    ctx.fill(pom, with: .color(.white))
    ctx.fill(pom, with: .radialGradient(
        Gradient(stops: [
            .init(color: .clear, location: 0.50),
            .init(color: Color.black.opacity(0.08), location: 1)
        ]),
        center: CGPoint(x: xS, y: pY - pR * 0.32),
        startRadius: 0, endRadius: pR * 1.12
    ))
}

// MARK: - Crown

private func drawCrown(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let xS    = hatXS(rx: rx, yaw: yaw)
    let bW    = rx * 1.05 * abs(cos(yaw))
    let bY    = -ry + R * 0.03
    let baseH = R * 0.14
    let ptH   = R * 0.56           // center point height
    let sideH = ptH * 0.70         // side points shorter

    // Base band (gold)
    var base = Path()
    base.addRoundedRect(
        in: CGRect(x: xS - bW, y: bY - baseH, width: bW * 2, height: baseH + R * 0.06),
        cornerSize: CGSize(width: R * 0.06, height: R * 0.06)
    )
    ctx.fill(base, with: .linearGradient(
        Gradient(colors: [Color(hex: "#FCD34D"), Color(hex: "#F59E0B")]),
        startPoint: CGPoint(x: xS, y: bY - baseH),
        endPoint:   CGPoint(x: xS, y: bY)
    ))

    // 3 rounded arch points
    let ptDefs: [(x: CGFloat, h: CGFloat)] = [
        (-0.55, sideH), (0.0, ptH), (0.55, sideH)
    ]
    for (tx, ph) in ptDefs {
        let px = xS + tx * bW
        let hw = bW * 0.22
        var pt = Path()
        pt.move(to: CGPoint(x: px - hw, y: bY - baseH))
        pt.addCurve(
            to: CGPoint(x: px + hw, y: bY - baseH),
            control1: CGPoint(x: px - hw, y: bY - baseH - ph * 1.05),
            control2: CGPoint(x: px + hw, y: bY - baseH - ph * 1.05)
        )
        pt.closeSubpath()
        ctx.fill(pt, with: .linearGradient(
            Gradient(colors: [Color(hex: "#FCD34D"), Color(hex: "#F59E0B")]),
            startPoint: CGPoint(x: px, y: bY - baseH - ph),
            endPoint:   CGPoint(x: px, y: bY - baseH)
        ))
    }

    // Base band highlight
    ctx.fill(base, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.30), location: 0),
            .init(color: .clear, location: 1)
        ]),
        startPoint: CGPoint(x: xS, y: bY - baseH),
        endPoint:   CGPoint(x: xS, y: bY)
    ))

    // 3 pearls between the points
    for px: CGFloat in [xS - bW * 0.27, xS, xS + bW * 0.27] {
        let pr = R * 0.078
        var pearl = Path()
        pearl.addEllipse(in: CGRect(x: px - pr, y: bY - baseH - pr * 1.10,
                                     width: pr * 2, height: pr * 2))
        ctx.fill(pearl, with: .color(Color.white.opacity(0.92)))
        ctx.fill(pearl, with: .radialGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: Color.black.opacity(0.18), location: 1)
            ]),
            center: CGPoint(x: px + pr * 0.18, y: bY - baseH - pr * 0.9),
            startRadius: 0, endRadius: pr * 1.10
        ))
    }
}

// MARK: - Witch hat

private func drawWitchHatBrim(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let xS = hatXS(rx: rx, yaw: yaw)
    let bW = hatBrimW(rx: rx, yaw: yaw, factor: 1.35)
    let bH = bW * 0.18
    let bY = hatBrimY(ry: ry)
    var brim = Path()
    brim.addEllipse(in: CGRect(x: xS - bW, y: bY - bH * 0.5, width: bW * 2, height: bH))
    ctx.fill(brim, with: .linearGradient(
        Gradient(colors: [Color(hex: "#4C1D95"), Color(hex: "#3B0764")]),
        startPoint: CGPoint(x: xS, y: bY - bH * 0.5),
        endPoint:   CGPoint(x: xS, y: bY + bH * 0.5)
    ))
}

private func drawWitchHatFront(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let xS    = hatXS(rx: rx, yaw: yaw)
    let bW    = hatBrimW(rx: rx, yaw: yaw, factor: 1.35)
    let bH    = bW * 0.18
    let bY    = hatBrimY(ry: ry)
    let coneW = rx * 0.72 * abs(cos(yaw))
    let coneH = min(R * 1.08, R * 1.10)    // ≤ 1.1R

    // Droopy tip (leans to one side)
    let droopX = xS + sin(yaw) * R * 0.07 + cos(yaw) * R * 0.13
    let tipY   = bY - coneH

    // Cone (bezier for slight droop)
    let cL = CGPoint(x: xS - coneW, y: bY)
    let cR = CGPoint(x: xS + coneW, y: bY)
    var cone = Path()
    cone.move(to: CGPoint(x: droopX, y: tipY))
    cone.addCurve(to: cL,
                  control1: CGPoint(x: droopX - coneW * 0.38, y: bY - coneH * 0.55),
                  control2: CGPoint(x: cL.x + coneW * 0.18, y: bY - coneH * 0.22))
    cone.addLine(to: cR)
    cone.addCurve(to: CGPoint(x: droopX, y: tipY),
                  control1: CGPoint(x: cR.x - coneW * 0.18, y: bY - coneH * 0.22),
                  control2: CGPoint(x: droopX + coneW * 0.38, y: bY - coneH * 0.55))
    cone.closeSubpath()

    ctx.fill(cone, with: .linearGradient(
        Gradient(colors: [Color(hex: "#6D28D9"), Color(hex: "#4C1D95")]),
        startPoint: CGPoint(x: droopX - coneW * 0.22, y: tipY),
        endPoint:   CGPoint(x: xS, y: bY)
    ))
    // Left-side highlight
    ctx.fill(cone, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.18), location: 0),
            .init(color: .clear, location: 1)
        ]),
        startPoint: CGPoint(x: xS - coneW * 0.24, y: tipY + coneH * 0.08),
        endPoint:   CGPoint(x: xS + coneW * 0.30, y: bY)
    ))

    // Orange ribbon
    let ribT: CGFloat = 0.22
    let ribW  = coneW * (1 - ribT) * 0.82
    let ribY  = bY - coneH * ribT
    let ribH  = R * 0.13
    var ribbon = Path()
    ribbon.addRoundedRect(
        in: CGRect(x: xS - ribW, y: ribY - ribH * 0.5, width: ribW * 2, height: ribH),
        cornerSize: CGSize(width: R * 0.04, height: R * 0.04)
    )
    ctx.fill(ribbon, with: .color(Color(hex: "#F97316")))

    // Gold buckle
    let bkW = ribW * 0.44
    let bkH = ribH * 1.14
    var buckle = Path()
    buckle.addRoundedRect(
        in: CGRect(x: xS - bkW * 0.5, y: ribY - bkH * 0.5, width: bkW, height: bkH),
        cornerSize: CGSize(width: bkH * 0.26, height: bkH * 0.26)
    )
    ctx.fill(buckle, with: .color(Color(hex: "#F59E0B")))
    var hole = Path()
    hole.addRoundedRect(
        in: CGRect(x: xS - bkW * 0.28, y: ribY - bkH * 0.28, width: bkW * 0.56, height: bkH * 0.56),
        cornerSize: CGSize(width: bkH * 0.12, height: bkH * 0.12)
    )
    ctx.fill(hole, with: .color(Color(hex: "#3B0764")))

    // Brim front face (top-half arc)
    var brimCtx = ctx
    brimCtx.clip(to: Path(CGRect(x: xS - bW - 2, y: bY - bH, width: bW * 2 + 4, height: bH)))
    var brim = Path()
    brim.addEllipse(in: CGRect(x: xS - bW, y: bY - bH * 0.5, width: bW * 2, height: bH))
    brimCtx.fill(brim, with: .linearGradient(
        Gradient(colors: [Color(hex: "#6D28D9"), Color(hex: "#3B0764")]),
        startPoint: CGPoint(x: xS, y: bY - bH * 0.5),
        endPoint:   CGPoint(x: xS, y: bY + bH * 0.5)
    ))
}

// MARK: - Santa hat

private func drawSantaHatBrim(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let xS = hatXS(rx: rx, yaw: yaw)
    let bW = hatBrimW(rx: rx, yaw: yaw, factor: 1.12)
    let bH = R * 0.24
    let bY = hatBrimY(ry: ry)
    var band = Path()
    band.addEllipse(in: CGRect(x: xS - bW, y: bY - bH * 0.55, width: bW * 2, height: bH))
    ctx.fill(band, with: .color(.white))
    ctx.fill(band, with: .radialGradient(
        Gradient(stops: [
            .init(color: .clear, location: 0.50),
            .init(color: Color.black.opacity(0.06), location: 1)
        ]),
        center: CGPoint(x: xS, y: bY),
        startRadius: 0, endRadius: bW
    ))
}

private func drawSantaHatFront(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                                yaw: CGFloat, sy: CGFloat) {
    let xS  = hatXS(rx: rx, yaw: yaw)
    let bW  = hatBrimW(rx: rx, yaw: yaw, factor: 1.12)
    let bH  = R * 0.24
    let bY  = hatBrimY(ry: ry)
    let cH  = R * 0.86

    // Droopy tip (droops to side)
    let droopX = xS + sin(yaw) * R * 0.10 + R * 0.18
    let tipY   = bY - cH

    // Red cone
    let cL = CGPoint(x: xS - bW * 0.90, y: bY)
    let cR = CGPoint(x: xS + bW * 0.90, y: bY)
    var cone = Path()
    cone.move(to: CGPoint(x: droopX, y: tipY))
    cone.addCurve(to: cL,
                  control1: CGPoint(x: droopX - bW * 0.50, y: bY - cH * 0.60),
                  control2: CGPoint(x: cL.x + bW * 0.18, y: bY - cH * 0.26))
    cone.addLine(to: cR)
    cone.addCurve(to: CGPoint(x: droopX, y: tipY),
                  control1: CGPoint(x: cR.x - bW * 0.14, y: bY - cH * 0.22),
                  control2: CGPoint(x: droopX + bW * 0.50, y: bY - cH * 0.62))
    cone.closeSubpath()

    ctx.fill(cone, with: .linearGradient(
        Gradient(colors: [Color(hex: "#EF4444"), Color(hex: "#B91C1C")]),
        startPoint: CGPoint(x: droopX, y: tipY),
        endPoint:   CGPoint(x: xS, y: bY)
    ))
    ctx.fill(cone, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.30), location: 0),
            .init(color: .clear, location: 1)
        ]),
        startPoint: CGPoint(x: xS - bW * 0.35, y: bY - cH * 0.75),
        endPoint:   CGPoint(x: xS + bW * 0.28, y: bY)
    ))

    // White base band front face
    var brimCtx = ctx
    brimCtx.clip(to: Path(CGRect(x: xS - bW - 2, y: bY - bH, width: bW * 2 + 4, height: bH)))
    var band = Path()
    band.addEllipse(in: CGRect(x: xS - bW, y: bY - bH * 0.55, width: bW * 2, height: bH))
    brimCtx.fill(band, with: .color(.white))

    // White pompom at tip (springs with sy)
    let pR = R * 0.21 + (sy - 1) * R * 0.12
    var pom = Path()
    pom.addEllipse(in: CGRect(x: droopX - pR, y: tipY - pR * 1.22, width: pR * 2, height: pR * 2))
    ctx.fill(pom, with: .color(.white))
    ctx.fill(pom, with: .radialGradient(
        Gradient(stops: [
            .init(color: .clear, location: 0.50),
            .init(color: Color.black.opacity(0.08), location: 1)
        ]),
        center: CGPoint(x: droopX, y: tipY - pR * 0.40),
        startRadius: 0, endRadius: pR * 1.22
    ))
}

// MARK: - Bunny ears (behind body)

private func drawBunnyEars(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let earHW = R * 0.22
    let earH  = R * 0.85
    let earSep = rx * 0.52
    let earY  = -ry - earH * 0.65
    let xS    = hatXS(rx: rx, yaw: yaw)

    for sd: CGFloat in [-1.0, 1.0] {
        let ex = xS + sd * earSep * abs(cos(yaw))
        var outer = Path()
        outer.addEllipse(in: CGRect(x: ex - earHW, y: earY, width: earHW * 2, height: earH))
        ctx.fill(outer, with: .color(Color(hex: "#F9F0F0")))
        ctx.stroke(outer, with: .color(Color.black.opacity(0.06)), lineWidth: 0.8)
        var inner = Path()
        inner.addEllipse(in: CGRect(x: ex - earHW * 0.50, y: earY + R * 0.10,
                                    width: earHW, height: earH * 0.65))
        ctx.fill(inner, with: .color(Color(hex: "#FCA5A5").opacity(0.70)))
    }
}

// MARK: - Bow

private func drawBow(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let xS = hatXS(rx: rx, yaw: yaw)
    let bY = -ry + R * 0.04
    let w  = R * 0.56 * abs(cos(yaw))
    let h  = R * 0.38

    var left = Path()
    left.move(to: CGPoint(x: xS, y: bY))
    left.addQuadCurve(to: CGPoint(x: xS - w, y: bY - h * 0.50),
                      control: CGPoint(x: xS - w, y: bY - h))
    left.addQuadCurve(to: CGPoint(x: xS, y: bY),
                      control: CGPoint(x: xS - w, y: bY + h * 0.50))
    left.closeSubpath()

    var right = Path()
    right.move(to: CGPoint(x: xS, y: bY))
    right.addQuadCurve(to: CGPoint(x: xS + w, y: bY - h * 0.50),
                       control: CGPoint(x: xS + w, y: bY - h))
    right.addQuadCurve(to: CGPoint(x: xS, y: bY),
                       control: CGPoint(x: xS + w, y: bY + h * 0.50))
    right.closeSubpath()

    ctx.fill(left,  with: .color(Color(hex: "#F472B6")))
    ctx.fill(right, with: .color(Color(hex: "#F472B6")))
    ctx.fill(left, with: .linearGradient(
        Gradient(stops: [.init(color: Color.white.opacity(0.28), location: 0), .init(color: .clear, location: 0.65)]),
        startPoint: CGPoint(x: xS - w, y: bY - h * 0.70), endPoint: CGPoint(x: xS, y: bY)
    ))
    ctx.fill(right, with: .linearGradient(
        Gradient(stops: [.init(color: Color.white.opacity(0.18), location: 0), .init(color: .clear, location: 0.65)]),
        startPoint: CGPoint(x: xS + w, y: bY - h * 0.70), endPoint: CGPoint(x: xS, y: bY)
    ))

    var knot = Path()
    knot.addEllipse(in: CGRect(x: xS - R * 0.11, y: bY - R * 0.13, width: R * 0.22, height: R * 0.22))
    ctx.fill(knot, with: .color(Color(hex: "#EC4899")))
}

// MARK: - Sunglasses (anchored to actual eye positions)

private func drawSunglasses(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                              yaw: CGFloat, pitch: CGFloat) {
    let eyes = mochiEyePositions(yaw: yaw, pitch: pitch, rx: rx, ry: ry)
    guard eyes.count == 2 else { return }
    let ew = R * MochiConst.eyeW * 2.30    // lens width ≈ 2.3× eye size
    let eh = R * MochiConst.eyeH * 1.12

    for eye in eyes {
        let lW = ew * eye.fx
        let lH = eh * eye.fy
        var lens = Path()
        lens.addRoundedRect(
            in: CGRect(x: eye.ex - lW * 0.50, y: eye.ey - lH * 0.55, width: lW, height: lH),
            cornerSize: CGSize(width: lW * 0.30, height: lH * 0.30)
        )
        ctx.fill(lens, with: .color(Color(red: 0.10, green: 0.09, blue: 0.08).opacity(0.85)))
        ctx.stroke(lens, with: .color(Color(hex: "#292524")), lineWidth: 1.2)
        // Subtle glare
        var shine = Path()
        shine.addEllipse(in: CGRect(x: eye.ex - lW * 0.36, y: eye.ey - lH * 0.45,
                                    width: lW * 0.38, height: lH * 0.28))
        ctx.fill(shine, with: .color(Color.white.opacity(0.20)))
    }

    // Bridge
    let l = eyes[0], r = eyes[1]
    let bY = (l.ey + r.ey) * 0.5 - eh * 0.05
    var bridge = Path()
    bridge.move(to: CGPoint(x: l.ex + ew * l.fx * 0.50, y: bY))
    bridge.addLine(to: CGPoint(x: r.ex - ew * r.fx * 0.50, y: bY))
    ctx.stroke(bridge, with: .color(Color(hex: "#292524")), lineWidth: 1.4)
}

// MARK: - Round glasses (anchored to actual eye positions)

private func drawRoundGlasses(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat,
                                yaw: CGFloat, pitch: CGFloat) {
    let eyes = mochiEyePositions(yaw: yaw, pitch: pitch, rx: rx, ry: ry)
    guard eyes.count == 2 else { return }
    let baseR = R * MochiConst.eyeW * 1.10

    for eye in eyes {
        let r = baseR * max(eye.fx, eye.fy)
        var ring = Path()
        ring.addEllipse(in: CGRect(x: eye.ex - r, y: eye.ey - r * 0.92, width: r * 2, height: r * 1.84))
        ctx.stroke(ring, with: .color(Color(hex: "#92400E")), lineWidth: max(1.5, R * 0.05))
        ctx.fill(ring, with: .color(Color(hex: "#92400E").opacity(0.08)))
    }

    let l = eyes[0], r = eyes[1]
    let lR = baseR * max(l.fx, l.fy)
    let rR = baseR * max(r.fx, r.fy)
    var bridge = Path()
    bridge.move(to: CGPoint(x: l.ex + lR, y: l.ey))
    bridge.addLine(to: CGPoint(x: r.ex - rR, y: r.ey))
    ctx.stroke(bridge, with: .color(Color(hex: "#92400E")), lineWidth: max(1.5, R * 0.05))
}

// MARK: - Scarf (thinner, lower)

private func drawScarf(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, yaw: CGFloat) {
    let scarfY = ry * 0.55
    let scarfH = ry * 0.22
    let bW     = rx * 1.06

    var wrap = Path()
    wrap.addRoundedRect(
        in: CGRect(x: -bW, y: scarfY - scarfH * 0.50, width: bW * 2, height: scarfH),
        cornerSize: CGSize(width: scarfH * 0.50, height: scarfH * 0.50)
    )
    ctx.fill(wrap, with: .linearGradient(
        Gradient(colors: [Color(hex: "#EF4444"), Color(hex: "#B91C1C")]),
        startPoint: CGPoint(x: 0, y: scarfY - scarfH * 0.50),
        endPoint:   CGPoint(x: 0, y: scarfY + scarfH * 0.50)
    ))

    // Two wide white stripes
    for ty: CGFloat in [0.30, 0.70] {
        let sY = scarfY - scarfH * 0.50 + scarfH * ty
        let sH = scarfH * 0.15
        var stripe = Path()
        stripe.addRect(CGRect(x: -bW, y: sY - sH * 0.50, width: bW * 2, height: sH))
        ctx.fill(stripe, with: .color(Color.white.opacity(0.52)))
    }

    // Small fringe (follows yaw slightly)
    let fX = bW * 0.55 + sin(yaw) * R * 0.08
    var fringe = Path()
    fringe.addRoundedRect(
        in: CGRect(x: fX - R * 0.10, y: scarfY - scarfH * 0.44, width: R * 0.20, height: scarfH * 1.32),
        cornerSize: CGSize(width: R * 0.05, height: R * 0.05)
    )
    ctx.fill(fringe, with: .color(Color(hex: "#EF4444")))
    ctx.stroke(wrap, with: .color(Color.black.opacity(0.07)), lineWidth: 0.8)
}

// MARK: - Pumpkin details

private func drawPumpkinDetails(ctx: inout GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat) {
    // 4 soft vertical ribs (gradient, not lines)
    for ribX: CGFloat in [-rx * 0.50, -rx * 0.16, rx * 0.16, rx * 0.50] {
        var rib = Path()
        rib.addRoundedRect(
            in: CGRect(x: ribX - R * 0.065, y: -ry * 0.78, width: R * 0.13, height: ry * 1.56),
            cornerSize: CGSize(width: R * 0.065, height: R * 0.065)
        )
        ctx.fill(rib, with: .color(Color(hex: "#EA580C").opacity(0.12)))
    }

    // Curved green stem
    let stemX: CGFloat = R * 0.04
    let stemY = -ry + R * 0.01
    var stem = Path()
    stem.move(to: CGPoint(x: stemX, y: stemY))
    stem.addCurve(
        to: CGPoint(x: stemX - R * 0.04, y: stemY - R * 0.28),
        control1: CGPoint(x: stemX + R * 0.09, y: stemY - R * 0.10),
        control2: CGPoint(x: stemX + R * 0.05, y: stemY - R * 0.22)
    )
    ctx.stroke(stem, with: .color(Color(hex: "#15803D")), lineWidth: R * 0.12)

    // Leaf
    var leaf = Path()
    leaf.move(to: CGPoint(x: stemX - R * 0.04, y: stemY - R * 0.22))
    leaf.addQuadCurve(to: CGPoint(x: stemX + R * 0.28, y: stemY - R * 0.10),
                      control: CGPoint(x: stemX + R * 0.40, y: stemY - R * 0.32))
    leaf.addQuadCurve(to: CGPoint(x: stemX - R * 0.04, y: stemY - R * 0.22),
                      control: CGPoint(x: stemX + R * 0.09, y: stemY - R * 0.04))
    ctx.fill(leaf, with: .color(Color(hex: "#16A34A")))
}

// MARK: - Math helper

private func outfitLerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
