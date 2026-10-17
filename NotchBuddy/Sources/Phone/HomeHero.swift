import QuartzCore
import SwiftUI

// The top of the Agents tab: the Mac hub's bands on the iPhone. A deep black card with a glow
// in the colour of what matters most right now, particles drifting up (the finger pushes them),
// the big Mochi of the most urgent session, and the little Mochi of every session and service
// walking on the floor. When a service or a session has news (a payment, a deploy, a finished
// turn), its Mochi jumps and a notification drops in at the top of the card.

// MARK: - Particles and glow

/// The particles of the card and the finger's light, moved frame by frame without redrawing
/// the page (the Mac's HubHeroLight, with a finger instead of a pointer).
@MainActor
final class HeroLight {
    struct Particle {
        var x: CGFloat, y: CGFloat
        var vx: CGFloat, vy: CGFloat
        var px: CGFloat = 0, py: CGFloat = 0
        var radius: CGFloat
        var phase: CGFloat
        /// 0.4 (far, slow, dim) to 1 (near, fast, bright).
        var depth: CGFloat
        var white: Bool
    }

    /// The finger on the card, nil when it is lifted.
    var target: CGPoint?
    private(set) var position: CGPoint?
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
            if let pos = position, strength > 0.01 {
                let dx = p.x - pos.x, dy = p.y - pos.y
                let d = max(1, hypot(dx, dy))
                if d < 110 {
                    let push = pow(1 - d / 110, 2) * 240 * strength * p.depth
                    p.px += dx / d * push * dt
                    p.py += dy / d * push * dt
                }
            }
            p.px *= max(0, 1 - dt * 2.2)
            p.py *= max(0, 1 - dt * 2.2)
            p.x += (p.vx + sin(t * 0.7 + p.phase) * 5 * p.depth) * dt + p.px * dt * 6
            p.y += p.vy * dt + p.py * dt * 6
            if p.y < -6 { p.y = size.height + 6; p.x = CGFloat.random(in: 0...max(1, size.width)) }
            if p.y > size.height + 8 { p.y = -4 }
            if p.x < -8 { p.x = size.width + 6 }
            if p.x > size.width + 8 { p.x = -6 }
            particles[i] = p
        }
    }

    private func reset(_ size: CGSize) {
        self.size = size
        let count = Int(min(90, max(18, size.width * size.height / 1400)))
        particles = (0..<count).map { _ in
            let depth = CGFloat.random(in: 0.4...1)
            return Particle(x: .random(in: 0...max(1, size.width)), y: .random(in: 0...max(1, size.height)),
                            vx: CGFloat.random(in: -3...3) * depth, vy: CGFloat.random(in: -13 ... -3) * depth,
                            radius: .random(in: 0.5...1.5) * (0.6 + depth * 0.7),
                            phase: .random(in: 0...(2 * .pi)), depth: depth, white: Int.random(in: 0..<9) == 0)
        }
    }

    /// The black, the breathing glow and the particles.
    func draw(_ context: inout GraphicsContext, size: CGSize, color: Color) {
        let rect = CGRect(origin: .zero, size: size)
        let t = CGFloat(CACurrentMediaTime() - start)
        context.fill(Path(rect), with: .color(Color(hex: "#020203")))
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [color.opacity(0.12), .clear]),
            startPoint: CGPoint(x: size.width, y: 0), endPoint: CGPoint(x: size.width * 0.3, y: size.height)))
        let breath = 0.85 + 0.15 * sin(t * 0.9)
        context.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [color.opacity(0.34 * breath), color.opacity(0.09), .clear]),
            center: CGPoint(x: size.width * 0.9, y: -size.height * 0.12),
            startRadius: 0, endRadius: max(size.width, size.height) * 0.62 * breath))
        // A warm floor under the Mochi.
        context.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [.clear, color.opacity(0.07)]),
            startPoint: CGPoint(x: 0, y: size.height * 0.55), endPoint: CGPoint(x: 0, y: size.height)))

        for p in particles {
            var alpha = (0.22 + 0.5 * (0.5 + 0.5 * sin(t * (1.2 + p.depth) + p.phase))) * p.depth
            var radius = p.radius
            if let pos = position, strength > 0.01 {
                let d = hypot(p.x - pos.x, p.y - pos.y)
                if d < 180 {
                    let near = (1 - d / 180) * strength
                    alpha += near * 0.6
                    radius *= 1 + near * 0.8
                }
            }
            let tint = p.white ? Color.white : color
            let dot = CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)
            if radius > 1.1 {
                context.fill(Path(ellipseIn: dot.insetBy(dx: -radius * 1.6, dy: -radius * 1.6)),
                             with: .color(tint.opacity(min(1, alpha) * 0.12)))
            }
            context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(min(1, alpha))))
        }
    }
}

