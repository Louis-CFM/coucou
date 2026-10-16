import QuartzCore
import SwiftUI

/// How the Mac feels, as Mochi shows it. Each level runs from 0 (not at all) to 1.
/// The Mac reads it (MachineVitals); the iPhone never sets it, so Mochi stays calm there.
struct MochiMood: Equatable, Sendable {
    /// The processor is at full load: Mochi sweats and breathes fast.
    var busy: CGFloat = 0
    /// The Mac is warm: Mochi flushes red, with heat waves above his head.
    var hot: CGFloat = 0
    /// Memory is short: Mochi puffs up, like after a big meal.
    var full: CGFloat = 0
    /// The battery is low: heavy eyelids, a yawn now and then.
    var tired: CGFloat = 0
    /// The battery is nearly empty: Mochi sleeps.
    var asleep = false

    static let calm = MochiMood()
}

/// A drop of sweat thrown from Mochi's side: it rises, then falls to the floor in an arc.
/// In Mochi's units (R), from his resting centre; the time is real time.
struct MoodDrop {
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var born: Double
    var size: CGFloat
    /// Each drop is its own: long or round, lighter or deeper blue, more or less clear.
    var stretch: CGFloat
    var tint: CGFloat
    var alpha: Double
    var wobble: CGFloat
}

/// One of Mochi's stressed hops, from side to side.
struct MoodHop {
    var from: CGFloat = 0
    var to: CGFloat = 0
    var start: Double = 0
    var duration: Double = 0.2
    var height: CGFloat = 0
    var rest: Double = 0
    var landed = true
}

// MARK: - Mochi's moods

extension BotEngine {
    /// States where the Mac's mood shows: Mochi is not asking for anything.
    private var moodShows: Bool {
        switch state {
        case .idle, .working, .thinking, .searching, .finished: return true
        default: return false
        }
    }

    /// Gravity of the sweat drops, in R per second².
    private static let dropGravity: CGFloat = 6.0

    /// Takes back last frame's hop offset before anything else moves Mochi.
    func undoMoodOffsets() {
        if moodShiftApplied != 0 { ox -= moodShiftApplied; moodShiftApplied = 0 }
        if moodLiftApplied != 0 { oy -= moodLiftApplied; moodLiftApplied = 0 }
    }

    /// Eases the mood levels towards `moodTarget` and plays their animations.
    /// Called from `update` before the look and the body scale are smoothed.
    func updateMood(dt: Double, now: Double, t: CGFloat) {
        guard !isMini else { return }
        let shows = moodShows
        let calmState = state == .idle || state == .finished
        let target = moodTarget
        let k = CGFloat(1 - pow(0.25, dt))
        moodBusy  += ((shows ? target.busy : 0) - moodBusy) * k
        moodHot   += ((shows ? target.hot : 0) - moodHot) * k
        moodFull  += ((shows ? target.full : 0) - moodFull) * k
        moodTired += ((calmState ? target.tired : 0) - moodTired) * k
        let sleeping = calmState && target.asleep

        updateStress(now: now)

        // Full memory: puffed up.
        if moodFull > 0.02 {
            tgSx *= 1 + 0.07 * moodFull
            tgSy *= 1 - 0.035 * moodFull
        }

        // Sweat: drops thrown from his sides, in bursts while the processor is at full load,
        // now and then when the Mac is only warm.
        if now > nextMoodDrop {
            if moodBusy > 0.4 {
                throwDrop(now: now)
                if Double.random(in: 0...1) < 0.35 { throwDrop(now: now) }
                nextMoodDrop = now + Double.random(in: 0.18...0.4)
            } else if moodHot > 0.6 {
                throwDrop(now: now)
                nextMoodDrop = now + Double.random(in: 0.6...1.1)
            } else {
                nextMoodDrop = now + 0.3
            }
        }
        moodDrops.removeAll { drop in
            let a = CGFloat(now - drop.born)
            return a > 1.6 || drop.y + drop.vy * a + Self.dropGravity * a * a / 2 > 1.05
        }

        // Low battery: heavy eyes, the odd yawn; nearly empty: asleep with his z's.
        let ownEye = eyeOverride == nil || eyeOverride == .tired || eyeOverride == .closed
        if sleeping {
            if ownEye { eyeOverride = .closed; eyeOverrideUntil = now + 0.4 }
            tgYaw = 0
            tgPitch = -0.14
            if now > nextMoodYawn {
                emit(.z, count: 1)
                nextMoodYawn = now + 1.6
            }
        } else if moodTired > 0.5 {
            if ownEye { eyeOverride = .tired; eyeOverrideUntil = now + 0.4 }
            tgPitch -= 0.06 * moodTired
            if now > nextMoodYawn {
                if nextMoodYawn > 0 { triggerEmote(.yawn, silent: true) }
                nextMoodYawn = now + 24 + Double.random(in: 0...12)
            }
        }
    }

