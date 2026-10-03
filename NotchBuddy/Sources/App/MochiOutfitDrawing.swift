import SwiftUI
import CoreGraphics

// MARK: - Constants (mirror JS)

private let kEXP: CGFloat = 2.7
private let kVIEW_TILT: CGFloat = -0.30
private let kACC_PITCH: CGFloat = 0.4
private let kEYE_W: CGFloat = 0.25
private let kEYE_H: CGFloat = 0.27
private let kEYE_SP: CGFloat = 0.37
private let kEYE_P: CGFloat = -0.12

// MARK: - MochiH  (head geometry + physics)

struct MochiH {
    let R, rx, ry: CGFloat
    let yaw, pitch: CGFloat
    let view: CGFloat      // = VIEW_TILT (-0.30)
    let physDx, physDy: CGFloat
    let roll: CGFloat

    init(R: CGFloat, yaw: CGFloat = 0, pitch: CGFloat = 0,
         physDx: CGFloat = 0, physDy: CGFloat = 0, roll: CGFloat = 0) {
        self.R = R
        self.rx = R * 1.14
        self.ry = R * 0.88
        self.yaw = yaw
        self.pitch = pitch
        self.view = kVIEW_TILT
        self.physDx = physDx
        self.physDy = physDy
        self.roll = roll
    }
}

// MARK: - EyeFrame  (replaces mochiEyePositions)

struct EyeFrame {
    let sd: CGFloat   // -1 left, +1 right
    let x, y: CGFloat
    let fx, fy: CGFloat
    let visible: Bool
    let w, h: CGFloat
}

func mEyeFrames(_ H: MochiH) -> [EyeFrame] {
    var out: [EyeFrame] = []
    for sdD: Double in [-1.0, 1.0] {
        let sd = CGFloat(sdD)
        let eyeYaw   = sd * kEYE_SP + H.yaw
        let eyePitch = kEYE_P + H.pitch
        let cp = cos(eyePitch)
        let visible = cos(eyeYaw) * cp > 0.04
        out.append(EyeFrame(
            sd: sd,
            x:  sin(eyeYaw) * cp * H.rx,
            y: -sin(eyePitch) * H.ry,
            fx: max(0.18, cos(eyeYaw)),
            fy: max(0.18, cp),
            visible: visible,
            w: H.R * kEYE_W,
            h: H.R * kEYE_H
        ))
    }
    return out
}

/// Backward-compat shim (used by existing callers that haven't been updated yet).
func mochiEyePositions(yaw: CGFloat, pitch: CGFloat, rx: CGFloat, ry: CGFloat)
    -> [(ex: CGFloat, ey: CGFloat, fx: CGFloat, fy: CGFloat)] {
    let H = MochiH(R: rx / 1.14, yaw: yaw, pitch: pitch)
    return mEyeFrames(H).filter { $0.visible }.map { (ex: $0.x, ey: $0.y, fx: $0.fx, fy: $0.fy) }
}

// MARK: - P3  (projected screen point with depth)

private struct P3 {
    let x, y, z: CGFloat
}

// MARK: - 3D helpers (faithful port)

// ringR(y) → radius of horizontal ring at head-local y
private func mRingR(_ y: CGFloat) -> CGFloat {
    let a = min(1, abs(y))
    return pow(1 - pow(a, kEXP), 1 / kEXP)
}

// rot(p, yaw, pitch) — rotate head-local (x right, y up, z viewer) by yaw then pitch
private func mRot3(_ p: (CGFloat, CGFloat, CGFloat), yaw: CGFloat, pitch: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    var (x, y, z) = p
    let cy = cos(yaw), sy = sin(yaw)
    let x1 = x * cy + z * sy
    let z1 = -x * sy + z * cy
    x = x1
    let cp = cos(pitch), sp = sin(pitch)
    let y2 = y * cp + z1 * sp
    let z2 = -y * sp + z1 * cp
    return (x, y2, z2)
}

// proj(H, p) — head-local -> screen (body space)
private func mProj(_ H: MochiH, _ p: (CGFloat, CGFloat, CGFloat)) -> P3 {
    let r = mRot3(p, yaw: H.yaw, pitch: H.view + H.pitch * kACC_PITCH)
    return P3(x: r.0 * H.rx, y: -r.1 * H.ry, z: r.2)
}

// surf(y, lon, s) — point on head surface at height y, longitude lon
private func mSurf(_ y: CGFloat, _ lon: CGFloat, _ s: CGFloat = 1) -> (CGFloat, CGFloat, CGFloat) {
    let r = mRingR(y) * s
    return (r * sin(lon), y, r * cos(lon))
}

// Shared: given projected ring points, return front arc ordered L→R via silhouette tangents
private func frontSilhouetteArc(_ pts: [P3]) -> [P3] {
    let n = pts.count
    guard n > 1 else { return pts }
    let minIdx = pts.indices.min(by: { pts[$0].x < pts[$1].x })!
    let maxIdx = pts.indices.max(by: { pts[$0].x < pts[$1].x })!
    guard minIdx != maxIdx else { return [pts[minIdx]] }
    // Arc A: minIdx→maxIdx going forward (+1 steps)
    var arcA: [P3] = []; var i = minIdx
    while true { arcA.append(pts[i]); if i == maxIdx { break }; i = (i+1)%n; if arcA.count > n { break } }
    // Arc B: minIdx→maxIdx going backward (-1 steps)
    var arcB: [P3] = []; i = minIdx
    while true { arcB.append(pts[i]); if i == maxIdx { break }; i = (i-1+n)%n; if arcB.count > n { break } }
    let zA = arcA.reduce(0) { $0+$1.z } / CGFloat(max(1, arcA.count))
    let zB = arcB.reduce(0) { $0+$1.z } / CGFloat(max(1, arcB.count))
    return zA >= zB ? arcA : arcB
}

// frontArc(H, y, s) — front arc of ring at height y, ordered left→right (silhouette tangent method)
private func mFrontArc(_ H: MochiH, y: CGFloat, s: CGFloat) -> [P3] {
    let n = 120
    let pts: [P3] = (0..<n).map { i in
        let lon = -.pi + CGFloat(i) / CGFloat(n) * 2 * .pi
        return mProj(H, mSurf(y, lon, s))
    }
    return frontSilhouetteArc(pts)
}

// proj with roll applied (for roll-following accessories)
private func mProjRoll(_ H: MochiH, _ p: (CGFloat, CGFloat, CGFloat)) -> P3 {
    let r = mRot3(p, yaw: H.yaw, pitch: H.view + H.pitch * kACC_PITCH + H.roll)
    return P3(x: r.0 * H.rx, y: -r.1 * H.ry, z: r.2)
}

// frontArc using roll projection (for scarf)
private func mFrontArcRoll(_ H: MochiH, y: CGFloat, s: CGFloat) -> [P3] {
    let n = 120
    let pts: [P3] = (0..<n).map { i in
        let lon = -.pi + CGFloat(i) / CGFloat(n) * 2 * .pi
        return mProjRoll(H, mSurf(y, lon, s))
    }
    return frontSilhouetteArc(pts)
}

// capClip(H, y, s) — path of the region ABOVE the front arc of ring y (what a cap covers)
private func mCapClip(_ H: MochiH, y: CGFloat, s: CGFloat, extraTop: CGFloat = 3) -> Path {
    let arc = mFrontArc(H, y: y, s: s)
    guard !arc.isEmpty else { return Path() }
    var p = Path()
    p.move(to: CGPoint(x: arc[0].x - H.rx, y: arc[0].y))
    for q in arc { p.addLine(to: CGPoint(x: q.x, y: q.y)) }
    p.addLine(to: CGPoint(x: arc.last!.x + H.rx, y: arc.last!.y))
    p.addLine(to: CGPoint(x:  H.rx * 2, y: -H.ry * extraTop))
    p.addLine(to: CGPoint(x: -H.rx * 2, y: -H.ry * extraTop))
    p.closeSubpath()
    return p
}

// frontRun — front arc of a CLOSED ring, ordered left→right (silhouette tangent method)
private func mFrontRun(_ ring: [P3]) -> [P3] {
    frontSilhouetteArc(ring)
}

// invert(p, H) — complement of path p inside a large rect, with evenodd fill
private func mInvert(_ p: Path, H: MochiH) -> Path {
    var q = Path()
    q.addRect(CGRect(x: -H.rx * 4, y: -H.ry * 4, width: H.rx * 8, height: H.ry * 8))
    q.addPath(p)
    return q
}

