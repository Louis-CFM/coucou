import SwiftUI

// The opening: Mochi alone on black while the app loads, looking around and
// playing with his eyes (big and round, small, a bar). When iCloud has
// answered he flies to his spot on the home screen, the VS Code session's
// tile (or the island at the top when there's no VS Code session).

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
    @State private var flying = false
    @State private var fade = false
    private var landing: IntroLanding { .shared }

    /// He plays for at least this long, even if everything is already there.
    private let minimum: TimeInterval = 2.4
    private let size: CGFloat = 132

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let target = landing.target
            ZStack {
                Color.black
                    .opacity(fade ? 0 : 1)
                TimelineView(.animation(paused: flying)) { timeline in
                    MochiStill(state: .idle, showBadge: false,
                               pose: flying ? .neutral : Self.pose(at: timeline.date.timeIntervalSince(start)))
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
            // Wait for iCloud a little longer, but never more than 4 s in all.
            var waited = minimum
            while !ready && waited < 4 {
                try? await Task.sleep(for: .milliseconds(200))
                waited += 0.2
            }
            withAnimation(.spring(duration: 0.7, bounce: 0.25)) { flying = true }
            withAnimation(.easeOut(duration: 0.5).delay(0.15)) { fade = true }
            try? await Task.sleep(for: .milliseconds(700))
            landing.landed = true
            onFinished()
        }
    }

    // MARK: His little show

    private struct Key {
        let time: Double
        let yaw: CGFloat
        let pitch: CGFloat
        let eye: EyeShape?
    }

    /// Looks left, right, up with big round eyes, small eyes, a bar, then back at you.
    private static let keys: [Key] = [
        Key(time: 0.0, yaw: 0, pitch: 0, eye: nil),
        Key(time: 0.35, yaw: -0.55, pitch: 0, eye: nil),
        Key(time: 0.75, yaw: 0.55, pitch: 0, eye: nil),
        Key(time: 1.1, yaw: 0.1, pitch: -0.3, eye: .wide),
        Key(time: 1.45, yaw: 0, pitch: 0, eye: .dot),
        Key(time: 1.8, yaw: -0.15, pitch: 0.1, eye: .line),
        Key(time: 2.1, yaw: 0, pitch: 0, eye: nil),
    ]
    private static let loop = 2.4

    static func pose(at elapsed: TimeInterval) -> MochiPose {
        let t = elapsed.truncatingRemainder(dividingBy: loop)
        let next = keys.firstIndex { $0.time > t } ?? keys.count
        let a = keys[max(0, next - 1)]
        let b = next < keys.count ? keys[next] : keys[0]
        let span = (next < keys.count ? b.time : loop) - a.time
        let p = span > 0 ? min(1, (t - a.time) / span) : 1
        // Ease in and out, so he turns his head rather than snapping.
        let e = CGFloat(0.5 - cos(p * .pi) / 2)
        // Eyes change shape at the key, and blink shut for a moment in between.
        let blink = p > 0.88 && a.eye != b.eye
        return MochiPose(yaw: a.yaw + (b.yaw - a.yaw) * e,
                         pitch: a.pitch + (b.pitch - a.pitch) * e,
                         eye: blink ? .closed : a.eye)
    }
}
