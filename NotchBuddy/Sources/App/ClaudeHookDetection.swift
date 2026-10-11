import Foundation

/// True when a parsed ~/.claude/settings.json routes Claude Code SessionStart events to Coucou.
///
/// Kept free of file access so it can be tested on fixtures instead of the real settings file.
/// Both the installed app and earlier builds matched on the command text: a hook written by
/// Coucou runs ~/.claude/coucou/nb-hook, and the App Store build names NotchBuddy instead.
func coucouHooksPresent(inSettings settings: [String: Any]) -> Bool {
    guard let hooks = settings["hooks"] as? [String: Any],
          let sessionStart = hooks["SessionStart"] as? [[String: Any]] else { return false }
    return sessionStart.contains { group in
        (group["hooks"] as? [[String: Any]])?.contains { hook in
            isLocalCoucouHook(hook["command"] as? String ?? "")
        } ?? false
    }
}

/// This Mac's own relay. Never another machine's: a remote client's tagged relay, or the Linux app's coucou-hook.
func isLocalCoucouHook(_ command: String) -> Bool {
    !command.contains("COUCOU_SOCKET=") && command.contains("nb-hook")
        && (command.contains("NotchBuddy") || command.contains("/.claude/coucou/nb-hook"))
}

/// A remote client's relay on a host, tagged with that client's socket there.
func isRemoteCoucouHook(_ command: String, clientId: String) -> Bool {
    command.contains("COUCOU_SOCKET=") && command.contains("/.coucou/\(clientId).sock")
}

/// A Mac client's relay from before clients had ids: untagged nb-hook in the remote relay folder.
func isLegacyRemoteHook(_ command: String) -> Bool {
    !command.contains("COUCOU_SOCKET=") && command.contains("/.local/share/coucou/bin/nb-hook")
}

/// `groups` without the hooks `owns` claims. A group left empty goes; every other group stays as it was.
func removingHooks(from groups: [[String: Any]], where owns: (String) -> Bool) -> [[String: Any]] {
    groups.compactMap { group in
        guard let list = group["hooks"] as? [[String: Any]] else { return group }
        let kept = list.filter { !owns($0["command"] as? String ?? "") }
        if kept.count == list.count { return group }
        if kept.isEmpty { return nil }
        var trimmed = group
        trimmed["hooks"] = kept
        return trimmed
    }
}
