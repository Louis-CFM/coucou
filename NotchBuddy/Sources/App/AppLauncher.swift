import Foundation
import AppKit

// MARK: - AppLauncher

/// Shared “open / un-minimize / bring to front” helper for every integration and agent.
/// Mirrors a Dock click: `openApplication` + AppleScript `reopen` + `activate`,
/// so minimized windows come back — `activate` alone is not enough.
enum AppLauncher {

    /// Preferred terminals, in order (running instance wins).
    static let terminalBundleIds = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty",
    ]

    /// Open (or un-minimize + focus) an app by bundle id.
    @discardableResult
    static func open(bundleId: String, fallbackPath: String? = nil) -> Bool {
        if isRunning(bundleId) {
            frontMost(bundleId: bundleId)
            return true
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let finish: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { app, _ in
            guard app != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                frontMost(bundleId: bundleId)
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: finish)
            return true
        }
        if let fallbackPath,
           FileManager.default.fileExists(atPath: fallbackPath) {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: fallbackPath),
                configuration: config,
                completionHandler: finish
            )
            return true
        }
        return false
    }

    /// Open the first installed app among `bundleIds` (prefer one already running).
    @discardableResult
    static func openFirst(of bundleIds: [String], fallbackPath: String? = nil) -> Bool {
        if let running = bundleIds.first(where: isRunning) {
            return open(bundleId: running)
        }
        if let installed = bundleIds.first(where: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }) {
            return open(bundleId: installed, fallbackPath: fallbackPath)
        }
        if let fallbackPath, !bundleIds.isEmpty {
            return open(bundleId: bundleIds[0], fallbackPath: fallbackPath)
        }
        return false
    }

    @discardableResult
    static func openTerminal() -> Bool {
        openFirst(
            of: terminalBundleIds,
            fallbackPath: "/System/Applications/Utilities/Terminal.app"
        )
    }

    /// Open a https dashboard (or any URL) in the default handler.
    @discardableResult
    static func openURL(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return openURL(url)
    }

    @discardableResult
    static func openURL(_ url: URL) -> Bool {
        let ok = NSWorkspace.shared.open(url)
        // For http(s) dashboards, also nudge a running browser so a minimized
        // window comes back. Skip for system preference / custom schemes.
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return ok }
        if let browser = frontBrowserBundleId() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                frontMost(bundleId: browser)
            }
        }
        return ok
    }

    // MARK: - Internals

    static func isRunning(_ bundleId: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    private static func frontMost(bundleId: String) {
        // Dock-style reopen: openApplication on an already-running app un-minimizes.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
                runReopenActivate(bundleId: bundleId)
            }
        } else {
            runReopenActivate(bundleId: bundleId)
        }
    }

    private static func runReopenActivate(bundleId: String) {
        let escaped = bundleId.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
            tell application id "\(escaped)"
                reopen
                activate
            end tell
            """
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
        }
    }

    private static func frontBrowserBundleId() -> String? {
        let browsers = [
            "company.thebrowser.Browser", // Arc
            "com.google.Chrome",
            "com.brave.Browser",
            "com.apple.Safari",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
        ]
        return browsers.first(where: isRunning)
    }
}
