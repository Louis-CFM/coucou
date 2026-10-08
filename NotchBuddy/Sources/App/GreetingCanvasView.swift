import SwiftUI

// MARK: - Timing constants

private enum GT {
    static let pop0:     Double = 1.30
    static let pop1:     Double = 1.45
    static let content0: Double = 2.40
    static let tuck0:    Double = 2.45
    static let tuck1:    Double = 2.70
    static let badge:    Double = 2.72
    static let down0:    Double = 2.85
    static let down1:    Double = 3.45
    static let blink2:   Double = 3.70
    static let tint0:    Double = 3.85
    static let tint1:    Double = 4.15
    static let end:      Double = 4.60
    static let autoLeave:Double = 4.90
    static let COLLAPSE: Double = 0.34
}

// MARK: - Geometry constants (640×150 reference space)

private let GC0     = CGPoint(x: 320, y: 90)
private let GHB:    CGFloat = 58
private let GASP:   CGFloat = 1.34
private let GEAR_X: CGFloat = 40
private let GEAR_HB:CGFloat = 17
private let GCARD   = CGRect(x: 10, y: 36, width: 620, height: 104)
private let GCARD_R:CGFloat = 20

// MARK: - Easing

private enum GE {
    static func out(_ t: Double)    -> Double { 1 - pow(1 - t, 3) }
    static func easeIn(_ t: Double) -> Double { t * t * t }
    static func inOut(_ t: Double)  -> Double {
        t < 0.5 ? 4*t*t*t : 1 - pow(-2*t+2, 3)/2
    }
    static func back(_ t: Double)   -> Double {
        let c1=1.70158, c3=c1+1
        return 1 + c3*pow(t-1,3) + c1*pow(t-1,2)
    }
}

private func gClamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
private func gLerp(_ a: Double, _ b: Double, _ t: Double)  -> Double { a + (b - a) * t }
private func gSeg(_ t: Double, _ a: Double, _ b: Double)   -> Double { gClamp((t-a)/(b-a), 0, 1) }
private func gLerpF(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b-a)*t }

// MARK: - Pose

private enum GEyeType { case dot, happy, content }

private struct GreetPose {
    var hb, x, y, sx, sy, tilt: Double
    var eye: GEyeType; var open, eyeRoll: Double
    var lookX, lookY: Double
    var handL, handR, wave: Double
    var badge, tint, halo, haloBlue, minis, fx: Double
    var header, card: Double
    var iw, ih: Double
}

// MARK: - Particle data (seeded LCG, seed=7)

private struct GWarpStreak { let xNorm, speed, len, thick, alpha, t0: Double }
private struct GRingDot    { let a, j, s, al: Double }

private let greetParticles: (warps: [GWarpStreak], ring: [GRingDot]) = {
    var seed: UInt32 = 7
    func rnd() -> Double {
        seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff
        return Double(seed) / Double(0x7fff_ffff)
    }
    // ~70 white warp streaks for the fall-in (0 → 0.55 s)
    let warps = (0..<70).map { _ in
        GWarpStreak(xNorm: rnd(),
                    speed: 400 + rnd() * 300,
                    len:   6   + rnd() * 16,
                    thick: 1   + rnd() * 0.5,
                    alpha: 0.25 + rnd() * 0.55,
                    t0:   rnd() * 0.35)
    }
    // Single burst ring at 0.45 s, ~90 dots, white
    let ring = (0..<90).map { _ in
        GRingDot(a: rnd() * .pi * 2, j: (rnd()-0.5)*0.22,
                 s: 0.7+rnd()*0.9,   al: 0.45+rnd()*0.55)
    }
    return (warps, ring)
}()

// MARK: - Pose computation

