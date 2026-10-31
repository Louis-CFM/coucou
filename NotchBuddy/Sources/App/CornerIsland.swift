import SwiftUI

// The island open in a corner of the screen (IslandPlacement): Mochi sits in the island's
// corner, the other pills' Mochis on a quarter circle around him, and the focused pill's card
// fills the rest. A tap on one of them swaps it with Mochi: it flies to the corner and becomes
// the one in focus, and the one that was in focus takes its place on the circle.

struct CornerArcView: View {
    @ObservedObject var state: AppState
    let islandW: CGFloat
    let islandH: CGFloat

    /// The circle's order, kept across swaps (the one leaving the corner takes the place of the
    /// one arriving), new pills added at the end.
    @State private var order: [String] = []
    /// Two Mochis swapping places: the one arriving in the corner and the one leaving it.
    @State private var swap: Swap? = nil
    @State private var swapStart = Date.distantPast
    /// Circles drawn out (ring off): the one a Mochi left, the one a Mochi just reached.
    @State private var ringOff: Set<String> = []
    /// Tapped, its circle drawing itself out before the flight.
    @State private var pendingTap: String? = nil

    private struct Swap: Equatable {
        let incoming: AgentTask
        let outgoing: AgentTask
        let slot: Int
        let order: [String]
        static func == (a: Swap, b: Swap) -> Bool { a.incoming.id == b.incoming.id && a.slot == b.slot }
    }

    /// Room for five around Mochi; the others are a tap on the circle away once one leaves it.
    static let maxShown = 5
    /// Mochi's size in the corner, and on the circle (the swap grows one and shrinks the other).
    static let bigBody: CGFloat = 58
    static let smallBody: CGFloat = 24
    static let swapDuration: Double = 0.5
    /// The tapped one's circle draws itself out first, this long, then the two fly.
    static let ringOutDuration: Double = 0.24

    private var arcTasks: [AgentTask] {
        let focus = state.focusTask?.id
        let others = state.tasks.filter { $0.id != focus }
        let known = order.compactMap { id in others.first { $0.id == id } }
        let rest = others.filter { t in !order.contains(t.id) }
        return Array((known + rest).prefix(Self.maxShown))
    }

