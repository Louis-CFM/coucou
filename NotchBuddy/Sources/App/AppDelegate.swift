import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when the hook relay closes the socket before we write the response
        signal(SIGPIPE, SIG_IGN)
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = KeychainStore.shared
        // Menu bar + notch only: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarItem()
        setupIsland()
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Orca Notch")
        button.image?.size = NSSize(width: 24, height: 18)
        button.image?.accessibilityDescription = "Orca Notch"
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: NSLocalizedString("Open Orca Notch", comment: ""), action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Settings…", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Quit", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openIsland() {
        islandController?.fsm.openedExternally()
        islandController?.expand(to: .overview)
    }

    @objc private func openSettingsFromNotification(_ notification: Notification) {
        if let section = notification.object as? String {
            UserDefaults.standard.set(section, forKey: "settingsSection")
        }
        openSettings()
    }

    @objc func openSettings() {
        // The island floats above every window; fold it away so it can't cover Settings.
        if AppState.shared.mode == .expanded { islandController?.collapse() }
        SettingsWindowController.shared.show()
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        islandController?.fsm.launch()
        HookServer.shared.start()
        GithubPoller.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsFromNotification(_:)),
                                               name: .openFullSettings, object: nil)
        ClaudeDesktopChatWatcher.shared.start()
        OrcaIslandBridge.shared.start()
    }
}