// mochiOutfitPath — clean superellipse (n=96), same exponent as JS mochiPath
func mochiOutfitPath(_ rx: CGFloat, _ ry: CGFloat) -> Path {
    let n = 96
    let e: CGFloat = 2.0 / kEXP
    var p = Path()
    for i in 0...n {
        let a = CGFloat(i) / CGFloat(n) * .pi * 2
        let ca = cos(a), sa = sin(a)
        let x = rx * (ca >= 0 ? pow(ca, e) : -pow(-ca, e))
        let y = ry * (sa >= 0 ? pow(sa, e) : -pow(-sa, e))
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
        else       { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

// ringPoints — all 120+1 projected points on ring (full circle, for frontRun)
private func mRingPoints(_ H: MochiH, y: CGFloat, s: CGFloat, n: Int = 72) -> [P3] {
    (0...n).map { i -> P3 in
        let lon = -.pi + CGFloat(i) / CGFloat(n) * 2 * .pi
        return mProj(H, mSurf(y, lon, s))
    }
}

// MARK: - pompom

private func drawPompom(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, r: CGFloat,
                         base: Color = .white,
                         shade: Color = Color(red: 0.835, green: 0.851, blue: 0.886)) {
    var g = ctx
    g.translateBy(x: x, y: y)
    // fluffy rim bumps
    let n = 11
    for i in 0..<n {
        let a = CGFloat(i) / CGFloat(n) * .pi * 2
        let br = r * (0.34 + 0.06 * sin(CGFloat(i) * 2.3))
        let bx = cos(a) * r * 0.78
        let by = sin(a) * r * 0.78
        var bump = Path()
        bump.addEllipse(in: CGRect(x: bx - br, y: by - br, width: br * 2, height: br * 2))
        g.fill(bump, with: .radialGradient(
            Gradient(stops: [.init(color: base, location: 0), .init(color: shade, location: 1)]),
            center: CGPoint(x: bx - br * 0.4, y: by - br * 0.5),
            startRadius: 0, endRadius: br * 1.3
        ))
    }
    var center = Path()
    center.addEllipse(in: CGRect(x: -r * 0.86, y: -r * 0.86, width: r * 0.86 * 2, height: r * 0.86 * 2))
    g.fill(center, with: .radialGradient(
        Gradient(stops: [
            .init(color: base,  location: 0),
            .init(color: base,  location: 0.7),
            .init(color: shade, location: 1)
        ]),
        center: CGPoint(x: -r * 0.3, y: -r * 0.35),
        startRadius: 0, endRadius: r * 1.05
    ))
}

// MARK: - fuzzyBand

private func drawFuzzyBand(_ ctx: inout GraphicsContext, arc: [P3], thick: CGFloat,
                            base: Color = .white,
                            shade: Color = Color(red: 0.855, green: 0.867, blue: 0.894)) {
    guard arc.count >= 2 else { return }
    // shade stroke
    var sp = Path()
    sp.move(to: CGPoint(x: arc[0].x, y: arc[0].y))
    for i in 1..<arc.count { sp.addLine(to: CGPoint(x: arc[i].x, y: arc[i].y)) }
    ctx.stroke(sp, with: .color(shade), style: StrokeStyle(lineWidth: thick, lineCap: .round, lineJoin: .round))
    // base stroke
    var bp = Path()
    bp.move(to: CGPoint(x: arc[0].x, y: arc[0].y))
    for i in 1..<arc.count { bp.addLine(to: CGPoint(x: arc[i].x, y: arc[i].y)) }
    ctx.stroke(bp, with: .color(base), style: StrokeStyle(lineWidth: thick * 0.78, lineCap: .round, lineJoin: .round))
    // bumps along the arc
    let step = max(2, arc.count / 16)
    for i in stride(from: 0, to: arc.count, by: step) {
        let q = arc[i]
        let r = thick * (0.32 + 0.1 * sin(CGFloat(i) * 1.7))
        var bump = Path()
        bump.addEllipse(in: CGRect(x: q.x - r, y: q.y - thick * 0.32 - r, width: r * 2, height: r * 2))
        ctx.fill(bump, with: .radialGradient(
            Gradient(stops: [.init(color: base, location: 0), .init(color: shade, location: 1)]),
            center: CGPoint(x: q.x - r * 0.3, y: q.y - thick * 0.35 - r * 0.3),
            startRadius: 0, endRadius: r * 1.2
        ))
    }
}

// MARK: - Body transform helper

func outfitBodyTransform(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                          tilt: CGFloat, sx: CGFloat, sy: CGFloat) -> GraphicsContext {
    var ctx = context
    ctx.translateBy(x: cx, y: cy)
    if tilt != 0 { ctx.rotate(by: .radians(tilt)) }
    ctx.scaleBy(x: sx, y: sy)
    return ctx
}

// MARK: - Front dispatcher

func drawOutfitFrontStatic(
    context: GraphicsContext,
    outfit: Outfit, H: MochiH,
    cx: CGFloat, cy: CGFloat, tilt: CGFloat, sx: CGFloat, sy: CGFloat,
    roll: CGFloat, morph: CGFloat, isMini: Bool,
    presence: CGFloat = 1, rollTurns: CGFloat = 1
) {
    guard !isMini, outfit != .none, outfit != .auto else { return }
    let morphFade = 1 - min(1, max(0, (morph - 0.3) / 0.2))
    guard morphFade > 0.01 else { return }

    // Roll-following (glasses, bow, scarf, pumpkin): skip front pass when z < 0 → behind pass handles it.
    // bunnyEars: always in behind pass; not in this set.
    switch outfit {
    case .sunglasses, .roundGlasses, .bow, .scarf, .pumpkin:
        if mProjRoll(H, (0, 0, 1)).z < 0 { return }
    default: break
    }

    // Opacity: opaque early so movement carries the transition; drawLayer prevents ghost overlaps.
    let p = presence
    let posP = Ease.back(p)
    let layerOpacity = Double(morphFade * min(1, p * 2.5))
    guard layerOpacity > 0.005 else { return }

    let simplified = H.R < 16
    let baseCtx = outfitBodyTransform(context: context, cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy)
    let bodyPath = mochiOutfitPath(H.rx, H.ry)

    // ── Hat fly-off during roll (beanie, santaHat, partyHat, crown, witchHat) ──────────────────
    let isHatType: Bool
    switch outfit {
    case .beanie, .santaHat, .partyHat, .crown, .witchHat: isHatType = true
    default: isHatType = false
    }
    if isHatType && abs(H.roll) > 0.01 {
        let u = min(1, abs(H.roll) / (2 * .pi * max(1, rollTurns)))
        let flyHeight = H.ry * 0.9 * sin(u * .pi)
        let flyDrift  = H.physDx * H.rx * 0.3 * sin(u * .pi)
        let spinAngle = 2 * CGFloat.pi * u
        // Pivot: approximate hat centre in body-space (between crown and hat body)
        let pivot: CGFloat = -H.ry * 1.4
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: flyDrift, y: -flyHeight)   // lift + drift
        c.translateBy(x: 0, y: pivot)               // to hat centre
        c.rotate(by: .radians(spinAngle))            // self-spin
        c.translateBy(x: 0, y: -pivot)              // back from hat centre
        c.drawLayer { lCtx in
            var l = lCtx
            switch outfit {
            case .beanie:
                drawBeaniesFront(ctx: &l, H: H, bodyPath: bodyPath, simplified: simplified)
            case .santaHat:
                drawSantaHatFront(ctx: &l, H: H, bodyPath: bodyPath)
            case .partyHat:
                drawPartyHatFront(ctx: &l, H: H, bodyPath: bodyPath, simplified: simplified)
            case .crown:
                var g = l; g.clip(to: bodyPath)
                g.clip(to: mCapClip(H, y: crownYb(H) - 0.1, s: 1))
                var g2 = g
                g2.clip(to: mInvert(mCapClip(H, y: crownYb(H), s: 1), H: H), style: FillStyle(eoFill: true))
                var shp = Path(); shp.addRect(CGRect(x: -H.rx*4, y: -H.ry*4, width: H.rx*8, height: H.ry*8))
                g2.fill(shp, with: .color(Color(red: 0.314, green: 0.196, blue: 0, opacity: 0.12)))
                drawCrownPart(ctx: &l, H: H, side: 1, simplified: simplified)
            case .witchHat:
                drawWitchHatFront(ctx: &l, H: H, bodyPath: bodyPath)
            default: break
            }
        }
        return
    }

    // ── Normal presence transitions (drawLayer eliminates ghost overlaps) ────────────────────────
    let hatScale = 0.85 + 0.15 * posP  // hats / crown: scale up as they settle

    switch outfit {
    case .beanie:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0); c.scaleBy(x: hatScale, y: hatScale)
        c.drawLayer { lCtx in var l = lCtx; drawBeaniesFront(ctx: &l, H: H, bodyPath: bodyPath, simplified: simplified) }

    case .santaHat:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0); c.scaleBy(x: hatScale, y: hatScale)
        c.drawLayer { lCtx in var l = lCtx; drawSantaHatFront(ctx: &l, H: H, bodyPath: bodyPath) }

    case .partyHat:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0); c.scaleBy(x: hatScale, y: hatScale)
        c.drawLayer { lCtx in var l = lCtx; drawPartyHatFront(ctx: &l, H: H, bodyPath: bodyPath, simplified: simplified) }

    case .crown:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0); c.scaleBy(x: hatScale, y: hatScale)
        c.drawLayer { lCtx in
            var l = lCtx
            var g = l; g.clip(to: bodyPath)
            g.clip(to: mCapClip(H, y: crownYb(H) - 0.1, s: 1))
            var g2 = g
            g2.clip(to: mInvert(mCapClip(H, y: crownYb(H), s: 1), H: H), style: FillStyle(eoFill: true))
            var shp = Path(); shp.addRect(CGRect(x: -H.rx*4, y: -H.ry*4, width: H.rx*8, height: H.ry*8))
            g2.fill(shp, with: .color(Color(red: 0.314, green: 0.196, blue: 0, opacity: 0.12)))
            drawCrownPart(ctx: &l, H: H, side: 1, simplified: simplified)
        }

    case .witchHat:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0); c.scaleBy(x: hatScale, y: hatScale)
        c.drawLayer { lCtx in var l = lCtx; drawWitchHatFront(ctx: &l, H: H, bodyPath: bodyPath) }

    case .sunglasses:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: (1 - p) * 0.25 * H.ry)
        c.drawLayer { lCtx in var l = lCtx; drawSunglassesFront(ctx: &l, H: H, bodyPath: bodyPath) }

    case .roundGlasses:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: (1 - p) * 0.25 * H.ry)
        c.drawLayer { lCtx in var l = lCtx; drawRoundGlassesFront(ctx: &l, H: H, bodyPath: bodyPath) }

    case .scarf:
        var c = baseCtx; c.opacity = layerOpacity
        c.translateBy(x: 0, y: (1 - p) * 0.3 * H.ry)
        c.drawLayer { lCtx in var l = lCtx; drawScarfFront(ctx: &l, H: H) }

    case .pumpkin:
        var c = baseCtx; c.opacity = layerOpacity
        c.drawLayer { lCtx in var l = lCtx; drawPumpkinFront(ctx: &l, H: H, bodyPath: bodyPath, simplified: simplified) }

    case .bow:
        var c = baseCtx; c.opacity = layerOpacity
        c.scaleBy(x: max(0.001, posP), y: max(0.001, posP))
        c.drawLayer { lCtx in var l = lCtx; drawBowFront(ctx: &l, H: H, bodyPath: bodyPath) }

    default:
        break
    }
}

