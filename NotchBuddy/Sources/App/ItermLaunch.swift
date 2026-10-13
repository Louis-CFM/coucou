import Foundation

/// Opens a new iTerm2 tab running Claude Code on what was typed in the chat.
/// Foundation only, so it can be tested without AppKit (see scripts/test-iterm-launch.sh).
enum ItermLaunch {
    static let bundleId = "com.googlecode.iterm2"

    /// `text` as one single-quoted shell word.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The line typed in the new tab. It goes through the user's shell, so PATH and
    /// aliases (e.g. `claude --dangerously-skip-permissions`) apply; `--` keeps a prompt
    /// starting with "-" from being read as a flag. Newlines would submit early: flattened.
    static func command(prompt: String, directory: String) -> String {
        let flat = prompt.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return "cd \(shellQuoted(directory)) && claude -- \(shellQuoted(flat))"
    }

    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `freshLaunch`: iTerm2 wasn't running, so launching it opens a window whose
    /// session is used as is, instead of leaving an empty tab next to ours.
    static func script(prompt: String, directory: String, freshLaunch: Bool) -> String {
        let line = appleScriptString(command(prompt: prompt, directory: directory))
        return """
        tell application id "\(bundleId)"
            activate
            set w to current window
            if w is missing value then
                set w to (create window with default profile)
            else if not \(freshLaunch) then
                tell w to create tab with default profile
            end if
            tell current session of w to write text \(line)
        end tell
        """
    }

    /// Runs the script off the main thread (a cold launch of iTerm2 takes seconds).
    /// Returns the AppleScript error message, or nil on success.
    static func run(prompt: String, directory: String, freshLaunch: Bool) async -> String? {
        let source = script(prompt: prompt, directory: directory, freshLaunch: freshLaunch)
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var err: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&err)
                cont.resume(returning: err.map { $0[NSAppleScript.errorMessage] as? String ?? "unknown" })
            }
        }
    }
}
