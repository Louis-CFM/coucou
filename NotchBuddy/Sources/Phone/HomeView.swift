import SwiftUI
import UIKit
import StoreKit

/// The tabs, in glass on iOS 26: the agents, the services, the decisions you
/// took, and a search through every turn.
enum CoucouTab: Hashable { case agents, services, history, chat, search }

struct HomeView: View {
    let link: PhoneLink
    @State private var tab: CoucouTab = .agents
    @State private var agentsPath: [String] = []
    @State private var servicesPath: [String] = []
    @State private var introDone = false
    @AppStorage("onboardingDone") private var onboardingDone = false
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        TabView(selection: $tab) {
            Tab("Agents", systemImage: "sparkles", value: CoucouTab.agents) {
                AgentsTab(link: link, path: $agentsPath)
            }
            Tab("Services", systemImage: "square.grid.2x2", value: CoucouTab.services) {
                ServicesTab(link: link, path: $servicesPath)
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: CoucouTab.history) {
                NavigationStack { HistoryView(link: link) }
            }
            Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: CoucouTab.chat) {
                ChatView()
            }
            Tab(value: CoucouTab.search, role: .search) {
                SearchTab(link: link)
            }
        }
        // The demo says so, with a way out, on every tab.
        .safeAreaInset(edge: .top, spacing: 0) {
            if link.isDemo { DemoBar(link: link) }
        }
        // A good moment (ReviewPolicy): Apple's own review request, a moment after the decision.
        .onChange(of: link.askForAppReview) { _, ask in
            guard ask else { return }
            link.askForAppReview = false
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                requestReview()
            }
        }
        // A widget tile was tapped: open that Mochi.
        .onOpenURL { url in
            if let id = SharedSession.sessionId(from: url) { open(id) }
        }
        // A notification, Siri, Spotlight or the Control Center asked for a session.
        .onChange(of: link.openPillId) { _, id in
            guard let id else { return }
            open(id)
            link.openPillId = nil
        }
        .onContinueUserActivity(SpotlightIndex.activityType) { activity in
            if let id = SpotlightIndex.pillId(from: activity) { open(id) }
        }
        .sheet(isPresented: Binding(get: { link.reviewFingerprint != nil },
                                    set: { if !$0 { link.reviewFingerprint = nil } })) {
            if let fingerprint = link.reviewFingerprint {
                ReviewSheet(link: link, fingerprint: fingerprint)
            }
        }
        // First launch: how to connect the Mac.
        .fullScreenCover(isPresented: Binding(get: { !onboardingDone }, set: { if !$0 { onboardingDone = true } })) {
            OnboardingView()
        }
        // The opening: Mochi alone while the app loads, then he flies to his tile.
        .overlay {
            if !introDone {
                IntroView(ready: link.firstSyncDone) { introDone = true }
                    .transition(.identity)
            }
        }
        .onAppear {
            // The first launch opens on the setup guide instead.
            if !onboardingDone {
                introDone = true
                IntroLanding.shared.landed = true
            }
        }
    }

    private func open(_ id: String) {
        if PillCatalog.isSession(id) {
            tab = .agents
            agentsPath = [id]
        } else {
            tab = .services
            servicesPath = [id]
        }
    }
}

/// Every agent session from the Mac, most urgent first. Swipe right to allow
/// (Face ID), left to deny; press and hold for a peek at the last turn.
struct AgentsTab: View {
    let link: PhoneLink
    @Binding var path: [String]
    @Namespace private var zoom
    /// The link test (builds run from Xcode): slides in from the left, the side of its button.
    @State private var showingTest = false
    @State private var showingNewTask = false

