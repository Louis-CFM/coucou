#if !APPSTORE
import AppKit
import SwiftUI

/// Coucou window → Mochi's room: Mochi and your agents in a little room where every object is
/// live data. Mochi naps on the bed when nothing runs, works at the desk while an agent does,
/// and waits at the door when one asks something; the window is your CI and deploys, the frames
/// are your connected tools, the clock is the time coded today and the plant is your streak.
/// It only reads what Coucou already has. Off by default; off, it draws nothing.
struct HubRoomPage: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var state = AppState.shared
    @AppStorage(MochiRoom.enabledKey) private var enabled = false
    @AppStorage(MochiRoom.doorKey) private var useDoor = true
    @AppStorage(MochiRoom.weatherKey) private var showWeather = true
    @AppStorage(MochiRoom.dayNightKey) private var dayNight = true
    @AppStorage(MochiRoom.hiddenToolsKey) private var hiddenRaw = ""
    @State private var connected: Set<String> = []
    @State private var today = RoomToday()
    @State private var now = Date()

    var body: some View {
        HubPageScaffold(title: String(localized: "room.title"), subtitle: String(localized: "room.subtitle")) {
            if enabled {
                Toggle(String(localized: "room.enabled"), isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(String(localized: "room.enabled"))
            }
        } content: {
            if enabled {
                room
            } else {
                intro
            }
            settings
        }
        // Read on arrival, then once a minute while the page shows (the clock, the streak).
        .task(id: enabled) {
            refresh()
            while enabled, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { refresh() }
            }
        }
    }

    // MARK: - The room

    @ViewBuilder private var room: some View {
        let waiting = state.pendingApproval != nil || state.pendingQuestion != nil
        let busy = state.tasks.contains { Self.busyStates.contains($0.state) }
        let spot = MochiRoom.spot(waiting: waiting, busy: busy, useDoor: useDoor)
        RoomScene(spot: spot,
                  mochiState: mochiState(spot: spot),
                  weather: showWeather ? weather : .clear,
                  night: dayNight && MochiRoom.isNight(hour: Calendar.current.component(.hour, from: now)),
                  frames: frames,
                  coded: today.minutes,
                  streak: today.streak,
                  minis: minis,
                  doorLit: waiting)
            .frame(height: RoomScene.height)

        if useDoor, let approval = state.pendingApproval {
            RoomDoorCard(approval: approval)
        } else if useDoor, state.pendingQuestion != nil {
            RoomQuestionCard(asker: state.focusTask?.name ?? "Claude Code")
        }

        HStack(spacing: 14) {
            RoomStat(label: String(localized: "room.stat.coded"), value: Self.duration(today.minutes), note: nil)
            RoomStat(label: String(localized: "room.stat.approvals"), value: "\(today.allowed)",
                     note: String(format: String(localized: "room.stat.denied %lld"), Int64(today.denied)))
            RoomStat(label: String(localized: "room.stat.deploys"), value: deploysToday, note: nil)
            RoomStat(label: String(localized: "room.stat.streak"), value: "\(today.streak)",
                     note: String(localized: "room.stat.streak-note"))
        }
    }

    private static let busyStates: Set<BotState> = [.working, .thinking, .searching]

    /// The face Mochi makes where he stands.
    private func mochiState(spot: MochiRoom.Spot) -> BotState {
        switch spot {
        case .door: return state.pendingApproval != nil ? .approval : .question
        case .bed:  return .sleeping
        case .desk:
            let shown = state.focusTask?.state ?? .working
            return Self.busyStates.contains(shown) || shown == .approval || shown == .question ? shown : .working
        }
    }

    private var weather: MochiRoom.Weather {
        MochiRoom.weather(ci: state.githubPulse?.mainCI.map(\.ci) ?? [], deploys: deploys.map(\.state))
    }

    /// The Vercel deploys that ran (not cancelled), newest first.
    private var deploys: [VercelDeployment] {
        state.vercelDeployments.filter { $0.state != "CANCELED" }.sorted { $0.createdAt > $1.createdAt }
    }

    /// One little Mochi per agent session and workflow at work, in its pill's colour.
    private var minis: [RoomMini] {
        state.tasks
            .filter { !$0.isIntegration || $0.source == .n8n }
            .prefix(6)
            .map { RoomMini(id: $0.id, name: $0.name, color: $0.color, state: $0.state) }
    }

    private var deploysToday: String {
        let mine = deploys.filter { Calendar.current.isDateInToday($0.createdAt) }
        if mine.isEmpty { return "–" }
        return "\(mine.filter(\.isSuccess).count) / \(mine.count)"
    }

    // MARK: - The frames on the wall

    private var frames: [RoomFrame] {
        let hidden = MochiRoom.hiddenTools(hiddenRaw)
        return RoomTool.all.filter { connected.contains($0.id) && !hidden.contains($0.id) }.map { wallFrame(for: $0) }
    }

    private func wallFrame(for tool: RoomTool) -> RoomFrame {
        switch tool.id {
        case "stripe":
            let cents = MochiRoom.paidToday(state.stripePayments.map { ($0.amount, $0.createdAt, $0.isSuccess) }, today: now)
            let money = (Double(cents) / 100).formatted(.currency(code: state.stripeCurrency.uppercased()).precision(.fractionLength(0)))
            return RoomFrame(tool: tool, value: money, label: String(localized: "room.frame.today"), dot: nil)
        case "github":
            let stars = state.githubStats.map { "★ " + MochiRoom.shortCount($0.totalStars) } ?? "–"
            return RoomFrame(tool: tool, value: stars, label: String(localized: "room.frame.stars"), dot: nil)
        case "vercel":
            // A cancelled deploy says nothing about production: the last one that ran.
            let last = deploys.first
            let dot: Color? = last.map { $0.isSuccess ? HubTheme.green : HubTheme.red }
            let value = last.map { $0.isSuccess ? String(localized: "room.deploy.ready") : String(localized: "room.deploy.failed") } ?? "–"
            return RoomFrame(tool: tool, value: value, label: last?.projectName ?? "Vercel", dot: dot)
        case "n8n":
            let runs = state.n8nRuns.filter { Calendar.current.isDateInToday($0.date) }
            let dot: Color? = state.n8nRuns.max { $0.date < $1.date }.map { $0.success ? HubTheme.green : HubTheme.red }
            return RoomFrame(tool: tool, value: "\(runs.count)", label: String(localized: "room.frame.runs"), dot: dot)
        default: // calcom
            let next = state.calcomBookings
                .filter { $0.isActive && $0.startTime > now && Calendar.current.isDateInToday($0.startTime) }
                .min { $0.startTime < $1.startTime }
            return RoomFrame(tool: tool, value: next?.timeLabel ?? "–", label: String(localized: "room.frame.next-call"), dot: nil)
        }
    }

    // MARK: - Off: what the room is

    private var intro: some View {
        HubCard(padding: 22) {
            Text("room.intro.title").font(.system(size: 17, weight: .bold))
            VStack(alignment: .leading, spacing: 10) {
                RoomIntroLine(symbol: "desktopcomputer", text: String(localized: "room.intro.desk"))
                RoomIntroLine(symbol: "door.left.hand.open", text: String(localized: "room.intro.door"))
                RoomIntroLine(symbol: "cloud.sun", text: String(localized: "room.intro.window"))
                RoomIntroLine(symbol: "photo.on.rectangle", text: String(localized: "room.intro.walls"))
                RoomIntroLine(symbol: "leaf", text: String(localized: "room.intro.plant"))
            }
            Button(String(localized: "room.turn-on")) { enabled = true }
                .buttonStyle(HubButtonStyle(primary: true))
                .padding(.top, 4)
        }
    }

    // MARK: - Settings

    private var settings: some View {
        HStack(alignment: .top, spacing: 14) {
            HubCard(padding: 20) {
                HubLabel(String(localized: "room.settings"))
                HubRow(title: String(localized: "room.enabled"), detail: String(localized: "room.enabled.detail")) {
                    Toggle(String(localized: "room.enabled"), isOn: $enabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "room.setting.door"), detail: String(localized: "room.setting.door.detail")) {
                    Toggle(String(localized: "room.setting.door"), isOn: $useDoor).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "room.setting.weather"), detail: String(localized: "room.setting.weather.detail")) {
                    Toggle(String(localized: "room.setting.weather"), isOn: $showWeather).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "room.setting.day-night"), detail: String(localized: "room.setting.day-night.detail")) {
                    Toggle(String(localized: "room.setting.day-night"), isOn: $dayNight).toggleStyle(.switch).labelsHidden()
                }
            }
            .settingsAnchor("room.settings", cornerRadius: 14)
            .frame(maxWidth: .infinity)

            HubCard(padding: 20) {
                HubLabel(String(localized: "room.tools"))
                ForEach(Array(RoomTool.all.enumerated()), id: \.element.id) { index, tool in
                    if index > 0 { HubDivider() }
                    toolRow(tool)
                }
            }
            .settingsAnchor("room.tools", cornerRadius: 14)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func toolRow(_ tool: RoomTool) -> some View {
        let isConnected = connected.contains(tool.id)
        HStack(spacing: 12) {
            Image(systemName: tool.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: tool.color))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: tool.color).opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: tool.name).font(.system(size: 13.5, weight: .medium))
                Text(isConnected ? String(localized: "room.tool.connected") : String(localized: "room.tool.missing"))
                    .font(.system(size: 12))
                    .foregroundColor(isConnected ? HubTheme.secondary : HubTheme.muted)
            }
            Spacer(minLength: 8)
            if isConnected {
                Toggle(tool.name, isOn: Binding(
                    get: { !MochiRoom.hiddenTools(hiddenRaw).contains(tool.id) },
                    set: { show in
                        var hidden = MochiRoom.hiddenTools(hiddenRaw)
                        if show { hidden.remove(tool.id) } else { hidden.insert(tool.id) }
                        hiddenRaw = MochiRoom.hiddenToolsRaw(hidden)
                    }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            } else {
                Button(String(localized: "room.connect")) { router.page = .integrations }
                    .buttonStyle(HubButtonStyle())
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Data

    private func refresh() {
        now = Date()
        // The Keychain is read here, not at every frame: once on arrival, then each minute.
        connected = Set(RoomTool.all.filter { tool in
            tool.keys.allSatisfy { !(KeychainStore.shared.get($0) ?? "").isEmpty }
        }.map(\.id))
        guard enabled else { return }
        let recap = RecapStore.shared.today(now: now)
        today = RoomToday(minutes: recap.minutes, allowed: recap.allowed, denied: recap.denied,
                          streak: MochiRoom.streak(days: RecapStore.shared.sessionDays(), today: now))
    }

    /// "2 h 14" or "38 min".
    static func duration(_ minutes: Int) -> String {
        let d = MochiRoom.duration(minutes: minutes)
        if d.hours == 0 { return String(format: String(localized: "hub.minutes %lld"), Int64(d.minutes)) }
        return String(format: String(localized: "hub.hours %lld %lld"), Int64(d.hours), Int64(d.minutes))
    }
}

// MARK: - Models

struct RoomToday {
    var minutes = 0
    var allowed = 0
    var denied = 0
    var streak = 0
}

/// A tool that can hang on the wall: connected when its keys are in the Keychain.
struct RoomTool: Identifiable {
    let id: String
    let name: String
    let keys: [String]
    let symbol: String
    let color: String
    /// Opened by a click on its frame.
    let url: String

    static let all: [RoomTool] = [
        RoomTool(id: "stripe", name: "Stripe", keys: ["stripe-api-key"], symbol: "creditcard.fill",
                 color: "#8C73F2", url: "https://dashboard.stripe.com/payments"),
        RoomTool(id: "github", name: "GitHub", keys: ["github-token"], symbol: "star.fill",
                 color: "#E1E3E6", url: "https://github.com"),
        RoomTool(id: "vercel", name: "Vercel", keys: ["vercel-token"], symbol: "triangle.fill",
                 color: "#F5F6F8", url: "https://vercel.com/dashboard"),
        RoomTool(id: "n8n", name: "n8n", keys: ["n8n-url", "n8n-api-key"], symbol: "point.3.connected.trianglepath.dotted",
                 color: "#EA4B71", url: ""),
        RoomTool(id: "calcom", name: "Cal.com", keys: ["calcom-api-key"], symbol: "calendar",
                 color: "#34D399", url: "https://app.cal.com/bookings/upcoming"),
    ]
}

struct RoomFrame: Identifiable {
    let tool: RoomTool
    let value: String
    let label: String
    let dot: Color?
    var id: String { tool.id }
}

struct RoomMini: Equatable {
    let id: String
    let name: String
    let color: String
    let state: BotState
}

// MARK: - The scene

/// The room itself: furniture drawn in SwiftUI, the Mochis in one canvas, at 30 fps while the
/// Coucou window shows and still otherwise.
private struct RoomScene: View {
    static let height: CGFloat = 340
    /// Where the floor starts.
    static let floor: CGFloat = 236

    let spot: MochiRoom.Spot
    let mochiState: BotState
    let weather: MochiRoom.Weather
    let night: Bool
    let frames: [RoomFrame]
    let coded: Int
    let streak: Int
    let minis: [RoomMini]
    let doorLit: Bool

    @StateObject private var cast = RoomCast()
    @Environment(\.hubVisible) private var visible

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let layout = RoomLayout(width: w)
            ZStack(alignment: .topLeading) {
                // Wall and floor
                LinearGradient(colors: night ? [Color(hex: "#0B1230"), Color(hex: "#070B1C")]
                                             : [Color(hex: "#24407F"), Color(hex: "#14214A")],
                               startPoint: .top, endPoint: .bottom)
                LinearGradient(colors: [Color(hex: "#20263A"), Color(hex: "#13172A")], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.height - Self.floor)
                    .offset(y: Self.floor)
                Ellipse()
                    .fill(Color(hex: "#8C73F2").opacity(0.13))
                    .frame(width: w * 0.42, height: 54)
                    .offset(x: w * 0.3, y: Self.floor + 30)

                RoomWindow(weather: weather, night: night)
                    .frame(width: layout.windowWidth, height: 108)
                    .offset(x: layout.windowX, y: 26)

                // Frames: the connected tools
                HStack(spacing: 12) {
                    ForEach(frames) { frame in
                        RoomFrameView(frame: frame)
                    }
                    RoomClock(coded: coded)
                }
                .offset(x: layout.framesX, y: 30)

                RoomBed()
                    .frame(width: 140, height: 44)
                    .offset(x: layout.bedX, y: Self.floor - 44)
                RoomPlant(streak: streak)
                    .offset(x: layout.bedX + 150, y: Self.floor - 72)

                RoomDesk(lit: spot == .desk)
                    .frame(width: 220, height: 120)
                    .offset(x: layout.deskX, y: Self.floor - 120)

                RoomDoor(lit: doorLit)
                    .frame(width: 52, height: 156)
                    .offset(x: layout.doorX, y: Self.floor - 156)

                // The Mochis
                TimelineView(.animation(minimumInterval: MochiFrameClock.interval(fps: MochiFrameClock.miniFPS),
                                        paused: !visible)) { timeline in
                    let frame = timeline.date
                    Canvas { context, size in
                        _ = frame
                        cast.step(spot: spot, state: mochiState, minis: minis, layout: layout)
                        cast.draw(&context, layout: layout)
                    }
                }
                // Clicks go to the frames under it.
                .allowsHitTesting(false)

                // The names under the little Mochis
                ForEach(Array(minis.enumerated()), id: \.element.id) { index, mini in
                    Text(verbatim: mini.name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color(hex: "#C7D0E0"))
                        .lineLimit(1)
                        .frame(width: 96)
                        .position(x: layout.miniX(index, of: minis.count), y: Self.height - 14)
                        .allowsHitTesting(false)
                }

                if night {
                    Color.black.opacity(0.18).allowsHitTesting(false)
                }
            }
            .frame(width: w, height: Self.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(HubTheme.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("room.title"))
    }
}

/// Where things are in a room of a given width.
struct RoomLayout {
    let width: CGFloat

    var windowX: CGFloat { 22 }
    var windowWidth: CGFloat { min(160, width * 0.16) }
    var framesX: CGFloat { windowX + windowWidth + 34 }
    var bedX: CGFloat { 18 }
    var deskX: CGFloat { width * 0.62 - 110 }
    var doorX: CGFloat { width - 84 }

    /// The middle of Mochi's feet at each spot (x), and how high they stand (y).
    func mochi(_ spot: MochiRoom.Spot) -> CGPoint {
        switch spot {
        case .bed:  return CGPoint(x: bedX + 80, y: RoomScene.floor - 34)
        case .desk: return CGPoint(x: deskX + 78, y: RoomScene.floor - 4)
        case .door: return CGPoint(x: doorX - 34, y: RoomScene.floor + 20)
        }
    }

    /// The little Mochis stand in a row at the front.
    func miniX(_ index: Int, of count: Int) -> CGFloat {
        let left = width * 0.24, right = width * 0.84
        guard count > 1 else { return (left + right) / 2 }
        return left + (right - left) * CGFloat(index) / CGFloat(count - 1)
    }
}

/// Mochi and the little Mochis, moved frame by frame.
@MainActor
final class RoomCast: ObservableObject {
    static let mochiSize: CGFloat = 92
    static let miniSize: CGFloat = 46

    let mochi: BotEngine
    private var position: CGPoint?
    private var hop: CGFloat = 0
    private var minis: [String: BotEngine] = [:]
    private var order: [RoomMini] = []
    private var last = CACurrentMediaTime()

    init() {
        mochi = BotEngine()
        mochi.setState(.sleeping, force: true)
    }

    func step(spot: MochiRoom.Spot, state: BotState, minis wanted: [RoomMini], layout: RoomLayout) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.1, max(0, now - last)))
        last = now

        // Mochi walks to his spot (a few hops), then takes its face.
        let target = layout.mochi(spot)
        var here = position ?? target
        let dx = target.x - here.x, dy = target.y - here.y
        let distance = hypot(dx, dy)
        if distance > 1 {
            let move = min(distance, 260 * dt)
            here.x += dx / distance * move
            here.y += dy / distance * move
            hop += dt * 12
            if mochi.state != .idle { mochi.setState(.idle) }
        } else {
            here = target
            hop = 0
            if mochi.state != state { mochi.setState(state) }
        }
        position = here
        MochiFrameClock.advance(mochi, fps: MochiFrameClock.miniFPS)

        // One little Mochi per session: made when it starts, gone when it ends.
        if wanted != order {
            for mini in wanted {
                let engine = minis[mini.id] ?? {
                    let e = BotEngine()
                    e.isMini = true
                    return e
                }()
                engine.bodyColor = cgColorFromHex(mini.color)
                if engine.state != mini.state { engine.setState(mini.state) }
                minis[mini.id] = engine
            }
            let ids = Set(wanted.map(\.id))
            minis = minis.filter { ids.contains($0.key) }
            order = wanted
        }
        for engine in minis.values { MochiFrameClock.advance(engine, fps: MochiFrameClock.miniFPS) }
    }

    func draw(_ context: inout GraphicsContext, layout: RoomLayout) {
        for (index, mini) in order.enumerated() {
            guard let engine = minis[mini.id] else { continue }
            let x = layout.miniX(index, of: order.count)
            Self.drawMochi(engine, at: CGPoint(x: x, y: RoomScene.height - 26), size: Self.miniSize, lift: 0, in: &context)
        }
        if let position {
            let lift = abs(sin(hop)) * Self.mochiSize * 0.06
            Self.drawMochi(mochi, at: position, size: Self.mochiSize, lift: lift, in: &context)
        }
    }

    private static func drawMochi(_ engine: BotEngine, at feet: CGPoint, size w: CGFloat, lift: CGFloat,
                                  in context: inout GraphicsContext) {
        let shadow = CGRect(x: feet.x - w * 0.26, y: feet.y - w * 0.05, width: w * 0.52, height: w * 0.09)
        context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.28)))
        var c = context
        c.translateBy(x: feet.x - w / 2, y: feet.y - w * 0.92 - lift)
        engine.draw(context: c, size: CGSize(width: w, height: w))
    }
}