    var body: some View {
        let placement = state.islandPlacement
        let size = CGSize(width: islandW, height: islandH)
        let tasks = arcTasks
        let points = placement.arcPoints(count: tasks.count, in: size)
        let home = placement.cornerBotCenter(in: size)

        ZStack(alignment: .topLeading) {
            // A faint quarter of the circle the Mochis sit on.
            Path { p in
                let pts = placement.arcPoints(count: 9, in: size)
                guard let first = pts.first else { return }
                p.move(to: first)
                for q in pts.dropFirst() { p.addLine(to: q) }
            }
            .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 5]))
            .allowsHitTesting(false)

            ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                let leaving = swap?.incoming.id == task.id
                // Its circle draws itself out, then its Mochi flies to the corner (drawn below).
                CornerMini(task: task, ring: ringOff.contains(task.id) ? 0 : 1, showBot: !leaving) {
                    start(task, at: i, current: tasks)
                }
                .position(i < points.count ? points[i] : home)
            }

            // The swap: each one on its own curve, crossing the other halfway.
            if let s = swap, s.slot < points.count {
                let slot = points[s.slot]
                let small = Self.smallBody / Self.bigBody
                TimelineView(.animation) { tl in
                    let t = CornerCurve.ease(tl.date.timeIntervalSince(swapStart) / Self.swapDuration)
                    ZStack(alignment: .topLeading) {
                        MiniBotCanvasView(task: s.outgoing)
                            .frame(width: Self.bigBody / 0.6, height: Self.bigBody / 0.6)
                            .scaleEffect(1 + (small - 1) * t)
                            .position(CornerCurve.point(t, from: home, to: slot, bulge: 46))
                        MiniBotCanvasView(task: s.incoming)
                            .frame(width: Self.bigBody / 0.6, height: Self.bigBody / 0.6)
                            .scaleEffect(small + (1 - small) * t)
                            .position(CornerCurve.point(t, from: slot, to: home, bulge: 46))
                    }
                    .frame(width: islandW, height: islandH, alignment: .topLeading)
                }
                .allowsHitTesting(false)
            }
        }
        .frame(width: islandW, height: islandH, alignment: .topLeading)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: tasks.map(\.id))
        .onAppear { swapPending(after: 0.42) }
        .onChange(of: state.cornerPendingSwap) { _, _ in swapPending(after: 0.1) }
        .onDisappear {
            pendingTap = nil
            if swap != nil { finish() }
        }
    }

    /// A pill clicked in the compact tile's row: the island has opened, now it swaps with Mochi.
    private func swapPending(after delay: Double) {
        guard let id = state.cornerPendingSwap else { return }
        state.cornerPendingSwap = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let tasks = arcTasks
            guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
            start(tasks[i], at: i, current: tasks)
        }
    }

    private func start(_ task: AgentTask, at index: Int, current: [AgentTask]) {
        guard swap == nil, pendingTap == nil, let focus = state.focusTask else { return }
        var ids = current.map(\.id)
        if index < ids.count { ids[index] = focus.id }
        // First its circle and its name go (from the top down both sides)…
        pendingTap = task.id
        withAnimation(.easeInOut(duration: Self.ringOutDuration)) { _ = ringOff.insert(task.id) }
        SoundEngine.shared.play("blip")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ringOutDuration) {
            guard pendingTap == task.id else { return }
            pendingTap = nil
            // …then both fly, crossing.
            swapStart = Date()
            swap = Swap(incoming: task, outgoing: focus, slot: index, order: ids)
            state.cornerSwapping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.swapDuration) { finish() }
        }
    }

    /// Both have arrived: the one in the corner is now the focus, the other is on the circle.
    private func finish() {
        guard let s = swap else { return }
        var tr = Transaction()
        tr.disablesAnimations = true
        withTransaction(tr) {
            order = s.order
            state.setFocus(s.incoming.id)
            state.cornerSwapping = false
            swap = nil
            ringOff.remove(s.incoming.id)
            ringOff.insert(s.outgoing.id)
        }
        // The one that left the corner has reached its place: its circle draws itself in.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.35)) { _ = ringOff.remove(s.outgoing.id) }
        }
    }
}

/// The swap's path: a quadratic curve from `from` to `to`, bowed `bulge` points to the side.
/// Two of them with the same bulge, in opposite directions, cross halfway.
enum CornerCurve {
    static func point(_ t: CGFloat, from: CGPoint, to: CGPoint, bulge: CGFloat) -> CGPoint {
        let dx = to.x - from.x, dy = to.y - from.y
        let len = max(1, hypot(dx, dy))
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let ctrl = CGPoint(x: mid.x - dy / len * bulge, y: mid.y + dx / len * bulge)
        let u = 1 - t
        return CGPoint(x: u * u * from.x + 2 * u * t * ctrl.x + t * t * to.x,
                       y: u * u * from.y + 2 * u * t * ctrl.y + t * t * to.y)
    }

    /// Slow out of the start, softly into the end.
    static func ease(_ x: Double) -> CGFloat {
        let t = min(1, max(0, x))
        return CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
    }
}

/// One pill's Mochi on the circle: a round button in its colour, its name under it. Its circle
/// draws itself in and out from the top, down both sides at once (`ring`, 0 to 1).
private struct CornerMini: View {
    let task: AgentTask
    let ring: CGFloat
    let showBot: Bool
    let onTap: () -> Void
    @State private var hover = false

    private var name: String {
        task.id == "integration_claude" ? ClaudeHost.pillName(hostApp: task.hostApp) : task.name
    }

    var body: some View {
        let color = Color(hex: task.color)
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(hover ? color.opacity(0.18) : Color(hex: "#0E0F11"))
                        .opacity(ring)
                    // Drawn in from the top, drawn out towards the bottom; whole, a plain circle.
                    RingShape(progress: ring, fromBottom: ring < 0.5)
                        .stroke(color.opacity(hover ? 0.6 : 0.3), lineWidth: 1.2)
                    MiniBotCanvasView(task: task)
                        .frame(width: CornerArcView.smallBody / 0.6, height: CornerArcView.smallBody / 0.6)
                        .frame(width: CornerArcView.smallBody, height: CornerArcView.smallBody)
                        .opacity(showBot ? 1 : 0)
                }
                .frame(width: 40, height: 40)
                .shadow(color: color.opacity(hover ? 0.35 : 0), radius: 10)

