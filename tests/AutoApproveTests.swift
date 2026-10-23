import Foundation

@main
enum AutoApproveTests {
    static func main() {
        let codex = "agent_codex", dir = "/Users/me/app"

        // A rule takes the first two words of a plain command
        let r = AutoApprove.rule(pillId: codex, cwd: dir, tool: "Bash", command: "npm  test --watch")
        precondition(r == AutoApproveRule(pillId: codex, cwd: dir, tool: "Bash", prefix: "npm test"))

        // Never for Claude Code (it has its own Always), a tool with no command, or an empty cwd
        precondition(AutoApprove.rule(pillId: "integration_claude", cwd: dir, tool: "Bash", command: "npm test") == nil)
        precondition(AutoApprove.rule(pillId: codex, cwd: dir, tool: "Write", command: nil) == nil)
        precondition(AutoApprove.rule(pillId: codex, cwd: "", tool: "Bash", command: "npm test") == nil)

        // Dangerous or opaque commands never get a rule
        for cmd in ["rm -rf build", "sudo npm test", "git push origin main", "git reset --hard",
                    "npm test && rm -rf /", "npm test; ls", "npm test | tee x", "echo $(id)",
                    "npm test > out", "bash -c 'npm test'", "RM -rf x", "xargs rm", ""] {
            precondition(AutoApprove.rule(pillId: codex, cwd: dir, tool: "Bash", command: cmd) == nil, cmd)
        }

        // Matching: same agent, folder and tool, and the command starts with the whole prefix
        let rules = [r!]
        precondition(AutoApprove.matches(rules, pillId: codex, cwd: dir, tool: "Bash", command: "npm test"))
        precondition(AutoApprove.matches(rules, pillId: codex, cwd: dir, tool: "Bash", command: "npm test -- api"))
        precondition(!AutoApprove.matches(rules, pillId: codex, cwd: dir, tool: "Bash", command: "npm testx"))
        precondition(!AutoApprove.matches(rules, pillId: codex, cwd: dir, tool: "Bash", command: "npm test && rm -rf ~"))
        precondition(!AutoApprove.matches(rules, pillId: codex, cwd: dir + "/sub", tool: "Bash", command: "npm test"))
        precondition(!AutoApprove.matches(rules, pillId: "agent_muse", cwd: dir, tool: "Bash", command: "npm test"))
        precondition(!AutoApprove.matches(rules, pillId: codex, cwd: dir, tool: "Edit", command: "npm test"))
        precondition(!AutoApprove.matches(rules, pillId: codex, cwd: dir, tool: "Bash", command: nil))
        precondition(!AutoApprove.matches([], pillId: codex, cwd: dir, tool: "Bash", command: "npm test"))

        print("pass")
    }
}
