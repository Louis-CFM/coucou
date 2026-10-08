import Foundation

@main
enum GitRepoInfoTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("GitRepoInfo.githubRepo")
        check("https", GitRepoInfo.githubRepo(fromRemote: "https://github.com/o/n.git") == "o/n")
        check("https no .git", GitRepoInfo.githubRepo(fromRemote: "https://github.com/o/n") == "o/n")
        check("scp-like ssh", GitRepoInfo.githubRepo(fromRemote: "git@github.com:o/n.git") == "o/n")
        check("ssh url", GitRepoInfo.githubRepo(fromRemote: "ssh://git@github.com/o/n.git") == "o/n")
        check("other host → nil", GitRepoInfo.githubRepo(fromRemote: "https://gitlab.com/o/n.git") == nil)
        check("too deep → nil", GitRepoInfo.githubRepo(fromRemote: "https://github.com/o/n/x") == nil)

        print("GitRepoInfo.branch")
        check("simple", GitRepoInfo.branch(fromHEAD: "ref: refs/heads/main\n") == "main")
        check("with slash", GitRepoInfo.branch(fromHEAD: "ref: refs/heads/feat/x") == "feat/x")
        check("detached → nil", GitRepoInfo.branch(fromHEAD: "0123456789abcdef\n") == nil)

        print("GitRepoInfo.originURL")
        let config = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = https://github.com/a/up.git
        [remote "origin"]
        \turl = git@github.com:me/fork.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        check("picks origin", GitRepoInfo.originURL(fromConfig: config) == "git@github.com:me/fork.git")
        check("no origin → nil", GitRepoInfo.originURL(fromConfig: "[core]\n\tbare = false") == nil)

        print("GitRepoInfo.read (temp checkout and worktree)")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gri-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let main = root.appendingPathComponent("main")
        let git = main.appendingPathComponent(".git")
        try? fm.createDirectory(at: git.appendingPathComponent("worktrees/wt"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: main.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        try? "ref: refs/heads/dev\n".write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try? "[remote \"origin\"]\n\turl = https://github.com/me/app.git\n"
            .write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        check("from a subfolder",
              GitRepoInfo.read(cwd: main.appendingPathComponent("src/deep").path) == GitRepoInfo(repo: "me/app", branch: "dev"))
        let wt = root.appendingPathComponent("wt")
        try? fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try? "gitdir: \(git.path)/worktrees/wt\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try? "ref: refs/heads/feature/x\n".write(to: git.appendingPathComponent("worktrees/wt/HEAD"), atomically: true, encoding: .utf8)
        try? "../..\n".write(to: git.appendingPathComponent("worktrees/wt/commondir"), atomically: true, encoding: .utf8)
        check("worktree: own branch, main repo's remote",
              GitRepoInfo.read(cwd: wt.path) == GitRepoInfo(repo: "me/app", branch: "feature/x"))
        check("not a repo → nil", GitRepoInfo.read(cwd: root.path) == nil)

        if failures == 0 { print("\nAll tests passed."); exit(0) }
        print("\n\(failures) test(s) failed."); exit(1)
    }
}