// MARK: - Behind dispatcher

func drawOutfitBehindStatic(
    context: GraphicsContext,
    outfit: Outfit, H: MochiH,
    cx: CGFloat, cy: CGFloat, tilt: CGFloat, sx: CGFloat, sy: CGFloat,
    roll: CGFloat, morph: CGFloat, isMini: Bool,
    presence: CGFloat = 1, rollTurns: CGFloat = 1
) {
    guard !isMini, outfit != .none, outfit != .auto else { return }
    let morphFade = 1 - min(1, max(0, (morph - 0.3) / 0.2))
    guard morphFade > 0.01 else { return }

    let layerOpacity = Double(morphFade * min(1, presence * 2.5))
    guard layerOpacity > 0.005 else { return }

    let simplified = H.R < 16
    var ctx = outfitBodyTransform(context: context, cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy)
    let bodyPath = mochiOutfitPath(H.rx, H.ry)

    // Roll-following accessories (glasses, bow, scarf, pumpkin — not bunnyEars): behind when z < 0
    switch outfit {
    case .sunglasses, .roundGlasses, .bow, .scarf, .pumpkin:
        guard mProjRoll(H, (0, 0, 1)).z < 0 else { return }
        ctx.opacity = layerOpacity
        ctx.drawLayer { lCtx in
            var l = lCtx
            switch outfit {
            case .sunglasses:   drawSunglassesFront(ctx: &l, H: H, bodyPath: bodyPath)
            case .roundGlasses: drawRoundGlassesFront(ctx: &l, H: H, bodyPath: bodyPath)
            case .scarf:        drawScarfFront(ctx: &l, H: H)
            case .pumpkin:      drawPumpkinFront(ctx: &l, H: H, bodyPath: bodyPath, simplified: simplified)
            case .bow:          drawBowFront(ctx: &l, H: H, bodyPath: bodyPath)
            default: break
            }
        }
        return
    default: break
    }

    // Behind accessories: bunnyEars (always), crown back, witchHat back
    let posP = Ease.back(presence)
    let hatScale = 0.85 + 0.15 * posP
    let pivot: CGFloat = -H.ry * 1.4

    switch outfit {
    case .bunnyEars:
        // Always behind body; no 3D roll — ears flatten/tilt during roll.
        let u: CGFloat = abs(H.roll) > 0.01
            ? min(1, abs(H.roll) / (2 * .pi * max(1, rollTurns)))
            : 0
        var c = ctx; c.opacity = layerOpacity
        // Presence transition: descend from above (same as hats)
        c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0)
        c.scaleBy(x: hatScale, y: hatScale)
        c.drawLayer { lCtx in
            var l = lCtx
            drawBunnyEarsBack(ctx: &l, H: H, rollProgress: u)
        }

    case .crown:
        var c = ctx; c.opacity = layerOpacity
        if abs(H.roll) > 0.01 {
            let u = min(1, abs(H.roll) / (2 * .pi * max(1, rollTurns)))
            c.translateBy(x: H.physDx * H.rx * 0.3 * sin(u * .pi), y: -H.ry * 0.9 * sin(u * .pi))
            c.translateBy(x: 0, y: pivot); c.rotate(by: .radians(2 * .pi * u)); c.translateBy(x: 0, y: -pivot)
        } else {
            c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0); c.scaleBy(x: hatScale, y: hatScale)
        }
        c.drawLayer { lCtx in var l = lCtx; drawCrownPart(ctx: &l, H: H, side: -1, simplified: simplified) }

    case .witchHat:
        var c = ctx; c.opacity = layerOpacity
        if abs(H.roll) > 0.01 {
            let u = min(1, abs(H.roll) / (2 * .pi * max(1, rollTurns)))
            c.translateBy(x: H.physDx * H.rx * 0.3 * sin(u * .pi), y: -H.ry * 0.9 * sin(u * .pi))
            c.translateBy(x: 0, y: pivot); c.rotate(by: .radians(2 * .pi * u)); c.translateBy(x: 0, y: -pivot)
        } else {
            c.translateBy(x: 0, y: -(1 - posP) * H.ry * 1.0); c.scaleBy(x: hatScale, y: hatScale)
        }
        c.drawLayer { lCtx in var l = lCtx; drawWitchHatBack(ctx: &l, H: H) }

    default:
        break
    }
}

// MARK: - Crown geometry helper

private func crownYb(_ H: MochiH) -> CGFloat { 0.46 }

// MARK: - Bunny ears (behind body)

// rollProgress: 0 = upright, 1 = max roll (ears fully flattened). Drawn with mProj (no 3D roll).
private func drawBunnyEarsBack(ctx: inout GraphicsContext, H: MochiH, rollProgress: CGFloat = 0) {
    let R = H.R
    let earH = R * 0.85

    for sd: CGFloat in [-1.0, 1.0] {
        // Standard projection — ears do not follow 3D roll
        let earRoot  = mProj(H, (sd * 0.45, 0.92, 0))
        let earRootL = mProj(H, (sd * 0.45 - 0.22, 0.92, 0))
        let earRootR = mProj(H, (sd * 0.45 + 0.22, 0.92, 0))
        let visHW = max(R * 0.04, abs(earRootR.x - earRootL.x) / 2)

        // During roll: ears flatten (shrink height) and tilt outward
        let flatten  = sin(rollProgress * .pi)
        let effEarH  = earH * (1 - 0.8 * flatten)
        let tiltAngle = sd * 0.6 * flatten   // left ear tilts left, right tilts right

        let earCX = earRoot.x
        let earCY = earRoot.y - effEarH * 0.65 + effEarH * 0.5  // visual centre of ear

        var eCtx = ctx
        eCtx.translateBy(x: earCX, y: earCY)
        eCtx.rotate(by: .radians(tiltAngle))

        var outer = Path()
        outer.addEllipse(in: CGRect(x: -visHW, y: -effEarH / 2, width: visHW * 2, height: effEarH))
        eCtx.fill(outer, with: .color(Color(hex: "#F9F0F0")))
        eCtx.stroke(outer, with: .color(Color.black.opacity(0.06)), lineWidth: 0.8)
        var inner = Path()
        inner.addEllipse(in: CGRect(x: -visHW * 0.50, y: -effEarH / 2 + R * 0.10,
                                    width: visHW, height: effEarH * 0.65))
        eCtx.fill(inner, with: .color(Color(hex: "#FCA5A5").opacity(0.70)))
    }
}

// MARK: - Beanie

