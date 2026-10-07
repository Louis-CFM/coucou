import Foundation

// MARK: - GitRepoInfo
//
// The GitHub repo and current branch of a working directory, read from the files of
// its .git folder (no `git` process). Worktrees and submodules (a `.git` file with
// "gitdir: …") are followed. nil when the folder isn't a git checkout of a GitHub
// repo, is on a detached HEAD, or can't be read (App Store sandbox).

struct GitRepoInfo: Equatable {
    let repo: String     // "owner/name"
    let branch: String

    static func read(cwd: String) -> GitRepoInfo? {
        guard !cwd.isEmpty, let gitDir = findGitDir(from: URL(fileURLWithPath: cwd)) else { return nil }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8),
              let branch = branch(fromHEAD: head) else { return nil }
        // A worktree's config lives in the main repo: <main>/.git/worktrees/<name> → <main>/.git
        let commonDir: URL = {
            if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
                return URL(fileURLWithPath: path, relativeTo: gitDir).standardizedFileURL
            }
            return gitDir
        }()
        guard let config = try? String(contentsOf: commonDir.appendingPathComponent("config"), encoding: .utf8),
              let remote = originURL(fromConfig: config),
              let repo = githubRepo(fromRemote: remote) else { return nil }
        return GitRepoInfo(repo: repo, branch: branch)
    }

    /// Walks up from `start` to the nearest `.git` folder, following a `.git` file's "gitdir:".
    static func findGitDir(from start: URL) -> URL? {
        var dir = start.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<40 {
            let candidate = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir) {
                if isDir.boolValue { return candidate }
                if let text = try? String(contentsOf: candidate, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    return URL(fileURLWithPath: path, relativeTo: dir).standardizedFileURL
                }
                return nil
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// "ref: refs/heads/feature/x" → "feature/x". nil on a detached HEAD.
    static func branch(fromHEAD head: String) -> String? {
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let branch = String(line.dropFirst(prefix.count))
        return branch.isEmpty ? nil : branch
    }

    /// The url of [remote "origin"] in a git config file.
    static func originURL(fromConfig config: String) -> String? {
        var inOrigin = false
        for raw in config.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
                continue
            }
            if inOrigin, line.hasPrefix("url") {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { return parts[1].trimmingCharacters(in: .whitespaces) }
            }
        }
        return nil
    }

    /// "owner/name" from a github.com remote: https://github.com/o/n(.git), git@github.com:o/n.git,
    /// ssh://git@github.com/o/n.git. nil for other hosts.
    static func githubRepo(fromRemote remote: String) -> String? {
        var path: Substring
        if let range = remote.range(of: "github.com:") {
            path = remote[range.upperBound...]
        } else if let range = remote.range(of: "github.com/") {
            path = remote[range.upperBound...]
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        if path.hasSuffix("/") { path = path.dropLast() }
        let parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
