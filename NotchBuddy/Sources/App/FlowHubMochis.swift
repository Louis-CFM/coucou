#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Visible or not

private struct HubVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the Coucou window is on screen: the Mochis rest (no frame drawn) while it is hidden,
    /// minimized or covered.
    var hubVisible: Bool {
        get { self[HubVisibleKey.self] }
        set { self[HubVisibleKey.self] = newValue }
    }
}

/// Follows the Coucou window's occlusion, for `hubVisible`.
@MainActor
final class HubWindowState: ObservableObject {
    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    func watch(_ window: NSWindow) {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                          NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification,
                                          NSWindow.willCloseNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let closing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let on = !closing && window.occlusionState.contains(.visible) && !window.isMiniaturized
                    if on != self.visible { self.visible = on }
                }
            }
        }
    }
}

// MARK: - A troupe of mini Mochis

/// One Mochi of a scene: its look, and whether it walks around.
struct HubMochiSpec: Hashable {
    var color: String
    /// The drawing's width in points (the body is about two thirds of it).
    var size: CGFloat
    var outfit: Outfit = .none
    var state: BotState = .idle
    /// Walks left and right, stops, looks around. Otherwise stays where it is.
    var roams = true
    /// Where it starts, from 0 (left of its area) to 1 (right).
    var start: CGFloat = 0.5
}

/// The Mochis of a scene, moved frame by frame.
@MainActor
final class HubMochiTroupe: ObservableObject {
    @MainActor final class Walker {
        let spec: HubMochiSpec
        let engine: BotEngine
        var x: CGFloat
        var target: CGFloat
        var speed: CGFloat = 0.06
        var restUntil: Double
        var hop: CGFloat = 0
        var lastHello: Double = 0

        init(spec: HubMochiSpec) {
            self.spec = spec
            let e = BotEngine()
            e.isMini = true
            e.bodyColor = cgColorFromHex(spec.color)
            if spec.outfit != .none { e.setOutfit(spec.outfit, animated: false) }
            if spec.state != .idle { e.setState(spec.state, force: true) }
            engine = e
            x = spec.start
            target = spec.start
            restUntil = CACurrentMediaTime() + Double.random(in: 0.5...3)
        }
    }

    private(set) var walkers: [Walker] = []
    private var last = CACurrentMediaTime()
    /// The part of the scene where they walk, from 0 to 1.
    var range: ClosedRange<CGFloat> = 0.05...0.95

    init(cast: [HubMochiSpec]) {
        walkers = cast.map { Walker(spec: $0) }
    }

    /// One frame: the walkers move, and stop now and then to do a little something.
    func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0, now - last)))
        last = now
        for actor in walkers {
            MochiFrameClock.advance(actor.engine)
            guard actor.spec.roams else { continue }
            if now < actor.restUntil {
                actor.hop = max(0, actor.hop - dt * 4)
                continue
            }
            let distance = actor.target - actor.x
            if abs(distance) < 0.004 {
                arrive(actor, now: now)
                continue
            }
            let move = min(abs(distance), actor.speed * dt)
            actor.x += distance > 0 ? move : -move
            actor.hop += dt * 9
        }
    }

    private func arrive(_ actor: Walker, now: Double) {
        actor.hop = 0
        actor.restUntil = now + Double.random(in: 1.2...5)
        actor.target = CGFloat.random(in: range)
        actor.speed = CGFloat.random(in: 0.035...0.08)
        // A little something once there.
        switch Int.random(in: 0..<10) {
        case 0, 1: actor.engine.triggerEmote(.happy, silent: true)
        case 2:    actor.engine.triggerEmote(.wink, silent: true)
        case 3:    actor.engine.doRoll(duration: 900, turns: 1)
        default:   break
        }
        // Two Mochis meeting say hello.
        for other in walkers where other !== actor && abs(other.x - actor.x) < 0.09 && now - actor.lastHello > 12 {
            actor.lastHello = now
            other.lastHello = now
            actor.engine.triggerEmote(.love, silent: true)
            other.engine.triggerEmote(.happy, silent: true)
            break
        }
    }

    /// A click on a Mochi: it blushes and jumps.
    func poke(at point: CGPoint, in size: CGSize) {
        let hit = walkers.min { distance(point, $0, size) < distance(point, $1, size) }
        guard let hit, distance(point, hit, size) < hit.spec.size * 0.6 else { return }
        hit.engine.triggerEmote(.love, silent: true)
        hit.engine.squash()
        hit.restUntil = CACurrentMediaTime() + 2
    }

    private func distance(_ p: CGPoint, _ actor: Walker, _ size: CGSize) -> CGFloat {
        let center = CGPoint(x: xPosition(actor, width: size.width), y: size.height - actor.spec.size * 0.45)
        return hypot(p.x - center.x, p.y - center.y)
    }

    func xPosition(_ actor: Walker, width: CGFloat) -> CGFloat {
        let half = actor.spec.size / 2
        return half + actor.x * max(0, width - actor.spec.size)
    }

    func draw(_ context: inout GraphicsContext, size: CGSize) {
        // Back to front: the small ones behind.
        for actor in walkers.sorted(by: { $0.spec.size < $1.spec.size }) {
            let w = actor.spec.size
            let cx = xPosition(actor, width: size.width)
            let lift = actor.spec.roams ? abs(sin(actor.hop)) * w * 0.07 : 0
            // Its shadow on the floor (a scene, not a lone Mochi).
            if size.height > w * 1.05 || walkers.count > 1 {
                let shadow = CGRect(x: cx - w * 0.26, y: size.height - w * 0.12, width: w * 0.52, height: w * 0.09)
                context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.28 - Double(lift / w))))
            }
            var c = context
            c.translateBy(x: cx - w / 2, y: size.height - w * 0.92 - lift)
            actor.engine.draw(context: c, size: CGSize(width: w, height: w))
        }
    }
}