private func drawBeaniesFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path, simplified: Bool = false) {
    let s: CGFloat = 1.035, yEdge: CGFloat = 0.42, yCuff: CGFloat = 0.58
    let head = mochiOutfitPath(H.rx * s, H.ry * s)

    // shadow on head under the cuff
    var shadow = ctx
    shadow.clip(to: bodyPath)
    shadow.clip(to: mCapClip(H, y: yEdge - 0.12, s: 1))
    var shRect = Path()
    shRect.addRect(CGRect(x: -H.rx * 4, y: -H.ry * 4, width: H.rx * 8, height: H.ry * 8))
    shadow.fill(shRect, with: .color(Color(red: 30/255, green: 40/255, blue: 70/255, opacity: 0.10)))

    // knit body
    var knitCtx = ctx
    knitCtx.clip(to: mCapClip(H, y: yCuff, s: s))
    knitCtx.fill(head, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#7DB6FF"), location: 0),
            .init(color: Color(hex: "#2F6FE0"), location: 1)
        ]),
        startPoint: CGPoint(x: H.rx * 0.5,  y: -H.ry * 1.1),
        endPoint:   CGPoint(x: -H.rx * 0.6, y:  H.ry * 0.2)
    ))
    // vertical knit ribs (skip when simplified)
    if !simplified {
        var ribCtx = knitCtx
        ribCtx.clip(to: head)
        for k in -6...6 {
            let lon = CGFloat(k) * 0.24
            var pts: [P3] = []
            for i in 0...16 {
                let y = yCuff + (1.05 - yCuff) * CGFloat(i) / 16
                let q = mProj(H, mSurf(y, lon, s))
                if q.z > 0 { pts.append(q) }
            }
            guard pts.count >= 2 else { continue }
            var rp = Path()
            rp.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
            for pt in pts.dropFirst() { rp.addLine(to: CGPoint(x: pt.x, y: pt.y)) }
            ribCtx.stroke(rp, with: .color(Color(red: 20/255, green: 50/255, blue: 140/255, opacity: 0.16)),
                          style: StrokeStyle(lineWidth: H.R * 0.045, lineCap: .round))
        }
    }

    // cuff (folded band) — clip to [yEdge, yCuff] band using invert
    var cuffCtx = ctx
    cuffCtx.clip(to: mCapClip(H, y: yEdge, s: s * 1.04))
    cuffCtx.clip(to: mInvert(mCapClip(H, y: yCuff, s: s * 1.04), H: H), style: FillStyle(eoFill: true))
    let cuffHead = mochiOutfitPath(H.rx * s * 1.04, H.ry * s * 1.04)
    cuffCtx.fill(cuffHead, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#3C7BEA"), location: 0),
            .init(color: Color(hex: "#2257C4"), location: 1)
        ]),
        startPoint: CGPoint(x: 0, y: -H.ry * 0.6),
        endPoint:   CGPoint(x: 0, y: -H.ry * 0.2)
    ))
    var cuffRib = cuffCtx
    cuffRib.clip(to: cuffHead)
    for k in -14...14 {
        let lon = CGFloat(k) * 0.115
        let a = mProj(H, mSurf(yEdge, lon, s * 1.04))
        let b = mProj(H, mSurf(yCuff,  lon, s * 1.04))
        if a.z < 0 { continue }
        var cp = Path()
        cp.move(to: CGPoint(x: a.x, y: a.y))
        cp.addLine(to: CGPoint(x: b.x, y: b.y))
        cuffRib.stroke(cp, with: .color(Color(red: 10/255, green: 30/255, blue: 100/255, opacity: 0.22)),
                       style: StrokeStyle(lineWidth: H.R * 0.035, lineCap: .butt))
    }

    // top highlight
    var hiCtx = ctx
    hiCtx.clip(to: mCapClip(H, y: yCuff, s: s))
    hiCtx.clip(to: head)
    hiCtx.fill(head, with: .radialGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.35), location: 0),
            .init(color: .clear, location: 1)
        ]),
        center: CGPoint(x: H.rx * 0.3, y: -H.ry * 0.85),
        startRadius: 0, endRadius: H.R * 0.45
    ))

    // pompom on short spring
    let top = mProj(H, (0, 1.08 * s, 0))
    drawPompom(&ctx, x: top.x + H.physDx * H.rx * 0.25,
               y: top.y - H.R * 0.12 + H.physDy * H.ry * 0.15,
               r: H.R * 0.24)
}

// MARK: - Santa hat

private func drawSantaHatFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path) {
    let s: CGFloat = 1.05, yEdge: CGFloat = 0.52
    let arc = mFrontArc(H, y: yEdge, s: s)
    guard !arc.isEmpty else { return }
    let L = arc.first!
    let Rt = arc.last!
    let crown = mProj(H, (0, 1.05, 0))
    // tip flops to right + spring lag
    let side: CGFloat = 1
    let tip = CGPoint(
        x: crown.x + side * H.rx * (0.95 + H.physDx * 0.35),
        y: crown.y + H.ry * (0.05 + H.physDy * 0.2)
    )
    let peak = CGPoint(
        x: crown.x + side * H.rx * 0.25,
        y: crown.y - H.ry * 0.62
    )
    var bag = Path()
    bag.move(to: CGPoint(x: L.x, y: L.y))
    bag.addCurve(
        to:       CGPoint(x: peak.x, y: peak.y),
        control1: CGPoint(x: L.x - H.rx * 0.05,     y: L.y - H.ry * 0.7),
        control2: CGPoint(x: peak.x - H.rx * 0.55,  y: peak.y - H.ry * 0.05)
    )
    bag.addQuadCurve(
        to:      CGPoint(x: tip.x, y: tip.y),
        control: CGPoint(x: tip.x - H.rx * 0.05, y: peak.y - H.ry * 0.02)
    )
    bag.addQuadCurve(
        to:      CGPoint(x: peak.x + H.rx * 0.18, y: peak.y + H.ry * 0.32),
        control: CGPoint(x: tip.x  - H.rx * 0.12, y: tip.y  - H.ry * 0.22)
    )
    bag.addCurve(
        to:       CGPoint(x: Rt.x, y: Rt.y),
        control1: CGPoint(x: Rt.x + H.rx * 0.05, y: peak.y + H.ry * 0.45),
        control2: CGPoint(x: Rt.x + H.rx * 0.08, y: Rt.y   - H.ry * 0.35)
    )
    for i in stride(from: arc.count - 1, through: 0, by: -1) {
        bag.addLine(to: CGPoint(x: arc[i].x, y: arc[i].y))
    }
    bag.closeSubpath()

    // shadow on head
    var sCtx = ctx
    sCtx.clip(to: bodyPath)
    sCtx.clip(to: mCapClip(H, y: yEdge - 0.14, s: 1))
    var sRect = Path()
    sRect.addRect(CGRect(x: -H.rx * 4, y: -H.ry * 4, width: H.rx * 8, height: H.ry * 8))
    sCtx.fill(sRect, with: .color(Color(red: 120/255, green: 10/255, blue: 10/255, opacity: 0.10)))

    // bag fill
    ctx.fill(bag, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#FF6B6B"), location: 0),
            .init(color: Color(hex: "#E53935"), location: 0.55),
            .init(color: Color(hex: "#B71C1C"), location: 1)
        ]),
        startPoint: CGPoint(x: -H.rx * 0.6, y: -H.ry * 1.6),
        endPoint:   CGPoint(x:  H.rx * 0.7, y: -H.ry * 0.3)
    ))

    // folds
    var fCtx = ctx
    fCtx.clip(to: bag)
    for (a, b, w): (CGFloat, CGFloat, CGFloat) in [(0.15, 0.55, 0.10), (0.45, 0.85, 0.08)] {
        var fold = Path()
        fold.move(to: CGPoint(
            x: peak.x - H.rx * 0.1 + (Rt.x - L.x) * a * 0.3,
            y: peak.y + H.ry * 0.15
        ))
        fold.addQuadCurve(
            to:      CGPoint(x: tip.x - H.rx * (0.45 - b * 0.3), y: tip.y - H.ry * 0.12),
            control: CGPoint(x: peak.x + H.rx * 0.35,            y: peak.y + H.ry * (0.05 + a * 0.3))
        )
        fCtx.stroke(fold, with: .color(Color(red: 90/255, green: 0, blue: 0, opacity: 0.20)),
                    style: StrokeStyle(lineWidth: H.R * w, lineCap: .round))
    }
    fCtx.fill(bag, with: .radialGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.32), location: 0),
            .init(color: .clear, location: 1)
        ]),
        center: CGPoint(x: peak.x - H.rx * 0.25, y: peak.y + H.ry * 0.05),
        startRadius: 0, endRadius: H.R * 0.5
    ))

    // trim + pompom
    drawFuzzyBand(&ctx, arc: arc, thick: H.R * 0.3)
    drawPompom(&ctx, x: tip.x, y: tip.y + H.R * 0.04, r: H.R * 0.22)
}

// MARK: - Party hat

