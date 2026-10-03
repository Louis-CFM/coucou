import Foundation

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    private var pulseInFlight = false
    private init() {}

    func start() {
        guard timer == nil else { return }
        // Existing stats poll: every 5 minutes
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 300)
        t.setEventHandler { [weak self] in self?.pollStats() }
        t.resume()
        timer = t
        // Adaptive pulse poll starts 10 s after launch
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.pollPulse()
        }
    }

    // MARK: - Stats (unchanged logic)

    private func pollStats() {
        guard let token = KeychainStore.shared.get("github-token") else { return }
        fetchUser(token: token)
    }

    private func fetchUser(token: String) {
        guard let url = URL(string: "https://api.github.com/user") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let publicRepos  = (json["public_repos"]        as? Int) ?? 0
            let privateOwned = (json["owned_private_repos"] as? Int)
                            ?? (json["total_private_repos"] as? Int)
                            ?? 0
            self.fetchStars(token: token, totalRepos: publicRepos + privateOwned)
        }.resume()
    }

    private func fetchStars(token: String, totalRepos: Int) {
        guard let url = URL(string: "https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let repos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let totalStars = repos.reduce(0) { $0 + (($1["stargazers_count"] as? Int) ?? 0) }
            DispatchQueue.main.async {
                AppState.shared.githubStats = GitHubStats(totalRepos: totalRepos, totalStars: totalStars)
            }
        }.resume()
    }

    // MARK: - Pulse (GraphQL, adaptive cadence)

    /// Kicks off on main to check guards safely, then fires the network call on background.
    private func pollPulse() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pulseInFlight else { return }
            guard let token = KeychainStore.shared.get("github-token"),
                  AppState.shared.activeIntegrations.contains("integration_github") else {
                self.scheduleNextPulse(hasPending: false)
                return
            }
            self.pulseInFlight = true
            DispatchQueue.global(qos: .background).async { self.fetchPulse(token: token) }
        }
    }

    private func fetchPulse(token: String) {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            finishPulse(hasPending: false); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": Self.graphQLQuery]) else {
            finishPulse(hasPending: false); return
        }
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                // Keep previous data; log HTTP code only (no PR titles, no repo names)
                print("[GithubPoller] pulse HTTP \(code)")
                self.finishPulse(hasPending: false)
                return
            }
            // GraphQL errors in body → keep previous data
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
                print("[GithubPoller] pulse GraphQL errors: \(errors.count)")
                self.finishPulse(hasPending: false)
                return
            }
            guard let pulse = GitHubPulse.parse(data) else {
                self.finishPulse(hasPending: false)
                return
            }
            DispatchQueue.main.async {
                let old = AppState.shared.githubPulse
                let events = GitHubPulse.events(old: old, new: pulse)
                AppState.shared.githubPulse = pulse
                AppState.shared.handleGitHubEvents(events)
            }
            self.finishPulse(hasPending: pulse.hasPending)
        }.resume()
    }

    private func finishPulse(hasPending: Bool) {
        DispatchQueue.main.async { self.pulseInFlight = false }
        scheduleNextPulse(hasPending: hasPending)
    }

    private func scheduleNextPulse(hasPending: Bool) {
        let delay = hasPending ? 60.0 : 300.0
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.pollPulse()
        }
    }

    // MARK: - GraphQL query

    private static let graphQLQuery = """
    query {
      viewer {
        login
        pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title url isDraft reviewDecision
            repository { nameWithOwner url }
            commits(last: 1) {
              nodes { commit { statusCheckRollup { state } } }
            }
          }
        }
        repositories(first: 10, ownerAffiliations: [OWNER], orderBy: {field: PUSHED_AT, direction: DESC}) {
          nodes {
            nameWithOwner url isArchived
            defaultBranchRef {
              name
              target { ... on Commit { statusCheckRollup { state } } }
            }
          }
        }
      }
      reviewRequested: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
        issueCount
        nodes {
          ... on PullRequest {
            number title url isDraft
            author { login }
            repository { nameWithOwner url }
          }
        }
      }
    }
    """
}