/// A strip where a few mini Mochis live: drawn in one canvas, at the display's rate while the
/// window shows, still otherwise. Click one to say hello.
struct HubMochiScene: View {
    @StateObject private var troupe: HubMochiTroupe
    @Environment(\.hubVisible) private var visible

    init(cast: [HubMochiSpec], range: ClosedRange<CGFloat> = 0.05...0.95) {
        _troupe = StateObject(wrappedValue: {
            let t = HubMochiTroupe(cast: cast)
            t.range = range
            return t
        }())
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: !visible)) { timeline in
                let frame = timeline.date
                Canvas { context, size in
                    _ = frame
                    troupe.step()
                    troupe.draw(&context, size: size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in troupe.poke(at: location, in: geo.size) }
        }
    }
}

/// One Mochi that stays where it is (the logo, the empty pages).
struct HubLiveMochi: View {
    var color = "#F5F6F8"
    /// Width of the body; the drawing around it is larger.
    var size: CGFloat = 28
    var state: BotState = .idle
    var outfit: Outfit = .none

    var body: some View {
        HubMochiScene(cast: [HubMochiSpec(color: color, size: size / 0.68, outfit: outfit, state: state, roams: false)])
            .frame(width: size / 0.68, height: size / 0.68)
            .frame(width: size, height: size * 0.75)
    }
}

// MARK: - The top of each page

/// A page's colour and its Mochis.
struct HubHeroTheme {
    var color: Color
    var cast: [HubMochiSpec]

    static func of(_ page: HubPage) -> HubHeroTheme {
        func m(_ color: String, _ size: CGFloat, _ start: CGFloat, outfit: Outfit = .none,
               state: BotState = .idle, roams: Bool = true) -> HubMochiSpec {
            HubMochiSpec(color: color, size: size, outfit: outfit, state: state, roams: roams, start: start)
        }
        switch page {
        case .dictation:
            return .init(color: Color(hex: "#FB923C"), cast: [m("#F5F6F8", 66, 0.2), m("#FB923C", 52, 0.65), m("#F472B6", 44, 0.95, outfit: .bow)])
        case .notes:
            return .init(color: Color(hex: "#3B9EFF"), cast: [m("#3B9EFF", 58, 0.1, outfit: .roundGlasses), m("#34D399", 50, 0.5), m("#A78BFA", 46, 0.9)])
        case .insights:
            return .init(color: Color(hex: "#34D399"), cast: [m("#F7B32B", 62, 0.3, outfit: .crown), m("#34D399", 48, 0.75), m("#F5F6F8", 40, 1)])
        case .dictionary:
            return .init(color: Color(hex: "#A78BFA"), cast: [m("#A78BFA", 60, 0.2, outfit: .roundGlasses), m("#F5F6F8", 48, 0.8, outfit: .beanie)])
        case .snippets:
            return .init(color: Color(hex: "#F7B32B"), cast: [m("#F7B32B", 56, 0.15, state: .working), m("#FB923C", 46, 0.6), m("#F5F6F8", 40, 0.95)])
        case .styles:
            return .init(color: Color(hex: "#F472B6"), cast: [m("#F472B6", 60, 0.25, outfit: .sunglasses), m("#F5F6F8", 48, 0.7, outfit: .bow), m("#22D3EE", 42, 1, outfit: .partyHat)])
        case .settings:
            return .init(color: Color(hex: "#8E939C"), cast: [m("#F5F6F8", 56, 0.3), m("#8E939C", 46, 0.95, state: .sleeping, roams: false)])
        case .general:
            return .init(color: Color(hex: "#8E939C"), cast: [m("#F5F6F8", 60, 0.4, outfit: .scarf), m("#FB923C", 46, 0.85)])
        case .pills:
            return .init(color: Color(hex: "#F5A524"), cast: [m("#F5A524", 44, 0.05), m("#3B9EFF", 44, 0.3), m("#34D399", 44, 0.55),
                                                               m("#E07950", 44, 0.8), m("#A78BFA", 44, 1)])
        case .agents:
            return .init(color: Color(hex: "#3B9EFF"), cast: [m("#3B9EFF", 56, 0.1, state: .working, roams: false),
                                                               m("#E07950", 50, 0.5, state: .thinking, roams: false),
                                                               m("#34D399", 50, 0.9)])
        case .chat:
            return .init(color: Color(hex: "#E07950"), cast: [m("#E07950", 58, 0.3, state: .thinking, roams: false), m("#F5F6F8", 48, 0.85)])
        case .integrations:
            return .init(color: Color(hex: "#7C5CFF"), cast: [m("#7C5CFF", 54, 0.15), m("#22D3EE", 46, 0.55), m("#F7B32B", 42, 0.95)])
        case .voice:
            return .init(color: Color(hex: "#F97316"), cast: [m("#F97316", 60, 0.3), m("#F5F6F8", 48, 0.85, outfit: .roundGlasses)])
        case .shortcuts:
            return .init(color: Color(hex: "#6366F1"), cast: [m("#6366F1", 56, 0.2, outfit: .sunglasses), m("#F5F6F8", 46, 0.8)])
        }
    }
}

