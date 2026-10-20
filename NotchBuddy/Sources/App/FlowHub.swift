#if !APPSTORE
import AppKit
import Carbon
import SwiftUI

/// The pages of the Coucou window: Flow (the dictation, the Notetaker) and the notch's settings.
enum HubPage: String, CaseIterable, Identifiable {
    case dictation, notes, insights, dictionary, snippets, styles, settings
    case general, pills, agents, chat, integrations, voice, shortcuts

    var id: String { rawValue }

    static let flowPages: [HubPage] = [.dictation, .notes, .insights, .dictionary, .snippets, .styles, .settings]
    static let notchPages: [HubPage] = [.general, .pills, .agents, .chat, .integrations, .voice, .shortcuts]

    /// The section of Settings this page shows, for the notch's pages.
    var settingsSection: String? {
        switch self {
        case .general:      return "general"
        case .pills:        return "activepills"
        case .agents:       return "agents"
        case .chat:         return "chat"
        case .integrations: return "integrations"
        case .voice:        return "voice"
        case .shortcuts:    return "shortcuts"
        default:            return nil
        }
    }

    /// The page showing a section of Settings ("chat", "voice"…).
    static func forSettings(_ section: String) -> HubPage {
        notchPages.first { $0.settingsSection == section } ?? .general
    }

    var title: String {
        switch self {
        case .general:      return String(localized: "General")
        case .pills:        return String(localized: "Active pills")
        case .agents:       return String(localized: "Agents")
        case .chat:         return String(localized: "Chat")
        case .integrations: return String(localized: "Integrations")
        case .voice:        return String(localized: "Voice")
        case .shortcuts:    return String(localized: "Shortcuts")
        case .dictation:  return String(localized: "hub.page.dictation")
        case .notes:      return String(localized: "hub.page.notes")
        case .insights:   return String(localized: "hub.page.insights")
        case .dictionary: return String(localized: "hub.page.dictionary")
        case .snippets:   return String(localized: "hub.page.snippets")
        case .styles:     return String(localized: "hub.page.styles")
        case .settings:   return String(localized: "hub.page.settings")
        }
    }

    var symbol: String {
        switch self {
        case .dictation:  return "mic"
        case .notes:      return "record.circle"
        case .insights:   return "chart.bar"
        case .dictionary: return "book.closed"
        case .snippets:   return "bolt"
        case .styles:     return "textformat"
        case .settings:   return "slider.horizontal.3"
        case .general:      return "gearshape"
        case .pills:        return "square.grid.2x2"
        case .agents:       return "terminal"
        case .chat:         return "bubble.left.and.bubble.right"
        case .integrations: return "puzzlepiece.extension"
        case .voice:        return "waveform"
        case .shortcuts:    return "keyboard"
        }
    }
}

/// The colors of the Coucou Flow window: the island's dark, with Coucou's orange.
enum HubTheme {
    /// OLED black: the window and the sidebar.
    static let window = Color.black
    static let sidebar = Color.black
    /// The big card on the right, where the pages are.
    static let panel = Color(hex: "#0E0F11")
    static let card = Color(hex: "#18191C")
    static let field = Color(hex: "#1F2024")
    static let line = Color.white.opacity(0.07)
    static let text = Color(hex: "#F5F6F8")
    static let body = Color(hex: "#E1E3E6")
    static let secondary = Color(hex: "#8E939C")
    static let muted = Color(hex: "#6B7079")
    static let accent = Color(hex: "#FB923C")
    static let onAccent = Color(hex: "#170C04")
    static let green = Color(hex: "#34D399")
    static let red = Color(hex: "#FF453A")
    /// One color per person in a call: you first, then the others.
    static let speakers: [Color] = ["#3B9EFF", "#34D399", "#A78BFA", "#F7B32B", "#F472B6", "#22D3EE"].map { Color(hex: $0) }

    static func speaker(_ index: Int) -> Color { speakers[max(0, index) % speakers.count] }
}

private struct HubPageKey: EnvironmentKey {
    static let defaultValue: HubPage = .dictation
}

