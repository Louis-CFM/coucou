import Foundation

@MainActor
enum AgentConnections {
    static func configured() -> Set<String> {
        var ids: Set<String> = []
        if HookServer.claudeHooksInstalled() { ids.insert("integration_claude") }
        #if !APPSTORE
        let checks: [(String, () -> Bool)] = [
            ("agent_codex", HookServer.codexHooksInstalled),
            ("agent_gemini", HookServer.geminiHooksInstalled),
            ("agent_antigravity", HookServer.agyHooksInstalled),
            ("agent_copilot", HookServer.copilotHooksInstalled),
            ("agent_muse", HookServer.museHooksInstalled),
            ("agent_opencode", HookServer.openCodePluginInstalled),
            ("agent_amp", HookServer.ampPluginInstalled),
            ("agent_hermes", HookServer.hermesPluginInstalled),
        ]
        for (id, check) in checks where check() { ids.insert(id) }
        if ClaudeDesktopChatWatcher.enabled { ids.insert("agent_claude-desktop") }
        #endif
        return ids
    }

    static func isAgent(_ id: String) -> Bool {
        AgentDisplayPolicy.isAgent(id)
    }
}

extension Notification.Name {
    static let agentsOnlyModeChanged = Notification.Name("agentsOnlyModeChanged")
}
