import SwiftUI
import AppKit
import Combine

// The GitLab merge request panel on the Mac: a small see-through window against the
// right edge of the island's screen, a slim bar of icons that unfolds on hover into
// a card with four folding sections — comments waiting for you, to review, mine,
// approved. A thread opens in place with the code it is about and can be answered,
// resolved or opened again from here; approving is left to GitLab, where the code
// is. What the data means is in GitLabDash.swift, what is read in
// GitLabPanelService.swift. Same behaviour as windows/src/gitlab-panel.

// MARK: - Model

@MainActor
final class GitLabPanelModel: ObservableObject {
    static let shared = GitLabPanelModel()

    static let slimWidth: CGFloat = 52
    static let cardWidth: CGFloat = 340
    /// How far below the top of the screen's visible area the panel starts.
    static let topGap: CGFloat = 80

    @Published private(set) var dashboard: GitLabDashboard?
    @Published private(set) var state: GitLabPanelState
    @Published private(set) var expanded = false
    /// The thread open in place, if any.
    @Published var openThread: String?
    /// Threads resolved from here, kept (dimmed) so they can be opened again.
    @Published private(set) var resolved: [GitLabThread] = []
    @Published private(set) var snippets: [String: [GitLabSnippetLine]] = [:]
    @Published var drafts: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var sending: Set<String> = []
    /// Sections whose tile pulses in the slim bar: something new arrived.
    @Published private(set) var pulsing: Set<GitLabSection> = []
    /// How tall the content is: the window follows it.
    @Published var contentHeight: CGFloat = 230

