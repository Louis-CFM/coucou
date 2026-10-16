import Foundation

// The GitLab panel's data — the pure half: what a merge request line holds, which
// discussion threads wait for my answer, the four lists, the alerts between two
// polls, and what the panel remembers of what was seen. No network, no AppState,
// so it compiles and is tested on its own (tests/GitLabDashTests.swift).
// GitLabPanelService fetches; GitLabPanel draws. Same rules as
// windows/src-tauri/src/gitlab_dash.rs and windows/src/core/gitlab-panel.ts.
//
// "A thread waits for me" (decided with the user):
// - a resolvable thread (a code or a threaded comment) that is not resolved,
//   whose last message is not mine, on a merge request that is mine or where I
//   wrote in that thread;
// - a plain comment (not resolvable) whose last message is not mine, on such a
//   merge request, and that is newer than anything I wrote there — GitLab has no
//   "resolved" for it, so my own later message is what clears it.
// System notes ("added 2 commits", "approved this merge request") are no message,
// and neither are those of automated accounts (SonarQube, dependabot, project
// bots…) nor SonarQube's report, which often comes under an ordinary account (its
// author is a person's name, only its text gives it away): the panel is for what
// people wrote. A thread that only holds such notes is not shown, nor counted
// among the open threads of a merge request.

// MARK: - Shapes

struct GitLabApprovals: Equatable {
    var given: Int
    /// 0 when the project asks for none.
    var required: Int
}

/// One merge request line.
struct GitLabMR: Equatable, Identifiable {
    /// "group/project!12"
    var id: String
    /// "group/project"
    var project: String
    var projectId: Int
    var iid: Int
    var title: String
    var url: String
    var isDraft: Bool
    var ci: CIState
    /// Unix milliseconds, 0 when unknown.
    var updatedAt: Int
    var approvals: GitLabApprovals?
    /// Resolvable threads not resolved yet; nil when the discussions were not read.
    var unresolved: Int?
}

struct GitLabThreadNote: Equatable, Identifiable {
    var id: Int
    var author: String
    var username: String
    var body: String
    var createdAt: Int
    var isMe: Bool
}

/// Where a thread hangs in the code: enough to read the lines around it.
struct GitLabCodePosition: Equatable {
    var file: String
    var line: Int
    /// "new" (the line exists after the change) or "old" (a removed line).
    var side: String
    /// The commit to read the file at.
    var sha: String
}

struct GitLabThread: Equatable, Identifiable {
    /// The discussion's id.
    var id: String
    /// Changes with the last message: a reply to a thread I answered is new again.
    var key: String
    var project: String
    var projectId: Int
    var mrIid: Int
    var mrRef: String
    var mrTitle: String
    var mrUrl: String
    var resolvable: Bool
    var notes: [GitLabThreadNote]
    var position: GitLabCodePosition?
    var lastAt: Int
}

struct GitLabDashboard: Equatable {
    var me: String
    /// The instance the data comes from: links open only on its host.
    var baseURL: String
    /// Whether the token has the `api` scope; nil when GitLab did not say.
    var canWrite: Bool?
    var toReview: [GitLabMR]
    var mine: [GitLabMR]
    var approved: [GitLabMR]
    var comments: [GitLabThread]
    var fetchedAt: Int
}

struct GitLabSnippetLine: Equatable, Identifiable {
    var number: Int
    var text: String
    var target: Bool
    var id: Int { number }
}

/// Everything read about one merge request.
struct GitLabEntry: Equatable {
    var mr: GitLabMR
    var author: String
    var open: Bool
    var approvedByMe: Bool
    var threads: [GitLabThread]
}

/// How a merge request came into the perimeter.
struct GitLabRoles: Equatable {
    var reviewer = false
    var assigned = false
    var approvedEvent = false
}

// MARK: - Parsing

extension GitLab {

    static let listMax = 30

