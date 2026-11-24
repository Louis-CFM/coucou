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
                    .controlSize(.small)
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

    /// One slot per tool, in order: an empty frame for a tool not connected or hidden.
    private var frames: [RoomFrame?] {
        let hidden = MochiRoom.hiddenTools(hiddenRaw)
        return RoomTool.all.map { tool in
            connected.contains(tool.id) && !hidden.contains(tool.id) ? wallFrame(for: tool) : nil
        }
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
                    Toggle(String(localized: "room.enabled"), isOn: $enabled).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "room.setting.door"), detail: String(localized: "room.setting.door.detail")) {
                    Toggle(String(localized: "room.setting.door"), isOn: $useDoor).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "room.setting.weather"), detail: String(localized: "room.setting.weather.detail")) {
                    Toggle(String(localized: "room.setting.weather"), isOn: $showWeather).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "room.setting.day-night"), detail: String(localized: "room.setting.day-night.detail")) {
                    Toggle(String(localized: "room.setting.day-night"), isOn: $dayNight).toggleStyle(.switch).controlSize(.small).labelsHidden()
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
            RoomLogo(tool: tool, size: 15)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
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
                    .controlSize(.small)
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
    /// The brand's logo in Assets → RoomLogos (Simple Icons, CC0), drawn in `color`.
    let logo: String
    let color: String
    /// Opened by a click on its frame.
    let url: String

    static let all: [RoomTool] = [
        RoomTool(id: "stripe", name: "Stripe", keys: ["stripe-api-key"], logo: "RoomLogoStripe",
                 color: "#635BFF", url: "https://dashboard.stripe.com/payments"),
        RoomTool(id: "github", name: "GitHub", keys: ["github-token"], logo: "RoomLogoGitHub",
                 color: "#F5F6F8", url: "https://github.com"),
        RoomTool(id: "vercel", name: "Vercel", keys: ["vercel-token"], logo: "RoomLogoVercel",
                 color: "#F5F6F8", url: "https://vercel.com/dashboard"),
        RoomTool(id: "n8n", name: "n8n", keys: ["n8n-url", "n8n-api-key"], logo: "RoomLogoN8n",
                 color: "#EA4B71", url: ""),
        RoomTool(id: "calcom", name: "Cal.com", keys: ["calcom-api-key"], logo: "RoomLogoCalcom",
                 color: "#F5F6F8", url: "https://app.cal.com/bookings/upcoming"),
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

/// The room: a painted picture (Assets → MochiRoom) and, over it, everything that moves or
/// shows data, drawn in one canvas at 30 fps while the Coucou window shows and still otherwise:
/// the weather in the window, the code on the screen, the clock, the plant on the shelf, the
/// light at the door, Mochi and the little Mochis. The frames on the wall are buttons.
/// Every place is in the picture's pixels (`RoomArt`), scaled to the width of the page.
private struct RoomScene: View {
    let spot: MochiRoom.Spot
    let mochiState: BotState
    let weather: MochiRoom.Weather
    let night: Bool
    /// One per slot on the wall, in `RoomTool.all` order: nil leaves the frame empty.
    let frames: [RoomFrame?]
    let coded: Int
    let streak: Int
    let minis: [RoomMini]
    let doorLit: Bool

    @StateObject private var cast = RoomCast()
    @Environment(\.hubVisible) private var visible

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / RoomArt.size.width
            ZStack(alignment: .topLeading) {
                Image("MochiRoom")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: geo.size.width, height: geo.size.height)

                TimelineView(.animation(minimumInterval: MochiFrameClock.interval(fps: MochiFrameClock.miniFPS),
                                        paused: !visible)) { timeline in
                    let date = timeline.date
                    Canvas { context, _ in
                        context.scaleBy(x: s, y: s)
                        let t = date.timeIntervalSinceReferenceDate
                        RoomPainter.window(&context, t: t, weather: weather, night: night)
                        RoomPainter.screen(&context, t: t, busy: spot == .desk)
                        RoomPainter.clock(&context, date: date)
                        RoomPainter.plant(&context, t: t, stage: MochiRoom.plant(streak: streak))
                        RoomPainter.door(&context, t: t, lit: doorLit)
                        RoomPainter.light(&context, night: night)
                        cast.step(spot: spot, state: mochiState, minis: minis)
                        cast.draw(&context)
                    }
                }
                // Clicks go to the frames.
                .allowsHitTesting(false)

                ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                    if let frame {
                        let slot = RoomArt.frames[index]
                        RoomFrameView(frame: frame, scale: s)
                            .frame(width: slot.width * s, height: slot.height * s)
                            .position(x: slot.midX * s, y: slot.midY * s)
                    }
                }

                RoomTag(text: HubRoomPage.duration(coded), scale: s)
                    .help(String(localized: "room.stat.coded"))
                    .position(x: RoomArt.clock.x * s, y: (RoomArt.clock.y + 70) * s)
                RoomTag(text: String(format: String(localized: "room.days %lld"), Int64(streak)), scale: s)
                    .help(String(localized: "room.stat.streak"))
                    .position(x: RoomArt.pot.x * s, y: 302 * s)

                // The names under the little Mochis
                ForEach(Array(minis.enumerated()), id: \.element.id) { index, mini in
                    Text(verbatim: mini.name)
                        .font(.system(size: 11 * s, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .lineLimit(1)
                        .frame(width: 120 * s)
                        .position(x: RoomArt.miniX(index, of: minis.count) * s, y: (RoomArt.miniFeet + 18) * s)
                        .allowsHitTesting(false)
                }
            }
        }
        .aspectRatio(RoomArt.size.width / RoomArt.size.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(HubTheme.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("room.title"))
    }
}

/// Where things are in the picture, in its pixels (1344 × 752).
enum RoomArt {
    static let size = CGSize(width: 1344, height: 752)
    /// The glass of the window (its exact shape is the MochiRoomWindow mask).
    static let window = CGRect(x: 24, y: 80, width: 140, height: 345)
    /// The screen of the computer on the desk.
    static let screen = CGRect(x: 968, y: 269, width: 145, height: 88)
    static let clock = CGPoint(x: 668, y: 143)
    /// The soil in the pot on the shelf.
    static let pot = CGPoint(x: 295, y: 231)
    static let door = CGRect(x: 1176, y: 52, width: 158, height: 590)
    /// The inside of the five frames on the wall.
    static let frames: [CGRect] = [433, 520, 607, 694, 780].map { CGRect(x: $0, y: 232, width: 59, height: 79) }

    /// Mochi's feet at each spot.
    static func mochi(_ spot: MochiRoom.Spot) -> CGPoint {
        switch spot {
        case .bed:  return CGPoint(x: 250, y: 452)
        case .desk: return CGPoint(x: 962, y: 486)
        case .door: return CGPoint(x: 1112, y: 648)
        }
    }

    /// The little Mochis stand on the rug.
    static let miniFeet: CGFloat = 686
    static func miniX(_ index: Int, of count: Int) -> CGFloat {
        let left: CGFloat = 450, right: CGFloat = 860
        guard count > 1 else { return (left + right) / 2 }
        return left + (right - left) * CGFloat(index) / CGFloat(count - 1)
    }
}

/// What moves in the room, drawn in the picture's pixels.
@MainActor
private enum RoomPainter {
    static func window(_ context: inout GraphicsContext, t: Double, weather: MochiRoom.Weather, night: Bool) {
        let mask = context.resolve(Image("MochiRoomWindow"))
        context.drawLayer { ctx in
            ctx.clipToLayer { layer in layer.draw(mask, in: CGRect(origin: .zero, size: RoomArt.size)) }
            let w = RoomArt.window
            let sky: [String]
            switch (weather, night) {
            case (.storm, _):      sky = ["#262B40", "#3D4560"]
            case (.rain, _):       sky = night ? ["#151C33", "#2B3552"] : ["#4A5A7A", "#7D8CA8"]
            case (_, true):        sky = ["#0B1430", "#1C2B58"]
            case (.cloudy, false): sky = ["#7FA6D8", "#C9D8EC"]
            default:               sky = ["#5AA8FF", "#BFE2FF"]
            }
            ctx.fill(Path(w.insetBy(dx: -10, dy: -10)),
                     with: .linearGradient(Gradient(colors: sky.map { Color(hex: $0) }),
                                           startPoint: CGPoint(x: 0, y: w.minY), endPoint: CGPoint(x: 0, y: w.maxY)))
            if night {
                for i in 0..<16 {
                    let x = w.minX + 10 + CGFloat((i * 53) % 120), y = w.minY + 14 + CGFloat((i * 97) % 250)
                    let twinkle = 0.35 + 0.65 * abs(sin(t * 1.3 + Double(i)))
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2.6, height: 2.6)), with: .color(.white.opacity(twinkle)))
                }
                if weather == .sun || weather == .clear {
                    ctx.fill(Path(ellipseIn: CGRect(x: 98, y: 128, width: 34, height: 34)), with: .color(Color(hex: "#F5F1DC")))
                }
            } else if weather == .sun || weather == .clear {
                let glow = 0.25 + 0.1 * sin(t * 1.2)
                ctx.fill(Path(ellipseIn: CGRect(x: 72, y: 112, width: 76, height: 76)), with: .color(Color(hex: "#FFD66B").opacity(glow)))
                ctx.fill(Path(ellipseIn: CGRect(x: 88, y: 128, width: 44, height: 44)), with: .color(Color(hex: "#FFD66B")))
            }
            if weather != .sun && weather != .clear {
                let drift = CGFloat((t * 9).truncatingRemainder(dividingBy: 240)) - 70
                let tone = Color(hex: weather == .storm ? "#545C75" : (night ? "#3A4566" : "#E4E9F2"))
                cloud(&ctx, x: w.minX + drift, y: 170, color: tone)
                cloud(&ctx, x: w.minX + drift - 130, y: 236, color: tone.opacity(0.9))
                cloud(&ctx, x: w.minX + drift + 110, y: 290, color: tone.opacity(0.8))
            }
            if weather == .rain || weather == .storm {
                for i in 0..<44 {
                    let x = w.minX + CGFloat((i * 37) % 150)
                    let y = w.minY + CGFloat((t * 420 + Double(i * 61)).truncatingRemainder(dividingBy: 370)) - 10
                    var drop = Path()
                    drop.move(to: CGPoint(x: x, y: y))
                    drop.addLine(to: CGPoint(x: x - 4, y: y + 13))
                    ctx.stroke(drop, with: .color(Color(hex: "#AAC8FF").opacity(0.75)), lineWidth: 2)
                }
            }
            if weather == .storm, t.truncatingRemainder(dividingBy: 5) < 0.12 {
                ctx.fill(Path(w.insetBy(dx: -10, dy: -10)), with: .color(.white.opacity(0.55)))
            }
        }
    }

    private static func cloud(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, color: Color) {
        var p = Path()
        p.addEllipse(in: CGRect(x: x, y: y - 14, width: 80, height: 28))
        p.addEllipse(in: CGRect(x: x + 12, y: y - 30, width: 36, height: 32))
        p.addEllipse(in: CGRect(x: x + 36, y: y - 24, width: 32, height: 26))
        ctx.fill(p, with: .color(color))
    }

    /// Code typing in while an agent works; a cursor blinking otherwise.
    static func screen(_ context: inout GraphicsContext, t: Double, busy: Bool) {
        let r = RoomArt.screen
        context.drawLayer { ctx in
            ctx.clip(to: Path(r))
            ctx.fill(Path(r), with: .color(Color(hex: "#0C1226")))
            if busy {
                let colors = ["#A78BFA", "#5AA8FF", "#34D399", "#FB923C"].map { Color(hex: $0) }
                let step = t / 0.22
                let first = Int(step)
                let typed = CGFloat(step - Double(first))
                for i in 0..<7 {
                    let line = first + i
                    let width = CGFloat(20 + (line * 37) % 72)
                    let indent = CGFloat((line * 13) % 3) * 10
                    let shown = i == 6 ? width * typed : width
                    ctx.fill(Path(roundedRect: CGRect(x: r.minX + 8 + indent, y: r.minY + 7 + CGFloat(i) * 11, width: shown, height: 4),
                                  cornerRadius: 2),
                             with: .color(colors[line % colors.count].opacity(0.9)))
                }
                ctx.fill(Path(r), with: .color(Color(hex: "#8C73F2").opacity(0.06)))
            } else if Int(t * 1.6) % 2 == 0 {
                ctx.fill(Path(CGRect(x: r.minX + 10, y: r.minY + 10, width: 7, height: 10)), with: .color(Color(hex: "#5AA8FF").opacity(0.8)))
            }
        }
    }

    /// The real time, with a second hand that ticks.
    static func clock(_ context: inout GraphicsContext, date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let seconds = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9
        let minutes = Double(c.minute ?? 0) + seconds / 60
        let hours = Double((c.hour ?? 0) % 12) + minutes / 60
        let ink = Color(hex: "#2B2236")
        hand(&context, turn: hours / 12, length: 24, width: 5, color: ink)
        hand(&context, turn: minutes / 60, length: 34, width: 4, color: ink)
        hand(&context, turn: Double(Int(seconds)) / 60, length: 38, width: 1.6, color: Color(hex: "#FB923C"))
        let o = RoomArt.clock
        context.fill(Path(ellipseIn: CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8)), with: .color(ink))
    }

    private static func hand(_ ctx: inout GraphicsContext, turn: Double, length: CGFloat, width: CGFloat, color: Color) {
        let o = RoomArt.clock, a = turn * 2 * .pi
        var p = Path()
        p.move(to: o)
        p.addLine(to: CGPoint(x: o.x + CGFloat(sin(a)) * length, y: o.y - CGFloat(cos(a)) * length))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// The streak plant, swaying a little in its pot.
    static func plant(_ context: inout GraphicsContext, t: Double, stage: MochiRoom.Plant) {
        var ctx = context
        ctx.translateBy(x: RoomArt.pot.x, y: RoomArt.pot.y)
        ctx.rotate(by: .radians(sin(t * 1.1) * 0.05))
        let dark = Color(hex: "#2FB86C"), light = Color(hex: "#3DDC84")
        switch stage {
        case .seed:
            ctx.fill(Path(ellipseIn: CGRect(x: -4, y: -5, width: 8, height: 6)), with: .color(Color(hex: "#C9A27A")))
            return
        case .sprout:
            stem(&ctx, height: 18, color: dark)
            leaf(&ctx, at: CGPoint(x: 0, y: -16), angle: -0.9, size: 0.7, color: light)
            leaf(&ctx, at: CGPoint(x: 0, y: -16), angle: 0.9, size: 0.7, color: dark)
        case .leafy, .bloom:
            stem(&ctx, height: 50, color: dark)
            leaf(&ctx, at: CGPoint(x: -1, y: -18), angle: -0.95, size: 1, color: light)
            leaf(&ctx, at: CGPoint(x: 1, y: -30), angle: 0.85, size: 1, color: dark)
            leaf(&ctx, at: CGPoint(x: 0, y: -42), angle: -0.6, size: 0.85, color: light)
            if stage == .bloom {
                for k in 0..<5 {
                    let a = Double(k) / 5 * 2 * .pi
                    ctx.fill(Path(ellipseIn: CGRect(x: CGFloat(cos(a)) * 6 - 5, y: -58 + CGFloat(sin(a)) * 6 - 5, width: 10, height: 10)),
                             with: .color(Color(hex: "#F472B6")))
                }
                ctx.fill(Path(ellipseIn: CGRect(x: -4, y: -62, width: 8, height: 8)), with: .color(Color(hex: "#FFD66B")))
            }
        }
    }

    private static func stem(_ ctx: inout GraphicsContext, height: CGFloat, color: Color) {
        var p = Path()
        p.move(to: .zero)
        p.addQuadCurve(to: CGPoint(x: 0, y: -height), control: CGPoint(x: 3, y: -height / 2))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 4, lineCap: .round))
    }

    private static func leaf(_ ctx: inout GraphicsContext, at point: CGPoint, angle: Double, size: CGFloat, color: Color) {
        var c = ctx
        c.translateBy(x: point.x, y: point.y)
        c.rotate(by: .radians(angle))
        c.fill(Path(ellipseIn: CGRect(x: -6 * size, y: -20 * size, width: 12 * size, height: 22 * size)), with: .color(color))
    }

    /// Someone is at the door: warm light around it, breathing.
    static func door(_ context: inout GraphicsContext, t: Double, lit: Bool) {
        guard lit else { return }
        let d = RoomArt.door
        let a = 0.42 + 0.22 * sin(t * 3)
        context.drawLayer { ctx in
            ctx.blendMode = .plusLighter
            let center = CGPoint(x: d.midX, y: d.midY)
            ctx.fill(Path(d.insetBy(dx: -220, dy: -60)),
                     with: .radialGradient(Gradient(colors: [Color(hex: "#FFBE5A").opacity(a), .clear]),
                                           center: center, startRadius: 40, endRadius: 300))
            // The light under the door
            ctx.fill(Path(CGRect(x: d.minX + 8, y: d.maxY - 6, width: d.width - 16, height: 6)),
                     with: .color(Color(hex: "#FFCF7A").opacity(a + 0.2)))
        }
    }

    /// Day: the window lights the room a little. Night: the room is dimmer, the lamp warmer.
    static func light(_ context: inout GraphicsContext, night: Bool) {
        let full = Path(CGRect(origin: .zero, size: RoomArt.size))
        if night {
            context.fill(full, with: .color(Color.black.opacity(0.14)))
            context.drawLayer { ctx in
                ctx.blendMode = .plusLighter
                ctx.fill(full, with: .radialGradient(Gradient(colors: [Color(hex: "#FFB45A").opacity(0.16), .clear]),
                                                     center: CGPoint(x: 905, y: 330), startRadius: 10, endRadius: 260))
            }
        } else {
            context.drawLayer { ctx in
                ctx.blendMode = .plusLighter
                ctx.fill(full, with: .radialGradient(Gradient(colors: [Color(hex: "#9CC8FF").opacity(0.12), .clear]),
                                                     center: CGPoint(x: 120, y: 260), startRadius: 20, endRadius: 520))
            }
        }
    }
}