    private var pointerInside = false
    private var replyFocus = Set<String>()
    private var hoverWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private static let defaultsKey = "gitlabPanelState"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode(GitLabPanelState.self, from: data) {
            state = saved
        } else {
            state = GitLabPanelState()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Data

    /// New data from the service.
    func receive(_ dash: GitLabDashboard?) {
        let before = dashboard.map { state.newCount(.comments, dash: $0) } ?? 0
        dashboard = dash
        guard let dash else { return }
        state = state.receiving(dash)
        persist()
        // A new comment while the panel is folded: its tile pulses, nothing unfolds by itself.
        if !expanded && state.newCount(.comments, dash: dash) > before { pulse(.comments) }
    }

    private func pulse(_ section: GitLabSection) {
        pulsing.insert(section)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.pulsing.remove(section) }
        }
    }

    /// The panel was closed: what was only kept for a moment goes.
    func closed() {
        resolved = []
        openThread = nil
        pointerInside = false
        clearTimers()
    }

    /// The panel was opened: always as the slim bar, like the island at rest.
    func opened() {
        expanded = false
        contentHeight = 230
    }

    // MARK: Folded or unfolded

    func setExpanded(_ on: Bool) {
        guard expanded != on else { return }
        expanded = on
        contentHeight = on ? 260 : 230
        clearTimers()
        if on && !pointerInside { armCollapse() }
    }

    /// The pointer is on the panel: the slim bar unfolds after a moment, and the card
    /// does not fold meanwhile.
    func pointerEntered() {
        pointerInside = true
        collapseWork?.cancel()
        if !expanded {
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.setExpanded(true) } }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    func pointerLeft() {
        pointerInside = false
        hoverWork?.cancel()
        if expanded { armCollapse() }
    }

    private func clearTimers() {
        hoverWork?.cancel()
        collapseWork?.cancel()
    }

    /// Folds again once the pointer has been away for the island's auto-close delay.
    private func armCollapse() {
        collapseWork?.cancel()
        let delay = AppState.shared.autoCloseInterval
        guard delay > 0 else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.tryCollapse() } }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A reply being written is never lost to a fold: it waits for the next delay.
    private func tryCollapse() {
        guard expanded, !pointerInside else { return }
        if hasDraft { armCollapse(); return }
        setExpanded(false)
    }

    private var hasDraft: Bool {
        !replyFocus.isEmpty || drafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func setReplyFocus(_ id: String, _ focused: Bool) {
        if focused { replyFocus.insert(id) } else { replyFocus.remove(id) }
    }

    // MARK: Sections and threads

    func toggleSection(_ s: GitLabSection) {
        state = state.toggling(s, dash: dashboard)
        persist()
    }

    /// A tile of the slim bar: unfolds the panel with its section open.
    func openSection(_ s: GitLabSection) {
        if !state.isOpen(s) { toggleSection(s) }
        setExpanded(true)
    }

    func toggleThread(_ th: GitLabThread) {
        openThread = openThread == th.id ? nil : th.id
        guard openThread == th.id, th.position != nil, snippets[th.id] == nil else { return }
        GitLabPanelService.shared.snippet(for: th) { [weak self] lines in
            self?.snippets[th.id] = lines ?? []
        }
    }

    /// The thread leaves the list at once (the service confirms with the next read).
    func drop(thread id: String) {
        guard let d = dashboard else { return }
        var next = d
        next.comments.removeAll { $0.id == id }
        dashboard = next
        drafts[id] = nil
        if openThread == id { openThread = nil }
    }

    func reply(_ th: GitLabThread) {
        let text = (drafts[th.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending.contains(th.id) else { return }
        sending.insert(th.id)
        errors[th.id] = nil
        GitLabPanelService.shared.reply(to: th, body: text) { [weak self] error in
            guard let self else { return }
            self.sending.remove(th.id)
            // The draft stays in its box when it did not go.
            if let error { self.errors[th.id] = GitLabPanelModel.message(for: error) }
        }
    }

    func resolve(_ th: GitLabThread, _ resolve: Bool) {
        guard !sending.contains(th.id) else { return }
        sending.insert(th.id)
        errors[th.id] = nil
        GitLabPanelService.shared.resolve(th, resolved: resolve) { [weak self] error in
            guard let self else { return }
            self.sending.remove(th.id)
            if let error {
                self.errors[th.id] = GitLabPanelModel.message(for: error)
            } else if resolve {
                // Rust-side the list already dropped it: keep it here, dimmed, to reopen.
                if !self.resolved.contains(where: { $0.id == th.id }) { self.resolved.append(th) }
            } else {
                self.resolved.removeAll { $0.id == th.id }
            }
        }
    }

    /// Why a reply or a resolve did not go through, in the user's words.
    static func message(for error: GitLabSendError) -> String {
        switch error {
        case "forbidden": return String(localized: "This token is read-only: add the api scope to reply")
        case "network":   return String(localized: "Could not reach GitLab. Your text is kept.")
        case "not_found": return String(localized: "This thread no longer exists.")
        case "no_token":  return String(localized: "No GitLab token.")
        case "empty":     return ""
        default:          return String(localized: "GitLab refused it. Your text is kept.")
        }
    }

    func open(_ url: String) {
        guard let base = dashboard?.baseURL,
              let safe = GitLabPanelText.safeInstanceURL(url, base: base) else { return }
        NSWorkspace.shared.open(safe)
    }
}

// MARK: - Window

/// Tells the model when the pointer is on the panel. A tracking area rather than
/// SwiftUI's onHover, which stays silent while the app is not the active one.
private final class GitLabHostingView<Content: View>: NSHostingView<Content> {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { GitLabPanelModel.shared.pointerEntered() }
    override func mouseExited(with event: NSEvent) { GitLabPanelModel.shared.pointerLeft() }
}

private final class GitLabNSPanel: NSPanel {
    // A reply is typed into it, so it can take the keyboard — without activating the app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's window: against the right edge of the island's screen, sized by its
/// content, like the island it is not moved by hand.
@MainActor
final class GitLabPanelController {
    static let shared = GitLabPanelController()

    private let model = GitLabPanelModel.shared
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private(set) var isOpen = false

    private init() {
        // Unfolding, folding, a taller content: the window follows.
        model.$expanded.sink { _ in GitLabPanelController.replaceSoon() }.store(in: &cancellables)
        model.$contentHeight.sink { _ in GitLabPanelController.replaceSoon() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .islandScreenChanged)
            .sink { _ in GitLabPanelController.replaceSoon() }.store(in: &cancellables)
    }

    /// Published values change just before they are stored: placing waits a turn.
    private nonisolated static func replaceSoon() {
        DispatchQueue.main.async { MainActor.assumeIsolated { GitLabPanelController.shared.place() } }
    }

    private func makePanel() -> NSPanel {
        let p = GitLabNSPanel(contentRect: NSRect(x: 0, y: 0, width: GitLabPanelModel.slimWidth, height: 230),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = GitLabHostingView(rootView: GitLabPanelRootView(model: model))
        host.sizingOptions = []
        p.contentView = host
        return p
    }

    /// The "panel" button of the GitLab card: opens the slim bar, or closes the panel.
    func toggle() {
        if isOpen { close() } else { open() }
    }

    private func open() {
        guard AppState.shared.activeIntegrations.contains(GitLabPanelService.pillId),
              KeychainStore.shared.get("gitlab-token") != nil else { return }
        let p = panel ?? makePanel()
        panel = p
        model.opened()
        isOpen = true
        place()
        p.orderFrontRegardless()
        GitLabPanelService.shared.refreshNow()
    }

    func close() {
        guard isOpen || panel != nil else { return }
        isOpen = false
        panel?.orderOut(nil)
        model.closed()
    }

    /// Sizes the window for the mode and the content's height and puts it flat against
    /// the right edge of the island's screen, a little below the top.
    private func place() {
        guard isOpen, let panel else { return }
        let visible = IslandWindowController.islandScreen().visibleFrame
        let width = model.expanded ? GitLabPanelModel.cardWidth : GitLabPanelModel.slimWidth
        let room = visible.height - GitLabPanelModel.topGap - 8
        let minHeight: CGFloat = model.expanded ? 160 : 80
        let height = min(max(model.contentHeight + 2, minHeight), max(room, minHeight))
        let y = max(visible.minY, visible.maxY - GitLabPanelModel.topGap - height)
        panel.setFrame(NSRect(x: visible.maxX - width, y: y, width: width, height: height), display: true)
    }
}

// MARK: - Views

/// A rounded card flat against the right edge: only its left corners are round.
private struct LeftRounded: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2, rect.width)
        var p = Path()
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private enum GLStyle {
    static let bg = Color(hex: "#0F1013")
    static let card = Color(hex: "#17181C")
    static let card2 = Color(hex: "#1D1F24")
    static let ink = Color(hex: "#F5F6F8")
    static let ink2 = Color(hex: "#C9CCD2")
    static let dim = Color(hex: "#9398A1")
    static let dim3 = Color(hex: "#6B7079")
    static let line = Color.white.opacity(0.07)
    static let orange = Color(hex: "#FC6D26")
}

struct GitLabPanelRootView: View {
    @ObservedObject var model: GitLabPanelModel

    var body: some View {
        let radius: CGFloat = model.expanded ? 16 : 26
        VStack(spacing: 0) {
            if model.expanded {
                GitLabCardView(model: model)
            } else {
                GitLabSlimView(model: model)
            }
        }
        .frame(width: model.expanded ? GitLabPanelModel.cardWidth : GitLabPanelModel.slimWidth,
               alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LeftRounded(radius: radius).fill(GLStyle.bg))
        .overlay(LeftRounded(radius: radius).stroke(Color.white.opacity(0.09), lineWidth: 1))
        .clipShape(LeftRounded(radius: radius))
        .preferredColorScheme(.dark)
    }
}

/// The logo tile of the header and the slim bar.
private struct GitLabLogo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [Color(hex: "#FF8A4C"), GLStyle.orange],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().fill(Color(hex: "#0B0B0D")).frame(width: 6, height: 6)
        }
        .frame(width: 20, height: 20)
        .shadow(color: GLStyle.orange.opacity(0.35), radius: 4, y: 2)
    }
}

