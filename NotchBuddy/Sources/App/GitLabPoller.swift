import Foundation

/// Fetches the user's GitLab merge requests for the GitLab pill: every 5 minutes, every
/// minute while a pipeline runs, and only while the pill is in the notch.
@MainActor
final class GitLabPoller {
    static let shared = GitLabPoller()
    private var loop: Task<Void, Never>?
    private var inFlight = false
    private var generation = 0
    private init() {}

    /// Instance URL from Settings (gitlab.com when empty); nil when it isn't https.
    static var baseURL: URL? { GitLabPulse.baseURL(from: KeychainStore.shared.get("gitlab-url")) }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            while !Task.isCancelled {
                let pending = await self?.poll() ?? false
                try? await Task.sleep(for: .seconds(pending ? 60 : 300))
            }
        }
    }

    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !inFlight,
              GitHubPulse.isStale(fetchedAt: AppState.shared.gitlabPulse?.fetchedAt, maxAge: maxAge) else { return }
        Task { await poll() }
    }

    /// After the token or URL changed: drop answers still in flight and fetch now.
    func restart() {
        generation += 1
        inFlight = false
        AppState.shared.gitlabPulse = nil
        AppState.shared.gitlabError = nil
        Task { await poll() }
    }

    /// Returns true while a pipeline is still running.
    @discardableResult
    private func poll() async -> Bool {
        let state = AppState.shared
        guard !inFlight, state.activeIntegrations.contains("integration_gitlab"),
              let token = KeychainStore.shared.get("gitlab-token") else { return false }
        guard let base = Self.baseURL else {
            state.gitlabError = "Instance URL must start with https://"
            return false
        }
        inFlight = true
        defer { inFlight = false }
        let gen = generation

        var req = URLRequest(url: base.appendingPathComponent("api/graphql"), timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["query": GitLabPulse.graphQLQuery])

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: req)
        } catch {
            guard gen == generation else { return false }
            appendAppLog("gitlab.log", "request failed: \(error.localizedDescription)")
            state.gitlabError = "Can't reach \(base.host ?? "GitLab")"
            return false
        }
        guard gen == generation else { return false }
        let code = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let pulse = GitLabPulse.parse(result.0) else {
            appendAppLog("gitlab.log", "pulse HTTP \(code)")
            state.gitlabError = code == 401 ? "Token rejected" : "GitLab error (HTTP \(code))"
            return false
        }
        let events = GitHubPulse.events(old: state.gitlabPulse, new: pulse)
        state.gitlabPulse = pulse
        state.gitlabError = nil
        state.handleGitHubEvents(events, pillId: "integration_gitlab")
        return pulse.hasPending
    }
}
