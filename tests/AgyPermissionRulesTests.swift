import Foundation

@main
enum AgyPermissionRulesTests {
    static func words(_ line: String) -> [[String]]? { AgyPermissionRules.parse(line)?.segments }

    static func write(_ json: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: url)
    }

    static func main() {
        // Shell words: quotes and backslashes as a shell reads them, parts split on operators
        precondition(words("npm test") == [["npm", "test"]])
        precondition(words("  git   log  ") == [["git", "log"]])
        precondition(words("git fetch && git rebase") == [["git", "fetch"], ["git", "rebase"]])
        precondition(words("a || b; c | d & e\nf") == [["a"], ["b"], ["c"], ["d"], ["e"], ["f"]])
        precondition(words("git log --grep=\"a|b\"") == [["git", "log", "--grep=a|b"]])
        precondition(words("echo 'x && y'") == [["echo", "x && y"]])
        precondition(words("echo \"say \\\"hi\\\"\"") == [["echo", "say \"hi\""]])
        precondition(words("echo a\\ b") == [["echo", "a b"]])
        precondition(words("npm test 2>&1") == [["npm", "test", "2>&1"]])
        precondition(words("npm test &> log.txt") == [["npm", "test", "&>", "log.txt"]])
        precondition(words("echo \"\"") == [["echo", ""]])
        precondition(words("echo 'open") == nil)               // open quote: unreadable
        precondition(AgyPermissionRules.parse("echo $(whoami)")?.hasSubstitution == true)
        precondition(AgyPermissionRules.parse("echo \"`whoami`\"")?.hasSubstitution == true)
        precondition(AgyPermissionRules.parse("echo '$(whoami)'")?.hasSubstitution == false)

        // Only command(...) entries count
        precondition(AgyPermissionRules.commandRules(["command(git log)", "mcp(x/y)", "read_file(/tmp)", " command(ls) "])
                     == ["git log", "ls"])

        let rules = AgyPermissionRules(
            allow: ["git log", "git status", "ls", "npm test", "git fetch && git rebase",
                    "curl -s \"http://localhost:3000/\"", "", "   "],
            deny: ["rm -rf", "git push"])

        // Allowed: every part starts with a rule's words
        precondition(rules.verdict(for: "git log --oneline -5") == .allowed)
        precondition(rules.verdict(for: "ls -la && git status") == .allowed)
        precondition(rules.verdict(for: "npm test 2>&1") == .allowed)
        precondition(rules.verdict(for: "git fetch && git rebase") == .allowed)
        precondition(rules.verdict(for: "curl -s http://localhost:3000/") == .allowed)

        // Unknown: a part no rule covers, a shorter command, a word that only shares a prefix
        precondition(rules.verdict(for: "ls && npm install") == .unknown)
        precondition(rules.verdict(for: "git") == .unknown)
        precondition(rules.verdict(for: "lsof -i :3000") == .unknown)
        precondition(rules.verdict(for: "npm testing") == .unknown)
        precondition(rules.verdict(for: "git fetch") == .unknown)        // the chain rule is exact
        precondition(rules.verdict(for: "git fetch && git rebase -i") == .unknown)
        // Unknown: a hidden command, an unreadable line, an empty one
        precondition(rules.verdict(for: "ls $(rm -rf ~)") == .unknown)
        precondition(rules.verdict(for: "ls `whoami`") == .unknown)
        precondition(rules.verdict(for: "ls 'open") == .unknown)
        precondition(rules.verdict(for: "") == .unknown)
        precondition(rules.verdict(for: " ; ") == .unknown)
        // Empty rules match nothing
        precondition(AgyPermissionRules(allow: [""]).verdict(for: "anything") == .unknown)

        // Denied: any part a deny rule covers, even next to allowed parts
        precondition(rules.verdict(for: "rm -rf build") == .denied)
        precondition(rules.verdict(for: "git status && git push origin main") == .denied)
        precondition(rules.verdict(for: "rm build") == .unknown)

        // A rule with a substitution only matches that exact command
        let exact = AgyPermissionRules(allow: ["TOKEN=$(gcloud auth print-access-token) terraform apply"])
        precondition(exact.verdict(for: "TOKEN=$(gcloud auth print-access-token) terraform apply") == .allowed)
        precondition(exact.verdict(for: "TOKEN=$(gcloud auth print-access-token) terraform apply -auto-approve") == .unknown)

        // Grants objects: allow and deny lists, other kinds ignored
        var added = AgyPermissionRules()
        added.add(grants: ["allow": ["command(make)", "mcp(a/b)"], "deny": ["command(sudo)"], "ask": ["command(x)"]])
        precondition(added == AgyPermissionRules(allow: ["make"], deny: ["sudo"]))
        added.add(grants: ["allow": "not a list"])
        precondition(added == AgyPermissionRules(allow: ["make"], deny: ["sudo"]))

        // Project folders: plain and git folders, percent-decoded; other schemes ignored
        let project: [String: Any] = ["projectResources": ["resources": [
            ["folderUri": "file:///Users/me/My%20App"],
            ["gitFolder": ["folderUri": "file:///Users/me/repo", "defaultBranch": "main"]],
            ["folderUri": "https://example.com/x"],
        ]]]
        precondition(AgyPermissionRules.projectFolders(project) == ["/Users/me/My App", "/Users/me/repo"])
        precondition(AgyPermissionRules.folder("/Users/me/repo", contains: "/Users/me/repo"))
        precondition(AgyPermissionRules.folder("/Users/me/repo", contains: "/Users/me/repo/sub/dir"))
        precondition(AgyPermissionRules.folder("/Users/me/repo/", contains: "/Users/me/repo/sub"))
        precondition(!AgyPermissionRules.folder("/Users/me/repo", contains: "/Users/me/repo-2"))
        precondition(!AgyPermissionRules.folder("/", contains: "/Users/me"))
        precondition(!AgyPermissionRules.folder("", contains: "/Users/me"))
        // Current files nest the grants twice, older ones once
        precondition(AgyPermissionRules.projectGrants(["permissionGrants": ["permissionGrants": ["allow": ["command(a)"]]]])["allow"] as? [String] == ["command(a)"])
        precondition(AgyPermissionRules.projectGrants(["permissionGrants": ["allow": ["command(b)"]]])["allow"] as? [String] == ["command(b)"])

        // Loading from a home folder laid out like Antigravity's
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("coucou-agy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let gemini = home.appendingPathComponent(".gemini")
        write(#"{"permissions":{"allow":["command(ls)"],"deny":["command(rm -rf)"]}}"#,
              to: gemini.appendingPathComponent("antigravity-cli/settings.json"))
        write(#"{"userSettings":{"globalPermissionGrants":{"allow":["command(git status)"]}}}"#,
              to: gemini.appendingPathComponent("config/config.json"))
        write(#"{"projectResources":{"resources":[{"folderUri":"file:///work/app"}]},"permissionGrants":{"permissionGrants":{"allow":["command(npm test)"]}}}"#,
              to: gemini.appendingPathComponent("config/projects/p1.json"))
        write(#"{"projectResources":{"resources":[{"folderUri":"file:///work/other"}]},"permissionGrants":{"permissionGrants":{"allow":["command(make)"]}}}"#,
              to: gemini.appendingPathComponent("config/projects/p2.json"))
        write(#"{"permissionGrants":{"permissionGrants":{"allow":["command(cat)"]}}}"#,
              to: gemini.appendingPathComponent("config/projects/outside-of-project.json"))
        write("not json", to: gemini.appendingPathComponent("config/projects/broken.json"))

        let inApp = AgyPermissionRules.load(home: home, cwd: "/work/app/src")
        precondition(inApp == AgyPermissionRules(allow: ["ls", "git status", "npm test"], deny: ["rm -rf"]))
        precondition(inApp.verdict(for: "npm test") == .allowed)
        precondition(inApp.verdict(for: "make") == .unknown)       // another project's grant
        precondition(inApp.verdict(for: "rm -rf /tmp/x") == .denied)
        let outside = AgyPermissionRules.load(home: home, cwd: "/elsewhere")
        precondition(outside == AgyPermissionRules(allow: ["ls", "git status", "cat"], deny: ["rm -rf"]))
        // No Antigravity files at all: no rules, every command is unknown
        let empty = AgyPermissionRules.load(home: home.appendingPathComponent("nobody"), cwd: "/work/app")
        precondition(empty == AgyPermissionRules())
        precondition(empty.verdict(for: "ls") == .unknown)

        print("AgyPermissionRules: all tests passed")
    }
}