private func greetPose(_ t: Double, compact: IslandRestingLayout) -> GreetPose {
    // Island size (reference for clip / warp spread)
    let gx = gSeg(t, 0, 0.5)
    let g  = sin(.pi*gx/2) + 0.04*sin(.pi*gx)*gx
    let iw = gLerp(Double(compact.width - 160), 640, g)
    let ih = gLerp(Double(compact.height), 150, g)

    let GH = Double(GHB)   // 58
    let cx = Double(GC0.x) // 320
    let cy = Double(GC0.y) // 90

    // Body height: invisible before 0.20, grows 0.15→1.0 with back ease
    let hb: Double = t < 0.20 ? 0 : gLerp(GH * 0.15, GH, GE.back(gSeg(t, 0.20, 0.60)))

    // Landmark y positions (absolute, GC0-relative in multiples of GH)
    let restY   = cy
    let landY   = cy + 0.12 * GH   // landing: y=+0.12
    let peakY   = cy - 0.15 * GH   // bounce peak: y=−0.15
    let dipY    = cy + 0.36 * GH   // plunge low: y=+0.36
    let springY = cy - 0.10 * GH   // spring high: y=−0.10
    let sinkY   = cy + 0.30 * GH   // sink for tuck: y=+0.30

    // Landmark x positions
    let restX   = cx
    let drift1  = cx - 0.16 * GH
    let drift2  = cx - 0.45 * GH
    let drift3  = cx - 0.57 * GH
    let drift4  = cx - 0.85 * GH

    // --- X (lateral travel) ---
    var x: Double
    if t < 0.85 {
        x = restX
    } else if t < 1.20 {
        x = gLerp(restX,  drift1, GE.inOut(gSeg(t, 0.85, 1.20)))
    } else if t < 1.30 {
        x = gLerp(drift1, drift2, GE.easeIn(gSeg(t, 1.20, 1.30)))
    } else if t < 1.45 {
        x = gLerp(drift2, drift3, GE.inOut(gSeg(t, 1.30, 1.45)))
    } else if t < 2.40 {
        x = gLerp(drift3, drift4, GE.inOut(gSeg(t, 1.45, 2.40)))
    } else if t < 2.85 {
        x = drift4
    } else {
        x = gLerp(drift4, restX,  GE.inOut(gSeg(t, 2.85, 3.45)))
    }

    // --- Y (vertical travel, base without bob) ---
    var y: Double
    if t < 0.20 {
        y = Double(compact.botCenterY)
    } else if t < 0.60 {
        y = gLerp(Double(compact.botCenterY), landY, GE.easeIn(gSeg(t, 0.20, 0.60)))
    } else if t < 0.73 {
        y = gLerp(landY,   peakY,   GE.out(gSeg(t, 0.60, 0.73)))
    } else if t < 0.90 {
        y = gLerp(peakY,   restY,   GE.inOut(gSeg(t, 0.73, 0.90)))
    } else if t < 1.20 {
        y = restY
    } else if t < 1.30 {
        y = gLerp(restY,   dipY,    GE.easeIn(gSeg(t, 1.20, 1.30)))
    } else if t < 1.45 {
        y = gLerp(dipY,    springY, GE.out(gSeg(t, 1.30, 1.45)))
    } else if t < 1.60 {
        y = gLerp(springY, restY,   GE.inOut(gSeg(t, 1.45, 1.60)))
    } else if t < 2.40 {
        y = restY
    } else if t < 2.70 {
        y = gLerp(restY,   sinkY,   GE.inOut(gSeg(t, 2.40, 2.70)))
    } else if t < 2.85 {
        y = sinkY
    } else {
        y = gLerp(sinkY,   restY,   GE.inOut(gSeg(t, 2.85, 3.45)))
    }

    // Body bob: in phase with hand wave, active pop1 → tuck0, ramp-in 0.08 s
    if t >= GT.pop1 && t < GT.tuck0 {
        let w = t - GT.pop1
        let rampIn = gClamp(w / 0.08, 0, 1)
        y += sin(w * 2 * .pi * 5.0) * 0.02 * GH * rampIn
    }

    // --- Scale ---
    var sx = 1.0, sy = 1.0

    // Landing squash (peak at 0.60, pulse 0.52→0.68)
    let landSqK = (t >= 0.52 && t < 0.68) ? sin(.pi * gSeg(t, 0.52, 0.68)) : 0
    // Bounce stretch (peak at 0.73, resolves 0.62→0.84)
    let bounceK  = (t >= 0.62 && t < 0.84) ? sin(.pi * gSeg(t, 0.62, 0.84)) : 0
    sx = 1.0 + 0.14 * landSqK - 0.10 * bounceK
    sy = 1.0 - 0.14 * landSqK + 0.18 * bounceK

    // Plunge squash (peaks at 1.30, pulse 1.18→1.42)
    let plungeK = (t >= 1.18 && t < 1.42) ? sin(.pi * gSeg(t, 1.18, 1.42)) : 0
    // Spring stretch (peak at 1.38, resolves 1.30→1.46)
    let springK = (t >= 1.30 && t < 1.46) ? sin(.pi * gSeg(t, 1.30, 1.46)) : 0
    sx += 0.12 * plungeK - 0.18 * springK
    sy -= 0.12 * plungeK - 0.25 * springK

    // Sink squash (peak at 2.70)
    let sinkK: Double
    if t >= 2.38 && t < 2.70 {
        sinkK = GE.inOut(gSeg(t, 2.38, 2.70))
    } else if t >= 2.70 && t < 2.85 {
        sinkK = 1 - GE.inOut(gSeg(t, 2.70, 2.85))
    } else {
        sinkK = 0
    }
    sx += 0.18 * sinkK
    sy -= 0.14 * sinkK

    // Micro squash at 3.70 (with blink)
    let microK = (t >= 3.70 && t < 3.82) ? sin(.pi * gSeg(t, 3.70, 3.82)) : 0
    sx += 0.08 * microK
    sy -= 0.07 * microK

    // --- Eyes ---
    var eye: GEyeType = .dot
    if t >= 0.55  && t < 0.80      { eye = .happy   }
    if t >= GT.content0 && t < GT.tuck1 { eye = .content }

    let blink: (Double) -> Double = { tb in
        let k = gSeg(t, tb, tb + 0.12)
        return (k > 0 && k < 1) ? 1 - sin(.pi * k) * 0.94 : 1
    }
    let openVal = min(blink(1.95), min(blink(3.05), blink(GT.blink2)))

    // --- Look ---
    var lookX = 0.0, lookY = 0.0
    if t >= GT.pop1 && t < GT.content0 {         // wave: up-right
        lookX = 0.55; lookY = -0.45
    } else if t >= GT.content0 && t < GT.down0 { // tuck: down-left
        lookX = -0.3; lookY = 0.6
    } else if t >= GT.down0 && t < GT.down1 {    // slide: down-right (returning)
        lookX = 0.3;  lookY = 0.6
    } else if t >= GT.down1 {
        let k = GE.inOut(gSeg(t, GT.down1, GT.down1 + 0.35))
        lookX = gLerp(0.3, 0, k); lookY = gLerp(0.6, 0, k)
    }

    // --- Hands ---
    let handL = t < GT.tuck0
        ? GE.back(gSeg(t, GT.pop0, GT.pop0 + 0.14))
        : 1 - GE.easeIn(gSeg(t, GT.tuck0, GT.tuck1 - 0.03))
    let handR = t < GT.tuck0
        ? GE.back(gSeg(t, GT.pop0 + 0.04, GT.pop0 + 0.18))
        : 1 - GE.easeIn(gSeg(t, GT.tuck0 + 0.03, GT.tuck1))
    let wave = (t >= GT.pop1 && t < GT.tuck0) ? t - GT.pop1 : -1.0

    return GreetPose(
        hb: hb, x: x, y: y, sx: sx, sy: sy, tilt: 0,
        eye: eye, open: openVal, eyeRoll: 0,
        lookX: lookX, lookY: lookY,
        handL: handL, handR: handR, wave: wave,
        badge:    GE.back(gSeg(t, GT.badge, GT.badge + 0.28)),
        tint:     0.6 * GE.inOut(gSeg(t, GT.tint0, GT.tint1)),
        halo:     GE.out(gSeg(t, 0.3, 0.7)),
        haloBlue: gSeg(t, GT.tint0, GT.tint1),
        minis: 0, fx: 1,
        header: gSeg(t, 0.35, 0.6), card: gSeg(t, 0.18, 0.45),
        iw: iw, ih: ih
    )
}

