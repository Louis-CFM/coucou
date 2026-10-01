import SwiftUI
import AppKit

// MARK: - Settings window
// Classic macOS preferences: one toolbar icon per tab (NSTabViewController, .toolbar style),
// each tab a grouped SwiftUI Form.

enum SettingsTab: Int, CaseIterable {
    case general, claude, integrations, island

    var title: String {
        switch self {
        case .general:      return String(localized: "General")
        case .claude:       return "Claude"
        case .integrations: return String(localized: "Integrations")
        case .island:       return String(localized: "Island")
        }
    }

    var symbol: String {
        switch self {
        case .general:      return "gearshape"
        case .claude:       return "terminal"
        case .integrations: return "puzzlepiece.extension"
        case .island:       return "capsule.portrait"
        }
    }

    @MainActor
    var content: AnyView {
        switch self {
        case .general:      return AnyView(SettingsGeneralTab())
        case .claude:       return AnyView(SettingsClaudeTab())
        case .integrations: return AnyView(SettingsIntegrationsTab())
        case .island:       return AnyView(SettingsIslandTab())
        }
    }
}

final class SettingsTabViewController: NSTabViewController {
    static let size = NSSize(width: 560, height: 600)
    private static let selectedTabKey = "settingsSelectedTab"

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let root = tab.content.frame(width: Self.size.width, height: Self.size.height)
            let item = NSTabViewItem(viewController: NSHostingController(rootView: root))
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            addTabViewItem(item)
        }
        let saved = UserDefaults.standard.integer(forKey: Self.selectedTabKey)
        selectedTabViewItemIndex = SettingsTab(rawValue: saved) != nil ? saved : 0
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        UserDefaults.standard.set(selectedTabViewItemIndex, forKey: Self.selectedTabKey)
        view.window?.title = tabViewItem?.label ?? ""
    }
}

// MARK: - Shared page layout

/// Grouped form (System Settings look) with the tab's status line as a last, header-less section.
struct SettingsPage<Content: View>: View {
    let status: SettingsStatus?
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
            if status != nil {
                Section {
                    StatusLine(status: status)
                        .font(.system(size: 12))
                }
            }
        }
        .formStyle(.grouped)
    }
}
