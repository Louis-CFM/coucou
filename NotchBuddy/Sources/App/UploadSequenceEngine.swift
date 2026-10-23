import Foundation
import CoreGraphics

// ============================================================
// CONSTANTS — exact mirror of upload-sequence.html
// All values in island-coordinate points (island = 640 × 176)
// ============================================================

enum USC {
    static let W:     Double = 640
    static let ISL_H: Double = 176
    static let CARD_X: Double = 10;  static let CARD_Y: Double = 42
    static let CARD_W: Double = 620; static let CARD_H: Double = 124; static let CARD_R: Double = 20
    static let REST_X: Double = 140; static let REST_Y: Double = 104
    static let D_BOX:  Double = 62
    static let FOLLOW_MIN: Double = 60    // CARD_X + 50
    static let FOLLOW_MAX: Double = 580   // CARD_X + CARD_W - 50
    static let TEXT_X: Double = 196;  static let TEXT_Y: Double = 94
    static let BAR_X0: Double = 46;   static let BAR_X1: Double = 520;  static let BAR_Y: Double = 118
    static let CHOOSE_X: Double = 60; static let CHOOSE_Y: Double = 101; static let CHOOSE_D: Double = 62
    static let LOCK_IN:  Double = 60
    static let LOCK_OUT: Double = 90
    static let MOUTH_AJAR: Double = 0.20
    static let MOUTH_OPEN: Double = 0.42
    static let MOUTH_MAX:  Double = 0.50
    // Phase timestamps (t_ref, drop = 1.95)
    static let T_DROP:       Double = 1.95
    static let T_SUCK_START: Double = 2.03
    static let T_SUCK_END:   Double = 2.33
    static let T_CLOSE_END:  Double = 2.42
    static let T_CHEW1:      Double = 2.60
    static let T_CHEW_END:   Double = 2.88
    static let T_SHRINK_END: Double = 3.23
    static let T_BAR_IN:     Double = 3.00
    static let T_PROG_START: Double = 3.25
    static let DT: Double = 1.0 / 240.0
    // Entry offset: gives 0.40 s of following before drop
    static let ENTRY_T_REF: Double = T_DROP - 0.40  // = 1.55
}

// ============================================================
// EASING — port of reference E.out / E.in / E.inOut / E.back
// ============================================================

func usEOut(_ t: Double) -> Double   { 1 - pow(1-t, 3) }
func usEIn(_ t: Double)  -> Double   { t*t*t }
func usEInOut(_ t: Double) -> Double { t < 0.5 ? 4*t*t*t : 1 - pow(-2*t+2,3)/2 }
func usEBack(_ t: Double) -> Double  { let c1=1.70158,c3=c1+1; return 1+c3*pow(t-1,3)+c1*pow(t-1,2) }

func usSeg(_ t: Double, _ a: Double, _ b: Double) -> Double { max(0, min(1,(t-a)/(b-a))) }
func usLerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a+(b-a)*t }

// Squeeze keyframes for suckEnd→chew1 phase (inline to avoid Swift @escaping issues)
func usSqueezeY(_ t: Double) -> Double {
    let t0=USC.T_SUCK_END, t1=t0+0.07, t2=t0+0.20, t3=USC.T_CHEW1
    if t<=t0 { return 1.06 }
    if t<=t1 { return usLerp(1.06, 0.82, usEOut(usSeg(t,t0,t1))) }
    if t<=t2 { return usLerp(0.82, 1.10, usEOut(usSeg(t,t1,t2))) }
    if t<=t3 { return usLerp(1.10, 1.00, usEInOut(usSeg(t,t2,t3))) }
    return 1.0
}
func usSqueezeX(_ t: Double) -> Double {
    let t0=USC.T_SUCK_END, t1=t0+0.07, t2=t0+0.20, t3=USC.T_CHEW1
    if t<=t0 { return 0.97 }
    if t<=t1 { return usLerp(0.97, 1.14, usEOut(usSeg(t,t0,t1))) }
    if t<=t2 { return usLerp(1.14, 0.95, usEOut(usSeg(t,t1,t2))) }
    if t<=t3 { return usLerp(0.95, 1.00, usEInOut(usSeg(t,t2,t3))) }
    return 1.0
}

