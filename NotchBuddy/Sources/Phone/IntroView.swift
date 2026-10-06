import SwiftUI
import QuartzCore

// The opening: Mochi alone on black while the app loads. He pops in and looks
// around like the greeting on the Mac (without the hands): quick glances and
// slow ones, eyes that pop round, shrink or squint to a bar, his body leaning,
// hopping and squashing along. It hides the first iCloud fetch: as soon as
// it's over he finishes with a little hop and flies to his spot on the home
// screen, the VS Code session's tile (or the island at the top), and the home
// screen behind is already up to date.

/// Where the intro's Mochi lands. The tile reports its frame on screen.
@MainActor
@Observable
final class IntroLanding {
    static let shared = IntroLanding()

    var tileFrame: CGRect?
    var headerFrame: CGRect?
    /// The intro is over: the real Mochi on the home screen show again.
    var landed = false

    var target: CGRect? { tileFrame ?? headerFrame }
}

extension View {
    /// Reports this view's frame as the intro's landing spot; hidden until he lands.
    func introLanding(_ kind: IntroLandingKind) -> some View {
        modifier(IntroLandingModifier(kind: kind))
    }
}

enum IntroLandingKind { case tile, header }

private struct IntroLandingModifier: ViewModifier {
    let kind: IntroLandingKind
    private var landing: IntroLanding { .shared }

    func body(content: Content) -> some View {
        content
            .opacity(landing.landed || !isTarget ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                switch kind {
                case .tile: landing.tileFrame = frame
                case .header: landing.headerFrame = frame
                }
            }
            .onDisappear {
                if kind == .tile { landing.tileFrame = nil }
            }
    }

    /// Only the spot he actually flies to is hidden.
    private var isTarget: Bool {
        switch kind {
        case .tile: true
        case .header: landing.tileFrame == nil
        }
    }
}

struct IntroView: View {
    /// True once the first iCloud fetch is over.
    let ready: Bool
    let onFinished: () -> Void

    @State private var flightStart: Date?
    @State private var fade = false
    @State private var engine = IntroEngine()
    private var landing: IntroLanding { .shared }

    /// He plays at least this long, even when everything is already there,
    /// and never keeps the app waiting longer than `maximum`.
    private let minimum: TimeInterval = 2.4
    private let maximum: TimeInterval = 6
    private let size: CGFloat = 132

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let target = landing.target
            let flying = flightStart != nil
            ZStack {
                Color.black
                    .opacity(fade ? 0 : 1)
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let now = timeline.date
                        // Over 0.4 s of the flight his face settles back to neutral.
                        let settle = flightStart.map { min(1, now.timeIntervalSince($0) / 0.4) } ?? 0
                        engine.draw(context: context, size: size, settle: settle)
                    }
                }
                .frame(width: flying ? (target?.width ?? size) : size,
                       height: flying ? (target?.height ?? size) : size)
                .position(flying ? CGPoint(x: target?.midX ?? center.x, y: target?.midY ?? center.y) : center)
                .opacity(flying && target == nil ? 0 : 1)
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .allowsHitTesting(!fade)
        .task {
            try? await Task.sleep(for: .seconds(minimum))
            var waited = minimum
            while !ready && waited < maximum {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 0.1
            }
            // Everything is there: a last hop looking at you, then off he goes.
            engine.finish()
            try? await Task.sleep(for: .milliseconds(480))
            withAnimation(.spring(duration: 0.7, bounce: 0.22)) { flightStart = Date() }
            withAnimation(.easeOut(duration: 0.5).delay(0.12)) { fade = true }
            try? await Task.sleep(for: .milliseconds(700))
            landing.landed = true
            onFinished()
        }
    }
}

/// A damped spring: stiff ones snap (a glance), soft ones drift (a slow look).
private struct Spring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    /// Stiffness and damping of the move in progress.
    var k: CGFloat = 200
    var c: CGFloat = 26

    init(_ value: CGFloat) {
        self.value = value
        target = value
    }

    mutating func go(_ target: CGFloat, _ motion: Motion) {
        self.target = target
        k = motion.k
        c = motion.c
    }

    mutating func step(_ dt: CGFloat) {
        velocity += (k * (target - value) - c * velocity) * dt
        value += velocity * dt
    }
}

