import Foundation

// MARK: - VercelPoller
// Polls Vercel API for latest deployments every 30s.
// On new terminal deployment: updates integration_vercel task state + AppState.vercelDeployments.

final class VercelPoller: @unchecked Sendable {
    static let shared = VercelPoller()
    private var timer: DispatchSourceTimer?
    private var lastDeploymentId: String = ""

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 5, repeating: 30)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    // MARK: - Poll

    private func poll() {
        guard let token = KeychainStore.shared.get("vercel-token") else { return }
        Self.fetchJSON(token: token, url: URL(string: "https://api.vercel.com/v2/teams")) { json in
            let teamIds = (json?["teams"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
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

    /// Canceled builds are replaced by a newer one. They are not the project's result.
    private static let shownStates = ["READY", "ERROR"]

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
        appState.vercelDeployments = deployments

        // Apply project filter (empty = all projects)
        let filter = appState.vercelProjectFilter
        let filtered = filter.isEmpty ? deployments : deployments.filter { filter.contains($0.projectName) }
        guard let latest = filtered.first else { return }
        guard latest.id != lastDeploymentId else { return }
        lastDeploymentId = latest.id

        guard let idx = appState.tasks.firstIndex(where: { $0.id == "integration_vercel" }) else { return }
        let focused = appState.focusId == "integration_vercel"

        appState.tasks[idx].state = latest.isSuccess ? .finished : .error
        appState.tasks[idx].steps = [latest.projectName]

        if !focused {
            appState.tasks[idx].pillBadge = latest.isSuccess ? .finished : .error
        }
        SoundEngine.shared.play(latest.isSuccess ? "finish" : "error")

        // Reveal compact island so user sees the badge
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        // Auto-clear task state after 60s (deployments list stays)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = appState.tasks.firstIndex(where: { $0.id == "integration_vercel" }) else { return }
            guard appState.tasks[i].state == .finished || appState.tasks[i].state == .error else { return }
            appState.tasks[i].state = .idle
            appState.tasks[i].steps = []
            appState.tasks[i].pillBadge = nil
        }
    }
}
