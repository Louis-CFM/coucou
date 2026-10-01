import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = KeychainStore.shared
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarItem()
        setupIsland()
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Coucou")
        button.image?.size = NSSize(width: 24, height: 18)
        button.image?.accessibilityDescription = "Coucou"
        button.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open Coucou"), action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func openIsland() {
        islandController?.expand(to: .overview)
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettings() {
        // The expanded island floats above every window and would cover the toolbar tabs.
        // Never collapse it while an approval is waiting — the card must stay reachable.
        if AppState.shared.pendingApproval == nil, AppState.shared.mode == .expanded {
            islandController?.collapse()
        }
        if let w = settingsWindow, w.isVisible { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let win = NSWindow(contentViewController: SettingsTabViewController())
        win.styleMask = [.titled, .closable]
        win.toolbarStyle = .preference
        win.setContentSize(SettingsTabViewController.size)
        win.center()
        win.isReleasedWhenClosed = false
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        islandController?.fsm.launch()
        HookServer.shared.start()
        // Registry routes the approval-card buttons to the owning provider — without
        // registration the Allow/Deny buttons are a silent no-op.
        AgentServiceRegistry.shared.register(HookServer.shared)
        OrcaService.shared.start()
        AgentServiceRegistry.shared.register(OrcaService.shared)
        N8nPoller.shared.start()
        VercelPoller.shared.start()
        ResendPoller.shared.start()
        GithubPoller.shared.start()
        StripePoller.shared.start()
        CalcomPoller.shared.start()
        NotionPoller.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettings),
                                               name: .openFullSettings, object: nil)
    }
}