// MARK: Slim bar

private struct GitLabSlimView: View {
    @ObservedObject var model: GitLabPanelModel

    var body: some View {
        VStack(spacing: 9) {
            GitLabLogo()
            ForEach(GitLabSection.order, id: \.self) { section in
                tile(section)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(heightReader(model))
    }

    private func tile(_ section: GitLabSection) -> some View {
        let accent = Color(hex: section.accentHex)
        let dash = model.dashboard
        let total = dash.map { section.count($0) } ?? 0
        let fresh = dash.map { model.state.newCount(section, dash: $0) } ?? 0
        let waiting = dash.map { section.waiting($0) } ?? false
        let pulsing = model.pulsing.contains(section)
        return Button(action: { model.openSection(section) }) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 13)
                    .fill(accent.opacity(waiting ? 0.22 : 0.14))
                    .overlay(RoundedRectangle(cornerRadius: 13)
                        .stroke(accent.opacity(waiting ? 0.55 : 0), lineWidth: 1))
                    .shadow(color: accent.opacity(waiting ? 0.38 : 0), radius: 7)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: section.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accent))
                if fresh > 0 {
                    Text("+\(fresh)")
                        .font(.system(size: 9.5, weight: .heavy))
                        .monospacedDigit()
                        .foregroundColor(Color(hex: "#0B0B0D"))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 17, minHeight: 16)
                        .background(Capsule().fill(accent))
                        .overlay(Capsule().stroke(GLStyle.bg, lineWidth: 2))
                        .offset(x: 8, y: -6)
                }
            }
            .scaleEffect(pulsing ? 1.15 : 1)
            .animation(pulsing ? Animation.easeInOut(duration: 0.45).repeatCount(6, autoreverses: true)
                               : Animation.default,
                       value: pulsing)
        }
        .buttonStyle(.plain)
        .help("\(section.title) · \(total)")
    }
}