private func drawPartyHatFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path, simplified: Bool = false) {
    let baseY: CGFloat = 0.82, baseR: CGFloat = 0.42
    let lean: CGFloat = -0.24 + H.physDx * 0.12
    let c = mProj(H, (0.16, baseY + 0.06, 0))
    // full ring for left/right extremes
    var ring: [P3] = []
    for i in 0...48 {
        let a = CGFloat(i) / 48 * .pi * 2
        ring.append(mProj(H, (0.16 + baseR * sin(a), baseY + 0.06, baseR * cos(a))))
    }
    let left  = ring.min(by: { $0.x < $1.x })!
    let right = ring.max(by: { $0.x < $1.x })!
    let h = H.ry * 1.6
    let apex = CGPoint(x: c.x + sin(lean) * h, y: c.y - cos(lean) * h)
    let front = mFrontRun(ring)

    var cone = Path()
    cone.move(to: CGPoint(x: left.x, y: left.y))
    cone.addQuadCurve(
        to:      CGPoint(x: apex.x - H.R * 0.05, y: apex.y + H.R * 0.06),
        control: CGPoint(x: (left.x + apex.x) / 2 - H.rx * 0.06, y: (left.y + apex.y) / 2)
    )
    cone.addQuadCurve(
        to:      CGPoint(x: apex.x + H.R * 0.05, y: apex.y + H.R * 0.06),
        control: CGPoint(x: apex.x, y: apex.y - H.R * 0.03)
    )
    cone.addQuadCurve(
        to:      CGPoint(x: right.x, y: right.y),
        control: CGPoint(x: (right.x + apex.x) / 2 + H.rx * 0.06, y: (right.y + apex.y) / 2)
    )
    for i in stride(from: front.count - 1, through: 0, by: -1) {
        cone.addLine(to: CGPoint(x: front[i].x, y: front[i].y))
    }
    cone.closeSubpath()

    ctx.fill(cone, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#FF9BD0"), location: 0),
            .init(color: Color(hex: "#F15BAE"), location: 0.5),
            .init(color: Color(hex: "#C2187A"), location: 1)
        ]),
        startPoint: CGPoint(x: left.x,  y: apex.y),
        endPoint:   CGPoint(x: right.x, y: left.y)
    ))

    var dotCtx = ctx
    dotCtx.clip(to: cone)
    // polka dots (skip when simplified)
    if !simplified {
        let dots: [(CGFloat, CGFloat)] = [
            (0.25, -0.35), (0.3, 0.3), (0.55, -0.05), (0.72, 0.28),
            (0.8, -0.3),   (0.45, 0.6), (0.48, -0.65)
        ]
        for (t, u) in dots {
            let bx = left.x + (right.x - left.x) * (0.5 + u * 0.5)
            let by = left.y + (right.y - left.y) * (0.5 + u * 0.5)
            let x  = bx + (apex.x - bx) * (1 - t)
            let y  = by + (apex.y - by) * (1 - t)
            let r  = H.R * 0.075 * (0.6 + t * 0.5)
            var dot = Path()
            dot.addEllipse(in: CGRect(x: x - r, y: y - r * 0.9, width: r * 2, height: r * 0.9 * 2))
            dotCtx.fill(dot, with: .color(Color.white.opacity(0.92)))
        }
    }
    dotCtx.fill(cone, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.28), location: 0),
            .init(color: .clear,                    location: 0.35),
            .init(color: Color(red: 80/255, green: 0, blue: 40/255, opacity: 0.18), location: 1)
        ]),
        startPoint: CGPoint(x: left.x,  y: 0),
        endPoint:   CGPoint(x: right.x, y: 0)
    ))

    // rim at base
    if !front.isEmpty {
        var rim = Path()
        rim.move(to: CGPoint(x: front[0].x, y: front[0].y))
        for i in 1..<front.count { rim.addLine(to: CGPoint(x: front[i].x, y: front[i].y)) }
        ctx.stroke(rim, with: .color(Color(hex: "#FFD84D")),
                   style: StrokeStyle(lineWidth: H.R * 0.07, lineCap: .round))
    }
    drawPompom(&ctx, x: apex.x, y: apex.y - H.R * 0.04, r: H.R * 0.16,
               base: Color(hex: "#FFE27A"), shade: Color(hex: "#F2B705"))
}

// MARK: - Crown

private func drawCrownPart(ctx: inout GraphicsContext, H: MochiH, side: CGFloat, simplified: Bool = false) {
    let s: CGFloat = 1.06, yb: CGFloat = 0.46, yt: CGFloat = 0.66
    let n = 8, spikeH: CGFloat = 0.42
    let N = 120
    var seg: [(lon: CGFloat, b: P3, t: P3, tt: P3, z: CGFloat, spike: CGFloat)] = []
    for i in 0...N {
        let lon = -.pi + CGFloat(i) / CGFloat(N) * 2 * .pi
        let b = mProj(H, mSurf(yb, lon, s))
        let t = mProj(H, mSurf(yt, lon, s))
        let phase = ((lon + .pi) / (2 * .pi)) * CGFloat(n)
        let f = phase - floor(phase)
        let spike = pow(max(0, 1 - abs(f - 0.5) * 2), 1.6)
        let topY = yt + spikeH * spike
        let sp = mSurf(yt, lon, s)
        let tt = mProj(H, (sp.0 * (1 - 0.08 * spike), topY, sp.2 * (1 - 0.08 * spike)))
        seg.append((lon: lon, b: b, t: t, tt: tt, z: b.z, spike: spike))
    }
    var keep = seg.filter { side > 0 ? $0.z >= 0 : $0.z < 0.02 }
    guard keep.count >= 2 else { return }
    keep.sort { $0.b.x < $1.b.x }

    var shape = Path()
    shape.move(to: CGPoint(x: keep[0].tt.x, y: keep[0].tt.y))
    for i in 1..<keep.count { shape.addLine(to: CGPoint(x: keep[i].tt.x, y: keep[i].tt.y)) }
    for i in stride(from: keep.count - 1, through: 0, by: -1) {
        shape.addLine(to: CGPoint(x: keep[i].b.x, y: keep[i].b.y))
    }
    shape.closeSubpath()

    let dark = side < 0
    ctx.fill(shape, with: .linearGradient(
        dark
        ? Gradient(stops: [.init(color: Color(hex: "#C98A12"), location: 0),
                           .init(color: Color(hex: "#8A5A06"), location: 1)])
        : Gradient(stops: [.init(color: Color(hex: "#FFE58A"), location: 0),
                           .init(color: Color(hex: "#FBBF24"), location: 0.5),
                           .init(color: Color(hex: "#D08A0B"), location: 1)]),
        startPoint: CGPoint(x: 0, y: -H.ry * 1.05),
        endPoint:   CGPoint(x: 0, y: -H.ry * 0.45)
    ))

    if !dark {
        // band highlight
        var hiCtx = ctx
        hiCtx.clip(to: shape)
        hiCtx.fill(shape, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 120/255, green: 70/255, blue: 0, opacity: 0.25), location: 0),
                .init(color: Color.white.opacity(0.0),                                   location: 0.45),
                .init(color: Color.white.opacity(0.35),                                  location: 0.62),
                .init(color: Color(red: 120/255, green: 70/255, blue: 0, opacity: 0.25), location: 1)
            ]),
            startPoint: CGPoint(x: -H.rx, y: 0),
            endPoint:   CGPoint(x:  H.rx, y: 0)
        ))
        // gems + ball tips on front spikes (skip when simplified)
        if !simplified {
            let gems: [Color] = [Color(hex: "#EF4444"), Color(hex: "#3B82F6"),
                                 Color(hex: "#22C55E"), Color(hex: "#A855F7")]
            for k in 0..<n {
                let lon = -.pi + (CGFloat(k) + 0.5) / CGFloat(n) * 2 * .pi
                let sp = mSurf(yt, lon, s)
                let tipP = mProj(H, (sp.0 * 0.92, yt + spikeH, sp.2 * 0.92))
                let mid  = mProj(H, mSurf((yb + yt) / 2, lon, s * 1.01))
                if mid.z <= 0.12 { continue }
                let r = H.R * 0.055
                var tip = Path()
                tip.addEllipse(in: CGRect(x: tipP.x - r, y: tipP.y - r * 0.5 - r, width: r * 2, height: r * 2))
                ctx.fill(tip, with: .radialGradient(
                    Gradient(stops: [.init(color: Color(hex: "#FFF6CC"), location: 0),
                                     .init(color: Color(hex: "#E0A21A"), location: 1)]),
                    center: CGPoint(x: tipP.x - r * 0.3, y: tipP.y - r),
                    startRadius: 0, endRadius: r * 1.2
                ))
                let gr = H.R * 0.075
                var gem = Path()
                gem.addEllipse(in: CGRect(
                    x: mid.x - gr * max(0.35, mid.z),
                    y: mid.y - gr,
                    width: gr * max(0.35, mid.z) * 2,
                    height: gr * 2
                ))
                ctx.fill(gem, with: .color(gems[k % gems.count]))
                var glint = Path()
                glint.addEllipse(in: CGRect(
                    x: mid.x - gr * 0.25 * mid.z - gr * 0.28,
                    y: mid.y - gr * 0.35 - gr * 0.28,
                    width: gr * 0.56, height: gr * 0.56
                ))
                ctx.fill(glint, with: .color(Color.white.opacity(0.75)))
            }
        }
    }
}

