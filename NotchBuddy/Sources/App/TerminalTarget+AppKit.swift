import AppKit

extension TerminalTarget {
    /// Brings the session's terminal to the front: the app the session runs in first,
    /// then the first running known terminal. Returns false if none is running.
    @discardableResult
    static func activate(
        sessionBundleId: String?,
        tty: String? = nil,
        cwd: String? = nil,
        itermSessionId: String? = nil
    ) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.compactMap(\.bundleIdentifier))
        guard let id = pick(sessionBundleId: sessionBundleId, running: running) else { return false }
        ClaudeHost.focusBundle(id, tty: tty, cwd: cwd, itermSessionId: itermSessionId)
        return true
    }
}
