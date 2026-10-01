import Foundation

// Polls GitHub for the pull requests that need the user: reviews requested from
// them, and their own open PRs with CI status. One GraphQL call per poll.
//
// Token: the one pasted in Settings wins; otherwise the local `gh` login is used
// (`gh auth token`), read fresh on every poll and never copied to the Keychain —
// logging out of gh disconnects Coucou too.

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "coucou.github", qos: .background)
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 7, repeating: 180)  // every 3 minutes
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Re-polls right away (after the token changes in Settings).
    func pollNow() {
        queue.async { [weak self] in self?.poll() }
    }

    // MARK: - Token

    private func resolveToken() -> (String, GitHubAuthSource)? {
        if let t = KeychainStore.shared.get("github-token"), !t.isEmpty { return (t, .manual) }
        #if !APPSTORE
        // The sandboxed App Store build can't launch gh.
        if let gh = LocalCLI.locate("gh"),
           let t = LocalCLI.capture(gh, ["auth", "token", "--hostname", "github.com"]) {
            return (t, .gh)
        }
        #endif
        return nil
    }

    // MARK: - Poll

    private static let query = """
    query {
      viewer { login }
      review: search(query: "is:open is:pr review-requested:@me archived:false sort:updated-desc", type: ISSUE, first: 5) {
        issueCount
        nodes { ... on PullRequest { number title url isDraft repository { nameWithOwner } author { login } } }
      }
      mine: search(query: "is:open is:pr author:@me archived:false sort:updated-desc", type: ISSUE, first: 5) {
        issueCount
        nodes { ... on PullRequest { number title url isDraft reviewDecision repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } }
      }
    }
    """

    private func poll() {
        guard let (token, source) = resolveToken() else {
            publish(summary: nil, source: nil, error: nil)
            return
        }

        guard let url = URL(string: "https://api.github.com/graphql") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": Self.query])

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                self.publish(summary: nil, source: source, error: error.localizedDescription, keepLast: true)
                return
            }
            guard code == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let msg = code == 401 ? (source == .gh ? "gh login expired — run gh auth login" : "Token rejected")
                                      : "GitHub error \(code)"
                self.publish(summary: nil, source: source, error: msg)
                return
            }
            if let errors = json["errors"] as? [[String: Any]], json["data"] == nil {
                self.publish(summary: nil, source: source, error: errors.first?["message"] as? String ?? "GitHub error")
                return
            }
            guard let d = json["data"] as? [String: Any] else { return }

            let login = (d["viewer"] as? [String: Any])?["login"] as? String ?? ""
            let review = d["review"] as? [String: Any]
            let mine = d["mine"] as? [String: Any]
            let summary = GitHubSummary(
                login: login,
                reviewCount: review?["issueCount"] as? Int ?? 0,
                reviewRequests: Self.parsePRs(review),
                mineCount: mine?["issueCount"] as? Int ?? 0,
                mine: Self.parsePRs(mine)
            )
            self.publish(summary: summary, source: source, error: nil)
        }.resume()
    }

    private static func parsePRs(_ search: [String: Any]?) -> [GitHubPR] {
        let nodes = search?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap { n in
            guard let url = n["url"] as? String, let number = n["number"] as? Int else { return nil }
            let commit = ((n["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"] as? [String: Any]
            let rollup = (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String
            return GitHubPR(
                url: url,
                number: number,
                title: n["title"] as? String ?? "",
                repo: (n["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "",
                author: (n["author"] as? [String: Any])?["login"] as? String,
                ci: GitHubCIState(rollup: rollup),
                reviewDecision: n["reviewDecision"] as? String,
                isDraft: n["isDraft"] as? Bool ?? false
            )
        }
    }

    /// `keepLast`: a network blip keeps the last good data on screen.
    private func publish(summary: GitHubSummary?, source: GitHubAuthSource?, error: String?, keepLast: Bool = false) {
        DispatchQueue.main.async {
            let state = AppState.shared
            state.githubAuthSource = source
            state.githubError = error
            if !(keepLast && summary == nil) { state.githubSummary = summary }
        }
    }
}