    /// The curve of iOS's own push (UINavigationController), so the link test moves like Settings.
    private static let push = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500, initialVelocity: 0)

    /// How far a finger pulled the link test back to the left (0 at rest, negative while pulling).
    @State private var testDrag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            // 1 with the link test fully in, 0 without: the home moves aside with it, as on a push.
            let progress = showingTest ? 1 + min(0, testDrag) / width : 0
            ZStack {
                agents
                    .offset(x: width * 0.3 * progress)
                    .overlay {
                        Color.black.opacity(0.3 * progress).ignoresSafeArea().allowsHitTesting(false)
                    }
                #if DEBUG
                if showingTest {
                    testPage
                        .offset(x: min(0, testDrag))
                        .shadow(color: .black.opacity(0.45), radius: 14)
                        .transition(.move(edge: .leading))
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onChanged { testDrag = min(0, $0.translation.width) }
                                .onEnded { drag in
                                    let leaves = drag.translation.width < -width * 0.3
                                        || drag.predictedEndTranslation.width < -width * 0.6
                                    withAnimation(Self.push) {
                                        if leaves { showingTest = false }
                                        testDrag = 0
                                    }
                                }
                        )
                        .zIndex(1)
                }
                #endif
            }
        }
    }

    #if DEBUG
    private var testPage: some View {
        NavigationStack {
            LinkTestView(link: link)
                .toolbar {
                    // Leaves the way it came: to the left.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(Self.push) { showingTest = false }
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                    }
                }
        }
        .background(Color.black)
    }
    #endif

    private var agents: some View {
        NavigationStack(path: $path) {
            List {
                // Mochi, what's going on, Botan's antenna; the OK panel grows out of it.
                Section {
                    NotchHeader(link: link)
                        // Shrinks and fades as the list scrolls, like Wallet.
                        .visualEffect { content, proxy in
                            let y = proxy.frame(in: .scrollView).minY
                            let pull = min(0, y - 8)
                            return content
                                .scaleEffect(max(0.86, 1 + pull / 500), anchor: .top)
                                .opacity(max(0, 1 + pull / 160))
                        }
                        .homeCardRow()
                }

                if TodayCard.hasContent(link) {
                    // The card's row only: on the section, the insets would move its title too.
                    Section("Today") {
                        TodayCard(link: link).homeCardRow()
                    }
                }

                if !AttentionCard.flagged(link).isEmpty {
                    Section("Needs a look") {
                        AttentionCard(link: link).homeCardRow()
                    }
                }

                Section("Agents") {
                    if link.sessions.isEmpty {
                        EmptySessionsView(link: link)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                    }
                    ForEach(link.sessions.sortedByUrgency()) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session, zoom: zoom)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            if session.needsApproval && !session.approvalFingerprint.isEmpty {
                                Button {
                                    Task { _ = await QuickDecision.allow(session, link: link) }
                                } label: {
                                    Label("Allow", systemImage: "faceid")
                                }
                                .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if session.needsApproval && !session.approvalFingerprint.isEmpty {
                                Button(role: .destructive) {
                                    Task { _ = await QuickDecision.deny(session, link: link) }
                                } label: {
                                    Label("Deny", systemImage: "xmark")
                                }
                            }
                        }
                        .contextMenu {
                            SessionMenu(link: link, session: session)
                        } preview: {
                            SessionPeek(session: session, turn: link.turns[session.id])
                        }
                    }
                }
            }
            // One rhythm between every section.
            .listSectionSpacing(.custom(18))
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            // Sessions move to their new place and change status smoothly.
            .animation(.spring(duration: 0.5, bounce: 0.2),
                       value: link.sessions.map { "\($0.id)|\($0.statusText)" })
            .refreshable { await link.refresh() }
            .navigationTitle("Botan")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                SessionDetailView(link: link, sessionId: id)
                    // The Mochi tile grows into the session, and shrinks back.
                    .navigationTransition(.zoom(sourceID: id, in: zoom))
            }
            .sheet(isPresented: $showingNewTask) {
                NewTaskView(link: link)
                    .presentationDragIndicator(.visible)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewTask = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New task")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AboutView(link: link)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #if DEBUG
                // Test screens, in builds run from Xcode only.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(Self.push) { showingTest = true }
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                }
                #endif
            }
        }
    }
}

/// The service Mochi (GitHub, Stripe…), each with what it saw.
struct ServicesTab: View {
    let link: PhoneLink
    @Binding var path: [String]
    @Namespace private var zoom

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                ServicesList(services: link.services)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
            .background(Color.black)
            .refreshable { await link.refresh() }
            .navigationTitle("Services")
            .navigationDestination(for: String.self) { id in
                ServiceDetailView(link: link, pillId: id)
            }
        }
    }
}

/// Allow (Face ID) and Deny without opening the session.
@MainActor
enum QuickDecision {
    static func allow(_ session: SessionItem, link: PhoneLink) async -> Bool {
        guard await OwnerCheck.confirm(reason: "Allow this command on your Mac") else {
            Haptics.warning()
            return false
        }
        let summary = session.approvalCommand.isEmpty ? "Permission" : session.approvalCommand
        let sent = await link.decide(.allow, fingerprint: session.approvalFingerprint, pillId: session.id,
                                     summary: String(summary.prefix(200)))
        if sent { Haptics.success() } else { Haptics.error() }
        return sent
    }

    static func deny(_ session: SessionItem, link: PhoneLink) async -> Bool {
        let summary = session.approvalCommand.isEmpty ? "Permission" : session.approvalCommand
        let sent = await link.decide(.deny, fingerprint: session.approvalFingerprint, pillId: session.id,
                                     summary: String(summary.prefix(200)))
        if sent { Haptics.impact() } else { Haptics.error() }
        return sent
    }
}