// MARK: - The little Mochi on the floor

/// One little Mochi of the card: a session or a service.
struct HeroCast: Equatable {
    var id: String
    var color: String
    var state: BotState
}

/// The little Mochi, walking left and right, resting, saying hello, and jumping when theirs
/// has news.
@MainActor
final class HeroTroupe {
    @MainActor final class Walker {
        let id: String
        let engine = BotEngine()
        let size: CGFloat
        var color: String
        var state: BotState
        var x: CGFloat
        var target: CGFloat
        var speed: CGFloat = 0.06
        var restUntil: Double
        /// The bob of the walk.
        var hop: CGFloat = 0
        /// A jump, when its service or session has news.
        var jumpAt: Double = -10
        var jumpHeight: CGFloat = 0
        var lastHello: Double = 0

        init(cast: HeroCast, size: CGFloat, x: CGFloat) {
            id = cast.id
            self.size = size
            color = cast.color
            state = cast.state
            self.x = x
            target = x
            restUntil = CACurrentMediaTime() + Double.random(in: 0.3...2.5)
            engine.isMini = true
            engine.bodyColor = cgColorFromHex(cast.color)
            engine.setState(cast.state, force: true)
        }
    }

    private(set) var walkers: [Walker] = []
    /// Where they walk, from 0 to 1: the right is the big Mochi's.
    var range: ClosedRange<CGFloat> = 0.02...0.66
    private var last = CACurrentMediaTime()

    static let jumpDuration = 0.6

    /// Keeps one walker per cast member: newcomers walk in, the gone leave, the others change
    /// colour and face in place.
    func sync(_ cast: [HeroCast]) {
        walkers.removeAll { walker in !cast.contains { $0.id == walker.id } }
        for (index, member) in cast.enumerated() {
            if let walker = walkers.first(where: { $0.id == member.id }) {
                if walker.color != member.color {
                    walker.color = member.color
                    walker.engine.bodyColor = cgColorFromHex(member.color)
                }
                if walker.state != member.state {
                    walker.state = member.state
                    walker.engine.setState(member.state)
                }
            } else {
                // Sizes vary a little, so the troupe doesn't look like a row of clones.
                let sizes: [CGFloat] = [46, 40, 43, 37, 44, 39]
                let size = sizes[index % sizes.count]
                let spread = CGFloat(index + 1) / CGFloat(cast.count + 1)
                let x = range.lowerBound + (range.upperBound - range.lowerBound) * spread
                walkers.append(Walker(cast: member, size: size, x: x))
            }
        }
    }

    /// Its service or session has news: it jumps, with a face that says how it went.
    func react(_ id: String, emote: BotEmote?) {
        guard let walker = walkers.first(where: { $0.id == id }) else { return }
        let now = CACurrentMediaTime()
        walker.jumpAt = now
        walker.jumpHeight = walker.size * 0.55
        walker.restUntil = now + Self.jumpDuration + 0.8
        walker.engine.squash()
        if let emote { walker.engine.triggerEmote(emote, silent: true) }
    }