private func smallPose(_ compact: IslandRestingLayout) -> GreetPose {
    let sw = Double(compact.width)
    return GreetPose(
        hb: Double(GEAR_HB * compact.botDiameter / 20),
        x: 320 - sw/2 + Double(GEAR_X),
        y: Double(compact.botCenterY),
        sx: 1, sy: 1, tilt: 0,
        eye: .dot, open: 1, eyeRoll: 0,
        lookX: 0, lookY: 0,
        handL: 0, handR: 0, wave: -1,
        badge: 1, tint: 0.6, halo: 0.6, haloBlue: 1,
        minis: 1, fx: 1,
        header: 0, card: 0,
        iw: sw, ih: Double(compact.height)
    )
}

private func pose(_ t: Double, tc: Double, compact: IslandRestingLayout) -> GreetPose {
    if t < tc { return greetPose(min(t, GT.end + 10), compact: compact) }
    let a = greetPose(tc, compact: compact)
    let b = smallPose(compact)
    let e = GE.inOut(gSeg(t, tc, tc + GT.COLLAPSE))
    var p = a
    p.iw = gLerp(a.iw, b.iw, e); p.ih = gLerp(a.ih, b.ih, e)
    p.x  = gLerp(a.x, b.x, e);   p.y  = gLerp(a.y, b.y, e)
    p.hb = gLerp(a.hb, b.hb, e)
    p.badge    = gLerp(a.badge, b.badge, e)
    p.tint     = gLerp(a.tint,  b.tint,  e)
    p.halo     = gLerp(a.halo,  b.halo,  e)
    p.haloBlue = gLerp(a.haloBlue, b.haloBlue, e)
    p.header   = a.header * (1 - gSeg(t, tc, tc+0.1))
    p.card     = a.card   * (1 - gSeg(t, tc, tc+0.18))
    p.handL    = a.handL  * (1 - gSeg(t, tc, tc+0.15))
    p.handR    = a.handR  * (1 - gSeg(t, tc, tc+0.15))
    p.wave     = a.wave >= 0 ? a.wave : -1
    p.tilt     = a.tilt * (1 - e)
    p.sx       = gLerp(a.sx, 1, e); p.sy = gLerp(a.sy, 1, e)
    p.eyeRoll  = a.eyeRoll * (1 - e)
    let bk = gSeg(t, tc+0.14, tc+0.26)
    p.eye = .dot; p.open = (bk > 0 && bk < 1) ? 1 - sin(.pi*bk)*0.94 : 1
    p.lookX = a.lookX*(1-e); p.lookY = a.lookY*(1-e)
    p.minis = GE.back(gSeg(t, tc+0.24, tc+0.42))
    p.fx    = 1 - gSeg(t, tc, tc+0.2)
    return p
}

