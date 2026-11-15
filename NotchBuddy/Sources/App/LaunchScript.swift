import Foundation

/// A new Claude Code session from the notch (GitHub build): the script the terminal runs, the
/// way each terminal is asked to run it, and the projects to offer. Foundation only, so it can be
/// tested without AppKit (scripts/test-session-launch.sh).
enum LaunchScript {
    /// The shell's single quotes: 'it'\''s' for it's.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A .command file: it removes itself, goes to the project, and starts Claude Code with the
    /// prompt in the user's own login shell (so `claude` is found as in any terminal). The prompt
    /// travels in an environment variable, never pasted into the command line. When Claude Code
    /// quits, the shell stays open in the project.
    static func script(prompt: String, folder: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = trimmed.isEmpty ? "claude" : "claude \"$COUCOU_PROMPT\""
        return """
        #!/bin/sh
        rm -f "$0"
        cd \(quote(folder)) || exit 1
        export COUCOU_PROMPT=\(quote(trimmed))
        exec "${SHELL:-/bin/zsh}" -lic \(quote(run + "; exec $SHELL -l"))

        """
    }

    /// How a terminal runs the script: `.open` hands it the .command file (Terminal, iTerm2),
    /// `.args` starts a new instance with these arguments, the script's path in place of `%s`.
    enum Way: Equatable { case open, args([String]) }

    static func way(for bundleId: String) -> Way? {
        switch bundleId {
        case "com.apple.Terminal", "com.googlecode.iterm2": return .open
        case "com.mitchellh.ghostty": return .args(["-e", "%s"])
        case "org.alacritty": return .args(["-e", "%s"])
        case "net.kovidgoyal.kitty": return .args(["%s"])
        case "com.github.wez.wezterm": return .args(["start", "--", "%s"])
        default: return nil   // Warp, cmux…: they can't be handed a command; Terminal does it
        }
    }

    /// The terminal: the one the last session ran in, else the first running one that can run
    /// the script, else Terminal.
    static func terminal(lastSession: String?, running: Set<String>) -> String {
        if let own = lastSession, way(for: own) != nil { return own }
        return TerminalTarget.knownTerminals.first { running.contains($0) && way(for: $0) != nil } ?? "com.apple.Terminal"
    }

    /// What a file dropped on a session types into its prompt: the paths as a terminal writes
    /// them when you drag files onto it (a backslash before spaces and shell characters), then a
    /// space. Claude Code takes them as files, an image path as the image.
    static func dropText(_ paths: [String]) -> String {
        let special = Set(" ()'\"\\&;|<>*?[]{}$`!#~")
        let escaped = paths.map { path in
            path.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
        }
        return escaped.joined(separator: " ") + " "
    }

    /// Projects, most recent first: the folders sessions ran in, without the home folder or /.
    static func remember(_ folder: String, in list: [String], home: String, max: Int = 10) -> [String] {
        var path = folder
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, path != "/", path != home else { return list }
        return Array(([path] + list.filter { $0 != path }).prefix(max))
    }
}
