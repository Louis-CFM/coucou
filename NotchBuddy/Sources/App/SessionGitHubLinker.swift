import Foundation

// MARK: - SessionGitHubLinker
//
// Finds the open PR and the CI of the branch the focused Claude Code session works on.
// Runs only while the island is open on that session (see OverviewView): reads the
// session's .git (branch may change between calls), then asks GitHub at most once a
// minute per branch, every 30 s while CI is running.

@MainActor
final class SessionGitHubLinker {
    static let shared = SessionGitHubLinker()
    private var inFlight: Set<String> = []
    private init() {}

    func refresh(for task: AgentTask?) {
        guard let task, task.source == .claudeCode, !task.isIntegration,
              let cwd = task.sessionCwd, !cwd.isEmpty else { return }
        let state = AppState.shared
        guard let git = GitRepoInfo.read(cwd: cwd) else {
            if state.sessionGit[task.id] != nil { state.sessionGit[task.id] = nil }
            return
        }
        if state.sessionGit[task.id] != git { state.sessionGit[task.id] = git }

        guard let token = KeychainStore.shared.get("github-token"),
              let variables = SessionBranchInfo.variables(repo: git.repo, branch: git.branch) else { return }
        let key = "\(git.repo)@\(git.branch)"
        if let known = state.sessionBranches[key],
           !GitHubPulse.isStale(fetchedAt: known.fetchedAt, maxAge: known.hasPending ? 30 : 60) { return }
        guard inFlight.insert(key).inserted else { return }

        Task {
            defer { inFlight.remove(key) }
            guard let url = URL(string: "https://api.github.com/graphql"),
                  let body = try? JSONSerialization.data(withJSONObject: ["query": SessionBranchInfo.query,
                                                                          "variables": variables]) else { return }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            guard let (data, response) = try? await URLSession.shared.data(for: req),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let info = SessionBranchInfo.parse(data, repo: git.repo, branch: git.branch) else {
                appendAppLog("github.log", "session branch lookup failed for \(key)")
                return
            }
            state.sessionBranches[key] = info
        }
    }

    /// Next lookup ignores the cache (after a merge or a re-run).
    func invalidate(repo: String, branch: String) {
        AppState.shared.sessionBranches["\(repo)@\(branch)"]?.fetchedAt = .distantPast
    }
}