extension EnvironmentValues {
    /// The page shown, for the colour and the Mochis of its top band.
    var hubPage: HubPage {
        get { self[HubPageKey.self] }
        set { self[HubPageKey.self] = newValue }
    }
}

extension HubPage {
    /// The line under the title of the notch's pages.
    static func notchSubtitle(_ page: HubPage) -> String? {
        switch page {
        case .general:      return String(localized: "hub.notch.general")
        case .pills:        return String(localized: "hub.notch.pills")
        case .agents:       return String(localized: "hub.notch.agents")
        case .chat:         return String(localized: "hub.notch.chat")
        case .integrations: return String(localized: "hub.notch.integrations")
        case .voice:        return String(localized: "hub.notch.voice")
        case .shortcuts:    return String(localized: "hub.notch.shortcuts")
        default:            return nil
        }
    }
}

@MainActor
final class HubRouter: ObservableObject {
    @Published var page: HubPage = .dictation
}

/// Opens the Coucou Flow window: the history of the dictations, the Notetaker, the numbers, the
/// dictionary, the snippets, the styles and the settings of the dictation.
@MainActor
final class FlowHubController {
    static let shared = FlowHubController()
    let router = HubRouter()
    let windowState = HubWindowState()
    private var window: NSWindow?

    static let showInDockKey = "coucouShowInDock"
    static let openAtLaunchKey = "coucouOpenAtLaunch"

    /// Coucou in the Dock, like a regular app (on by default in the GitHub build).
    static var showInDock: Bool {
        get { UserDefaults.standard.object(forKey: showInDockKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: showInDockKey)
            NSApp.setActivationPolicy(newValue ? .regular : .accessory)
            if newValue { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    /// The window opens when Coucou is opened by hand (never at login).
    static var openAtLaunch: Bool {
        get { UserDefaults.standard.object(forKey: openAtLaunchKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: openAtLaunchKey) }
    }

    /// Whether macOS opened Coucou at login, rather than you from the Finder, the Dock or Spotlight.
    static func launchedAtLogin() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        // A login item started by launchd may come without that flag: the first minutes after
        // the Mac starts count as a login.
        return ProcessInfo.processInfo.systemUptime < 180
    }

    func show(_ page: HubPage? = nil) {
        if let page { router.page = page }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Coucou"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .black
        win.contentView = NSHostingView(rootView: FlowHubView(router: router, windowState: windowState))
        windowState.watch(win)
        win.contentMinSize = NSSize(width: 940, height: 600)
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("CoucouFlowWindow")
        if !win.setFrameUsingName("CoucouFlowWindow") { win.center() }
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct FlowHubView: View {
    @ObservedObject var router: HubRouter
    @ObservedObject var windowState: HubWindowState

    var body: some View {
        HStack(spacing: 0) {
            HubSidebar(router: router)
            // The pages sit in one big card, like Wispr Flow's window.
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(HubTheme.panel)
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
                .padding(.top, 10)
                .padding(.bottom, 10)
                .padding(.trailing, 10)
        }
        .background(HubTheme.window)
        .foregroundColor(HubTheme.text)
        .preferredColorScheme(.dark)
        .tint(HubTheme.accent)
        .environment(\.hubVisible, windowState.visible)
        .environment(\.hubPage, router.page)
    }

    @ViewBuilder private var page: some View {
        switch router.page {
        case .dictation:  HubHomePage(router: router)
        case .notes:      HubNotesPage()
        case .insights:   HubInsightsPage()
        case .dictionary: HubDictionaryPage()
        case .snippets:   HubSnippetsPage()
        case .styles:     HubStylesPage(router: router)
        case .settings:   HubSettingsPage()
        default:
            if let section = router.page.settingsSection {
                VStack(alignment: .leading, spacing: 0) {
                    HubHero(page: router.page, title: router.page.title, subtitle: HubPage.notchSubtitle(router.page))
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                    SettingsView(embeddedSection: section)
                        .id(section)
                }
            }
        }
    }
}

// MARK: - Sidebar

private struct HubSidebar: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var flow = FlowDictation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                // The scene draws Mochi a little below its middle (room for his
                // hops and hats): lifted so his body lines up with the name.
                HubLiveMochi(size: 28)
                    .offset(y: -4)
                Text(verbatim: "Coucou")
                    .font(.system(size: 18, weight: .bold))
            }
            .padding(.horizontal, 8)
            // Halfway between the window's buttons and "FLOW".
            .padding(.top, 25)
            .padding(.bottom, 31)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    HubSidebarHeader(text: "Flow")
                    ForEach(HubPage.flowPages) { page in
                        HubSidebarItem(page: page, selected: router.page == page) { router.page = page }
                    }
                    HubSidebarHeader(text: String(localized: "hub.section.notch"))
                        .padding(.top, 14)
                    ForEach(HubPage.notchPages) { page in
                        HubSidebarItem(page: page, selected: router.page == page) { router.page = page }
                    }
                }
            }
            .scrollIndicators(.never)
            status
                .padding(.top, 8)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .frame(width: 228)
        .frame(maxHeight: .infinity)
        .background(HubTheme.sidebar)
    }

    @ViewBuilder private var status: some View {
        let ready = flow.isEnabled && flow.trusted
        Button { router.page = .settings } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(ready ? HubTheme.green : (flow.isEnabled ? HubTheme.accent : HubTheme.muted))
                    .frame(width: 7, height: 7)
                Text(ready ? String(format: String(localized: "hub.status-ready %@"), flow.key.label)
                     : (flow.isEnabled ? String(localized: "hub.status-access") : String(localized: "hub.status-off")))
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#A4A9B1"))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(HubTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

/// "FLOW", "NOTCH": the small capitals above a group of pages.
private struct HubSidebarHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased(with: .current))
            .font(.system(size: 10.5, weight: .bold))
            .tracking(1.2)
            .foregroundColor(HubTheme.muted)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct HubSidebarItem: View {
    let page: HubPage
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundColor(selected ? HubTheme.text : Color(hex: "#B7BBC2"))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(selected ? 0.08 : (hover ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Shared pieces

/// Mochi as a small logo: the white body and its two eyes.
struct HubMochi: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.33, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(hex: "#C9CBD1")], startPoint: .top, endPoint: .bottom))
            HStack(spacing: size * 0.2) {
                Capsule().fill(Color(hex: "#1A1412")).frame(width: size * 0.11, height: size * 0.22)
                Capsule().fill(Color(hex: "#1A1412")).frame(width: size * 0.11, height: size * 0.22)
            }
        }
        .frame(width: size, height: size * 0.72)
    }
}

