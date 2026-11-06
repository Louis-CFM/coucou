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
    var headSha: String? = nil   // oid of last commit; nil if not fetched
    var headRef: String? = nil   // head branch name; ties the session's branch to its PR
    var reviews: [GitHubReview] = []   // latest review of each reviewer
}

// MARK: - GitHubReview

struct GitHubReview: Equatable {
    var id: String
    var state: String    // APPROVED, CHANGES_REQUESTED, COMMENTED, …
    var author: String
}

// MARK: - GitHubRepoCI

struct GitHubRepoCI: Equatable {
    var repo: String
    var url: String
    var branch: String
    var ci: CIState
    var headSha: String? = nil   // oid of HEAD commit; nil if not fetched
    var link: String? = nil      // the session branch's failing job or commit page

    /// Where a tap goes: `link` when set, the repo's Actions page otherwise.
    var openURL: String {
        if let link, !link.isEmpty { return link }
        return url.hasSuffix("/") ? url + "actions" : url + "/actions"
    }
}

// MARK: - GitHubDetailSection

enum GitHubDetailSection { case myPRs, toReview, mainCI, activity }

// MARK: - GitHubEvent

enum GitHubEvent: Equatable {
    case ciFailed(prId: String)
    case ciPassed(prId: String)
    case mainFailed(repo: String)
    case reviewRequested(prId: String)
    // The branch of the last Claude Code session (GitHubBranchCI)
    case branchCIPassed(repo: String, branch: String)
    case branchCIFailed(repo: String, branch: String)
    // A new review on one of your PRs, by someone else
    case reviewApproved(prId: String)
    case changesRequested(prId: String)
    case reviewCommented(prId: String)
}

// MARK: - GitHubPulse

struct GitHubPulse: Equatable {
    var login: String
    var myPRs: [GitHubPR]
    var toReview: [GitHubPR]
    var mainCI: [GitHubRepoCI]
    var fetchedAt: Date
    /// CI of the branch checked out by the last Claude Code session; nil when
    /// there is none, or its repository isn't on GitHub or visible to the token.
    var branch: GitHubBranchCI? = nil

    /// Pull requests nobody has touched in a month are abandoned, not "on the go".
    static let staleAfter: TimeInterval = 30 * 86_400

    /// True when at least one PR CI, default-branch CI or the session branch's CI
    /// is pending — triggers 60 s poll cadence.
    var hasPending: Bool {
        myPRs.contains { $0.ci == .pending } ||
        mainCI.contains { $0.ci == .pending } ||
        branch?.ci == .pending
    }

    // MARK: - Parse

    /// `target` is the session's branch the query asked about (`sessionBranch`).
    static func parse(_ data: Data, target: GitHubBranchRef? = nil, now: Date = Date()) -> GitHubPulse? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let viewer = dataNode["viewer"] as? [String: Any] else { return nil }

        let login = viewer["login"] as? String ?? ""

