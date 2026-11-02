import Foundation

/// Removes entries containing "nb-hook" from a Gemini- or Claude-format groups array
/// (matcher + hooks[]), handling the legacy flat format too (command at top level).
/// Used by both paths' install/uninstall so only Coucou's own entries are removed;
/// whole groups are dropped only when every entry in them was ours.
///
/// Kept free of file access so it can be tested on fixtures (scripts/test-claude-hook-removal.sh).
func removeNbHookEntries(from groups: [[String: Any]]) -> [[String: Any]] {
    groups.compactMap { group -> [String: Any]? in
        // Legacy flat entry — command at group level
        if let cmd = group["command"] as? String, cmd.contains("nb-hook") { return nil }
        // Group format — filter inner hooks
        if var innerHooks = group["hooks"] as? [[String: Any]] {
            innerHooks.removeAll { ($0["command"] as? String)?.contains("nb-hook") == true }
            if innerHooks.isEmpty { return nil }
            var updated = group
            updated["hooks"] = innerHooks
            return updated
        }
        return group
    }
}