/// Mochi and the little Mochis, moved frame by frame, in the picture's pixels.
@MainActor
final class RoomCast: ObservableObject {
    static let mochiSize: CGFloat = 118
    static let miniSize: CGFloat = 58

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

    func step(spot: MochiRoom.Spot, state: BotState, minis wanted: [RoomMini]) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.1, max(0, now - last)))
        last = now

        // Mochi hops to his spot, then takes its face.
        let target = RoomArt.mochi(spot)
        var here = position ?? target
        let dx = target.x - here.x, dy = target.y - here.y
        let distance = hypot(dx, dy)
        if distance > 1 {
            let move = min(distance, 320 * dt)
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

    func draw(_ context: inout GraphicsContext) {
        for (index, mini) in order.enumerated() {
            guard let engine = minis[mini.id] else { continue }
            let x = RoomArt.miniX(index, of: order.count)
            Self.drawMochi(engine, at: CGPoint(x: x, y: RoomArt.miniFeet), size: Self.miniSize, lift: 0, in: &context)
        }
        if let position {
            let lift = abs(sin(hop)) * Self.mochiSize * 0.08
            Self.drawMochi(mochi, at: position, size: Self.mochiSize, lift: lift, in: &context)
        }
    }

    private static func drawMochi(_ engine: BotEngine, at feet: CGPoint, size w: CGFloat, lift: CGFloat,
                                  in context: inout GraphicsContext) {
        let shadow = CGRect(x: feet.x - w * 0.26, y: feet.y - w * 0.05, width: w * 0.52, height: w * 0.09)
        context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.3)))
        var c = context
        c.translateBy(x: feet.x - w / 2, y: feet.y - w * 0.92 - lift)
        engine.draw(context: c, size: CGSize(width: w, height: w))
    }
}

