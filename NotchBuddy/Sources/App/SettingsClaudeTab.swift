import SwiftUI
import AppKit

struct SettingsClaudeTab: View {
    @State private var apiKey: String = KeychainStore.shared.get("anthropic-api-key") ?? ""
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()
    @State private var status: SettingsStatus?

    var body: some View {
        SettingsPage(status: status) {
            Section {
                SecureField("API key", text: $apiKey, prompt: Text(verbatim: "sk-ant-…"))
                HStack {
                    Spacer()
                    Button("Save") {
                        KeychainStore.shared.set("anthropic-api-key", value: apiKey)
                        status = .success(String(localized: "Key saved."))
                    }
                    .buttonStyle(.borderedProminent)
                }
            } header: {
                Text("Anthropic API")
            } footer: {
                Text("Stored in the macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section {
                if hookNeedsUpdate { outdatedHooksWarning }
                LabeledContent("Hook script") {
                    Text(verbatim: hookScriptLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                hookButtons
                #if !APPSTORE
                if showDiff { diffPreview }
                #endif
            } header: {
                Text("Claude Code Hooks")
            } footer: {
                Text("Coucou never overwrites ~/.claude/settings.json: it makes a dated backup, merges its hooks and writes only after you confirm.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var hookScriptLabel: String {
        #if APPSTORE
        return "~/.claude/coucou/nb-hook"
        #else
        return HookServer.hookScriptPath
        #endif
    }

    private var outdatedHooksWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Hook timeout outdated — update to fix approvals")
                .font(.system(size: 12))
            Spacer()
            #if APPSTORE
            Button("Update hooks") { installHooksAppStore() }
            #else
            Button("Update hooks") { installHooks() }
            #endif
        }
    }

    private var hookButtons: some View {
        HStack(spacing: 10) {
            Spacer()
            #if APPSTORE
            Button("Uninstall") { uninstallHooksAppStore() }
            Button("Install hooks") { installHooksAppStore() }
                .buttonStyle(.borderedProminent)
            #else
            Button("Uninstall") { uninstallHooks() }
            Button("Install hooks") { installHooks() }
                .buttonStyle(.borderedProminent)
            #endif
        }
    }

    // MARK: - App Store: hooks via NSOpenPanel

    #if APPSTORE
    /// Opens NSOpenPanel to select ~/.claude, then writes hooks directly.
    /// NSOpenPanel grants sandbox access immediately — no security-scoped bookmark needed.
    private func pickClaudeFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Select your .claude folder (press ⇧⌘. to show hidden files)")
        panel.prompt = String(localized: "Select")
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
            status = .failure(String(localized: "Select the .claude folder (hidden, in your Home directory)."))
            return nil
        }
        return url
    }

    private func installHooksAppStore() {
        guard let claudeURL = pickClaudeFolder() else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Install Coucou hooks in ~/.claude?")
        alert.informativeText = String(localized: "Will write:\n• ~/.claude/coucou/nb-hook\n• ~/.claude/settings.json (backup created first)")
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HookServer.shared.installAndWriteClaudeHooksAppStore(claudeURL: claudeURL)
            hookNeedsUpdate = false
            status = .success(String(localized: "Hooks installed — restart VS Code to activate."))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func uninstallHooksAppStore() {
        guard let claudeURL = pickClaudeFolder() else { return }
        do {
            try HookServer.shared.uninstallClaudeHooksAppStore(claudeURL: claudeURL)
            status = .success(String(localized: "Hooks removed."))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
    #endif

    // MARK: - Direct install (Developer ID build): diff preview, then explicit confirm

    #if !APPSTORE
    private var diffPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(verbatim: pendingHookJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(height: 200)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))

            HStack {
                Spacer()
                Button("Cancel") { showDiff = false; pendingHookJSON = "" }
                Button("Confirm & write") { confirmInstall() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
    #endif

    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            status = .info(String(localized: "Review the JSON below before confirming."))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            status = .success(String(localized: "Hooks installed in ~/.claude/settings.json"))
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            status = .failure(String(localized: "Write error: \(error.localizedDescription)"))
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            status = .success(String(localized: "Hooks removed."))
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