                if let badge = task.pillBadge {
                    PillBadgeView(badge: badge, taskColor: task.color)
                        .offset(x: 2, y: -2)
                        .opacity(ring)
                }
            }
            .overlay(alignment: .bottom) {
                Text(verbatim: name)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(hover ? color.lighter(by: 0.3) : Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(y: 15 - 5 * (1 - ring))
                    .opacity(ring)
                    .blur(radius: 2 * (1 - ring))
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.1 : 1)
        .onHover { h in withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { hover = h } }
        .help(name)
    }
}

/// The circle around a Mochi on the arc, drawn in part: an arc spread evenly on both sides of
/// its top (`fromBottom` false: drawing itself in, down both sides) or of its bottom (true: the
/// gap opens at the top and runs down both sides as it goes). Whole, a plain circle: no seam.
private struct RingShape: Shape {
    var progress: CGFloat
    let fromBottom: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        if progress >= 0.999 {
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        } else if progress > 0.001 {
            let mid: Double = fromBottom ? 90 : -90
            let half = 180 * Double(progress)
            p.addArc(center: c, radius: r, startAngle: .degrees(mid - half), endAngle: .degrees(mid + half),
                     clockwise: false)
        }
        return p
    }
}

/// Compact in a corner, the pointer on the tile: the other pills come out of it one after the
/// other, each small tile born from the one before, along the screen's edge. A click opens
/// the island on that pill.
struct CornerBubbles: View {
    @ObservedObject var state: AppState
    @State private var shown = 0

    static let maxShown = 4

    static func tasks(_ state: AppState) -> [AgentTask] {
        let focus = state.focusTask?.id
        return Array(state.tasks.filter { $0.id != focus }.prefix(maxShown))
    }

    static func count(_ state: AppState) -> Int { tasks(state).count }

    var body: some View {
        let placement = state.islandPlacement
        let tasks = Self.tasks(state)
        let centers = placement.bubbleCenters(count: tasks.count)
        let t = IslandPlacement.tile
        ZStack(alignment: .topLeading) {
            ForEach(Array(tasks.enumerated()), id: \.element.id) { i, task in
                let out = i < shown
                let from = i == 0 ? CGPoint(x: t / 2, y: t / 2) : centers[i - 1]
                // The click opens the island; there it swaps places with Mochi.
                CornerBubble(task: task) { state.cornerPendingSwap = task.id }
                    .scaleEffect(out ? 1 : 0.3)
                    .opacity(out ? 1 : 0)
                    .position(out ? centers[i] : from)
            }
        }
        .frame(width: t, height: t, alignment: .topLeading)
        .onAppear {
            for i in 0..<tasks.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06 * Double(i)) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { shown = max(shown, i + 1) }
                }
            }
        }
    }
}

/// One of them: a small black tile with rounded corners, the pill's mini Mochi inside.
private struct CornerBubble: View {
    let task: AgentTask
    let onTap: () -> Void
    @State private var hover = false

    private var name: String {
        task.id == "integration_claude" ? ClaudeHost.pillName(hostApp: task.hostApp) : task.name
    }

    var body: some View {
        let color = Color(hex: task.color)
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(color.opacity(hover ? 0.6 : 0.25), lineWidth: 1)
                    MiniBotCanvasView(task: task)
                        .frame(width: 22 / 0.6, height: 22 / 0.6)
                        .frame(width: 22, height: 22)
                }
                .frame(width: IslandPlacement.bubble, height: IslandPlacement.bubble)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)

                if let badge = task.pillBadge {
                    PillBadgeView(badge: badge, taskColor: task.color)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.08 : 1)
        .onHover { h in withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { hover = h } }
        .help(name)
    }
}

/// While Mochi is dragged near a corner (or back to the top centre): the place he will take,
/// shown before he is let go.
struct SnapTargetView: View {
    let corner: Bool
    @State private var shown = false

    var body: some View {
        RoundedRectangle(cornerRadius: corner ? 18 : 17, style: .continuous)
            .fill(Color.black.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: corner ? 18 : 17, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )
            .scaleEffect(shown ? 1 : 0.7)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { shown = true } }
    }
}