/// Reports the content's height to the model, which sizes the window with it.
private func heightReader(_ model: GitLabPanelModel) -> some View {
    GeometryReader { geo in
        Color.clear
            .onAppear { report(geo.size.height, model) }
            .onChange(of: geo.size.height) { _, h in report(h, model) }
    }
}

private func report(_ height: CGFloat, _ model: GitLabPanelModel) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            if abs(model.contentHeight - height) > 0.5 { model.contentHeight = height }
        }
    }
}

// MARK: Card

private struct GitLabCardView: View {
    @ObservedObject var model: GitLabPanelModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                header
                if let dash = model.dashboard {
                    VStack(spacing: 8) {
                        ForEach(GitLabSection.order, id: \.self) { section in
                            GitLabSectionView(model: model, dash: dash, section: section)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                } else {
                    Text("Loading…")
                        .font(.system(size: 11.5))
                        .foregroundColor(GLStyle.dim3)
                        .padding(14)
                }
            }
            .background(heightReader(model))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            GitLabLogo()
            Text("GitLab").font(.system(size: 13, weight: .semibold)).foregroundColor(GLStyle.ink)
            Spacer(minLength: 4)
            iconButton("arrow.down.right.and.arrow.up.left", help: String(localized: "Fold the panel")) {
                model.setExpanded(false)
            }
            iconButton("xmark", help: String(localized: "Close")) {
                GitLabPanelController.shared.close()
            }
        }
        .frame(height: 42)
        .padding(.leading, 14)
        .padding(.trailing, 10)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(GLStyle.dim)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct GitLabSectionView: View {
    @ObservedObject var model: GitLabPanelModel
    let dash: GitLabDashboard
    let section: GitLabSection

    var body: some View {
        let accent = Color(hex: section.accentHex)
        let open = model.state.isOpen(section)
        let waiting = section.waiting(dash)
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeOut(duration: 0.14)) { model.toggleSection(section) } }) {
                HStack(spacing: 8) {
                    Image(systemName: section.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(accent)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 9).fill(accent.opacity(0.16)))
                    Text(section.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(GLStyle.ink)
                    Spacer(minLength: 4)
                    let fresh = model.state.newCount(section, dash: dash)
                    if fresh > 0 {
                        Text("+\(fresh)")
                            .font(.system(size: 10.5, weight: .heavy)).monospacedDigit()
                            .foregroundColor(Color(hex: "#0B0B0D"))
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Capsule().fill(accent))
                    }
                    Text("\(section.count(dash))")
                        .font(.system(size: 11, weight: waiting ? .bold : .regular)).monospacedDigit()
                        .foregroundColor(waiting ? GLStyle.ink : GLStyle.dim)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(waiting ? accent.opacity(0.2) : Color.white.opacity(0.07)))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(GLStyle.dim3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.leading, 8).padding(.trailing, 10)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(spacing: 2) { rows }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(GLStyle.card))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(waiting ? accent.opacity(0.45) : GLStyle.line, lineWidth: 1))
        .shadow(color: accent.opacity(waiting ? 0.1 : 0), radius: 8, y: 4)
    }

    @ViewBuilder private var rows: some View {
        switch section {
        case .comments:
            let threads = model.resolved + dash.comments.filter { c in !model.resolved.contains { $0.id == c.id } }
            if threads.isEmpty { emptyRow }
            ForEach(threads) { th in
                GitLabThreadView(model: model, dash: dash, thread: th,
                                 done: model.resolved.contains { $0.id == th.id })
            }
        case .toReview: mrRows(dash.toReview, mine: false)
        case .mine:     mrRows(dash.mine, mine: true)
        case .approved: mrRows(dash.approved, mine: false)
        }
    }

    @ViewBuilder private func mrRows(_ list: [GitLabMR], mine: Bool) -> some View {
        if list.isEmpty { emptyRow }
        ForEach(list) { mr in GitLabMRRow(model: model, mr: mr, mine: mine) }
    }

    private var emptyRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(GLStyle.dim3)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.06)))
            Text("Nothing here").font(.system(size: 11.5)).foregroundColor(GLStyle.dim3)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }
}

// MARK: Pieces