// MARK: - Furniture

private struct RoomWindow: View {
    let weather: MochiRoom.Weather
    let night: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(sky)
            switch weather {
            case .sun, .clear:
                if night {
                    Circle().fill(Color(hex: "#F5F1DC")).frame(width: 26, height: 26).offset(x: 26, y: -22)
                    ForEach(0..<5, id: \.self) { i in
                        Circle().fill(.white.opacity(0.8)).frame(width: 2.5, height: 2.5)
                            .offset(x: Self.stars[i].x, y: Self.stars[i].y)
                    }
                } else {
                    Circle().fill(Color(hex: "#FFD66B")).frame(width: 30, height: 30)
                        .shadow(color: Color(hex: "#FFD66B"), radius: 12)
                        .offset(x: 26, y: -20)
                }
            case .cloudy:
                cloud.offset(x: 10, y: -10)
            case .rain, .storm:
                cloud.offset(x: 4, y: -18)
                ForEach(0..<7, id: \.self) { i in
                    Capsule().fill(Color(hex: "#9CC3FF").opacity(0.8))
                        .frame(width: 2, height: 10)
                        .rotationEffect(.degrees(14))
                        .offset(x: CGFloat(i) * 12 - 36, y: CGFloat(i % 2) * 8 + 16)
                }
                if weather == .storm {
                    Path { p in
                        p.move(to: CGPoint(x: 8, y: 0)); p.addLine(to: CGPoint(x: 0, y: 16))
                        p.addLine(to: CGPoint(x: 7, y: 16)); p.addLine(to: CGPoint(x: 2, y: 30))
                        p.addLine(to: CGPoint(x: 14, y: 12)); p.addLine(to: CGPoint(x: 7, y: 12)); p.closeSubpath()
                    }
                    .fill(Color(hex: "#FFD66B"))
                    .frame(width: 14, height: 30)
                    .offset(x: 18, y: 4)
                }
            }
            // The frame and the bar in the middle
            Rectangle().fill(Color(hex: "#2A3A66")).frame(width: 4)
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: "#2A3A66"), lineWidth: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(tip)
    }

    private static let stars: [CGPoint] = [CGPoint(x: -46, y: -30), CGPoint(x: -20, y: -8), CGPoint(x: 6, y: -34),
                                           CGPoint(x: -34, y: 18), CGPoint(x: 44, y: 14)]

    private var cloud: some View {
        ZStack {
            Capsule().fill(Color(hex: weather == .storm ? "#5B6478" : "#DCE3EE")).frame(width: 64, height: 22)
            Circle().fill(Color(hex: weather == .storm ? "#5B6478" : "#DCE3EE")).frame(width: 30, height: 30).offset(x: -8, y: -10)
        }
    }

    private var sky: LinearGradient {
        let colors: [String]
        switch (weather, night) {
        case (.storm, _):          colors = ["#2B3044", "#3D4560"]
        case (.rain, _):           colors = ["#4A5A7A", "#6B7C9C"]
        case (_, true):            colors = ["#0E1838", "#1C2B58"]
        case (.cloudy, false):     colors = ["#7FA6D8", "#B9CDE8"]
        default:                   colors = ["#5AA8FF", "#A6D4FF"]
        }
        return LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom)
    }

    private var tip: String {
        switch weather {
        case .sun:    return String(localized: "room.weather.sun")
        case .cloudy: return String(localized: "room.weather.cloudy")
        case .rain:   return String(localized: "room.weather.rain")
        case .storm:  return String(localized: "room.weather.storm")
        case .clear:  return String(localized: "room.weather.clear")
        }
    }
}

