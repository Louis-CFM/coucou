import AppKit

/// Where a Claude Code session runs: the app from the hook's `__CFBundleIdentifier`
/// (Terminal, iTerm, GoLand, PhpStorm, Zed…), else the first running terminal.
enum SessionApp {
    static let terminalBundleIds = ["com.apple.Terminal", "com.googlecode.iterm2",
                                    "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
    private static let lastKey = "lastClaudeCodeAppBundleId"

    /// Saves `bundleId` as the app Claude Code last ran in and returns it. Returns nil for
    /// an empty ID, or Coucou's own (it runs `claude` itself for iPhone instructions).
    static func remember(_ bundleId: String) -> String? {
        guard !bundleId.isEmpty, bundleId != Bundle.main.bundleIdentifier else { return nil }
        UserDefaults.standard.set(bundleId, forKey: lastKey)
        return bundleId
    }

    /// The session's app, or the one Claude Code last ran in (survives a Coucou restart).
    static func resolve(_ bundleId: String?) -> String? {
        if let bundleId, !bundleId.isEmpty { return bundleId }
        return UserDefaults.standard.string(forKey: lastKey)
    }

    /// "GoLand", "Zed", "Terminal"… nil when the app is unknown or not installed.
    static func name(bundleId: String?) -> String? {
        guard let id = resolve(bundleId),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    @MainActor
    static func activate(bundleId: String?) {
        if let id = resolve(bundleId) {
            if let app = running(id) {
                app.activate(options: .activateIgnoringOtherApps)
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
                return
            }
        }
        if let terminal = terminalBundleIds.lazy.compactMap(running).first {
            terminal.activate(options: .activateIgnoringOtherApps)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }

    private static func running(_ id: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
    }
}
