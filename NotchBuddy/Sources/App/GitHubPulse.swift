import Foundation

// MARK: - CIState

enum CIState: String, Equatable {
    case pending, success, failure, unknown

    init(rawGitHub: String?) {
        guard let s = rawGitHub else { self = .unknown; return }
        switch s.uppercased() {
        case "PENDING", "EXPECTED": self = .pending
        case "SUCCESS":             self = .success
        case "ERROR", "FAILURE":    self = .failure
        default:                    self = .unknown
        }
    }
}

// MARK: - ReviewState

enum ReviewState: String, Equatable {
    case approved, changesRequested, pending, unknown

    init(rawGitHub: String?) {
        guard let s = rawGitHub else { self = .unknown; return }
        switch s.uppercased() {
        case "APPROVED":           self = .approved
        case "CHANGES_REQUESTED":  self = .changesRequested
        case "REVIEW_REQUIRED":    self = .pending
        default:                   self = .unknown
        }
    }
}

// MARK: - GitHubPR

struct GitHubPR: Equatable {
    var id: String      // "owner/repo#num"
    var title: String
    var url: String
    var repo: String
    var number: Int
    var isDraft: Bool
    var ci: CIState
    var review: ReviewState
}

// MARK: - GitHubRepoCI

struct GitHubRepoCI: Equatable {
    var repo: String
    var url: String
    var branch: String
    var ci: CIState
}

// MARK: - GitHubDetailSection

enum GitHubDetailSection { case myPRs, toReview, mainCI }

// MARK: - GitHubEvent

enum GitHubEvent: Equatable {
    case ciFailed(prId: String)
    case ciPassed(prId: String)
    case mainFailed(repo: String)
    case reviewRequested(prId: String)
}

// MARK: - GitHubPulse

struct GitHubPulse: Equatable {
    var login: String
    var myPRs: [GitHubPR]
    var toReview: [GitHubPR]
    var mainCI: [GitHubRepoCI]
    var fetchedAt: Date

    /// True when at least one PR CI or default-branch CI is pending — triggers 60 s poll cadence.
    var hasPending: Bool {
        myPRs.contains { $0.ci == .pending } ||
        mainCI.contains { $0.ci == .pending }
    }

    // MARK: - Parse

    static func parse(_ data: Data) -> GitHubPulse? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let viewer = dataNode["viewer"] as? [String: Any] else { return nil }

        let login = viewer["login"] as? String ?? ""

        // My PRs
        var myPRs: [GitHubPR] = []
        if let prConn = viewer["pullRequests"] as? [String: Any],
           let nodes = prConn["nodes"] as? [[String: Any]] {
            var seenPR = Set<String>()
            for node in nodes {
                guard let number = node["number"] as? Int,
                      let title  = node["title"]  as? String,
                      let url    = node["url"]     as? String,
                      let repoNode = node["repository"] as? [String: Any],
                      let repo  = repoNode["nameWithOwner"] as? String else { continue }
                let id = "\(repo)#\(number)"
                guard seenPR.insert(id).inserted else { continue }   // skip duplicates
                let isDraft = node["isDraft"] as? Bool ?? false
                let reviewDecision = node["reviewDecision"] as? String
                let ciRaw: String? = {
                    guard let commits = node["commits"] as? [String: Any],
                          let cNodes = commits["nodes"] as? [[String: Any]],
                          let last = cNodes.last,
                          let commit = last["commit"] as? [String: Any],
                          let rollup = commit["statusCheckRollup"] as? [String: Any] else { return nil }
                    return rollup["state"] as? String
                }()
                myPRs.append(GitHubPR(
                    id: id,
                    title: title,
                    url: url,
                    repo: repo,
                    number: number,
                    isDraft: isDraft,
                    ci: CIState(rawGitHub: ciRaw),
                    review: ReviewState(rawGitHub: reviewDecision)
                ))
            }
        }

        // Main CI for recently-pushed repos (client-side filter: skip archived)
        var mainCI: [GitHubRepoCI] = []
        if let repoConn = viewer["repositories"] as? [String: Any],
           let nodes = repoConn["nodes"] as? [[String: Any]] {
            for node in nodes {
                let isArchived = node["isArchived"] as? Bool ?? false
                if isArchived { continue }
                guard let repo     = node["nameWithOwner"] as? String,
                      let url      = node["url"] as? String,
                      let branchRef = node["defaultBranchRef"] as? [String: Any],
                      let branch   = branchRef["name"] as? String else { continue }
                let ciRaw: String? = {
                    guard let target = branchRef["target"] as? [String: Any],
                          let rollup = target["statusCheckRollup"] as? [String: Any] else { return nil }
                    return rollup["state"] as? String
                }()
                mainCI.append(GitHubRepoCI(repo: repo, url: url, branch: branch,
                                           ci: CIState(rawGitHub: ciRaw)))
            }
        }

        // To review
        var toReview: [GitHubPR] = []
        if let searchResult = dataNode["reviewRequested"] as? [String: Any],
           let nodes = searchResult["nodes"] as? [[String: Any]] {
            var seenReview = Set<String>()
            for node in nodes {
                guard let number   = node["number"] as? Int,
                      let title    = node["title"]  as? String,
                      let url      = node["url"]    as? String,
                      let repoNode = node["repository"] as? [String: Any],
                      let repo     = repoNode["nameWithOwner"] as? String else { continue }
                let id = "\(repo)#\(number)"
                guard seenReview.insert(id).inserted else { continue }   // skip duplicates
                let isDraft = node["isDraft"] as? Bool ?? false
                toReview.append(GitHubPR(
                    id: id,
                    title: title,
                    url: url,
                    repo: repo,
                    number: number,
                    isDraft: isDraft,
                    ci: .unknown,
                    review: .pending
                ))
            }
        }

        return GitHubPulse(login: login, myPRs: myPRs, toReview: toReview,
                           mainCI: mainCI, fetchedAt: Date())
    }

    // MARK: - Events

    /// Returns events comparing old → new. If old is nil (first poll after launch) returns empty — no
    /// alerts on initial load, only on subsequent changes.
    static func events(old: GitHubPulse?, new: GitHubPulse) -> [GitHubEvent] {
        guard let old else { return [] }

        var result: [GitHubEvent] = []

        // PR CI transitions
        let oldPRmap = Dictionary(old.myPRs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for pr in new.myPRs {
            guard let prev = oldPRmap[pr.id] else { continue }
            if pr.ci == .failure && prev.ci != .failure {
                result.append(.ciFailed(prId: pr.id))
            } else if pr.ci == .success && prev.ci == .pending {
                result.append(.ciPassed(prId: pr.id))
            }
        }

        // Default-branch CI failures
        let oldRepoMap = Dictionary(old.mainCI.map { ($0.repo, $0) }, uniquingKeysWith: { a, _ in a })
        for repo in new.mainCI {
            guard let prev = oldRepoMap[repo.repo] else { continue }
            if repo.ci == .failure && prev.ci != .failure {
                result.append(.mainFailed(repo: repo.repo))
            }
        }

        // New review requests
        let oldReviewIds = Set(old.toReview.map { $0.id })
        for pr in new.toReview {
            if !oldReviewIds.contains(pr.id) {
                result.append(.reviewRequested(prId: pr.id))
            }
        }

        return result
    }
}