private struct RoomFrameView: View {
    let frame: RoomFrame
    @State private var hover = false

    var body: some View {
        Button {
            if let url = safeWebURL(frame.tool.url) ?? n8nURL { NSWorkspace.shared.open(url) }
        } label: {
            VStack(spacing: 3) {
                HStack(spacing: 5) {
                    if let dot = frame.dot { Circle().fill(dot).frame(width: 7, height: 7) }
                    Text(verbatim: frame.value)
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Text(verbatim: frame.label)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#A9B3C7"))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(width: 84, height: 60)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: "#0C1226")))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color(hex: frame.tool.color).opacity(hover ? 0.9 : 0.45), lineWidth: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(frame.tool.name)
    }

    /// n8n lives on your own server: its address is in the Keychain.
    private var n8nURL: URL? {
        frame.tool.id == "n8n" ? safeWebURL(KeychainStore.shared.get("n8n-url")) : nil
    }
}

private struct RoomClock: View {
    let coded: Int

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color(hex: "#0C1226"))
                Circle().strokeBorder(Color(hex: "#C7D0E0"), lineWidth: 3)
                Capsule().fill(.white).frame(width: 2, height: 13).offset(y: -6)
                Capsule().fill(.white).frame(width: 11, height: 2).offset(x: 5)
            }
            .frame(width: 42, height: 42)
            Text(verbatim: HubRoomPage.duration(coded))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#C7D0E0"))
                .monospacedDigit()
        }
        .help(String(localized: "room.stat.coded"))
    }
}