// MARK: - Drawing helpers

private func gHex(_ hex: String, alpha: CGFloat = 1) -> CGColor {
    let h = hex.trimmingCharacters(in: CharacterSet(charactersIn:"#"))
    let v = UInt64(h, radix: 16) ?? 0
    return CGColor(red: CGFloat((v>>16)&0xFF)/255,
                   green: CGFloat((v>>8)&0xFF)/255,
                   blue: CGFloat(v&0xFF)/255, alpha: alpha)
}

private func gRR(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat,
                 _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
    let r = max(0, min(r, w/2, h/2))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: x+r, y: y))
    ctx.addArc(tangent1End: CGPoint(x: x+w, y: y),   tangent2End: CGPoint(x: x+w, y: y+h), radius: r)
    ctx.addArc(tangent1End: CGPoint(x: x+w, y: y+h), tangent2End: CGPoint(x: x,   y: y+h), radius: r)
    ctx.addArc(tangent1End: CGPoint(x: x,   y: y+h), tangent2End: CGPoint(x: x,   y: y),   radius: r)
    ctx.addArc(tangent1End: CGPoint(x: x,   y: y),   tangent2End: CGPoint(x: x+r, y: y),   radius: r)
    ctx.closePath()
}

private func mochiPath(hw: CGFloat, hh: CGFloat) -> CGPath {
    let n: CGFloat = 3.2
    let path = CGMutablePath()
    let steps = 96
    for i in 0...steps {
        let a = CGFloat(i)/CGFloat(steps)*2 * .pi
        let ca = cos(a), sa = sin(a)
        let px = hw * (ca < 0 ? -1 : 1) * pow(abs(ca), 2/n)
        let py = hh * (sa < 0 ? -1 : 1) * pow(abs(sa), 2/n)
        if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
        else { path.addLine(to: CGPoint(x: px, y: py)) }
    }
    path.closeSubpath(); return path
}

