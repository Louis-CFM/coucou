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
    var headRef: String? = nil   // head branch name; nil if not fetched
}

// MARK: - GitHubRepoCI

struct GitHubRepoCI: Equatable {
    var repo: String
    var url: String
    var branch: String
    var ci: CIState
    var headSha: String? = nil   // oid of HEAD commit; nil if not fetched
}

// MARK: - GitHubDetailSection

enum GitHubDetailSection { case myPRs, toReview, mainCI, activity }

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

    /// Keeps only PRs and default-branch CI from the given repos (nameWithOwner). Empty set = unchanged.
    func filtered(toRepos repos: Set<String>) -> GitHubPulse {
        guard !repos.isEmpty else { return self }
        var copy = self
        copy.myPRs    = myPRs.filter    { repos.contains($0.repo) }
        copy.toReview = toReview.filter { repos.contains($0.repo) }
        copy.mainCI   = mainCI.filter   { repos.contains($0.repo) }
        return copy
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
                let (ciRaw, headSha): (String?, String?) = {
                    guard let commits = node["commits"] as? [String: Any],
                          let cNodes = commits["nodes"] as? [[String: Any]],
                          let last = cNodes.last,
                          let commit = last["commit"] as? [String: Any] else { return (nil, nil) }
                    let rollup = commit["statusCheckRollup"] as? [String: Any]
                    return (rollup?["state"] as? String, commit["oid"] as? String)
                }()
                myPRs.append(GitHubPR(
                    id: id, title: title, url: url, repo: repo, number: number,
                    isDraft: isDraft, ci: CIState(rawGitHub: ciRaw),
                    review: ReviewState(rawGitHub: reviewDecision), headSha: headSha,
                    headRef: node["headRefName"] as? String
                ))
            }
        }

        // Main CI: recently-pushed repos, or the watched repos queried as aliases r0, r1…
        // (client-side filter: skip archived)
        var repoNodes: [[String: Any]] = []
        if let repoConn = viewer["repositories"] as? [String: Any],
           let nodes = repoConn["nodes"] as? [[String: Any]] {
            repoNodes = nodes
        }
        let aliasKeys = dataNode.keys
            .compactMap { key -> (Int, String)? in
                guard key.hasPrefix("r"), let i = Int(key.dropFirst()) else { return nil }
                return (i, key)
            }
            .sorted { $0.0 < $1.0 }
        repoNodes += aliasKeys.compactMap { dataNode[$0.1] as? [String: Any] }

        var mainCI: [GitHubRepoCI] = []
        for node in repoNodes {
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

        return result
    }

    // MARK: - Staleness

    /// Pure predicate: true when fetchedAt is nil or older than maxAge seconds before now.
    static func isStale(fetchedAt: Date?, now: Date = Date(), maxAge: TimeInterval) -> Bool {
        guard let t = fetchedAt else { return true }
        return now.timeIntervalSince(t) > maxAge
    }
}

// MARK: - Query

extension GitHubPulse {
    /// Pulse query. With no watched repos: the 10 most recently pushed owned repos.
    /// With watched repos: each one fetched by name as an alias r0, r1… (parsed in GitHubPulse.parse).
    static func query(watched: [String]) -> String {
        let repoFields = """
        nameWithOwner url isArchived
              defaultBranchRef {
                name
                target { ... on Commit { oid statusCheckRollup { state } } }
              }
        """
        let viewerRepos = watched.isEmpty ? """
            repositories(first: 10, ownerAffiliations: [OWNER], orderBy: {field: PUSHED_AT, direction: DESC}) {
              nodes {
                \(repoFields)
              }
            }
        """ : ""
        let aliases = watched.compactMap(repoOwnerAndName).enumerated().map { i, pair in
            "  r\(i): repository(owner: \"\(pair.0)\", name: \"\(pair.1)\") { \(repoFields) }"
        }.joined(separator: "\n")
        return """
        query {
          viewer {
            login
            pullRequests(states: OPEN, first: 20, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title url isDraft reviewDecision headRefName
                repository { nameWithOwner url }
                commits(last: 1) {
                  nodes { commit { oid statusCheckRollup { state } } }
                }
              }
            }
        \(viewerRepos)
          }
          reviewRequested: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 20) {
            issueCount
            nodes {
              ... on PullRequest {
                number title url isDraft
                author { login }
                repository { nameWithOwner url }
              }
            }
          }
        \(aliases)
        }
        """
    }

    /// "owner/name" → ("owner", "name"), only when both parts are safe to put in a GraphQL string.
    static func repoOwnerAndName(_ nameWithOwner: String) -> (String, String)? {
        let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return (parts[0], parts[1])
    }
}

// MARK: - SessionBranchInfo
//
// The open PR and the CI of the branch a Claude Code session works on.

struct SessionBranchInfo: Equatable {
    var repo: String
    var branch: String
    var pr: GitHubPR?
    var branchCI: CIState
    var fetchedAt: Date

    var hasPending: Bool { branchCI == .pending || pr?.ci == .pending }

    /// Values go in GraphQL variables, never in the query text.
    static let query = """
    query($owner: String!, $name: String!, $branch: String!, $qualified: String!) {
      repository(owner: $owner, name: $name) {
        pullRequests(headRefName: $branch, states: [OPEN], first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number title url isDraft reviewDecision headRefName
            headRepository { nameWithOwner }
            commits(last: 1) { nodes { commit { oid statusCheckRollup { state } } } }
          }
        }
        ref(qualifiedName: $qualified) {
          target { ... on Commit { oid statusCheckRollup { state } } }
        }
      }
    }
    """

    static func variables(repo: String, branch: String) -> [String: String]? {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        return ["owner": parts[0], "name": parts[1], "branch": branch, "qualified": "refs/heads/\(branch)"]
    }

    static func parse(_ data: Data, repo: String, branch: String, now: Date = Date()) -> SessionBranchInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let repository = dataNode["repository"] as? [String: Any] else { return nil }
        var pr: GitHubPR? = nil
        // headRefName also matches PRs from forks with a same-named branch: keep this repo's own.
        let nodes = (repository["pullRequests"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let own = nodes.first {
            let head = ($0["headRepository"] as? [String: Any])?["nameWithOwner"] as? String
            return head?.caseInsensitiveCompare(repo) == .orderedSame
        }
        if let node = own,
           let number = node["number"] as? Int,
           let title = node["title"] as? String,
           let url = node["url"] as? String {
            let commit = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"] as? [String: Any]
            let rollup = commit?["statusCheckRollup"] as? [String: Any]
            pr = GitHubPR(id: "\(repo)#\(number)", title: title, url: url, repo: repo, number: number,
                          isDraft: node["isDraft"] as? Bool ?? false,
                          ci: CIState(rawGitHub: rollup?["state"] as? String),
                          review: ReviewState(rawGitHub: node["reviewDecision"] as? String),
                          headSha: commit?["oid"] as? String,
                          headRef: node["headRefName"] as? String ?? branch)
        }
        let target = (repository["ref"] as? [String: Any])?["target"] as? [String: Any]
        let ci = CIState(rawGitHub: (target?["statusCheckRollup"] as? [String: Any])?["state"] as? String)
        return SessionBranchInfo(repo: repo, branch: branch, pr: pr, branchCI: ci, fetchedAt: now)
    }
}