private struct RoomBed: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 4, bottomTrailingRadius: 4,
                                   topTrailingRadius: 12, style: .continuous)
                .fill(Color(hex: "#3A4570"))
            Capsule().fill(Color(hex: "#E9ECF3")).frame(width: 38, height: 18).offset(x: 8, y: -10)
            Capsule().fill(Color(hex: "#6E5BD0")).frame(width: 82, height: 24).offset(x: 52, y: -5)
        }
    }
}

private struct RoomPlant: View {
    let streak: Int

    var body: some View {
        let stage = MochiRoom.plant(streak: streak)
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if stage != .seed {
                    Capsule().fill(Color(hex: "#2FB86C")).frame(width: 3, height: stage == .sprout ? 14 : 26)
                }
                if stage == .leafy || stage == .bloom {
                    Capsule().fill(Color(hex: "#3DDC84")).frame(width: 12, height: 24)
                        .rotationEffect(.degrees(-24)).offset(x: -7, y: -8)
                    Capsule().fill(Color(hex: "#2FB86C")).frame(width: 11, height: 22)
                        .rotationEffect(.degrees(22)).offset(x: 7, y: -6)
                }
                if stage == .sprout {
                    Capsule().fill(Color(hex: "#3DDC84")).frame(width: 9, height: 12)
                        .rotationEffect(.degrees(30)).offset(x: 5, y: -8)
                }
                if stage == .bloom {
                    Circle().fill(Color(hex: "#F472B6")).frame(width: 12, height: 12).offset(y: -28)
                    Circle().fill(Color(hex: "#FFD66B")).frame(width: 5, height: 5).offset(y: -31.5)
                }
            }
            .frame(width: 40, height: 46, alignment: .bottom)
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 8, bottomTrailingRadius: 8,
                                   topTrailingRadius: 3, style: .continuous)
                .fill(Color(hex: "#B5673F"))
                .frame(width: 26, height: 26)
            Text(verbatim: String(format: String(localized: "room.days %lld"), Int64(streak)))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color(hex: "#C7D0E0"))
                .padding(.top, 6)
                .fixedSize()
        }
        .help(String(localized: "room.stat.streak"))
    }
}