// MARK: - Witch hat

private func drawWitchHatBack(ctx: inout GraphicsContext, H: MochiH) {
    let pts = witchBrimPts(H)
    let back = pts.filter { $0.z < 0.05 }.sorted { $0.x < $1.x }
    guard !back.isEmpty else { return }
    var ell = Path()
    ell.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
    for q in pts.dropFirst() { ell.addLine(to: CGPoint(x: q.x, y: q.y)) }
    ell.closeSubpath()
    ctx.fill(ell, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#2A0A4F"), location: 0),
            .init(color: Color(hex: "#3B0F6B"), location: 1)
        ]),
        startPoint: CGPoint(x: 0, y: -H.ry * 1.0),
        endPoint:   CGPoint(x: 0, y: -H.ry * 0.4)
    ))
}

private func witchBrimPts(_ H: MochiH) -> [P3] {
    let y: CGFloat = 0.70, rr: CGFloat = 1.42
    return (0...120).map { i -> P3 in
        let a = -.pi + CGFloat(i) / 120 * 2 * .pi
        let wob = 1 + 0.035 * sin(a * 3 + 0.6)
        let droop = -0.10 * pow(abs(sin(a)), 2)
        return mProj(H, (rr * wob * sin(a), y + droop, rr * wob * cos(a)))
    }
}

private func drawWitchHatFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path) {
    let all = witchBrimPts(H)
    var brim = Path()
    brim.move(to: CGPoint(x: all[0].x, y: all[0].y))
    for q in all.dropFirst() { brim.addLine(to: CGPoint(x: q.x, y: q.y)) }
    brim.closeSubpath()
    let fr = all.filter { $0.z >= 0 }.sorted { $0.x < $1.x }

    // shadow on head
    var sCtx = ctx
    sCtx.clip(to: bodyPath)
    sCtx.clip(to: mCapClip(H, y: 0.50, s: 1))
    var sRect = Path()
    sRect.addRect(CGRect(x: -H.rx * 4, y: -H.ry * 4, width: H.rx * 8, height: H.ry * 8))
    sCtx.fill(sRect, with: .color(Color(red: 40/255, green: 0, blue: 70/255, opacity: 0.10)))

    // full brim front
    ctx.fill(brim, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#5B21B6"), location: 0),
            .init(color: Color(hex: "#3B0764"), location: 1)
        ]),
        startPoint: CGPoint(x: 0, y: -H.ry * 0.9),
        endPoint:   CGPoint(x: 0, y: -H.ry * 0.3)
    ))
    if !fr.isEmpty {
        var frLine = Path()
        frLine.move(to: CGPoint(x: fr[0].x, y: fr[0].y))
        for i in 1..<fr.count { frLine.addLine(to: CGPoint(x: fr[i].x, y: fr[i].y)) }
        ctx.stroke(frLine, with: .color(Color(red: 190/255, green: 150/255, blue: 1, opacity: 0.35)),
                   style: StrokeStyle(lineWidth: H.R * 0.035, lineCap: .round))
    }

    // cone
    let baseR: CGFloat = 0.62, by: CGFloat = 0.74
    let bl = mProj(H, (-baseR, by, 0))
    let br = mProj(H, (baseR,  by, 0))
    let c  = mProj(H, (0, by, 0))
    let lean: CGFloat = 0.10 + H.physDx * 0.15
    let top = CGPoint(
        x: c.x + H.rx * 0.18 + sin(lean) * H.ry * 0.3,
        y: c.y - H.ry * 1.25
    )
    let tip = CGPoint(
        x: top.x + H.rx * (0.45 + H.physDx * 0.25),
        y: top.y + H.ry * (0.22 + H.physDy * 0.1)
    )
    // cap arc clipped to [bl.x-1, br.x+1]
    let capFront = mFrontArc(H, y: by, s: baseR / mRingR(by)).filter {
        $0.x >= bl.x - 1 && $0.x <= br.x + 1
    }

    var cone = Path()
    cone.move(to: CGPoint(x: bl.x, y: bl.y))
    cone.addCurve(
        to:       CGPoint(x: top.x - H.rx * 0.02, y: top.y - H.ry * 0.02),
        control1: CGPoint(x: bl.x  + H.rx * 0.12, y: bl.y  - H.ry * 0.5),
        control2: CGPoint(x: top.x - H.rx * 0.28, y: top.y + H.ry * 0.25)
    )
    cone.addQuadCurve(
        to:      CGPoint(x: tip.x, y: tip.y),
        control: CGPoint(x: top.x + H.rx * 0.25, y: top.y - H.ry * 0.08)
    )
    cone.addQuadCurve(
        to:      CGPoint(x: top.x + H.rx * 0.14, y: top.y + H.ry * 0.22),
        control: CGPoint(x: top.x + H.rx * 0.22, y: top.y + H.ry * 0.08)
    )
    cone.addCurve(
        to:       CGPoint(x: br.x, y: br.y),
        control1: CGPoint(x: br.x - H.rx * 0.18, y: c.y - H.ry * 0.45),
        control2: CGPoint(x: br.x - H.rx * 0.02, y: br.y - H.ry * 0.2)
    )
    for i in stride(from: capFront.count - 1, through: 0, by: -1) {
        cone.addLine(to: CGPoint(x: capFront[i].x, y: capFront[i].y))
    }
    cone.closeSubpath()

    ctx.fill(cone, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#7C3AED"), location: 0),
            .init(color: Color(hex: "#4C1D95"), location: 0.55),
            .init(color: Color(hex: "#2E1065"), location: 1)
        ]),
        startPoint: CGPoint(x: bl.x, y: top.y),
        endPoint:   CGPoint(x: br.x, y: bl.y)
    ))

    var coneCtx = ctx
    coneCtx.clip(to: cone)
    coneCtx.fill(cone, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.22), location: 0),
            .init(color: .clear, location: 0.4),
            .init(color: Color.black.opacity(0.15), location: 1)
        ]),
        startPoint: CGPoint(x: bl.x, y: 0),
        endPoint:   CGPoint(x: br.x, y: 0)
    ))
    // crease
    var crease = Path()
    crease.move(to:    CGPoint(x: top.x - H.rx * 0.05, y: top.y + H.ry * 0.05))
    crease.addQuadCurve(
        to:      CGPoint(x: top.x + H.rx * 0.2,  y: top.y + H.ry * 0.06),
        control: CGPoint(x: top.x + H.rx * 0.1,  y: top.y + H.ry * 0.12)
    )
    coneCtx.stroke(crease, with: .color(Color(red: 20/255, green: 0, blue: 40/255, opacity: 0.35)),
                   style: StrokeStyle(lineWidth: H.R * 0.05, lineCap: .round))

    // orange band
    let fc = mProj(H, (0, by, baseR))
    let lift = H.ry * 0.11
    var band = Path()
    band.move(to: CGPoint(x: bl.x - 2, y: bl.y - lift))
    band.addQuadCurve(
        to:      CGPoint(x: br.x + 2, y: br.y - lift),
        control: CGPoint(x: fc.x, y: 2 * (fc.y - lift) - (bl.y + br.y) / 2)
    )
    coneCtx.stroke(band, with: .color(Color(hex: "#F97316")),
                   style: StrokeStyle(lineWidth: H.ry * 0.17, lineCap: .butt))

    // buckle
    let bk0 = mProj(H, (0, by, baseR))
    let bk = CGPoint(x: bk0.x, y: bk0.y - H.ry * 0.11)
    let bw = H.R * 0.2, bh = H.R * 0.16
    var bkCtx = ctx
    bkCtx.translateBy(x: bk.x, y: bk.y)
    var buckle = Path()
    buckle.addRoundedRect(
        in: CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh),
        cornerSize: CGSize(width: bh * 0.25, height: bh * 0.25)
    )
    bkCtx.fill(buckle, with: .color(Color(hex: "#FCD34D")))
    var hole = Path()
    hole.addRoundedRect(
        in: CGRect(x: -bw / 2 + bw * 0.24, y: -bh / 2 + bh * 0.28,
                   width: bw * 0.52, height: bh * 0.44),
        cornerSize: CGSize(width: bh * 0.10, height: bh * 0.10)
    )
    bkCtx.fill(hole, with: .color(Color(hex: "#C2410C")))
}

// MARK: - Sunglasses

