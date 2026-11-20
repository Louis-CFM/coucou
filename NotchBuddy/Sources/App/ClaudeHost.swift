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

    /// Terminals (and agent apps like Conductor) accepted for Claude Code sessions.
    /// Keyed by bundle id; the second
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
        "com.conductor.app":          "Conductor", // runs Claude Code with no TERM_PROGRAM
        "com.t3tools.t3code": "T3 Code",
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

    private static let editorBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium.codium",
        "com.todesktop.230313mzl4w4u92",
    ]

    /// Validates a TTY device path before interpolating into AppleScript.
    static func validatedTty(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.hasPrefix("/dev/tty"),
              trimmed.count <= 64 else { return nil }
        for scalar in trimmed.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x30 && v <= 0x39)
                  || (v >= 0x41 && v <= 0x5A)
                  || (v >= 0x61 && v <= 0x7A)
                  || v == 0x2F || v == 0x2D || v == 0x5F
            guard ok else { return nil }
        }
        return trimmed
    }

    /// Extracts the AppleScript `unique id` portion of `ITERM_SESSION_ID` (e.g. `w0t0p0:UUID` -> `UUID`).
    static func normalizedItermUniqueId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 128 else { return nil }
        let uid = trimmed.split(separator: ":", maxSplits: 1).last.map(String.init) ?? trimmed
        guard !uid.isEmpty else { return nil }
        for scalar in uid.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x30 && v <= 0x39)
                  || (v >= 0x41 && v <= 0x5A)
                  || (v >= 0x61 && v <= 0x7A)
                  || v == 0x2D || v == 0x5F
            guard ok else { return nil }
        }
        return uid
    }

    static func focusTerminalScript(tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    static func focusItermScript(uniqueId: String?, tty: String?) -> String {
        var clauses: [String] = []
        if let uniqueId { clauses.append("unique id of s is \"\(uniqueId)\"") }
        if let tty { clauses.append("tty of s is \"\(tty)\"") }
        let condition = clauses.joined(separator: " or ")
        return """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (\(condition)) then
                            select t
                            select s
                            select w
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }

    /// Brings a specific terminal tab/session or IDE workspace folder forward, falling back to app activation.
    static func focusBundle(
        _ bundleId: String,
        tty: String? = nil,
        cwd: String? = nil,
        itermSessionId: String? = nil
    ) {
        let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId })
        let appURL = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)

        #if !APPSTORE
        if running != nil {
            if bundleId == "com.apple.Terminal", let validTty = validatedTty(tty) {
                var err: NSDictionary?
                let result = NSAppleScript(source: focusTerminalScript(tty: validTty))?.executeAndReturnError(&err)
                if err == nil, result?.booleanValue == true { return }
            } else if bundleId == "com.googlecode.iterm2" {
                let uid = normalizedItermUniqueId(itermSessionId)
                let validTty = validatedTty(tty)
                if uid != nil || validTty != nil {
                    var err: NSDictionary?
                    let result = NSAppleScript(source: focusItermScript(uniqueId: uid, tty: validTty))?.executeAndReturnError(&err)
                    if err == nil, result?.booleanValue == true { return }
                }
            }
        }
        #endif

        if editorBundleIds.contains(bundleId),
           let folder = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !folder.isEmpty,
           FileManager.default.fileExists(atPath: folder),
           let appURL {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL, configuration: .init(), completionHandler: nil)
            return
        }

        // Open through Launch Services even when it runs: since macOS 14,
        // NSRunningApplication.activate() is ignored when called from an app that is not
        // active, and the island never is.
        if let appURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init(), completionHandler: nil)
        }
    }

    /// Brings the session's terminal forward (launching it if needed). false when not a terminal host.
    @discardableResult
    static func activate(
        _ hostBundleId: String?,
        tty: String? = nil,
        cwd: String? = nil,
        itermSessionId: String? = nil
    ) -> Bool {
        guard let id = hostBundleId, terminals[id] != nil else { return false }
        focusBundle(id, tty: tty, cwd: cwd, itermSessionId: itermSessionId)
        return true
    }
}
