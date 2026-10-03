import Foundation

// MARK: - GitHub pull request (integration_github_prs)

struct GitHubPullRequest: Identifiable, Equatable {
    /// Why this pull request is in the list. A PR can be there for several reasons.
    enum Reason: String, CaseIterable {
        case reviewRequested
        case assigned
    }

    /// Stable identity: "owner/repo#123" (the search API's `id` is not the PR number).
    let id: String
    let number: Int
    let title: String
    let repoFullName: String   // "owner/repo"
    let author: String
    let url: String
    let updatedAt: Date
    let isDraft: Bool
    var reasons: Set<Reason>

    var repoShort: String { repoFullName.components(separatedBy: "/").last ?? repoFullName }
    var reference: String { "\(repoShort)#\(number)" }
    var needsReview: Bool { reasons.contains(.reviewRequested) }

    var timeAgo: String {
        let diff = Date().timeIntervalSince(updatedAt)
        if diff < 60    { return "just now" }
        if diff < 3600  { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Parsing + helpers (Foundation-only, no AppKit/SwiftUI, so tests can compile this file alone)

enum GithubPullRequests {

    /// Search queries, one per reason. `@me` is resolved by GitHub from the token.
    static func searchQuery(for reason: GitHubPullRequest.Reason) -> String {
        switch reason {
        case .reviewRequested: return "is:pr is:open archived:false review-requested:@me"
        case .assigned:        return "is:pr is:open archived:false assignee:@me"
        }
    }

    static func searchURL(for reason: GitHubPullRequest.Reason, perPage: Int = 30) -> URL? {
        var comps = URLComponents(string: "https://api.github.com/search/issues")
        comps?.queryItems = [
            URLQueryItem(name: "q",               value: searchQuery(for: reason)),
            URLQueryItem(name: "sort",            value: "updated"),
            URLQueryItem(name: "order",           value: "desc"),
            URLQueryItem(name: "per_page",        value: "\(perPage)"),
            URLQueryItem(name: "advanced_search", value: "true"),
        ]
        return comps?.url
    }

    /// Parses one item of a `/search/issues` response. Returns nil for issues and malformed items.
    static func parse(item d: [String: Any], reason: GitHubPullRequest.Reason) -> GitHubPullRequest? {
        guard d["pull_request"] != nil,
              let number  = d["number"]  as? Int,
              let title   = d["title"]   as? String,
              let htmlURL = d["html_url"] as? String,
              let repoURL = d["repository_url"] as? String else { return nil }

        // "https://api.github.com/repos/owner/name" → "owner/name"
        let parts = repoURL.components(separatedBy: "/repos/")
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        let repoFullName = parts[1]

        let author  = ((d["user"] as? [String: Any])?["login"] as? String) ?? ""
        let isDraft = (d["draft"] as? Bool) ?? false
        let updated = parseDate(d["updated_at"] as? String) ?? parseDate(d["created_at"] as? String) ?? Date()

        return GitHubPullRequest(id: "\(repoFullName)#\(number)", number: number, title: title,
                                 repoFullName: repoFullName, author: author, url: htmlURL,
                                 updatedAt: updated, isDraft: isDraft, reasons: [reason])
    }

    /// Parses a whole `/search/issues` payload for one reason.
    static func parse(payload: [String: Any], reason: GitHubPullRequest.Reason) -> [GitHubPullRequest] {
        let items = (payload["items"] as? [[String: Any]]) ?? []
        return items.compactMap { parse(item: $0, reason: reason) }
    }

    /// Dedupes by id (a PR both assigned and awaiting review keeps both reasons),
    /// then sorts: review requests first, then most recently updated.
    static func merge(_ lists: [[GitHubPullRequest]]) -> [GitHubPullRequest] {
        var byId: [String: GitHubPullRequest] = [:]
        var order: [String] = []
        for list in lists {
            for pr in list {
                if var existing = byId[pr.id] {
                    existing.reasons.formUnion(pr.reasons)
                    byId[pr.id] = existing
                } else {
                    byId[pr.id] = pr
                    order.append(pr.id)
                }
            }
        }
        return order.compactMap { byId[$0] }.sorted { a, b in
            if a.needsReview != b.needsReview { return a.needsReview }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Short summary for the card header, where only ~90 pt are available next to the
    /// pill name: "2 to review", else "1 assigned", else nil when empty.
    static func summary(_ prs: [GitHubPullRequest]) -> String? {
        let review   = prs.filter { $0.needsReview }.count
        let assigned = prs.filter { !$0.needsReview }.count
        if review   > 0 { return "\(review) to review" }
        if assigned > 0 { return "\(assigned) assigned" }
        return nil
    }

    /// Full summary for the header tooltip: "2 to review · 1 assigned", or nil when empty.
    static func detailedSummary(_ prs: [GitHubPullRequest]) -> String? {
        let review   = prs.filter { $0.needsReview }.count
        let assigned = prs.filter { !$0.needsReview }.count
        var parts: [String] = []
        if review   > 0 { parts.append("\(review) to review") }
        if assigned > 0 { parts.append("\(assigned) assigned") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Human message for a non-200 search response.
    static func errorMessage(status: Int, transport: String?) -> String {
        switch status {
        case 401: return "Invalid token (401)"
        case 403: return "Rate limited or missing scope (403)"
        case 422: return "Search rejected (422)"
        case 0:   return transport ?? "No connection"
        default:  return "API error \(status)"
        }
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
