import Foundation

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    private var knownPush = ""
    private var hasPushBaseline = false
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 300)  // every 5 minutes
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
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

            let publicRepos  = (json["public_repos"]       as? Int) ?? 0
            let privateOwned = (json["owned_private_repos"] as? Int)
                            ?? (json["total_private_repos"] as? Int)
                            ?? 0
            let totalRepos = publicRepos + privateOwned

            self.fetchStars(token: token, totalRepos: totalRepos)
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

            let totalStars = repos.reduce(0) { $0 + ((($1["stargazers_count"] as? Int) ?? 0)) }
            let repoName = repos.first?["name"] as? String ?? ""
            let pushedAt = repos.first?["pushed_at"] as? String ?? ""

            Task { @MainActor in
                AppState.shared.githubStats = GitHubStats(totalRepos: totalRepos, totalStars: totalStars)
                let key = repoName + pushedAt
                guard !repoName.isEmpty else { return }
                if !self.hasPushBaseline {
                    self.hasPushBaseline = true
                    self.knownPush = key
                    return
                }
                guard key != self.knownPush else { return }
                self.knownPush = key
                AppState.shared.presentNotice(
                    pillId: "integration_github",
                    status: CoucouL10n.string("New push"),
                    headline: repoName,
                    detail: "",
                    isFailure: false
                )
            }
        }.resume()
    }
}
