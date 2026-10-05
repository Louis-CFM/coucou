import SwiftUI
import QuartzCore

// The opening: Mochi alone on black while the app loads, his gaze wandering
// and his eyes slowly growing round, shrinking, flattening to a bar, all in
// one continuous motion (no blink, no shape that snaps into another). When
// iCloud has answered he flies to his spot on the home screen, the VS Code
// session's tile (or the island at the top when there's no VS Code session).

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
    /// True once the app has what it needs to show the home screen.
    let ready: Bool
    let onFinished: () -> Void

    @State private var start = Date()
    @State private var flightStart: Date?
    @State private var fade = false
    @State private var engine = IntroEngine()
    private var landing: IntroLanding { .shared }

    /// He plays for at least this long, even if everything is already there.
    private let minimum: TimeInterval = 3.2
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
                        // Over 0.45 s of the flight his face settles back to neutral.
                        let settle = flightStart.map { min(1, now.timeIntervalSince($0) / 0.45) } ?? 0
                        engine.draw(context: context, size: size,
                                    pose: IntroEngine.pose(at: now.timeIntervalSince(start)), settle: settle)
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
            // Wait for iCloud a little longer, but never more than 5 s in all.
            var waited = minimum
            while !ready && waited < 5 {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 0.2
            }
            withAnimation(.spring(duration: 0.75, bounce: 0.22)) { flightStart = Date() }
            withAnimation(.easeOut(duration: 0.55).delay(0.15)) { fade = true }
            try? await Task.sleep(for: .milliseconds(750))
            landing.landed = true
            onFinished()
        }
    }
}

/// Mochi's face for the opening, drawn by the same engine as everywhere else
/// but driven by smooth curves: where he looks, how he tilts, how big and how
/// open his eyes are. The eyes stay the same pill and only change size and
/// height, so a round eye, a small one and a bar flow into each other.
@MainActor
final class IntroEngine {
    private let bot: BotEngine = {
        let bot = BotEngine()
        bot.isMini = true
        bot.bodyColor = cgColorFromHex("#FFFFFF")
        bot.setState(.idle, force: true)
        return bot
    }()

    struct Pose {
        var yaw: CGFloat = 0
        var pitch: CGFloat = 0
        var tilt: CGFloat = 0
        /// Eye size (1 = usual).
        var scale: CGFloat = 1
        /// Eye height (1 = usual pill, ~0.2 = a bar).
        var open: CGFloat = 1
    }

    /// One loop of his show, every 0.6 s or so: look left, look right, eyes
    /// big and round looking up, small, a bar, back at you.
    private static let keys: [Pose] = [
        Pose(),
        Pose(yaw: -0.5, pitch: -0.08, tilt: -0.06, scale: 1.05, open: 1),
        Pose(yaw: 0.45, pitch: 0.12, tilt: 0.08, scale: 0.92, open: 0.8),
        Pose(yaw: 0.12, pitch: -0.28, tilt: 0, scale: 1.38, open: 1.2),
        Pose(yaw: -0.22, pitch: 0.1, tilt: -0.05, scale: 0.68, open: 0.95),
        Pose(yaw: 0.06, pitch: 0.02, tilt: 0.06, scale: 1.1, open: 0.18),
        Pose(),
    ]
    private static let step: Double = 0.6

    /// A smooth path through the keys (Catmull-Rom), looping: he never stops dead.
    static func pose(at elapsed: TimeInterval) -> Pose {
        let count = keys.count - 1                // the last key is the first again
        let position = (elapsed / step).truncatingRemainder(dividingBy: Double(count))
        let i = Int(position)
        let t = CGFloat(position - Double(i))
        func key(_ n: Int) -> Pose { keys[((n % count) + count) % count] }
        let p0 = key(i - 1), p1 = key(i), p2 = key(i + 1), p3 = key(i + 2)
        func spline(_ v: (Pose) -> CGFloat) -> CGFloat {
            let a = v(p0), b = v(p1), c = v(p2), d = v(p3)
            return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (-a + 3 * b - 3 * c + d) * t * t * t)
        }
        return Pose(yaw: spline(\.yaw), pitch: spline(\.pitch), tilt: spline(\.tilt),
                    scale: spline(\.scale), open: spline(\.open))
    }

    func draw(context: GraphicsContext, size: CGSize, pose: Pose, settle: Double) {
        let keep = CGFloat(1 - settle)
        bot.yaw = pose.yaw * keep
        bot.pitch = pose.pitch * keep
        bot.tilt = pose.tilt * keep
        bot.es = 1 + (pose.scale - 1) * keep
        bot.open = 1 + (pose.open - 1) * keep
        // A slow breath.
        let breath = CGFloat(sin(CACurrentMediaTime() * 2.1)) * 0.018 * keep
        bot.sx = 1 - breath
        bot.sy = 1 + breath
        bot.draw(context: context, size: size)
    }
}