private func whiteFill(_ ctx: CGContext, _ path: CGPath,
                       x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let c0 = CGColor(red: 251/255, green: 251/255, blue: 252/255, alpha: 1)
    let c1 = CGColor(red: 231/255, green: 233/255, blue: 236/255, alpha: 1)
    guard let g = CGGradient(colorsSpace: cs, colors: [c0,c1] as CFArray, locations: [0,1]) else { return }
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.drawLinearGradient(g, start: CGPoint(x: x0, y: y0),
                              end:   CGPoint(x: x1, y: y1),
                              options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Left hand: ball, waves (bobs vertically)
private func drawHandL(_ ctx: CGContext, hw: CGFloat, hh: CGFloat, p: GreetPose) {
    let k = CGFloat(p.handL); guard k > 0.01 else { return }
    let hb = hh * 2
    let r  = hb * 0.15 * k
    let rx = gLerpF(-hw * 0.35, -hw - hb * 0.22, k)
    let ry0 = gLerpF(hh * 0.85, hh * 0.62, k)
    var ry = Double(ry0)
    if p.wave >= 0 {
        let w = p.wave
        // Ramp in 0.08 s after pop1; ramp out over tuck0→tuck1
        let rampIn  = gClamp(w / 0.08, 0, 1)
        let waveEnd = GT.tuck0 - GT.pop1   // = 1.00
        let rampOut = 1 - gClamp((w - waveEnd) / (GT.tuck1 - GT.tuck0), 0, 1)
        let ramp    = rampIn * rampOut
        ry += sin(w * 2 * .pi * 5.0) * Double(hb) * 0.14 * ramp
    }
    ctx.saveGState()
    ctx.translateBy(x: rx, y: CGFloat(ry))
    let circ = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: r*2, height: r*2), transform: nil)
    whiteFill(ctx, circ, x0: r, y0: -r, x1: -r, y1: r)
    ctx.addEllipse(in: CGRect(x: -r, y: -r, width: r*2, height: r*2))
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.08))
    ctx.setLineWidth(0.8); ctx.strokePath()
    ctx.restoreGState()
}

// Right hand: capsule, quasi-static with breathing rotation ±0.04 rad at 2.5 Hz
private func drawHandR(_ ctx: CGContext, hw: CGFloat, hh: CGFloat, p: GreetPose) {
    let k = CGFloat(p.handR); guard k > 0.01 else { return }
    let hb = hh * 2, L = hb * 0.40 * k, T2 = hb * 0.22 * k
    let rx0 = gLerpF(hw * 0.35, hw + hb * 0.20, k)
    let ry0 = gLerpF(hh * 0.85, hh * 0.20, k)
    // Breathing rotation ±0.04 rad at 2.5 Hz, only while wave is active; no displacement
    let ang: CGFloat = p.wave >= 0
        ? -0.61 + CGFloat(sin(p.wave * 2 * .pi * 2.5)) * 0.04
        : -0.61
    ctx.saveGState()
    ctx.translateBy(x: rx0, y: ry0)
    ctx.rotate(by: ang)
    let cap = CGMutablePath()
    gRR(ctx, -L/2, -T2/2, L, T2, T2/2)
    cap.addPath(ctx.path!)
    ctx.beginPath()
    whiteFill(ctx, cap, x0: L/2, y0: -T2/2, x1: -L/2, y1: T2/2)
    gRR(ctx, -L/2, -T2/2, L, T2, T2/2)
    ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.08))
    ctx.setLineWidth(0.8); ctx.strokePath()
    ctx.restoreGState()
}