/// A page: its title, an optional line under it, and the content, scrolling.
struct HubPageScaffold<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @Environment(\.hubPage) private var page

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HubHero(page: page, title: title, subtitle: subtitle, trailing: trailing)
                content()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

extension HubPageScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
        self.content = content
    }
}

/// A dark rounded card.
struct HubCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
    }
}

/// "AUJOURD'HUI": the small capitals above a list.
struct HubLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased(with: .current))
            .font(.system(size: 11.5, weight: .bold))
            .tracking(1.3)
            .foregroundColor(HubTheme.muted)
    }
}

/// A row of a settings card: the label on the left, the control on the right.
struct HubRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 2)
    }
}

struct HubDivider: View {
    var body: some View { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
}

/// Orange (primary) or dark (secondary) button.
struct HubButtonStyle: ButtonStyle {
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: primary ? .bold : .semibold))
            .foregroundColor(primary ? HubTheme.onAccent : HubTheme.text)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(primary ? HubTheme.accent : Color(hex: "#1D1E22")))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(primary ? Color.clear : Color.white.opacity(0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

/// A small square icon button (copy, delete).
struct HubIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(hover ? HubTheme.text : Color(hex: "#A4A9B1"))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.1 : 0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hover = $0 }
    }
}

/// A text field drawn like the rest of the window.
struct HubField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
            .onSubmit(onSubmit)
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full (the dictionary's words).
struct HubWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension NSPasteboard {
    /// Copies plain text, as the copy buttons of the window do.
    @MainActor static func copyText(_ text: String) {
        general.clearContents()
        general.setString(text, forType: .string)
    }
}
#endif
