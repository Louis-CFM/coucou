import AppKit

extension TerminalTarget {
    /// Brings the session's terminal to the front: the app the session runs in first,
    /// then the first running known terminal. Returns false if none is running.
    /// Opened through Launch Services, as NSRunningApplication.activate() is ignored on
    /// macOS 14+ unless the caller is the active app.
    @discardableResult
    static func activate(sessionBundleId: String?) -> Bool {
        let apps = NSWorkspace.shared.runningApplications
        let running = Set(apps.compactMap(\.bundleIdentifier))
        guard let id = pick(sessionBundleId: sessionBundleId, running: running),
              let url = apps.first(where: { $0.bundleIdentifier == id })?.bundleURL else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        return true
    }
}
