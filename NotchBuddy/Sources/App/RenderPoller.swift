import Foundation

// MARK: - RenderPoller
// Polls Render every 30s — watch the notch Files list jump on each edit.
// Pattern mirrors VercelPoller: list services → latest deploy per service → notify notch.

final class RenderPoller: @unchecked Sendable {
    static let shared = RenderPoller()
    private var timer: DispatchSourceTimer?
    private var lastDeployKey: String = ""

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 6, repeating: 30)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.poll() }
    }

    // MARK: - Poll

    private func poll() {
        guard let token = KeychainStore.shared.get("render-api-key"), !token.isEmpty else { return }
        guard let url = URL(string: "https://api.render.com/v1/services?limit=20") else { return }

        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else { return }
            guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let services: [(id: String, name: String)] = list.compactMap { row in
                let svc = (row["service"] as? [String: Any]) ?? row
                guard let id = svc["id"] as? String,
                      let name = svc["name"] as? String else { return nil }
                return (id, name)
            }
            guard !services.isEmpty else { return }

            let filter: Set<String> = {
                if let d = UserDefaults.standard.data(forKey: "renderServiceFilter"),
                   let a = try? JSONDecoder().decode([String].self, from: d) {
                    return Set(a)
                }
                return []
            }()
            let selected = filter.isEmpty
                ? services
                : services.filter { filter.contains($0.name) }
            guard !selected.isEmpty else { return }

            self.fetchLatestDeploys(token: token, services: Array(selected.prefix(8)))
        }.resume()
    }

    private func fetchLatestDeploys(token: String, services: [(id: String, name: String)]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var collected: [RenderDeployment] = []

        for svc in services {
            group.enter()
            guard let url = URL(string: "https://api.render.com/v1/services/\(svc.id)/deploys?limit=1") else {
                group.leave(); continue
            }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: req) { data, response, _ in
                defer { group.leave() }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, code == 200,
                      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let first = list.first else { return }
                let deploy = (first["deploy"] as? [String: Any]) ?? first
                guard let parsed = self.parseDeploy(deploy, serviceId: svc.id, serviceName: svc.name) else { return }
                lock.lock(); collected.append(parsed); lock.unlock()
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let sorted = collected.sorted { $0.createdAt > $1.createdAt }
            Task { @MainActor in self.handleDeployments(sorted) }
        }
    }

    private func parseDeploy(_ d: [String: Any], serviceId: String, serviceName: String) -> RenderDeployment? {
        guard let id = d["id"] as? String,
              let status = d["status"] as? String else { return nil }

        let createdAt: Date = {
            if let s = d["createdAt"] as? String { return Self.parseISO(s) ?? Date() }
            return Date()
        }()

        let commit = d["commit"] as? [String: Any]
        let commitMessage = commit?["message"] as? String
        let commitId = commit?["id"] as? String
        let trigger = d["trigger"] as? String

        return RenderDeployment(
            id: id,
            serviceId: serviceId,
            serviceName: serviceName,
            status: status,
            createdAt: createdAt,
            commitMessage: commitMessage,
            commitId: commitId,
            trigger: trigger
        )
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    @MainActor
    private func handleDeployments(_ deployments: [RenderDeployment]) {
        let appState = AppState.shared
        appState.renderDeployments = deployments

        if let inProgress = deployments.first(where: { $0.isInProgress }) {
            guard let idx = appState.tasks.firstIndex(where: { $0.id == "integration_render" }) else { return }
            appState.tasks[idx].state = .working
            appState.tasks[idx].steps = [inProgress.serviceName]
            appState.tasks[idx].pillBadge = nil
            NotificationCenter.default.post(name: .hookReveal, object: nil)
            return
        }

        guard let latest = deployments.first(where: { $0.isTerminal }) else { return }
        let key = "\(latest.serviceId):\(latest.id):\(latest.status)"
        guard key != lastDeployKey else { return }
        lastDeployKey = key

        guard let idx = appState.tasks.firstIndex(where: { $0.id == "integration_render" }) else { return }
        let focused = appState.focusId == "integration_render"

        appState.tasks[idx].state = latest.isSuccess ? .finished : .error
        appState.tasks[idx].steps = [latest.serviceName]

        if !focused {
            appState.tasks[idx].pillBadge = latest.isSuccess ? .finished : .error
        }
        SoundEngine.shared.play(latest.isSuccess ? "finish" : "error")
        NotificationCenter.default.post(
            name: .triggerEmote,
            object: latest.isSuccess ? BotEmote.happy : BotEmote.annoyed
        )
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = appState.tasks.firstIndex(where: { $0.id == "integration_render" }) else { return }
            guard appState.tasks[i].state == .finished || appState.tasks[i].state == .error else { return }
            appState.tasks[i].state = .idle
            appState.tasks[i].steps = []
            appState.tasks[i].pillBadge = nil
        }
    }
}
