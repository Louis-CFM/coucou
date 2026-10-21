import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    private(set) var islandController: IslandWindowController?
    private var demoMenuItem: NSMenuItem?
    private lazy var optionalFeatures: OptionalFeatureRuntime = {
        let features: [OptionalFeatureRuntime.Feature] = [
            .init(start: { N8nPoller.shared.start() }, stop: { N8nPoller.shared.stop() }),
            .init(start: { VercelPoller.shared.start() }, stop: { VercelPoller.shared.stop() }),
            .init(start: { ResendPoller.shared.start() }, stop: { ResendPoller.shared.stop() }),
            .init(start: { GithubPoller.shared.start() }, stop: { GithubPoller.shared.stop() }),
            .init(start: { StripePoller.shared.start() }, stop: { StripePoller.shared.stop() }),
            .init(start: { CalcomPoller.shared.start() }, stop: { CalcomPoller.shared.stop() }),
            .init(start: { NotionPoller.shared.start() }, stop: { NotionPoller.shared.stop() }),
            .init(start: { MachineVitals.shared.start() }, stop: { MachineVitals.shared.stop() }),
            .init(start: { CryptoController.shared.start() }, stop: { CryptoController.shared.stop() }),
            .init(start: { PortfolioController.shared.start() }, stop: { PortfolioController.shared.stop() }),
        ]
        #if !APPSTORE
        return OptionalFeatureRuntime(features: features + [
            .init(start: { VoiceEngine.shared.start() }, stop: { VoiceEngine.shared.stop() }),
            .init(start: { FlowDictation.shared.start() }, stop: { FlowDictation.shared.stop() }),
            .init(start: { NoteTaker.existing?.startObserving() }, stop: { NoteTaker.existing?.stopObserving() }),
            .init(start: { MusicController.shared.start() }, stop: { MusicController.shared.stop() }),
            .init(start: { SpotifyController.shared.start() }, stop: { SpotifyController.shared.stop() }),
            .init(start: { MailController.shared.start() }, stop: { MailController.shared.stop() }),
            .init(start: { WhatsAppController.shared.start() }, stop: { WhatsAppController.shared.stop() }),
            .init(start: { MacUpdater.shared.start() }, stop: { MacUpdater.shared.stop() }),
        ])
        #else
        return OptionalFeatureRuntime(features: features)
        #endif
    }()
    #if !APPSTORE
    /// "Update Coucou to 0.6.0…", shown only when a new version is out.
    private var updateMenuItem: NSMenuItem?
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        #if !APPSTORE
        NoteTaker.shared.shutdown()
        // The GOWA gateway Coucou started never outlives it.
        WhatsAppGOWAProcess.shared.stopNow()
        #endif
        DemoEngine.shared.stop()
        HotKeyCenter.shared.unregisterAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when nb-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = KeychainStore.shared
        #if APPSTORE
        NSApp.setActivationPolicy(.accessory)
        #else
        // In the Dock like a regular app (Coucou → Settings → Flow), or only in the menu bar.
        NSApp.setActivationPolicy(FlowHubController.showInDock ? .regular : .accessory)
        #endif
        setupMenuBarItem()
        setupIsland()
        #if !APPSTORE
        // Opened by hand (Finder, Dock, Spotlight): the Coucou window shows. Not at login.
        if FlowHubController.openAtLaunch && !FlowHubController.launchedAtLogin() {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                FlowHubController.shared.show()
            }
        }
        #endif
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        #if APPSTORE
        openIsland()
        #else
        // A click on the Dock icon: the Coucou window.
        FlowHubController.shared.show()
        #endif
        return true
    }

    #if !APPSTORE
    /// Right-click on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !AppState.shared.agentsOnly {
            add(String(localized: "hub.page.dictation"), #selector(openFlowHub))
            add(String(localized: "hub.page.notes"), #selector(openNotes))
            add(NoteTaker.shared.isRecording ? String(localized: "notes.stop") : String(localized: "hub.record-call"),
                #selector(toggleCallRecording))
        }
        menu.addItem(.separator())
        add(String(localized: "Open Coucou"), #selector(openIsland))
        add(NSLocalizedString("Settings…", comment: ""), #selector(openSettings))
        return menu
    }

    @objc private func openNotes() {
        FlowHubController.shared.show(.notes)
    }

    @objc private func toggleCallRecording() {
        let taker = NoteTaker.shared
        if taker.isRecording {
            taker.stop()
        } else {
            FlowHubController.shared.show(.notes)
            Task { await taker.start() }
        }
    }
    #endif

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
        menu.addItem(withTitle: NSLocalizedString("Open Coucou", comment: ""), action: #selector(openIsland), keyEquivalent: "")
        #if !APPSTORE
        let updateItem = NSMenuItem(title: "", action: #selector(openUpdate), keyEquivalent: "")
        updateItem.isHidden = true
        updateMenuItem = updateItem
        menu.addItem(updateItem)
        #endif
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Weekly recap", comment: ""), action: #selector(openWeeklyRecap), keyEquivalent: "")
        #if !APPSTORE
        menu.addItem(withTitle: String(localized: "hub.menu"), action: #selector(openFlowHub), keyEquivalent: "")
        #endif
        menu.addItem(withTitle: NSLocalizedString("Settings…", comment: ""), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: NSLocalizedString("Quit", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleDemoMode() {
        guard !AppState.shared.agentsOnly else { return }
        if DemoEngine.shared.isActive { DemoEngine.shared.stop() }
        else { DemoEngine.shared.start() }
    }

    @objc private func openIsland() {
        islandController?.fsm.openedExternally()
        islandController?.expand(to: AppState.shared.tasks.isEmpty ? .empty : .overview)
    }

    @objc private func openWeeklyRecap() {
        islandController?.expand(to: .recap)
    }

    #if !APPSTORE
    @objc private func openUpdate() {
        guard !AppState.shared.agentsOnly else { return }
        MacUpdater.shared.show()
    }

    @objc private func openFlowHub() {
        if AppState.shared.mode == .expanded { islandController?.collapse() }
        FlowHubController.shared.show(.dictation)
    }
    #endif

    private var settingsWindow: NSWindow?

    @objc private func openSettingsFromNotification(_ notification: Notification) {
        if let section = notification.object as? String {
            UserDefaults.standard.set(section, forKey: "settingsSection")
        }
        openSettings()
    }

    @objc func openSettings() {
        // The island floats above every window; fold it away so it can't cover Settings.
        if AppState.shared.mode == .expanded { islandController?.collapse() }
        #if !APPSTORE
        // Everything in one place: Settings are the notch's pages of the Coucou window.
        let section = UserDefaults.standard.string(forKey: "settingsSection") ?? "general"
        FlowHubController.shared.show(HubPage.forSettings(section))
        #else

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
        #endif
    }

    /// Centres the window horizontally and keeps its title bar clear of the island panel
    /// (320 pt tall at the top of the island screen), shrinking it to fit if needed.
    private func placeBelowIsland(_ win: NSWindow) {
        let screen = IslandWindowController.islandScreen()
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
        optionalFeatures.apply(agentsOnly: AppState.shared.agentsOnly)
        NotificationCenter.default.addObserver(self, selector: #selector(agentsOnlyModeChanged),
                                               name: .agentsOnlyModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsFromNotification(_:)),
                                               name: .openFullSettings, object: nil)
        // After the greeting ends, fly Mochi back to the desktop if it was there at last quit
        NotificationCenter.default.addObserver(forName: .greetComplete, object: nil, queue: .main) { [weak self] _ in
            if !AgentsOnlyPreference.shared.enabled { DesktopMochiController.shared.launchFlyIfNeeded() }
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
        ClaudeDesktopChatWatcher.shared.start()
        #endif
    }

    @objc private func agentsOnlyModeChanged() {
        let state = AppState.shared
        if state.agentsOnly {
            DemoEngine.shared.stop()
            DesktopMochiController.existing?.suspendForAgentsOnly()
            state.refreshAgentConnections()
        } else {
            DesktopMochiController.shared.resumeAfterAgentsOnly()
        }
        optionalFeatures.apply(agentsOnly: state.agentsOnly)
        HotKeyCenter.shared.registerAll()
        #if !APPSTORE
        if state.agentsOnly { FlowHubController.shared.router.page = .general }
        #endif
        #if PHONE_LINK
        CloudProbe.shared.updateServiceMode()
        #endif
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        demoMenuItem?.isHidden = AppState.shared.agentsOnly
        demoMenuItem?.title = DemoEngine.shared.isActive
            ? NSLocalizedString("demo.stop", comment: "")
            : NSLocalizedString("Demo mode", comment: "")
        #if !APPSTORE
        if AppState.shared.agentsOnly { updateMenuItem?.isHidden = true; return }
        if let r = MacUpdater.shared.latest, MacUpdate.isNewer(r.version, than: MacUpdater.currentVersion) {
            updateMenuItem?.title = String(format: String(localized: "update.menu %@"), r.version)
            updateMenuItem?.isHidden = false
        } else {
            updateMenuItem?.isHidden = true
        }
        #endif
    }
}
