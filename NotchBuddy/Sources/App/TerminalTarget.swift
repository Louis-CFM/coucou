import Foundation

/// Picks which app "Open terminal" / ⌃⌥T should bring to the front.
/// Foundation only, so it can be tested without AppKit (see scripts/test-terminal-target.sh).
enum TerminalTarget {
    /// Terminals tried, in order, when the session's own app is unknown or not running.
    static let knownTerminals = [
        "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.mitchellh.ghostty", "com.cmuxterm.app", "dev.warp.Warp-Stable",
        "com.github.wez.wezterm", "org.alacritty",
    ]

    /// Bundle IDs to try, in order: the app the session runs in (from the hook's
    /// `bundle_id`, i.e. `__CFBundleIdentifier`), then the known terminals.
    static func candidates(sessionBundleId: String?) -> [String] {
        let own = sessionBundleId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !own.isEmpty else { return knownTerminals }
        return [own] + knownTerminals.filter { $0 != own }
    }

    /// First candidate that is currently running, or nil.
    static func pick(sessionBundleId: String?, running: Set<String>) -> String? {
        candidates(sessionBundleId: sessionBundleId).first { running.contains($0) }
    }

    /// AppleScript that raises the tab on `tty` (checked by ClaudeHost.isTTY), true when found.
    /// nil for terminals whose tabs don't expose a tty.
    static func tabScript(bundleId: String, tty: String) -> String? {
        switch bundleId {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected tab of w to t
                            set index of w to 1
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    /// The ttys whose tab holds the session: in tmux the session's tty is a pane's, so that pane is
    /// selected and the tabs are those of the clients attached to its session.
    static func tabTTYs(for tty: String) -> [String] {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let found = tmuxPane(tty: tty, listing: run(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id} #{session_id}"]))
        else { return [tty] }
        _ = run(tmux, ["select-window", "-t", found.pane])
        _ = run(tmux, ["select-pane", "-t", found.pane])
        // ponytail: only clients already on the pane's session; switch-client if needed later
        return run(tmux, ["list-clients", "-t", found.session, "-F", "#{client_tty}"])
            .split(separator: "\n").map(String.init)
    }

    /// The tmux pane on `tty` and its session id, from
    /// `tmux list-panes -a -F '#{pane_tty} #{pane_id} #{session_id}'`.
    static func tmuxPane(tty: String, listing: String) -> (pane: String, session: String)? {
        for line in listing.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 3, f[0] == tty { return (String(f[1]), String(f[2])) }
        }
        return nil
    }

    static let weztermId = "com.github.wez.wezterm"

    /// Every WezTerm pane's title by its tty, from `wezterm cli list --format json`.
    static func weztermTitles(listing: String) -> [String: String] {
        guard let panes = try? JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [[String: Any]] else { return [:] }
        var titles: [String: String] = [:]
        for pane in panes {
            if let tty = pane["tty_name"] as? String, let title = pane["title"] as? String { titles[tty] = title }
        }
        return titles
    }

    static func weztermTitles(cli: String) -> [String: String] {
        guard FileManager.default.isExecutableFile(atPath: cli) else { return [:] }
        return weztermTitles(listing: run(cli, ["cli", "list", "--format", "json"]))
    }

    /// The WezTerm pane on `tty` and its title, from `wezterm cli list --format json`.
    static func weztermPane(tty: String, listing: String) -> (id: Int, title: String)? {
        guard let panes = try? JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [[String: Any]],
              let pane = panes.first(where: { $0["tty_name"] as? String == tty }),
              let id = pane["pane_id"] as? Int else { return nil }
        return (id, pane["title"] as? String ?? "")
    }

    /// Makes the pane on `tty` the active one in its WezTerm window; returns that window's title.
    /// The CLI does not raise the window itself.
    static func activateWezTermPane(tty: String, cli: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: cli),
              let pane = weztermPane(tty: tty, listing: run(cli, ["cli", "list", "--format", "json"])) else { return nil }
        _ = run(cli, ["cli", "activate-pane", "--pane-id", String(pane.id)])
        return pane.title
    }

    private static func run(_ exe: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
