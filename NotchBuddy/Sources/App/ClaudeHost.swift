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

    /// Brings the session's terminal forward (launching it if needed). false when not a terminal host.
    @discardableResult
    static func activate(_ hostBundleId: String?, tty: String? = nil) -> Bool {
        guard let id = hostBundleId, terminals[id] != nil else { return false }
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
        if let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            bringForward(url, bundleId: id, tty: tty)
        }
        return true
    }

    /// True for a tty path the relay can send ("/dev/ttys004"), so it is safe inside AppleScript.
    static func isTTY(_ tty: String?) -> Bool {
        tty?.range(of: #"^/dev/ttys?[0-9]+$"#, options: .regularExpression) != nil
    }

    private static let tabQueue = DispatchQueue(label: "fr.louisraille.coucou.terminal-tab")

    /// Opens the app at `url` through Launch Services: NSRunningApplication.activate() is ignored
    /// on macOS 14+ unless the caller is the active app, which Coucou never is. For Apple Terminal
    /// with the session's tty, that tab is selected and its window raised first, so the session's
    /// own window comes back rather than the last one used.
    static func bringForward(_ url: URL, bundleId: String, tty: String?) {
        let open: @Sendable () -> Void = {
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        }
        #if !APPSTORE
        if bundleId == "com.apple.Terminal", let tty, isTTY(tty) {
            tabQueue.async {
                var error: NSDictionary?
                NSAppleScript(source: """
                    tell application id "com.apple.Terminal"
                        repeat with w in windows
                            repeat with t in tabs of w
                                if tty of t is "\(tty)" then
                                    set selected tab of w to t
                                    set index of w to 1
                                    return
                                end if
                            end repeat
                        end repeat
                    end tell
                    """)?.executeAndReturnError(&error)
                open()
            }
            return
        }
        #endif
        open()
    }
}
