import Foundation

// The session branch's CI and the reviews on your PRs, on top of GitHubPulse.
// Same cases as the tests in windows/src-tauri/src/github.rs.

@main
enum GitHubBranchCITests {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String, line: Int = #line) {
        precondition(condition, "line \(line): \(what)")
        passed += 1
    }

    static func main() {
        githubURLs()
        upstreamFromConfig()
        worktreeGitDir()
        parsesAGraphQLAnswer()
        branchCIIsAnnouncedOnlyWhenItFinishes()
        newReviewsByOthersAreAnnounced()
        print("GitHub branch CI: \(passed) checks passed")
    }

    static func githubURLs() {
        func ok(_ u: String) -> String? { GitHubBranch.parseGitHubURL(u).map { "\($0.0)/\($0.1)" } }
        check(ok("https://github.com/Louis-CFM/coucou.git") == "Louis-CFM/coucou", "https .git")
        check(ok("https://github.com/Louis-CFM/coucou") == "Louis-CFM/coucou", "https")
        check(ok("https://me@github.com/a/b/") == "a/b", "user + trailing slash")
        check(ok("git@github.com:a/b.git") == "a/b", "scp-like")
        check(ok("ssh://git@github.com/a/b.git") == "a/b", "ssh")
        check(ok("https://gitlab.com/a/b.git") == nil, "not GitHub")
        check(ok("https://github.com/a") == nil, "no repo")
    }

    static func upstreamFromConfig() {
        let config = """
        [core]
        \tbare = false
        [remote "origin"]
        \turl = git@github.com:Louis-CFM/coucou.git
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        [remote "fork"]
        \turl = https://github.com/jhoan/coucou.git
        [branch "main"]
        \tremote = origin
        \tmerge = refs/heads/main
        [branch "local-name"]
        \tremote = fork
        \tmerge = refs/heads/remote-name
        """
        let main = GitHubBranch.resolveUpstream(config: config, local: "main")
        check(main == GitHubBranchRef(owner: "Louis-CFM", name: "coucou", branch: "main"), "main")
        let forked = GitHubBranch.resolveUpstream(config: config, local: "local-name")
        check(forked?.owner == "jhoan" && forked?.branch == "remote-name", "fork upstream")
        // Never pushed: same name on origin.
        let fresh = GitHubBranch.resolveUpstream(config: config, local: "feat/x")
        check(fresh?.owner == "Louis-CFM" && fresh?.branch == "feat/x", "never pushed")
        // No origin at all: whichever remote points at GitHub.
        let other = GitHubBranch.resolveUpstream(config: "[remote \"up\"]\n\turl = https://github.com/x/y\n", local: "dev")
        check(other == GitHubBranchRef(owner: "x", name: "y", branch: "dev"), "any GitHub remote")
        check(GitHubBranch.resolveUpstream(config: "[remote \"origin\"]\n\turl = https://gitlab.com/x/y\n", local: "dev") == nil,
              "no GitHub remote")
    }

    static func worktreeGitDir() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("coucou-gh-\(ProcessInfo.processInfo.processIdentifier)")
        defer { try? fm.removeItem(at: root) }
        let mainGit = root.appendingPathComponent("repo/.git")
        let wtGit = mainGit.appendingPathComponent("worktrees/wt")
        let wt = root.appendingPathComponent("wt")
        try! fm.createDirectory(at: wtGit, withIntermediateDirectories: true)
        try! fm.createDirectory(at: wt.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try! "[remote \"origin\"]\n\turl = https://github.com/a/b.git\n"
            .write(to: mainGit.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try! "ref: refs/heads/fix/thing\n".write(to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try! "../..\n".write(to: wtGit.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try! "gitdir: \(wtGit.path)\n".write(to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let got = GitHubBranch.of(cwd: wt.appendingPathComponent("sub"))
        check(got == GitHubBranchRef(owner: "a", name: "b", branch: "fix/thing"), "worktree")

        // The main checkout itself, and a detached HEAD.
        try! "ref: refs/heads/main\n".write(to: mainGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        check(GitHubBranch.of(cwd: root.appendingPathComponent("repo")) == GitHubBranchRef(owner: "a", name: "b", branch: "main"),
              "normal checkout")
        try! "4b825dc642cb6eb9a060e54bf8d69288fbee4904\n"
            .write(to: mainGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        check(GitHubBranch.of(cwd: root.appendingPathComponent("repo")) == nil, "detached HEAD")
        check(GitHubBranch.of(cwd: URL(fileURLWithPath: "/")) == nil, "no repository")
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func parsesAGraphQLAnswer() {
        let now = Date()
        let recent = iso(now.addingTimeInterval(-3600))
        let data = Data("""
        {
          "data": {
            "viewer": {
              "login": "me",
              "pullRequests": { "nodes": [
                { "number": 8, "title": "Calendar", "url": "u8", "isDraft": false, "headRefName": "feat/cal",
                  "reviewDecision": null, "updatedAt": "\(recent)",
                  "repository": { "nameWithOwner": "Louis-CFM/coucou", "url": "r" },
                  "commits": { "nodes": [{ "commit": { "oid": "abc", "statusCheckRollup": { "state": "FAILURE" } } }] },
                  "latestReviews": { "nodes": [{ "id": "r1", "state": "COMMENTED", "author": { "login": "louis" } }] } },
                { "number": 2, "title": "[Snyk] Fix", "url": "u2", "isDraft": false, "headRefName": "snyk-fix-1",
                  "reviewDecision": null, "updatedAt": "2025-12-14T14:33:19Z",
                  "repository": { "nameWithOwner": "me/old", "url": "r" }, "latestReviews": { "nodes": [] } }
              ] },
              "repositories": { "nodes": [] }
            },
            "reviewRequested": { "issueCount": 0, "nodes": [] },
            "sessionBranch": {
              "nameWithOwner": "Louis-CFM/coucou",
              "ref": { "target": {
                "oid": "abc", "url": "commit-url",
                "statusCheckRollup": { "state": "FAILURE", "contexts": { "nodes": [
                  { "__typename": "CheckRun", "name": "lint", "conclusion": "SUCCESS", "detailsUrl": "l" },
                  { "__typename": "CheckRun", "name": "build", "conclusion": "FAILURE", "detailsUrl": "job-url" },
                  { "__typename": "StatusContext", "context": "vercel", "state": "ERROR", "targetUrl": "v" }
                ] } }
              } }
            }
          }
        }
        """.utf8)
        let target = GitHubBranchRef(owner: "Louis-CFM", name: "coucou", branch: "feat/cal")
        guard let p = GitHubPulse.parse(data, target: target, now: now) else {
            check(false, "parses"); return
        }
        // The ten-month-old bot PR is gone.
        check(p.myPRs.map(\.number) == [8], "stale pull requests left out")
        check(p.myPRs.first?.headRef == "feat/cal", "head branch")
        check(p.myPRs.first?.reviews == [GitHubReview(id: "r1", state: "COMMENTED", author: "louis")], "reviews")
        let b = p.branch
        check(b?.ci == .failure && b?.failing == ["build", "vercel"] && b?.url == "job-url"
              && b?.prId == "Louis-CFM/coucou#8" && b?.pushed == true && b?.oid == "abc", "branch CI")
        check(p.hasPending == false, "nothing running")

        // A branch GitHub doesn't know yet, and a repository the token can't see.
        func answer(_ sessionBranch: String) -> Data {
            Data(#"{"data": {"viewer": {"login": "me"}, "sessionBranch": \#(sessionBranch)}}"#.utf8)
        }
        let newBranch = GitHubBranchRef(owner: "a", name: "b", branch: "new")
        let unpushed = GitHubPulse.parse(answer(#"{"nameWithOwner": "a/b", "ref": null}"#), target: newBranch)
        check(unpushed?.branch?.pushed == false && unpushed?.branch?.ci == .unknown, "not pushed")
        check(GitHubPulse.parse(answer("null"), target: newBranch)?.branch == nil, "repository not visible")
        check(GitHubPulse.parse(data, target: nil)?.branch == nil, "no session branch")
    }

    static func pulse(branch: GitHubBranchCI?, reviews: [(String, String, String)] = []) -> GitHubPulse {
        let pr = GitHubPR(id: "a/b#7", title: "Fix", url: "u7", repo: "a/b", number: 7, isDraft: false,
                          ci: .unknown, review: .unknown, headRef: "fix",
                          reviews: reviews.map { GitHubReview(id: $0.0, state: $0.1, author: $0.2) })
        return GitHubPulse(login: "me", myPRs: [pr], toReview: [], mainCI: [], fetchedAt: Date(), branch: branch)
    }

    static func ci(_ state: CIState, oid: String = "abc", branch: String = "fix", repo: String = "a/b") -> GitHubBranchCI {
        GitHubBranchCI(repo: repo, branch: branch, pushed: true, oid: oid, ci: state,
                       failing: state == .failure ? ["build"] : [], url: "", prId: "a/b#7")
    }

    static func branchCIIsAnnouncedOnlyWhenItFinishes() {
        // First poll: nothing, whatever the state.
        check(GitHubPulse.events(old: nil, new: pulse(branch: ci(.failure))).isEmpty, "first poll silent")
        check(pulse(branch: ci(.pending)).hasPending, "a running branch speeds up polling")

        // Watched going from running to done.
        let failed = GitHubPulse.events(old: pulse(branch: ci(.pending)), new: pulse(branch: ci(.failure)))
        check(failed == [.branchCIFailed(repo: "a/b", branch: "fix")], "CI failed")
        let passed = GitHubPulse.events(old: pulse(branch: ci(.pending)), new: pulse(branch: ci(.success)))
        check(passed == [.branchCIPassed(repo: "a/b", branch: "fix")], "CI passed")
        // Still red on the next poll: already said.
        check(GitHubPulse.events(old: pulse(branch: ci(.failure)), new: pulse(branch: ci(.failure))).isEmpty, "said once")

        // A new commit that finished between two polls is news too.
        let fast = GitHubPulse.events(old: pulse(branch: ci(.success, oid: "old")), new: pulse(branch: ci(.failure, oid: "new")))
        check(fast == [.branchCIFailed(repo: "a/b", branch: "fix")], "fast CI on a new commit")
        check(GitHubPulse.events(old: pulse(branch: ci(.success, oid: "old")),
                                 new: pulse(branch: ci(.pending, oid: "new"))).isEmpty, "new commit still running")

        // Switching to another branch or repo is old news.
        check(GitHubPulse.events(old: pulse(branch: ci(.pending)),
                                 new: pulse(branch: ci(.failure, branch: "other"))).isEmpty, "another branch")
        check(GitHubPulse.events(old: pulse(branch: ci(.pending)),
                                 new: pulse(branch: ci(.failure, repo: "c/d"))).isEmpty, "another repo")
        check(GitHubPulse.events(old: pulse(branch: nil), new: pulse(branch: ci(.failure))).isEmpty, "first session")
    }

    static func newReviewsByOthersAreAnnounced() {
        let before = pulse(branch: nil, reviews: [("r1", "COMMENTED", "louis")])
        check(GitHubPulse.events(old: before, new: before).isEmpty, "nothing new")

        let approved = pulse(branch: nil, reviews: [("r1", "COMMENTED", "louis"), ("r2", "APPROVED", "ana")])
        check(GitHubPulse.events(old: before, new: approved) == [.reviewApproved(prId: "a/b#7")], "approval")
        let changes = pulse(branch: nil, reviews: [("r3", "CHANGES_REQUESTED", "louis")])
        check(GitHubPulse.events(old: before, new: changes) == [.changesRequested(prId: "a/b#7")], "changes requested")
        let comment = pulse(branch: nil, reviews: [("r4", "COMMENTED", "ana")])
        check(GitHubPulse.events(old: before, new: comment) == [.reviewCommented(prId: "a/b#7")], "comment")

        // Your own review says nothing.
        let mine = pulse(branch: nil, reviews: [("r5", "COMMENTED", "me")])
        check(GitHubPulse.events(old: before, new: mine).isEmpty, "own review")

        // A PR coming back into the list doesn't replay its reviews.
        let empty = GitHubPulse(login: "me", myPRs: [], toReview: [], mainCI: [], fetchedAt: Date())
        check(GitHubPulse.events(old: empty, new: approved).isEmpty, "PR not seen before")
    }
}
