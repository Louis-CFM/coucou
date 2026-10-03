import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Easing functions (same as prototype: E.out, E.inOut, E.back, E.lin)

enum Ease {
    static func out(_ t: CGFloat) -> CGFloat   { 1 - pow(1 - t, 3) }
    static func inOut(_ t: CGFloat) -> CGFloat { t < 0.5 ? 4*t*t*t : 1 - pow(-2*t+2, 3)/2 }
    static func back(_ t: CGFloat) -> CGFloat  { let c1: CGFloat = 1.7; let c3 = c1+1; return 1+c3*pow(t-1,3)+c1*pow(t-1,2) }
    static func lin(_ t: CGFloat) -> CGFloat   { t }
}

// MARK: - Tween key: [target, duration_ms, easing]

struct TweenKey {
    let target: CGFloat
    let duration: CGFloat    // milliseconds
    let ease: (CGFloat) -> CGFloat
}

struct Tween {
    let property: String
    var keys: [TweenKey]
    var keyIndex: Int = 0
    var from: CGFloat
    var startTime: Double    // CACurrentMediaTime() * 1000
    var onComplete: (() -> Void)? = nil
}

// MARK: - Particle

struct Particle {
    enum ParticleType { case heart, star, spark, sweat, z }
    var type: ParticleType
    var x, y, vx, vy: CGFloat
    var age: Double        // seconds
    var life: Double
    var rot: CGFloat
    var size: CGFloat
}

// MARK: - Bot state config (mirrors STATES in prototype)

struct BotStateCfg {
    let color: CGColor
    let tint: CGFloat
    let eye: EyeShape
    let badge: BadgeType?
    let badgeColor: CGColor
    let glow: CGColor
    let glowOpacity: CGFloat
    let bounces: Bool
    let scans: Bool
    let breathes: Bool
    let zz: Bool
    let sweat: Bool
    let look: CGPoint?     // fixed look direction
    let tilt: CGFloat
    let sound: String?
}

enum EyeShape: String {
    case pill, wide, dot, line, flat, happy, closed, spiral, heart, star, tired, wink, cup
}

enum BadgeType {
    case dots(CGColor)
    case bang(CGColor)
    case question(CGColor)
    case dot(CGColor)
}

// MARK: - Mochi track constants (from PISTES.mochi)

enum MochiConst {
    static let eyeW: CGFloat  = 0.25
    static let eyeH: CGFloat  = 0.27
    static let eyeSp: CGFloat = 0.37
    static let eyeP: CGFloat  = -0.12
    static let baseTop    = CGColor(red: 0.929, green: 0.929, blue: 0.937, alpha: 1)  // #EDEDEF
    static let baseBottom = CGColor(red: 0.769, green: 0.773, blue: 0.792, alpha: 1)  // #C4C5CA
    static let ink        = CGColor(red: 0.102, green: 0.082, blue: 0.071, alpha: 1)  // #1A1412
    static let miniInk    = CGColor(red: 0.063, green: 0.075, blue: 0.102, alpha: 1)  // #10131A
}

// MARK: - Bot state configs

