import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?
    private var demoMenuItem: NSMenuItem?

    func applicationWillTerminate(_ notification: Notification) {
        DemoEngine.shared.stop()
        HotKeyCenter.shared.unregisterAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = KeychainStore.shared
        NSApp.setActivationPolicy(.accessory)
        setupMenuBarItem()
        setupIsland()
        #if DEBUG
        let debugMenu = NSMenu(title: "Debug")
        debugMenu.addItem(NSMenuItem(title: "Render recap image", action: #selector(renderRecapImage), keyEquivalent: ""))
        let debugMenuItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debugMenuItem.submenu = debugMenu
        NSApp.mainMenu?.addItem(debugMenuItem)
        #endif
        #if PHONE_LINK
        CloudProbe.shared.startIfEnabled()
        #endif
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
        menu.delegate = self
        let demoItem = NSMenuItem(title: NSLocalizedString("Demo mode", comment: ""), action: #selector(toggleDemoMode), keyEquivalent: "")
        demoMenuItem = demoItem
        menu.addItem(demoItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Memory Manager…", action: #selector(openMemoryManager), keyEquivalent: "m")
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: NSLocalizedString("Open Coucou", comment: ""), action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Weekly recap", comment: ""), action: #selector(openWeeklyRecap), keyEquivalent: "")
        menu.addItem(withTitle: NSLocalizedString("Settings…", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Quit", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleDemoMode() {
        if DemoEngine.shared.isActive { DemoEngine.shared.stop() }
        else { DemoEngine.shared.start() }
    }

    @objc private func openIsland() {
        islandController?.expand(to: .overview)
    }

    @objc private func openMemoryManager() {
        if AppState.shared.mode == .expanded { islandController?.collapse() }
        MemoryManagerWindowController.shared.present()
    @objc private func openWeeklyRecap() {
        islandController?.expand(to: .recap)
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettingsFromNotification(_ notification: Notification) {
        if let section = notification.object as? String {
            UserDefaults.standard.set(section, forKey: "settingsSection")
        }
        openSettings()
    }

    @objc private func openSettings() {
        // The island floats above every window; fold it away so it can't cover Settings.
        if AppState.shared.mode == .expanded { islandController?.collapse() }

        if let w = settingsWindow, w.isVisible {
            placeBelowIsland(w)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = String(localized: "settings.window.title")
        let host = NSHostingView(rootView: SettingsView())
        host.sizingOptions = [.minSize]
        win.contentView = host
        win.contentMinSize = NSSize(width: 640, height: 420)
        win.isReleasedWhenClosed = false
        placeBelowIsland(win)
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Centres the window horizontally and keeps its title bar clear of the island panel
    /// (320 pt tall at the top of the notch screen), shrinking it to fit if needed.
    private func placeBelowIsland(_ win: NSWindow) {
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main ?? win.screen
        guard let screen else { win.center(); return }
        let visible = screen.visibleFrame
        let islandBottom = screen.frame.maxY - 320 - 12   // island panel height + margin
        let top = min(visible.maxY, islandBottom)
        var frame = win.frame
        frame.size.height = min(frame.height, max(top - visible.minY - 12, win.minSize.height))
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = max(visible.minY + 12, top - frame.height)
        win.setFrame(frame, display: true)
    }

    // MARK: - Debug helpers

    #if DEBUG
    @objc func renderRecapImage() {
        let summary = RecapStore.shared.weeklySummary() ?? WeeklySummary(
            weekStart: Date(), weekEnd: Date(),
            totalMinutes: 300, sessionCount: 6,
            filesChanged: 31, linesAdded: 1217, linesRemoved: 312,
            commandsRun: 54, questionsAnswered: 11,
            permissionsAllowed: 4, permissionsDenied: 1,
            topAgent: "Claude Code", topProject: "coucou",
            busiestDay: "Friday", longestSessionMinutes: 300
        )
        let view = RecapShareImageView(summary: summary, hideProjects: false)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 1080, height: 1920)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { return }
        let img = NSImage(cgImage: cg, size: NSSize(width: 1080, height: 1920))
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/coucou-recap-debug.png")
        if let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            NSWorkspace.shared.open(url)
        }
    }
    #endif

    // MARK: - Weekly recap trigger

    /// On Monday ≥ 8 am, show the recap card once (if there is activity to display).
    /// Called from greetComplete, SessionStart/UserPromptSubmit hooks, and on wake.
    func checkMondayRecap() {
        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        // weekday in ISO 8601 calendar: 2 = Monday
        guard cal.component(.weekday, from: now) == 2,
              cal.component(.hour,    from: now) >= 8 else { return }
        // Don't interrupt a pending approval or question
        let s = AppState.shared
        guard s.pendingApproval == nil, s.pendingQuestion == nil else { return }
        let weekYear = cal.component(.yearForWeekOfYear, from: now)
        let weekNum  = cal.component(.weekOfYear,        from: now)
        let weekKey  = weekYear * 100 + weekNum
        let lastShown = UserDefaults.standard.integer(forKey: "recapLastShownWeek")
        guard weekKey != lastShown else { return }
        guard RecapStore.shared.weeklySummary() != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            let s = AppState.shared
            guard s.pendingApproval == nil, s.pendingQuestion == nil else { return }
            self?.islandController?.expand(to: .recap)
            UserDefaults.standard.set(weekKey, forKey: "recapLastShownWeek")
        }
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        islandController?.fsm.launch()
        HookServer.shared.start()
        N8nPoller.shared.start()
        VercelPoller.shared.start()
        ResendPoller.shared.start()
        GithubPoller.shared.start()
        StripePoller.shared.start()
        CalcomPoller.shared.start()
        NotionPoller.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsFromNotification(_:)),
                                               name: .openFullSettings, object: nil)
        // After the greeting ends, fly Mochi back to the desktop if it was there at last quit
        NotificationCenter.default.addObserver(forName: .greetComplete, object: nil, queue: .main) { [weak self] _ in
            DesktopMochiController.shared.launchFlyIfNeeded()
            self?.checkMondayRecap()
        }
        // Check for Monday recap on wake and when a new session/prompt arrives
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.checkMondayRecap()
        }
        NotificationCenter.default.addObserver(forName: .checkMondayRecap, object: nil, queue: .main) { [weak self] _ in
            self?.checkMondayRecap()
        }
        #if !APPSTORE
        _ = MusicController.shared
        #endif
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        demoMenuItem?.title = DemoEngine.shared.isActive
            ? NSLocalizedString("demo.stop", comment: "")
            : NSLocalizedString("Demo mode", comment: "")
    }
}