private func drawSunglassesFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path) {
    let rollH = MochiH(R: H.R, yaw: H.yaw, pitch: H.pitch + H.roll, physDx: H.physDx, physDy: H.physDy)
    let eyes = mEyeFrames(rollH)
    let w = H.R * 0.62, h = H.R * 0.46

    var g = ctx
    g.clip(to: bodyPath)

    let le = eyes[0], re = eyes[1]
    if le.visible && re.visible {
        var bridge = Path()
        bridge.move(to: CGPoint(x: le.x + w / 2 * le.fx * 0.9, y: le.y - h * 0.18))
        bridge.addQuadCurve(
            to:      CGPoint(x: re.x - w / 2 * re.fx * 0.9, y: re.y - h * 0.18),
            control: CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2 - h * 0.42)
        )
        g.stroke(bridge, with: .color(Color(hex: "#111317")),
                 style: StrokeStyle(lineWidth: H.R * 0.07, lineCap: .round))
    }
    for e in eyes {
        guard e.visible else { continue }
        let ox = e.x + e.sd * w / 2 * e.fx
        var temple = Path()
        temple.move(to: CGPoint(x: ox, y: e.y - h * 0.2))
        temple.addLine(to: CGPoint(x: e.sd * H.rx * 1.05, y: e.y - h * 0.35))
        g.stroke(temple, with: .color(Color(hex: "#111317")),
                 style: StrokeStyle(lineWidth: H.R * 0.06, lineCap: .round))
    }
    for e in eyes {
        guard e.visible else { continue }
        var lens = Path()
        lens.addRoundedRect(
            in: CGRect(x: e.x - w / 2, y: e.y - h * 0.5, width: w, height: h),
            cornerSize: CGSize(width: h * 0.42, height: h * 0.42)
        )
        // foreshorten lens via scale
        var lg = g
        lg.translateBy(x: e.x, y: e.y)
        lg.scaleBy(x: e.fx, y: e.fy)
        var lensLocal = Path()
        lensLocal.addRoundedRect(
            in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
            cornerSize: CGSize(width: h * 0.42, height: h * 0.42)
        )
        lg.fill(lensLocal, with: .color(Color(red: 17/255, green: 19/255, blue: 23/255, opacity: 0.82)))
        lg.stroke(lensLocal, with: .color(Color(hex: "#0B0C0F")),
                  style: StrokeStyle(lineWidth: H.R * 0.05))
        // glare
        var glare = Path()
        glare.move(to: CGPoint(x: -w * 0.28, y: -h * 0.05))
        glare.addLine(to: CGPoint(x: -w * 0.05, y: -h * 0.3))
        lg.stroke(glare, with: .color(Color.white.opacity(0.45)),
                  style: StrokeStyle(lineWidth: H.R * 0.05, lineCap: .round))
    }
}

// MARK: - Round glasses

private func drawRoundGlassesFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path) {
    let rollH = MochiH(R: H.R, yaw: H.yaw, pitch: H.pitch + H.roll, physDx: H.physDx, physDy: H.physDy)
    let eyes = mEyeFrames(rollH)
    let d = H.R * 0.56

    var g = ctx
    g.clip(to: bodyPath)

    let le = eyes[0], re = eyes[1]
    if le.visible && re.visible {
        var bridge = Path()
        bridge.move(to: CGPoint(x: le.x + d / 2 * le.fx, y: le.y - d * 0.08))
        bridge.addQuadCurve(
            to:      CGPoint(x: re.x - d / 2 * re.fx, y: re.y - d * 0.08),
            control: CGPoint(x: (le.x + re.x) / 2, y: (le.y + re.y) / 2 - d * 0.3)
        )
        g.stroke(bridge, with: .color(Color(hex: "#8A4B12")),
                 style: StrokeStyle(lineWidth: H.R * 0.055, lineCap: .round))
    }
    for e in eyes {
        guard e.visible else { continue }
        var temple = Path()
        temple.move(to: CGPoint(x: e.x + e.sd * d / 2 * e.fx, y: e.y - d * 0.1))
        temple.addLine(to: CGPoint(x: e.sd * H.rx * 1.05, y: e.y - d * 0.25))
        g.stroke(temple, with: .color(Color(hex: "#8A4B12")),
                 style: StrokeStyle(lineWidth: H.R * 0.05, lineCap: .round))
    }
    for e in eyes {
        guard e.visible else { continue }
        var lg = g
        lg.translateBy(x: e.x, y: e.y)
        lg.scaleBy(x: e.fx, y: e.fy)
        // circle fill
        var circle = Path()
        circle.addEllipse(in: CGRect(x: -d / 2, y: -d / 2, width: d, height: d))
        lg.fill(circle, with: .color(Color(red: 190/255, green: 225/255, blue: 1, opacity: 0.18)))
        lg.stroke(circle, with: .color(Color(hex: "#9A5A1A")),
                  style: StrokeStyle(lineWidth: H.R * 0.065, lineCap: .round))
        // highlight arc
        var arcPath = Path()
        arcPath.addArc(center: .zero, radius: d / 2 - H.R * 0.03,
                       startAngle: .radians(.pi * 1.1), endAngle: .radians(.pi * 1.45), clockwise: false)
        lg.stroke(arcPath, with: .color(Color.white.opacity(0.55)),
                  style: StrokeStyle(lineWidth: H.R * 0.03, lineCap: .round))
    }
}

// MARK: - Scarf

private func drawScarfFront(ctx: inout GraphicsContext, H: MochiH) {
    let s: CGFloat = 1.05, y0: CGFloat = -0.34, y1: CGFloat = -0.66
    let top = mFrontArcRoll(H, y: y0, s: s)
    let bot = mFrontArcRoll(H, y: y1, s: s)
    guard !top.isEmpty, !bot.isEmpty else { return }

    var band = Path()
    band.move(to: CGPoint(x: top[0].x, y: top[0].y))
    for q in top.dropFirst() { band.addLine(to: CGPoint(x: q.x, y: q.y)) }
    for i in stride(from: bot.count - 1, through: 0, by: -1) {
        band.addLine(to: CGPoint(x: bot[i].x, y: bot[i].y))
    }
    band.closeSubpath()

    var g = ctx
    g.clip(to: mochiOutfitPath(H.rx * s, H.ry * s))
    g.fill(band, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#F87171"), location: 0),
            .init(color: Color(hex: "#B91C1C"), location: 1)
        ]),
        startPoint: CGPoint(x: 0, y: -H.ry * 0.2),
        endPoint:   CGPoint(x: 0, y:  H.ry * 0.7)
    ))
    var g2 = g
    g2.clip(to: band)
    // stripes along meridians
    for lon: CGFloat in [-1.0, -0.45, 0.1, 0.65, 1.2] {
        let a = mProj(H, mSurf(y0, lon, s))
        let b = mProj(H, mSurf(y1, lon, s))
        if a.z < 0 { continue }
        var stripe = Path()
        stripe.move(to: CGPoint(x: a.x, y: a.y - 4))
        stripe.addLine(to: CGPoint(x: b.x, y: b.y + 4))
        g2.stroke(stripe, with: .color(Color.white.opacity(0.85)),
                  style: StrokeStyle(lineWidth: H.R * 0.09 * max(0.3, a.z), lineCap: .round))
    }
    g.fill(band, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color.white.opacity(0.18), location: 0),
            .init(color: Color.black.opacity(0.10), location: 1)
        ]),
        startPoint: CGPoint(x: 0, y: -H.ry * 0.5),
        endPoint:   CGPoint(x: 0, y:  H.ry * 0.3)
    ))

    // hanging end
    let k = mProj(H, mSurf((y0 + y1) / 2, -0.55, s * 1.03))
    if k.z > 0 {
        let sw = H.physDx * H.rx * 0.12
        var end = Path()
        end.move(to: CGPoint(x: k.x - H.R * 0.16, y: k.y))
        end.addQuadCurve(
            to:      CGPoint(x: k.x - H.R * 0.2 + sw * 1.4, y: k.y + H.ry * 0.62),
            control: CGPoint(x: k.x - H.R * 0.24 + sw,      y: k.y + H.ry * 0.35)
        )
        end.addLine(to: CGPoint(x: k.x + H.R * 0.06 + sw * 1.4, y: k.y + H.ry * 0.60))
        end.addQuadCurve(
            to:      CGPoint(x: k.x + H.R * 0.12, y: k.y),
            control: CGPoint(x: k.x + H.R * 0.02 + sw, y: k.y + H.ry * 0.3)
        )
        end.closeSubpath()
        ctx.fill(end, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(hex: "#EF4444"), location: 0),
                .init(color: Color(hex: "#B91C1C"), location: 1)
            ]),
            startPoint: CGPoint(x: 0, y: k.y),
            endPoint:   CGPoint(x: 0, y: k.y + H.ry * 0.6)
        ))
        var eCtx = ctx
        eCtx.clip(to: end)
        // stripes in hanging end
        for t: CGFloat in [0.35, 0.7] {
            var stripe = Path()
            stripe.addRect(CGRect(
                x: k.x - H.R * 0.4 + sw,
                y: k.y + H.ry * 0.62 * t,
                width: H.R * 0.8, height: H.R * 0.07
            ))
            eCtx.fill(stripe, with: .color(Color.white.opacity(0.85)))
        }
        // fringe
        for i in 0..<4 {
            let fx = k.x - H.R * 0.17 + sw * 1.4 + CGFloat(i) * H.R * 0.075
            var fringe = Path()
            fringe.move(to: CGPoint(x: fx, y: k.y + H.ry * 0.6))
            fringe.addLine(to: CGPoint(x: fx, y: k.y + H.ry * 0.72))
            ctx.stroke(fringe, with: .color(Color(hex: "#DC2626")),
                       style: StrokeStyle(lineWidth: H.R * 0.035, lineCap: .round))
        }
        // knot (rotated ellipse)
        var knotCtx = ctx
        knotCtx.translateBy(x: k.x, y: k.y)
        knotCtx.rotate(by: .radians(0.2))
        var knot = Path()
        knot.addEllipse(in: CGRect(x: -H.R * 0.17, y: -H.R * 0.14, width: H.R * 0.34, height: H.R * 0.28))
        knotCtx.fill(knot, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(hex: "#F87171"), location: 0),
                .init(color: Color(hex: "#B91C1C"), location: 1)
            ]),
            center: CGPoint(x: -H.R * 0.05, y: -H.R * 0.05),
            startRadius: 0, endRadius: H.R * 0.2
        ))
    }
}

