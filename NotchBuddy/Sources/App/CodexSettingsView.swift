import SwiftUI
import AppKit

/// Codex is an optional provider. Its hook config never changes Claude settings.
struct CodexSettingsView: View {
    @State private var preview: CodexHooks.Preview?
    @State private var message = ""
    @State private var directory: URL? = CodexSettingsView.initialDirectory()

    private static func initialDirectory() -> URL? {
        #if APPSTORE
        guard let data = UserDefaults.standard.data(forKey: "codexDirectoryBookmark") else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale else { return nil }
        return url
        #else
        return CodexHooks.defaultDirectory
        #endif
    }

    private func installer(_ directory: URL) -> CodexHooks {
        #if APPSTORE
        let path = directory.appendingPathComponent("coucou/nb-hook").path
        #else
        let path = HookServer.hookScriptPath
        #endif
        // Keep upstream's fail-open shell wrapper, including its developer-tools guard.
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        return CodexHooks(directory: directory, relayCommand: "/bin/sh \(quoted) --codex")
    }

    var body: some View {
        GroupBox("Codex (optional coding-agent provider)") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Session activity and Allow / Deny through local lifecycle hooks. Chat stays on the Anthropic API.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if let directory {
                    Text(directory.appendingPathComponent("hooks.json").path)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Install hooks…") { makePreview(install: true) }
                        Button("Uninstall hooks…") { makePreview(install: false) }
                    }
                }
                #if APPSTORE
                Button("Choose Codex configuration folder…") { chooseFolder() }
                #endif
                if let preview {
                    ScrollView {
                        Text(preview.diff).font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.frame(height: 140)
                    HStack {
                        Button("Back up & apply") { confirm() }.buttonStyle(.borderedProminent)
                        Button("Cancel") { self.preview = nil }
                    }
                }
                Text("Open a new Codex session, then review and trust the new hook definitions using /hooks.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                if !message.isEmpty { Text(message).font(.system(size: 11)).textSelection(.enabled) }
            }.padding(6)
        }
    }

    private func makePreview(install: Bool) {
        guard let directory else { return }
        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
        do {
            preview = try installer(directory).preview(install: install)
            message = "Review both versions before confirming. Existing hook handlers are preserved."
        } catch { preview = nil; message = error.localizedDescription }
    }

    private func confirm() {
        guard let directory, let preview else { return }
        let accessing = directory.startAccessingSecurityScopedResource()
        defer { if accessing { directory.stopAccessingSecurityScopedResource() } }
        do {
            // Relay materialization is explicit, not a side effect of preview.
            if preview.install { try HookServer.shared.installCodexRelay(directory: directory) }
            let backup = try installer(directory).apply(preview)
            self.preview = nil
            AppState.shared.loadIntegrationTasks()
            message = backup.map { "Applied. Backup: \($0.path)" } ?? "Applied. No previous hooks.json existed."
        } catch { message = error.localizedDescription }
    }

    #if APPSTORE
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.canCreateDirectories = true
        // The sandbox home is not the developer's actual Codex configuration folder.
        let realHome = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? "/Users/\(NSUserName())"
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        } else {
            panel.directoryURL = URL(fileURLWithPath: realHome).appendingPathComponent(".codex")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: "codexDirectoryBookmark")
            directory = url
            preview = nil
        } catch { message = error.localizedDescription }
    }
    #endif
}
