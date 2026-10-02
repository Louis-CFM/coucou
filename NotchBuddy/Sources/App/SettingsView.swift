import SwiftUI
import ServiceManagement
import AppKit

private enum SettingsPage: String, CaseIterable, Identifiable {
    case notch, chat, hooks, services

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notch: return "Notch"
        case .chat: return "Chat"
        case .hooks: return "Hooks"
        case .services: return "Services"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
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
    #endif

    // Multi-provider chat keys
    @State private var googleKey: String  = KeychainStore.shared.get("google-api-key") ?? ""
    @State private var openAIKey: String  = KeychainStore.shared.get("openai-api-key") ?? ""

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

    // Chat engine detection in progress
    @State private var detectingCLIs: Bool = false
    @State private var settingsPage: SettingsPage = .notch

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(CoucouL10n.string("Section"), selection: $settingsPage) {
                ForEach(SettingsPage.allCases) { page in
                    Text(CoucouL10n.string(page.title)).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                if settingsPage == .notch {
                GroupBox(CoucouL10n.string("Language")) {
                    Picker(CoucouL10n.string("Language"), selection: $state.appLanguage) {
                        Text(CoucouL10n.string("English")).tag(AppLanguage.en)
                        Text(CoucouL10n.string("Español")).tag(AppLanguage.es)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(6)
                }

                // MARK: Active pills
                GroupBox(CoucouL10n.string("Active pills")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(CoucouL10n.string("Choose the tools you use. Coucou only shows what you declare here."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Text(CoucouL10n.format("%d/4 slots used", state.activeIntegrations.count))
                            .font(.system(size: 11))
                            .foregroundColor(state.activeIntegrations.count >= 4 ? .orange : .secondary)

                        Picker("Main", selection: $state.mainPillId) {
                            ForEach(PillCatalog.available.filter { $0.category == .workspace && !$0.comingSoon }, id: \.id) { def in
                                Text(def.name).tag(def.id)
                            }
                        }
                        .onChange(of: state.mainPillId) { _, newId in
                            state.activeIntegrations.remove(newId)
                            state.loadIntegrationTasks()
                            state.setFocus(newId)
                        }

                        // All categories — main pill shown with "Main" label instead of toggle
                        ForEach(PillCategory.allCases, id: \.self) { cat in
                            let catPills = PillCatalog.available.filter { $0.category == cat }
                            if !catPills.isEmpty {
                                Divider()
                                Text(CoucouL10n.string(cat.title))
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

                // MARK: Timings
                GroupBox(CoucouL10n.string("Behavior")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(CoucouL10n.string("Occasional idle glances"), isOn: $state.idleAnimationsEnabled)
                        Text(CoucouL10n.string("Mochi occasionally looks around and blinks while resting. Respects Reduce Motion."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Text(CoucouL10n.string("Close after"))
                            TextField("60", value: $state.autoCloseInterval, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 64)
                            Text(CoucouL10n.string("s inactive"))
                        }
                        HStack(spacing: 8) {
                            Text(CoucouL10n.string("Hide after"))
                            TextField("3", value: absenceMinutes, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 48)
                            Text(CoucouL10n.string("min without movement"))
                        }
                    }
                    .padding(6)
                }

                // MARK: Son
                GroupBox(CoucouL10n.string("Sound")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(CoucouL10n.string("Enable sounds"), isOn: $state.soundEnabled)
                        HStack(spacing: 8) {
                            Text(CoucouL10n.string("Volume"))
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

                // MARK: Hotkey
                GroupBox(CoucouL10n.string("Hotkey")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(CoucouL10n.string("Show island with shortcut"), isOn: $state.hotkeyEnabled)
                        if state.hotkeyEnabled {
                            HStack(spacing: 8) {
                                Text(CoucouL10n.string("Shortcut"))
                                    .frame(width: 70, alignment: .leading)
                                ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                                    .onChange(of: hotkeyFlags) { _, v in state.hotkeyFlags = v }
                                    .onChange(of: hotkeyCode)  { _, v in state.hotkeyCode  = v }
                                Text(CoucouL10n.string("presses this → island opens"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(6)
                }

                // MARK: Startup
                GroupBox(CoucouL10n.string("Startup")) {
                    Toggle(CoucouL10n.string("Launch at Mac startup"), isOn: $launchAtStartup)
                        .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }
                        .padding(6)
                }

                } // notch

                if settingsPage == .chat {
                // MARK: Chat engine
                #if APPSTORE
                GroupBox(CoucouL10n.string("Anthropic API")) {
                    VStack(alignment: .leading, spacing: 8) {
                        apiKeyField
                    }
                    .padding(6)
                }
                #else
                GroupBox(CoucouL10n.string("Chat")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(CoucouL10n.string("Who answers in the notch chat. Local CLIs use the login you already have — no API key."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ForEach(ChatEngine.allCases) { engine in
                            engineRow(engine)
                        }

                        HStack(spacing: 8) {
                            Button(CoucouL10n.string("Detect again")) {
                                detectingCLIs = true
                                Task {
                                    await state.detectCLIs()
                                    detectingCLIs = false
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(detectingCLIs)
                            if detectingCLIs {
                                ProgressView().controlSize(.small)
                            }
                        }

                        if state.chatEngine == .api {
                            apiKeyField
                        }
                    }
                    .padding(6)
                }
                .task {
                    if !state.cliDetectionDone {
                        detectingCLIs = true
                        await state.detectCLIs()
                        detectingCLIs = false
                    }
                }
                #endif

                if state.chatEngine == .api {
                GroupBox(CoucouL10n.string("Chat — other providers")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(CoucouL10n.string("To use Google Gemini or OpenAI from the chat. Keys are stored in the Keychain."))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: "#4285F4")).frame(width: 8, height: 8)
                            Text("Google AI").font(.system(size: 12, weight: .semibold))
                        }
                        SecureField("API key (AI Studio)", text: $googleKey)
                            .textFieldStyle(.roundedBorder)
                        Button(CoucouL10n.string("Save")) {
                            KeychainStore.shared.set("google-api-key", value: googleKey)
                            statusMessage = "✓ Google key saved."
                        }
                        .buttonStyle(.borderedProminent)

                        Divider()

                        HStack(spacing: 8) {
                            Circle().fill(Color(hex: "#10A37F")).frame(width: 8, height: 8)
                            Text("OpenAI").font(.system(size: 12, weight: .semibold))
                        }
                        SecureField("API key (sk-…)", text: $openAIKey)
                            .textFieldStyle(.roundedBorder)
                        Button(CoucouL10n.string("Save")) {
                            KeychainStore.shared.set("openai-api-key", value: openAIKey)
                            statusMessage = "✓ OpenAI key saved."
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
                }
                } // chat

                if settingsPage == .hooks {
                // MARK: Hooks
                GroupBox(CoucouL10n.string("Claude Code Hooks")) {
                    VStack(alignment: .leading, spacing: 10) {
                        if hookNeedsUpdate {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text(CoucouL10n.string("Hook timeout outdated — update to fix approvals"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                            }
                            #if APPSTORE
                            Button(CoucouL10n.string("Update hooks")) { installHooksAppStore() }
                            #else
                            Button(CoucouL10n.string("Update hooks")) { installHooks() }
                            #endif
                        }
                        #if APPSTORE
                        Text("~/.claude/coucou/nb-hook")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button(CoucouL10n.string("Install hooks")) { installHooksAppStore() }
                                .buttonStyle(.borderedProminent)
                            Button(CoucouL10n.string("Uninstall")) { uninstallHooksAppStore() }
                                .buttonStyle(.bordered)
                        }
                        #else
                        Text("nb-hook : \(HookServer.hookScriptPath)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button(CoucouL10n.string("Install hooks")) { installHooks() }
                                .buttonStyle(.borderedProminent)
                            Button(CoucouL10n.string("Uninstall")) { uninstallHooks() }
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
                                Button(CoucouL10n.string("Confirm & write")) { confirmInstall() }
                                    .buttonStyle(.borderedProminent)
                                Button(CoucouL10n.string("Cancel")) { showDiff = false; pendingHookJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                        #endif
                    }
                    .padding(6)
                }

                // MARK: Gemini CLI Hooks / Antigravity Hooks
                #if !APPSTORE
                if state.activeIntegrations.contains("agent_gemini") {
                GroupBox(CoucouL10n.string("Gemini CLI Hooks")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(geminiHooksInstalled
                             ? "Hooks installed — restart Gemini CLI to activate"
                             : "~/.gemini/settings.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button(CoucouL10n.string("Install hooks")) { triggerGeminiPreview(install: true) }
                                .buttonStyle(.borderedProminent)
                            Button(CoucouL10n.string("Uninstall")) { triggerGeminiPreview(install: false) }
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
                                Button(CoucouL10n.string("Confirm & write")) { confirmGeminiOp() }
                                    .buttonStyle(.borderedProminent)
                                Button(CoucouL10n.string("Cancel")) { showGeminiDiff = false; pendingGeminiJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(6)
                }
                }

                if state.activeIntegrations.contains("agent_antigravity") {
                GroupBox(CoucouL10n.string("Antigravity Hooks")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(agyHooksInstalled
                             ? "Hooks installed — restart Antigravity to activate"
                             : "~/.gemini/config/hooks.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button(CoucouL10n.string("Install hooks")) { triggerAgyPreview(install: true) }
                                .buttonStyle(.borderedProminent)
                            Button(CoucouL10n.string("Uninstall")) { triggerAgyPreview(install: false) }
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
                                Button(CoucouL10n.string("Confirm & write")) { confirmAgyOp() }
                                    .buttonStyle(.borderedProminent)
                                Button(CoucouL10n.string("Cancel")) { showAgyDiff = false; pendingAgyJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(6)
                }
                }
                #endif

                #if !APPSTORE
                GroupBox("Codex Hooks") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(codexHooksInstalled
                             ? "Hooks installed — open Codex and run /hooks or open Hooks in the app's settings to trust them"
                             : "~/.codex/hooks.json")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            Button(CoucouL10n.string("Install hooks")) { triggerCodexPreview(install: true) }
                                .buttonStyle(.borderedProminent)
                            Button(CoucouL10n.string("Uninstall")) { triggerCodexPreview(install: false) }
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
                                Button(CoucouL10n.string("Confirm & write")) { confirmCodexOp() }
                                    .buttonStyle(.borderedProminent)
                                Button(CoucouL10n.string("Cancel")) { showCodexDiff = false; pendingCodexJSON = "" }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(6)
                }
                #endif

                } // hooks

                if settingsPage == .services {
                if state.activeIntegrations.contains(where: {
                    $0.hasPrefix("integration_") && $0 != "integration_claude"
                }) {
                GroupBox(CoucouL10n.string("Integrations")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(CoucouL10n.string("Keys for the services you turned on in Notch."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        if state.activeIntegrations.contains("integration_resend") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#22C55E")).frame(width: 8, height: 8)
                                Text("Resend").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("API key  (re_…)", text: $resendKey)
                                .textFieldStyle(.roundedBorder)
                            TextField(CoucouL10n.string("From address  (you@yourdomain.com)"), text: $resendFrom)
                                .textFieldStyle(.roundedBorder)
                        }
                        }

                        if state.activeIntegrations.contains("integration_n8n") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#F29B38")).frame(width: 8, height: 8)
                                Text("n8n").font(.system(size: 12, weight: .semibold))
                            }
                            TextField(CoucouL10n.string("Instance URL  (https://…)"), text: $n8nUrl)
                                .textFieldStyle(.roundedBorder)
                            SecureField("API key", text: $n8nKey)
                                .textFieldStyle(.roundedBorder)
                            IntegrationFilterRow(
                                label: "Workflows",
                                items: n8nWorkflows,
                                filter: $state.n8nWorkflowFilter,
                                loading: loadingN8n,
                                onLoad: loadN8nWorkflows
                            )
                        }
                        }

                        if state.activeIntegrations.contains("integration_vercel") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#7C5CFF")).frame(width: 8, height: 8)
                                Text("Vercel").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField(CoucouL10n.string("Token"), text: $vercelToken)
                                .textFieldStyle(.roundedBorder)
                            IntegrationFilterRow(
                                label: "Projects",
                                items: vercelProjects,
                                filter: $state.vercelProjectFilter,
                                loading: loadingVercel,
                                onLoad: loadVercelProjects
                            )
                        }
                        }

                        if state.activeIntegrations.contains("integration_github") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#F4505E")).frame(width: 8, height: 8)
                                Text("GitHub").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField(CoucouL10n.string("Personal Access Token"), text: $githubToken)
                                .textFieldStyle(.roundedBorder)
                        }
                        }

                        if state.activeIntegrations.contains("integration_stripe") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#0570DE")).frame(width: 8, height: 8)
                                Text("Stripe").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField(CoucouL10n.string("Secret key  (sk_live_… or sk_test_…)"), text: $stripeKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        }

                        if state.activeIntegrations.contains("integration_calcom") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#C9956A")).frame(width: 8, height: 8)
                                Text("Cal.com").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField("API key  (cal_live_…)", text: $calcomKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        }

                        if state.activeIntegrations.contains("integration_notion") {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#E8E8E8")).frame(width: 8, height: 8)
                                Text("Notion").font(.system(size: 12, weight: .semibold))
                            }
                            SecureField(CoucouL10n.string("Integration token  (secret_…)"), text: $notionKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        }

                        Button(CoucouL10n.string("Save integrations")) { saveIntegrations() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(6)
                }
                } else {
                    Text(CoucouL10n.string("Turn a service on in Notch. Its key shows up here."))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                } // services
                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusMessage.hasPrefix("❌") ? .red : .secondary)
                        .padding(.horizontal, 2)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .onAppear {
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
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity)
        .id(state.appLanguage)
        }
    }

    // MARK: - Chat engine

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("API key (sk-ant-…)", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            Button(CoucouL10n.string("Save")) {
                KeychainStore.shared.set("anthropic-api-key", value: apiKey)
                statusMessage = "✓ Key saved."
            }
            .buttonStyle(.borderedProminent)

            Divider().padding(.vertical, 2)

            Picker(CoucouL10n.string("Model"), selection: $modelChoice) {
                ForEach(displayModels, id: \.id) { preset in
                    Text(preset.label).tag(preset.id)
                }
                Text(CoucouL10n.string("Custom…")).tag(Self.customModelTag)
            }
            .onChange(of: modelChoice) { _, choice in
                if choice != Self.customModelTag {
                    state.claudeModel = choice
                } else {
                    applyCustomModel(customModel)
                }
            }

            if modelChoice == Self.customModelTag {
                TextField(CoucouL10n.string("Model ID (e.g. claude-sonnet-4-6)"), text: $customModel)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: customModel) { _, value in applyCustomModel(value) }
            }

            Text(CoucouL10n.string("Used by the chat. The list comes from your Anthropic account."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func engineRow(_ engine: ChatEngine) -> some View {
        let info = state.detectedCLIs[engine]
        let available = engine == .api || info != nil
        let selected = state.chatEngine == engine

        let detail: String
        if engine == .api {
            detail = KeychainStore.shared.get("anthropic-api-key") == nil ? "Needs an API key" : "API key saved"
        } else if let info {
            detail = [info.version, info.path].compactMap { $0 }.joined(separator: " · ")
        } else {
            detail = state.cliDetectionDone ? "Not installed" : "Looking…"
        }

        return Button {
            guard !selected else { return }
            state.chatEngine = engine
            // A new engine starts a new conversation.
            ClaudeService.shared.clearConversation()
            state.chatHistory = []
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.label).font(.system(size: 12, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(available ? .secondary : .orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.55)
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
    /// Opens NSOpenPanel to select ~/.claude, then writes hooks directly.
    /// NSOpenPanel grants sandbox access immediately — no security-scoped bookmark needed.
    private func pickClaudeFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Select your .claude folder (press ⇧⌘. to show hidden files)"
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // getpwuid bypasses CFFIXED_USER_HOME and always returns the real user home
        let realHomePath = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? "/Users/\(NSUserName())"
        panel.directoryURL = URL(fileURLWithPath: realHomePath)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.lastPathComponent == ".claude" else {
            statusMessage = "❌ Select the .claude folder (hidden, in your Home directory)."
            return nil
        }
        return url
    }

    private func installHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        let alert = NSAlert()
        alert.messageText = "Install Coucou hooks in ~/.claude?"
        alert.informativeText = "Will write:\n• ~/.claude/coucou/nb-hook\n• ~/.claude/settings.json (backup created first)"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookServer.shared.installAndWriteClaudeHooksAppStore(claudeURL: claudeURL)
            hookNeedsUpdate = false
            statusMessage = "✓ Hooks installed — restart VS Code to activate."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func uninstallHooksAppStore() {
        guard let claudeURL = pickClaudeFolder(prompt: "Select") else { return }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: claudeURL)
            statusMessage = "✓ Hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
    #endif

    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            statusMessage = "Review the JSON below before confirming."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            statusMessage = "✓ Hooks installed in ~/.claude/settings.json"
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Write error: \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            statusMessage = "✓ Hooks removed."
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
            statusMessage = "Review the JSON below before confirming."
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
                ? "✓ Gemini CLI hooks installed in ~/.gemini/settings.json"
                : "✓ Gemini CLI hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerAgyPreview(install: Bool) {
        do {
            agyPendingInstall = install
            pendingAgyJSON = try HookServer.shared.previewAgyHooks(install: install)
            showAgyDiff = true
            statusMessage = "Review the JSON below before confirming."
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
                ? "✓ Antigravity hooks installed in ~/.gemini/config/hooks.json"
                : "✓ Antigravity hooks removed."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerCodexPreview(install: Bool) {
        do {
            codexPendingInstall = install
            pendingCodexJSON = try HookServer.shared.previewCodexHooks(install: install)
            showCodexDiff = true
            statusMessage = "Review the JSON below before confirming."
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
                ? "✓ Codex hooks installed — run /hooks in Codex or open Hooks in the app's settings to trust them."
                : "✓ Codex hooks removed."
        } catch {
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
        saveKey("github-token",    value: githubToken)
        saveKey("stripe-api-key",  value: stripeKey)
        saveKey("calcom-api-key",  value: calcomKey)
        saveKey("notion-api-key",  value: notionKey)
        statusMessage = "✓ Integration keys saved."
    }

    /// Saves non-empty value; removes only if key was previously set (explicit user clear).
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
        VercelPoller.fetchProjectNames(token: token) { names in
            self.vercelProjects = names
            self.loadingVercel = false
            if names.isEmpty { self.statusMessage = "❌ No Vercel projects found." }
        }
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
        // Status hint: shown in 11pt gray before the toggle (not shown for main pill)
        let hint: String? = {
            if isMain { return nil }
            if def.comingSoon { return CoucouL10n.string("Coming soon") }
            #if !APPSTORE
            if def.id == "agent_gemini"      && !HookServer.geminiHooksInstalled() { return CoucouL10n.string("Hooks not installed") }
            if def.id == "agent_antigravity" && !HookServer.agyHooksInstalled()    { return CoucouL10n.string("Hooks not installed") }
            if def.id == "agent_codex"       && !HookServer.codexHooksInstalled()  { return CoucouL10n.string("Hooks not installed") }
            #endif
            if def.category == .ai {
                let keyId = def.id == "ai_anthropic" ? "anthropic-api-key"
                           : def.id == "ai_google"    ? "google-api-key" : "openai-api-key"
                if KeychainStore.shared.get(keyId) == nil { return CoucouL10n.string("Key not configured") }
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
                    Button(CoucouL10n.string("Clear")) { filter = [] }
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
                                    // First click on any item: switch from "all" to explicit set
                                    if filter.isEmpty { filter = Set(items).subtracting([item]) }
                                    else { filter.remove(item) }
                                    if filter.count == items.count { filter = [] } // all = empty
                                }
                            }
                        ))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
                if !filter.isEmpty {
                    Text("Watching \(filter.count) of \(items.count)")
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
