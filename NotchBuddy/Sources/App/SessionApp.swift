import AppKit

/// Where a Claude Code session runs: the app from the hook's `__CFBundleIdentifier`
/// (Terminal, iTerm, GoLand, PhpStorm, Zed…), else the first running terminal.
enum SessionApp {
    static let terminalBundleIds = ["com.apple.Terminal", "com.googlecode.iterm2",
                                    "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]

    /// "GoLand", "Zed", "Terminal"… nil when the bundle ID is unknown or not installed.
    static func name(bundleId: String?) -> String? {
        guard let bundleId, !bundleId.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    @MainActor
    static func activate(bundleId: String?) {
        let ids = [bundleId].compactMap { $0 }.filter { !$0.isEmpty } + terminalBundleIds
        let running = ids.lazy.compactMap { id in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
        }.first
        if let running {
            running.activate(options: .activateIgnoringOtherApps)
        } else if let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}