/// The top of a page: a coloured band with the title, a line, an action, and the page's Mochis
/// walking on its floor.
struct HubHero<Trailing: View>: View {
    let page: HubPage
    let title: String
    var subtitle: String?
    var compact = false
    @ViewBuilder var trailing: () -> Trailing
    @StateObject private var light = HubHeroLight()

    var body: some View {
        let theme = HubHeroTheme.of(page)
        ZStack(alignment: .bottomTrailing) {
            HubHeroBackdrop(color: theme.color, light: light)
                .allowsHitTesting(false)
            HubMochiScene(cast: theme.cast, range: 0...1)
                .id(page)
                .frame(width: compact ? 280 : 340, height: compact ? 92 : 128)
                .padding(.trailing, 18)
                .padding(.bottom, 6)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: compact ? 24 : 30, weight: .bold))
                        .tracking(-0.6)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#B7BBC2"))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 420, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    trailing()
                }
                .padding(compact ? 20 : 26)
                Spacer(minLength: compact ? 290 : 350)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: compact ? 116 : 170)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(theme.color.opacity(0.16)))
        // The light follows the pointer over the band.
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): light.target = point
            case .ended:             light.target = nil
            }
        }
    }
}

extension HubHero where Trailing == EmptyView {
    init(page: HubPage, title: String, subtitle: String? = nil, compact: Bool = false) {
        self.page = page
        self.title = title
        self.subtitle = subtitle
        self.compact = compact
        self.trailing = { EmptyView() }
    }
}

/// The light and the particles of a band, moved frame by frame without redrawing the page: the
/// pointer is written here by the hover handler and read by the canvas.
@MainActor
final class HubHeroLight: ObservableObject {
    struct Particle {
        var x: CGFloat, y: CGFloat
        /// Drift, in points per second.
        var vx: CGFloat, vy: CGFloat
        /// Push from the pointer, fading.
        var px: CGFloat = 0, py: CGFloat = 0
        var radius: CGFloat
        var phase: CGFloat
        /// 0.4 (far, slow, dim) to 1 (near, fast, bright).
        var depth: CGFloat
        var white: Bool
    }

    /// The pointer over the band, nil when it is elsewhere.
    var target: CGPoint?
    private(set) var position: CGPoint?
    /// 0 → 1 while the pointer is over the band.
    private(set) var strength: CGFloat = 0
    private(set) var particles: [Particle] = []
    private var size: CGSize = .zero
    private var last = CACurrentMediaTime()
    let start = CACurrentMediaTime()

