import AppKit

/// All four return actions use the observed host and project; unknown hosts stay unknown.
@MainActor
enum SessionTarget {
    static func actionLabel(for task: AgentTask?) -> String {
        guard let task else { return String(localized: "session.open-source", defaultValue: "Open session source") }
        if task.codexManaged { return String(localized: "codex.continue-chat", defaultValue: "Continue chat") }
        switch sourceBundleId(for: task) {
        case "com.openai.codex":
            return String(localized: "codex.open-desktop", defaultValue: "Open Codex")
        case "com.openai.chat" where task.id == "agent_codex":
            return String(localized: "codex.open-desktop", defaultValue: "Open Codex")
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92":
            return String(localized: "session.open-editor", defaultValue: "Open editor")
        case "com.anthropic.claudefordesktop":
            return String(localized: "Open Claude")
        case let bundleId?:
            if ClaudeHost.terminal(termProgram: "", bundleId: bundleId) != nil { return String(localized: "Open terminal") }
            fallthrough
        default:
            return String(localized: "session.open-source", defaultValue: "Open session source")
        }
    }

    static func open(_ task: AgentTask?) {
        guard let task else { return }
        let state = AppState.shared
        if task.codexManaged {
            state.chatProvider = .codex
            state.view = .prompt
            return
        }
        let bundleId = sourceBundleId(for: task)
        var appURL = bundleId.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        // A Codex source may use ChatGPT's host bundle; other agents never use this fallback.
        if appURL == nil, task.id == "agent_codex", bundleId == "com.openai.codex" {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat")
        }
        guard let bundleId, let appURL else {
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

    private static func sourceBundleId(for task: AgentTask) -> String? {
        if let bundleId = task.sessionBundleId { return bundleId.isEmpty ? nil : bundleId }
        if let hostApp = task.hostApp, !hostApp.isEmpty { return hostApp }
        switch task.id {
        case "integration_claude": return "com.microsoft.VSCode"
        case "agent_cursor": return "com.todesktop.230313mzl4w4u92"
        case "agent_claude-desktop": return "com.anthropic.claudefordesktop"
        default: return nil
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