    /// The processor at full load: Mochi panics, hopping from side to side at random, quick and
    /// short, leaning into each hop, squashing when he lands, eyes darting where he jumps.
    private func updateStress(now: Double) {
        let level = moodBusy
        guard level > 0.02 || abs(hop.to) > 0.005 || !hop.landed else { stressTremble = .zero; return }
        let p = hop.duration > 0 ? min(1, (now - hop.start) / hop.duration) : 1
        if p >= 1 {
            if !hop.landed {
                hop.landed = true
                // The landing squash.
                anim("sy", keys: [TweenKey(target: 0.86, duration: 60, ease: Ease.out),
                                  TweenKey(target: 1.0, duration: 140, ease: Ease.out)])
                anim("sx", keys: [TweenKey(target: 1.1, duration: 60, ease: Ease.out),
                                  TweenKey(target: 1.0, duration: 140, ease: Ease.out)])
            }
            if now > hop.start + hop.duration + hop.rest {
                // Next hop: somewhere else on the floor, never twice the same.
                var next: CGFloat = 0
                if level > 0.3 {
                    repeat { next = CGFloat.random(in: -0.28...0.28) } while abs(next - hop.to) < 0.12
                }
                hop = MoodHop(from: hop.to, to: next, start: now,
                              duration: Double.random(in: 0.22...0.4),
                              height: level > 0.3 ? CGFloat.random(in: 0.07...0.18) : 0.05,
                              rest: Double.random(in: 0.1...0.55), landed: false)
            }
        }
        let q = CGFloat(min(1, hop.duration > 0 ? (now - hop.start) / hop.duration : 1))
        let eased = q < 0.5 ? 2 * q * q : 1 - pow(-2 * q + 2, 2) / 2
        let x = hop.from + (hop.to - hop.from) * eased
        let lift = sin(.pi * q) * hop.height * (hop.landed ? 0 : 1)
        let dir: CGFloat = hop.to >= hop.from ? 1 : -1
        let amount = min(1, level * 1.4)
        if !locks.contains("ox") {
            moodShiftApplied = x * amount
            ox += moodShiftApplied
        }
        if !locks.contains("oy") {
            moodLiftApplied = -lift * amount
            oy += moodLiftApplied
        }
        if !hop.landed {
            tgTilt += dir * 0.12 * sin(.pi * q) * amount
        }

        // The look of a scared Mochi: the eyes dart from one spot to another, quick and
        // jerky, looking for a way out, tremble, and blink nervously, sometimes twice.
        if level > 0.3 {
            if now > nextStressLook {
                let back = Double.random(in: 0...1) < 0.3
                stressLook = CGPoint(x: back ? -stressLook.x * 0.8 : CGFloat.random(in: -0.85...0.85),
                                     y: CGFloat.random(in: -0.3...0.18))
                nextStressLook = now + Double.random(in: 0.16...0.45)
            }
            tgYaw = stressLook.x
            tgPitch = stressLook.y
            // Snap towards the new spot faster than a calm look.
            if !locks.contains("yaw") { yaw += (tgYaw - yaw) * 0.2 * amount }
            if !locks.contains("pitch") { pitch += (tgPitch - pitch) * 0.2 * amount }
            if now > nextNervousBlink {
                if nextNervousBlink > 0, !locks.contains("open") {
                    if Double.random(in: 0...1) < 0.3 {
                        anim("open", keys: Self.doubleBlink)
                    } else {
                        blink()
                    }
                }
                nextNervousBlink = now + Double.random(in: 1.0...2.4)
            }
        }
        let tremble = min(1, level * 1.3)
        stressTremble = tremble > 0.01
            ? CGPoint(x: sin(CGFloat(now) * 63) * 0.012 * tremble, y: cos(CGFloat(now) * 51) * 0.01 * tremble)
            : .zero
    }

    /// Two quick blinks in a row.
    private static var doubleBlink: [TweenKey] {
        [TweenKey(target: 0.06, duration: 60, ease: Ease.inOut),
         TweenKey(target: 1, duration: 90, ease: Ease.out),
         TweenKey(target: 0.06, duration: 60, ease: Ease.inOut),
         TweenKey(target: 1, duration: 120, ease: Ease.out)]
    }

