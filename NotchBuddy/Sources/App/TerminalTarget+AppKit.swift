import AppKit

extension TerminalTarget {
    /// Brings the session's terminal to the front: the app the session runs in first,
    /// then the first running known terminal, on the session's own tab when `tty` is known
    /// (see ClaudeHost.bringForward). Returns false if none is running.
    @discardableResult
    static func activate(sessionBundleId: String?, tty: String? = nil) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.compactMap(\.bundleIdentifier))
        guard let id = pick(sessionBundleId: sessionBundleId, running: running),
              let url = apps.first(where: { $0.bundleIdentifier == id })?.bundleURL else { return false }
        ClaudeHost.bringForward(url, bundleId: id, tty: tty)
        return true
    }
}