/// A small rounded label.
private struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = GLStyle.dim
    var fill: Color = Color.white.opacity(0.07)

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 7.5, weight: .bold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
        .foregroundColor(tint)
        .padding(.horizontal, 6).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 7).fill(fill))
    }
}

/// A round icon for a pipeline: ✓ passed, ✕ failed, a clock while it runs, a ring when unknown.
private struct CIBadge: View {
    let ci: CIState

    private var color: Color {
        switch ci {
        case .success: return Color(hex: "#22C55E")
        case .failure: return Color(hex: "#F4505E")
        case .pending: return Color(hex: "#F5A524")
        case .unknown: return Color(hex: "#6B7079")
        }
    }

    private var symbol: String? {
        switch ci {
        case .success: return "checkmark"
        case .failure: return "xmark"
        case .pending: return "clock.fill"
        case .unknown: return nil
        }
    }

    var body: some View {
        ZStack {
            if ci == .unknown {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 1.5)
            } else {
                Circle().fill(color.opacity(0.18))
            }
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8, weight: .heavy)).foregroundColor(color)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// A round avatar: the initials of a person, in a colour that is theirs.
private struct Avatar: View {
    let name: String
    let username: String
    var size: CGFloat = 22

    var body: some View {
        let hue = Double(GitLabPanelText.avatarHue(username.isEmpty ? name : username)) / 360
        Text(GitLabPanelText.initials(name))
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(LinearGradient(
                colors: [Color(hue: hue, saturation: 0.6, brightness: 0.78),
                         Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.62, brightness: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
    }
}

private struct GitLabMRRow: View {
    @ObservedObject var model: GitLabPanelModel
    let mr: GitLabMR
    let mine: Bool

    var body: some View {
        Button(action: { model.open(mr.url) }) {
            HStack(spacing: 9) {
                CIBadge(ci: mr.ci)
                VStack(alignment: .leading, spacing: 3) {
                    Text(mr.title).font(.system(size: 12)).foregroundColor(GLStyle.ink).lineLimit(1)
                    HStack(spacing: 5) {
                        Chip(text: GitLabPanelText.shortProject(mr.project), tint: GLStyle.ink2)
                            .help(mr.project)
                        Text("!\(mr.iid)").font(.system(size: 10.5)).monospacedDigit().foregroundColor(GLStyle.dim)
                        if mr.isDraft { Chip(text: String(localized: "Draft"), tint: GLStyle.dim3,
                                             fill: Color.white.opacity(0.05)) }
                        if mine, let a = GitLabPanelText.approvals(mr.approvals) {
                            Chip(text: a, symbol: "checkmark", tint: Color(hex: "#22C55E"),
                                 fill: Color(hex: "#22C55E").opacity(0.16))
                                .help(String(localized: "Approvals"))
                        }
                        if mine, let n = mr.unresolved, n > 0 {
                            Chip(text: "\(n)", symbol: "bubble.left.fill", tint: Color(hex: "#F5A524"),
                                 fill: Color(hex: "#F5A524").opacity(0.16))
                                .help(String(localized: "Unresolved threads"))
                        }
                    }
                }
                Spacer(minLength: 4)
                Text(GitLabPanelText.age(ms: mr.updatedAt))
                    .font(.system(size: 10.5)).monospacedDigit().foregroundColor(GLStyle.dim3)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0)))
    }
}

// MARK: Threads

private struct GitLabThreadView: View {
    @ObservedObject var model: GitLabPanelModel
    let dash: GitLabDashboard
    let thread: GitLabThread
    let done: Bool

    var body: some View {
        let open = model.openThread == thread.id
        let last = thread.notes.last
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeOut(duration: 0.14)) { model.toggleThread(thread) } }) {
                HStack(spacing: 9) {
                    if let last { Avatar(name: last.author, username: last.username).opacity(done ? 0.5 : 1) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(GitLabPanelText.preview(thread))
                            .font(.system(size: 12)).foregroundColor(GLStyle.ink).lineLimit(1)
                            .strikethrough(done)
                            .opacity(done ? 0.5 : 1)
                        HStack(spacing: 5) {
                            Chip(text: GitLabPanelText.shortProject(thread.project), tint: GLStyle.ink2)
                                .help(thread.project)
                            Text("!\(thread.mrIid)").font(.system(size: 10.5)).monospacedDigit().foregroundColor(GLStyle.dim)
                            if done {
                                Chip(text: String(localized: "Resolved"), symbol: "checkmark",
                                     tint: Color(hex: "#22C55E"), fill: Color(hex: "#22C55E").opacity(0.16))
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if let last {
                        Text(GitLabPanelText.age(ms: last.createdAt))
                            .font(.system(size: 10.5)).monospacedDigit().foregroundColor(GLStyle.dim3)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            if open {
                GitLabThreadDetail(model: model, dash: dash, thread: thread, done: done)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(open ? GLStyle.card2 : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(open ? GLStyle.line : Color.clear, lineWidth: 1))
        .padding(.vertical, open ? 2 : 0)
    }
}

private struct GitLabThreadDetail: View {
    @ObservedObject var model: GitLabPanelModel
    let dash: GitLabDashboard
    let thread: GitLabThread
    let done: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Text(thread.mrRef)
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(GLStyle.ink2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                Text(thread.mrTitle).font(.system(size: 11)).foregroundColor(GLStyle.dim).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: { model.open(GitLabPanelText.noteURL(thread)) }) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(GLStyle.ink2)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Open in GitLab"))
            }
            if let position = thread.position { code(position) }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(thread.notes) { note in noteView(note) }
            }
            if done { reopenBar } else { replyBar }
        }
        .padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 2)
        .onChange(of: focused) { _, now in model.setReplyFocus(thread.id, now) }
    }

    private func code(_ position: GitLabCodePosition) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(position.file):\(position.line)")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(GLStyle.dim)
                .padding(.horizontal, 10).padding(.vertical, 4)
            Divider().overlay(GLStyle.line)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.snippets[thread.id] ?? []) { l in
                        HStack(spacing: 10) {
                            Text("\(l.number)").frame(minWidth: 26, alignment: .trailing).foregroundColor(GLStyle.dim3)
                            Text(l.text.isEmpty ? " " : l.text).foregroundColor(GLStyle.ink2)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 10)
                        .background(l.target ? GLStyle.orange.opacity(0.18) : Color.clear)
                        .overlay(alignment: .leading) {
                            if l.target { Rectangle().fill(GLStyle.orange).frame(width: 2) }
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(GLStyle.bg))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(GLStyle.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func noteView(_ note: GitLabThreadNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(name: note.author, username: note.username, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(note.isMe ? String(localized: "You") : note.author)
                        .font(.system(size: 10.5, weight: .semibold)).foregroundColor(GLStyle.ink2)
                    Text(GitLabPanelText.age(ms: note.createdAt))
                        .font(.system(size: 10.5)).foregroundColor(GLStyle.dim3)
                }
                ChatMarkdownView(markdown: note.body)
                    .foregroundColor(GLStyle.ink2)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(note.isMe ? GLStyle.orange.opacity(0.1) : Color.white.opacity(0.04)))
        }
    }

