import Foundation

// The pure half of GitLabPoller: instance URL rules, parsing of the REST v4
// answers, and the activity grid. No network, no AppState, so it compiles and is
// tested on its own (tests/GitLabPulseTests.swift).
//
// GitLab's answers are turned into the very types GitHubPulse.swift defines for
// GitHub (GitHubPulse, GitHubPR, GitHubRepoCI, GitHubActivity): a merge request
// is a GitHubPR, a project's default-branch pipeline a GitHubRepoCI. The island
// reads both providers the same way, and the alert rules are the same code.
// Same rules as windows/src-tauri/src/gitlab.rs.

extension CIState {
    /// A GitLab pipeline `status`. A cancelled, skipped or manual pipeline says
    /// nothing about the code, so it is unknown.
    init(rawGitLab: String?) {
        switch rawGitLab {
        case "created", "waiting_for_resource", "preparing", "pending", "running", "scheduled":
            self = .pending
        case "success", "success_with_warnings":
            self = .success
        case "failed":
            self = .failure
        default:
            self = .unknown
        }
    }
}

enum GitLab {

    static let defaultBaseURL = "https://gitlab.com"

    // MARK: - Instance URL

    /// The instance the token belongs to: the stored URL, or gitlab.com when
    /// there is none. Only https is accepted, plus http on this machine (a local
    /// test instance): the token travels in a header and must not cross a network
    /// in clear text. A sub-path is kept; query, fragment and trailing slash go.
    static func normalizeBase(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? defaultBaseURL : trimmed
        guard let comps = URLComponents(string: value),
              let scheme = comps.scheme?.lowercased(),
              let host = comps.host, !host.isEmpty else { return nil }
        let isLocal = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }
        var base = "\(scheme)://" + (host.contains(":") ? "[\(host)]" : host)
        if let port = comps.port { base += ":\(port)" }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        base += path
        return base
    }

    static func apiURL(base: String, path: String) -> String {
        "\(base)/api/v4/\(path)"
    }

    // MARK: - Merge requests

    /// "group/project" out of a merge request: `references.full`
    /// ("group/project!12"), else the path of its web URL before "/-/merge_requests".
    static func projectPath(_ item: [String: Any]) -> String? {
        if let refs = item["references"] as? [String: Any],
           let full = refs["full"] as? String,
           let bang = full.lastIndex(of: "!") {
            let repo = String(full[..<bang])
            if !repo.isEmpty { return repo }
        }
        guard let urlString = item["web_url"] as? String,
              let url = URL(string: urlString),
              let range = url.path.range(of: "/-/merge_requests") else { return nil }
        let repo = String(url.path[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return repo.isEmpty ? nil : repo
    }

    /// One item of `GET /merge_requests`. nil when a required field is missing
    /// (that item is skipped, as for GitHub). `pipeline` is the head pipeline's
    /// status, which the list does not carry (see `headPipelineStatus`).
    /// `withCI` is true for my own merge requests, false for the ones to review.
    static func parseMR(_ item: [String: Any], pipeline: String?, withCI: Bool) -> GitHubPR? {
        guard let number = item["iid"] as? Int,
              let title = item["title"] as? String,
              let url = item["web_url"] as? String,
              let repo = projectPath(item) else { return nil }
        let isDraft = (item["draft"] as? Bool) ?? (item["work_in_progress"] as? Bool) ?? false
        let review: ReviewState
        if withCI {
            review = (item["detailed_merge_status"] as? String) == "not_approved" ? .pending : .unknown
        } else {
            review = .pending
        }
        return GitHubPR(
            id: "\(repo)!\(number)", title: title, url: url, repo: repo, number: number,
            isDraft: isDraft,
            ci: withCI ? CIState(rawGitLab: pipeline) : .unknown,
            review: review,
            headSha: withCI ? (item["sha"] as? String) : nil
        )
    }

    /// `head_pipeline.status` of one `GET /projects/:id/merge_requests/:iid`.
    static func headPipelineStatus(_ detail: Any?) -> String? {
        guard let detail = detail as? [String: Any],
              let pipeline = detail["head_pipeline"] as? [String: Any] else { return nil }
        return pipeline["status"] as? String
    }

    /// Key of the pipeline-status map: "project_id!iid".
    static func mrKey(_ item: [String: Any]) -> String? {
        guard let project = item["project_id"] as? Int, let iid = item["iid"] as? Int else { return nil }
        return "\(project)!\(iid)"
    }

    /// My open merge requests. `ci` maps "project_id!iid" to a pipeline status.
    /// The first occurrence of an id wins.
    static func parseMyMRs(_ list: Any?, ci: [String: String]) -> [GitHubPR] {
        var out: [GitHubPR] = []
        var seen = Set<String>()
        for item in (list as? [[String: Any]]) ?? [] {
            let status = mrKey(item).flatMap { ci[$0] }
            guard let mr = parseMR(item, pipeline: status, withCI: true),
                  seen.insert(mr.id).inserted else { continue }
            out.append(mr)
        }
        return out
    }

    /// Merge requests waiting for me: those where I am a reviewer, then those
    /// assigned to me; my own (assigned to myself) and duplicates left out.
    static func parseToReview(reviewer: Any?, assigned: Any?, me: String) -> [GitHubPR] {
        var out: [GitHubPR] = []
        var seen = Set<String>()
        for list in [reviewer, assigned] {
            for item in (list as? [[String: Any]]) ?? [] {
                if let author = item["author"] as? [String: Any], author["username"] as? String == me { continue }
                guard let mr = parseMR(item, pipeline: nil, withCI: false),
                      seen.insert(mr.id).inserted else { continue }
                out.append(mr)
            }
        }
        return out
    }

    // MARK: - Pipelines of the default branches

    /// A project and the latest pipeline on its default branch. Archived
    /// projects, and projects without a default branch (empty), are left out.
    static func parseRepoCI(_ project: [String: Any], latestPipeline: [String: Any]?) -> GitHubRepoCI? {
        if (project["archived"] as? Bool) == true { return nil }
        guard let repo = project["path_with_namespace"] as? String,
              let url = project["web_url"] as? String,
              let branch = project["default_branch"] as? String else { return nil }
        return GitHubRepoCI(
            repo: repo, url: url, branch: branch,
            ci: CIState(rawGitLab: latestPipeline?["status"] as? String),
            headSha: latestPipeline?["sha"] as? String
        )
    }

    // MARK: - Stats

    /// (projects, stars) over the user's own projects (`GET /projects?owned=true`).
    static func parseStats(_ projects: Any?) -> (repos: Int, stars: Int) {
        let list = (projects as? [[String: Any]]) ?? []
        let stars = list.reduce(0) { $0 + (($1["star_count"] as? Int) ?? 0) }
        return (list.count, stars)
    }

    // MARK: - Activity grid
    //
    // GitLab has no contribution-calendar API, so the grid counts the user's own
    // events (`GET /events`: pushes, merge requests, comments…) per day. That is
    // close to GitLab's own calendar, not identical to it.

    /// Days since 1970-01-01 → (year, month, day). Howard Hinnant's civil_from_days.
    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// (year, month, day) → days since 1970-01-01. Howard Hinnant's days_from_civil.
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func formatDate(_ days: Int) -> String {
        let c = civilFromDays(days)
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    /// "YYYY-MM-DD" → days since the epoch; also takes a full ISO timestamp.
    static func parseDate(_ raw: String) -> Int? {
        let parts = raw.prefix(10).split(separator: "-")
        guard raw.count >= 10, parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return daysFromCivil(y, m, d)
    }

    private static func epochDay(_ now: Date) -> Int {
        Int((now.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// The date a poll starts from (`after` is exclusive): a year back.
    static func eventsAfter(now: Date) -> String {
        formatDate(epochDay(now) - 366)
    }

    /// The date `days` days before now, "YYYY-MM-DD" (the `after` of an events poll).
    static func dateDaysAgo(nowMs: Int, days: Int) -> String {
        formatDate(nowMs / 86_400_000 - days)
    }

    /// Counts events per day over the last 53 weeks (Sunday first, the last week
    /// ends today) and grades each day 0…4 against the busiest one.
    static func parseActivity(events: [[String: Any]], now: Date) -> GitHubActivity {
        let today = epochDay(now)
        var counts: [Int: Int] = [:]
        for event in events {
            guard let raw = event["created_at"] as? String, let day = parseDate(raw),
                  day <= today, day > today - 366 else { continue }
            counts[day, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        let maxCount = counts.values.max() ?? 0

        // 1970-01-01 was a Thursday.
        func weekday(_ day: Int) -> Int { ((day + 4) % 7 + 7) % 7 }
        let thisSunday = today - weekday(today)

        var weeks: [[ContributionDay]] = []
        for w in stride(from: 52, through: 0, by: -1) {
            let sunday = thisSunday - 7 * w
            var days: [ContributionDay] = []
            for dow in 0..<7 {
                let day = sunday + dow
                if day > today { break }
                let count = counts[day] ?? 0
                let level = (count == 0 || maxCount == 0) ? 0 : min(4, max(1, (count * 4 + maxCount - 1) / maxCount))
                days.append(ContributionDay(date: formatDate(day), count: count, level: level, weekday: dow))
            }
            weeks.append(days)
        }
        return GitHubActivity(total: total, weeks: weeks, fetchedAt: now)
    }
}
