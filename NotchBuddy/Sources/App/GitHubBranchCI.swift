import Foundation

// GitHub — CI for the branch you're on. Same rules as windows/src-tauri/src/github.rs.
//
// "The branch you're on" is the branch checked out in the folder of the last
// Claude Code session, read straight from its .git directory: no `git` process
// and nothing to configure. Its CI comes back with the pulse (GithubPoller), as
// the `sessionBranch` part of the same GraphQL query, and lands in
// GitHubPulse.branch. GitHubPulse.events says when a run on it finishes.

// MARK: - The session's branch

struct GitHubBranchRef: Equatable, Sendable {
    var owner: String
    var name: String
    /// The branch's name on GitHub (its upstream), which is what CI ran on.
    var branch: String
}

enum GitHubBranch {
    /// The GitHub repository and branch checked out in `cwd`, if there is one.
    static func of(cwd: URL) -> GitHubBranchRef? {
        guard let (gitDir, commonDir) = findGitDir(cwd),
              let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        // Detached HEAD (rebase, bisect, checkout of a tag): no branch to follow.
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ref: refs/heads/") else { return nil }
        let local = String(trimmed.dropFirst("ref: refs/heads/".count))
        guard let config = try? String(contentsOf: commonDir.appendingPathComponent("config"), encoding: .utf8)
        else { return nil }
        return resolveUpstream(config: config, local: local)
    }

    /// `.git` is a directory in a normal checkout and a `gitdir: …` file in a
    /// worktree, whose config then lives in the main repository (`commondir`).
    static func findGitDir(_ start: URL) -> (URL, URL)? {
        let fm = FileManager.default
        var dir = start.standardizedFileURL
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue { return (dotGit, dotGit) }
                guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("gitdir:") else { return nil }
                let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                let gitDir = target.hasPrefix("/")
                    ? URL(fileURLWithPath: target)
                    : dir.appendingPathComponent(target).standardizedFileURL
                var common = gitDir
                if let c = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                    let rel = c.trimmingCharacters(in: .whitespacesAndNewlines)
                    common = rel.hasPrefix("/")
                        ? URL(fileURLWithPath: rel)
                        : gitDir.appendingPathComponent(rel).standardizedFileURL
                }
                return (gitDir, common)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return nil }
            dir = parent
        }
    }

    /// Follows `branch.<local>.remote` / `.merge` to the GitHub repo and remote
    /// branch name; a branch with no upstream is assumed to be pushed to origin
    /// under the same name.
    static func resolveUpstream(config: String, local: String) -> GitHubBranchRef? {
        let entries = parseGitConfig(config)
        func get(_ section: String, _ sub: String, _ key: String) -> String? {
            entries.first { $0.section == section && $0.sub == sub && $0.key == key }?.value
        }

        let remote = get("branch", local, "remote") ?? "origin"
        var branch = local
        if let merge = get("branch", local, "merge"), merge.hasPrefix("refs/heads/") {
            branch = String(merge.dropFirst("refs/heads/".count))
        }

        // No such remote: take whichever remote points at GitHub.
        guard let url = get("remote", remote, "url")
                ?? entries.first(where: { $0.section == "remote" && $0.key == "url" && parseGitHubURL($0.value) != nil })?.value,
              let (owner, name) = parseGitHubURL(url) else { return nil }
        return GitHubBranchRef(owner: owner, name: name, branch: branch)
    }

    /// (section, subsection, key, value) — just enough of git-config(1) for
    /// `[remote "x"]` and `[branch "x"]`. Section and key names are case-insensitive.
    static func parseGitConfig(_ text: String) -> [(section: String, sub: String, key: String, value: String)] {
        var out: [(section: String, sub: String, key: String, value: String)] = []
        var section = "", sub = ""
        let quotes = CharacterSet(charactersIn: "\"")
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast())
                if let space = header.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                    section = header[..<space].lowercased()
                    sub = header[header.index(after: space)...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: quotes)
                } else {
                    section = header.lowercased()
                    sub = ""
                }
                continue
            }
            if let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eq)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: quotes)
                out.append((section, sub, key, value))
            }
        }
        return out
    }

    /// `https://github.com/o/r(.git)`, `git@github.com:o/r.git`,
    /// `ssh://git@github.com/o/r.git` → (o, r). Anything not on github.com → nil.
    static func parseGitHubURL(_ url: String) -> (String, String)? {
        guard let at = url.range(of: "github.com") else { return nil }
        var rest = Substring(url[at.upperBound...])
        guard rest.hasPrefix(":") || rest.hasPrefix("/") else { return nil }
        rest = rest.dropFirst()
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        if rest.hasSuffix(".git") { rest = rest.dropLast(4) }
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let owner = String(rest[..<slash])
        let name = String(rest[rest.index(after: slash)...])
        guard !owner.isEmpty, !name.isEmpty, !name.contains("/") else { return nil }
        return (owner, name)
    }

    /// Variables for the pulse query: the `sessionBranch` part only runs when
    /// there is a branch to follow.
    static func queryVariables(for target: GitHubBranchRef?) -> [String: Any] {
        guard let t = target else { return ["owner": "", "name": "", "ref": "", "withBranch": false] }
        return ["owner": t.owner, "name": t.name, "ref": "refs/heads/\(t.branch)", "withBranch": true]
    }
}

