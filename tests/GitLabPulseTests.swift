import Foundation

@main
enum GitLabPulseTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    /// Parses a JSON literal the way the poller does.
    static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: text.data(using: .utf8)!)
    }

    static func mr(_ iid: Int, project: Int, title: String, author: String = "me") -> String {
        """
        {"iid": \(iid), "project_id": \(project), "title": "\(title)",
         "web_url": "https://gitlab.com/group/sub/proj/-/merge_requests/\(iid)",
         "references": {"full": "group/sub/proj!\(iid)"},
         "draft": false, "sha": "abc", "detailed_merge_status": "mergeable",
         "author": {"username": "\(author)"}}
        """
    }

    static func main() {

        // ── Instance URL ──────────────────────────────────────────────────────
        print("GitLab.normalizeBase")
        do {
            check("nil → gitlab.com",        GitLab.normalizeBase(nil) == "https://gitlab.com")
            check("blank → gitlab.com",      GitLab.normalizeBase("  ") == "https://gitlab.com")
            check("trailing slash dropped",  GitLab.normalizeBase("https://git.corp.fr/") == "https://git.corp.fr")
            check("port and sub-path kept, query dropped",
                  GitLab.normalizeBase("https://git.corp.fr:8443/gitlab/?x=1#y") == "https://git.corp.fr:8443/gitlab")
            check("clear text refused off machine", GitLab.normalizeBase("http://git.corp.fr") == nil)
            check("http accepted on localhost",
                  GitLab.normalizeBase("http://localhost:8080") == "http://localhost:8080")
            check("ftp refused",             GitLab.normalizeBase("ftp://git.corp.fr") == nil)
            check("garbage refused",         GitLab.normalizeBase("not a url") == nil)
            check("api url",
                  GitLab.apiURL(base: "https://gitlab.com", path: "user") == "https://gitlab.com/api/v4/user")
        }

        // ── CIState ───────────────────────────────────────────────────────────
        print("CIState init (GitLab)")
        do {
            check("running → pending",   CIState(rawGitLab: "running")  == .pending)
            check("created → pending",   CIState(rawGitLab: "created")  == .pending)
            check("success → success",   CIState(rawGitLab: "success")  == .success)
            check("failed → failure",    CIState(rawGitLab: "failed")   == .failure)
            check("canceled → unknown",  CIState(rawGitLab: "canceled") == .unknown)
            check("manual → unknown",    CIState(rawGitLab: "manual")   == .unknown)
            check("nil → unknown",       CIState(rawGitLab: nil)        == .unknown)
        }

        // ── My merge requests ─────────────────────────────────────────────────
        print("GitLab.parseMyMRs")
        do {
            let list = json("[\(mr(5, project: 10, title: "Add thing")), \(mr(6, project: 10, title: "Fix")), \(mr(5, project: 10, title: "dup"))]")
            let mrs = GitLab.parseMyMRs(list, ci: ["10!5": "failed"])
            check("duplicate id dropped",     mrs.count == 2)
            check("id",                       mrs[0].id == "group/sub/proj!5")
            check("repo",                     mrs[0].repo == "group/sub/proj")
            check("number",                   mrs[0].number == 5)
            check("pipeline failed → failure", mrs[0].ci == .failure)
            check("head sha",                 mrs[0].headSha == "abc")
            check("no pipeline known → unknown", mrs[1].ci == .unknown)
        }

        print("GitLab.parseMR — odd items")
        do {
            let noRefs = json("""
            {"iid": 9, "title": "T", "web_url": "https://gitlab.com/group/sub/proj/-/merge_requests/9"}
            """) as! [String: Any]
            check("repo from the web URL", GitLab.parseMR(noRefs, pipeline: nil, withCI: true)?.repo == "group/sub/proj")
            let missing = json("[{\"iid\": 1, \"title\": \"no url\"}, \(mr(2, project: 3, title: "ok"))]")
            check("item without URL skipped", GitLab.parseMyMRs(missing, ci: [:]).count == 1)
            let draft = json("""
            {"iid": 1, "title": "T", "web_url": "https://gitlab.com/a/b/-/merge_requests/1", "work_in_progress": true}
            """) as! [String: Any]
            check("draft from the old field", GitLab.parseMR(draft, pipeline: nil, withCI: true)?.isDraft == true)
        }

        // ── To review ─────────────────────────────────────────────────────────
        print("GitLab.parseToReview")
        do {
            let theirs = mr(4, project: 1, title: "theirs", author: "bob")
            let mine = mr(3, project: 1, title: "mine", author: "me")
            let out = GitLab.parseToReview(reviewer: json("[\(theirs)]"),
                                           assigned: json("[\(theirs), \(mine)]"), me: "me")
            check("reviewer + assigned merged, mine and duplicates out", out.count == 1)
            check("id",              out.first?.id == "group/sub/proj!4")
            check("review pending",  out.first?.review == .pending)
            check("ci unknown",      out.first?.ci == .unknown)
        }

        // ── Default-branch pipelines ──────────────────────────────────────────
        print("GitLab.parseRepoCI")
        do {
            let project = json("""
            {"path_with_namespace": "me/app", "web_url": "https://gitlab.com/me/app",
             "default_branch": "main", "archived": false}
            """) as! [String: Any]
            let pipeline = json("{\"status\": \"failed\", \"sha\": \"def\"}") as? [String: Any]
            let r = GitLab.parseRepoCI(project, latestPipeline: pipeline)
            check("repo",     r?.repo == "me/app")
            check("branch",   r?.branch == "main")
            check("failed",   r?.ci == .failure)
            check("sha",      r?.headSha == "def")
            check("no pipeline → unknown", GitLab.parseRepoCI(project, latestPipeline: nil)?.ci == .unknown)

            let archived = json("""
            {"path_with_namespace": "a/b", "web_url": "u", "default_branch": "main", "archived": true}
            """) as! [String: Any]
            let empty = json("""
            {"path_with_namespace": "a/c", "web_url": "u", "default_branch": null}
            """) as! [String: Any]
            check("archived left out",             GitLab.parseRepoCI(archived, latestPipeline: nil) == nil)
            check("project without branch left out", GitLab.parseRepoCI(empty, latestPipeline: nil) == nil)
        }

        // ── Stats ─────────────────────────────────────────────────────────────
        print("GitLab.parseStats")
        do {
            let s = GitLab.parseStats(json("[{\"star_count\": 2}, {\"star_count\": 5}, {}]"))
            check("projects", s.repos == 3)
            check("stars",    s.stars == 7)
        }

        // ── The GitHub alert rules apply ──────────────────────────────────────
        print("GitHubPulse.events with GitLab data")
        do {
            let empty = GitHubPulse(login: "me", myPRs: [], toReview: [], mainCI: [], fetchedAt: Date())
            var failing = empty
            failing.myPRs = GitLab.parseMyMRs(json("[\(mr(1, project: 1, title: "T"))]"), ci: ["1!1": "failed"])
            check("first poll is silent", GitHubPulse.events(old: nil, new: failing).isEmpty)
            check("new failing MR → ciFailed",
                  GitHubPulse.events(old: empty, new: failing) == [.ciFailed(prId: "group/sub/proj!1")])
        }

        // ── Dates ─────────────────────────────────────────────────────────────
        print("GitLab dates")
        do {
            check("epoch",           GitLab.daysFromCivil(1970, 1, 1) == 0)
            check("epoch formatted", GitLab.formatDate(0) == "1970-01-01")
            check("leap day round trip", GitLab.formatDate(GitLab.daysFromCivil(2024, 2, 29)) == "2024-02-29")
            check("ISO timestamp",
                  GitLab.parseDate("2026-02-28T10:00:00.000Z") == GitLab.daysFromCivil(2026, 2, 28))
            check("garbage → nil",   GitLab.parseDate("nope") == nil)
            let now = Date(timeIntervalSince1970: Double(GitLab.daysFromCivil(2026, 6, 1)) * 86_400)
            check("events start a year back", GitLab.eventsAfter(now: now) == "2025-05-31")
        }

        // ── Activity grid ─────────────────────────────────────────────────────
        print("GitLab.parseActivity")
        do {
            // 2026-01-14 is a Wednesday.
            let now = Date(timeIntervalSince1970: Double(GitLab.daysFromCivil(2026, 1, 14)) * 86_400 + 3600)
            let events = json("""
            [{"created_at": "2026-01-14T08:00:00.000Z"},
             {"created_at": "2026-01-14T09:00:00.000Z"},
             {"created_at": "2026-01-13T09:00:00.000Z"},
             {"created_at": "2024-01-01T09:00:00.000Z"},
             {"no": "date"}]
            """) as! [[String: Any]]
            let a = GitLab.parseActivity(events: events, now: now)
            check("total counts only the year", a.total == 3)
            check("53 weeks", a.weeks.count == 53)
            let last = a.weeks.last ?? []
            check("last week stops today (Sunday to Wednesday)", last.count == 4)
            check("today's date",    last.last?.date == "2026-01-14")
            check("today: 2 events, level 4, Wednesday",
                  last.last?.count == 2 && last.last?.level == 4 && last.last?.weekday == 3)
            check("yesterday: 1 event, level 2", last[2].count == 1 && last[2].level == 2)
            check("empty day is level 0", last[1].level == 0)
            check("older weeks are complete", a.weeks.dropLast().allSatisfy { $0.count == 7 })
        }

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