private struct RoomDesk: View {
    let lit: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The Mac on the desk: its screen glows while an agent works.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(hex: "#0C1226"))
                .frame(width: 94, height: 58)
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color(hex: "#8C73F2")).frame(width: 70, height: 4)
                        Capsule().fill(Color(hex: "#8C73F2")).frame(width: 44, height: 4)
                        Capsule().fill(Color(hex: "#5AA8FF")).frame(width: 58, height: 4)
                    }
                    .opacity(lit ? 1 : 0.25)
                )
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(hex: "#C7D0E0"), lineWidth: 3))
                .shadow(color: Color(hex: "#8C73F2").opacity(lit ? 0.55 : 0), radius: 14)
                .offset(x: 112, y: 0)
            Rectangle().fill(Color(hex: "#C7D0E0")).frame(width: 6, height: 10).offset(x: 156, y: 58)
            RoundedRectangle(cornerRadius: 6).fill(Color(hex: "#4A5378")).frame(width: 220, height: 12).offset(y: 68)
            Rectangle().fill(Color(hex: "#4A5378")).frame(width: 7, height: 40).offset(x: 12, y: 80)
            Rectangle().fill(Color(hex: "#4A5378")).frame(width: 7, height: 40).offset(x: 200, y: 80)
        }
    }
}