let BotStates: [BotState: BotStateCfg] = [
    .idle: BotStateCfg(
        color: CGColor(red:0.902,green:0.914,blue:0.933,alpha:1), tint:0,
        eye:.pill, badge:nil,
        badgeColor: .white, glow: CGColor(red:1,green:1,blue:1,alpha:0.35), glowOpacity:0.25,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:nil),
    .working: BotStateCfg(
        color: CGColor(red:0.231,green:0.620,blue:1,alpha:1), tint:0.72,
        eye:.pill, badge:.dots(CGColor(red:0.231,green:0.620,blue:1,alpha:1)),
        badgeColor: CGColor(red:0.231,green:0.620,blue:1,alpha:1),
        glow: CGColor(red:0.231,green:0.620,blue:1,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"work"),
    .thinking: BotStateCfg(
        color: CGColor(red:0.545,green:0.361,blue:0.965,alpha:1), tint:0.72,
        eye:.pill, badge:.dots(CGColor(red:0.545,green:0.361,blue:0.965,alpha:1)),
        badgeColor: CGColor(red:0.545,green:0.361,blue:0.965,alpha:1),
        glow: CGColor(red:0.545,green:0.361,blue:0.965,alpha:1), glowOpacity:0.5,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look: CGPoint(x:0.55, y:0.55), tilt:0, sound:"think"),
    .searching: BotStateCfg(
        color: CGColor(red:0.388,green:0.396,blue:0.949,alpha:1), tint:0.72,
        eye:.pill, badge:.dots(CGColor(red:0.388,green:0.396,blue:0.949,alpha:1)),
        badgeColor: CGColor(red:0.388,green:0.396,blue:0.949,alpha:1),
        glow: CGColor(red:0.388,green:0.396,blue:0.949,alpha:1), glowOpacity:0.55,
        bounces:false, scans:true, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"search"),
    .approval: BotStateCfg(
        color: CGColor(red:0.961,green:0.647,blue:0.141,alpha:1), tint:0.78,
        eye:.wide, badge:.bang(CGColor(red:0.961,green:0.647,blue:0.141,alpha:1)),
        badgeColor: CGColor(red:0.961,green:0.647,blue:0.141,alpha:1),
        glow: CGColor(red:0.961,green:0.647,blue:0.141,alpha:1), glowOpacity:0.6,
        bounces:true, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"approval"),
    .question: BotStateCfg(
        color: CGColor(red:0.133,green:0.827,blue:0.933,alpha:1), tint:0.75,
        eye:.pill, badge:.question(CGColor(red:0.133,green:0.827,blue:0.933,alpha:1)),
        badgeColor: CGColor(red:0.133,green:0.827,blue:0.933,alpha:1),
        glow: CGColor(red:0.133,green:0.827,blue:0.933,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0.17, sound:"question"),
    .error: BotStateCfg(
        color: CGColor(red:0.957,green:0.314,blue:0.369,alpha:1), tint:0.78,
        eye:.flat, badge:.dot(CGColor(red:0.957,green:0.314,blue:0.369,alpha:1)),
        badgeColor: CGColor(red:0.957,green:0.314,blue:0.369,alpha:1),
        glow: CGColor(red:0.957,green:0.314,blue:0.369,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"error"),
    .finished: BotStateCfg(
        color: CGColor(red:0.204,green:0.831,blue:0.600,alpha:1), tint:0.35,
        eye:.happy, badge:.dot(CGColor(red:0.204,green:0.831,blue:0.600,alpha:1)),
        badgeColor: CGColor(red:0.204,green:0.831,blue:0.600,alpha:1),
        glow: CGColor(red:0.204,green:0.831,blue:0.600,alpha:1), glowOpacity:0.5,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"finish"),
    .ratelimit: BotStateCfg(
        color: CGColor(red:0.984,green:0.573,blue:0.235,alpha:1), tint:0.72,
        eye:.tired, badge:.dot(CGColor(red:0.984,green:0.573,blue:0.235,alpha:1)),
        badgeColor: CGColor(red:0.984,green:0.573,blue:0.235,alpha:1),
        glow: CGColor(red:0.984,green:0.573,blue:0.235,alpha:1), glowOpacity:0.45,
        bounces:false, scans:false, breathes:false, zz:false, sweat:true,
        look:nil, tilt:0, sound:"rate"),
    .sleeping: BotStateCfg(
        color: CGColor(red:0.580,green:0.635,blue:0.722,alpha:1), tint:0.32,
        eye:.closed, badge:nil,
        badgeColor: .white,
        glow: CGColor(red:0.580,green:0.635,blue:0.722,alpha:1), glowOpacity:0.2,
        bounces:false, scans:false, breathes:true, zz:true, sweat:false,
        look:nil, tilt:0, sound:"sleep"),
    .dizzy: BotStateCfg(
        color: CGColor(red:0.957,green:0.447,blue:0.714,alpha:1), tint:0.7,
        eye:.spiral, badge:nil,
        badgeColor: .white,
        glow: CGColor(red:0.957,green:0.447,blue:0.714,alpha:1), glowOpacity:0.55,
        bounces:false, scans:false, breathes:false, zz:false, sweat:false,
        look:nil, tilt:0, sound:"dizzy"),
]

// MARK: - Bot engine

@MainActor
final class BotEngine: ObservableObject {
    var isMini: Bool = false
    var bodyColor: CGColor? = nil    // override for mini bots

    // Animation state (mirrors prototype 's' object)
    var yaw:    CGFloat = 0
    var pitch:  CGFloat = 0
    var roll:      CGFloat = 0
    var rollTurns: CGFloat = 1
    var tilt:   CGFloat = 0
    var open:   CGFloat = 1          // eye open amount
    var sx:     CGFloat = 1          // scale X
    var sy:     CGFloat = 1          // scale Y
    var oy:     CGFloat = 0          // offset Y (bounce)
    var ox:     CGFloat = 0          // offset X (shake)
    var tint:   CGFloat = 0
    var morph:  CGFloat = 0          // morph to rect (for upload bucket)
    var hands:  CGFloat = 0
    var blush:  CGFloat = 0
    var outfit: Outfit = .none
    var es:     CGFloat = 1          // eye scale
    var badgeS: CGFloat = 0          // badge scale
    var outfitPresence: CGFloat = 0  // 0=hidden, 1=fully visible (animated)
    private var outfitTarget: Outfit = .none

    // Physical spring (hat/pompom lag) — updated in update()
    var physDx: CGFloat = 0   // horizontal lag (-1..1)
    var physDy: CGFloat = 0   // vertical lag (-1..1)
    private var physVx: CGFloat = 0
    private var physVy: CGFloat = 0
    private var prevYaw: CGFloat = 0
    private var prevOy: CGFloat = 0

    // Targets
    var tgYaw:    CGFloat = 0
    var tgPitch:  CGFloat = 0
    var tgTilt:   CGFloat = 0
    var tgSy:     CGFloat = 1
    var tgSx:     CGFloat = 1
    var tgEs:     CGFloat = 1   // eye-scale target (hover love: 1.08, normal: 1)

    // Particle canvas overhang (extra canvas height at top for hearts to fly into)
    var particleOverhang: CGFloat = 0

    // Mouth spring (fraction of R: 0=closed, 0.20=hover, 0.42=open, 0.50=overopen)
    var slotH: CGFloat = 0           // current height (fraction of R)
    var slotHTarget: CGFloat = 0     // spring target
    var slotHVel: CGFloat = 0        // spring velocity (fraction of R / s)
    var isChewing: Bool = false       // true for ~800ms after gulp swallow

    // Color (animated)
    var col:  (CGFloat, CGFloat, CGFloat) = (0.902, 0.914, 0.933)  // idle
    var colT: (CGFloat, CGFloat, CGFloat) = (0.902, 0.914, 0.933)

    // State
    var state: BotState = .idle
    var cfg: BotStateCfg = BotStates[.idle]!

    // Eye override (emote)
    var eyeOverride: EyeShape? = nil
    var eyeOverrideUntil: Double = 0   // CACurrentMediaTime()
    var permanentEye: EyeShape? = nil   // restored after temporary emote/blink expires
    var permanentEmote: BotEmote? = nil // stored so doMiniBehaviorLoop can switch on it
    var miniNextBehavior: Double = 0    // CACurrentMediaTime() of next periodic mini action

    // Badge animation
    var badge: BadgeType? = nil
    var badgeKey: String = "none"
    var badgeToken: Int = 0

    // Tweens (keyed by property name)
    var tweens: [String: Tween] = [:]
    var locks:  Set<String> = []

    // Particles
    var particles: [Particle] = []

    // Look target
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0

    // Timing
    var lastTime: Double = CACurrentMediaTime()
    var t0: Double = CACurrentMediaTime() - Double.random(in: 0...5)
    var nextBlink: Double = CACurrentMediaTime() + 1.5 + Double.random(in: 0...2)
    var waveUntil: Double = 0
    var waveStart: Double = 0     // CACurrentMediaTime() when wave animation began
    var greetToken: Int = 0       // incremented to invalidate stale greet closures
    var lastAmbient: Double = 0

    // Slap tracking (for dizzy on 3 slaps)
    var slapTimes: [Double] = []

    // Dancing (Apple Music)
    var isDancing: Bool = false
    var dancingLevel: CGFloat = 0   // 0→1 over 0.3s, 1→0 over 0.5s

    // Mini wandering look (random, ignores mouse)
    var miniLookTarget: CGPoint = .zero
    var miniLookNextTime: Double = 0

    // MARK: - Public API

    func setState(_ newState: BotState, force: Bool = false) {
        guard state != newState || force else { return }
        let prev = state
        state = newState
        cfg = BotStates[newState]!
        colT = cgColorToTuple(cfg.color)
        setTarget(key: "tint", value: cfg.tint)
        setTarget(key: "tilt", value: cfg.tilt)
        setBadge(cfg.badge)

        switch newState {
        case .finished:
            doRoll(duration: 950, turns: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.emit(.spark, count: 5)
            }
        case .error:
            anim("ox", keys: [
                TweenKey(target: 0.08,  duration: 50,  ease: Ease.out),
                TweenKey(target: -0.08, duration: 70,  ease: Ease.inOut),
                TweenKey(target: 0.05,  duration: 70,  ease: Ease.inOut),
                TweenKey(target: 0,     duration: 90,  ease: Ease.out),
            ])
        case .approval:
            anim("oy", keys: [
                TweenKey(target: -0.2, duration: 150, ease: Ease.out),
                TweenKey(target: 0,    duration: 300, ease: Ease.back),
            ])
        case .dizzy:
            doRoll(duration: 1300, turns: 2)
        case .question:
            blink()
        case .ratelimit:
            emit(.sweat, count: 1)
        default:
            if prev != .idle || newState != .idle { blink() }
        }
    }

    func setBadge(_ b: BadgeType?) {
        let key = badgeString(b)
        guard key != badgeKey else { return }
        badgeKey = key
        let tok = badgeToken + 1
        badgeToken = tok
        anim("badgeS", keys: [TweenKey(target: 0, duration: 90, ease: Ease.inOut)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, tok == self.badgeToken else { return }
            self.badge = b
            if b != nil {
                self.anim("badgeS", keys: [TweenKey(target: 1, duration: 280, ease: Ease.back)])
            }
        }
    }

    func blink() {
        guard !locks.contains("open") else { return }
        anim("open", keys: [
            TweenKey(target: 0.06, duration: 70,  ease: Ease.inOut),
            TweenKey(target: 1,    duration: 130, ease: Ease.out),
        ])
    }

    func squash() {
        physVy += 0.6
        anim("sy", keys: [
            TweenKey(target: 0.78, duration: 70,  ease: Ease.out),
            TweenKey(target: 1.1,  duration: 130, ease: Ease.out),
            TweenKey(target: 1,    duration: 170, ease: Ease.inOut),
        ])
        anim("sx", keys: [
            TweenKey(target: 1.16, duration: 70,  ease: Ease.out),
            TweenKey(target: 0.95, duration: 130, ease: Ease.out),
            TweenKey(target: 1,    duration: 170, ease: Ease.inOut),
        ])
    }

    // MARK: - Gulp (mailbox swallow)

    func gulp() {
        // Open mouth wide for the swallow, then close during chewing
        slotHTarget = 0.42
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            self?.slotHTarget = 0
            self?.isChewing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) { [weak self] in
                self?.isChewing = false
            }
        }
        anim("sy", keys: [
            TweenKey(target: 0.78, duration: 80,  ease: Ease.out),
            TweenKey(target: 1.18, duration: 130, ease: Ease.out),
            TweenKey(target: 1,    duration: 220, ease: Ease.back),
        ])
        anim("sx", keys: [
            TweenKey(target: 1.28, duration: 80,  ease: Ease.out),
            TweenKey(target: 0.92, duration: 130, ease: Ease.out),
            TweenKey(target: 1,    duration: 220, ease: Ease.back),
        ])
        blink()
    }

    // MARK: - Slap (dizzy mechanic)

    func slap() {
        interruptGreet()
        guard state != .dizzy else { return }
        let now = CACurrentMediaTime()
        slapTimes = slapTimes.filter { now - $0 < 1.7 }
        slapTimes.append(now)
        SoundEngine.shared.play("slap")
        squash()
        physVy -= 1.2
        physVx += Bool.random() ? 0.7 : -0.7
        if slapTimes.count >= 3 {
            slapTimes = []
            NotificationCenter.default.post(name: .botDizzy, object: nil)
        } else {
            // Annoyed: line eyes for 800ms, annoyed sound after 60ms delay
            eyeOverride = .line
            eyeOverrideUntil = now + 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                SoundEngine.shared.play("annoyed")
            }
        }
    }

    // MARK: - Dancing

    func setDancing(_ dancing: Bool) {
        guard isDancing != dancing else { return }
        isDancing = dancing
    }

    // MARK: - Mini periodic behavior loop

    func doMiniBehaviorLoop() {
        switch permanentEmote {

        case .happy:
            // Little jump + squash
            guard !locks.contains("oy") else {
                miniNextBehavior = CACurrentMediaTime() + 0.4
                return
            }
            anim("oy", keys: [
                TweenKey(target: -0.30, duration: 120, ease: Ease.out),
                TweenKey(target:  0.03, duration: 200, ease: Ease.inOut),
                TweenKey(target:  0,    duration: 160, ease: Ease.back),
            ])
            anim("sy", keys: [
                TweenKey(target: 0.82, duration: 80,  ease: Ease.out),
                TweenKey(target: 1.18, duration: 130, ease: Ease.out),
                TweenKey(target: 0.88, duration: 160, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 200, ease: Ease.back),
            ])
            anim("sx", keys: [
                TweenKey(target: 1.15, duration: 80,  ease: Ease.out),
                TweenKey(target: 0.88, duration: 130, ease: Ease.out),
                TweenKey(target: 1.06, duration: 160, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 200, ease: Ease.back),
            ])
            miniNextBehavior = CACurrentMediaTime() + 2.2 + Double.random(in: 0...1.2)

        case .annoyed:
            // Rapid head shake
            guard !locks.contains("yaw") else {
                miniNextBehavior = CACurrentMediaTime() + 0.5
                return
            }
            anim("yaw", keys: [
                TweenKey(target: -0.65, duration: 50,  ease: Ease.out),
                TweenKey(target:  0.65, duration: 90,  ease: Ease.inOut),
                TweenKey(target: -0.5,  duration: 80,  ease: Ease.inOut),
                TweenKey(target:  0.4,  duration: 75,  ease: Ease.inOut),
                TweenKey(target: -0.2,  duration: 70,  ease: Ease.inOut),
                TweenKey(target:  0,    duration: 140, ease: Ease.out),
            ])
            miniNextBehavior = CACurrentMediaTime() + 3.0 + Double.random(in: 0...2.5)

        case .wink:
            // Brief wink: eye closes, head tilts slightly
            let now2 = CACurrentMediaTime()
            eyeOverride = .wink
            eyeOverrideUntil = now2 + 0.55
            anim("tilt", keys: [
                TweenKey(target:  0.13, duration: 100, ease: Ease.out),
                TweenKey(target:  0.13, duration: 320, ease: Ease.lin),
                TweenKey(target:  0,    duration: 200, ease: Ease.inOut),
            ])
            miniNextBehavior = CACurrentMediaTime() + 2.2 + Double.random(in: 0...2.0)

        case .love:
            // Emit hearts + gentle sway
            emit(.heart, count: 2)
            anim("tilt", keys: [
                TweenKey(target: -0.1, duration: 180, ease: Ease.out),
                TweenKey(target:  0.1, duration: 340, ease: Ease.inOut),
                TweenKey(target:  0,   duration: 220, ease: Ease.inOut),
            ])
            miniNextBehavior = CACurrentMediaTime() + 2.6 + Double.random(in: 0...1.5)

        default:
            miniNextBehavior = CACurrentMediaTime() + 3.0 + Double.random(in: 0...2.0)
        }
    }

    func doRoll(duration: CGFloat, turns: CGFloat) {
        roll = 0
        rollTurns = turns
        anim("roll", keys: [TweenKey(target: .pi * 2 * turns, duration: duration, ease: Ease.inOut)]) { [weak self] in
            self?.roll = 0
            self?.squash()
        }
    }

    func setOutfit(_ newOutfit: Outfit, animated: Bool = true) {
        guard newOutfit != outfitTarget else { return }
        outfitTarget = newOutfit
        tweens.removeValue(forKey: "outfitPresence")
        locks.remove("outfitPresence")
        if !animated {
            outfit = newOutfit
            outfitPresence = newOutfit != .none ? 1 : 0
        } else if newOutfit == .none {
            // Exit: fade out then clear outfit
            anim("outfitPresence", keys: [TweenKey(target: 0, duration: 180, ease: Ease.inOut)]) { [weak self] in
                self?.outfit = .none
            }
        } else if outfit == .none {
            // Enter: set outfit then animate in (Ease.back applied to position offsets in drawing code)
            outfit = newOutfit
            outfitPresence = 0
            anim("outfitPresence", keys: [TweenKey(target: 1, duration: 350, ease: Ease.inOut)]) { [weak self] in
                self?.squash()
            }
        } else {
            // Change: exit old, set new, enter
            anim("outfitPresence", keys: [TweenKey(target: 0, duration: 180, ease: Ease.inOut)]) { [weak self] in
                guard let self else { return }
                self.outfit = newOutfit
                self.anim("outfitPresence", keys: [TweenKey(target: 1, duration: 350, ease: Ease.inOut)]) { [weak self] in
                    self?.squash()
                }
            }
        }
    }

    func greet() {
        let now = CACurrentMediaTime()
        greetToken += 1
        let tok = greetToken
        waveStart = now + 0.45   // wave begins at 0.45s
        waveUntil = now + 1.55   // wave ends at 1.55s
        physVx += 0.2

        // 0s: happy eyes for full greeting (2s — no gap, no flicker)
        eyeOverride = .happy
        eyeOverrideUntil = now + 2.0
        anim("oy", keys: [
            TweenKey(target: -0.06, duration: 220, ease: Ease.out),
            TweenKey(target:  0.0,  duration: 220, ease: Ease.back),
        ])

        // 0.25s: hands out + body squash + sound
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.anim("hands", keys: [TweenKey(target: 1, duration: 280, ease: Ease.out)])
            self.anim("sy", keys: [
                TweenKey(target: 0.95, duration: 100, ease: Ease.out),
                TweenKey(target: 1.0,  duration: 260, ease: Ease.back),
            ])
            self.anim("sx", keys: [
                TweenKey(target: 1.04, duration: 100, ease: Ease.out),
                TweenKey(target: 1.0,  duration: 260, ease: Ease.back),
            ])
            SoundEngine.shared.play("greet")
        }

        // 0.55s: first blink
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.blink()
        }

        // 1.50s: second blink
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.50) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.blink()
        }

        // 1.55s: retract hands
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.55) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.waveUntil = 0
            self.anim("hands", keys: [TweenKey(target: 0, duration: 200, ease: Ease.inOut)])
        }

        // 1.75s: brief happy eyes then back to normal
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.75) { [weak self] in
            guard let self, self.greetToken == tok else { return }
            self.eyeOverride = .happy
            self.eyeOverrideUntil = CACurrentMediaTime() + 0.30
        }
    }

    /// Immediately interrupts an in-progress greeting (hands retract in 150 ms).
    func interruptGreet() {
        guard hands > 0.01 || CACurrentMediaTime() < waveUntil else { return }
        greetToken += 1   // invalidate any pending closures
        waveUntil = 0
        waveStart = 0
        anim("hands", keys: [TweenKey(target: 0, duration: 150, ease: Ease.inOut)])
    }

    /// Sets a permanent eye expression that survives blinks and transient emotes.
    func setPermanentEmote(_ emote: BotEmote?) {
        permanentEmote = emote
        // .wink fires periodically — don't freeze the eye (normal between winks)
        if emote == .wink {
            miniNextBehavior = CACurrentMediaTime() + Double.random(in: 0.8...2.5)
            return
        }
        permanentEye = emote.map { emoteEyeShape($0) }
        if let eye = permanentEye {
            eyeOverride = eye
            eyeOverrideUntil = .greatestFiniteMagnitude
        } else {
            if eyeOverrideUntil == .greatestFiniteMagnitude {
                eyeOverride = nil
                eyeOverrideUntil = 0
            }
        }
        // Stagger first periodic behavior so bots don't all fire at once
        miniNextBehavior = CACurrentMediaTime() + Double.random(in: 0.8...2.5)
    }

    func triggerEmote(_ emote: BotEmote, duration: Double = 1.8, silent: Bool = false) {
        let now = CACurrentMediaTime()
        eyeOverride = emoteEyeShape(emote)
        eyeOverrideUntil = now + duration

        switch emote {
        case .love:
            anim("blush", keys: [
                TweenKey(target: 1, duration: 300, ease: Ease.out),
                TweenKey(target: 1, duration: CGFloat((duration - 0.6) * 1000), ease: Ease.lin),
                TweenKey(target: 0, duration: 300, ease: Ease.inOut),
            ])
            emit(.heart, count: 4)
            anim("oy", keys: [
                TweenKey(target: -0.1, duration: 160, ease: Ease.out),
                TweenKey(target: 0,    duration: 300, ease: Ease.back),
            ])
        case .surprised:
            anim("oy", keys: [
                TweenKey(target: -0.3, duration: 140, ease: Ease.out),
                TweenKey(target: 0,    duration: 380, ease: Ease.back),
            ])
            anim("es", keys: [
                TweenKey(target: 1.25, duration: 120, ease: Ease.out),
                TweenKey(target: 1,    duration: 500, ease: Ease.inOut),
            ])
        case .proud:
            squash()
            emit(.star, count: 5)
            anim("tilt", keys: [
                TweenKey(target: -0.14, duration: 220, ease: Ease.out),
                TweenKey(target: -0.14, duration: CGFloat((duration - 0.5) * 1000), ease: Ease.lin),
                TweenKey(target: 0,     duration: 280, ease: Ease.inOut),
            ])
            anim("blush", keys: [
                TweenKey(target: 0.7, duration: 250, ease: Ease.out),
                TweenKey(target: 0.7, duration: CGFloat((duration - 0.5) * 1000), ease: Ease.lin),
                TweenKey(target: 0,   duration: 300, ease: Ease.inOut),
            ])
        case .wink:
            anim("tilt", keys: [
                TweenKey(target: 0.12, duration: 160, ease: Ease.out),
                TweenKey(target: 0.12, duration: CGFloat((duration - 0.4) * 1000), ease: Ease.lin),
                TweenKey(target: 0,    duration: 240, ease: Ease.inOut),
            ])
        case .yawn:
            anim("sy", keys: [
                TweenKey(target: 1.12, duration: 500, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 500, ease: Ease.inOut),
            ])
            anim("sx", keys: [
                TweenKey(target: 0.94, duration: 500, ease: Ease.inOut),
                TweenKey(target: 1,    duration: 500, ease: Ease.inOut),
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.eyeOverride = .closed
                self?.emit(.z, count: 2)
            }
        case .happy:
            anim("blush", keys: [
                TweenKey(target: 0.6, duration: 200, ease: Ease.out),
                TweenKey(target: 0,   duration: 600, ease: Ease.inOut),
            ])
        case .annoyed:
            eyeOverride = .line
            eyeOverrideUntil = now + 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                SoundEngine.shared.play("annoyed")
            }
        }
    }

    func emit(_ type: Particle.ParticleType, count: Int) {
        for i in 0..<count {
            let isZ = type == .z
            let p = Particle(
                type: type,
                x: (CGFloat.random(in: -0.5...0.5)) * 0.9 + (isZ ? 0.55 : 0),
                y: -0.7 - CGFloat.random(in: 0...0.2),
                vx: CGFloat.random(in: -0.5...0.5) * 0.35 + (isZ ? 0.18 : 0),
                vy: -(0.45 + CGFloat.random(in: 0...0.35)),
                age: -Double(i) * 0.14,
                life: 1.3 + Double.random(in: 0...0.5),
                rot: CGFloat.random(in: 0...(.pi * 2)),
                size: 0.15 + CGFloat.random(in: 0...0.08)
            )
            particles.append(p)
        }
    }

    // MARK: - Update (called every frame from TimelineView)

    func update(dt: Double) {
        let now = CACurrentMediaTime()
        let dtCG = CGFloat(dt)

        // Process tweens
        for key in tweens.keys {
            guard var tw = tweens[key] else { continue }
            let k = tw.keys[tw.keyIndex]
            let elapsed = now * 1000 - tw.startTime
            let p = min(1, max(0, CGFloat(elapsed) / k.duration))
            let val = tw.from + (k.target - tw.from) * k.ease(p)
            setProperty(key, value: val)

            if p >= 1 {
                tw.from = k.target
                tw.keyIndex += 1
                tw.startTime = now * 1000
                if tw.keyIndex >= tw.keys.count {
                    tweens.removeValue(forKey: key)
                    locks.remove(key)
                    tw.onComplete?()
                } else {
                    tweens[key] = tw
                }
            } else {
                tweens[key] = tw
            }
        }

        // Compute look targets
        let t = CGFloat(now - t0)
        var ty: CGFloat = lookX * 0.62
        var tp: CGFloat = lookY * 0.5

        if let fixedLook = cfg.look {
            ty = ty * 0.35 + fixedLook.x * 0.55
            tp = tp * 0.3  + fixedLook.y * 0.5
        }
        if cfg.scans {
            ty = sin(t * 2.6) * 0.6
            tp = -0.06
        }
        if state == .sleeping { ty = 0; tp = -0.14 }
        if state == .dizzy    { ty = sin(t * 9) * 0.25 }

        // Mini bots: override look with random wandering (never follows mouse)
        if isMini && cfg.look == nil && !cfg.scans && state != .sleeping && state != .dizzy {
            if now > miniLookNextTime {
                miniLookTarget = CGPoint(
                    x: CGFloat.random(in: -0.88...0.88),
                    y: CGFloat.random(in: -0.55...0.45)
                )
                miniLookNextTime = now + Double.random(in: 0.5...2.0)
            }
            ty = miniLookTarget.x * 0.62
            tp = miniLookTarget.y * 0.5
        }

        tgYaw   = ty
        tgPitch = tp
        tgTilt  = cfg.tilt

        // Body sway during greeting wave
        if now > waveStart && now < waveUntil {
            let wt = CGFloat(now - waveStart)
            tgTilt = -0.06 + sin(2 * .pi * 1.2 * wt) * 0.07
        }

        let bounce = cfg.bounces ? -abs(sin(t * 5.2)) * 0.07 : CGFloat(0)
        // oy tween can override if not locked
        if !locks.contains("oy") { oy += (bounce - oy) * CGFloat(1 - pow(0.0008, dt)) }

        if cfg.breathes {
            let amp: CGFloat = isMini ? 0.07 : 0.035
            tgSy = 1 + sin(t * 1.8) * amp
            tgSx = 1 - sin(t * 1.8) * amp * 0.57
        } else if isMini {
            // Subtle idle pulse (unique phase per engine via t0)
            tgSy = 1 + sin(t * 2.2) * 0.04
            tgSx = 1 - sin(t * 2.2) * 0.02
        } else {
            tgSy = 1; tgSx = 1
        }

        // Mini bots: periodic dramatic behaviors
        if isMini && now > miniNextBehavior {
            doMiniBehaviorLoop()
        }

        // Smooth look
        let kLook = CGFloat(1 - pow(0.0025, dt))
        let kGen  = CGFloat(1 - pow(0.0008, dt))

        if !locks.contains("yaw")   { yaw   += (tgYaw   - yaw)   * kLook }
        if !locks.contains("pitch") { pitch += (tgPitch  - pitch) * kLook }
        if !locks.contains("tilt")  { tilt  += (tgTilt   - tilt)  * kGen  }
        if !locks.contains("sy")    { sy    += (tgSy     - sy)    * kGen  }
        if !locks.contains("sx")    { sx    += (tgSx     - sx)    * kGen  }
        if !locks.contains("es")    { es    += (tgEs     - es)    * kGen  }

        // Animate color
        col = mixColor(col, colT, 1 - pow(0.002, dt))

        // Blink
        if now > nextBlink {
            if state != .sleeping && state != .dizzy {
                blink()
                if Double.random(in: 0...1) < 0.22 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) { [weak self] in self?.blink() }
                }
            }
            nextBlink = now + 2.2 + Double.random(in: 0...3.2)
        }

        // Clear expired eye override (restore permanent if set)
        if eyeOverride != nil && now > eyeOverrideUntil {
            eyeOverride = permanentEye
            if permanentEye != nil { eyeOverrideUntil = .greatestFiniteMagnitude }
        }

        // Ambient particles
        if now - lastAmbient > 1.3 {
            lastAmbient = now
            if cfg.zz { emit(.z, count: 1) }   // ZZZ works for mini too
            if !isMini && cfg.sweat && Double.random(in: 0...1) < 0.5 { emit(.sweat, count: 1) }
        }

        // Age particles
        for i in particles.indices { particles[i].age += dt }
        particles.removeAll { $0.age >= $0.life }

        // Mouth slot spring — ω₀ ≈ 25 rad/s (T=0.25s), ζ=0.6 (underdamped, slight clack)
        let slotOmega: CGFloat = 2 * .pi / 0.25
        let slotZeta: CGFloat = 0.6
        let slotAcc = slotOmega * slotOmega * (slotHTarget - slotH)
                    - 2 * slotZeta * slotOmega * slotHVel
        slotHVel += slotAcc * dtCG
        slotH = max(0, slotH + slotHVel * dtCG)

        // Dance level: fade in 0.3s, out 0.5s
        let dancingTarget: CGFloat = isDancing ? 1 : 0
        if dancingLevel < dancingTarget {
            dancingLevel = min(dancingTarget, dancingLevel + CGFloat(dt) / 0.3)
        } else if dancingLevel > dancingTarget {
            dancingLevel = max(dancingTarget, dancingLevel - CGFloat(dt) / 0.5)
        }

        // Phys spring for hat/pompom lag
        let yawVel = (yaw - prevYaw) / CGFloat(dt)
        let oyVel  = (oy  - prevOy)  / CGFloat(dt)
        prevYaw = yaw; prevOy = oy
        let tDx = max(-1, min(1, -yawVel * 0.35 - tilt * 2))
        let tDy = max(-1, min(1,  oyVel  * 0.50))
        let stiff: CGFloat = 60, damp: CGFloat = 9
        physVx += (stiff * (tDx - physDx) - damp * physVx) * dtCG
        physVy += (stiff * (tDy - physDy) - damp * physVy) * dtCG
        physDx += physVx * dtCG
        physDy += physVy * dtCG

        lastTime = now
    }

    // MARK: - Dance transform

    /// Applies a 112-BPM dance bounce/sway around the bottom of the body.
    /// Call this on a copy of the GraphicsContext before the three draw passes.
    func applyDance(_ ctx: inout GraphicsContext, size: CGSize) {
        guard dancingLevel > 0.001 else { return }
        let W = size.width, H = size.height, R = W * 0.3
        let px = W / 2 + ox * R
        let py = H / 2 + particleOverhang / 2 + oy * R + R * 0.06 + R * 0.88
        let beat = CGFloat(CACurrentMediaTime()) * 112 / 60
        let hop = abs(sin(.pi * beat)), land = pow(1 - hop, 6), l = dancingLevel
        ctx.translateBy(x: px + 0.08 * R * sin(.pi * beat) * l, y: py - 0.20 * R * hop * l)
        ctx.rotate(by: .radians(0.10 * sin(.pi * beat) * l))
        ctx.scaleBy(x: 1 + 0.045 * land * l, y: 1 - 0.06 * land * l)
        ctx.translateBy(x: -px, y: -py)
    }

    // MARK: - Draw

    func draw(context: GraphicsContext, size: CGSize) {
        let W = size.width
        let H = size.height
        let R = W * 0.3
        let rx = R * 1.14
        let ry = R * 0.88

        let cx = W / 2 + ox * R
        // particleOverhang shifts the bot body down in canvas coords so hearts can fly into
        // the extended canvas above without clipping (BotPlacement compensates with position offset)
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06

        var ctx = context
        ctx.translateBy(x: cx, y: cy)
        if tilt != 0 { ctx.rotate(by: .radians(tilt)) }
        ctx.scaleBy(x: sx, y: sy)

        // Body path (superellipse for Mochi, morph to rect for upload)
        let bodyPath = mochiPath(rx: rx, ry: ry, morph: morph, R: R)

        // Body fill
        drawBody(ctx: &ctx, path: bodyPath, R: R, rx: rx, ry: ry,
                 pumpkinColors: outfit == .pumpkin && !isMini)

        // Blush — always shows a floor proportional to tint (prototype behaviour)
        let blushVal = max(blush, tint * 0.5) * (1 - morph)
        if blushVal > 0.01 {
            drawBlush(ctx: &ctx, path: bodyPath, rx: rx, ry: ry, R: R, blush: blushVal)
        }

        // Eyes
        drawEyes(ctx: &ctx, path: bodyPath, R: R, rx: rx, ry: ry)

        // Mouth hole — dark pill cutout inside the box face
        // Spec: left/right margins 0.10R, top margin 0.08R from box top (-0.94R)
        if morph > 0.05 {
            let hW = R * 1.80 * morph   // hole width = box width (2×1.0R) − 2×0.10R margin
            let hH = slotH * R * morph  // hole height (spring-animated, scaled by morph)
            let hX = -hW / 2
            // Hole Y: box top is -R*0.94 at morph=1, lerped from -R*0.88 at morph=0
            let boxTop = -R * (0.88 + 0.06 * morph)
            let hY = boxTop + R * 0.08 * morph  // top margin scales with morph

            var boxCtx = ctx
            boxCtx.clip(to: bodyPath)  // everything clipped inside body

            // Top rim — 1pt white 55% line at box top edge
            var rim = Path()
            rim.move(to: CGPoint(x: -R * 0.90 * morph, y: boxTop + 1))
            rim.addLine(to: CGPoint(x: R * 0.90 * morph, y: boxTop + 1))
            boxCtx.stroke(rim, with: .color(Color.white.opacity(0.55 * Double(morph))),
                          style: StrokeStyle(lineWidth: 1, lineCap: .round))

            // Hole interior — only draw if visibly open
            if hH > 0.8 {
                let hR = min(hW / 2, hH / 2)  // fully rounded when hH < hW (pill shape)
                var hole = Path()
                hole.addRoundedRect(in: CGRect(x: hX, y: hY, width: hW, height: hH),
                                    cornerSize: CGSize(width: hR, height: hR))
                boxCtx.fill(hole, with: .linearGradient(
                    Gradient(colors: [Color(red: 0.027, green: 0.031, blue: 0.039),
                                      Color(red: 0.063, green: 0.075, blue: 0.102)]),
                    startPoint: CGPoint(x: 0, y: hY),
                    endPoint: CGPoint(x: 0, y: hY + hH)
                ))
                // Bottom lip — 1pt white 28% highlight
                if hH > 4 {
                    let lipR = min(hR, (hW - 2) / 2)
                    var lip = Path()
                    lip.move(to: CGPoint(x: hX + lipR, y: hY + hH - 0.5))
                    lip.addLine(to: CGPoint(x: hX + hW - lipR, y: hY + hH - 0.5))
                    boxCtx.stroke(lip, with: .color(Color.white.opacity(0.28 * Double(morph))),
                                  style: StrokeStyle(lineWidth: 1, lineCap: .round))
                }
            }
        }

        // Reset transform for hands, badge, particles which need world coords
        // (We'll pass world-space cx/cy to these helpers)
    }

    // MARK: - Draw hands behind body (called before draw() so hands appear under Mochi)

    func drawHandsBehind(context: GraphicsContext, size: CGSize) {
        guard hands > 0.01, !isMini else { return }
        let W = size.width, H = size.height
        let R = W * 0.3
        // Only draw hands when Mochi is large enough to be meaningful (not compact/peek)
        guard R > 14 else { return }
        let rx = R * 1.14
        let ry = R * 0.88
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06

        let now = CACurrentMediaTime()
        let bodyH = 2 * ry   // full body height

        // Hand ellipse half-dims: 0.30×bodyH wide, 0.26×bodyH tall (scaled by hands 0→1)
        let hew = 0.30 * ry * hands   // half-width
        let heh = 0.26 * ry * hands   // half-height

        // Body half-dims with current squash scale
        let hwB = rx * sx
        let hhB = ry * sy

        let isWaving = now >= waveStart && waveStart > 0 && now < waveUntil

        for sd in [-1.0, 1.0] {
            var localX: CGFloat
            var localY: CGFloat
            var handRot: CGFloat = 0

            if sd > 0 && isWaving {
                // Right hand: rise to wave position over first 180ms, then oscillate
                let wt = CGFloat(now - waveStart)
                let rise = min(1.0, wt / 0.18)
                let riseEased: CGFloat = 1 - pow(1 - rise, 3)   // easeOut cubic

                // Rest position is lower-side; wave position is upper-side (at eye height)
                let restX: CGFloat = hwB * 1.08
                let restY: CGFloat = hhB * 0.70
                let oscX = cos(13 * wt) * 0.06 * bodyH
                let oscY = -sin(13 * wt) * 0.14 * bodyH
                let waveX: CGFloat = hwB * 1.10 + oscX
                let waveY: CGFloat = -hhB * 0.15 + oscY
                localX = restX + (waveX - restX) * riseEased
                localY = restY + (waveY - restY) * riseEased
                handRot = (-0.5 + sin(13 * wt) * 0.35) * riseEased

            } else if sd < 0 && isWaving {
                // Left hand: gentle sway at rest position
                let wt = CGFloat(now - waveStart)
                localX = -hwB * 1.08
                localY = hhB * 0.70 + sin(6 * wt) * 0.04 * bodyH

            } else {
                // Rest: lower-side, clearly peeking behind body bottom
                localX = CGFloat(sd) * hwB * 1.08
                localY = hhB * 0.70
            }

            // Apply body tilt to get world position
            let cosT = cos(tilt), sinT = sin(tilt)
            let worldX = cx + cosT * localX - sinT * localY
            let worldY = cy + sinT * localX + cosT * localY

            // Draw
            var handCtx = context
            handCtx.translateBy(x: worldX, y: worldY)
            if handRot != 0 { handCtx.rotate(by: .radians(handRot)) }

            let handRect = CGRect(x: -hew, y: -heh, width: hew * 2, height: heh * 2)
            var handPath = Path()
            handPath.addEllipse(in: handRect)

            // Fill with body material (same gradient as body)
            if let bc = bodyColor {
                let c0 = mix3(cgColorToTuple(bc), (1, 1, 1), 0.35)
                let c1 = cgColorToTuple(bc)
                handCtx.fill(handPath, with: .linearGradient(
                    Gradient(colors: [colorFromTuple(c0), colorFromTuple(c1)]),
                    startPoint: CGPoint(x: hew * 0.7, y: -heh * 0.85),
                    endPoint: CGPoint(x: -hew * 0.8, y: heh * 0.9)
                ))
            } else {
                let c0 = cgColorToTuple(MochiConst.baseTop)
                let c1 = cgColorToTuple(MochiConst.baseBottom)
                handCtx.fill(handPath, with: .linearGradient(
                    Gradient(colors: [colorFromTuple(c0), colorFromTuple(c1)]),
                    startPoint: CGPoint(x: hew * 0.7, y: -heh * 0.85),
                    endPoint: CGPoint(x: -hew * 0.8, y: heh * 0.9)
                ))
            }

            // Subtle separation border — rgba(0,0,0,0.08) 1pt
            handCtx.stroke(handPath, with: .color(Color.black.opacity(0.08)), lineWidth: 1)
        }
    }

    func drawHandsAndExtras(context: GraphicsContext, size: CGSize) {
        let W = size.width
        let H = size.height
        let R = W * 0.3
        let rx = R * 1.14
        let ry = R * 0.88
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06

        // Badge — hidden while morphing to mailbox
        if let badge = badge, badgeS > 0.01, morph < 0.25 {
            drawBadge(context: context, size: size, badge: badge, R: R, rx: rx, ry: ry, cx: cx, cy: cy)
        }

        // Particles
        drawParticles(context: context, size: size, R: R, cx: cx, cy: cy)
    }

    func drawOutfitBehind(context: GraphicsContext, size: CGSize) {
        guard outfit != .none, !isMini else { return }
        let W = size.width, H = size.height, R = W * 0.3
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06
        let mH = MochiH(R: R, yaw: yaw, pitch: pitch, physDx: physDx, physDy: physDy, roll: roll)
        drawOutfitBehindStatic(context: context, outfit: outfit, H: mH,
                               cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                               roll: roll, morph: morph, isMini: isMini,
                               presence: outfitPresence, rollTurns: rollTurns)
    }

    func drawOutfitFront(context: GraphicsContext, size: CGSize) {
        guard outfit != .none, !isMini else { return }
        let W = size.width, H = size.height, R = W * 0.3
        let cx = W / 2 + ox * R
        let cy = H / 2 + particleOverhang / 2 + oy * R + R * 0.06
        let mH = MochiH(R: R, yaw: yaw, pitch: pitch, physDx: physDx, physDy: physDy, roll: roll)
        drawOutfitFrontStatic(context: context, outfit: outfit, H: mH,
                              cx: cx, cy: cy, tilt: tilt, sx: sx, sy: sy,
                              roll: roll, morph: morph, isMini: isMini,
                              presence: outfitPresence, rollTurns: rollTurns)
    }

    var outfitFollowsRoll: Bool {
        switch outfit {
        case .sunglasses, .roundGlasses, .bow, .scarf, .pumpkin: return true
        default: return false
        }
    }

    // MARK: - Private draw helpers

    private func mochiPath(rx: CGFloat, ry: CGFloat, morph: CGFloat, R: CGFloat) -> Path {
        let n = 72
        let expN: CGFloat = 2.0 / 2.7
        // Target mailbox dims (spec: 1.0R wide, 0.94R tall, 0.42R corner radius)
        let tw = R * 1.0
        let th = R * 0.94
        let tr = R * 0.42
        var path = Path()
        for i in 0...n {
            let a = CGFloat(i) / CGFloat(n) * .pi * 2
            let ca = cos(a), sa = sin(a)
            let px0 = rx * (ca >= 0 ? pow(ca, expN) : -pow(-ca, expN))
            let py0 = ry * (sa >= 0 ? pow(sa, expN) : -pow(-sa, expN))
            let px: CGFloat
            let py: CGFloat
            if morph < 0.005 {
                px = px0; py = py0
            } else {
                let rr = rrPoint(ca: ca, sa: sa, W: tw, H: th, cr: tr)
                px = lerp(px0, rr.x, morph)
                py = lerp(py0, rr.y, morph)
            }
            if i == 0 { path.move(to: CGPoint(x: px, y: py)) }
            else { path.addLine(to: CGPoint(x: px, y: py)) }
        }
        path.closeSubpath()
        return path
    }

    /// Ray-rounded-rect intersection: find the point on the rounded rect boundary in direction (ca, sa).
    private func rrPoint(ca: CGFloat, sa: CGFloat, W: CGFloat, H: CGFloat, cr: CGFloat) -> CGPoint {
        let eps: CGFloat = 1e-6
        let kx: CGFloat = ca >= 0 ? 1 : -1
        let ky: CGFloat = sa >= 0 ? 1 : -1
        let cx = kx * (W - cr)
        let cy = ky * (H - cr)

        // Try corner arc
        let dot  = ca * cx + sa * cy
        let disc = dot * dot - (cx*cx + cy*cy - cr*cr)
        if disc >= 0 {
            let t = dot + sqrt(disc)
            if t > eps {
                let px = ca * t, py = sa * t
                if abs(px) >= W - cr - eps && abs(py) >= H - cr - eps {
                    return CGPoint(x: px, y: py)
                }
            }
        }

        // Horizontal edge |y| = H
        if abs(sa) > eps {
            let t = (ky * H) / sa
            if t > eps {
                let x = ca * t
                if abs(x) <= W - cr + eps { return CGPoint(x: x, y: ky * H) }
            }
        }
        // Vertical edge |x| = W
        if abs(ca) > eps {
            let t = (kx * W) / ca
            if t > eps {
                let y = sa * t
                if abs(y) <= H - cr + eps { return CGPoint(x: kx * W, y: y) }
            }
        }

        return CGPoint(x: kx * W, y: ky * H)
    }

    private func drawBody(ctx: inout GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat,
                          pumpkinColors: Bool = false) {
        if let bc = bodyColor, !pumpkinColors {
            // Mini bots: flat solid fill — no gradient, no reflection, no highlight
            ctx.fill(path, with: .color(Color(cgColor: bc)))
        } else {
            // Main bot: linear gradient body
            let top: Color = pumpkinColors ? Color(hex: "#FFA94D") : Color(red: 0.929, green: 0.929, blue: 0.937)
            let bot: Color = pumpkinColors ? Color(hex: "#E8590C") : Color(red: 0.769, green: 0.773, blue: 0.792)
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [top, bot]),
                startPoint: CGPoint(x: rx*0.7, y: -ry*0.85),
                endPoint: CGPoint(x: -rx*0.8, y: ry*0.9)
            ))
            // State tint — fades out as morph increases (mailbox has no tint)
            let effectiveTint = tint * (1 - morph)
            if effectiveTint > 0.01 {
                let tc = colorFromTuple(col)
                ctx.fill(path, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: tc.opacity(Double(0.72 * effectiveTint)), location: 0),
                        .init(color: tc.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: 0, y: ry),
                    endPoint: CGPoint(x: 0, y: -ry)
                ))
            }
            // Shadow rim
            ctx.fill(path, with: .radialGradient(
                Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.6),
                    .init(color: Color.black.opacity(0.2), location: 1)
                ]),
                center: .zero, startRadius: R*0.15, endRadius: R*1.25
            ))
            // Highlight
            ctx.fill(path, with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color.white.opacity(0.55), location: 0),
                    .init(color: .clear, location: 1)
                ]),
                center: CGPoint(x: rx*0.34, y: -ry*0.46),
                startRadius: 0,
                endRadius: R*0.42
            ))
        }
    }

    private func drawBlush(ctx: inout GraphicsContext, path: Path, rx: CGFloat, ry: CGFloat, R: CGFloat, blush: CGFloat) {
        ctx.clip(to: path)
        let yOffset = sin(yaw) * rx * 0.8
        for sd in [-1.0, 1.0] {
            let bx = CGFloat(sd) * rx * 0.55 + yOffset
            let by = ry * 0.2
            var ellipse = Path()
            ellipse.addEllipse(in: CGRect(x: bx - R*0.17, y: by - R*0.1, width: R*0.34, height: R*0.2))
            ctx.fill(ellipse, with: .color(Color(red: 1, green: 0.471, blue: 0.588, opacity: Double(0.5 * blush))))
        }
    }

    private func drawEyes(ctx: inout GraphicsContext, path: Path, R: CGFloat, rx: CGFloat, ry: CGFloat) {
        var shape = eyeOverride ?? cfg.eye
        // Dance: happy eyes in calm states
        if isDancing && dancingLevel > 0.15 && !isMini && (state == .idle || state == .finished) {
            shape = .happy
        }
        // In box mode: cup eyes when file over box (slotHTarget set), happy arcs while chewing
        if morph > 0.5 {
            if isChewing { shape = .happy }
            else if slotHTarget > 0.05 || slotH > 0.10 { shape = .cup }
        }
        ctx.clip(to: path)

        // Build eye frames: use mEyeFrames for position/foreshortening, but keep roll in eyePitch
        let mH = MochiH(R: R, yaw: yaw, pitch: pitch)
        for f in mEyeFrames(mH) {
            // Re-derive pitch with roll for the roll-through effect
            var eyePitch = MochiConst.eyeP + pitch + roll
            eyePitch = ((eyePitch + .pi).truncatingRemainder(dividingBy: .pi*2) + .pi*2).truncatingRemainder(dividingBy: .pi*2) - .pi
            let cp = cos(eyePitch)
            let eyeYaw = f.sd * MochiConst.eyeSp + yaw
            guard cos(eyeYaw) * cp > 0.04 else { continue }

            let ey = f.y + (morph > 0 ? ry * 0.14 * morph : 0)
            let fx = lerp(f.fx, 1, morph * 0.7)
            let fy = lerp(f.fy, 1, morph * 0.7)

            let eyeMult: CGFloat = isMini ? 1.9 : 1.0
            let ew = R * MochiConst.eyeW * es * eyeMult
            let eh = R * MochiConst.eyeH * es * eyeMult

            var eyeCtx = ctx
            eyeCtx.translateBy(x: f.x, y: ey)
            eyeCtx.scaleBy(x: fx, y: fy)
            drawEyeShape(ctx: &eyeCtx, shape: shape, w: ew, h: eh, open: open, sd: f.sd, R: R)
        }
    }

    private func drawEyeShape(ctx: inout GraphicsContext, shape: EyeShape, w: CGFloat, h: CGFloat, open: CGFloat, sd: CGFloat, R: CGFloat) {
        let ink = isMini ? Color(cgColor: MochiConst.miniInk) : Color(cgColor: MochiConst.ink)
        let now = CGFloat(CACurrentMediaTime())

        switch shape {
        case .wide:
            drawEyeShape(ctx: &ctx, shape: .pill, w: w*1.16, h: h*1.12, open: open, sd: sd, R: R)

        case .pill:
            let hh = max(h * open, w * 0.3)
            var p = Path()
            p.addRoundedRect(in: CGRect(x: -w/2, y: -hh/2, width: w, height: hh),
                             cornerSize: CGSize(width: min(w/2, hh/2), height: min(w/2, hh/2)))
            ctx.fill(p, with: .color(ink))

        case .dot:
            var p = Path()
            p.addEllipse(in: CGRect(x: -w*0.45, y: -w*0.45, width: w*0.9, height: w*0.9))
            ctx.fill(p, with: .color(ink))

        case .line:
            ctx.rotate(by: .radians(-sd * 0.2))
            var p = Path()
            p.addRoundedRect(in: CGRect(x: -w*0.78, y: -w*0.21, width: w*1.56, height: w*0.42),
                             cornerSize: CGSize(width: w*0.21, height: w*0.21))
            ctx.fill(p, with: .color(ink))

        case .flat:
            var p = Path()
            p.addRoundedRect(in: CGRect(x: -w*0.72, y: -w*0.2, width: w*1.44, height: w*0.4),
                             cornerSize: CGSize(width: w*0.2, height: w*0.2))
            ctx.fill(p, with: .color(ink))

        case .happy:
            var p = Path()
            p.addArc(center: CGPoint(x: 0, y: h*0.18), radius: w*0.82,
                     startAngle: .degrees(180 + 12), endAngle: .degrees(180 - 12), clockwise: true)
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w*0.5, lineCap: .round))

        case .closed:
            var p = Path()
            p.addArc(center: CGPoint(x: 0, y: -h*0.08), radius: w*0.78,
                     startAngle: .degrees(15), endAngle: .degrees(165), clockwise: false)
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w*0.36, lineCap: .round))

        case .spiral:
            var p = Path()
            var a: CGFloat = 0
            while a < 4.4 * .pi {
                let r  = w * 0.06 + a * w * 0.058
                let aa = a + now * 9 * sd
                let px = cos(aa) * r
                let py = sin(aa) * r
                if a == 0 { p.move(to: CGPoint(x: px, y: py)) }
                else { p.addLine(to: CGPoint(x: px, y: py)) }
                a += 0.2
            }
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w*0.22, lineCap: .round))

        case .heart:
            let heartPath = heartShape(size: w * 1.2)
            ctx.fill(heartPath, with: .color(Color(hex: "#FF4D6D")))

        case .star:
            ctx.rotate(by: .radians(now * 1.5 * sd))
            let starPath = starShape(outer: w * 1.05, inner: w * 0.46)
            ctx.fill(starPath, with: .color(Color(hex: "#F7B32B")))

        case .tired:
            var p1 = Path()
            p1.addRoundedRect(in: CGRect(x: -w/2, y: -h*0.02, width: w, height: h*0.38),
                              cornerSize: CGSize(width: w/2, height: w/2))
            ctx.fill(p1, with: .color(ink))
            var p2 = Path()
            p2.addRoundedRect(in: CGRect(x: -w*0.62, y: -h*0.1, width: w*1.24, height: w*0.22),
                              cornerSize: CGSize(width: w*0.11, height: w*0.11))
            ctx.fill(p2, with: .color(ink))

        case .wink:
            if sd < 0 {
                let hh = max(h * open, w * 0.3)
                var p = Path()
                p.addRoundedRect(in: CGRect(x: -w/2, y: -hh/2, width: w, height: hh),
                                 cornerSize: CGSize(width: min(w/2,hh/2), height: min(w/2,hh/2)))
                ctx.fill(p, with: .color(ink))
            } else {
                var p = Path()
                p.addArc(center: CGPoint(x: 0, y: h*0.18), radius: w*0.82,
                         startAngle: .degrees(180+12), endAngle: .degrees(180-12), clockwise: true)
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: w*0.5, lineCap: .round))
            }

        case .cup:
            // Flat top, rounded bottom corners (like a cup / U-shape)
            let hh = max(h * open, w * 0.3)
            let cr = min(w / 2, hh / 2)  // bottom corner radius
            var p = Path()
            p.move(to: CGPoint(x: -w/2, y: -hh/2))
            p.addLine(to: CGPoint(x: w/2, y: -hh/2))
            p.addLine(to: CGPoint(x: w/2, y: hh/2 - cr))
            p.addQuadCurve(to: CGPoint(x: w/2 - cr, y: hh/2),
                           control: CGPoint(x: w/2, y: hh/2))
            p.addLine(to: CGPoint(x: -w/2 + cr, y: hh/2))
            p.addQuadCurve(to: CGPoint(x: -w/2, y: hh/2 - cr),
                           control: CGPoint(x: -w/2, y: hh/2))
            p.closeSubpath()
            ctx.fill(p, with: .color(ink))
        }
    }

    private func drawBadge(context: GraphicsContext, size: CGSize, badge: BadgeType, R: CGFloat, rx: CGFloat, ry: CGFloat, cx: CGFloat, cy: CGFloat) {
        let bs = badgeS * (isMini ? 1.25 : 1)
        let bx = cx - R * 0.72 * sx
        let by = cy - R * 0.72 * sy
        var ctx = context
        ctx.translateBy(x: bx, y: by)
        ctx.scaleBy(x: bs, y: bs)
        let now = CGFloat(CACurrentMediaTime())

        switch badge {
        case .dots(let col):
            if isMini {
                // Mini: animated pulsing dot
                let phase = (now * 2.4).truncatingRemainder(dividingBy: 1)
                let dotR = R * 0.22 * (1 + 0.25 * sin(phase * .pi * 2))
                var outer = Path()
                outer.addEllipse(in: CGRect(x: -R*0.2, y: -R*0.2, width: R*0.4, height: R*0.4))
                ctx.fill(outer, with: .color(.black))
                var dot = Path()
                dot.addEllipse(in: CGRect(x: -dotR, y: -dotR, width: dotR*2, height: dotR*2))
                ctx.fill(dot, with: .color(Color(cgColor: col)))
            } else {
                // Pill badge with animated dots (prototype style)
                let pw: CGFloat = R * 0.72
                let ph: CGFloat = R * 0.36
                var pill = Path()
                pill.addRoundedRect(in: CGRect(x: -pw/2, y: -ph/2, width: pw, height: ph),
                                    cornerSize: CGSize(width: ph/2, height: ph/2))
                ctx.fill(pill, with: .color(Color(cgColor: col)))
                for i in 0..<3 {
                    let phase = ((now * 2.4 - CGFloat(i) * 0.22).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
                    let dotR = R * 0.055 * (1 + 0.4 * max(0, sin(phase * .pi * 2)))
                    var dot = Path()
                    dot.addEllipse(in: CGRect(x: (CGFloat(i)-1)*R*0.18 - dotR, y: -dotR, width: dotR*2, height: dotR*2))
                    ctx.fill(dot, with: .color(.white))
                }
            }

        case .bang(let col), .question(let col):
            var ring = Path()
            ring.addEllipse(in: CGRect(x: -R*0.3, y: -R*0.3, width: R*0.6, height: R*0.6))
            ctx.fill(ring, with: .color(.black))
            var inner = Path()
            inner.addEllipse(in: CGRect(x: -R*0.23, y: -R*0.23, width: R*0.46, height: R*0.46))
            ctx.fill(inner, with: .color(Color(cgColor: col)))
            if !isMini {
                let text = badge == .bang(col) ? "!" : "?"
                ctx.draw(Text(text).font(.system(size: R*0.32, weight: .black)).foregroundColor(.white),
                         at: CGPoint(x: 0, y: R*0.02))
            }

        case .dot(let col):
            var outer = Path()
            outer.addEllipse(in: CGRect(x: -R*0.2, y: -R*0.2, width: R*0.4, height: R*0.4))
            ctx.fill(outer, with: .color(.black))
            var inner = Path()
            inner.addEllipse(in: CGRect(x: -R*0.135, y: -R*0.135, width: R*0.27, height: R*0.27))
            ctx.fill(inner, with: .color(Color(cgColor: col)))
        }
    }

    private func drawParticles(context: GraphicsContext, size: CGSize, R: CGFloat, cx: CGFloat, cy: CGFloat) {
        for p in particles {
            guard p.age > 0 else { continue }
            let k = CGFloat(p.age / p.life)
            let a = k < 0.2 ? k / 0.2 : 1 - (k - 0.2) / 0.8
            let px = cx + (p.x + p.vx * CGFloat(p.age)) * R * 1.3
            let py = cy + (p.y + p.vy * CGFloat(p.age)) * R * 1.3
            let sz = R * p.size * (1 + k * 0.4)

            var pctx = context
            pctx.translateBy(x: px, y: py)
            pctx.opacity = Double(min(max(a, 0), 1))

            switch p.type {
            case .heart:
                pctx.rotate(by: .radians(sin(CGFloat(p.age) * 6) * 0.3))
                pctx.fill(heartShape(size: sz), with: .color(Color(hex: "#FF4D6D")))
            case .star:
                pctx.rotate(by: .radians(p.rot + CGFloat(p.age) * 2))
                pctx.fill(starShape(outer: sz, inner: sz*0.45), with: .color(Color(hex: "#F7B32B")))
            case .spark:
                pctx.rotate(by: .radians(p.rot))
                pctx.fill(starShape(outer: sz*0.8, inner: sz*0.18), with: .color(.white))
            case .sweat:
                var drop = Path()
                drop.move(to: CGPoint(x: 0, y: -sz))
                drop.addQuadCurve(to: CGPoint(x: 0, y: sz*0.6), control: CGPoint(x: sz*0.8, y: sz*0.2))
                drop.addQuadCurve(to: CGPoint(x: 0, y: -sz), control: CGPoint(x: -sz*0.8, y: sz*0.2))
                pctx.fill(drop, with: .color(Color(hex: "#7CC7FF")))
            case .z:
                pctx.draw(Text("z").font(.system(size: sz*1.9, weight: .bold)).foregroundColor(Color(red: 0.82, green: 0.86, blue: 0.92)),
                          at: .zero)
            }
        }
    }

    // MARK: - Tween helpers

    func anim(_ key: String, keys: [TweenKey], onComplete: (() -> Void)? = nil) {
        let current = getProperty(key)
        tweens[key] = Tween(property: key, keys: keys, keyIndex: 0,
                            from: current, startTime: CACurrentMediaTime() * 1000,
                            onComplete: onComplete)
        locks.insert(key)
    }

    private func setTarget(key: String, value: CGFloat) {
        guard !locks.contains(key) else { return }
        switch key {
        case "tint":  tint  += (value - tint)  // immediate target, smoothed in update
        case "tilt":  tgTilt = value
        default: break
        }
    }

    private func setProperty(_ key: String, value: CGFloat) {
        switch key {
        case "yaw":           yaw           = value
        case "pitch":         pitch         = value
        case "roll":          roll          = value
        case "tilt":          tilt          = value
        case "open":          open          = value
        case "sx":            sx            = value
        case "sy":            sy            = value
        case "oy":            oy            = value
        case "ox":            ox            = value
        case "tint":          tint          = value
        case "morph":         morph         = value
        case "hands":         hands         = value
        case "blush":         blush         = value
        case "es":            es            = value
        case "badgeS":        badgeS        = value
        case "outfitPresence": outfitPresence = value
        default: break
        }
    }

    private func getProperty(_ key: String) -> CGFloat {
        switch key {
        case "yaw":           return yaw
        case "pitch":         return pitch
        case "roll":          return roll
        case "tilt":          return tilt
        case "open":          return open
        case "sx":            return sx
        case "sy":            return sy
        case "oy":            return oy
        case "ox":            return ox
        case "tint":          return tint
        case "morph":         return morph
        case "hands":         return hands
        case "blush":         return blush
        case "es":            return es
        case "badgeS":        return badgeS
        case "outfitPresence": return outfitPresence
        default:              return 0
        }
    }
}