func usProgressCurve(_ u: Double) -> Double {
    if u < 0.40  { return 0.60 * usEOut(u/0.40) }
    if u < 0.85  { return 0.60 + 0.32 * usEInOut((u-0.40)/0.45) }
    return 0.92 + 0.08 * usEIn((u-0.85)/0.15)
}
func usProgressAt(_ t: Double, progStart: Double, progEnd: Double) -> Double {
    t < progStart ? 0 : usProgressCurve(usSeg(t, progStart, progEnd))
}

// ============================================================
// SPRING — port of reference spring(s, target, response, damping, dt)
// ============================================================

struct USSpring {
    var v:   Double
    var vel: Double = 0
    mutating func step(target: Double, response: Double, damping: Double, dt: Double) {
        let k = pow(2 * .pi / response, 2)
        let c = 2 * damping * sqrt(k)
        let a = k*(target-v) - c*vel
        vel += a*dt; v += vel*dt
    }
}

// ============================================================
// SIMULATION STATE — mirrors reference newSim()
// ============================================================

struct USSimState {
    var t:       Double = 0
    var bx:      USSpring = USSpring(v: USC.REST_X)
    var by:      USSpring = USSpring(v: USC.REST_Y)
    var tilt:    Double = 0
    var mouth:   USSpring = USSpring(v: 0)
    var locked:  Bool = false
    var lockAt:  Double = -9
    var entered: Double = -9  // t_ref of zone entry; -9 = not entered
    var gulp:    Bool = false
    var ok:      Bool = false
    var lastPct: Int = 0
}

// ============================================================
// FRAME DATA — output of frame(), read by UploadCanvasView
// ============================================================

enum USEyeShape { case pill, cup, content }

struct USMouthRect { var x,y,w,h: Double }

struct USFrame {
    var t: Double = 0
    var cursorX: Double = 600; var cursorY: Double = 280
    var morph: Double = 0
    var x: Double = USC.REST_X; var y: Double = USC.REST_Y; var d: Double = USC.D_BOX
    var sx: Double = 1; var sy: Double = 1; var tilt: Double = 0; var hop: Double = 0
    var mouth: Double = 0
    var mouthRect = USMouthRect(x:0,y:0,w:0,h:0)
    var eye: USEyeShape = .pill
    var lookX: Double = 0; var lookY: Double = 0
    var fileVisible: Bool = true; var suck: Double = 0
    var zoneOver:    Bool   = false
    var zoneAlpha:   Double = 1
    var textAlpha:   Double = 1
    var barReveal:   Double = 0
    var barAlpha:    Double = 0
    var progress:    Double = 0
    var flash:       Double = 0
    var check:       Double = 0
    var greenWash:   Double = 0
    var chooseAlpha: Double = 0
    var uploadDuration: Double = 2.4
    var progEnd:    Double = USC.T_PROG_START + 2.4
    var growStart:  Double = USC.T_PROG_START + 2.4 + 0.25
    var growEnd:    Double = USC.T_PROG_START + 2.4 + 0.70
}

// ============================================================
// ENGINE
// ============================================================

@MainActor
final class UploadSequenceEngine {
    static let shared = UploadSequenceEngine()

    var uploadDuration: Double = 2.4
    var progEnd:   Double { USC.T_PROG_START + uploadDuration }
    var growStart: Double { progEnd + 0.25 }
    var growEnd:   Double { progEnd + 0.70 }

    private(set) var isActive: Bool = false
    private var entryWallTime: Double = 0   // Date().timeIntervalSinceReferenceDate at entry
    private var dropWallTime:  Double? = nil

    private var sim = USSimState()

    // Real cursor in island coords
    var cursorX: Double = 600
    var cursorY: Double = 280
    private var prevCursorX:  Double = 600
    private var prevCursorY:  Double = 280
    private var prevCursorTime: Double = 0
    private var cursorSpeed: Double = 0

    // MARK: - Session lifecycle

    func enterZone(x: CGFloat, y: CGFloat) {
        let now = Date().timeIntervalSinceReferenceDate
        cursorX = Double(x); cursorY = Double(y)
        prevCursorX = cursorX; prevCursorY = cursorY; prevCursorTime = now
        cursorSpeed = 0
        sim = USSimState()
        sim.t       = USC.ENTRY_T_REF
        sim.entered = USC.ENTRY_T_REF
        sim.bx      = USSpring(v: USC.REST_X)
        sim.by      = USSpring(v: USC.REST_Y)
        entryWallTime = now
        dropWallTime  = nil
        isActive      = true
    }

