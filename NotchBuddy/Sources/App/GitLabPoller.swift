import Foundation

/// GitLab next to GitHub, with GithubPoller's cadence: the stats every 5 minutes,
/// the pulse (my merge requests and their pipeline, reviews waiting for me,
/// default-branch pipelines) every 60 s while some pipeline runs and every 5 min
/// otherwise, and the activity grid every 30 min. It talks to the REST v4 API of
/// the instance the user configured (gitlab.com unless `gitlab-url` says
/// otherwise) and requests nothing while the pill is off or the token is missing.
/// Parsing is in GitLabPulse.swift.
final class GitLabPoller: @unchecked Sendable {
    static let shared = GitLabPoller()
    static let pillId = "integration_gitlab"

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
        // Stats poll: every 5 minutes, starting 8 s after launch
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 8, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.pollStats() }
        t.resume()
        timer = t
        // First pulse: 11 s after launch
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNextPulse(hasPending: false, delay: 11)
        }
        // First activity: 16 s after launch, then every 30 min
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNextActivity(delay: 16)
        }
    }

    /// Merge requests, pipelines and activity are fetched when the GitLab pill
    /// is in the notch.
    @MainActor private static var isWanted: Bool {
        AppState.shared.activeIntegrations.contains(pillId)
    }

    /// The instance to talk to; nil when the stored URL is not acceptable.
    static var baseURL: String? {
        GitLab.normalizeBase(KeychainStore.shared.get("gitlab-url"))
    }

    /// True when `url` points at the configured instance (host and port).
    static func isOnInstance(_ url: URL) -> Bool {
        guard let base = baseURL, let b = URL(string: base) else { return false }
        return url.host == b.host && url.port == b.port
    }

    // MARK: - HTTP

    final class Reply: @unchecked Sendable {
        var code = 0
        var data: Data?
    }

    /// Guards a dictionary filled from several threads.
    final class Collector<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Value] = [:]
        func set(_ index: Int, _ value: Value) { lock.withLock { values[index] = value } }
        var all: [Int: Value] { lock.withLock { values } }
    }

    /// One authenticated GET, blocking: only called from background queues. The
    /// token is never logged. nil when nothing came back, the status is not 2xx
    /// or the body is not JSON.
    func get(base: String, token: String, path: String, query: [String: String] = [:]) -> Any? {
        guard var comps = URLComponents(string: GitLab.apiURL(base: base, path: path)) else { return nil }
        if !query.isEmpty {
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            reply.code = (response as? HTTPURLResponse)?.statusCode ?? 0
            reply.data = data
            done.signal()
        }.resume()
        done.wait()

        guard (200..<300).contains(reply.code), let data = reply.data else {
            nbLog("\(path) HTTP \(reply.code)")
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func nbLog(_ message: String) {
        appendAppLog("gitlab.log", message)
    }

    // MARK: - Stats

    private func pollStats() {
        guard !DemoEngine.isPollerPaused else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, Self.isWanted,
                  let token = KeychainStore.shared.get("gitlab-token"),
                  let base = Self.baseURL else { return }
            let gen = self.tokenGeneration
            DispatchQueue.global(qos: .background).async { self.fetchStats(token: token, base: base, generation: gen) }
        }
    }

    private func fetchStats(token: String, base: String, generation: Int) {
        guard get(base: base, token: token, path: "user") != nil else { return }
        let projects = get(base: base, token: token, path: "projects",
                           query: ["owned": "true", "per_page": "100"])
        let (repos, stars) = GitLab.parseStats(projects)
        DispatchQueue.main.async {
            guard self.tokenGeneration == generation else { return }
            AppState.shared.gitlabStats = GitHubStats(totalRepos: repos, totalStars: stars)
        }
    }

    // MARK: - Pulse

    /// Dispatches guards + state reads to main, then fires network on background.
    private func pollPulse() {
        guard !DemoEngine.isPollerPaused else { scheduleNextPulse(hasPending: false); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pulseInFlight else { return }
            guard let token = KeychainStore.shared.get("gitlab-token"),
                  let base = Self.baseURL,
                  Self.isWanted else {
                self.scheduleNextPulse(hasPending: false)
                return
            }
            self.pulseInFlight = true
            let gen = self.tokenGeneration
            DispatchQueue.global(qos: .background).async { self.fetchPulse(token: token, base: base, generation: gen) }
        }
    }

    private func fetchPulse(token: String, base: String, generation: Int) {
        guard let user = get(base: base, token: token, path: "user") as? [String: Any],
              let me = user["username"] as? String,
              // Without the first list there is nothing to show; the others may be empty.
              let mine = get(base: base, token: token, path: "merge_requests",
                             query: ["scope": "created_by_me", "state": "opened",
                                     "order_by": "updated_at", "per_page": "20"]) else {
            finishPulse(hasPending: false)
            return
        }
        let reviewer = get(base: base, token: token, path: "merge_requests",
                           query: ["scope": "all", "state": "opened",
                                   "reviewer_username": me, "per_page": "20"])
        let assigned = get(base: base, token: token, path: "merge_requests",
                           query: ["scope": "assigned_to_me", "state": "opened", "per_page": "20"])
        let projects = get(base: base, token: token, path: "projects",
                           query: ["owned": "true", "archived": "false",
                                   "order_by": "last_activity_at", "per_page": "10"])

        // The merge request list has no pipeline: one call per merge request
        // (and, below, one per project), a few at a time.
        let myItems = (mine as? [[String: Any]]) ?? []
        let details = Collector<String>()
        DispatchQueue.concurrentPerform(iterations: myItems.count) { i in
            guard let project = myItems[i]["project_id"] as? Int, let iid = myItems[i]["iid"] as? Int,
                  let detail = self.get(base: base, token: token,
                                        path: "projects/\(project)/merge_requests/\(iid)"),
                  let status = GitLab.headPipelineStatus(detail) else { return }
            details.set(i, status)
        }
        var statuses: [String: String] = [:]
        for (i, status) in details.all {
            if let key = GitLab.mrKey(myItems[i]) { statuses[key] = status }
        }

        let projectItems = (projects as? [[String: Any]]) ?? []
        let pipelines = Collector<[String: Any]>()
        DispatchQueue.concurrentPerform(iterations: projectItems.count) { i in
            guard let id = projectItems[i]["id"] as? Int,
                  let branch = projectItems[i]["default_branch"] as? String,
                  let list = self.get(base: base, token: token, path: "projects/\(id)/pipelines",
                                      query: ["ref": branch, "per_page": "1"]) as? [[String: Any]],
                  let latest = list.first else { return }
            pipelines.set(i, latest)
        }
        let latest = pipelines.all
        var mainCI: [GitHubRepoCI] = []
        for (i, project) in projectItems.enumerated() {
            if let repo = GitLab.parseRepoCI(project, latestPipeline: latest[i]) { mainCI.append(repo) }
        }

        let pulse = GitHubPulse(
            login: me,
            myPRs: GitLab.parseMyMRs(mine, ci: statuses),
            toReview: GitLab.parseToReview(reviewer: reviewer, assigned: assigned, me: me),
            mainCI: mainCI,
            fetchedAt: Date()
        )
        DispatchQueue.main.async {
            // Discard stale response if token or instance changed while the request was in flight
            guard self.tokenGeneration == generation else { return }
            let old = AppState.shared.gitlabPulse
            let events = GitHubPulse.events(old: old, new: pulse)
            AppState.shared.gitlabPulse = pulse
            if AppState.shared.activeIntegrations.contains(Self.pillId) {
                AppState.shared.handleGitHubEvents(events, pillId: Self.pillId)
            }
        }
        finishPulse(hasPending: pulse.hasPending)
    }

    /// Refreshes pulse data immediately if the last fetch is older than maxAge seconds (or absent).
    /// No-op when a request is already in flight. Safe to call from any thread.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pulseInFlight else { return }
            guard GitHubPulse.isStale(fetchedAt: AppState.shared.gitlabPulse?.fetchedAt,
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

    // MARK: - Activity (events per day, 30 min cadence)

    private func pollActivity() {
        guard !DemoEngine.isPollerPaused else { scheduleNextActivity(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.activityInFlight else { return }
            guard let token = KeychainStore.shared.get("gitlab-token"),
                  let base = Self.baseURL,
                  Self.isWanted else {
                self.scheduleNextActivity()
                return
            }
            self.activityInFlight = true
            let gen = self.tokenGeneration
            DispatchQueue.global(qos: .background).async { self.fetchActivity(token: token, base: base, generation: gen) }
        }
    }

    /// Pages of the user's events over the past year, up to 1000 events.
    private func fetchActivity(token: String, base: String, generation: Int) {
        let after = GitLab.eventsAfter(now: Date())
        var events: [[String: Any]] = []
        for page in 1...10 {
            guard let batch = get(base: base, token: token, path: "events",
                                  query: ["after": after, "per_page": "100", "page": "\(page)"]) as? [[String: Any]] else {
                if page == 1 { finishActivity(); return }
                break
            }
            events.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        let activity = GitLab.parseActivity(events: events, now: Date())
        DispatchQueue.main.async {
            guard self.tokenGeneration == generation else { return }
            AppState.shared.gitlabActivity = activity
        }
        finishActivity()
    }

    /// Refreshes activity data immediately if stale. Safe to call from any thread.
    func refreshActivityIfStale(maxAge: TimeInterval = 300) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.activityInFlight else { return }
            guard GitHubPulse.isStale(fetchedAt: AppState.shared.gitlabActivity?.fetchedAt,
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

    // MARK: - Credentials

    /// The GitLab token or instance URL was saved or removed: forget what the
    /// old one fetched, then fetch again right away.
    func credentialsChanged() {
        DispatchQueue.main.async {
            let state = AppState.shared
            state.gitlabPulse = nil
            state.gitlabActivity = nil
            state.gitlabStats = nil
            guard KeychainStore.shared.get("gitlab-token") != nil else {
                self.tokenGeneration += 1
                return
            }
            self.triggerPulseNow()
            self.pollStats()
            self.refreshActivityIfStale()
        }
    }
}
