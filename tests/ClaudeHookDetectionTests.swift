import Foundation

@main
enum ClaudeHookDetectionTests {
    static func settings(_ json: String) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
        return (object as? [String: Any]) ?? [:]
    }

    static func main() {
        // Installed: the hook Coucou writes, GitHub build
        precondition(coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"$HOME/.claude/coucou/nb-hook"}]}]}}
        """)))

        // Installed: App Store build names NotchBuddy
        precondition(coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"/Applications/NotchBuddy.app/.../nb-hook"}]}]}}
        """)))

        // Installed: our hook sits alongside somebody else's
        precondition(coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[
          {"hooks":[{"type":"command","command":"/usr/local/bin/other-tool"}]},
          {"hooks":[{"type":"command","command":"$HOME/.claude/coucou/nb-hook"}]}]}}
        """)))

        // Not installed: other tools only — the case that showed "Key not configured"
        precondition(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[
          {"type":"command","command":"$HOME/.vibe-island/bin/vibe-island-bridge"},
          {"type":"command","command":"python3 /Users/me/.claude/skills/harness/hook.py"}]}]}}
        """)))

        // Not installed: hooks for other events do not count
        precondition(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"PreToolUse":[{"hooks":[
          {"type":"command","command":"$HOME/.claude/coucou/nb-hook"}]}]}}
        """)))

        // Malformed or empty settings never crash, and never read as installed
        precondition(!coucouHooksPresent(inSettings: settings("{}")))
        precondition(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[]}}
        """)))
        precondition(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[{"hooks":[{"type":"command"}]}]}}
        """)))
        precondition(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":"not-an-array"}}
        """)))
        precondition(!coucouHooksPresent(inSettings: settings("""
        {"hooks":"not-an-object"}
        """)))

        // Another machine's relays are never this Mac's: the Linux app, remote clients, old untagged ones
        precondition(!coucouHooksPresent(inSettings: settings("""
        {"hooks":{"SessionStart":[
          {"hooks":[{"type":"command","command":"'/home/me/.local/share/coucou/bin/coucou-hook' SessionStart"}]},
          {"hooks":[{"type":"command","command":"COUCOU_SOCKET='/Users/me/.coucou/aaaaaaaa.sock' '/Users/me/.local/share/coucou/bin/coucou-hook.py' SessionStart"}]},
          {"hooks":[{"type":"command","command":"\\"/home/me/.local/share/coucou/bin/nb-hook\\""}]}]}}
        """)))
        precondition(isLocalCoucouHook(#""/Users/me/Library/Application Support/NotchBuddy/nb-hook" --ask"#))

        ownership()
        print("Claude hook detection: 13 cases passed")
    }

    /// Several machines share one settings.json: each installer replaces or removes only its own entries.
    static func ownership() {
        let user = #"/usr/local/bin/other-tool"#
        let linux = #"'/home/me/.local/share/coucou/bin/coucou-hook' Stop"#
        let a = #"COUCOU_SOCKET='/home/me/.coucou/aaaaaaaa.sock' '/home/me/.local/share/coucou/bin/nb-hook'"#
        let b = #"COUCOU_SOCKET='/home/me/.coucou/bbbbbbbb.sock' '/home/me/.local/share/coucou/bin/coucou-hook.py' Stop"#
        let legacy = #""/home/me/.local/share/coucou/bin/nb-hook""#
        let mac = #""/Users/me/Library/Application Support/NotchBuddy/nb-hook""#
        let groups: [[String: Any]] = [user, linux, a, b, legacy, mac].map { cmd in
            let hook: [String: Any] = ["type": "command", "command": cmd]
            return ["hooks": [hook]]
        }
        func commands(_ g: [[String: Any]]) -> [String] {
            g.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        }
        // A new client c installs: its own and the old untagged nb-hook go, everybody else stays.
        let installC = removingHooks(from: groups) { isRemoteCoucouHook($0, clientId: "cccccccc") || isLegacyRemoteHook($0) }
        precondition(commands(installC) == [user, linux, a, b, mac])
        // Client a uninstalls: only its entry goes.
        precondition(commands(removingHooks(from: groups) { isRemoteCoucouHook($0, clientId: "aaaaaaaa") }) == [user, linux, b, legacy, mac])
        // This Mac's own installer touches only its own relay, never the hosts' clients or the Linux app.
        precondition(commands(removingHooks(from: groups, where: isLocalCoucouHook)) == [user, linux, a, b, legacy])
        // A group holding a user hook next to ours keeps the user hook.
        let pair: [[String: Any]] = [["type": "command", "command": user], ["type": "command", "command": mac]]
        let mixed: [[String: Any]] = [["matcher": "Bash", "hooks": pair]]
        let kept = removingHooks(from: mixed, where: isLocalCoucouHook)
        precondition(commands(kept) == [user] && (kept.first?["matcher"] as? String) == "Bash")
    }
}