    func updateCursor(x: CGFloat, y: CGFloat) {
        let now = Date().timeIntervalSinceReferenceDate
        let dt = now - prevCursorTime
        if dt > 0.001 {
            let dx = Double(x) - prevCursorX, dy = Double(y) - prevCursorY
            cursorSpeed = hypot(dx, dy) / dt
        }
        prevCursorX = Double(x); prevCursorY = Double(y); prevCursorTime = now
        cursorX = Double(x); cursorY = Double(y)
    }

    func exitZone() {
        // Keep engine active — island stays open per spec
    }

    func performDrop(uploadDuration ud: Double) {
        uploadDuration = ud
        let now = Date().timeIntervalSinceReferenceDate
        dropWallTime = now
        // Reset sim.t to T_DROP so the canonical post-drop timeline starts correctly,
        // regardless of how long the user hovered. Spring state (position/velocity) is preserved.
        sim.t = USC.T_DROP
    }

    func deactivate() {
        isActive = false
        dropWallTime = nil
    }

    // MARK: - t_ref from wall clock

    func tRef(at date: Date) -> Double {
        guard isActive else { return 0 }
        let now = date.timeIntervalSinceReferenceDate
        if let dw = dropWallTime {
            return USC.T_DROP + max(0, now - dw)
        }
        // No cap — spring keeps stepping as long as user hovers.
        // computeFrame clamps phase-sensitive outputs to pre-drop state.
        let elapsed = max(0, now - entryWallTime)
        return USC.ENTRY_T_REF + elapsed
    }

    // MARK: - Public entry point

    func frame(at date: Date) -> USFrame {
        guard isActive else { return USFrame() }
        let t = tRef(at: date)
        simulateTo(t)
        return computeFrame(t: t)
    }

    // MARK: - Simulation

    private func simulateTo(_ tTarget: Double) {
        while sim.t < tTarget - 1e-10 {
            let dt = min(USC.DT, tTarget - sim.t)
            stepOnce(dt: dt)
            sim.t += dt
        }
    }

    private func stepOnce(dt: Double) {
        let isDragging = (dropWallTime == nil)

        // Horizontal follow + lock (only while dragging and in zone)
        if isDragging && sim.entered >= 0 {
            let dist = hypot(cursorX - sim.bx.v, (cursorY + 14) - sim.by.v)
            if !sim.locked && dist < USC.LOCK_IN && cursorSpeed < 180 {
                sim.locked = true; sim.lockAt = sim.t
            }
            if sim.locked && dist > USC.LOCK_OUT { sim.locked = false }
            let tx = max(USC.FOLLOW_MIN, min(USC.FOLLOW_MAX, cursorX))
            if sim.locked {
                sim.bx.step(target: tx,      response:0.18, damping:0.75, dt:dt)
                sim.by.step(target: USC.REST_Y, response:0.18, damping:0.75, dt:dt)
            } else {
                sim.bx.step(target: tx,      response:0.35, damping:0.70, dt:dt)
                sim.by.step(target: USC.REST_Y, response:0.35, damping:0.70, dt:dt)
            }
        }

        // Tilt
        let tiltTarget = isDragging ? max(-0.18, min(0.18, sim.bx.vel * 0.0015)) : 0.0
        sim.tilt = usLerp(sim.tilt, tiltTarget, 1 - pow(0.0005, dt))

        // Mouth — post-drop close only after drop has actually happened
        let t = sim.t
        if !isDragging && t >= USC.T_SUCK_END {
            sim.mouth.v = max(0, usLerp(USC.MOUTH_MAX, 0, usEIn(usSeg(t, USC.T_SUCK_END, USC.T_CLOSE_END))))
        } else {
            var mt = 0.0
            if sim.entered >= 0 {
                mt = (sim.locked || !isDragging) ? USC.MOUTH_OPEN : USC.MOUTH_AJAR
            }
            if !isDragging && t < USC.T_SUCK_END { mt = USC.MOUTH_MAX }
            sim.mouth.step(target: mt, response:0.25, damping:0.60, dt:dt)
            if sim.mouth.v < 0 { sim.mouth.v = 0 }
        }
    }