    /// "2026-01-14T08:00:00.000Z" or "…+02:00" → Unix milliseconds.
    static func parseISOms(_ raw: String) -> Int? {
        guard let days = parseDate(raw) else { return nil }
        let chars = Array(raw)
        guard chars.count >= 19 else { return nil }
        let time = String(chars[11..<19]).split(separator: ":")
        guard time.count == 3, let h = Int(time[0]), let m = Int(time[1]), let s = Int(time[2]) else { return nil }
        var rest = Substring(String(chars[19...]))
        var ms = 0
        if rest.hasPrefix(".") {
            let digits = rest.dropFirst().prefix(while: { $0.isNumber })
            rest = rest.dropFirst(1 + digits.count)
            ms = Int(String((digits + "000").prefix(3))) ?? 0
        }
        var offsetMin = 0
        if let sign = rest.first, sign == "+" || sign == "-" {
            let parts = rest.dropFirst().split(separator: ":")
            guard let oh = parts.first.flatMap({ Int($0) }) else { return nil }
            let om = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            offsetMin = (sign == "-" ? -1 : 1) * (oh * 60 + om)
        }
        let total = days * 86_400_000 + h * 3_600_000 + m * 60_000 + s * 1000 + ms - offsetMin * 60_000
        return total >= 0 ? total : nil
    }

    // MARK: Automated messages

    /// Names of accounts that post by themselves, matched whole (lower case) against
    /// the words of an account's username and name.
    private static let automatedWords: Set<String> = [
        "bot", "dependabot", "renovate", "renovatebot", "codecov", "snyk", "danger", "dangerbot", "sonar",
        "sonarqube", "sonarcloud", "sonarscanner", "coveralls", "semgrep", "mergify", "reviewdog",
    ]