private func drawMochi(_ ctx: CGContext, p: GreetPose) {
    let hh = CGFloat(p.hb/2), hw = hh*GASP; guard hh > 0.4 else { return }

    // Halo (golden → blue)
    if p.halo > 0 {
        let bl = CGFloat(p.haloBlue)
        let cr = gLerpF(232/255, 59/255, bl)
        let cg = gLerpF(195/255, 158/255, bl)
        let cb = gLerpF(154/255, 255/255, bl)
        let cs = CGColorSpaceCreateDeviceRGB()
        let px = CGFloat(p.x), py = CGFloat(p.y)
        let R1 = hw * 2.6
        let ic1 = CGColor(red: cr, green: cg, blue: cb, alpha: CGFloat(0.18 * p.halo))
        let oc1 = CGColor(red: cr, green: cg, blue: cb, alpha: 0)
        if let g1 = CGGradient(colorsSpace: cs, colors: [ic1,oc1] as CFArray, locations: [0,1]) {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: px-R1, y: py-R1, width: R1*2, height: R1*2))
            ctx.clip()
            ctx.drawRadialGradient(g1, startCenter: CGPoint(x: px,y: py), startRadius: 0,
                                   endCenter: CGPoint(x: px,y: py), endRadius: R1, options: [])
            ctx.restoreGState()
        }
        let R2 = hw * 4.2
        let ic2 = CGColor(red: cr, green: cg, blue: cb, alpha: CGFloat(0.07 * p.halo))
        let oc2 = CGColor(red: cr, green: cg, blue: cb, alpha: 0)
        if let g2 = CGGradient(colorsSpace: cs, colors: [ic2,oc2] as CFArray, locations: [0,1]) {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: px-R2, y: py-R2, width: R2*2, height: R2*2))
            ctx.clip()
            ctx.drawRadialGradient(g2, startCenter: CGPoint(x: px,y: py), startRadius: 0,
                                   endCenter: CGPoint(x: px,y: py), endRadius: R2, options: [])
            ctx.restoreGState()
        }
    }

    ctx.saveGState()
    ctx.translateBy(x: CGFloat(p.x), y: CGFloat(p.y))
    ctx.rotate(by: CGFloat(p.tilt))
    ctx.scaleBy(x: CGFloat(p.sx), y: CGFloat(p.sy))

    drawHandL(ctx, hw: hw, hh: hh, p: p)
    drawHandR(ctx, hw: hw, hh: hh, p: p)

    let mpath = mochiPath(hw: hw, hh: hh)
    whiteFill(ctx, mpath, x0: hw*0.6, y0: -hh, x1: -hw*0.6, y1: hh)

    if p.tint > 0 {
        let cs = CGColorSpaceCreateDeviceRGB()
        let c0 = CGColor(red: 127/255, green: 180/255, blue: 234/255, alpha: CGFloat(p.tint))
        let c1 = CGColor(red: 127/255, green: 180/255, blue: 234/255, alpha: 0)
        if let g = CGGradient(colorsSpace: cs, colors: [c0,c1] as CFArray, locations: [0,1]) {
            ctx.saveGState()
            ctx.addPath(mpath); ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: hh),
                                      end:   CGPoint(x: 0, y: -hh*0.1), options: [])
            ctx.restoreGState()
        }
    }

    ctx.saveGState()
    ctx.addPath(mpath); ctx.clip()
    ctx.setFillColor(gHex("#16171A"))
    ctx.setStrokeColor(gHex("#16171A"))
    let er = CGFloat(p.hb*0.06)
    let sp = CGFloat(p.hb*0.19)
    let lx = CGFloat(p.lookX)*hw*0.42
    let ly = CGFloat(p.lookY)*hh*0.28 + hh*0.12 + CGFloat(p.eyeRoll)*hh*1.25
    for sd: CGFloat in [-1, 1] {
        ctx.saveGState()
        ctx.translateBy(x: sd*sp+lx, y: ly)
        if p.eye == .happy {
            ctx.setLineWidth(er*0.95); ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.addArc(center: CGPoint(x: 0, y: er*0.6), radius: er*1.25,
                       startAngle: .pi*1.15, endAngle: .pi*1.85, clockwise: false)
            ctx.strokePath()
        } else if p.eye == .content {
            ctx.setLineWidth(er*0.95); ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.addArc(center: CGPoint(x: 0, y: -er*0.5), radius: er*1.25,
                       startAngle: .pi*0.15, endAngle: .pi*0.85, clockwise: false)
            ctx.strokePath()
        } else {
            ctx.scaleBy(x: 1, y: max(0.12, CGFloat(p.open)))
            ctx.addEllipse(in: CGRect(x: -er, y: -er, width: er*2, height: er*2))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // Activity badge
    if p.badge > 0.01 {
        let bs = CGFloat(p.badge)
        let br = hh*0.3
        ctx.saveGState()
        ctx.translateBy(x: -hw*0.78, y: -hh*0.72)
        ctx.scaleBy(x: bs, y: bs)
        ctx.setFillColor(gHex("#000000"))
        ctx.addEllipse(in: CGRect(x: -(br+hh*0.07), y: -(br+hh*0.07),
                                  width: (br+hh*0.07)*2, height: (br+hh*0.07)*2))
        ctx.fillPath()
        ctx.setFillColor(gHex("#3BA0F5"))
        ctx.addEllipse(in: CGRect(x: -br, y: -br, width: br*2, height: br*2))
        ctx.fillPath()
        ctx.setFillColor(gHex("#0B1B3A"))
        for i: CGFloat in [-1, 0, 1] {
            ctx.addEllipse(in: CGRect(x: i*br*0.5-br*0.17, y: -br*0.17,
                                      width: br*0.34, height: br*0.34))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    ctx.restoreGState()
}

private func drawParticles(_ ctx: CGContext, t: Double, tc: Double, p: GreetPose) {
    guard p.card > 0 || p.fx < 1 else { return }
    let fx = p.fx

    // WARP STREAKS: white vertical lines, fall-in 0 → 0.55 s
    if t < 0.55 {
        for s in greetParticles.warps {
            guard t >= s.t0 else { continue }
            let elapsed = t - s.t0
            let yBot = CGFloat(elapsed * s.speed)
            let yTop = yBot - CGFloat(s.len)
            guard yBot > 0 else { continue }
            let streakX  = CGFloat(320 - p.iw/2 + s.xNorm * p.iw)
            let fadeOut  = 1 - gSeg(t, 0.40, 0.55)
            let alpha    = CGFloat(s.alpha * fx * fadeOut)
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            ctx.setLineWidth(CGFloat(s.thick)); ctx.setLineCap(.butt)
            ctx.beginPath()
            ctx.move(to:    CGPoint(x: streakX, y: max(0, yTop)))
            ctx.addLine(to: CGPoint(x: streakX, y: min(150, yBot)))
            ctx.strokePath()
        }
    }

    // RING: single white burst at 0.45 s, ~90 dots
    let ringT0 = 0.45
    let k = gSeg(t, ringT0, ringT0 + 1.35)
    if k > 0 && k < 1 {
        let rx   = gLerpF(14, 380, CGFloat(GE.out(k)))
        let ry   = rx * 0.34
        let fade = CGFloat((1-k) * (k < 0.08 ? k/0.08 : 1) * fx * p.card)
        for dot in greetParticles.ring {
            let r: CGFloat = 1 + CGFloat(dot.j)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1,
                                     alpha: CGFloat(dot.al) * fade))
            let dx = CGFloat(GC0.x) + cos(CGFloat(dot.a)) * rx * r
            let dy = CGFloat(GC0.y) + sin(CGFloat(dot.a)) * ry * r
            ctx.fill(CGRect(x: dx, y: dy, width: CGFloat(dot.s), height: CGFloat(dot.s)))
        }
    }
}

private func drawHeader(_ ctx: CGContext, alpha: Double) {
    guard alpha > 0 else { return }
    ctx.saveGState()
    ctx.setAlpha(CGFloat(alpha))
    gRR(ctx, 18, 4, 44, 26, 13)
    ctx.setFillColor(gHex("#1D1F23")); ctx.fillPath()
    ctx.setFillColor(gHex("#F5F6F8"))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 33, y: 20)); ctx.addLine(to: CGPoint(x: 40, y: 13))
    ctx.addLine(to: CGPoint(x: 47, y: 20)); ctx.addLine(to: CGPoint(x: 47, y: 25))
    ctx.addLine(to: CGPoint(x: 33, y: 25)); ctx.closePath(); ctx.fillPath()
    ctx.setFillColor(gHex("#8E939C"))
    ctx.addEllipse(in: CGRect(x: 75.5, y: 10.5, width: 13, height: 13)); ctx.fillPath()
    ctx.addEllipse(in: CGRect(x: 572, y: 11, width: 12, height: 12)); ctx.fillPath()
    ctx.setFillColor(gHex("#000000"))
    ctx.addEllipse(in: CGRect(x: 575.6, y: 14.6, width: 4.8, height: 4.8)); ctx.fillPath()
    ctx.restoreGState()
}

