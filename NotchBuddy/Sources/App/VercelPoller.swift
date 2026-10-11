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
        guard !DemoEngine.isPollerPaused else { return }
        guard let token = KeychainStore.shared.get("vercel-token") else { return }

        // Fetch last 5 terminal deployments
        guard let url = URL(string: "https://api.vercel.com/v6/deployments?limit=5") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawList = json["deployments"] as? [[String: Any]] else { return }

            // Only terminal deployments (READY, ERROR, CANCELED)
            let terminal = ["READY", "ERROR", "CANCELED"]
            let parsed = rawList
                .compactMap { self.parseDeployment($0) }
                .filter { terminal.contains($0.state) }
            guard !parsed.isEmpty else { return }

            DispatchQueue.main.async { self.handleDeployments(parsed) }
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