/// What a long press on a session offers.
struct SessionMenu: View {
    let link: PhoneLink
    let session: SessionItem

    var body: some View {
        if session.needsApproval && !session.approvalFingerprint.isEmpty {
            Button {
                Task { _ = await QuickDecision.allow(session, link: link) }
            } label: {
                Label("Allow", systemImage: "faceid")
            }
            Button(role: .destructive) {
                Task { _ = await QuickDecision.deny(session, link: link) }
            } label: {
                Label("Deny", systemImage: "xmark")
            }
        }
        if !session.approvalCommand.isEmpty {
            Button {
                UIPasteboard.general.string = session.approvalCommand
            } label: {
                Label("Copy the command", systemImage: "doc.on.doc")
            }
        }
        if let answer = link.turns[session.id]?.finalMessage, !answer.isEmpty {
            Button {
                UIPasteboard.general.string = answer
            } label: {
                Label("Copy Claude's answer", systemImage: "text.quote")
            }
        }
        Button {
            link.openPillId = session.id
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
    }
}

/// The peek of a long press: who, where it is, and the last turn in short.
struct SessionPeek: View {
    let session: SessionItem
    let turn: TurnSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MochiStill(state: session.state, bodyHex: session.color)
                    .padding(6)
                    .frame(width: 48, height: 48)
                    .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.headline)
                    Text(session.statusText).font(.subheadline.weight(.semibold)).foregroundStyle(session.statusColor)
                }
            }
            if session.needsApproval, !session.approvalCommand.isEmpty {
                Text(session.approvalCommand)
                    .font(.callout.monospaced())
                    .lineLimit(5)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            if let turn {
                Text(turn.headline)
                    .font(.callout)
                    .lineLimit(3)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 14) {
                    Label("\(turn.actions.count)", systemImage: "wrench.and.screwdriver")
                    Label("\(turn.files.count)", systemImage: "doc.text")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !turn.finalMessage.isEmpty {
                    Text(turn.finalMessage).font(.callout).foregroundStyle(.secondary).lineLimit(6)
                }
            }
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
        .background(Color(white: 0.09))
        .environment(\.colorScheme, .dark)
    }
}

/// The black island at the top: Mochi with the most urgent state and a
/// summary. When a command waits for your OK, Allow and Deny grow out of it
/// (Liquid Glass morphing on iOS 26) and fold back once answered.
struct NotchHeader: View {
    let link: PhoneLink
    @Namespace private var glass
    @State private var sending = false
    @State private var approved = false

    private var sessions: [SessionItem] { link.sessions }

    /// The session waiting for an OK this iPhone can give.
    private var waiting: SessionItem? {
        sessions.sortedByUrgency().first { $0.needsApproval && !$0.approvalFingerprint.isEmpty }
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        summary
                            // Tinted with the color of the moment, like Botan's screen.
                            .glassEffect(sessions.leadState.tint.map { .regular.tint($0.opacity(0.22)) } ?? .regular,
                                         in: RoundedRectangle(cornerRadius: 28))
                            .glassEffectID("island", in: glass)
                        if let waiting {
                            panel(waiting)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
                                .glassEffectID("panel", in: glass)
                                // Mirror the entry animation on exit (move down + fade).
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    summary
                        .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 28))
                        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    if let waiting {
                        panel(waiting)
                            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 26))
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
        }
        .overlay {
            if approved {
                DrawnCheckmark(size: 64)
                    .padding(14)
                    .background(.ultraThinMaterial, in: Circle())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.55, bounce: 0.3), value: waiting?.approvalFingerprint)
        .animation(.spring(duration: 0.5, bounce: 0.2), value: "\(headline)|\(detail ?? "")")
        .animation(.spring(duration: 0.4, bounce: 0.3), value: approved)
        .sensoryFeedback(.success, trigger: approved) { _, new in new }
    }

    private func panel(_ session: SessionItem) -> some View {
        ApprovalPanel(session: session, disabled: sending) {
            Task {
                sending = true
                _ = await QuickDecision.deny(session, link: link)
                sending = false
            }
        } allow: {
            Task {
                sending = true
                if await QuickDecision.allow(session, link: link) {
                    approved = true
                    try? await Task.sleep(for: .seconds(1.4))
                    approved = false
                }
                sending = false
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            MochiLive(state: sessions.leadState)
                .frame(width: 64, height: 64)
                .background {
                    // His glow, in the color of the moment.
                    if let tint = sessions.leadState.tint {
                        Circle().fill(tint).blur(radius: 18).opacity(0.55).frame(width: 70, height: 70)
                    }
                }
                .introLanding(.header)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .contentTransition(.interpolate)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }
            }
            Spacer(minLength: 0)
            BotanAntenna()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var headline: String {
        switch link.status {
        case .noAccount: return "iCloud not connected"
        case .failed: return "Can't reach iCloud"
        default: break
        }
        return sessions.summary ?? (sessions.isEmpty ? "Nothing yet" : "All quiet")
    }

    private var detail: String? {
        guard let lead = sessions.sortedByUrgency().first else { return nil }
        return "\(lead.title) · \(lead.statusText)"
    }
}