    private func throwDrop(now: Double) {
        let side: CGFloat = Bool.random() ? 1 : -1
        // Now and then a small round droplet, mostly a full drop.
        let small = Double.random(in: 0...1) < 0.3
        let drop = MoodDrop(
            x: side * CGFloat.random(in: 0.92...1.05) + ox, y: CGFloat.random(in: -0.5 ... -0.25) + oy,
            vx: side * CGFloat.random(in: 0.5...1.0),
            vy: -CGFloat.random(in: 1.5...2.4),
            born: now,
            size: small ? CGFloat.random(in: 0.09...0.13) : CGFloat.random(in: 0.15...0.26),
            stretch: small ? CGFloat.random(in: 0.75...0.95) : CGFloat.random(in: 1.0...1.55),
            tint: CGFloat.random(in: 0...1),
            alpha: Double.random(in: 0.7...1),
            wobble: CGFloat.random(in: 0...(2 * .pi)))
        moodDrops.append(drop)
        if moodDrops.count > 28 { moodDrops.removeFirst() }
    }

    /// Red cheeks and a flushed body while the Mac is warm (inside the body's transform).
    func drawMoodTint(ctx: inout GraphicsContext, path: Path, rx: CGFloat, ry: CGFloat) {
        guard moodHot > 0.01, morph < 0.5, !isMini else { return }
        let a = Double(moodHot) * (1 - Double(morph) * 2)
        ctx.fill(path, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(red: 1, green: 0.36, blue: 0.24).opacity(0.42 * a), location: 0),
                .init(color: Color(red: 1, green: 0.36, blue: 0.24).opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: ry),
            endPoint: CGPoint(x: 0, y: -ry * 0.6)
        ))
    }

    /// What goes over Mochi in world space: sweat drops and heat waves.
    func drawMoodExtras(context: GraphicsContext, R: CGFloat, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat) {
        guard !isMini, morph < 0.3 else { return }
        let real = CACurrentMediaTime()
        let now = CGFloat(real - t0)

        // Sweat: each drop follows its arc from where it left Mochi's side.
        if !moodDrops.isEmpty {
            let baseX = cx - ox * R, baseY = cy - oy * R
            for drop in moodDrops {
                let a = CGFloat(real - drop.born)
                guard a >= 0 else { continue }
                let x = drop.x + drop.vx * a
                let y = drop.y + drop.vy * a + Self.dropGravity * a * a / 2
                let vy = drop.vy + Self.dropGravity * a
                var c = context
                c.opacity = drop.alpha * Double(min(1, a / 0.06) * min(1, max(0, (1.05 - y) / 0.25)))
                c.translateBy(x: baseX + x * R, y: baseY + y * R)
                c.rotate(by: .radians(atan2(vy, drop.vx) - .pi / 2))
                // It wobbles a little as it flies.
                let wob = 1 + sin(a * 22 + drop.wobble) * 0.08
                let s = R * drop.size
                let long = drop.stretch * wob
                var tear = Path()
                tear.move(to: CGPoint(x: 0, y: -s * 1.15 * long))
                tear.addQuadCurve(to: CGPoint(x: 0, y: s * 0.7), control: CGPoint(x: s * 0.9 / wob, y: s * 0.2))
                tear.addQuadCurve(to: CGPoint(x: 0, y: -s * 1.15 * long), control: CGPoint(x: -s * 0.9 / wob, y: s * 0.2))
                // From a pale sky blue to a deeper blue, lighter at the top.
                let light = Color(red: 0.72 - 0.2 * drop.tint, green: 0.88 - 0.12 * drop.tint, blue: 1)
                let deep = Color(red: 0.36 - 0.12 * drop.tint, green: 0.68 - 0.14 * drop.tint, blue: 0.98)
                c.fill(tear, with: .linearGradient(Gradient(colors: [light, deep]),
                                                   startPoint: CGPoint(x: 0, y: -s * long), endPoint: CGPoint(x: 0, y: s * 0.7)))
                c.fill(Path(ellipseIn: CGRect(x: -s * 0.36, y: -s * 0.1 * long, width: s * 0.22, height: s * 0.32 * long)),
                       with: .color(.white.opacity(0.4 + 0.35 * Double(drop.tint))))
            }
        }

        // Heat waves: three wavy lines rising above the head.
        if moodHot > 0.5 {
            let a = Double((moodHot - 0.5) * 2)
            for i in 0..<3 {
                let x0 = cx + CGFloat(i - 1) * R * 0.42
                let phase = now * 3 + CGFloat(i) * 1.7
                let rise = (now * 0.6 + CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1)
                var wave = Path()
                let top = cy - ry * 1.18 - R * 0.55 * rise
                let len = R * 0.5
                for s in 0...12 {
                    let f = CGFloat(s) / 12
                    let p = CGPoint(x: x0 + sin(phase + f * 6) * R * 0.07, y: top - f * len)
                    if s == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
                }
                var c = context
                c.opacity = a * Double(sin(rise * .pi))
                c.stroke(wave, with: .color(Color(red: 1, green: 0.55, blue: 0.3)),
                         style: StrokeStyle(lineWidth: max(1, R * 0.07), lineCap: .round))
            }
        }
    }
}