    /// True for an account that posts automated messages (a CI analysis, a dependency
    /// bot): GitLab's own `bot` flag when it gives one, a project or group access
    /// token's bot user (`project_12_bot_…`), a name with "[bot]", or a username or
    /// name made of the words of a known tool. "sonar" matches wherever it is, since
    /// SonarQube runs under many names (sonarqube, sonar-bot, sonarqube-service…).
    static func isAutomated(author: [String: Any]?) -> Bool {
        guard let author else { return false }
        if (author["bot"] as? Bool) == true { return true }
        let username = ((author["username"] as? String) ?? "").lowercased()
        let name = ((author["name"] as? String) ?? "").lowercased()
        if username.contains("sonar") || name.contains("sonar") || name.contains("[bot]") || username.contains("[bot]") {
            return true
        }
        let tokenUser = (username.hasPrefix("project_") || username.hasPrefix("group_")) && username.contains("_bot")
        if tokenUser { return true }
        func words(_ text: String) -> [String] {
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        return (words(username) + words(name)).contains { automatedWords.contains($0) }
    }

    /// True for the text of a code-analysis report posted by a tool, whoever's account
    /// it was posted from: SonarQube's "Quality Gate" comment on a merge request.
    static func isAutomatedText(_ body: String) -> Bool {
        let lower = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.hasPrefix("sonarqube")
            || lower.hasPrefix("sonarcloud")
            || lower.hasPrefix("**sonar")
            || lower.contains("see analysis details on sonar")
            || (lower.contains("quality gate") && lower.contains("sonar"))
    }

    /// A note nobody wrote to be read: from an automated account, or a tool's report.
    private static func isAutomatedNote(_ note: [String: Any]) -> Bool {
        isAutomated(author: note["author"] as? [String: Any]) || isAutomatedText((note["body"] as? String) ?? "")
    }

    // MARK: Approvals, threads, merge requests

    /// The approvals answer: how many gave one, how many are asked, and whether I did.
    static func parseApprovals(_ approvals: [String: Any], me: String) -> (GitLabApprovals, Bool) {
        let givenBy = (approvals["approved_by"] as? [[String: Any]]) ?? []
        let byMe = givenBy.contains { (($0["user"] as? [String: Any])?["username"] as? String) == me }
        let required = (approvals["approvals_required"] as? Int) ?? 0
        return (GitLabApprovals(given: givenBy.count, required: required), byMe)
    }

    /// A note's position → where to read the code. The new side when the line exists
    /// after the change, else the old one (a removed line) at the base commit.
    private static func codePosition(_ p: [String: Any]) -> GitLabCodePosition? {
        if let file = p["new_path"] as? String, let line = p["new_line"] as? Int, let sha = p["head_sha"] as? String {
            return GitLabCodePosition(file: file, line: line, side: "new", sha: sha)
        }
        guard let file = p["old_path"] as? String, let line = p["old_line"] as? Int,
              let sha = p["base_sha"] as? String else { return nil }
        return GitLabCodePosition(file: file, line: line, side: "old", sha: sha)
    }

    /// The pending threads of one merge request, and how many resolvable threads are
    /// still open (the "unresolved" count of its line).
    static func pendingThreads(discussions: [[String: Any]], me: String, iAmAuthor: Bool,
                               mr: GitLabMR) -> (threads: [GitLabThread], unresolved: Int) {
        struct Draft {
            var id: String
            var notes: [GitLabThreadNote]
            var resolvable: Bool
            var resolved: Bool
            var position: GitLabCodePosition?
        }
        var drafts: [Draft] = []
        for d in discussions {
            guard let id = d["id"] as? String else { continue }
            let raw = (d["notes"] as? [[String: Any]]) ?? []
            var notes: [GitLabThreadNote] = []
            for n in raw where !((n["system"] as? Bool) ?? false) && !isAutomatedNote(n) {
                let author = n["author"] as? [String: Any]
                let username = (author?["username"] as? String) ?? ""
                let name = (author?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? username
                notes.append(GitLabThreadNote(
                    id: (n["id"] as? Int) ?? 0, author: name, username: username,
                    body: (n["body"] as? String) ?? "",
                    createdAt: ((n["created_at"] as? String).flatMap(parseISOms)) ?? 0,
                    isMe: username == me))
            }
            if notes.isEmpty { continue }
            let resolvables = raw.filter { ($0["resolvable"] as? Bool) ?? false }
            let resolvable = !resolvables.isEmpty
            let resolved = resolvable && resolvables.allSatisfy { ($0["resolved"] as? Bool) ?? false }
            let position = raw.compactMap { $0["position"] as? [String: Any] }.first.flatMap(codePosition)
            drafts.append(Draft(id: id, notes: notes, resolvable: resolvable, resolved: resolved, position: position))
        }

        let unresolved = drafts.filter { $0.resolvable && !$0.resolved }.count
        // My latest message anywhere in this merge request clears the plain comments before it.
        let myLast = drafts.flatMap { $0.notes }.filter { $0.isMe }.map { $0.createdAt }.max() ?? 0

        var out: [GitLabThread] = []
        for t in drafts {
            guard let last = t.notes.last, !last.isMe else { continue }
            let wroteInIt = t.notes.contains { $0.isMe }
            if !(iAmAuthor || wroteInIt) { continue }
            let waiting = t.resolvable ? !t.resolved : last.createdAt > myLast
            if !waiting { continue }
            out.append(GitLabThread(
                id: t.id, key: "\(t.id):\(last.id)", project: mr.project, projectId: mr.projectId,
                mrIid: mr.iid, mrRef: mr.id, mrTitle: mr.title, mrUrl: mr.url,
                resolvable: t.resolvable, notes: t.notes, position: t.position, lastAt: last.createdAt))
        }
        return (out, unresolved)
    }

    /// A merge request's line out of its detail (`GET /projects/:id/merge_requests/:iid`).
    static func parseDashMR(_ detail: [String: Any], approvals: GitLabApprovals?, unresolved: Int?) -> GitLabMR? {
        guard let iid = detail["iid"] as? Int,
              let projectId = detail["project_id"] as? Int,
              let project = projectPath(detail),
              let title = detail["title"] as? String,
              let url = detail["web_url"] as? String else { return nil }
        let pipeline = (detail["head_pipeline"] as? [String: Any])?["status"] as? String
        return GitLabMR(
            id: "\(project)!\(iid)", project: project, projectId: projectId, iid: iid, title: title, url: url,
            isDraft: (detail["draft"] as? Bool) ?? (detail["work_in_progress"] as? Bool) ?? false,
            ci: CIState(rawGitLab: pipeline),
            updatedAt: ((detail["updated_at"] as? String).flatMap(parseISOms)) ?? 0,
            approvals: approvals, unresolved: unresolved)
    }

    /// Reads one merge request whole. nil when it lacks a required field.
    static func buildEntry(detail: [String: Any], approvals: [String: Any]?, discussions: [[String: Any]]?,
                           me: String) -> GitLabEntry? {
        let author = ((detail["author"] as? [String: Any])?["username"] as? String) ?? ""
        var counts: GitLabApprovals?
        var byMe = false
        if let approvals {
            let read = parseApprovals(approvals, me: me)
            counts = read.0
            byMe = read.1
        }
        guard var mr = parseDashMR(detail, approvals: counts, unresolved: nil) else { return nil }
        var threads: [GitLabThread] = []
        if let discussions {
            let found = pendingThreads(discussions: discussions, me: me, iAmAuthor: author == me, mr: mr)
            threads = found.threads
            mr.unresolved = found.unresolved
        }
        return GitLabEntry(mr: mr, author: author, open: (detail["state"] as? String) == "opened",
                           approvedByMe: byMe, threads: threads)
    }

    // MARK: The four lists

    private static func newestFirst(_ list: [GitLabMR]) -> [GitLabMR] {
        Array(list.sorted { $0.updatedAt > $1.updatedAt }.prefix(listMax))
    }

    static func buildDashboard(me: String, baseURL: String, canWrite: Bool?,
                               entries: [(entry: GitLabEntry, roles: GitLabRoles)], nowMs: Int) -> GitLabDashboard {
        var toReview: [GitLabMR] = [], mine: [GitLabMR] = [], approved: [GitLabMR] = []
        var comments: [GitLabThread] = []
        for (e, roles) in entries where e.open {
            if e.author == me { mine.append(e.mr) }
            else if roles.reviewer || roles.assigned { toReview.append(e.mr) }
            if roles.approvedEvent && e.approvedByMe { approved.append(e.mr) }
            comments.append(contentsOf: e.threads)
        }
        comments.sort { $0.lastAt > $1.lastAt }
        return GitLabDashboard(
            me: me, baseURL: baseURL, canWrite: canWrite,
            toReview: newestFirst(toReview), mine: newestFirst(mine), approved: newestFirst(approved),
            comments: Array(comments.prefix(listMax)), fetchedAt: nowMs)
    }

    /// Alerts between two polls: a thread that is new, or has a new last message. The
    /// first poll (no `old`) stays silent.
    static func events(old: GitLabDashboard?, new: GitLabDashboard) -> [GitHubEvent] {
        guard let old else { return [] }
        let known = Set(old.comments.map { $0.key })
        return new.comments.filter { !known.contains($0.key) }.map { .commentPending(threadId: $0.id) }
    }

    // MARK: Candidates from the events

    /// (project id, merge request iid) of the merge requests my events point at —
    /// `action=approved` events carry the merge request as their target,
    /// `action=commented` ones a note whose `noteable_type` is MergeRequest. Newest
    /// first, without duplicates, at most `max`.
    static func eventTargets(_ events: Any?, max: Int) -> [(project: Int, iid: Int)] {
        var out: [(project: Int, iid: Int)] = []
        for e in (events as? [[String: Any]]) ?? [] {
            guard let project = e["project_id"] as? Int else { continue }
            let iid: Int?
            if (e["target_type"] as? String) == "MergeRequest" {
                iid = e["target_iid"] as? Int
            } else if let note = e["note"] as? [String: Any], (note["noteable_type"] as? String) == "MergeRequest" {
                iid = note["noteable_iid"] as? Int
            } else {
                iid = nil
            }
            guard let iid else { continue }
            if !out.contains(where: { $0.project == project && $0.iid == iid }) {
                out.append((project, iid))
                if out.count >= max { break }
            }
        }
        return out
    }

    /// The lines around `line` (1-based) in `text`: up to `context` before and after,
    /// numbered. Empty when the file is shorter.
    static func snippet(text: String, line: Int, context: Int) -> [GitLabSnippetLine] {
        guard line >= 1 else { return [] }
        let from = Swift.max(1, line - context)
        var out: [GitLabSnippetLine] = []
        for (i, l) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let number = i + 1
            guard number >= from && number <= line + context else { continue }
            // A very long line (minified code) would swell the panel.
            out.append(GitLabSnippetLine(number: number, text: String(l.prefix(300)), target: number == line))
        }
        return out
    }

    /// MRs whose cached read is still good: same update time and no running pipeline.
    static func isFresh(cached: (updatedAt: String, entry: GitLabEntry)?, updatedAt: String?) -> Bool {
        guard let cached, let updatedAt else { return false }
        return cached.updatedAt == updatedAt && cached.entry.mr.ci != .pending
    }
}

// MARK: - Sections and what has been seen

enum GitLabSection: String, CaseIterable, Codable {
    case comments, toReview, mine, approved