    // MARK: - Frame computation (mirrors reference frame(t))

    private func computeFrame(t: Double) -> USFrame {
        var f = USFrame()
        f.t = t
        f.cursorX = cursorX; f.cursorY = cursorY
        f.uploadDuration = uploadDuration
        f.progEnd   = progEnd
        f.growStart = growStart
        f.growEnd   = growEnd

        let entered    = sim.entered >= 0 ? sim.entered : 1e9
        let isDragging = (dropWallTime == nil)
        // For all phase-based calculations, clamp t to just before T_DROP while pre-drop
        // so long hovers don't accidentally trigger post-drop visuals.
        let pt = isDragging ? min(t, USC.T_DROP - USC.DT) : t

        // Morph: 0→1 (entry), 1→0 (shrink to ball), 0→1 (grow back to box at choose)
        var morph: Double
        if pt < USC.T_CHEW_END {
            morph = usEBack(usSeg(pt, entered, entered + 0.38))
        } else if pt < growStart {
            morph = 1 - usEOut(usSeg(pt, USC.T_CHEW_END, USC.T_SHRINK_END))
        } else {
            morph = usEBack(usSeg(pt, growStart, growEnd))
        }
        morph = max(0, min(morph, 1.08))
        f.morph = morph

        // Position / diameter
        var x = sim.bx.v, y = sim.by.v, d = USC.D_BOX
        if pt >= USC.T_CHEW_END && pt < USC.T_PROG_START {
            let k = usEInOut(usSeg(pt, USC.T_CHEW_END, USC.T_SHRINK_END))
            x = usLerp(sim.bx.v, USC.BAR_X0, k)
            y = usLerp(sim.by.v, USC.BAR_Y,  k)
            d = usLerp(USC.D_BOX, 14, k)
        }
        if pt >= USC.T_PROG_START {
            let p = usProgressAt(pt, progStart: USC.T_PROG_START, progEnd: progEnd)
            x = usLerp(USC.BAR_X0, USC.BAR_X1, p); y = USC.BAR_Y; d = 14
        }
        if pt >= progEnd {
            x = USC.BAR_X1
            y = USC.BAR_Y - 8 * sin(.pi * usSeg(pt, progEnd, progEnd + 0.20))
        }
        if pt >= growStart {
            x = usLerp(USC.BAR_X1,  USC.CHOOSE_X, usEInOut(usSeg(pt, growStart, growEnd)))
            y = usLerp(USC.BAR_Y,   USC.CHOOSE_Y, usEInOut(usSeg(pt, growStart, growEnd)))
            d = usLerp(14, USC.CHOOSE_D, usEBack(usSeg(pt, growStart, growEnd)))
        }
        f.x = x; f.y = y; f.d = d

        // Squeeze
        var sx = 1.0, sy = 1.0
        if pt >= USC.T_DROP && pt < USC.T_SUCK_START {
            let k = usEOut(usSeg(pt, USC.T_DROP, USC.T_SUCK_START))
            sy = usLerp(1, 0.92, k); sx = usLerp(1, 1.06, k)
        }
        if pt >= USC.T_SUCK_START && pt < USC.T_SUCK_END {
            let k = usEInOut(usSeg(pt, USC.T_SUCK_START, USC.T_SUCK_END))
            sy = usLerp(0.92, 1.06, k); sx = usLerp(1.06, 0.97, k)
        }
        if pt >= USC.T_SUCK_END && pt < USC.T_CHEW1 {
            sy = usSqueezeY(pt); sx = usSqueezeX(pt)
        }
        if pt >= USC.T_CHEW1 && pt < USC.T_CHEW_END {
            let k = ((pt-USC.T_CHEW1).truncatingRemainder(dividingBy: 0.14)) / 0.14
            sy = 1 - 0.05*sin(.pi*k); sx = 1 + 0.03*sin(.pi*k)
        }
        if pt >= USC.T_CHEW_END && pt < USC.T_SHRINK_END {
            let k = usSeg(pt, USC.T_CHEW_END, USC.T_SHRINK_END)
            sy = 1 + 0.12*sin(.pi*k); sx = 1 - 0.06*sin(.pi*k)
        }
        if pt >= USC.T_PROG_START && pt < progEnd {
            let v = (usProgressAt(pt+0.01, progStart: USC.T_PROG_START, progEnd: progEnd)
                   - usProgressAt(pt,      progStart: USC.T_PROG_START, progEnd: progEnd)) / 0.01
            let st = max(0, min(1, v*0.18))
            sx = 1 + 0.25*st; sy = 1 - 0.15*st
        }
        if pt >= growStart && pt < growEnd {
            sy = 1 + 0.06*sin(.pi * usSeg(pt, growStart, growEnd))
        }
        f.sx = sx; f.sy = sy; f.tilt = sim.tilt
        f.hop = (sim.lockAt > 0 && isDragging)
            ? -5 * sin(.pi * usSeg(pt, sim.lockAt, sim.lockAt + 0.15)) : 0

        f.mouth = sim.mouth.v

        // Eyes
        var eye: USEyeShape = .pill
        if sim.locked && pt < USC.T_SUCK_END { eye = .cup }
        if pt >= USC.T_SUCK_END && pt < USC.T_CHEW_END + 0.10 { eye = .content }
        if pt >= progEnd && pt < growEnd + 0.30 { eye = .content }
        f.eye = eye

        let lkx = pt < USC.T_SUCK_END ? cursorX - x : (pt < USC.T_PROG_START ? 0.0 : 40.0)
        let lky = pt < USC.T_SUCK_END ? (cursorY+10) - y : 0.0
        f.lookX = max(-1, min(1, lkx/200)); f.lookY = max(-1, min(1, lky/150))

        f.fileVisible = pt < USC.T_SUCK_END
        f.suck = usSeg(pt, USC.T_SUCK_START, USC.T_SUCK_END)

        // Content alpha values
        f.zoneOver   = sim.entered >= 0 && pt < USC.T_CHEW_END
        f.zoneAlpha  = 1 - usSeg(pt, USC.T_CHEW_END, USC.T_CHEW_END + 0.20)
        f.textAlpha  = f.zoneAlpha
        f.barReveal  = usEOut(usSeg(pt, USC.T_BAR_IN, USC.T_BAR_IN+0.25))
                     * (1 - usSeg(pt, growStart, growStart+0.20))
        f.barAlpha   = usSeg(pt, USC.T_BAR_IN+0.05, USC.T_BAR_IN+0.25)
                     * (1 - usSeg(pt, growStart, growStart+0.20))
        f.progress   = usProgressAt(pt, progStart: USC.T_PROG_START, progEnd: progEnd)
        f.flash      = pt >= progEnd ? sin(.pi * usSeg(pt, progEnd, progEnd+0.30)) : 0
        f.check      = pt >= progEnd ? usEBack(usSeg(pt, progEnd, progEnd+0.25)) : 0
        let hoverGreen = f.zoneOver ? 0.22 : 0.0
        var uploadGreen = 0.0
        if pt >= USC.T_PROG_START {
            // Grows gradually from 0→0.50 as upload progresses (tied to f.progress)
            let baseGreen = f.progress * 0.50
            // Brief flash burst at completion
            let flashExtra = pt >= progEnd ? 0.20 * sin(.pi * usSeg(pt, progEnd, progEnd + 0.40)) : 0
            // Fade out as Mochi grows back to choose position
            let fadeOut = 1.0 - usSeg(pt, growEnd, growEnd + 0.60)
            uploadGreen = (baseGreen + flashExtra) * fadeOut
        }
        f.greenWash = max(hoverGreen, uploadGreen)
        f.chooseAlpha = usSeg(pt, growStart+0.15, growEnd)

        // Mouth rect in island coords (used by drawFile for clipping)
        let R  = d / 2 / 1.04
        let mc = max(0, min(morph, 1.0))
        let rx = R * (1.04 - 0.04*mc)
        let ry = R * (0.97 - 0.03*mc)
        let mh = f.mouth * R * mc
        let mw = 2*rx - 0.24*R
        let mxOff = -mw/2
        let myOff = -ry + 0.10*R
        f.mouthRect = USMouthRect(
            x: x + mxOff * sx,
            y: y + f.hop + myOff * sy,
            w: mw * sx,
            h: mh * sy
        )
        return f
    }
}