private let miniColors = ["#E86A6A","#3E86E0","#EFAE5A","#8C73F2"]

private func drawMinis(_ ctx: CGContext, alpha: Double, compact: IslandRestingLayout) {
    guard alpha > 0.01 else { return }
    let cx = 320 - compact.width/2 + compact.miniGridCenterX
    let cy = compact.botCenterY
    let sp: CGFloat = 6 * compact.miniGridScale
    let offsets: [(CGFloat, CGFloat)] = [(-sp,-sp),(sp,-sp),(-sp,sp),(sp,sp)]
    for (i,(dx,dy)) in offsets.enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: cx+dx, y: cy+dy)
        let scale = CGFloat(alpha) * compact.miniGridScale
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(gHex(miniColors[i]))
        ctx.addPath(mochiPath(hw: 5.3, hh: 4)); ctx.fillPath()
        ctx.restoreGState()
    }
}

// MARK: - Full draw

private func drawGreeting(_ ctx: CGContext, size: CGSize, t: Double,
                          tc: Double, compact: IslandRestingLayout) {
    let p = pose(t, tc: tc, compact: compact)

    if p.card > 0 {
        ctx.saveGState()
        ctx.setAlpha(CGFloat(p.card))
        gRR(ctx, GCARD.minX, GCARD.minY, GCARD.width, GCARD.height, GCARD_R)
        ctx.setFillColor(gHex("#141518")); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        gRR(ctx, GCARD.minX, GCARD.minY, GCARD.width, GCARD.height, GCARD_R)
        ctx.clip()
        drawParticles(ctx, t: t, tc: tc, p: p)
        ctx.restoreGState()
    } else if tc.isFinite && t >= tc {
        ctx.saveGState()
        drawParticles(ctx, t: t, tc: tc, p: p)
        ctx.restoreGState()
    }

    drawMinis(ctx, alpha: p.minis, compact: compact)
    drawMochi(ctx, p: p)
}

