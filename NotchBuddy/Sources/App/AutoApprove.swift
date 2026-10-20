import Foundation

// MARK: - AutoApprove
// Rules the user made with "Always here" on an approval card. Only for the agents that have no
// "Always" of their own (Codex, Copilot CLI, Muse Code). Off until turned on in Settings → Agents.
// The click that creates a rule is the explicit consent; a rule never grows past what was clicked.

struct AutoApproveRule: Codable, Equatable, Hashable, Sendable {
    let pillId: String
    let cwd: String
    let tool: String
    /// The command's first words, as shown on the card when the rule was made.
    let prefix: String
}

enum AutoApprove {
    static let enabledKey = "autoApproveEnabled"
    static let rulesKey = "autoApproveRules"
    static let agents: Set<String> = ["agent_codex", "agent_copilot", "agent_muse"]

    /// Commands whose first word can do too much to ever be allowed without a look.
    static let blockedFirstWords: Set<String> = [
        "rm", "rmdir", "del", "sudo", "su", "doas", "dd", "mkfs", "chmod", "chown", "mv", "kill", "pkill",
        "killall", "shutdown", "reboot", "curl", "wget", "ssh", "scp", "rsync", "bash", "sh", "zsh", "fish",
        "pwsh", "powershell", "cmd", "eval", "exec", "xargs", "env", "find", "remove-item",
    ]
    static let blockedPrefixes = ["git push", "git reset", "git clean", "git checkout", "git rebase"]

    /// The command with its whitespace collapsed, or nil when it chains, pipes, redirects or
    /// substitutes: a prefix rule could not tell what such a command really runs.
    static func normalized(_ command: String) -> String? {
        if command.contains(where: { ";&|`$<>\n\r".contains($0) }) { return nil }
        let words = command.split(whereSeparator: \.isWhitespace)
        guard let first = words.first, !blockedFirstWords.contains(first.lowercased()) else { return nil }
        let joined = words.joined(separator: " ")
        if blockedPrefixes.contains(where: { joined.lowercased() == $0 || joined.lowercased().hasPrefix($0 + " ") }) {
            return nil
        }
        return joined
    }

    // ponytail: the prefix is the first two words ("npm test", "cargo build"). Add a prefix
    // editor in Settings if two words turn out too wide or too narrow.
    static func prefix(of command: String) -> String? {
        guard let cmd = normalized(command) else { return nil }
        return cmd.split(separator: " ").prefix(2).joined(separator: " ")
    }

    /// `command` is tool_input.command, nil for a tool that runs none (a file write, a fetch…):
    /// those never get a rule, whatever their tool name looks like.
    static func rule(pillId: String, cwd: String, tool: String, command: String?) -> AutoApproveRule? {
        guard agents.contains(pillId), !cwd.isEmpty, let command, let prefix = prefix(of: command) else { return nil }
        return AutoApproveRule(pillId: pillId, cwd: cwd, tool: tool, prefix: prefix)
    }

    static func matches(_ rules: [AutoApproveRule], pillId: String, cwd: String, tool: String, command: String?) -> Bool {
        guard agents.contains(pillId), let command, let cmd = normalized(command) else { return false }
        return rules.contains {
            $0.pillId == pillId && $0.cwd == cwd && $0.tool == tool
                && (cmd == $0.prefix || cmd.hasPrefix($0.prefix + " "))
        }
    }

    // MARK: Storage (UserDefaults: nothing here is a secret)

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var rules: [AutoApproveRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: rulesKey) else { return [] }
            return (try? JSONDecoder().decode([AutoApproveRule].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: rulesKey) }
    }

    static func add(_ rule: AutoApproveRule) {
        var all = rules
        if !all.contains(rule) { all.append(rule) }
        rules = all
    }

    static func remove(_ rule: AutoApproveRule) {
        rules = rules.filter { $0 != rule }
    }
}
