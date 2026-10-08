import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var demoEngine = DemoEngine.shared
    @State private var apiKey: String = KeychainStore.shared.get("anthropic-api-key") ?? ""

    // Claude model — dynamic list fetched from the API, static fallback if unavailable
    private static let fallbackModels: [(id: String, label: String)] = [
        ("claude-sonnet-4-6",         "Claude Sonnet 4.6"),
        ("claude-sonnet-5-5",         "Claude Sonnet 5.5"),
        ("claude-opus-5-5",           "Claude Opus 5.5"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
    ]
    private static let customModelTag = "__custom__"
    @State private var fetchedModels: [(id: String, label: String)] = []
    @State private var modelChoice: String = {
        let m = AppState.shared.claudeModel
        return SettingsView.fallbackModels.contains { $0.id == m } ? m : SettingsView.customModelTag
    }()
    @State private var customModel: String = {
        let m = AppState.shared.claudeModel
        return SettingsView.fallbackModels.contains { $0.id == m } ? "" : m
    }()
    private var displayModels: [(id: String, label: String)] {
        fetchedModels.isEmpty ? Self.fallbackModels : fetchedModels
    }
    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var statusMessage: String = ""
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()

    #if !APPSTORE
    @State private var showStatusLineDiff: Bool = false
    @State private var pendingStatusLineJSON: String = ""
    @State private var statusLinePendingInstall: Bool = true
    @State private var planTogglePending: Bool = false

    @State private var geminiHooksInstalled: Bool = HookServer.geminiHooksInstalled()
    @State private var showGeminiDiff: Bool = false
    @State private var pendingGeminiJSON: String = ""
    @State private var geminiPendingInstall: Bool = true

    @State private var agyHooksInstalled: Bool = HookServer.agyHooksInstalled()
    @State private var showAgyDiff: Bool = false
    @State private var pendingAgyJSON: String = ""
    @State private var agyPendingInstall: Bool = true

    @State private var codexHooksInstalled: Bool = HookServer.codexHooksInstalled()
    @State private var showCodexDiff: Bool = false
    @State private var pendingCodexJSON: String = ""
    @State private var codexPendingInstall: Bool = true

    @State private var copilotHooksInstalled: Bool = HookServer.copilotHooksInstalled()
    @State private var showCopilotDiff: Bool = false
    @State private var pendingCopilotJSON: String = ""
    @State private var copilotPendingInstall: Bool = true

    @State private var museHooksInstalled: Bool = HookServer.museHooksInstalled()
    @State private var showMuseDiff: Bool = false
    @State private var pendingMuseJSON: String = ""
    @State private var musePendingInstall: Bool = true

    @State private var openCodePluginInstalled: Bool = HookServer.openCodePluginInstalled()
    @State private var showOpenCodeDiff: Bool = false
    @State private var pendingOpenCodeContent: String = ""
    @State private var openCodePendingInstall: Bool = true

    @State private var ampPluginInstalled: Bool = HookServer.ampPluginInstalled()
    @State private var showAmpDiff: Bool = false
    @State private var pendingAmpContent: String = ""
    @State private var ampPendingInstall: Bool = true

    @State private var hermesPluginInstalled: Bool = HookServer.hermesPluginInstalled()
    @State private var showHermesPluginDiff: Bool = false
    @State private var pendingHermesPluginContent: String = ""
    @State private var hermesPluginPendingInstall: Bool = true

    @State private var showHermesConfigDiff: Bool = false
    @State private var pendingHermesConfigContent: String = ""
    @AppStorage("hermesApprovalsEnabled") private var hermesApprovalsEnabled: Bool = false
    @State private var hermesSupportsApprovals: Bool = false
    #endif

    // Multi-provider chat keys
    @State private var googleKey: String  = KeychainStore.shared.get("google-api-key") ?? ""
    @State private var openAIKey: String  = KeychainStore.shared.get("openai-api-key") ?? ""
    @State private var ollamaURL:    String = AppState.shared.ollamaServerURL
    @State private var lmstudioURL:  String = AppState.shared.lmstudioServerURL
    @State private var connectingOllama:    Bool = false
    @State private var connectingLMStudio:  Bool = false

    // Integration keys
    @State private var resendKey: String    = KeychainStore.shared.get("resend-api-key")  ?? ""
    @State private var resendFrom: String   = KeychainStore.shared.get("resend-from")     ?? ""
    @State private var n8nUrl: String       = KeychainStore.shared.get("n8n-url")         ?? ""
    @State private var n8nKey: String       = KeychainStore.shared.get("n8n-api-key")     ?? ""
    @State private var vercelToken: String  = KeychainStore.shared.get("vercel-token")    ?? ""
    @State private var githubToken: String  = KeychainStore.shared.get("github-token")    ?? ""
    @State private var stripeKey: String    = KeychainStore.shared.get("stripe-api-key")  ?? ""
    @State private var calcomKey: String    = KeychainStore.shared.get("calcom-api-key")  ?? ""
    @State private var notionKey: String    = KeychainStore.shared.get("notion-api-key")  ?? ""

    // Hotkey
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode

    // Vercel project filter
    @State private var vercelProjects: [String] = []
    @State private var loadingVercel: Bool = false

    // n8n workflow filter
    @State private var n8nWorkflows: [String] = []
    @State private var loadingN8n: Bool = false

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    // Connected screens for the Display picker, refreshed when screens change
    @State private var connectedScreens: [(uuid: String, name: String)] = []

    // Sidebar selection persisted across sessions
    @AppStorage("settingsSection") private var selectedSection: String = "general"
    #if PHONE_LINK
    @AppStorage("iPhoneSyncEnabled") private var iPhoneSyncEnabled = false
    @AppStorage("iPhoneLiveActivityEnabled") private var iPhoneLiveActivityEnabled = false
    @AppStorage("iPhoneInstructionsEnabled") private var iPhoneInstructionsEnabled = false
    #endif

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — 200 pt, sidebar visual effect background
            ZStack(alignment: .topLeading) {
                SidebarBackground()
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(alignment: .center, spacing: 10) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Coucou")
                                .font(.system(size: 13, weight: .semibold))
                            Text(appVersion)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                    Divider()
                    List(selection: Binding(
                        get: { Optional(selectedSection) },
                        set: { if let v = $0 { selectedSection = v; statusMessage = "" } }
                    )) {
                        SettingsSidebarRow(title: "General",      icon: "gearshape.fill",                    color: "#8E939C").tag("general")
                        SettingsSidebarRow(title: "Active pills", icon: "square.grid.2x2.fill",              color: "#F5A524").tag("activepills")
                        SettingsSidebarRow(title: "Agents",       icon: "terminal.fill",                     color: "#3B9EFF").tag("agents")
                        SettingsSidebarRow(title: "Chat",         icon: "bubble.left.and.bubble.right.fill", color: "#E07950").tag("chat")
                        SettingsSidebarRow(title: "Integrations", icon: "puzzlepiece.extension.fill",        color: "#7C5CFF").tag("integrations")
                        SettingsSidebarRow(title: "Shortcuts",    icon: "keyboard.fill",                     color: "#6366F1").tag("shortcuts")
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 200)

            Divider()

            // Detail panel
            VStack(alignment: .leading, spacing: 0) {
                Text(sectionTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                if !statusMessage.isEmpty {
                    Divider()
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusMessage.hasPrefix("❌") ? .red : .secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
        }
        .onAppear {
            #if !APPSTORE
            state.refreshPlanRelayState()
            #endif
            guard fetchedModels.isEmpty,
                  let key = KeychainStore.shared.get("anthropic-api-key"), !key.isEmpty else { return }
            Task {
                let models = await ClaudeService.fetchModels(apiKey: key)
                guard !models.isEmpty else { return }
                await MainActor.run {
                    fetchedModels = models
                    let m = state.claudeModel
                    if models.contains(where: { $0.id == m }) {
                        modelChoice = m
                        customModel = ""
                    } else if modelChoice != Self.customModelTag {
                        modelChoice = Self.customModelTag
                        customModel = m
                    }
                }
            }
        }
    }

    // MARK: - Section routing

    private var sectionTitle: String {
        switch selectedSection {
        case "general":      return String(localized: "General")
        case "activepills":  return String(localized: "Active pills")
        case "agents":       return String(localized: "Agents")
        case "chat":         return String(localized: "Chat")
        case "integrations": return String(localized: "Integrations")
        case "shortcuts":    return String(localized: "Shortcuts")
        default:             return String(localized: "General")
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case "activepills":  activePillsSection
        case "agents":       agentsSection
        case "chat":         chatSection
        case "integrations": integrationsSection
        case "shortcuts":    ShortcutsSettingsView()
        default:             generalSection
        }
    }

    // MARK: - General section

    @ViewBuilder private var generalSection: some View {
        GroupBox(String(localized: "demo.groupbox.title")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "demo.description"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(demoEngine.isActive ? String(localized: "demo.stop") : String(localized: "demo.start")) {
                    if demoEngine.isActive { DemoEngine.shared.stop() }
                    else { DemoEngine.shared.start() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }

        GroupBox("Sound") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Enable sounds", isOn: $state.soundEnabled)
                HStack(spacing: 8) {
                    Text("Volume")
                        .frame(width: 56, alignment: .leading)
                    Slider(value: $state.soundVolume, in: 0...0.2)
                        .disabled(!state.soundEnabled)
                    Text("\(Int(state.soundVolume / 0.2 * 100)) %")
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }
            }
            .padding(6)
        }

        GroupBox("Behavior") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Close after")
                    TextField("60", value: $state.autoCloseInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("s inactive")
                }
                HStack(spacing: 8) {
                    Text("Hide after")
                    TextField("3", value: absenceMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                    Text("min without movement")
                }
            }
            .padding(6)
        }

        GroupBox("Display") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Show Mochi on", selection: $state.islandDisplay) {
                    Text("Screen with the notch").tag(IslandDisplayChoice.notch)
                    Text("Main screen (menu bar)").tag(IslandDisplayChoice.menuBar)
                    Text("Follow the mouse").tag(IslandDisplayChoice.followMouse)
                    Divider()
                    ForEach(connectedScreens, id: \.uuid) { screen in
                        Text(screen.name).tag(IslandDisplayChoice.display(uuid: screen.uuid))
                    }
                    if case .display(let uuid) = state.islandDisplay,
                       !connectedScreens.contains(where: { $0.uuid == uuid }) {
                        Text("Saved screen (not connected)").tag(state.islandDisplay)
                    }
                }
                .frame(maxWidth: 360)
                Text("On a screen without a notch, Mochi sits in a small bar at the top. Follow the mouse moves it to your cursor's screen while it is closed.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .onAppear { refreshConnectedScreens() }
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)) { _ in
                refreshConnectedScreens()
            }
        }

        GroupBox("Hotkey") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show island with shortcut", isOn: $state.hotkeyEnabled)
                    .onChange(of: state.hotkeyEnabled) { _, _ in
                        HotKeyCenter.shared.reregister(.toggleIsland)
                    }
                if state.hotkeyEnabled {
                    HStack(spacing: 8) {
                        Text("Shortcut")
                            .frame(width: 70, alignment: .leading)
                        ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                            .onChange(of: hotkeyFlags) { _, v in
                                state.hotkeyFlags = v
                                HotKeyCenter.shared.reregister(.toggleIsland)
                            }
                            .onChange(of: hotkeyCode) { _, v in
                                state.hotkeyCode = v
                                HotKeyCenter.shared.reregister(.toggleIsland)
                            }
                        Text("presses this → island opens")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(6)
        }

        GroupBox("Startup") {
            Toggle("Launch at Mac startup", isOn: $launchAtStartup)
                .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }
                .padding(6)
        }

        GroupBox(String(localized: "Weekly recap")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "Keep a history of my coding sessions"), isOn: $state.recapEnabled)
                Text(String(localized: "Stored locally on your Mac. Nothing leaves your Mac. Retained for 12 weeks."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(String(localized: "Hide project names in shared images"), isOn: $state.recapHideProjects)
                    .disabled(!state.recapEnabled)
                Button(String(localized: "Clear history")) { RecapStore.shared.clearHistory() }
            }
            .padding(6)
        }

        GroupBox(String(localized: "Language")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $state.appLanguage) {
                    Text(String(localized: "System")).tag("")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("हिन्दी").tag("hi")
                    Text("Español").tag("es")
                    Text("العربية").tag("ar")
                    Text("Français").tag("fr")
                    Text("বাংলা").tag("bn")
                    Text("Português (Brasil)").tag("pt-BR")
                    Text("Русский").tag("ru")
                    Text("Bahasa Indonesia").tag("id")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: state.appLanguage) { _, code in
                    if code.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([code], forKey: "AppleLanguages")
                    }
                    UserDefaults.standard.synchronize()
                }
                HStack(spacing: 8) {
                    Button(String(localized: "Restart Coucou")) {
                        let appPath = Bundle.main.bundleURL.path
                        let pid = ProcessInfo.processInfo.processIdentifier
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/bin/sh")
                        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open \"$1\"", "--", appPath]
                        try? task.run()
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.bordered)
                    Text(String(localized: "Applies on next launch"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(6)
        }

        #if PHONE_LINK
        GroupBox("iPhone") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(String(localized: "iphone.sync.toggle"), isOn: $iPhoneSyncEnabled)
                    .onChange(of: iPhoneSyncEnabled) { _, on in CloudProbe.shared.setEnabled(on) }
                Text(String(localized: "iphone.sync.description"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(String(localized: "iphone.live-activity.toggle"), isOn: $iPhoneLiveActivityEnabled)
                    .disabled(!iPhoneSyncEnabled)
                    .onChange(of: iPhoneLiveActivityEnabled) { _, on in LiveActivityRelay.shared.setEnabled(on) }
                Text(String(localized: "iphone.live-activity.description"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if !APPSTORE
                Toggle(String(localized: "iphone.instruction.toggle"), isOn: $iPhoneInstructionsEnabled)
                    .disabled(!iPhoneSyncEnabled)
                    .onChange(of: iPhoneInstructionsEnabled) { _, on in InstructionRunner.shared.setEnabled(on) }
                Text(String(localized: "iphone.instruction.description"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            .padding(6)
        }
        #endif
    }

    private func refreshConnectedScreens() {
        connectedScreens = NSScreen.screens.compactMap { screen in
            guard let uuid = IslandWindowController.displayUUID(screen) else { return nil }
            return (uuid, screen.localizedName)
        }
    }

    // MARK: - Active pills section

    @ViewBuilder private var activePillsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose the tools you use. Coucou only shows what you declare here.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(String(format: String(localized: "settings.slots-used %lld"), Int64(state.activeIntegrations.count)))
                    .font(.system(size: 11))
                    .foregroundColor(state.activeIntegrations.count >= 4 ? .orange : .secondary)

                Picker(String(localized: "settings.main-pill"), selection: $state.mainPillId) {
                    ForEach(PillCatalog.available.filter { $0.category == .workspace && !$0.comingSoon }, id: \.id) { def in
                        Text(def.name).tag(def.id)
                    }
                }
                .onChange(of: state.mainPillId) { _, newId in
                    state.activeIntegrations.remove(newId)
                    state.loadIntegrationTasks()
                    state.setFocus(newId)
                }

                ForEach(PillCategory.allCases, id: \.self) { cat in
                    let catPills = PillCatalog.available.filter { $0.category == cat }
                    if !catPills.isEmpty {
                        Divider()
                        Text(cat.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        ForEach(catPills, id: \.id) { def in
                            pillRow(def)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Agents section

    @ViewBuilder private var agentsSection: some View {
        GroupBox(String(localized: "hooks.claude-code.title")) {
            VStack(alignment: .leading, spacing: 10) {
                if hookNeedsUpdate {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(String(localized: "hooks.outdated"))
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    #if APPSTORE
                    Button(String(localized: "hooks.update")) { installHooksAppStore() }
                    #else
                    Button(String(localized: "hooks.update")) { installHooks() }
                    #endif
                }
                #if APPSTORE
                Text("~/.claude/coucou/nb-hook")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { installHooksAppStore() }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { uninstallHooksAppStore() }
                        .buttonStyle(.bordered)
                }
                #else
                Text("nb-hook : \(HookServer.hookScriptPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { installHooks() }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { uninstallHooks() }
                        .buttonStyle(.bordered)
                }
                #endif

                #if !APPSTORE
                if showDiff {
                    ScrollView {
                        Text(pendingHookJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmInstall() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showDiff = false; pendingHookJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
                #endif
            }
            .padding(6)
        }

        #if !APPSTORE
        GroupBox(String(localized: "hooks.gemini.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(geminiHooksInstalled
                     ? String(localized: "hooks.gemini.installed")
                     : "~/.gemini/settings.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerGeminiPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerGeminiPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showGeminiDiff {
                    ScrollView {
                        Text(pendingGeminiJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmGeminiOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showGeminiDiff = false; pendingGeminiJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.antigravity.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(agyHooksInstalled
                     ? String(localized: "hooks.antigravity.installed")
                     : "~/.gemini/config/hooks.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerAgyPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerAgyPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showAgyDiff {
                    ScrollView {
                        Text(pendingAgyJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmAgyOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showAgyDiff = false; pendingAgyJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.codex.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(codexHooksInstalled
                     ? String(localized: "hooks.codex.installed")
                     : "~/.codex/hooks.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerCodexPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerCodexPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showCodexDiff {
                    ScrollView {
                        Text(pendingCodexJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmCodexOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showCodexDiff = false; pendingCodexJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.copilot.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(copilotHooksInstalled
                     ? String(localized: "hooks.copilot.installed")
                     : "~/.copilot/hooks/coucou.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerCopilotPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerCopilotPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showCopilotDiff {
                    ScrollView {
                        Text(pendingCopilotJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmCopilotOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showCopilotDiff = false; pendingCopilotJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "hooks.muse.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(museHooksInstalled
                     ? String(localized: "hooks.muse.installed")
                     : "~/.config/muse/settings.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "hooks.install")) { triggerMusePreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerMusePreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showMuseDiff {
                    ScrollView {
                        Text(pendingMuseJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmMuseOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showMuseDiff = false; pendingMuseJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "plugin.opencode.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(openCodePluginInstalled
                     ? String(localized: "plugin.opencode.installed")
                     : "~/.config/opencode/plugins/coucou.js")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "plugin.install")) { triggerOpenCodePreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerOpenCodePreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showOpenCodeDiff {
                    ScrollView {
                        Text(pendingOpenCodeContent)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmOpenCodeOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showOpenCodeDiff = false; pendingOpenCodeContent = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "plugin.amp.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(ampPluginInstalled
                     ? String(localized: "plugin.amp.installed")
                     : "~/.config/amp/plugins/coucou.ts")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button(String(localized: "plugin.install")) { triggerAmpPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button(String(localized: "hooks.uninstall")) { triggerAmpPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showAmpDiff {
                    ScrollView {
                        Text(pendingAmpContent)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmAmpOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showAmpDiff = false; pendingAmpContent = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox(String(localized: "plugin.hermes.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(hermesPluginInstalled
                     ? String(localized: "plugin.hermes.installed")
                     : "~/.hermes/plugins/coucou/__init__.py")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    if !hermesPluginInstalled {
                        Button(String(localized: "plugin.install")) { triggerHermesPluginPreview(install: true) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(String(localized: "hooks.uninstall")) { triggerHermesPluginPreview(install: false) }
                            .buttonStyle(.bordered)
                    }
                }
                if showHermesPluginDiff {
                    ScrollView {
                        Text(pendingHermesPluginContent)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmHermesPluginOp() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) { showHermesPluginDiff = false; pendingHermesPluginContent = "" }
                            .buttonStyle(.bordered)
                    }
                }

                if hermesPluginInstalled {
                    Divider()
                    Toggle(String(localized: "plugin.hermes.approvals"), isOn: $hermesApprovalsEnabled)
                        .onChange(of: hermesApprovalsEnabled) { _, _ in triggerHermesConfigPreview() }
                        .disabled(!hermesSupportsApprovals)
                    if !hermesSupportsApprovals {
                        Text("Requires a newer version of Hermes — run: hermes update")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(hermesApprovalsEnabled
                             ? String(localized: "plugin.hermes.approvals.enabled")
                             : String(localized: "plugin.hermes.approvals.disabled"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if showHermesConfigDiff {
                        ScrollView {
                            Text(pendingHermesConfigContent)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        HStack {
                            Button(String(localized: "hooks.confirm-write")) { confirmHermesConfigOp() }
                                .buttonStyle(.borderedProminent)
                            Button(String(localized: "Cancel")) { showHermesConfigDiff = false; pendingHermesConfigContent = "" }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(6)
        }
        #if !APPSTORE
        .task(id: hermesPluginInstalled) {
            guard hermesPluginInstalled else { hermesSupportsApprovals = false; return }
            let result = await Task.detached(priority: .background) {
                HookServer.hermesSupportsApprovalTransport()
            }.value
            await MainActor.run { hermesSupportsApprovals = result }
        }
        #endif

        GroupBox(String(localized: "plan.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "plan.description"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(String(localized: "plan.show-in-notch"), isOn: Binding(
                    get: { state.showPlanInNotch || planTogglePending },
                    set: { on in
                        if on {
                            if state.planRelayInstalled {
                                state.showPlanInNotch = true
                            } else {
                                planTogglePending = true
                                installStatusLine()
                            }
                        } else {
                            state.showPlanInNotch = false
                            planTogglePending = false
                        }
                    }
                ))
                HStack(spacing: 10) {
                    if state.planRelayInstalled {
                        Text(String(localized: "plan.relay.installed"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(String(localized: "plan.relay.uninstall")) { uninstallStatusLine() }
                            .buttonStyle(.bordered)
                    } else {
                        Text(String(localized: "plan.relay.not-installed"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Button(String(localized: "plan.relay.install")) { installStatusLine() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if showStatusLineDiff {
                    ScrollView {
                        Text(pendingStatusLineJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button(String(localized: "hooks.confirm-write")) { confirmStatusLine() }
                            .buttonStyle(.borderedProminent)
                        Button(String(localized: "Cancel")) {
                            showStatusLineDiff = false
                            pendingStatusLineJSON = ""
                            planTogglePending = false
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Divider()
                Text("Shows your Codex plan usage (weekly limit and free resets left) in the notch header. Coucou asks the Codex CLI (codex app-server) when the pill shows; nothing is installed. Codex must be signed in with ChatGPT.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Show Codex plan in the notch", isOn: Binding(
                    get: { state.showCodexPlanInNotch },
                    set: { state.showCodexPlanInNotch = $0 }
                ))
            }
            .padding(6)
        }
        #endif
    }

    // MARK: - Chat section

    @ViewBuilder private var chatSection: some View {
        GroupBox(String(localized: "chat.anthropic-api.title")) {
            VStack(alignment: .leading, spacing: 8) {
                SecureField(String(localized: "chat.api-key.claude"), text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Save")) {
                    KeychainStore.shared.set("anthropic-api-key", value: apiKey)
                    statusMessage = String(localized: "status.key-saved")
                }
                .buttonStyle(.borderedProminent)

                Divider().padding(.vertical, 2)

                Picker(String(localized: "chat.model"), selection: $modelChoice) {
                    ForEach(displayModels, id: \.id) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                    Text(String(localized: "chat.model.custom")).tag(Self.customModelTag)
                }
                .onChange(of: modelChoice) { _, choice in
                    if choice != Self.customModelTag {
                        state.claudeModel = choice
                    } else {
                        applyCustomModel(customModel)
                    }
                }

                if modelChoice == Self.customModelTag {
                    TextField(String(localized: "chat.model.custom-id"), text: $customModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customModel) { _, value in applyCustomModel(value) }
                }

                Text(String(localized: "chat.model.description"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }

        GroupBox(String(localized: "chat.other-providers.title")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "chat.other-providers.description"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "#4285F4")).frame(width: 8, height: 8)
                    Text(String(localized: "chat.google-ai")).font(.system(size: 12, weight: .semibold))
                }
                SecureField(String(localized: "chat.api-key.google"), text: $googleKey)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Save")) {
                    KeychainStore.shared.set("google-api-key", value: googleKey)
                    statusMessage = String(localized: "status.google-key-saved")
                }
                .buttonStyle(.borderedProminent)

                Divider()

                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "#10A37F")).frame(width: 8, height: 8)
                    Text(String(localized: "chat.openai")).font(.system(size: 12, weight: .semibold))
                }
                SecureField(String(localized: "chat.api-key.openai"), text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "Save")) {
                    KeychainStore.shared.set("openai-api-key", value: openAIKey)
                    statusMessage = String(localized: "status.openai-key-saved")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }

        GroupBox(String(localized: "chat.local.title")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "chat.local.description"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                // ── Ollama ──────────────────────────────────────────────────────
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "#FACC15")).frame(width: 8, height: 8)
                    Text("Ollama").font(.system(size: 12, weight: .semibold))
                    if !state.ollamaServerURL.isEmpty {
                        Text(String(localized: "Connected"))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#22C55E"))
                    }
                }
                if state.ollamaServerURL.isEmpty {
                    TextField("http://127.0.0.1:11434", text: $ollamaURL)
                        .textFieldStyle(.roundedBorder)
                    Button(connectingOllama ? String(localized: "chat.connecting") : String(localized: "chat.connect")) {
                        Task { await connectLocal(provider: .ollama) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(connectingOllama)
                } else {
                    Text(state.ollamaServerURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button(String(localized: "chat.disconnect")) {
                        state.ollamaServerURL = ""
                        ollamaURL = ""
                        state.fetchedProviderModels[.ollama] = nil
                        state.providerModelFetchError[.ollama] = nil
                        if state.chatProvider == .ollama { state.chatProvider = .anthropic }
                        statusMessage = String(localized: "status.local.ollama-disconnected")
                    }
                    .buttonStyle(.bordered)
                }

                Divider()

                // ── LM Studio ───────────────────────────────────────────────────
                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "#A3E635")).frame(width: 8, height: 8)
                    Text("LM Studio").font(.system(size: 12, weight: .semibold))
                    if !state.lmstudioServerURL.isEmpty {
                        Text(String(localized: "Connected"))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#22C55E"))
                    }
                }
                if state.lmstudioServerURL.isEmpty {
                    TextField("http://127.0.0.1:1234", text: $lmstudioURL)
                        .textFieldStyle(.roundedBorder)
                    Button(connectingLMStudio ? String(localized: "chat.connecting") : String(localized: "chat.connect")) {
                        Task { await connectLocal(provider: .lmstudio) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(connectingLMStudio)
                } else {
                    Text(state.lmstudioServerURL)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button(String(localized: "chat.disconnect")) {
                        state.lmstudioServerURL = ""
                        lmstudioURL = ""
                        state.fetchedProviderModels[.lmstudio] = nil
                        state.providerModelFetchError[.lmstudio] = nil
                        if state.chatProvider == .lmstudio { state.chatProvider = .anthropic }
                        statusMessage = String(localized: "status.local.lmstudio-disconnected")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Integrations section

    @ViewBuilder private var integrationsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {

                // Resend
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#22C55E")).frame(width: 8, height: 8)
                        Text("Resend").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("API key  (re_…)", text: $resendKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("From address  (you@yourdomain.com)", text: $resendFrom)
                        .textFieldStyle(.roundedBorder)
                }

                // n8n
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#F29B38")).frame(width: 8, height: 8)
                        Text("n8n").font(.system(size: 12, weight: .semibold))
                    }
                    TextField("Instance URL  (https://…)", text: $n8nUrl)
                        .textFieldStyle(.roundedBorder)
                    SecureField("API key", text: $n8nKey)
                        .textFieldStyle(.roundedBorder)
                    IntegrationFilterRow(
                        label: String(localized: "integrations.workflows"),
                        items: n8nWorkflows,
                        filter: $state.n8nWorkflowFilter,
                        loading: loadingN8n,
                        onLoad: loadN8nWorkflows
                    )
                }

                // Vercel
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#7C5CFF")).frame(width: 8, height: 8)
                        Text("Vercel").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Token", text: $vercelToken)
                        .textFieldStyle(.roundedBorder)
                    IntegrationFilterRow(
                        label: String(localized: "integrations.projects"),
                        items: vercelProjects,
                        filter: $state.vercelProjectFilter,
                        loading: loadingVercel,
                        onLoad: loadVercelProjects
                    )
                }

                // GitHub
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#F4505E")).frame(width: 8, height: 8)
                        Text("GitHub").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Personal Access Token", text: $githubToken)
                        .textFieldStyle(.roundedBorder)
                    Text(String(localized: "integrations.github.token-hint"))
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8E939C"))
                }

                // Stripe
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#0570DE")).frame(width: 8, height: 8)
                        Text("Stripe").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Secret key  (sk_live_… or sk_test_…)", text: $stripeKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Cal.com
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#C9956A")).frame(width: 8, height: 8)
                        Text("Cal.com").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("API key  (cal_live_…)", text: $calcomKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Notion
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#E8E8E8")).frame(width: 8, height: 8)
                        Text("Notion").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Integration token  (secret_…)", text: $notionKey)
                        .textFieldStyle(.roundedBorder)
                }

                Button(String(localized: "integrations.save")) { saveIntegrations() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    // MARK: - Actions

    private func applyCustomModel(_ value: String) {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { state.claudeModel = id }
    }

    private func toggleStartup(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "❌ Startup: \(error.localizedDescription)"
            launchAtStartup = !on
        }
    }

    // MARK: - App Store: hooks via NSOpenPanel + security-scoped bookmark

    #if APPSTORE
    private func pickClaudeFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Select your .claude folder (press ⇧⌘. to show hidden files)"
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let realHomePath = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? "/Users/\(NSUserName())"
        panel.directoryURL = URL(fileURLWithPath: realHomePath)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.lastPathComponent == ".claude" else {
            statusMessage = String(localized: "status.select-claude-folder")
            return nil
        }
        return url
    }

    private func installHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.hooks.title")
        alert.informativeText = String(localized: "alert.hooks.body")
        alert.addButton(withTitle: String(localized: "alert.hooks.button-install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookServer.shared.installAndWriteClaudeHooksAppStore(claudeURL: claudeURL)
            hookNeedsUpdate = false
            statusMessage = String(localized: "status.hooks-installed-claude")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: claudeURL)
            statusMessage = String(localized: "status.hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif

    private func connectLocal(provider: ChatProvider) async {
        let rawURL = provider == .ollama ? ollamaURL : lmstudioURL
        let candidate = rawURL.isEmpty
            ? (provider == .ollama ? "http://127.0.0.1:11434" : "http://127.0.0.1:1234")
            : rawURL
        let normalised = LocalChat.normaliseURL(candidate)
        guard normalised.hasPrefix("http://") || normalised.hasPrefix("https://") else {
            statusMessage = String(localized: "status.local.url-invalid")
            return
        }
        if provider == .ollama { connectingOllama = true } else { connectingLMStudio = true }
        statusMessage = ""
        let result = await LocalChat.fetchModelsResult(baseURL: normalised)
        if provider == .ollama { connectingOllama = false } else { connectingLMStudio = false }
        let name = provider == .ollama ? "Ollama" : "LM Studio"
        switch result {
        case .success(let models) where models.isEmpty:
            statusMessage = String(format: String(localized: "status.local.no-models %@"), name)
        case .success(let models):
            if provider == .ollama {
                state.ollamaServerURL = normalised
                ollamaURL = normalised
                state.fetchedProviderModels[.ollama] = nil
                state.providerModelFetchError[.ollama] = nil
            } else {
                state.lmstudioServerURL = normalised
                lmstudioURL = normalised
                state.fetchedProviderModels[.lmstudio] = nil
                state.providerModelFetchError[.lmstudio] = nil
            }
            statusMessage = String(localized: "status.local.connected \(models.count)")
        case .failure:
            statusMessage = String(format: String(localized: "status.local.unreachable %1$@ %2$@"), name, normalised)
        }
    }

    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            statusMessage = String(localized: "status.hooks-installed-settings")
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            statusMessage = String(localized: "status.hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    #if !APPSTORE
    private func triggerGeminiPreview(install: Bool) {
        do {
            geminiPendingInstall = install
            pendingGeminiJSON = try HookServer.shared.previewGeminiHooks(install: install)
            showGeminiDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmGeminiOp() {
        do {
            try HookServer.shared.writeGeminiHooks()
            showGeminiDiff = false
            pendingGeminiJSON = ""
            geminiHooksInstalled = geminiPendingInstall
            statusMessage = geminiPendingInstall
                ? String(localized: "status.gemini-hooks-installed")
                : String(localized: "status.gemini-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerAgyPreview(install: Bool) {
        do {
            agyPendingInstall = install
            pendingAgyJSON = try HookServer.shared.previewAgyHooks(install: install)
            showAgyDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmAgyOp() {
        do {
            try HookServer.shared.writeAgyHooks()
            showAgyDiff = false
            pendingAgyJSON = ""
            agyHooksInstalled = agyPendingInstall
            statusMessage = agyPendingInstall
                ? String(localized: "status.agy-hooks-installed")
                : String(localized: "status.agy-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerCodexPreview(install: Bool) {
        do {
            codexPendingInstall = install
            pendingCodexJSON = try HookServer.shared.previewCodexHooks(install: install)
            showCodexDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmCodexOp() {
        do {
            try HookServer.shared.writeCodexHooks()
            showCodexDiff = false
            pendingCodexJSON = ""
            codexHooksInstalled = codexPendingInstall
            statusMessage = codexPendingInstall
                ? String(localized: "status.codex-hooks-installed")
                : String(localized: "status.codex-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerCopilotPreview(install: Bool) {
        do {
            copilotPendingInstall = install
            pendingCopilotJSON = try HookServer.shared.previewCopilotHooks(install: install)
            showCopilotDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmCopilotOp() {
        do {
            try HookServer.shared.writeCopilotHooks()
            showCopilotDiff = false
            pendingCopilotJSON = ""
            copilotHooksInstalled = copilotPendingInstall
            statusMessage = copilotPendingInstall
                ? String(localized: "status.copilot-hooks-installed")
                : String(localized: "status.copilot-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerMusePreview(install: Bool) {
        do {
            musePendingInstall = install
            pendingMuseJSON = try HookServer.shared.previewMuseHooks(install: install)
            showMuseDiff = true
            statusMessage = String(localized: "hooks.review-json")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmMuseOp() {
        do {
            try HookServer.shared.writeMuseHooks()
            showMuseDiff = false
            pendingMuseJSON = ""
            museHooksInstalled = musePendingInstall
            statusMessage = musePendingInstall
                ? String(localized: "status.muse-hooks-installed")
                : String(localized: "status.muse-hooks-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerOpenCodePreview(install: Bool) {
        do {
            openCodePendingInstall = install
            pendingOpenCodeContent = try HookServer.shared.previewOpenCodePlugin(install: install)
            showOpenCodeDiff = true
            statusMessage = String(localized: "plugin.review-content")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmOpenCodeOp() {
        do {
            if openCodePendingInstall {
                try HookServer.shared.writeOpenCodePlugin()
            } else {
                try HookServer.shared.removeOpenCodePlugin()
            }
            showOpenCodeDiff = false
            pendingOpenCodeContent = ""
            openCodePluginInstalled = openCodePendingInstall
            statusMessage = openCodePendingInstall
                ? String(localized: "status.opencode-plugin-installed")
                : String(localized: "status.opencode-plugin-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerAmpPreview(install: Bool) {
        do {
            ampPendingInstall = install
            pendingAmpContent = try HookServer.shared.previewAmpPlugin(install: install)
            showAmpDiff = true
            statusMessage = String(localized: "plugin.review-content")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmAmpOp() {
        do {
            if ampPendingInstall {
                try HookServer.shared.writeAmpPlugin()
            } else {
                try HookServer.shared.removeAmpPlugin()
            }
            showAmpDiff = false
            pendingAmpContent = ""
            ampPluginInstalled = ampPendingInstall
            statusMessage = ampPendingInstall
                ? String(localized: "status.amp-plugin-installed")
                : String(localized: "status.amp-plugin-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerHermesPluginPreview(install: Bool) {
        do {
            hermesPluginPendingInstall = install
            pendingHermesPluginContent = try HookServer.shared.previewHermesPlugin(install: install)
            showHermesPluginDiff = true
            statusMessage = String(localized: "plugin.review-content")
        } catch let e as NSError where e.domain == "CoucouNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmHermesPluginOp() {
        do {
            if hermesPluginPendingInstall {
                try HookServer.shared.writeHermesPlugin()
            } else {
                try HookServer.shared.removeHermesPlugin()
            }
            showHermesPluginDiff = false
            pendingHermesPluginContent = ""
            hermesPluginInstalled = hermesPluginPendingInstall
            statusMessage = hermesPluginPendingInstall
                ? String(localized: "status.hermes-plugin-installed")
                : String(localized: "status.hermes-plugin-removed")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerHermesConfigPreview() {
        do {
            pendingHermesConfigContent = try HookServer.shared.previewHermesConfig(
                enableApprovals: hermesApprovalsEnabled,
                supportsTransport: hermesSupportsApprovals)
            showHermesConfigDiff = true
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmHermesConfigOp() {
        do {
            try HookServer.shared.writeHermesConfig()
            showHermesConfigDiff = false
            pendingHermesConfigContent = ""
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func installStatusLine() {
        do {
            pendingStatusLineJSON = try HookServer.shared.previewStatusLine(install: true)
            showStatusLineDiff = true
            statusLinePendingInstall = true
            statusMessage = String(localized: "hooks.review-json")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallStatusLine() {
        do {
            pendingStatusLineJSON = try HookServer.shared.previewStatusLine(install: false)
            showStatusLineDiff = true
            statusLinePendingInstall = false
            statusMessage = String(localized: "hooks.review-json")
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmStatusLine() {
        do {
            try HookServer.shared.writeStatusLine()
            showStatusLineDiff = false
            pendingStatusLineJSON = ""
            state.refreshPlanRelayState()
            if planTogglePending {
                state.showPlanInNotch = true
                planTogglePending = false
            }
            if !statusLinePendingInstall {
                state.showPlanInNotch = false
            }
            statusMessage = statusLinePendingInstall
                ? String(localized: "status.statusline-installed")
                : String(localized: "status.statusline-removed")
        } catch {
            planTogglePending = false
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif

    private func saveIntegrations() {
        saveKey("resend-api-key",  value: resendKey)
        saveKey("resend-from",     value: resendFrom)
        saveKey("n8n-url",         value: n8nUrl)
        saveKey("n8n-api-key",     value: n8nKey)
        saveKey("vercel-token",    value: vercelToken)

        // Detect GitHub token changes before writing
        let prevGithubToken = KeychainStore.shared.get("github-token")
        saveKey("github-token", value: githubToken)
        let nextGithubToken = KeychainStore.shared.get("github-token")
        if nextGithubToken != prevGithubToken {
            AppState.shared.githubPulse = nil
            AppState.shared.githubActivity = nil
            if nextGithubToken == nil { AppState.shared.githubStats = nil }
            if nextGithubToken != nil {
                GithubPoller.shared.triggerPulseNow()
                GithubPoller.shared.refreshActivityIfStale()
            }
        }

        saveKey("stripe-api-key",  value: stripeKey)
        saveKey("calcom-api-key",  value: calcomKey)
        saveKey("notion-api-key",  value: notionKey)
        statusMessage = String(localized: "status.integrations-saved")
    }

    private func saveKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainStore.shared.remove(key)
        } else {
            KeychainStore.shared.set(key, value: value)
        }
    }

    // MARK: - Vercel project list

    private func loadVercelProjects() {
        guard let token = KeychainStore.shared.get("vercel-token") else {
            statusMessage = "❌ Save Vercel token first."
            return
        }
        loadingVercel = true
        guard let url = URL(string: "https://api.vercel.com/v9/projects?limit=100") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let names: [String]
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projects = json["projects"] as? [[String: Any]] {
                names = projects.compactMap { $0["name"] as? String }.sorted()
            } else {
                names = []
            }
            DispatchQueue.main.async {
                self.vercelProjects = names
                self.loadingVercel = false
                if names.isEmpty { self.statusMessage = "❌ No Vercel projects found." }
            }
        }.resume()
    }

    // MARK: - n8n workflow list

    private func loadN8nWorkflows() {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            statusMessage = "❌ Save n8n URL and API key first."
            return
        }
        loadingN8n = true
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urls = ["\(base)/api/v1/workflows?limit=100", "\(base)/rest/workflows?limit=100"]
        fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: 0)
    }

    private func fetchN8nWorkflows(urls: [String], apiKey: String, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            DispatchQueue.main.async { self.loadingN8n = false; self.statusMessage = "❌ No n8n workflows found." }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: idx + 1)
                return
            }
            let items: [[String: Any]]
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] { items = arr }
            else if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { items = arr }
            else { items = [] }
            let names = items.compactMap { $0["name"] as? String }.sorted()
            DispatchQueue.main.async {
                self.n8nWorkflows = names
                self.loadingN8n = false
                if names.isEmpty { self.statusMessage = "❌ No n8n workflows found." }
            }
        }.resume()
    }

    @ViewBuilder
    private func pillRow(_ def: PillDefinition) -> some View {
        let isMain = def.id == state.mainPillId
        let isOn   = state.activeIntegrations.contains(def.id)
        let atMax  = state.activeIntegrations.count >= 4 && !isOn && !isMain
        let hint: String? = {
            if isMain { return nil }
            if def.comingSoon { return String(localized: "Coming soon") }
            #if !APPSTORE
            if def.id == "agent_gemini"        && !HookServer.geminiHooksInstalled()      { return String(localized: "Hooks not installed") }
            if def.id == "agent_antigravity"   && !HookServer.agyHooksInstalled()        { return String(localized: "Hooks not installed") }
            if def.id == "agent_codex"         && !HookServer.codexHooksInstalled()      { return String(localized: "Hooks not installed") }
            if def.id == "agent_copilot"       && !HookServer.copilotHooksInstalled()    { return String(localized: "Hooks not installed") }
            if def.id == "agent_muse"          && !HookServer.museHooksInstalled()       { return String(localized: "Hooks not installed") }
            if def.id == "agent_opencode"      && !HookServer.openCodePluginInstalled()  { return String(localized: "Plugin not installed") }
            if def.id == "agent_amp"           && !HookServer.ampPluginInstalled()       { return String(localized: "Plugin not installed") }
            #endif
            if def.category == .ai {
                if let provider = ChatProvider(pillID: def.id), provider.isLocal {
                    let url = provider == .ollama ? state.ollamaServerURL : state.lmstudioServerURL
                    if url.isEmpty { return String(localized: "Not connected") }
                } else {
                    let keyId = def.id == "ai_anthropic" ? "anthropic-api-key"
                               : def.id == "ai_google"    ? "google-api-key" : "openai-api-key"
                    if KeychainStore.shared.get(keyId) == nil { return String(localized: "Key not configured") }
                }
            }
            return nil
        }()
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: def.color))
                .frame(width: 10, height: 10)
            Text(def.name)
                .font(.system(size: 12))
                .foregroundColor(atMax ? .secondary : .primary)
            Spacer()
            if isMain {
                Text("Main")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                if let h = hint {
                    Text(h)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { _ in state.toggleIntegration(def.id) }
                ))
                .labelsHidden()
                .disabled(atMax)
            }
        }
    }
}

// MARK: - Sidebar background (NSVisualEffectView .sidebar)

struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Sidebar row (System Settings style icon)

struct SettingsSidebarRow: View {
    let title: String
    let icon: String
    let color: String

    var body: some View {
        Label {
            Text(LocalizedStringKey(title))
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: color)))
        }
    }
}

// MARK: - Integration filter row (reusable for Vercel / n8n)

struct IntegrationFilterRow: View {
    let label: String
    let items: [String]
    @Binding var filter: Set<String>
    let loading: Bool
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button(items.isEmpty ? "Load list" : "Refresh") { onLoad() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                if !filter.isEmpty {
                    Button("Clear") { filter = [] }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundColor(.secondary)
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        Toggle(item, isOn: Binding(
                            get: { filter.isEmpty || filter.contains(item) },
                            set: { on in
                                if on { filter.insert(item) }
                                else  {
                                    if filter.isEmpty { filter = Set(items).subtracting([item]) }
                                    else { filter.remove(item) }
                                    if filter.count == items.count { filter = [] }
                                }
                            }
                        ))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
                if !filter.isEmpty {
                    Text(String(format: String(localized: "Watching %lld of %lld"), Int64(filter.count), Int64(items.count)))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Shortcut recorder button

struct ShortcutRecorderButton: View {
    @Binding var flags: UInt
    @Binding var code: UInt16
    @State private var isRecording = false

    var body: some View {
        Button {
            guard !isRecording else { return }
            isRecording = true
            var token: Any?
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard !mods.isEmpty else { return event }
                DispatchQueue.main.async {
                    self.flags = mods.rawValue
                    self.code = event.keyCode
                    self.isRecording = false
                    if let t = token { NSEvent.removeMonitor(t) }
                }
                return nil
            }
        } label: {
            Text(isRecording ? "Press keys…" : shortcutLabel)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var shortcutLabel: String {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyChar(code)
        return s.isEmpty ? "None" : s
    }

    private func keyChar(_ c: UInt16) -> String {
        let map: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 31:"O", 32:"U",
            34:"I", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M", 49:"Space", 50:"`", 27:"-"
        ]
        return map[c] ?? "·"
    }
}