    /// What asks for an action first, then what to follow.
    static let order: [GitLabSection] = [.comments, .toReview, .mine, .approved]

    /// The sections that take the colour of "something waits for you".
    var attention: Bool { self == .comments || self == .toReview }

    var title: String {
        switch self {
        case .comments: return String(localized: "Comments waiting")
        case .toReview: return String(localized: "To review")
        case .mine:     return String(localized: "My MRs")
        case .approved: return String(localized: "recap.image.approved")
        }
    }

    var accentHex: String {
        switch self {
        case .comments: return "#FC6D26"
        case .toReview: return "#8AB4F8"
        case .mine:     return "#B79CFF"
        case .approved: return "#22C55E"
        }
    }

    /// SF Symbol of the section's tile.
    var symbol: String {
        switch self {
        case .comments: return "bubble.left.fill"
        case .toReview: return "eye"
        case .mine:     return "arrow.triangle.pull"
        case .approved: return "checkmark"
        }
    }

    /// What identifies an item: a thread by its last message, a merge request by its reference.
    func itemIds(_ dash: GitLabDashboard) -> [String] {
        switch self {
        case .comments: return dash.comments.map { $0.key }
        case .toReview: return dash.toReview.map { $0.id }
        case .mine:     return dash.mine.map { $0.id }
        case .approved: return dash.approved.map { $0.id }
        }
    }