    func step() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0, now - last)))
        last = now
        for actor in walkers {
            actor.engine.update(dt: 0.05)
            if now - actor.jumpAt < Self.jumpDuration { continue }
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
        actor.speed = CGFloat.random(in: 0.04...0.09)
        switch Int.random(in: 0..<10) {
        case 0, 1: actor.engine.triggerEmote(.happy, silent: true)
        case 2:    actor.engine.triggerEmote(.wink, silent: true)
        case 3:    actor.engine.doRoll(duration: 900, turns: 1)
        default:   break
        }
        for other in walkers where other !== actor && abs(other.x - actor.x) < 0.1 && now - actor.lastHello > 12 {
            actor.lastHello = now
            other.lastHello = now
            actor.engine.triggerEmote(.love, silent: true)
            other.engine.triggerEmote(.happy, silent: true)
            break
        }
    }

    /// A tap on a little Mochi: it blushes and jumps. Returns its id.
    @discardableResult
    func poke(at point: CGPoint, in size: CGSize) -> String? {
        let hit = walkers.min { distance(point, $0, size) < distance(point, $1, size) }
        guard let hit, distance(point, hit, size) < hit.size * 0.7 else { return nil }
        react(hit.id, emote: .love)
        return hit.id
    }

    private func distance(_ p: CGPoint, _ actor: Walker, _ size: CGSize) -> CGFloat {
        let center = CGPoint(x: xPosition(actor, width: size.width), y: size.height - actor.size * 0.5)
        return hypot(p.x - center.x, p.y - center.y)
    }

    private func xPosition(_ actor: Walker, width: CGFloat) -> CGFloat {
        actor.size / 2 + actor.x * max(0, width - actor.size)
    }

    /// Draws them standing on the bottom of `size`, the small ones behind.
    func draw(_ context: inout GraphicsContext, size: CGSize, floor: CGFloat) {
        let now = CACurrentMediaTime()
        for actor in walkers.sorted(by: { $0.size < $1.size }) {
            let w = actor.size
            let cx = xPosition(actor, width: size.width)
            var lift = abs(sin(actor.hop)) * w * 0.07
            let since = now - actor.jumpAt
            if since < Self.jumpDuration {
                lift += sin(.pi * CGFloat(since / Self.jumpDuration)) * actor.jumpHeight
            }
            let shadow = CGRect(x: cx - w * 0.26, y: floor - w * 0.12, width: w * 0.52, height: w * 0.09)
            context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(max(0.08, 0.32 - Double(lift / w) * 0.5))))
            var c = context
            c.translateBy(x: cx - w / 2, y: floor - w * 0.92 - lift)
            actor.engine.draw(context: c, size: CGSize(width: w, height: w))
        }
    }
}

// MARK: - The notifications of the card

/// News from a service or a session, dropping in at the top of the card for a few seconds.
struct HeroToast: Identifiable, Equatable {
    let id = UUID()
    var pillId: String
    var name: String
    var color: String
    var text: String
    var tone: Color
    var state: BotState
}

private struct HeroToastView: View {
    let toast: HeroToast