    private var busy: Bool { model.sending.contains(thread.id) }

    private var reopenBar: some View {
        HStack(spacing: 6) {
            pill(String(localized: "Reopen"), primary: false) { model.resolve(thread, false) }
            errorText
        }
    }

    private var replyBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            if dash.canWrite == false {
                Text(GitLabPanelModel.message(for: "forbidden"))
                    .font(.system(size: 11)).foregroundColor(GLStyle.dim)
            } else {
                TextField(String(localized: "Write a reply…"),
                          text: Binding(get: { model.drafts[thread.id] ?? "" },
                                        set: { model.drafts[thread.id] = $0 }),
                          axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .font(.system(size: 12))
                    .foregroundColor(GLStyle.ink)
                    .focused($focused)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(GLStyle.bg))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .stroke(focused ? GLStyle.orange.opacity(0.7) : GLStyle.line, lineWidth: 1))
                errorText
                HStack(spacing: 6) {
                    pill(String(localized: "Send"), primary: true) { model.reply(thread) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(busy || (model.drafts[thread.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if thread.resolvable {
                        pill(String(localized: "Resolve"), primary: false) { model.resolve(thread, true) }
                            .disabled(busy)
                    }
                }
            }
        }
    }

    @ViewBuilder private var errorText: some View {
        if let e = model.errors[thread.id], !e.isEmpty {
            Text(e).font(.system(size: 11)).foregroundColor(Color(hex: "#F4505E"))
        }
    }

    private func pill(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundColor(primary ? Color(hex: "#0B0B0D") : GLStyle.ink2)
                .padding(.horizontal, 13).padding(.vertical, 5)
                .background(Capsule().fill(primary
                    ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "#FF8A4C"), GLStyle.orange],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                    : AnyShapeStyle(Color.white.opacity(0.08))))
        }
        .buttonStyle(.plain)
    }
}
