import AppKit

/// All four return actions use the observed host and project; unknown hosts stay unknown.
@MainActor
enum SessionTarget {
    static func open(_ task: AgentTask?) {
        guard let task else { return }
        let state = AppState.shared
        if task.codexManaged {
            state.chatProvider = .codex
            state.view = .prompt
            return
        }
        let defaultBundleId: String?
        switch task.id {
        case "integration_claude": defaultBundleId = "com.microsoft.VSCode"
        case "agent_cursor": defaultBundleId = "com.todesktop.230313mzl4w4u92"
        case "agent_claude-desktop": defaultBundleId = "com.anthropic.claudefordesktop"
        default: defaultBundleId = nil
        }
        let sourceBundleId = task.sessionBundleId ?? defaultBundleId
        guard let bundleId = sourceBundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            state.noteMessage = String(localized: "session.host-unavailable", defaultValue: "The session's source app is unknown or unavailable. Open it from your editor.")
            state.view = .note
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let cwd = task.sessionCwd, !cwd.isEmpty,
           ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92"].contains(bundleId) {
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd, isDirectory: true)], withApplicationAt: appURL, configuration: config) { _, error in
                if let error { Task { @MainActor in state.noteMessage = error.localizedDescription; state.view = .note } }
            }
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
                if let error { Task { @MainActor in state.noteMessage = error.localizedDescription; state.view = .note } }
            }
        }
    }

    static func bundleId(payload: [String: Any]) -> String? {
        // Desktop currently reports source "vscode", but declares its own originator.
        if payload["coucou_agent"] as? String == "codex",
           (payload["originator"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "codex desktop" {
            return "com.openai.codex"
        }
        if let bundle = payload["bundle_id"] as? String, !bundle.isEmpty { return bundle }
        let termProgram = payload["term_program"] as? String ?? ""
        if let host = ClaudeHost.terminal(termProgram: termProgram, bundleId: "") { return host.bundleId }
        switch termProgram.lowercased() {
        case "vscode": return "com.microsoft.VSCode"
        case "codex": return "com.openai.codex"
        default: return nil
        }
    }
}