    func count(_ dash: GitLabDashboard) -> Int { itemIds(dash).count }

    /// Something in the section waits for an action of yours.
    func waiting(_ dash: GitLabDashboard) -> Bool { attention && count(dash) > 0 }
}

/// What the panel remembers: which items were seen and which sections are open.
struct GitLabPanelState: Equatable, Codable {
    /// False until the first data arrives: it is taken as already seen.
    var initialized = false
    /// The items present when each section was last looked at.
    var seen: [String: [String]] = [:]
    var open: [String: Bool] = [:]

    func isOpen(_ s: GitLabSection) -> Bool { open[s.rawValue] ?? false }

    /// New data arrived. The very first data is taken as seen, so the badges start at
    /// nothing; after that, a section the user has open is being looked at, so what
    /// arrives in it is seen at once.
    func receiving(_ dash: GitLabDashboard) -> GitLabPanelState {
        var next = self
        for s in GitLabSection.order where !initialized || isOpen(s) {
            next.seen[s.rawValue] = s.itemIds(dash)
        }
        next.initialized = true
        return next
    }

    /// Opening a section marks what it holds as seen; closing it keeps that.
    func toggling(_ s: GitLabSection, dash: GitLabDashboard?) -> GitLabPanelState {
        var next = self
        let nowOpen = !isOpen(s)
        next.open[s.rawValue] = nowOpen
        if nowOpen, let dash { next.seen[s.rawValue] = s.itemIds(dash) }
        return next
    }

    /// The "+N": items present now that were not when the section was last looked at.
    func newCount(_ s: GitLabSection, dash: GitLabDashboard) -> Int {
        guard initialized else { return 0 }
        let seen = Set(self.seen[s.rawValue] ?? [])
        return s.itemIds(dash).filter { !seen.contains($0) }.count
    }
}

// MARK: - Words and numbers

enum GitLabPanelText {

    /// "just now", "5m", "3h", "2d" — the same words as the other cards.
    static func age(ms: Int, now: Date = Date()) -> String {
        guard ms > 0 else { return "" }
        let diff = now.timeIntervalSince1970 - Double(ms) / 1000
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }

    /// "1/2" when the project asks for approvals, "✓ 1" when some came without being asked.
    static func approvals(_ a: GitLabApprovals?) -> String? {
        guard let a else { return nil }
        if a.required > 0 { return "\(a.given)/\(a.required)" }
        return a.given > 0 ? "✓ \(a.given)" : nil
    }

    /// "group/sub/proj" → "proj".
    static func shortProject(_ project: String) -> String {
        project.split(separator: "/").last.map(String.init) ?? project
    }

    /// The last message of a thread, on one line, for the collapsed row.
    static func preview(_ thread: GitLabThread, max: Int = 90) -> String {
        guard let last = thread.notes.last else { return "" }
        let flat = last.body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// "Jane Doe" → "JD", "bob" → "B": what a little round avatar carries.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let first = words.first?.first else { return "?" }
        var out = String(first)
        if words.count > 1, let second = words.last?.first { out.append(second) }
        return out.uppercased()
    }

    /// A colour for a person, the same every time: a hue from 0 to 359.
    static func avatarHue(_ username: String) -> Int {
        var hash: UInt32 = 0
        for scalar in username.unicodeScalars { hash = hash &* 31 &+ scalar.value }
        return Int(hash % 360)
    }

    /// A link to one message of a thread, so GitLab scrolls to it.
    static func noteURL(_ thread: GitLabThread) -> String {
        guard let last = thread.notes.last else { return thread.mrUrl }
        return "\(thread.mrUrl)#note_\(last.id)"
    }

    /// Only http(s) links to the instance the data came from open.
    static func safeInstanceURL(_ raw: String, base: String) -> URL? {
        guard let url = URL(string: raw), let b = URL(string: base),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, host == b.host, url.port == b.port else { return nil }
        return url
    }
}