// MARK: - Math helpers

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b-a) * t }
private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }

private func cgColorToTuple(_ c: CGColor) -> (CGFloat, CGFloat, CGFloat) {
    guard let comps = c.components, comps.count >= 3 else { return (1,1,1) }
    return (comps[0], comps[1], comps[2])
}

private func mix3(_ a: (CGFloat,CGFloat,CGFloat), _ b: (CGFloat,CGFloat,CGFloat), _ t: CGFloat) -> (CGFloat,CGFloat,CGFloat) {
    (lerp(a.0,b.0,t), lerp(a.1,b.1,t), lerp(a.2,b.2,t))
}

private func mixColor(_ a: (CGFloat,CGFloat,CGFloat), _ b: (CGFloat,CGFloat,CGFloat), _ t: CGFloat) -> (CGFloat,CGFloat,CGFloat) {
    mix3(a, b, t)
}

private func colorFromTuple(_ t: (CGFloat,CGFloat,CGFloat)) -> Color {
    Color(red: Double(t.0), green: Double(t.1), blue: Double(t.2))
}

private func badgeString(_ b: BadgeType?) -> String {
    guard let b else { return "none" }
    func hex(_ c: CGColor) -> String {
        guard let k = c.components, k.count >= 3 else { return "?" }
        return "\(Int(k[0]*255)).\(Int(k[1]*255)).\(Int(k[2]*255))"
    }
    switch b {
    case .dots(let c):     return "dots-\(hex(c))"
    case .bang(let c):     return "bang-\(hex(c))"
    case .question(let c): return "q-\(hex(c))"
    case .dot(let c):      return "dot-\(hex(c))"
    }
}

private func emoteEyeShape(_ e: BotEmote) -> EyeShape {
    switch e {
    case .love:      return .heart
    case .surprised: return .dot
    case .proud:     return .star
    case .wink:      return .wink
    case .yawn:      return .tired
    case .happy:     return .happy
    case .annoyed:   return .line
    }
}

// MARK: - Shape helpers

private func heartShape(size s: CGFloat) -> Path {
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

private func starShape(outer ro: CGFloat, inner ri: CGFloat) -> Path {
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

// Equatable for BadgeType (needed for comparing)
extension BadgeType: Equatable {
    static func == (lhs: BadgeType, rhs: BadgeType) -> Bool {
        switch (lhs, rhs) {
        case (.dots, .dots): return true
        case (.bang, .bang): return true
        case (.question, .question): return true
        case (.dot, .dot): return true
        default: return false
        }
    }
}