/// How a move happens.
private struct Motion {
    var k: CGFloat
    var c: CGFloat
    /// A glance: very fast, a hint of overshoot.
    static let snap = Motion(k: 900, c: 42)
    /// A normal look.
    static let look = Motion(k: 260, c: 28)
    /// A slow, curious drift.
    static let drift = Motion(k: 55, c: 14)
    /// Eyes popping open: bouncy.
    static let pop = Motion(k: 520, c: 16)
    /// Squinting: quick, no bounce.
    static let squint = Motion(k: 700, c: 52)
    /// Reopening after a squint: slow.
    static let ease = Motion(k: 90, c: 17)
}

/// Mochi's face and body for the opening, drawn by the same engine as
/// everywhere else, driven here by a little show of moves. Each move has its
/// own speed, his body follows where he looks (leans, drifts, tilts with the
/// motion) and hops land with a squash, so it never feels mechanical. The
/// eyes stay the same pill and only change size and height: no blink.
@MainActor
final class IntroEngine {
    private let bot: BotEngine = {
        let bot = BotEngine()
        bot.isMini = true
        bot.bodyColor = cgColorFromHex("#FFFFFF")
        bot.setState(.idle, force: true)
        return bot
    }()

    private enum Body { case none, hop, squash, shiver }

    private struct Beat {
        var x: CGFloat = 0, y: CGFloat = 0
        var gaze: Motion = .look
        var eyes: CGFloat = 1, open: CGFloat = 1
        var eyeMotion: Motion = .look
        var body: Body = .none
        /// How long he stays on it.
        var hold: Double
    }

    /// The show, in order, then random moves from `idle` while iCloud is still busy.
    private static let show: [Beat] = [
        Beat(eyes: 1.05, eyeMotion: .pop, hold: 0.42),                                         // hello
        Beat(x: -0.75, y: 0.05, gaze: .snap, hold: 0.5),                                       // glance left
        Beat(x: 0.62, y: 0.16, gaze: .drift, eyes: 0.82, eyeMotion: .drift, hold: 0.75),       // slowly to the right
        Beat(x: 0.08, y: -0.45, gaze: .look, eyes: 1.42, eyeMotion: .pop, body: .hop, hold: 0.55), // up, big round eyes
        Beat(x: 0.28, y: 0.04, gaze: .look, eyes: 1.05, open: 0.2, eyeMotion: .squint, body: .squash, hold: 0.5), // a bar
        Beat(x: -0.42, y: 0.32, gaze: .drift, eyes: 0.74, eyeMotion: .ease, hold: 0.55),       // small, down left
        Beat(x: 0.7, y: -0.04, gaze: .snap, eyes: 0.9, hold: 0.16),                            // double take…
        Beat(x: 0, y: 0, gaze: .snap, eyes: 1.25, eyeMotion: .pop, body: .shiver, hold: 0.45), // …at you
    ]
    private static let idle: [Beat] = [
        Beat(x: -0.6, y: -0.2, gaze: .snap, eyes: 1.15, eyeMotion: .pop, hold: 0.5),
        Beat(x: 0.55, y: 0.25, gaze: .drift, eyes: 0.8, eyeMotion: .drift, hold: 0.6),
        Beat(x: 0.15, y: -0.4, gaze: .look, eyes: 1.35, eyeMotion: .pop, body: .hop, hold: 0.5),
        Beat(x: -0.2, y: 0.05, gaze: .look, open: 0.22, eyeMotion: .squint, body: .squash, hold: 0.45),
        Beat(x: 0.7, y: 0, gaze: .snap, hold: 0.35),
        Beat(x: -0.35, y: 0.3, gaze: .drift, eyes: 0.72, eyeMotion: .ease, hold: 0.55),
    ]
    private static let last = Beat(x: 0, y: 0, gaze: .look, eyes: 1.12, eyeMotion: .pop, body: .hop, hold: 10)

    private var yaw = Spring(0), pitch = Spring(0)
    private var eyes = Spring(0.6), open = Spring(1)
    private var sx = Spring(0.25), sy = Spring(0.25)
    private var lean = Spring(0), tilt = Spring(0)
    /// Height off the ground (negative is up) and its speed, with gravity.
    private var oy: CGFloat = 0, oyVelocity: CGFloat = 0
    /// A hop waiting for its crouch to end.
    private var launchAt: Double?
    private var shiverUntil: Double = 0

