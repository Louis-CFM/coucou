import SwiftUI

// MARK: - Per-session tracking (several chats share one pill)

struct AgentSession: Identifiable, Equatable {
    let id: String          // session_id from the hook payload
    let pillId: String
    var bundleId: String    // app the session runs in (terminal, VS Code…)
    var lastActivity: Date
}

extension AppState {

    func sessions(for pillId: String) -> [AgentSession] {
        agentSessions.filter { $0.pillId == pillId }.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Records one hook event for its session. SessionEnd removes it; sessions quiet for 6 h are dropped
    /// (a closed terminal never sends SessionEnd).
    func trackSession(id: String, pillId: String, bundleId: String, event: String) {
        guard id != "unknown" else { return }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        agentSessions.removeAll { $0.lastActivity < cutoff || $0.id == id }
        guard event != "SessionEnd" else { return }
        agentSessions.append(AgentSession(id: id, pillId: pillId, bundleId: bundleId, lastActivity: Date()))
    }

    /// Brings the session's app to the front, else the first running terminal.
    static func openSessionApp(_ session: AgentSession?) {
        var bundleIds = ["com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
        if let id = session?.bundleId, !id.isEmpty { bundleIds.insert(id, at: 0) }
        if let hit = bundleIds.compactMap({ id in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
        }).first {
            hit.activate(options: .activateIgnoringOtherApps)
        }
    }
}