// MARK: - On the wall

/// A connected tool in its frame: its logo, today's number, a word. A click opens the service.
private struct RoomFrameView: View {
    let frame: RoomFrame
    let scale: CGFloat
    @State private var hover = false

    var body: some View {
        Button {
            if let url = safeWebURL(frame.tool.url) ?? n8nURL { NSWorkspace.shared.open(url) }
        } label: {
            VStack(spacing: 4 * scale) {
                RoomLogo(tool: frame.tool, size: 17 * scale)
                HStack(spacing: 3 * scale) {
                    if let dot = frame.dot {
                        Circle().fill(dot).frame(width: 6 * scale, height: 6 * scale)
                    }
                    Text(verbatim: frame.value)
                        .font(.system(size: 13 * scale, weight: .bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                Text(verbatim: frame.label)
                    .font(.system(size: 9 * scale))
                    .foregroundColor(Color(hex: "#A9B3C7"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 3 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: "#0C1226").opacity(hover ? 1 : 0.92))
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

/// A tool's real logo (Assets → RoomLogos), in its colour.
struct RoomLogo: View {
    let tool: RoomTool
    let size: CGFloat

    var body: some View {
        Image(tool.logo)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundColor(Color(hex: tool.color))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A small label hung under the clock or the shelf.
private struct RoomTag: View {
    let text: String
    let scale: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11.5 * scale, weight: .semibold))
            .foregroundColor(Color(hex: "#E1E3E6"))
            .monospacedDigit()
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 3 * scale)
            .background(Capsule().fill(Color(hex: "#0C1226").opacity(0.85)))
            .fixedSize()
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