    private var index = 0
    private var nextBeat: Double?
    private var lastTime: Double?
    private var lastIdle = -1
    private var finishing = false

    init() {
        // He pops in from nothing.
        sx.go(1, .pop)
        sy.go(1, .pop)
    }

    /// The app is ready: back to looking at you, one last hop.
    func finish() {
        guard !finishing else { return }
        finishing = true
        play(Self.last, at: CACurrentMediaTime())
    }

    private func play(_ beat: Beat, at now: Double) {
        yaw.go(beat.x * 0.62, beat.gaze)
        pitch.go(beat.y * 0.5, beat.gaze)
        eyes.go(beat.eyes, beat.eyeMotion)
        open.go(beat.open, beat.open < 0.5 ? .squint : beat.eyeMotion)
        // The body leans the way he looks, a little behind his eyes.
        lean.go(beat.x * 0.14, beat.gaze.k > 500 ? .look : .drift)
        tilt.go(beat.x * 0.07, .drift)
        // A quick glance jolts the body.
        if beat.gaze.k > 500 {
            sx.velocity += 0.9
            sy.velocity -= 0.9
        }
        switch beat.body {
        case .hop:
            // Crouch first, then jump.
            sx.velocity += 2.2
            sy.velocity -= 2.6
            launchAt = now + 0.1
        case .squash:
            sx.velocity += 1.8
            sy.velocity -= 2.0
        case .shiver:
            shiverUntil = now + 0.28
        case .none:
            break
        }
        nextBeat = now + beat.hold
    }

    private func advance(_ now: Double) {
        if finishing { return }
        if index < Self.show.count {
            play(Self.show[index], at: now)
            index += 1
        } else {
            var pick = Int.random(in: 0..<Self.idle.count)
            if pick == lastIdle { pick = (pick + 1) % Self.idle.count }
            lastIdle = pick
            play(Self.idle[pick], at: now)
        }
    }

    private func step(_ now: Double) {
        let dt = CGFloat(min(1.0 / 30, now - (lastTime ?? now)))
        lastTime = now
        if now >= nextBeat ?? 0 { advance(now) }

        if let launch = launchAt, now >= launch {
            launchAt = nil
            oyVelocity = -2.3
            sx.velocity -= 2.4    // stretched in the air
            sy.velocity += 3.0
        }
        // Two half steps: the stiff springs stay stable at any frame rate.
        for _ in 0..<2 {
            let h = dt / 2
            yaw.step(h); pitch.step(h)
            eyes.step(h); open.step(h)
            sx.step(h); sy.step(h)
            lean.step(h); tilt.step(h)
            if oy < 0 || oyVelocity < 0 {
                oyVelocity += 15 * h
                oy += oyVelocity * h
                if oy >= 0 {
                    // Landing: squash with the speed he had.
                    sx.velocity += oyVelocity * 0.9
                    sy.velocity -= oyVelocity * 1.1
                    oy = 0
                    oyVelocity = 0
                }
            }
        }
    }

    func draw(context: GraphicsContext, size: CGSize, settle: Double) {
        let now = CACurrentMediaTime()
        step(now)
        let keep = CGFloat(1 - settle)
        // A slow breath, on top of the moves.
        let breath = CGFloat(sin(now * 2.4)) * 0.022
        let shiver = now < shiverUntil ? CGFloat(sin(now * 70)) * 0.035 * CGFloat((shiverUntil - now) / 0.28) : 0
        bot.yaw = yaw.value * keep
        bot.pitch = pitch.value * keep
        bot.es = 1 + (eyes.value - 1) * keep
        bot.open = 1 + (open.value - 1) * keep
        bot.ox = (lean.value + shiver) * keep
        bot.oy = oy * keep
        // Leaning into the motion: he tilts with how fast his gaze moves.
        bot.tilt = (tilt.value - yaw.velocity * 0.012) * keep
        bot.sx = 1 + (sx.value - 1 - breath * 0.6) * keep
        bot.sy = 1 + (sy.value - 1 + breath) * keep
        bot.draw(context: context, size: size)
    }
}
