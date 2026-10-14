import AppKit

// MARK: - ClaudeHost
//
// The app a Claude Code session runs in, from the hook payload's term_program /
// bundle_id. VS Code sessions keep the original "VS Code" pill; sessions from a
// terminal also route to integration_claude and the pill says "Claude Code".

struct ClaudeHost: Equatable {
    let bundleId: String
    let name: String

    /// UserDefaults key: show terminal sessions' questions and permission requests in the
    /// notch (they then wait for the notch). Off by default: the terminal asks itself.
    static let terminalCardsKey = "terminalCardsEnabled"
    static var terminalCardsEnabled: Bool { UserDefaults.standard.bool(forKey: terminalCardsKey) }

    /// Terminals accepted for Claude Code sessions. Keyed by bundle id; the second
    /// table maps TERM_PROGRAM for hooks that run without __CFBundleIdentifier.
    private static let terminals: [String: String] = [
        "dev.warp.Warp-Stable":       "Warp",
        "dev.warp.Warp-Preview":      "Warp",
        "com.apple.Terminal":         "Terminal",
        "com.googlecode.iterm2":      "iTerm",
        "com.mitchellh.ghostty":      "Ghostty",
        "net.kovidgoyal.kitty":       "kitty",
        "org.alacritty":              "Alacritty",
        "com.github.wez.wezterm":     "WezTerm",
        "co.zeit.hyper":              "Hyper",
        "dev.zed.Zed":                "Zed",
        "com.cmuxterm.app":           "cmux",    // sets TERM_PROGRAM=ghostty: the bundle id decides
        "com.stablyai.orca":          "Orca",
        "com.conductor.app":          "Conductor",
    ]
    private static let termPrograms: [String: String] = [
        "warpterminal":   "dev.warp.Warp-Stable",
        "apple_terminal": "com.apple.Terminal",
        "iterm.app":      "com.googlecode.iterm2",
        "ghostty":        "com.mitchellh.ghostty",
        "kitty":          "net.kovidgoyal.kitty",
        "alacritty":      "org.alacritty",
        "wezterm":        "com.github.wez.wezterm",
        "hyper":          "co.zeit.hyper",
        "zed":            "dev.zed.Zed",
    ]

    /// The terminal a session runs in, or nil when it isn't a known terminal.
    static func terminal(termProgram: String, bundleId: String) -> ClaudeHost? {
        if let name = terminals[bundleId] { return ClaudeHost(bundleId: bundleId, name: name) }
        if let id = termPrograms[termProgram.lowercased()], let name = terminals[id] {
            return ClaudeHost(bundleId: id, name: name)
        }
        return nil
    }

    /// The app name for a task's host; nil host means VS Code (the original routing).
    static func name(for hostBundleId: String?) -> String {
        guard let id = hostBundleId, let name = terminals[id] else { return "VS Code" }
        return name
    }

    /// Pill label for integration_claude: "VS Code" for editor sessions, "Claude Code" otherwise.
    static func pillName(hostApp: String?) -> String {
        hostApp == nil ? "VS Code" : "Claude Code"
    }

    /// Pills that keep the app and link of the session they show (Claude Code and Codex
    /// both run in terminals and Conductor), so "Open terminal" goes back to that session.
    static func recordsHost(pillId: String?) -> Bool {
        pillId == "integration_claude" || pillId == "agent_codex"
    }

    /// Whether a session runs in Conductor, which runs workspaces side by side: each of its
    /// sessions gets its own finished card and takes the pill when it gets a prompt.
    static func isConductor(_ hostBundleId: String?) -> Bool {
        hostBundleId == "com.conductor.app"
    }

    /// Conductor's link to the workspace and chat a session runs in
    /// (`conductor://workspace?id=…&session=…`), from the ids the relay reads in
    /// CONDUCTOR_WORKSPACE_ID / CONDUCTOR_SESSION_ID. nil for any other host.
    static func sessionURL(from payload: [String: Any]) -> URL? {
        guard payload["bundle_id"] as? String == "com.conductor.app",
              let workspace = conductorId(payload["conductor_workspace_id"]) else { return nil }
        var link = URLComponents()
        link.scheme = "conductor"
        link.host = "workspace"
        link.queryItems = [URLQueryItem(name: "id", value: workspace)]
        if let session = conductorId(payload["conductor_session_id"]) {
            link.queryItems?.append(URLQueryItem(name: "session", value: session))
        }
        return link.url
    }

    /// Brings the host forward the way ⌘-Tab does, so macOS also switches to the desktop its
    /// window is on: activate() alone leaves that window on another desktop. Needs Accessibility,
    /// like the prompt context (GitHub build only); without it, activate() is all there is.
    private static func switchToDesktop(of app: NSRunningApplication) {
        #if !APPSTORE
        guard AXIsProcessTrusted() else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        #endif
    }

    /// A Conductor id (a UUID: letters, digits and hyphens), or nil.
    private static func conductorId(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return id
    }

    /// Brings the session's terminal forward (launching it if needed). false when not a terminal host.
    /// With a `sessionURL` (Conductor), opens that link instead, so the host shows the session itself.
    @discardableResult
    static func activate(_ hostBundleId: String?, sessionURL: URL? = nil) -> Bool {
        guard let id = hostBundleId, terminals[id] != nil else { return false }
        // The link switches the chat, but opened from Coucou (never the active app) it leaves
        // the host behind other windows or on another desktop: bring it forward once it has it.
        if let sessionURL, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            // `activates` already brings the host forward; the completion runs on a background
            // queue, so the desktop switch (Accessibility) goes back to the main thread.
            NSWorkspace.shared.open([sessionURL], withApplicationAt: app, configuration: configuration) { running, _ in
                DispatchQueue.main.async {
                    // The link failed to open (app moved, launch refused): bring the host forward without it.
                    guard let running else { activate(id); return }
                    switchToDesktop(of: running)
                }
            }
            return true
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id }) {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
        return true
    }
}
