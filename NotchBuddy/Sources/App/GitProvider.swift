import Foundation

/// The git host a pulse card shows. The GitHub and GitLab cards are the same
/// views (GitHubPulseCardView, GitHubDetailView…) fed with the same types; what
/// differs is the name, the accent colour, the words for merge requests and
/// pipelines, which links may open and which poller refreshes the data.
/// `.github` is what every view used before GitLab existed: the default.
enum GitProvider: Sendable {
    case github, gitlab

    var name: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }

    var colorHex: String {
        switch self {
        case .github: return "#F4505E"
        case .gitlab: return "#FC6D26"
        }
    }

    /// "My PRs" / "My MRs".
    var myItemsLabel: String {
        switch self {
        case .github: return String(localized: "My PRs")
        case .gitlab: return String(localized: "My MRs")
        }
    }

    var mainCILabel: String {
        switch self {
        case .github: return "Default branch CI"
        case .gitlab: return String(localized: "Default branch pipelines")
        }
    }

    /// "repo#12" on GitHub, "repo!12" on GitLab.
    var refMark: String {
        switch self {
        case .github: return "#"
        case .gitlab: return "!"
        }
    }

    /// Only links that point at the provider's own host open: github.com, or the
    /// GitLab instance the user configured.
    func allows(_ url: URL) -> Bool {
        switch self {
        case .github: return url.host == "github.com"
        case .gitlab: return GitLabPoller.isOnInstance(url)
        }
    }

    /// Where a red default branch is explained.
    func pipelinesURL(_ repoURL: String) -> String {
        let base = repoURL.hasSuffix("/") ? String(repoURL.dropLast()) : repoURL
        switch self {
        case .github: return repoURL.hasSuffix("/") ? repoURL + "actions" : repoURL + "/actions"
        case .gitlab: return base + "/-/pipelines"
        }
    }

    func profileURL(_ login: String) -> String {
        switch self {
        case .github:
            return "https://github.com/\(login)"
        case .gitlab:
            let base = GitLabPoller.baseURL ?? GitLab.defaultBaseURL
            return "\(base)/\(login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? login)"
        }
    }

    func refreshPulse() {
        switch self {
        case .github: GithubPoller.shared.refreshIfStale()
        case .gitlab: GitLabPoller.shared.refreshIfStale()
        }
    }

    func refreshActivity() {
        switch self {
        case .github: GithubPoller.shared.refreshActivityIfStale()
        case .gitlab: GitLabPoller.shared.refreshActivityIfStale()
        }
    }
}