// MARK: - SwiftUI View

struct GreetingCanvasView: View {
    @ObservedObject var state: AppState

    @State private var startDate = Date()
    @State private var tc: Double = .infinity
    @State private var greetFired = false
    @State private var doneWork: DispatchWorkItem? = nil

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(startDate)
            Canvas { context, size in
                context.withCGContext { cgCtx in
                    drawGreeting(cgCtx, size: size, t: t, tc: tc,
                                 compact: IslandRestingLayout(width: state.notchWidth + 160,
                                                              height: state.notchHeight))
                }
            }
            .onChange(of: !greetFired && t >= GT.end && tc >= GT.autoLeave) { _, trigger in
                if trigger { fireGreetComplete() }
            }
        }
        .onAppear {
            startDate = Date()
            tc = .infinity
            greetFired = false
            // Original score plays from the start; greet.wav and blip.wav kept for other uses
            SoundEngine.shared.play("greeting")
            // Safety fallback: fire done if timeline onChange misses it
            let item = DispatchWorkItem { fireGreetComplete() }
            doneWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + GT.end + 0.05, execute: item)
        }
        .onDisappear {
            doneWork?.cancel(); doneWork = nil
            SoundEngine.shared.fadeOut("greeting", duration: 0.2)
        }
        .onReceive(NotificationCenter.default.publisher(for: .greetingHover)) { _ in
            if tc >= GT.autoLeave { tc = .infinity }
        }
        .onReceive(NotificationCenter.default.publisher(for: .greetingInterrupt)) { _ in
            let t = Date().timeIntervalSince(startDate)
            if tc.isInfinite || tc > t { tc = t }
            doneWork?.cancel(); doneWork = nil
            SoundEngine.shared.fadeOut("greeting", duration: 0.25)
        }
    }

    private func fireGreetComplete() {
        guard !greetFired else { return }
        greetFired = true
        doneWork?.cancel(); doneWork = nil
        // Note: greeting music continues for ~0.3 s after greetComplete — intentional queue overlap
        NotificationCenter.default.post(name: .greetComplete, object: nil)
    }
}