struct SessionRow: View {
    let session: SessionItem
    var zoom: Namespace.ID? = nil

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                // The agent under the project name; for a session without a project
                // name (title is the agent already), what runs in it.
                Text(session.title == session.pillName
                     ? (PillCatalog.definition(for: session.id)?.sessionSubtitle ?? session.pillName)
                     : session.pillName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    StateSymbol(session: session).font(.caption)
                    Text(session.statusText)
                        .font(.subheadline.weight(session.isWaitingForYou ? .semibold : .regular))
                        .foregroundStyle(session.statusColor)
                        .contentTransition(.interpolate)
                }
                Text(session.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var tile: some View {
        let base = mochi
            .padding(4)
            .frame(width: 40, height: 40)
            .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 11))
        if let zoom {
            base.matchedTransitionSource(id: session.id, in: zoom)
        } else {
            base
        }
    }

    /// VS Code's Mochi is where the intro's Mochi lands.
    @ViewBuilder private var mochi: some View {
        if session.id == "integration_claude" {
            MochiLive(state: session.state, fps: 60).introLanding(.tile)
        } else {
            MochiLive(state: session.state, fps: 60)
        }
    }
}

struct EmptySessionsView: View {
    let link: PhoneLink
    private var status: PhoneLink.Status { link.status }

    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            // No Mac yet: see what it looks like with sample agents.
            if status != .starting {
                Button("Try the demo") {
                    withAnimation { Demo.start(link) }
                    Haptics.impact()
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(Color.botan)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .glassCard()
    }

    private var message: String {
        switch status {
        case .starting: "Connecting to iCloud…"
        case .noAccount(let reason): "\(reason) Sign in to iCloud with the same account as your Mac."
        case .zoneMissing: "Open Coucou on your Mac: your sessions will show up here."
        case .failed(let message): message
        case .ready: "No session yet. Start Claude Code, Cursor or Codex on your Mac."
        }
    }
}

/// Today, as this iPhone saw it: turns finished, files and lines changed,
/// commands you answered. Counted on the iPhone, never sent anywhere.
extension View {
    /// A card standing alone in its section, edge to edge of the section, no row chrome.
    func homeCardRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}

struct TodayCard: View {
    let link: PhoneLink

