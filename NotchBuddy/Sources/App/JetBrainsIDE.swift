import AppKit
import ApplicationServices

// MARK: - JetBrainsIDE
//
// The JetBrains IDE a Claude Code session runs in, from the hook payload's bundle_id.
// The IDE's integrated terminal inherits its __CFBundleIdentifier and sets no
// TERM_PROGRAM, so the bundle id is the only reliable signal.

enum JetBrainsIDE {
    /// Known IDEs, in the order "Open" tries them when no session names one.
    private static let ides: [(bundleId: String, name: String)] = [
        ("com.jetbrains.WebStorm",    "WebStorm"),
        ("com.jetbrains.intellij",    "IntelliJ IDEA"),
        ("com.jetbrains.intellij.ce", "IntelliJ IDEA CE"),
        ("com.jetbrains.pycharm",     "PyCharm"),
        ("com.jetbrains.pycharm.ce",  "PyCharm CE"),
        ("com.jetbrains.rubymine",    "RubyMine"),
        ("com.jetbrains.goland",      "GoLand"),
        ("com.jetbrains.PhpStorm",    "PhpStorm"),
        ("com.jetbrains.CLion",       "CLion"),
        ("com.jetbrains.rider",       "Rider"),
        ("com.jetbrains.rustrover",   "RustRover"),
        ("com.jetbrains.datagrip",    "DataGrip"),
        ("com.jetbrains.dataspell",   "DataSpell"),
        ("com.google.android.studio", "Android Studio"),
    ]

    /// True for any JetBrains IDE, including ones missing from the table.
    static func matches(bundleId: String) -> Bool {
        bundleId.hasPrefix("com.jetbrains.") || ides.contains { $0.bundleId == bundleId }
    }

    /// "WebStorm", "PyCharm"…, or "JetBrains" when the IDE is unknown.
    static func name(for bundleId: String?) -> String {
        ides.first { $0.bundleId == bundleId }?.name ?? "JetBrains"
    }

    /// The project a session runs in: the nearest folder, from cwd up to the home folder,
    /// that holds `.idea`. nil when there is none.
    static func projectRoot(for cwd: String?) -> URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent(".idea").path) { return dir }
            if dir.path == home || dir.path == "/" { return nil }
            dir.deleteLastPathComponent()
        }
    }

    /// The IDE "Open" targets: the session's own, else a running one, else the first installed.
    static func appBundleId(sessionBundleId: String?) -> String? {
        if let id = sessionBundleId, matches(bundleId: id) { return id }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        if let id = running.first(where: { matches(bundleId: $0) }) { return id }
        return ides.map(\.bundleId).first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }

    /// The name the IDE puts in window titles: `.idea/.name` when the project was renamed,
    /// else the folder name.
    static func projectName(_ root: URL) -> String {
        let renamed = try? String(contentsOf: root.appendingPathComponent(".idea/.name"), encoding: .utf8)
        let name = renamed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? root.lastPathComponent : name
    }

    /// Brings the IDE forward on the session's project window, launching it if needed.
    /// The project folder is never handed to the IDE: an already-open project briefly takes
    /// focus and gives it back, so the window is raised through Accessibility instead.
    /// false when no JetBrains IDE is installed.
    @discardableResult
    static func open(sessionBundleId: String?, cwd: String?) -> Bool {
        guard let id = appBundleId(sessionBundleId: sessionBundleId),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
        let project = projectRoot(for: cwd).map(projectName)
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { app, _ in
            guard let project, let pid = app?.processIdentifier else { return }
            DispatchQueue.main.async { raiseWindow(of: project, pid: pid) }
        }
        return true
    }

    /// Window titles read "octopi-ai – README.md", or just the project name.
    private static func raiseWindow(of project: String, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String, title == project || title.hasPrefix(project + " ") else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }
}
