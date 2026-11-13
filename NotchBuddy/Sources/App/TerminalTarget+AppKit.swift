import AppKit

extension TerminalTarget {
    /// Brings the session's terminal to the front: the app the session runs in first,
    /// then the first running known terminal. Returns false if none is running.
    @discardableResult
    static func activate(sessionBundleId: String?) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.compactMap(\.bundleIdentifier))
        guard let id = pick(sessionBundleId: sessionBundleId, running: running),
              let url = apps.first(where: { $0.bundleIdentifier == id })?.bundleURL else { return false }
        // Not NSRunningApplication.activate(): since macOS 14 it is ignored when called
        // from an app that is not active, and the island never is.
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        return true
    }
}