    private var decisionsToday: Int {
        link.history.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    private struct Figure: Identifiable {
        let snapshot: ServiceSnapshot
        let stat: DetailStat
        var id: String { snapshot.pillId }
    }

    /// Each service's day in a figure (from the Mac), in the services' order.
    private var serviceFigures: [Figure] {
        PillCatalog.phoneServices.compactMap { id in
            guard let snapshot = link.services[id], let stat = snapshot.today?.first else { return nil }
            return Figure(snapshot: snapshot, stat: stat)
        }
    }

    static func hasContent(_ link: PhoneLink) -> Bool {
        !link.archive.currentTally.isEmpty || link.history.contains { Calendar.current.isDateInToday($0.date) }
            || link.services.values.contains { $0.today != nil } || !RecentFeed.entries(link).isEmpty
    }

    var body: some View {
        let tally = link.archive.currentTally
        let figures = serviceFigures
        let latest = RecentFeed.entries(link)
        if !tally.isEmpty || decisionsToday > 0 || !figures.isEmpty || !latest.isEmpty {
            VStack(spacing: 12) {
                if !tally.isEmpty || decisionsToday > 0 {
                    HStack(spacing: 0) {
                        stat("\(tally.turns)", tally.turns == 1 ? "turn" : "turns")
                        stat("\(tally.files)", tally.files == 1 ? "file" : "files")
                        VStack(spacing: 2) {
                            HStack(spacing: 4) {
                                Text("+\(tally.added)").foregroundStyle(.green)
                                Text("−\(tally.removed)").foregroundStyle(.red)
                            }
                            .font(.headline.monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            Text("lines").font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        stat("\(decisionsToday)", decisionsToday == 1 ? "OK given" : "OKs given")
                    }
                }
                if !figures.isEmpty {
                    if !tally.isEmpty || decisionsToday > 0 { Divider().padding(.horizontal, 14) }
                    // The services' day: money in, deploys, meetings… one chip each, tap to open.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(figures) { figure in
                                Button { link.openPillId = figure.snapshot.pillId } label: {
                                    chip(figure.snapshot, figure.stat)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .scrollClipDisabled()
                }
                if !latest.isEmpty {
                    Divider().padding(.horizontal, 14)
                    RecentFeed(link: link, entries: latest)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 14)
            .glassCard()
        }
    }

    private func chip(_ snapshot: ServiceSnapshot, _ stat: DetailStat) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: snapshot.color)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(stat.value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(stat.tone == .idle ? Color.primary : stat.tone.color)
                    .lineLimit(1)
                Text("\(snapshot.name) · \(stat.label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The services that want a look (something failed, something waits on you, or news), each with
/// why, in a line. Nothing at all when every service is fine.
struct AttentionCard: View {
    let link: PhoneLink

    static func flagged(_ link: PhoneLink) -> [ServiceSnapshot] {
        PillCatalog.phoneServices.compactMap { link.services[$0] }
            .filter { $0.tone == .error || $0.tone == .warning }
            .sorted { ($0.tone == .error ? 0 : 1) < ($1.tone == .error ? 0 : 1) }
    }

    var body: some View {
        let list = Self.flagged(link)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(list, id: \.pillId) { snapshot in
                    Button { link.openPillId = snapshot.pillId } label: {
                        HStack(spacing: 12) {
                            Circle().fill(snapshot.tone.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(snapshot.name).font(.callout.weight(.semibold))
                                    Text(snapshot.tone.label).font(.caption.weight(.semibold)).foregroundStyle(snapshot.tone.color)
                                }
                                Text(snapshot.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassCard()
        }
    }
}

/// What happened lately, every source together (your OKs, payments, deploys, runs, meetings…),
/// newest first. Tap a line to open where it comes from.
struct RecentFeed: View {
    let link: PhoneLink
    let entries: [Entry]

    struct Entry: Identifiable {
        let id: String
        let pillId: String
        let title: String
        let detail: String
        let date: Date
        let color: Color
        let symbol: String?
    }

    static func entries(_ link: PhoneLink) -> [Entry] {
        var all: [Entry] = link.history.prefix(10).map { log in
            Entry(id: "decision-\(log.id)", pillId: log.pillId,
                  title: log.decision == .allow ? "Allowed" : "Denied",
                  detail: log.summary, date: log.date,
                  color: log.decision == .allow ? .green : .red,
                  symbol: log.decision == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
        }
        for (pillId, snapshot) in link.services {
            for section in snapshot.sections {
                for (index, item) in section.items.enumerated() {
                    guard let date = item.date, date <= Date() else { continue }
                    all.append(Entry(id: "\(pillId)-\(section.title)-\(index)", pillId: pillId,
                                     title: item.title, detail: "\(snapshot.name) · \(item.detail)",
                                     date: date, color: item.tone == .idle ? .secondary : item.tone.color, symbol: nil))
                }
            }
        }
        return Array(all.sorted { $0.date > $1.date }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
                ForEach(entries) { entry in
                    Button { link.openPillId = entry.pillId } label: {
                        HStack(spacing: 10) {
                            if let symbol = entry.symbol {
                                Image(systemName: symbol).foregroundStyle(entry.color).frame(width: 16)
                            } else {
                                Circle().fill(entry.color).frame(width: 7, height: 7).frame(width: 16)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(entry.date, format: .relative(presentation: .named))
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Botan in the corner of Mochi's card: its antenna, orange when it is linked, gray while
/// looking for it. Nothing when the switch is off.
struct BotanAntenna: View {
    @AppStorage(BotanBridge.enabledKey) private var enabled = false
    private var bridge: BotanBridge { BotanBridge.shared }

    private var linked: Bool {
        if case .linked = bridge.status { return true }
        return false
    }

    var body: some View {
        if enabled {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: linked)
                Text("Botan")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(linked ? Color.botan : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: Capsule())
            .accessibilityLabel(linked ? "Botan is linked" : "Looking for Botan")
        }
    }
}

/// On top of every tab while the demo shows: sample data, and the way back to yours.
struct DemoBar: View {
    let link: PhoneLink

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Color.botan)
            Text("Demo · sample agents and services")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Leave") {
                withAnimation { Demo.stop(link) }
                Haptics.impact()
            }
            .font(.footnote.weight(.semibold))
            .tint(Color.botan)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassPill(Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
