import Foundation

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    // All properties below are accessed only on the main thread.
    private var pulseInFlight = false
    private var nextPulse: DispatchWorkItem?
    private var tokenGeneration = 0
    private var activityInFlight = false
    private var nextActivity: DispatchWorkItem?
    private init() {}

    func start() {
        guard timer == nil else { return }
        // Stats poll: every 5 minutes, starting 7 s after launch
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 7, repeating: 300)
        t.setEventHandler { [weak self] in self?.pollStats() }
        t.resume()
        timer = t
        // First pulse: 10 s after launch
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNextPulse(hasPending: false, delay: 10)
        }
        // First activity: 15 s after launch, then every 30 min
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNextActivity(delay: 15)
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

    // MARK: - Pulse (GraphQL, single chain)

    /// Dispatches guards + state reads to main, then fires network on background.
    private func pollPulse() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pulseInFlight else { return }
            guard let token = KeychainStore.shared.get("github-token"),
                  AppState.shared.activeIntegrations.contains("integration_github") else {
                self.scheduleNextPulse(hasPending: false)
                return
            }
            self.pulseInFlight = true
            let gen = self.tokenGeneration
            DispatchQueue.global(qos: .background).async { self.fetchPulse(token: token, generation: gen) }
        }
    }

    private func fetchPulse(token: String, generation: Int) {
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
                self.nbLog("pulse HTTP \(code)")
                self.finishPulse(hasPending: false)
                return
            }
            // Partial GraphQL errors: if "data" is present, parse anyway and log error count.
            // Only discard if "data" is absent or null.
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
                    self.nbLog("pulse GraphQL errors: \(errors.count)")
                }
                guard root["data"] is [String: Any] else {
                    self.finishPulse(hasPending: false); return
                }
            }
            guard let pulse = GitHubPulse.parse(data) else {
                self.finishPulse(hasPending: false); return
            }
            DispatchQueue.main.async {
                // Discard stale response if token changed while request was in flight
                guard self.tokenGeneration == generation else { return }
                let old = AppState.shared.githubPulse
                let events = GitHubPulse.events(old: old, new: pulse)
                AppState.shared.githubPulse = pulse
                AppState.shared.handleGitHubEvents(events)
            }
            self.finishPulse(hasPending: pulse.hasPending)
        }.resume()
    }

    /// Refreshes pulse data immediately if the last fetch is older than maxAge seconds (or absent).
    /// No-op when a request is already in flight. Safe to call from any thread.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pulseInFlight else { return }
            guard GitHubPulse.isStale(fetchedAt: AppState.shared.githubPulse?.fetchedAt,
                                      maxAge: maxAge) else { return }
            self.nextPulse?.cancel()
            self.nextPulse = nil
            self.pollPulse()
        }
    }

    /// Cancels any scheduled next poll, increments tokenGeneration to invalidate in-flight
    /// responses, then fires pollPulse immediately. If a request is already in flight,
    /// does not launch another — finishPulse will reschedule.
    /// Safe to call from any thread.
    func triggerPulseNow() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tokenGeneration += 1
            self.nextPulse?.cancel()
            self.nextPulse = nil
            guard !self.pulseInFlight else { return }
            self.pollPulse()
        }
    }

    private func nbLog(_ message: String) {
        appendAppLog("github.log", message)
    }

    /// Called from any thread; dispatches cleanup to main then schedules next poll.
    private func finishPulse(hasPending: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pulseInFlight = false
            self.scheduleNextPulse(hasPending: hasPending)
        }
    }

    /// Cancels any pending scheduled poll and schedules a new one on the main queue.
    /// Must run on the main thread.
    private func scheduleNextPulse(hasPending: Bool, delay: Double? = nil) {
        nextPulse?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollPulse() }
        nextPulse = work
        let d = delay ?? (hasPending ? 60.0 : 300.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }

    // MARK: - Activity (contribution calendar, 30 min cadence)

    private func pollActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.activityInFlight else { return }
            guard let token = KeychainStore.shared.get("github-token"),
                  AppState.shared.activeIntegrations.contains("integration_github") else {
                self.scheduleNextActivity()
                return
            }
            self.activityInFlight = true
            let gen = self.tokenGeneration
            DispatchQueue.global(qos: .background).async { self.fetchActivity(token: token, generation: gen) }
        }
    }

    private func fetchActivity(token: String, generation: Int) {
        guard let url = URL(string: "https://api.github.com/graphql") else {
            finishActivity(); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": Self.activityQuery]) else {
            finishActivity(); return
        }
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.nbLog("activity HTTP \(code)")
                self.finishActivity()
                return
            }
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
                    self.nbLog("activity GraphQL errors: \(errors.count)")
                }
                guard root["data"] is [String: Any] else {
                    self.finishActivity(); return
                }
            }
            guard let activity = GitHubActivity.parse(data) else {
                self.finishActivity(); return
            }
            DispatchQueue.main.async {
                guard self.tokenGeneration == generation else { return }
                AppState.shared.githubActivity = activity
            }
            self.finishActivity()
        }.resume()
    }

    /// Refreshes activity data immediately if stale. Safe to call from any thread.
    func refreshActivityIfStale(maxAge: TimeInterval = 300) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.activityInFlight else { return }
            guard GitHubPulse.isStale(fetchedAt: AppState.shared.githubActivity?.fetchedAt,
                                      maxAge: maxAge) else { return }
            self.nextActivity?.cancel()
            self.nextActivity = nil
            self.pollActivity()
        }
    }

    private func finishActivity() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activityInFlight = false
            self.scheduleNextActivity()
        }
    }

    private func scheduleNextActivity(delay: Double? = nil) {
        nextActivity?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pollActivity() }
        nextActivity = work
        let d = delay ?? 1800.0   // 30 minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: work)
    }

    // MARK: - GraphQL queries

    private static let graphQLQuery = """
    query {
      viewer {
        login
        pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title url isDraft reviewDecision
            repository { nameWithOwner url }
            commits(last: 1) {
              nodes { commit { oid statusCheckRollup { state } } }
            }
          }
        }
        repositories(first: 10, ownerAffiliations: [OWNER], orderBy: {field: PUSHED_AT, direction: DESC}) {
          nodes {
            nameWithOwner url isArchived
            defaultBranchRef {
              name
              target { ... on Commit { oid statusCheckRollup { state } } }
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

    private static let activityQuery = """
    query {
      viewer {
        login
        contributionsCollection {
          contributionCalendar {
            totalContributions
            weeks {
              contributionDays {
                date contributionCount contributionLevel weekday
              }
            }
          }
        }
      }
    }
    """
}
