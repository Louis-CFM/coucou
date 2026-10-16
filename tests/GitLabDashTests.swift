import Foundation

@main
enum GitLabDashTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    // MARK: - Fixtures

    static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: text.data(using: .utf8)!)
    }

    static func obj(_ text: String) -> [String: Any] { (json(text) as? [String: Any]) ?? [:] }

    static func detail(_ iid: Int, author: String, state: String = "opened", updated: String = "2026-01-14T08:00:00.000Z",
                       pipeline: String? = "running") -> [String: Any] {
        let head = pipeline.map { "\"head_pipeline\": {\"status\": \"\($0)\"}," } ?? ""
        return obj("""
        {"iid": \(iid), "project_id": 7, "title": "Add thing", "state": "\(state)",
         "web_url": "https://gitlab.com/g/p/-/merge_requests/\(iid)",
         "references": {"full": "g/p!\(iid)"},
         "draft": false, "updated_at": "\(updated)",
         \(head)
         "author": {"username": "\(author)"}}
        """)
    }

    static func note(_ id: Int, _ who: String, _ at: String, _ body: String, system: Bool = false) -> String {
        """
        {"id": \(id), "author": {"username": "\(who)", "name": "\(who.uppercased())"},
         "created_at": "\(at)", "body": "\(body)", "system": \(system)}
        """
    }

    /// A discussion whose notes are given as JSON object texts.
    static func thread(_ id: String, _ notes: [String], resolvable: Bool, resolved: Bool) -> [String: Any] {
        let withFlags = notes.map { n -> String in
            var d = obj(n)
            d["resolvable"] = resolvable
            d["resolved"] = resolved
            return String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!
        }
        return obj("{\"id\": \"\(id)\", \"individual_note\": \(!resolvable), \"notes\": [\(withFlags.joined(separator: ","))]}")
    }

    static func mr() -> GitLabMR {
        GitLab.parseDashMR(detail(5, author: "me"), approvals: nil, unresolved: nil)!
    }

    static func entry(_ iid: Int, _ author: String, state: String = "opened", updated: String) -> GitLabEntry {
        GitLab.buildEntry(detail: detail(iid, author: author, state: state, updated: updated),
                          approvals: obj("{\"approved_by\": [{\"user\": {\"username\": \"me\"}}]}"),
                          discussions: [], me: "me")!
    }

    static let sonarReport = "SonarQube Code Analysis\\nQuality Gate passed\\nIssues  \\n0 New issues  \\n22.2% Coverage on New Code  \\nSee analysis details on SonarQube"

    // MARK: - Main

    static func main() {

        // ── Dates ─────────────────────────────────────────────────────────────
        print("GitLab.parseISOms")
        do {
            check("epoch",                GitLab.parseISOms("1970-01-01T00:00:00.000Z") == 0)
            check("milliseconds",         GitLab.parseISOms("1970-01-01T00:00:01.500Z") == 1500)
            check("offset",               GitLab.parseISOms("1970-01-01T01:00:00.000+01:00") == 0)
            check("no fraction",          GitLab.parseISOms("1970-01-01T00:00:00Z") == 0)
            check("short fraction",       GitLab.parseISOms("1970-01-01T00:00:00.5Z") == 500)
            check("garbage → nil",        GitLab.parseISOms("nope") == nil)
        }

        // ── A line, approvals ─────────────────────────────────────────────────
        print("GitLab.parseDashMR / parseApprovals")
        do {
            let m = GitLab.parseDashMR(detail(5, author: "me"), approvals: GitLabApprovals(given: 1, required: 2), unresolved: 3)
            check("id",                   m?.id == "g/p!5")
            check("project",              m?.project == "g/p" && m?.projectId == 7 && m?.iid == 5)
            check("running pipeline",     m?.ci == .pending)
            check("approvals kept",       m?.approvals == GitLabApprovals(given: 1, required: 2))
            check("update time known",    (m?.updatedAt ?? 0) > 0)
            let a = obj("{\"approvals_required\": 2, \"approved_by\": [{\"user\": {\"username\": \"bob\"}}, {\"user\": {\"username\": \"me\"}}]}")
            let (counts, byMe) = GitLab.parseApprovals(a, me: "me")
            check("2 of 2",               counts == GitLabApprovals(given: 2, required: 2))
            check("I gave one",           byMe)
            let (none, notMe) = GitLab.parseApprovals([:], me: "me")
            check("nothing asked, nothing given", none == GitLabApprovals(given: 0, required: 0) && !notMe)
        }

        // ── Threads waiting for me ────────────────────────────────────────────
        print("GitLab.pendingThreads")
        do {
            let open = [thread("t1", [note(1, "me", "2026-01-14T08:00:00Z", "why?"), note(2, "bob", "2026-01-14T09:00:00Z", "because")],
                               resolvable: true, resolved: false)]
            let (found, unresolved) = GitLab.pendingThreads(discussions: open, me: "me", iAmAuthor: false, mr: mr())
            check("an open thread with their answer waits", found.count == 1 && found[0].id == "t1")
            check("its key follows the last message",       found.first?.key == "t1:2")
            check("both messages",                          found.first?.notes.count == 2)
            check("my message is mine",                     found.first?.notes[0].isMe == true)
            check("author name",                            found.first?.notes[1].author == "BOB")
            check("one open thread",                        unresolved == 1)

            let mineLast = thread("t1", [note(1, "bob", "2026-01-14T08:00:00Z", "q"), note(2, "me", "2026-01-14T09:00:00Z", "a")],
                                  resolvable: true, resolved: false)
            let resolved = thread("t2", [note(3, "bob", "2026-01-14T08:00:00Z", "q")], resolvable: true, resolved: true)
            let (none, count) = GitLab.pendingThreads(discussions: [mineLast, resolved], me: "me", iAmAuthor: true, mr: mr())
            check("my own last word or a resolved thread does not wait", none.isEmpty)
            check("only the open one counts",                            count == 1)

            let theirs = thread("t1", [note(1, "bob", "2026-01-14T08:00:00Z", "x"), note(2, "carol", "2026-01-14T09:00:00Z", "y")],
                                resolvable: true, resolved: false)
            check("someone else's thread I took no part in does not wait",
                  GitLab.pendingThreads(discussions: [theirs], me: "me", iAmAuthor: false, mr: mr()).threads.isEmpty)
            check("but it does on my merge request",
                  GitLab.pendingThreads(discussions: [theirs], me: "me", iAmAuthor: true, mr: mr()).threads.count == 1)

            let withSystem = thread("t1", [note(1, "me", "2026-01-14T08:00:00Z", "q"),
                                           note(2, "bob", "2026-01-14T09:00:00Z", "approved this merge request", system: true)],
                                    resolvable: true, resolved: false)
            check("system notes are no message",
                  GitLab.pendingThreads(discussions: [withSystem], me: "me", iAmAuthor: true, mr: mr()).threads.isEmpty)

            let c1 = thread("c1", [note(1, "bob", "2026-01-14T08:00:00Z", "nice")], resolvable: false, resolved: false)
            let c2 = thread("c2", [note(2, "bob", "2026-01-14T10:00:00Z", "and this")], resolvable: false, resolved: false)
            let reply = thread("r", [note(3, "me", "2026-01-14T09:00:00Z", "thanks")], resolvable: false, resolved: false)
            let plain = GitLab.pendingThreads(discussions: [c1, c2, reply], me: "me", iAmAuthor: true, mr: mr())
            check("a plain comment waits until I write after it", plain.threads.map { $0.id } == ["c2"])
            check("plain comments are not resolvable",            plain.unresolved == 0)
        }

        print("GitLab.pendingThreads — code position")
        do {
            var n = obj(note(1, "bob", "2026-01-14T08:00:00Z", "rename"))
            n["position"] = ["new_path": "src/a.rs", "new_line": 42, "old_path": "src/a.rs", "head_sha": "H", "base_sha": "B"]
            let t = thread("t1", [String(data: try! JSONSerialization.data(withJSONObject: n), encoding: .utf8)!],
                           resolvable: true, resolved: false)
            let found = GitLab.pendingThreads(discussions: [t], me: "me", iAmAuthor: true, mr: mr()).threads
            check("new side",  found.first?.position == GitLabCodePosition(file: "src/a.rs", line: 42, side: "new", sha: "H"))
            var removed = obj(note(2, "bob", "2026-01-14T08:00:00Z", "why drop"))
            removed["position"] = ["new_path": "src/a.rs", "old_path": "src/a.rs", "old_line": 9, "head_sha": "H", "base_sha": "B"]
            let t2 = thread("t2", [String(data: try! JSONSerialization.data(withJSONObject: removed), encoding: .utf8)!],
                            resolvable: true, resolved: false)
            let found2 = GitLab.pendingThreads(discussions: [t2], me: "me", iAmAuthor: true, mr: mr()).threads
            check("old side at the base commit",
                  found2.first?.position == GitLabCodePosition(file: "src/a.rs", line: 9, side: "old", sha: "B"))
        }

        // ── Automated messages ────────────────────────────────────────────────
        print("GitLab.isAutomated / isAutomatedText")
        do {
            func user(_ username: String, _ name: String) -> [String: Any] { ["username": username, "name": name] }
            for (u, n) in [("sonarqube", "SonarQube"), ("svc-sonar", "Analysis service"), ("jenkins", "SonarCloud"),
                           ("project_123_bot_a1b2c3", "ci-token"), ("group_9_bot", "x"), ("dependabot", "Dependabot"),
                           ("renovate-bot", "Renovate Bot"), ("ci", "Release [bot]"), ("codecov", "Codecov")] {
                check("\(u) / \(n) is automated", GitLab.isAutomated(author: user(u, n)))
            }
            for (u, n) in [("bob", "Bob Martin"), ("jtalbot", "John Talbot"), ("abbot", "Anne Abbot"),
                           ("robotics-team", "Robotics Team"), ("elodie", "Élodie Botrel"), ("projet_x", "Project X")] {
                check("\(u) / \(n) is a person", !GitLab.isAutomated(author: user(u, n)))
            }
            check("GitLab's own bot flag", GitLab.isAutomated(author: ["username": "ci", "name": "CI", "bot": true]))
            check("no author",             !GitLab.isAutomated(author: nil))

            check("SonarQube's report",    GitLab.isAutomatedText(sonarReport.replacingOccurrences(of: "\\n", with: "\n")))
            check("SonarCloud, indented",  GitLab.isAutomatedText("  SonarCloud Quality Gate failed"))
            check("quality gate and sonar", GitLab.isAutomatedText("Quality Gate failed\nsee Sonar for details"))
            check("bold SonarQube",        GitLab.isAutomatedText("**SonarQube** found 3 issues"))
            check("a person talking about Sonar",
                  !GitLab.isAutomatedText("Sonar says it is fine, but I disagree with the naming here"))
            check("a quality gate of ours", !GitLab.isAutomatedText("The quality gate of our pipeline is too strict"))
            check("a plain question",       !GitLab.isAutomatedText("why this?"))

            // Posted from an ordinary account, as in the wild: only the text gives it away.
            let report = thread("t1", [note(1, "adminMeyclub", "2026-01-14T08:00:00Z", sonarReport)], resolvable: false, resolved: false)
            let r = GitLab.pendingThreads(discussions: [report], me: "me", iAmAuthor: true, mr: mr())
            check("a report from an ordinary account is not shown", r.threads.isEmpty && r.unresolved == 0)
            let real = thread("t2", [note(2, "adminMeyclub", "2026-01-14T09:00:00Z", "please rename this")], resolvable: false, resolved: false)
            check("a real comment from the same account is",
                  GitLab.pendingThreads(discussions: [real], me: "me", iAmAuthor: true, mr: mr()).threads.count == 1)

            let answered = thread("t3", [note(1, "sonarqube", "2026-01-14T08:00:00Z", "Quality Gate failed"),
                                         note(2, "bob", "2026-01-14T09:00:00Z", "a false positive?")],
                                  resolvable: true, resolved: false)
            let a = GitLab.pendingThreads(discussions: [answered], me: "me", iAmAuthor: true, mr: mr())
            check("a person answering a bot is heard, alone", a.threads.count == 1 && a.threads[0].notes.count == 1
                  && a.threads[0].notes[0].username == "bob")
            let after = thread("t4", [note(1, "bob", "2026-01-14T08:00:00Z", "please fix"),
                                      note(2, "me", "2026-01-14T09:00:00Z", "done"),
                                      note(3, "sonarqube", "2026-01-14T10:00:00Z", "Quality Gate passed")],
                               resolvable: true, resolved: false)
            check("a bot after my answer does not bring the thread back",
                  GitLab.pendingThreads(discussions: [after], me: "me", iAmAuthor: true, mr: mr()).threads.isEmpty)
        }

        // ── An entry and the lists ────────────────────────────────────────────
        print("GitLab.buildEntry / buildDashboard")
        do {
            let d = [thread("t1", [note(1, "bob", "2026-01-14T08:00:00Z", "x")], resolvable: true, resolved: false)]
            let a = obj("{\"approvals_required\": 1, \"approved_by\": [{\"user\": {\"username\": \"me\"}}]}")
            let e = GitLab.buildEntry(detail: detail(5, author: "me"), approvals: a, discussions: d, me: "me")
            check("threads and unresolved count", e?.threads.count == 1 && e?.mr.unresolved == 1)
            check("approved by me, open, author", e?.approvedByMe == true && e?.open == true && e?.author == "me")
            let unread = GitLab.buildEntry(detail: detail(6, author: "me"), approvals: nil, discussions: nil, me: "me")
            check("discussions not read", unread?.mr.unresolved == nil)

            let entries: [(entry: GitLabEntry, roles: GitLabRoles)] = [
                (entry(1, "me", updated: "2026-01-14T08:00:00Z"), GitLabRoles()),
                (entry(2, "bob", updated: "2026-01-14T09:00:00Z"), GitLabRoles(reviewer: true)),
                (entry(3, "bob", updated: "2026-01-14T10:00:00Z"), GitLabRoles(assigned: true)),
                (entry(4, "bob", updated: "2026-01-14T11:00:00Z"), GitLabRoles(approvedEvent: true)),
                (entry(5, "bob", state: "merged", updated: "2026-01-14T12:00:00Z"),
                 GitLabRoles(reviewer: true, approvedEvent: true)),
            ]
            let dash = GitLab.buildDashboard(me: "me", baseURL: "https://gitlab.com", canWrite: true, entries: entries, nowMs: 99)
            check("mine",                 dash.mine.map { $0.iid } == [1])
            check("to review, newest first", dash.toReview.map { $0.iid } == [3, 2])
            check("approved, merged left out", dash.approved.map { $0.iid } == [4])
            check("the rest",             dash.me == "me" && dash.canWrite == true && dash.fetchedAt == 99
                  && dash.baseURL == "https://gitlab.com")

            var taken = entry(4, "bob", updated: "2026-01-14T11:00:00Z")
            taken.approvedByMe = false
            let none = GitLab.buildDashboard(me: "me", baseURL: "u", canWrite: nil,
                                             entries: [(taken, GitLabRoles(approvedEvent: true))], nowMs: 1)
            check("an approval taken back is no longer listed", none.approved.isEmpty)
        }

        // ── Alerts ────────────────────────────────────────────────────────────
        print("GitLab.events")
        do {
            func t(_ id: String, _ last: Int) -> GitLabThread {
                GitLabThread(id: id, key: "\(id):\(last)", project: "g/p", projectId: 7, mrIid: 5, mrRef: "g/p!5",
                             mrTitle: "T", mrUrl: "", resolvable: true, notes: [], position: nil, lastAt: 0)
            }
            let empty = GitLab.buildDashboard(me: "me", baseURL: "u", canWrite: nil, entries: [], nowMs: 0)
            var old = empty; old.comments = [t("a", 1)]
            var new = empty; new.comments = [t("a", 1), t("b", 3)]
            check("first poll is silent", GitLab.events(old: nil, new: new).isEmpty)
            check("a new thread",         GitLab.events(old: old, new: new) == [.commentPending(threadId: "b")])
            new.comments = [t("a", 2)]
            check("a new answer brings a thread back", GitLab.events(old: old, new: new) == [.commentPending(threadId: "a")])
            new.comments = []
            check("a thread that went away raises nothing", GitLab.events(old: old, new: new).isEmpty)
        }

        // ── Candidates, snippets, cache ───────────────────────────────────────
        print("GitLab.eventTargets / snippet / isFresh")
        do {
            let events = json("""
            [{"project_id": 1, "target_type": "MergeRequest", "target_iid": 10, "action_name": "approved"},
             {"project_id": 1, "target_type": "DiffNote", "action_name": "commented on",
              "note": {"noteable_type": "MergeRequest", "noteable_iid": 11}},
             {"project_id": 1, "target_type": "Note", "note": {"noteable_type": "Issue", "noteable_iid": 12}},
             {"project_id": 1, "target_type": "MergeRequest", "target_iid": 10},
             {"project_id": 2, "target_type": "MergeRequest", "target_iid": 3},
             {"target_type": "MergeRequest", "target_iid": 99}]
            """)
            let all = GitLab.eventTargets(events, max: 10).map { "\($0.project)!\($0.iid)" }
            check("merge requests my events point at", all == ["1!10", "1!11", "2!3"])
            check("at most max",   GitLab.eventTargets(events, max: 2).count == 2)
            check("nothing",       GitLab.eventTargets(nil, max: 5).isEmpty)

            let text = "a\nb\nc\nd\ne\nf\ng\n"
            let s = GitLab.snippet(text: text, line: 4, context: 2)
            check("the lines around",  s.map { $0.number } == [2, 3, 4, 5, 6])
            check("the target line",   s.first { $0.target }?.text == "d")
            check("near the top",      GitLab.snippet(text: text, line: 1, context: 2).map { $0.number } == [1, 2, 3])
            check("past the end",      GitLab.snippet(text: text, line: 40, context: 2).isEmpty)
            check("line 0",            GitLab.snippet(text: text, line: 0, context: 2).isEmpty)
            check("long lines cut",    GitLab.snippet(text: String(repeating: "x", count: 1000), line: 1, context: 0)[0].text.count == 300)

            var e = entry(1, "me", updated: "2026-01-14T08:00:00Z")
            e.mr.ci = .success
            check("fresh while nothing moved",
                  GitLab.isFresh(cached: ("2026-01-14T08:00:00Z", e), updatedAt: "2026-01-14T08:00:00Z"))
            check("the merge request changed",
                  !GitLab.isFresh(cached: ("2026-01-14T08:00:00Z", e), updatedAt: "2026-01-14T09:00:00Z"))
            check("unknown update time: read again", !GitLab.isFresh(cached: ("2026-01-14T08:00:00Z", e), updatedAt: nil))
            check("no cache",                        !GitLab.isFresh(cached: nil, updatedAt: "2026-01-14T08:00:00Z"))
            e.mr.ci = .pending
            check("pipeline still running", !GitLab.isFresh(cached: ("2026-01-14T08:00:00Z", e), updatedAt: "2026-01-14T08:00:00Z"))
        }

        // ── +N and the colour of what waits ───────────────────────────────────
        print("GitLabPanelState")
        do {
            func dash(comments: [GitLabThread] = [], review: [GitLabMR] = []) -> GitLabDashboard {
                var d = GitLab.buildDashboard(me: "me", baseURL: "u", canWrite: nil, entries: [], nowMs: 0)
                d.comments = comments; d.toReview = review
                return d
            }
            func th(_ id: String, _ last: Int = 1) -> GitLabThread {
                GitLabThread(id: id, key: "\(id):\(last)", project: "g/p", projectId: 7, mrIid: 5, mrRef: "g/p!5",
                             mrTitle: "T", mrUrl: "", resolvable: true, notes: [], position: nil, lastAt: 0)
            }
            func m(_ iid: Int) -> GitLabMR { GitLab.parseDashMR(detail(iid, author: "bob"), approvals: nil, unresolved: nil)! }

            check("what asks for an action comes first", GitLabSection.order == [.comments, .toReview, .mine, .approved])
            let d = dash(comments: [th("a")], review: [m(1)])
            check("comments and review take the colour",
                  GitLabSection.order.map { $0.waiting(d) } == [true, true, false, false])
            check("counts", GitLabSection.order.map { $0.count(d) } == [1, 1, 0, 0])
            check("a thread is told by its last message", GitLabSection.comments.itemIds(dash(comments: [th("a", 4)])) == ["a:4"])

            var state = GitLabPanelState().receiving(d)
            check("the first data counts as seen",
                  state.initialized && GitLabSection.order.allSatisfy { state.newCount($0, dash: d) == 0 })
            check("no badge before any data", GitLabPanelState().newCount(.toReview, dash: d) == 0)

            let later = dash(comments: [th("a")], review: [m(1), m(2), m(3)])
            state = state.receiving(later)
            check("what arrives in a closed section is new", state.newCount(.toReview, dash: later) == 2)
            state = state.toggling(.toReview, dash: later)
            check("opening clears it",           state.newCount(.toReview, dash: later) == 0 && state.isOpen(.toReview))
            state = state.toggling(.toReview, dash: later)
            check("closing it keeps it seen",    !state.isOpen(.toReview) && state.newCount(.toReview, dash: later) == 0)

            var open = GitLabPanelState().receiving(dash()).toggling(.comments, dash: dash())
            let withComment = dash(comments: [th("a")])
            open = open.receiving(withComment)
            check("what arrives in an open section is seen at once", open.newCount(.comments, dash: withComment) == 0)

            let answered = GitLabPanelState().receiving(dash(comments: [th("a", 2)]))
            let newAnswer = dash(comments: [th("a", 5)])
            check("a new answer in a thread is new again",
                  answered.receiving(newAnswer).newCount(.comments, dash: newAnswer) == 1)

            let data = try! JSONEncoder().encode(state)
            check("it is kept as it was", (try? JSONDecoder().decode(GitLabPanelState.self, from: data)) == state)
        }

        // ── Words ─────────────────────────────────────────────────────────────
        print("GitLabPanelText")
        do {
            let now = Date(timeIntervalSince1970: 10 * 86_400)
            let nowMs = 10 * 86_400_000
            check("no date, no age",     GitLabPanelText.age(ms: 0, now: now) == "")
            check("just now",            GitLabPanelText.age(ms: nowMs - 30_000, now: now) == "just now")
            check("minutes",             GitLabPanelText.age(ms: nowMs - 5 * 60_000, now: now) == "5m")
            check("hours",               GitLabPanelText.age(ms: nowMs - 3 * 3_600_000, now: now) == "3h")
            check("days",                GitLabPanelText.age(ms: nowMs - 2 * 86_400_000, now: now) == "2d")
            check("approvals asked",     GitLabPanelText.approvals(GitLabApprovals(given: 1, required: 2)) == "1/2")
            check("approvals given",     GitLabPanelText.approvals(GitLabApprovals(given: 1, required: 0)) == "✓ 1")
            check("no approvals",        GitLabPanelText.approvals(GitLabApprovals(given: 0, required: 0)) == nil)
            check("no approvals data",   GitLabPanelText.approvals(nil) == nil)
            check("short project",       GitLabPanelText.shortProject("group/sub/proj") == "proj")
            check("initials of two words", GitLabPanelText.initials("Jane Doe") == "JD")
            check("initials of one",     GitLabPanelText.initials("bob") == "B")
            check("initials of a login", GitLabPanelText.initials("anne-marie.dupont") == "AD")
            check("initials of nothing", GitLabPanelText.initials("  ") == "?")
            check("same hue every time", GitLabPanelText.avatarHue("bob") == GitLabPanelText.avatarHue("bob"))
            check("another person, another hue", GitLabPanelText.avatarHue("bob") != GitLabPanelText.avatarHue("alice"))
            check("hue in range",        (0..<360).contains(GitLabPanelText.avatarHue("anyone")))

            let thr = GitLabThread(id: "a", key: "a:9", project: "g/p", projectId: 7, mrIid: 5, mrRef: "g/p!5", mrTitle: "T",
                                   mrUrl: "https://gitlab.com/g/p/-/merge_requests/5", resolvable: true,
                                   notes: [GitLabThreadNote(id: 9, author: "Bob", username: "bob",
                                                            body: "line one\n\n  line   two", createdAt: 0, isMe: false)],
                                   position: nil, lastAt: 0)
            check("preview on one line", GitLabPanelText.preview(thr) == "line one line two")
            check("preview cut",         GitLabPanelText.preview(thr, max: 6) == "line …")
            check("link to a message",   GitLabPanelText.noteURL(thr) == "https://gitlab.com/g/p/-/merge_requests/5#note_9")

            let base = "https://git.corp.fr"
            check("a link on the instance opens",
                  GitLabPanelText.safeInstanceURL("https://git.corp.fr/a/-/merge_requests/1", base: base) != nil)
            check("another host does not",      GitLabPanelText.safeInstanceURL("https://evil.example/x", base: base) == nil)
            check("javascript does not",        GitLabPanelText.safeInstanceURL("javascript:alert(1)", base: base) == nil)
            check("another port is another host", GitLabPanelText.safeInstanceURL("https://git.corp.fr:8443/x", base: base) == nil)
        }

        // ── Dates for the events poll ─────────────────────────────────────────
        print("GitLab.dateDaysAgo")
        do {
            let now = GitLab.daysFromCivil(2026, 6, 1) * 86_400_000
            check("60 days back", GitLab.dateDaysAgo(nowMs: now, days: 60) == "2026-04-02")
            check("14 days back", GitLab.dateDaysAgo(nowMs: now, days: 14) == "2026-05-18")
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