// MARK: - Pumpkin

private func drawPumpkinFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path, simplified: Bool = false) {
    // ribs only — body recolor is done in BotEngine.drawBody(pumpkinColors:)
    if !simplified {
        var g = ctx
        g.clip(to: bodyPath)
        for lon: CGFloat in [-1.15, -0.55, 0.0, 0.55, 1.15] {
            var pts: [P3] = []
            for i in 0...30 {
                let y = -0.98 + 1.96 * CGFloat(i) / 30
                let q = mProjRoll(H, mSurf(y, lon, 1))
                if q.z > 0 { pts.append(q) }
            }
            guard pts.count >= 2 else { continue }
            var rib = Path()
            rib.move(to: CGPoint(x: pts[0].x, y: pts[0].y))
            for pt in pts.dropFirst() { rib.addLine(to: CGPoint(x: pt.x, y: pt.y)) }
            let zz = pts[pts.count / 2].z
            g.stroke(rib, with: .color(Color(red: 150/255, green: 50/255, blue: 0, opacity: 0.22 * zz)),
                     style: StrokeStyle(lineWidth: H.R * 0.12, lineCap: .round))
            // highlight offset stripe
            var hi = Path()
            hi.move(to: CGPoint(x: pts[0].x + H.R * 0.07, y: pts[0].y))
            for pt in pts.dropFirst() { hi.addLine(to: CGPoint(x: pt.x + H.R * 0.07, y: pt.y)) }
            g.stroke(hi, with: .color(Color(red: 1, green: 220/255, blue: 170/255, opacity: 0.18 * zz)),
                     style: StrokeStyle(lineWidth: H.R * 0.04, lineCap: .round))
        }
    }

    let t = mProjRoll(H, (0.02, 1.0, 0))
    // stem
    var stem = Path()
    stem.move(to: CGPoint(x: t.x - H.R * 0.09, y: t.y + H.R * 0.04))
    stem.addQuadCurve(
        to:      CGPoint(x: t.x + H.R * 0.08, y: t.y - H.R * 0.3),
        control: CGPoint(x: t.x - H.R * 0.08, y: t.y - H.R * 0.22)
    )
    stem.addLine(to: CGPoint(x: t.x + H.R * 0.13, y: t.y - H.R * 0.22))
    stem.addQuadCurve(
        to:      CGPoint(x: t.x + H.R * 0.08, y: t.y + H.R * 0.04),
        control: CGPoint(x: t.x + H.R * 0.04, y: t.y - H.R * 0.15)
    )
    stem.closeSubpath()
    ctx.fill(stem, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#65A30D"), location: 0),
            .init(color: Color(hex: "#3F6212"), location: 1)
        ]),
        startPoint: CGPoint(x: t.x - H.R * 0.1, y: 0),
        endPoint:   CGPoint(x: t.x + H.R * 0.1, y: 0)
    ))

    // leaf
    var leafCtx = ctx
    leafCtx.translateBy(x: t.x - H.R * 0.06, y: t.y - H.R * 0.02)
    leafCtx.rotate(by: .radians(-0.5))
    var leaf = Path()
    leaf.move(to: .zero)
    leaf.addQuadCurve(
        to:      CGPoint(x: -H.R * 0.38, y: -H.R * 0.02),
        control: CGPoint(x: -H.R * 0.18, y: -H.R * 0.2)
    )
    leaf.addQuadCurve(
        to:      .zero,
        control: CGPoint(x: -H.R * 0.18, y: H.R * 0.1)
    )
    leafCtx.fill(leaf, with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#84CC16"), location: 0),
            .init(color: Color(hex: "#4D7C0F"), location: 1)
        ]),
        startPoint: CGPoint(x: 0, y: -H.R * 0.15),
        endPoint:   CGPoint(x: -H.R * 0.3, y: 0)
    ))
    var vein = Path()
    vein.move(to: CGPoint(x: -H.R * 0.02, y: -H.R * 0.01))
    vein.addQuadCurve(
        to:      CGPoint(x: -H.R * 0.32, y: -H.R * 0.03),
        control: CGPoint(x: -H.R * 0.18, y: -H.R * 0.08)
    )
    leafCtx.stroke(vein, with: .color(Color(red: 30/255, green: 60/255, blue: 0, opacity: 0.4)),
                   style: StrokeStyle(lineWidth: H.R * 0.02, lineCap: .round))

    // tendril (skip when simplified)
    if !simplified {
        var tendril = Path()
        tendril.move(to: CGPoint(x: t.x + H.R * 0.1, y: t.y - H.R * 0.12))
        tendril.addCurve(
            to:       CGPoint(x: t.x + H.R * 0.22, y: t.y - H.R * 0.06),
            control1: CGPoint(x: t.x + H.R * 0.3,  y: t.y - H.R * 0.25),
            control2: CGPoint(x: t.x + H.R * 0.35, y: t.y - H.R * 0.02)
        )
        ctx.stroke(tendril, with: .color(Color(hex: "#4D7C0F")),
                   style: StrokeStyle(lineWidth: H.R * 0.03, lineCap: .round))
    }
}

// MARK: - Bow

private func drawBowFront(ctx: inout GraphicsContext, H: MochiH, bodyPath: Path) {
    let a = mProjRoll(H, mSurf(0.86, 0.55, 1.02))
    guard a.z >= -0.2 else { return }
    let s = H.R * 0.26
    let sq = max(0.45, cos(0.55 + H.yaw))

    var g = ctx
    g.translateBy(x: a.x, y: a.y)
    g.rotate(by: .radians(0.35 + H.yaw * 0.3))
    g.scaleBy(x: sq, y: 1)

    for sdD: Double in [-1.0, 1.0] {
        let sd = CGFloat(sdD)
        var wing = Path()
        wing.move(to: .zero)
        wing.addCurve(
            to:       CGPoint(x: sd * s * 1.15, y: 0),
            control1: CGPoint(x: sd * s * 0.6,  y: -s * 0.85),
            control2: CGPoint(x: sd * s * 1.35, y: -s * 0.55)
        )
        wing.addCurve(
            to:       .zero,
            control1: CGPoint(x: sd * s * 1.35, y:  s * 0.55),
            control2: CGPoint(x: sd * s * 0.6,  y:  s * 0.85)
        )
        g.fill(wing, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(hex: "#FF8CC6"), location: 0),
                .init(color: Color(hex: "#DB2777"), location: 1)
            ]),
            startPoint: CGPoint(x: 0, y: -s),
            endPoint:   CGPoint(x: 0, y:  s)
        ))
        // crease
        var crease = Path()
        crease.move(to: CGPoint(x: sd * s * 0.25, y: -s * 0.05))
        crease.addQuadCurve(
            to:      CGPoint(x: sd * s * 0.95, y: -s * 0.05),
            control: CGPoint(x: sd * s * 0.7,  y: -s * 0.15)
        )
        g.stroke(crease, with: .color(Color(red: 140/255, green: 10/255, blue: 70/255, opacity: 0.35)),
                 style: StrokeStyle(lineWidth: s * 0.08, lineCap: .round))
    }
    // centre knot
    var knot = Path()
    knot.addEllipse(in: CGRect(x: -s * 0.24, y: -s * 0.30, width: s * 0.48, height: s * 0.60))
    g.fill(knot, with: .radialGradient(
        Gradient(stops: [
            .init(color: Color(hex: "#FFB3D9"), location: 0),
            .init(color: Color(hex: "#C2185B"), location: 1)
        ]),
        center: CGPoint(x: -s * 0.06, y: -s * 0.1),
        startRadius: 0, endRadius: s * 0.35
    ))
}
