import Foundation

// GitLab merge requests mapped onto the GitHub pulse model, so the GitLab pill reuses
// the GitHub card, detail list and CI/review alerts.

extension CIState {
    init(rawGitLab: String?) {
        switch rawGitLab?.uppercased() {
        case "CREATED", "WAITING_FOR_RESOURCE", "PREPARING", "PENDING", "RUNNING", "SCHEDULED":
            self = .pending
        case "SUCCESS":
            self = .success
        case "FAILED":
            self = .failure
        default:   // CANCELED, SKIPPED, MANUAL, no pipeline
            self = .unknown
        }
    }
}

enum GitLabPulse {
    static let graphQLQuery = """
    query {
      currentUser {
        username
        authoredMergeRequests(state: opened, first: 20, sort: UPDATED_DESC) {
          nodes { iid title webUrl draft approved diffHeadSha project { fullPath } headPipeline { status } }
        }
        reviewRequestedMergeRequests(state: opened, first: 20, sort: UPDATED_DESC) {
          nodes { iid title webUrl draft project { fullPath } }
        }
      }
    }
    """

    static func parse(_ data: Data, now: Date = Date()) -> GitHubPulse? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let user = dataNode["currentUser"] as? [String: Any] else { return nil }

        func mergeRequests(_ key: String, withCI: Bool) -> [GitHubPR] {
            let nodes = (user[key] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            return nodes.compactMap { node in
                guard let iidString = node["iid"] as? String, let iid = Int(iidString),
                      let title = node["title"] as? String,
                      let url = node["webUrl"] as? String,
                      let repo = (node["project"] as? [String: Any])?["fullPath"] as? String else { return nil }
                let id = "\(repo)!\(iid)"
                guard seen.insert(id).inserted else { return nil }
                let pipeline = (node["headPipeline"] as? [String: Any])?["status"] as? String
                return GitHubPR(
                    id: id, title: title, url: url, repo: repo, number: iid,
                    isDraft: node["draft"] as? Bool ?? false,
                    ci: withCI ? CIState(rawGitLab: pipeline) : .unknown,
                    review: withCI ? ((node["approved"] as? Bool ?? false) ? .approved : .unknown) : .pending,
                    headSha: withCI ? node["diffHeadSha"] as? String : nil
                )
            }
        }

        return GitHubPulse(
            login: user["username"] as? String ?? "",
            myPRs: mergeRequests("authoredMergeRequests", withCI: true),
            toReview: mergeRequests("reviewRequestedMergeRequests", withCI: false),
            mainCI: [],
            fetchedAt: now
        )
    }

    /// The instance URL from Settings: https only, no trailing slash. Defaults to gitlab.com.
    static func baseURL(from raw: String?) -> URL? {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = "https://gitlab.com" }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