        // My PRs
        var myPRs: [GitHubPR] = []
        if let prConn = viewer["pullRequests"] as? [String: Any],
           let nodes = prConn["nodes"] as? [[String: Any]] {
            var seenPR = Set<String>()
            let iso = ISO8601DateFormatter()
            for node in nodes {
                guard let number = node["number"] as? Int,
                      let title  = node["title"]  as? String,
                      let url    = node["url"]     as? String,
                      let repoNode = node["repository"] as? [String: Any],
                      let repo  = repoNode["nameWithOwner"] as? String else { continue }
                // Bots opening PRs under your name leave plenty of abandoned ones.
                // A new review bumps updatedAt, so one coming back to life reappears.
                if let updated = (node["updatedAt"] as? String).flatMap(iso.date(from:)),
                   now.timeIntervalSince(updated) > staleAfter { continue }
                let id = "\(repo)#\(number)"
                guard seenPR.insert(id).inserted else { continue }   // skip duplicates
                let isDraft = node["isDraft"] as? Bool ?? false
                let reviewDecision = node["reviewDecision"] as? String
                let (ciRaw, headSha): (String?, String?) = {
                    guard let commits = node["commits"] as? [String: Any],
                          let cNodes = commits["nodes"] as? [[String: Any]],
                          let last = cNodes.last,
                          let commit = last["commit"] as? [String: Any] else { return (nil, nil) }
                    let rollup = commit["statusCheckRollup"] as? [String: Any]
                    return (rollup?["state"] as? String, commit["oid"] as? String)
                }()
                let reviewNodes = (node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
                let reviews = reviewNodes.map { r in
                    GitHubReview(id: r["id"] as? String ?? "",
                                 state: r["state"] as? String ?? "",
                                 author: (r["author"] as? [String: Any])?["login"] as? String ?? "")
                }
                myPRs.append(GitHubPR(
                    id: id, title: title, url: url, repo: repo, number: number,
                    isDraft: isDraft, ci: CIState(rawGitHub: ciRaw),
                    review: ReviewState(rawGitHub: reviewDecision), headSha: headSha,
                    headRef: node["headRefName"] as? String, reviews: reviews
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
                let (ciRaw, headSha): (String?, String?) = {
                    guard let target = branchRef["target"] as? [String: Any] else { return (nil, nil) }
                    let rollup = target["statusCheckRollup"] as? [String: Any]
                    return (rollup?["state"] as? String, target["oid"] as? String)
                }()
                mainCI.append(GitHubRepoCI(repo: repo, url: url, branch: branch,
                                           ci: CIState(rawGitHub: ciRaw), headSha: headSha))
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

        let branch = target.flatMap {
            GitHubBranchCI.parse(dataNode["sessionBranch"], target: $0, myPRs: myPRs)
        }

        return GitHubPulse(login: login, myPRs: myPRs, toReview: toReview,
                           mainCI: mainCI, fetchedAt: now, branch: branch)
    }

    // MARK: - Events

    /// Returns events comparing old → new. If old is nil (first poll after launch) returns empty — no
    /// alerts on initial load, only on subsequent changes.
    ///
    /// headSha logic (catches fast CIs missed between polls):
    /// - Same SHA (or both nil): classic transition rules apply.
    /// - Different SHA or PR/repo absent in old: fire immediately if CI is already done.
    ///   If still pending, nothing — next poll with the same SHA will catch the result.
    /// - Main CI: no "green" alert, only .mainFailed on new failure.
    static func events(old: GitHubPulse?, new: GitHubPulse) -> [GitHubEvent] {
        guard let old else { return [] }

        var result: [GitHubEvent] = []

        // PR CI transitions
        let oldPRmap = Dictionary(old.myPRs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for pr in new.myPRs {
            if let prev = oldPRmap[pr.id], prev.headSha == pr.headSha {
                // Same commit: classic state-transition rules
                if pr.ci == .failure && prev.ci != .failure {
                    result.append(.ciFailed(prId: pr.id))
                } else if pr.ci == .success && prev.ci == .pending {
                    result.append(.ciPassed(prId: pr.id))
                }
            } else {
                // New PR or new commit: alert if CI already finished
                if pr.ci == .success  { result.append(.ciPassed(prId: pr.id)) }
                else if pr.ci == .failure { result.append(.ciFailed(prId: pr.id)) }
                // pending → nothing; same-SHA rule catches it next poll
            }
        }

        // Default-branch CI
        let oldRepoMap = Dictionary(old.mainCI.map { ($0.repo, $0) }, uniquingKeysWith: { a, _ in a })
        for repo in new.mainCI {
            if let prev = oldRepoMap[repo.repo], prev.headSha == repo.headSha {
                // Same commit: classic rule (failure transition only)
                if repo.ci == .failure && prev.ci != .failure {
                    result.append(.mainFailed(repo: repo.repo))
                }
            } else {
                // New repo or new commit: only alert on failure (no "green" event for main)
                if repo.ci == .failure { result.append(.mainFailed(repo: repo.repo)) }
            }
        }

        // New review requests
        let oldReviewIds = Set(old.toReview.map { $0.id })
        for pr in new.toReview {
            if !oldReviewIds.contains(pr.id) {
                result.append(.reviewRequested(prId: pr.id))
            }
        }

        // The session's branch: same headSha logic as PRs, on the same repo and
        // branch only. Switching to another branch or repo says nothing — that's
        // old news, not something that just happened.
        if let b = new.branch, b.pushed, let prev = old.branch,
           prev.repo == b.repo, prev.branch == b.branch {
            let finished: CIState? = prev.oid == b.oid
                ? (prev.ci == .pending && b.ci != .pending ? b.ci : nil)
                : b.ci
            switch finished {
            case .success: result.append(.branchCIPassed(repo: b.repo, branch: b.branch))
            case .failure: result.append(.branchCIFailed(repo: b.repo, branch: b.branch))
            default:       break   // still running: the next poll catches it
            }
        }

        // New reviews on your PRs, by anyone but you. Only on PRs already seen,
        // so a PR coming back into the list doesn't replay its old reviews.
        let oldReviewsSeen = Set(old.myPRs.flatMap { $0.reviews.map(\.id) })
        for pr in new.myPRs where oldPRmap[pr.id] != nil {
            for r in pr.reviews where !r.id.isEmpty && r.author != new.login && !oldReviewsSeen.contains(r.id) {
                switch r.state {
                case "APPROVED":          result.append(.reviewApproved(prId: pr.id))
                case "CHANGES_REQUESTED": result.append(.changesRequested(prId: pr.id))
                case "COMMENTED":         result.append(.reviewCommented(prId: pr.id))
                default:                  break
                }
            }
        }

        return result
    }

    // MARK: - Staleness

    /// Pure predicate: true when fetchedAt is nil or older than maxAge seconds before now.
    static func isStale(fetchedAt: Date?, now: Date = Date(), maxAge: TimeInterval) -> Bool {
        guard let t = fetchedAt else { return true }
        return now.timeIntervalSince(t) > maxAge
    }
}