    func step(size: CGSize) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0, now - last)))
        last = now
        if size != self.size { reset(size) }

        if let target {
            let from = position ?? target
            let k = min(1, dt * 9)
            position = CGPoint(x: from.x + (target.x - from.x) * k, y: from.y + (target.y - from.y) * k)
            strength = min(1, strength + dt * 3.5)
        } else {
            strength = max(0, strength - dt * 1.6)
        }

        let t = CGFloat(now - start)
        for i in particles.indices {
            var p = particles[i]
            // The pointer pushes the particles near it away.
            if let pos = position, strength > 0.01 {
                let dx = p.x - pos.x, dy = p.y - pos.y
                let d = max(1, hypot(dx, dy))
                if d < 120 {
                    let push = pow(1 - d / 120, 2) * 220 * strength * p.depth
                    p.px += dx / d * push * dt
                    p.py += dy / d * push * dt
                }
            }
            p.px *= max(0, 1 - dt * 2.2)
            p.py *= max(0, 1 - dt * 2.2)
            p.x += (p.vx + sin(t * 0.7 + p.phase) * 5 * p.depth) * dt + p.px * dt * 6
            p.y += p.vy * dt + p.py * dt * 6
            // Out of the band: back in on the other side.
            if p.y < -6 { p.y = size.height + 6; p.x = CGFloat.random(in: 0...max(1, size.width)) }
            if p.y > size.height + 8 { p.y = -4 }
            if p.x < -8 { p.x = size.width + 6 }
            if p.x > size.width + 8 { p.x = -6 }
            particles[i] = p
        }
    }

    private func reset(_ size: CGSize) {
        self.size = size
        let count = Int(min(110, max(18, size.width * size.height / 3600)))
        particles = (0..<count).map { _ in
            let depth = CGFloat.random(in: 0.4...1)
            return Particle(x: .random(in: 0...max(1, size.width)), y: .random(in: 0...max(1, size.height)),
                            vx: CGFloat.random(in: -3...3) * depth, vy: CGFloat.random(in: -13 ... -3) * depth,
                            radius: .random(in: 0.5...1.5) * (0.6 + depth * 0.7),
                            phase: .random(in: 0...(2 * .pi)), depth: depth, white: Int.random(in: 0..<9) == 0)
        }
    }
}

/// A band's background: an ultra deep black, the page's colour as a glow that breathes in a
/// corner, and particles drifting up all the time, pushed away by the pointer and brighter near it.
struct HubHeroBackdrop: View {
    let color: Color
    let light: HubHeroLight
    var cornerRadius: CGFloat = 18
    @Environment(\.hubVisible) private var visible

    var body: some View {
        TimelineView(.animation(paused: !visible)) { timeline in
            let frame = timeline.date
            Canvas { context, size in
                _ = frame
                light.step(size: size)
                let rect = CGRect(origin: .zero, size: size)
                let t = CGFloat(CACurrentMediaTime() - light.start)

                // The black, deeper than the card around it.
                context.fill(Path(rect), with: .color(Color(hex: "#020203")))
                // The page's colour, low in the opposite corner and breathing in the top one.
                context.fill(Path(rect), with: .linearGradient(
                    Gradient(colors: [color.opacity(0.10), .clear]),
                    startPoint: CGPoint(x: size.width, y: 0), endPoint: CGPoint(x: size.width * 0.35, y: size.height)))
                let breath = 0.85 + 0.15 * sin(t * 0.9)
                context.fill(Path(rect), with: .radialGradient(
                    Gradient(colors: [color.opacity(0.30 * breath), color.opacity(0.08), .clear]),
                    center: CGPoint(x: size.width * 0.92, y: -size.height * 0.15),
                    startRadius: 0, endRadius: max(size.width, size.height) * 0.55 * breath))

                // The particles.
                for p in light.particles {
                    var alpha = (0.22 + 0.5 * (0.5 + 0.5 * sin(t * (1.2 + p.depth) + p.phase))) * p.depth
                    var radius = p.radius
                    if let pos = light.position, light.strength > 0.01 {
                        let d = hypot(p.x - pos.x, p.y - pos.y)
                        if d < 200 {
                            let near = (1 - d / 200) * light.strength
                            alpha += near * 0.6
                            radius *= 1 + near * 0.8
                        }
                    }
                    let tint = p.white ? Color.white : color
                    let dot = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
                    if radius > 1.1 {
                        // A soft halo around the bigger ones.
                        context.fill(Path(ellipseIn: dot.insetBy(dx: -radius * 1.6, dy: -radius * 1.6)),
                                     with: .color(tint.opacity(min(1, alpha) * 0.12)))
                    }
                    context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(min(1, alpha))))
                }
            }
        }
    }
}

/// A card in a colour (the Notetaker's, a setup to do): the bands' deep black, their particles
/// and their light following the pointer.
struct HubGlowCard<Content: View>: View {
    let color: Color
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content
    @StateObject private var light = HubHeroLight()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HubHeroBackdrop(color: color, light: light, cornerRadius: 14).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(color.opacity(0.18)))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): light.target = point
                case .ended:             light.target = nil
                }
            }
    }
}

/// An empty page: a Mochi asleep, and a line.
struct HubEmptyState: View {
    let text: String
    var state: BotState = .sleeping
    var color = "#F5F6F8"

    var body: some View {
        VStack(spacing: 10) {
            HubLiveMochi(color: color, size: 54, state: state)
                .frame(height: 54)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundColor(HubTheme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
}
#endif
