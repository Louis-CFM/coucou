import Foundation

// MARK: - VercelPoller
// Polls Vercel often enough that a new deploy shows up within a few seconds.
// A new Ready or Failed deploy opens the island on that project.

final class VercelPoller: @unchecked Sendable {
    static let shared = VercelPoller()
    private var timer: DispatchSourceTimer?
    private var isLivePoll = false
    private var didBaseline = false
    private var seenStates: [String: String] = [:]
    private var noticeGeneration = 0
    private var cachedTeamIds: [String] = []
    private var teamsFetchedAt = Date.distantPast

    private init() {}

    func start() {
        guard timer == nil else { return }
        armTimer(live: false, firstDelay: 2)
    }

    /// Quiet poll is 8s. While a build is running, 4s, so Ready/Failed lands quickly.
    private func armTimer(live: Bool, firstDelay: TimeInterval? = nil) {
        guard timer == nil || live != isLivePoll else { return }
        isLivePoll = live
        timer?.cancel()
        let interval: TimeInterval = live ? 4 : 8
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + (firstDelay ?? interval), repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    /// Newest Ready or Failed deploy whose state just changed. Failures win over successes.
    static func freshResult(among current: [VercelDeployment], seen: [String: String], hasBaseline: Bool) -> VercelDeployment? {
        guard hasBaseline else { return nil }
        var failed: VercelDeployment?
        var ready: VercelDeployment?
        for item in current where seen[item.id] != item.state {
            if item.state == "ERROR", failed == nil { failed = item }
            if item.state == "READY", ready == nil { ready = item }
        }
        return failed ?? ready
    }

    // MARK: - Poll

    private func poll() {
        guard let token = KeychainStore.shared.get("vercel-token") else { return }
        if !cachedTeamIds.isEmpty, Date().timeIntervalSince(teamsFetchedAt) < 600 {
            fetchDeployments(token: token, teamIds: cachedTeamIds)
            return
        }
        Self.fetchJSON(token: token, url: URL(string: "https://api.vercel.com/v2/teams")) { json in
            let teamIds = (json?["teams"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            self.cachedTeamIds = teamIds
            self.teamsFetchedAt = Date()
            self.fetchDeployments(token: token, teamIds: teamIds)
        }
    }

    /// Personal account plus every team. The personal list hides team projects.
    private func fetchDeployments(token: String, teamIds: [String]) {
        let scopes: [String?] = [nil] + teamIds.map { Optional($0) }
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [VercelDeployment] = []

        for teamId in scopes {
            group.enter()
            guard let url = Self.deploymentsURL(teamId: teamId) else { group.leave(); continue }
            Self.fetchJSON(token: token, url: url) { json in
                let raw = json?["deployments"] as? [[String: Any]] ?? []
                let parsed = raw.compactMap { self.parseDeployment($0) }.filter { Self.shownStates.contains($0.state) }
                lock.lock()
                collected.append(contentsOf: parsed)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            let latest = Self.latestPerProject(collected)
            guard !latest.isEmpty else { return }
            Task { @MainActor in self?.handleDeployments(latest) }
        }
    }

    /// Canceled builds are replaced by a newer one. In-progress builds stay so the dot can move.
    private static let shownStates = ["READY", "ERROR", "BUILDING", "QUEUED", "INITIALIZING"]

    private static func deploymentsURL(teamId: String?) -> URL? {
        var parts = URLComponents(string: "https://api.vercel.com/v6/deployments")
        var items = [URLQueryItem(name: "limit", value: "20")]
        if let teamId { items.append(URLQueryItem(name: "teamId", value: teamId)) }
        parts?.queryItems = items
        return parts?.url
    }

    /// One row per project, newest first, so a busy project cannot hide the others.
    private static func latestPerProject(_ items: [VercelDeployment]) -> [VercelDeployment] {
        var newest: [String: VercelDeployment] = [:]
        for item in items {
            if let current = newest[item.projectName], current.createdAt >= item.createdAt { continue }
            newest[item.projectName] = item
        }
        return newest.values.sorted { $0.createdAt > $1.createdAt }
    }

    static func fetchProjectNames(token: String, completion: @escaping ([String]) -> Void) {
        fetchJSON(token: token, url: URL(string: "https://api.vercel.com/v2/teams")) { json in
            let teamIds = (json?["teams"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            let scopes: [String?] = [nil] + teamIds.map { Optional($0) }
            let group = DispatchGroup()
            let lock = NSLock()
            var names = Set<String>()
            for teamId in scopes {
                group.enter()
                var parts = URLComponents(string: "https://api.vercel.com/v9/projects")
                var items = [URLQueryItem(name: "limit", value: "100")]
                if let teamId { items.append(URLQueryItem(name: "teamId", value: teamId)) }
                parts?.queryItems = items
                fetchJSON(token: token, url: parts?.url) { json in
                    let found = (json?["projects"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                    lock.lock()
                    names.formUnion(found)
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: .main) { completion(names.sorted()) }
        }
    }

    private static func fetchJSON(token: String, url: URL?, completion: @escaping ([String: Any]?) -> Void) {
        guard let url else { completion(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(json)
        }.resume()
    }

    private func parseDeployment(_ d: [String: Any]) -> VercelDeployment? {
        guard let uid   = d["uid"]   as? String,
              let name  = d["name"]  as? String,
              let state = d["state"] as? String else { return nil }

        let url = (d["url"] as? String) ?? ""
        let createdAtMs = (d["createdAt"] as? Double) ?? 0
        let createdAt = Date(timeIntervalSince1970: createdAtMs / 1000)

        let meta = d["meta"] as? [String: Any]
        let commitMessage = meta?["githubCommitMessage"] as? String
                         ?? meta?["gitlabCommitMessage"] as? String
                         ?? meta?["bitbucketCommitMessage"] as? String
        let branch = meta?["githubCommitRef"] as? String
                  ?? meta?["gitlabCommitRef"] as? String
                  ?? meta?["bitbucketBranch"] as? String

        return VercelDeployment(id: uid, projectName: name, url: url, state: state,
                                 createdAt: createdAt, commitMessage: commitMessage, branch: branch)
    }

    @MainActor
    private func handleDeployments(_ deployments: [VercelDeployment]) {
        let appState = AppState.shared
        let filter = appState.vercelProjectFilter
        let visible = filter.isEmpty ? deployments : deployments.filter { filter.contains($0.projectName) }
        guard !visible.isEmpty else { return }
        let hot = Self.freshResult(among: visible, seen: seenStates, hasBaseline: didBaseline)
        didBaseline = true
        var nextSeen: [String: String] = [:]
        for item in visible { nextSeen[item.id] = item.state }
        seenStates = nextSeen
        armTimer(live: visible.contains(where: \.isInProgress))

        var shown = visible
        if let hot {
            shown.removeAll { $0.id == hot.id }
            shown.insert(hot, at: 0)
        }
        appState.vercelDeployments = shown
        guard let idx = appState.tasks.firstIndex(where: { $0.id == "integration_vercel" }) else { return }

        if let hot {
            show(hot, on: appState)
        } else if let building = visible.first(where: \.isInProgress) {
            markBuilding(building, on: appState, taskIndex: idx)
        } else if appState.tasks[idx].state == .working {
            appState.tasks[idx].state = .idle
            appState.tasks[idx].steps = []
        }
    }

    @MainActor
    private func markBuilding(_ deployment: VercelDeployment, on appState: AppState, taskIndex: Int) {
        guard appState.tasks[taskIndex].state != .working else { return }
        appState.tasks[taskIndex].state = .working
        appState.tasks[taskIndex].steps = [deployment.projectName]
    }

    @MainActor
    private func show(_ deployment: VercelDeployment, on appState: AppState) {
        let failed = deployment.state == "ERROR"
        appState.presentNotice(
            pillId: "integration_vercel",
            status: CoucouL10n.string(failed ? "Deploy failed" : "Deploy ready"),
            headline: deployment.projectName,
            detail: deployment.commitMessage ?? "",
            isFailure: failed
        )
        scheduleIdleReset()
    }

    @MainActor
    private func scheduleIdleReset() {
        noticeGeneration += 1
        let generation = noticeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard self.noticeGeneration == generation else { return }
            let state = AppState.shared
            guard let index = state.tasks.firstIndex(where: { $0.id == "integration_vercel" }) else { return }
            guard state.tasks[index].state == .finished || state.tasks[index].state == .error else { return }
            state.tasks[index].state = .idle
            state.tasks[index].steps = []
            state.tasks[index].pillBadge = nil
        }
    }
}
