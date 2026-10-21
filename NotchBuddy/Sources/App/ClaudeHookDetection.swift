import Foundation

/// True when a parsed ~/.claude/settings.json routes Claude Code SessionStart events to Orca Notch.
///
/// Kept free of file access so it can be tested on fixtures instead of the real settings file.
/// Matched on the command text: a hook written by Orca Notch runs
/// ~/Library/Application Support/OrcaNotch/nb-hook.
func orcaNotchHooksPresent(inSettings settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any],
          let sessionStart = hooks["SessionStart"] as? [[String: Any]] else { return false }
    return sessionStart.contains { group in
        (group["hooks"] as? [[String: Any]])?.contains { hook in
            guard let command = hook["command"] as? String else { return false }
            return command.contains("OrcaNotch")
        } ?? false
    }
}
