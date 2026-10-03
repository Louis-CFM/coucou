import Foundation

// MARK: - GithubPullRequestsPoller
// Polls the GitHub search API every 2 minutes for the open pull requests that wait for the
// user: review requested, or assigned. Fills AppState.githubPullRequests; a new review
// request after the first load puts a badge on the integration_github_prs pill, plays a
// sound and reveals the island (same dance as VercelPoller).
//
// Token: "github-prs-token" in the Keychain; falls back to the GitHub pill's "github-token"
// so one token can serve both pills. Nothing is polled without a token.

final class GithubPullRequestsPoller: @unchecked Sendable {
    static let shared = GithubPullRequestsPoller()
    static let pillId = "integration_github_prs"
    static let keychainKey = "github-prs-token"

    private var timer: DispatchSourceTimer?
    /// Review-request ids seen so far; filled silently on the first load.
    private var knownReviewIds: Set<String> = []
    private var hasLoaded = false

    private init() {}

    /// The token that backs the pill: its own, or the GitHub pill's one.
    static func token() -> String? {
        KeychainStore.shared.get(keychainKey) ?? KeychainStore.shared.get("github-token")
    }

    static var isConfigured: Bool { token() != nil }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 8, repeating: 120)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func pollNow() { poll() }

    // MARK: - Poll

    /// Collects the per-reason results of one poll; shared by the request callbacks.
    private final class PollResults: @unchecked Sendable {
        private let lock = NSLock()
        private var lists: [[GitHubPullRequest]] = []
        private var firstError: String?

        func add(_ list: [GitHubPullRequest]) { lock.withLock { lists.append(list) } }
        func fail(_ message: String) { lock.withLock { if firstError == nil { firstError = message } } }
        var outcome: (lists: [[GitHubPullRequest]], error: String?) { lock.withLock { (lists, firstError) } }
    }

    private func poll() {
        guard let token = Self.token() else { return }

        let group = DispatchGroup()
        let results = PollResults()

        for reason in GitHubPullRequest.Reason.allCases {
            guard let url = GithubPullRequests.searchURL(for: reason) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

            group.enter()
            URLSession.shared.dataTask(with: req) { data, response, error in
                defer { group.leave() }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, code == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    results.fail(GithubPullRequests.errorMessage(status: code, transport: error?.localizedDescription))
                    return
                }
                results.add(GithubPullRequests.parse(payload: json, reason: reason))
            }.resume()
        }

        group.notify(queue: .global(qos: .background)) { [weak self] in
            guard let self else { return }
            let (lists, error) = results.outcome
            let merged = GithubPullRequests.merge(lists)
            DispatchQueue.main.async {
                if let error {
                    AppState.shared.githubPRsError = error
                    return
                }
                self.handle(merged)
            }
        }
    }

    @MainActor
    private func handle(_ prs: [GitHubPullRequest]) {
        let appState = AppState.shared
        appState.githubPullRequests = prs
        appState.githubPRsError = nil
        appState.githubPRsLoaded = true

        let reviewIds = Set(prs.filter { $0.needsReview }.map { $0.id })
        let fresh = reviewIds.subtracting(knownReviewIds)
        knownReviewIds = reviewIds

        // First load only fills the card; later loads announce new review requests.
        guard hasLoaded else { hasLoaded = true; return }
        guard !fresh.isEmpty else { return }

        let pillId = Self.pillId
        guard let idx = appState.tasks.firstIndex(where: { $0.id == pillId }) else { return }
        if appState.focusId != pillId {
            appState.tasks[idx].pillBadge = .approval
        }
        SoundEngine.shared.play("pop")
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        // Badge fades after 60 s (the list stays).
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = appState.tasks.firstIndex(where: { $0.id == pillId }) else { return }
            guard appState.tasks[i].pillBadge == .approval else { return }
            appState.tasks[i].pillBadge = nil
        }
    }
}