// MARK: - Its CI

struct GitHubBranchCI: Equatable {
    var repo: String            // "owner/repo"
    var branch: String
    /// False when GitHub doesn't know the branch yet (never pushed).
    var pushed: Bool
    var oid: String
    var ci: CIState
    /// Names of the checks that failed.
    var failing: [String]
    /// Straight to the failing job when there is one; the commit page (which lists
    /// every check) otherwise; "" when the branch isn't pushed.
    var url: String
    /// Your open pull request for this branch ("owner/repo#n"), if there is one.
    var prId: String? = nil

    /// The `sessionBranch` node of the pulse answer. A repository the token can't
    /// see comes back null: no CI row then.
    static func parse(_ node: Any?, target: GitHubBranchRef, myPRs: [GitHubPR]) -> GitHubBranchCI? {
        guard let repoNode = node as? [String: Any],
              let repo = repoNode["nameWithOwner"] as? String else { return nil }
        let prId = myPRs.first {
            $0.headRef == target.branch && $0.repo.lowercased() == repo.lowercased()
        }?.id

        guard let ref = repoNode["ref"] as? [String: Any],
              let commit = ref["target"] as? [String: Any] else {
            return GitHubBranchCI(repo: repo, branch: target.branch, pushed: false, oid: "",
                                  ci: .unknown, failing: [], url: "", prId: prId)
        }

        let rollup = commit["statusCheckRollup"] as? [String: Any]
        let contexts = (rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        var failing: [String] = []
        var failingURL: String?
        for c in contexts {
            let name: String, bad: Bool, url: String
            switch c["__typename"] as? String {
            case "CheckRun":
                name = c["name"] as? String ?? ""
                bad = ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"]
                    .contains(c["conclusion"] as? String ?? "")
                url = c["detailsUrl"] as? String ?? ""
            case "StatusContext":
                name = c["context"] as? String ?? ""
                bad = ["FAILURE", "ERROR"].contains(c["state"] as? String ?? "")
                url = c["targetUrl"] as? String ?? ""
            default:
                continue
            }
            if bad {
                if failingURL == nil, !url.isEmpty { failingURL = url }
                failing.append(name)
            }
        }

        return GitHubBranchCI(
            repo: repo, branch: target.branch, pushed: true,
            oid: commit["oid"] as? String ?? "",
            ci: CIState(rawGitHub: rollup?["state"] as? String),
            failing: failing,
            url: failingURL ?? commit["url"] as? String ?? "",
            prId: prId
        )
    }
}