    var body: some View {
        HStack(spacing: 10) {
            MochiStill(state: toast.state, bodyHex: toast.color, showBadge: false)
                .padding(3)
                .frame(width: 30, height: 30)
                .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: toast.color).opacity(0.4), lineWidth: 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(toast.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle().fill(toast.tone).frame(width: 8, height: 8)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - The card

struct HomeHero: View {
    let link: PhoneLink
    let headline: String
    let detail: String?

    @State private var light = HeroLight()
    @State private var troupe = HeroTroupe()
    @State private var toasts: [HeroToast] = []
    @State private var visible = false
    /// What each session and service looked like last time, to tell news from a refresh.
    @State private var seen: [String: String] = [:]
    @State private var primed = false
    @State private var toastBump = 0
    @Environment(\.scenePhase) private var scenePhase

    private var sessions: [SessionItem] { link.sessions }
    private var lead: SessionItem? { sessions.sortedByUrgency().first }

    /// The colour of what matters most right now.
    private var mood: Color {
        switch sessions.leadState {
        case .approval, .question: Color(hex: "#F7B32B")
        case .error, .ratelimit, .dizzy: Color(hex: "#F4505E")
        case .finished: Color(hex: "#34D399")
        case .sleeping: Color(hex: "#7C8AFF")
        default: Color(hex: "#FB923C")
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        case 18..<23: "Good evening"
        default: "Up late"
        }
    }

    /// The little Mochi: every session but the lead (he is the big one), then every connected
    /// service. Two strollers keep the card alive when there is nothing else.
    private var cast: [HeroCast] {
        var out: [HeroCast] = sessions.sortedByUrgency().dropFirst().map {
            HeroCast(id: $0.id, color: $0.color.isEmpty ? "#F5F6F8" : $0.color, state: $0.state)
        }
        for id in PillCatalog.phoneServices {
            guard let snapshot = link.services[id] else { continue }
            out.append(HeroCast(id: id, color: snapshot.color,
                                state: snapshot.tone == .ok ? .idle : snapshot.tone.botState))
        }
        if out.isEmpty {
            out = [HeroCast(id: "stroller-orange", color: "#FB923C", state: .idle),
                   HeroCast(id: "stroller-pink", color: "#F472B6", state: .idle)]
        }
        return Array(out.prefix(6))
    }

    /// Changes whenever a session or a service changes in a way worth showing.
    private var signature: [String: String] {
        var out: [String: String] = [:]
        for session in sessions {
            out[session.id] = "\(session.state.rawValue)|\(session.isWaitingForYou)"
        }
        for (id, snapshot) in link.services {
            out[id] = "\(snapshot.tone.rawValue)|\(snapshot.headline)|\(snapshot.sections.first?.items.first?.title ?? "")"
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 0.9 / 60, paused: !visible || scenePhase != .active)) { timeline in
                    Canvas { context, canvasSize in
                        _ = timeline.date
                        light.step(size: canvasSize)
                        light.draw(&context, size: canvasSize, color: mood)
                        troupe.step()
                        troupe.draw(&context, size: canvasSize, floor: canvasSize.height - 10)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { light.target = $0.location }
                        .onEnded { value in
                            light.target = nil
                            if hypot(value.translation.width, value.translation.height) < 8,
                               troupe.poke(at: value.location, in: size) != nil {
                                Haptics.impact()
                            }
                        }
                )

                // The big Mochi of the most urgent session, where the opening's Mochi lands.
                MochiLive(state: sessions.leadState, fps: 60)
                    .frame(width: 92, height: 92)
                    .introLanding(.header)
                    .allowsHitTesting(false)
                    .position(x: size.width - 66, y: size.height - 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(mood.opacity(0.95))
                    Text(headline)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.interpolate)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                            .contentTransition(.interpolate)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.trailing, 20)
                .allowsHitTesting(false)

                // News, dropping in from the top.
                VStack(spacing: 6) {
                    ForEach(toasts) { toast in
                        Button {
                            link.openPillId = toast.pillId
                        } label: {
                            HeroToastView(toast: toast)
                        }
                        .buttonStyle(.plain)
                        .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(height: 236)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(mood.opacity(0.22), lineWidth: 1))
        .animation(.spring(duration: 0.55, bounce: 0.35), value: toasts)
        .animation(.easeInOut(duration: 0.6), value: sessions.leadState)
        .sensoryFeedback(.impact(weight: .light), trigger: toastBump)
        .onAppear {
            visible = true
            troupe.sync(cast)
            notice(signature)
        }
        .onDisappear { visible = false }
        .onChange(of: cast) { _, new in troupe.sync(new) }
        .onChange(of: signature) { _, new in notice(new) }
        .accessibilityElement(children: .combine)
    }

    // MARK: News

    /// Compares with what was seen: a changed service or session gets a jump and a notification.
    /// What is already there at launch (or before the first sync) only gets remembered.
    private func notice(_ now: [String: String]) {
        defer { seen = now }
        guard link.firstSyncDone else { return }
        guard primed else {
            primed = true
            return
        }
        for (id, value) in now where seen[id] != value {
            if let snapshot = link.services[id] {
                announce(service: snapshot, isNew: seen[id] == nil)
            } else if let session = sessions.first(where: { $0.id == id }) {
                announce(session: session)
            }
        }
    }

    private func announce(service snapshot: ServiceSnapshot, isNew: Bool) {
        let latest = snapshot.sections.first?.items.first
        let text = latest.map { $0.detail.isEmpty ? $0.title : "\($0.title) · \($0.detail)" } ?? snapshot.headline
        let emote: BotEmote? = switch snapshot.tone {
        case .ok: .happy
        case .error: .surprised
        case .warning: .surprised
        case .info: .proud
        case .idle: nil
        }
        troupe.react(snapshot.pillId, emote: emote)
        push(HeroToast(pillId: snapshot.pillId, name: snapshot.name, color: snapshot.color,
                       text: text.isEmpty ? snapshot.tone.label : text,
                       tone: snapshot.tone.color, state: snapshot.tone == .ok ? .finished : snapshot.tone.botState))
    }

    private func announce(session: SessionItem) {
        let text: String
        let emote: BotEmote?
        switch session.state {
        case .finished:
            text = session.finalLine.isEmpty ? "Finished" : session.finalLine
            emote = .proud
        case .error:
            text = "Stopped on an error"
            emote = .surprised
        default:
            guard session.isWaitingForYou else {
                troupe.react(session.id, emote: nil)
                return
            }
            text = session.needsApproval ? "Waiting for your OK" : "Has a question for you"
            emote = .surprised
        }
        troupe.react(session.id, emote: emote)
        push(HeroToast(pillId: session.id, name: session.title, color: session.color.isEmpty ? "#F5F6F8" : session.color,
                       text: text, tone: session.statusColor, state: session.state))
    }

    private func push(_ toast: HeroToast) {
        toasts.removeAll { $0.pillId == toast.pillId }
        toasts.insert(toast, at: 0)
        if toasts.count > 2 { toasts.removeLast(toasts.count - 2) }
        toastBump += 1
        let id = toast.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.5))
            toasts.removeAll { $0.id == id }
        }
    }
}