private struct RoomDoor: View {
    let lit: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                   topTrailingRadius: 8, style: .continuous)
                .fill(lit ? Color(hex: "#FFCF7A") : Color(hex: "#2C3557"))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                                topTrailingRadius: 8, style: .continuous)
                    .strokeBorder(Color(hex: "#3A4570"), lineWidth: 3))
                .shadow(color: Color(hex: "#FFBE5A").opacity(lit ? 0.7 : 0), radius: 20)
            Circle().fill(Color(hex: "#C7D0E0")).frame(width: 7, height: 7).offset(x: 9, y: 76)
        }
    }
}

// MARK: - Cards under the room

/// A permission request, answered in the room: the same choices as the island's card, each one
/// a click (never a key press here, the page has text fields).
private struct RoomDoorCard: View {
    let approval: ApprovalInfo

    var body: some View {
        let shownId = approval.id
        let isPlan = approval.tool == "ExitPlanMode"
        let asking = PillCatalog.basePillId(approval.pillId)
        let name = approval.projectName.isEmpty
            ? (PillCatalog.definition(for: asking)?.name ?? "Claude Code") : approval.projectName
        HubCard(padding: 18) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: "#FFB340")).frame(width: 8, height: 8)
                Text(verbatim: isPlan ? String(format: String(localized: "room.door.plan %@"), name)
                                      : String(format: String(localized: "room.door.asks %@"), name))
                    .font(.system(size: 15, weight: .semibold))
                if approval.queueCount > 1 {
                    Text(verbatim: "1/\(approval.queueCount)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(HubTheme.secondary)
                        .monospacedDigit()
                }
            }
            Text(verbatim: approval.command.isEmpty ? approval.tool : approval.command)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(HubTheme.body)
                .lineLimit(6)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black))
            if isPlan || asking == "agent_antigravity" {
                // The plan's choices and Antigravity's terminal prompt stay in the island.
                HStack {
                    Text("room.door.answer-island")
                        .font(.system(size: 12.5))
                        .foregroundColor(HubTheme.secondary)
                    Spacer()
                    Button(String(localized: "room.door.open-island")) { RoomIsland.open(.approval) }
                        .buttonStyle(HubButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    Button(String(localized: "Deny")) { HookServer.shared.sendApprovalDecision("deny", for: shownId) }
                        .buttonStyle(HubButtonStyle())
                    // Codex, Copilot CLI and Muse Code do not support updatedPermissions.
                    if !["agent_codex", "agent_copilot", "agent_muse"].contains(asking) {
                        Button(String(localized: "Always")) { HookServer.shared.sendApprovalDecision("always", for: shownId) }
                            .buttonStyle(HubButtonStyle())
                    }
                    Spacer()
                    Button(String(localized: "Allow")) { HookServer.shared.sendApprovalDecision("allow", for: shownId) }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
        }
    }
}

/// A question from an agent: its choices live in the island.
private struct RoomQuestionCard: View {
    let asker: String

    var body: some View {
        HubCard(padding: 18) {
            HStack {
                Circle().fill(Color(hex: "#3B9EFF")).frame(width: 8, height: 8)
                Text(verbatim: String(format: String(localized: "room.door.question %@"), asker))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(String(localized: "room.door.open-island")) { RoomIsland.open(.question) }
                    .buttonStyle(HubButtonStyle(primary: true))
            }
        }
    }
}

@MainActor
private enum RoomIsland {
    static func open(_ view: IslandView) {
        (NSApp.delegate as? AppDelegate)?.islandController?.expand(to: view)
    }
}

private struct RoomStat: View {
    let label: String
    let value: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
            Text(verbatim: value)
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.6)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: note ?? " ")
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }
}

private struct RoomIntroLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(hex: "#A78BFA"))
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundColor(HubTheme.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
