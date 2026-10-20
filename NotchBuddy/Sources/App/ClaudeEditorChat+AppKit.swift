import AppKit

extension ClaudeEditorChat {
    /// Brings back the exact chat tab of a VS Code session: the project folder first (it brings
    /// the right VS Code window forward, and the link opens in the focused window), then the link.
    /// Returns false when the task is not a VS Code chat, so the caller keeps its own fallback.
    @MainActor
    @discardableResult
    static func open(_ task: AgentTask?) -> Bool {
        guard let task, task.id == "integration_claude", task.hostApp == nil,
              let session = task.editorChatSession,
              let bundleId = task.sessionBundleId,
              let link = url(sessionId: session, bundleId: bundleId) else { return false }
        guard let cwd = task.sessionCwd, !cwd.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return NSWorkspace.shared.open(link)
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSWorkspace.shared.open(link)
            }
        }
        return true
    }
}
