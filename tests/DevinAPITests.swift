import Foundation

@main
enum DevinAPITests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    // MARK: - Fixtures

    /// Representative /v3/self response for a Personal Access Token.
    static let selfJSON: Data = """
    {
      "principal_type": "pat_user",
      "user_id": "user_abc123",
      "user_name": "Test User",
      "api_key_id": "key_1",
      "api_key_name": "Coucou",
      "org_id": null,
      "devin_sessions_org_id": "org-abc123def456"
    }
    """.data(using: .utf8)!

    /// /v3/self for a PAT whose account has no Devin sessions organization.
    static let selfNoOrgJSON: Data = """
    {
      "principal_type": "pat_user",
      "user_id": "user_abc123",
      "user_name": "Test User",
      "api_key_id": "key_1",
      "api_key_name": "Coucou",
      "org_id": null,
      "devin_sessions_org_id": null
    }
    """.data(using: .utf8)!

    /// One session per documented shape we care about: waiting, running, exit,
    /// suspended on a quota, with optional fields absent on one of them.
    static func sessionJSON(id: String, status: String, detail: String?,
                            title: String?, updated: Int, prs: [[String: Any]]? = nil) -> [String: Any] {
        var obj: [String: Any] = [
            "session_id": id,
            "url": "https://app.devin.ai/sessions/\(id)",
            "status": status,
            "tags": [],
            "org_id": "org-abc123def456",
            "created_at": updated - 600,
            "updated_at": updated,
            "acus_consumed": 1.5,
            "pull_requests": prs ?? [],
        ]
        if let detail { obj["status_detail"] = detail }
        if let title  { obj["title"] = title }
        return obj
    }

    static func pageData(_ items: [[String: Any]],
                         hasNext: Bool = false, cursor: String? = nil) -> Data {
        var root: [String: Any] = ["items": items, "has_next_page": hasNext]
        if let cursor { root["end_cursor"] = cursor }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    static func epoch(_ secondsAgo: TimeInterval, from now: Date) -> Int {
        Int(now.timeIntervalSince1970 - secondsAgo)
    }

    // MARK: - Identity

    static func testIdentity() {
        print("DevinIdentity.parse")
        do {
            let me = DevinIdentity.parse(selfJSON)
            check("parse returns non-nil",          me != nil)
            check("principal_type",                 me?.principalType == "pat_user")
            check("user_id",                        me?.userId == "user_abc123")
            check("user_name",                      me?.userName == "Test User")
            check("sessionsOrgId",                  me?.sessionsOrgId == "org-abc123def456")

            let noOrg = DevinIdentity.parse(selfNoOrgJSON)
            check("no-org account parses",           noOrg != nil)
            check("no-org account has nil org",      noOrg?.sessionsOrgId == nil)

            check("garbage → nil",        DevinIdentity.parse("garbage".data(using: .utf8)!) == nil)
            check("empty obj → nil",      DevinIdentity.parse("{}".data(using: .utf8)!) == nil)
            check("missing user_id → nil",
                  DevinIdentity.parse(#"{"principal_type":"pat_user","user_name":"u"}"#.data(using: .utf8)!) == nil)
        }
    }

    // MARK: - Session page

    static func testPage() {
        print("DevinSessionPage.parse")
        let now = Date()
        let items = [
            sessionJSON(id: "devin-aaa", status: "running", detail: "waiting_for_user",
                        title: "Fix login", updated: epoch(5, from: now)),
            sessionJSON(id: "devin-bbb", status: "running", detail: "working",
                        title: nil, updated: epoch(30, from: now)),
            sessionJSON(id: "devin-ccc", status: "exit", detail: nil,
                        title: "Old task", updated: epoch(10, from: now)),
        ]
        do {
            let page = DevinSessionPage.parse(pageData(items, hasNext: true, cursor: "cur=1"))
            check("parse returns non-nil",       page != nil)
            check("3 items",                     page?.items.count == 3)
            check("has_next_page",               page?.hasNextPage == true)
            check("end_cursor",                 page?.endCursor == "cur=1")

            let first = page?.items.first { $0.id == "devin-aaa" }
            check("session_id",                  first?.id == "devin-aaa")
            check("url from the API",            first?.url == "https://app.devin.ai/sessions/devin-aaa")
            check("title",                       first?.title == "Fix login")
            check("createdAt",                    first?.createdAt != nil)
            check("updatedAt",                    first?.updatedAt != nil)
            check("no title → empty string",
                  page?.items.first { $0.id == "devin-bbb" }?.title == "")
            check("no status_detail → nil",
                  page?.items.first { $0.id == "devin-ccc" }?.statusDetail == nil)
        }

        print("DevinSessionPage.parse — pull requests")
        do {
            let items = [sessionJSON(id: "devin-pr1", status: "exit", detail: nil, title: "PR task",
                                    updated: epoch(5, from: now),
                                    prs: [["pr_url": "https://github.com/o/r/pull/1", "pr_state": "open"]])]
            let page = DevinSessionPage.parse(pageData(items))
            check("1 PR parsed",   page?.items.first?.pullRequests.count == 1)
            check("PR url",        page?.items.first?.pullRequests.first?.url == "https://github.com/o/r/pull/1")
            check("PR state",      page?.items.first?.pullRequests.first?.state == "open")
        }

        print("DevinSessionPage.parse — malformed, partial and duplicates")
        do {
            check("garbage → nil",           DevinSessionPage.parse("garbage".data(using: .utf8)!) == nil)
            check("empty obj → nil",         DevinSessionPage.parse("{}".data(using: .utf8)!) == nil)

            // Item missing session_id is skipped, the healthy one survives.
            let bad = sessionJSON(id: "", status: "running", detail: nil, title: nil, updated: 100)
            let good = sessionJSON(id: "devin-ok", status: "running", detail: "working",
                                   title: "Fine", updated: 100)
            let page = DevinSessionPage.parse(pageData([bad, good]))
            check("malformed item skipped",   page?.items.count == 1)
            check("healthy item kept",       page?.items.first?.id == "devin-ok")

            // Duplicate session ids keep the first occurrence only.
            let dupA = sessionJSON(id: "devin-dup", status: "running", detail: "working",
                                   title: "First", updated: 100)
            let dupB = sessionJSON(id: "devin-dup", status: "exit", detail: nil,
                                   title: "Second", updated: 100)
            let dupPage = DevinSessionPage.parse(pageData([dupA, dupB]))
            check("duplicate id deduped",     dupPage?.items.count == 1)
            check("duplicate keeps first",   dupPage?.items.first?.title == "First")
        }

        print("DevinSessionPage.parse — unknown future status value")
        do {
            // The API adds a status we have never heard of: parsing must still work.
            let future = sessionJSON(id: "devin-future", status: "queued_v4", detail: "new_detail",
                                     title: "Future", updated: 100)
            let page = DevinSessionPage.parse(pageData([future]))
            check("unknown status still parses",   page?.items.count == 1)
            check("unknown status → .unknown",     page?.items.first?.phase == .unknown)
        }
    }

    // MARK: - Phase mapping

    static func testPhases() {
        print("DevinPhase — documented status mapping")
        do {
            check("new → starting",                    DevinPhase(status: "new", detail: nil) == .starting)
            check("claimed → starting",                 DevinPhase(status: "claimed", detail: nil) == .starting)
            check("resuming → starting",                DevinPhase(status: "resuming", detail: nil) == .starting)
            check("running+working → working",         DevinPhase(status: "running", detail: "working") == .working)
            check("running+nil → working",             DevinPhase(status: "running", detail: nil) == .working)
            check("running+waiting_for_user → waiting",
                  DevinPhase(status: "running", detail: "waiting_for_user") == .waitingForUser)
            check("running+waiting_for_approval → waiting",
                  DevinPhase(status: "running", detail: "waiting_for_approval") == .waitingForApproval)
            check("running+finished → finished",       DevinPhase(status: "running", detail: "finished") == .finished)
            check("exit → finished",                   DevinPhase(status: "exit", detail: nil) == .finished)
            check("error → failed",                    DevinPhase(status: "error", detail: nil) == .failed)
            check("suspended+error → failed",          DevinPhase(status: "suspended", detail: "error") == .failed)
            check("suspended+payment_declined → failed",
                  DevinPhase(status: "suspended", detail: "payment_declined") == .failed)
            check("suspended+usage_limit_exceeded → rateLimited",
                  DevinPhase(status: "suspended", detail: "usage_limit_exceeded") == .rateLimited)
            check("suspended+out_of_credits → rateLimited",
                  DevinPhase(status: "suspended", detail: "out_of_credits") == .rateLimited)
            check("suspended+user_usage_limit_exceeded → rateLimited",
                  DevinPhase(status: "suspended", detail: "user_usage_limit_exceeded") == .rateLimited)
            check("suspended+inactivity → ended",      DevinPhase(status: "suspended", detail: "inactivity") == .ended)
            check("suspended+user_request → ended",     DevinPhase(status: "suspended", detail: "user_request") == .ended)
            check("suspended+nil → ended",              DevinPhase(status: "suspended", detail: nil) == .ended)
            check("unknown status → unknown",          DevinPhase(status: "migrated", detail: nil) == .unknown)
            check("nil status → unknown",              DevinPhase(status: nil, detail: nil) == .unknown)
            check("running+unknown detail → working",  DevinPhase(status: "running", detail: "brand_new") == .working)
        }

        print("DevinPhase — properties")
        do {
            check("waiting_for_user is attention",      DevinPhase.waitingForUser.isAttention)
            check("waiting_for_approval is attention",  DevinPhase.waitingForApproval.isAttention)
            check("working is not attention",          !DevinPhase.working.isAttention)
            check("working is live",                   DevinPhase.working.isLive)
            check("starting is live",                  DevinPhase.starting.isLive)
            check("waiting is live",                   DevinPhase.waitingForUser.isLive)
            check("rateLimited is live (suspended, resumable)", DevinPhase.rateLimited.isLive)
            check("unknown is live (degrade to active)", DevinPhase.unknown.isLive)
            check("finished is terminal",              DevinPhase.finished.isTerminal)
            check("failed is terminal",                 DevinPhase.failed.isTerminal)
            check("ended is terminal",                 DevinPhase.ended.isTerminal)
            check("finished is not live",               !DevinPhase.finished.isLive)
        }
    }

    // MARK: - Tracker lifecycle

    static func testTracker() {
        let now = Date()
        let ago = { (s: TimeInterval) in epoch(s, from: now) }

        print("DevinTracker — first poll is silent")
        do {
            var tracker = DevinTracker()
            let page = DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-a", status: "running", detail: "working", title: "A", updated: ago(10)),
            ]))!
            let events = tracker.ingest(page, now: now)
            check("first poll → no events",     events.isEmpty)
            check("first poll adopts session", tracker.totalCount == 1)
        }

        print("DevinTracker — old finished sessions are ignored at launch")
        do {
            var tracker = DevinTracker()
            let page = DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-old", status: "exit", detail: nil, title: "Old", updated: ago(3600)),
            ]))!
            _ = tracker.ingest(page, now: now)
            check("stale terminal not tracked",   tracker.totalCount == 0)
        }

        print("DevinTracker — state transitions")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-t1", status: "running", detail: "working", title: "T1", updated: ago(120)),
            ]))!, now: now)

            // working → waiting for the user
            let waiting = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-t1", status: "running", detail: "waiting_for_user", title: "T1", updated: ago(5)),
            ]))!, now: now)
            check("working → 1 event",                       waiting.count == 1)
            check("working → waiting event",                  waiting.first?.kind == .waiting)
            check("waiting attention in aggregate",          tracker.aggregatePhase == .waitingForUser)

            // same state again → no duplicate events
            let same = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-t1", status: "running", detail: "waiting_for_user", title: "T1", updated: ago(2)),
            ]))!, now: now)
            check("unchanged state → no event",               same.isEmpty)

            // waiting → finished
            let done = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-t1", status: "exit", detail: nil, title: "T1", updated: ago(1)),
            ]))!, now: now)
            check("waiting → finished event",                 done.first?.kind == .finished)
            check("finished aggregate",                       tracker.aggregatePhase == .finished)

            // terminal session ages out of the pill
            let later = now.addingTimeInterval(DevinTracker.terminalWindow + 5)
            let aged = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-t1", status: "exit", detail: nil, title: "T1", updated: ago(1)),
            ]))!, now: later)
            check("aging out is silent",                       aged.isEmpty)
            check("aged out of the tracker",                   tracker.totalCount == 0)
            check("empty tracker → nil aggregate",              tracker.aggregatePhase == nil)
        }

        print("DevinTracker — new session and PR events")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-n1", status: "running", detail: "working", title: "N1", updated: ago(60)),
            ]))!, now: now)

            let withPR = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-n1", status: "running", detail: "working", title: "N1", updated: ago(10),
                            prs: [["pr_url": "https://github.com/o/r/pull/9", "pr_state": "open"]]),
            ]))!, now: now)
            check("PR appears → prReady event",                 withPR.first?.kind == .prReady)

            let newcomer = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-n1", status: "running", detail: "working", title: "N1", updated: ago(10),
                            prs: [["pr_url": "https://github.com/o/r/pull/9", "pr_state": "open"]]),
                sessionJSON(id: "devin-n2", status: "running", detail: "working", title: "N2", updated: ago(3)),
            ]))!, now: now)
            check("new session → started event",                newcomer.contains { $0.kind == .started && $0.sessionId == "devin-n2" })

            // A session already finished before Coucou watched is not "started" news.
            let preFinished = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-n1", status: "running", detail: "working", title: "N1", updated: ago(10),
                            prs: [["pr_url": "https://github.com/o/r/pull/9", "pr_state": "open"]]),
                sessionJSON(id: "devin-n2", status: "running", detail: "working", title: "N2", updated: ago(3)),
                sessionJSON(id: "devin-late", status: "exit", detail: nil, title: "Late", updated: ago(30)),
            ]))!, now: now)
            check("late finished session → no started event",
                  !preFinished.contains { $0.sessionId == "devin-late" })
        }

        print("DevinTracker — session disappears while live")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-gone", status: "running", detail: "working", title: "Gone", updated: ago(30)),
            ]))!, now: now)
            let events = tracker.ingest(DevinSessionPage.parse(pageData([]))!, now: now)
            check("disappeared live session → suspended event",
                  events.first?.kind == .suspended && events.first?.sessionId == "devin-gone")
            check("session removed from tracker",       tracker.totalCount == 0)
        }

        print("DevinTracker — reset")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-r1", status: "running", detail: "working", title: "R1", updated: ago(30)),
            ]))!, now: now)
            let ids = tracker.reset()
            check("reset returns watched ids",          ids == ["devin-r1"])
            check("reset empties the tracker",           tracker.totalCount == 0)
            check("reset forgets the first poll",        tracker.firstPollDone == false)
        }
    }

    // MARK: - Multiple concurrent sessions

    static func testMultipleSessions() {
        let now = Date()
        let ago = { (s: TimeInterval) in epoch(s, from: now) }
        let session = { (id: String, status: String, detail: String?, title: String, updatedAgo: TimeInterval) in
            sessionJSON(id: id, status: status, detail: detail, title: title, updated: ago(updatedAgo))
        }

        print("DevinTracker — three concurrent sessions stay isolated")
        do {
            var tracker = DevinTracker()
            // A working, B waiting, C just exited.
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-a", "running", "working", "A", 300),
                session("devin-b", "running", "waiting_for_user", "B", 200),
                session("devin-c", "exit", nil, "C", 20),
            ]))!, now: now)
            check("3 sessions tracked",                       tracker.totalCount == 3)
            check("waiting wins the aggregate",                tracker.aggregatePhase == .waitingForUser)
            check("B is the lead session",                     tracker.leadSession?.id == "devin-b")

            // B resolves: A keeps working, C's completion must not hide it.
            let events = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-a", "running", "working", "A", 90),
                session("devin-b", "running", "working", "B", 80),
                session("devin-c", "exit", nil, "C", 20),
            ]))!, now: now)
            check("B working → 1 event only",                  events.count == 1 && events.first?.sessionId == "devin-b")
            check("A still tracked",                          tracker.sessions["devin-a"] != nil)
            check("A still working",                           tracker.sessions["devin-a"]?.phase == .working)
            check("C still tracked (fresh terminal)",         tracker.sessions["devin-c"] != nil)
            check("aggregate → working after B resumes",      tracker.aggregatePhase == .working)
            check("B is the lead (most recent working)",      tracker.leadSession?.id == "devin-b")

            // A fails while B keeps working: error outranks working in the pill.
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-a", "error", nil, "A", 10),
                session("devin-b", "running", "working", "B", 5),
                session("devin-c", "exit", nil, "C", 20),
            ]))!, now: now)
            check("error wins the aggregate",                  tracker.aggregatePhase == .failed)
            check("B untouched by A's failure",               tracker.sessions["devin-b"]?.phase == .working)
        }

        print("DevinTracker — usage-limited session surfaces")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-q1", "suspended", "user_usage_limit_exceeded", "Q1", 60),
            ]))!, now: now)
            check("quota suspension → rateLimited aggregate",  tracker.aggregatePhase == .rateLimited)
            check("suspended session stays watched",          tracker.totalCount == 1)
        }
    }

    // MARK: - Schedule

    static func testSchedule() {
        print("DevinSchedule — cadence and backoff")
        do {
            check("active interval",           DevinSchedule.nextDelay(hasLive: true,  consecutiveErrors: 0, retryAfter: nil) == DevinSchedule.activeInterval)
            check("discovery interval",       DevinSchedule.nextDelay(hasLive: false, consecutiveErrors: 0, retryAfter: nil) == DevinSchedule.discoveryInterval)
            check("first error backs off",     DevinSchedule.nextDelay(hasLive: true,  consecutiveErrors: 1, retryAfter: nil) == DevinSchedule.backoffFloor)
            check("errors double the delay",
                  DevinSchedule.nextDelay(hasLive: false, consecutiveErrors: 3, retryAfter: nil) == DevinSchedule.backoffFloor * 4)
            check("backoff caps at the ceiling",
                  DevinSchedule.backoffDelay(consecutiveErrors: 20) == DevinSchedule.backoffCeiling)
            check("Retry-After is honored",
                  DevinSchedule.nextDelay(hasLive: true, consecutiveErrors: 0, retryAfter: 90) == 90)
            check("Retry-After is capped",
                  DevinSchedule.nextDelay(hasLive: true, consecutiveErrors: 0, retryAfter: 9999) == DevinSchedule.backoffCeiling)
        }
    }

    // MARK: - Discovery + by-id refresh

    static func testDiscoveryRefresh() {
        let now = Date()
        let ago = { (s: TimeInterval) in epoch(s, from: now) }

        print("DevinSessionPage.merge — crowded-out session stays watched")
        do {
            // Tracked session adopted on the first poll.
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-tracked", status: "running", detail: "working",
                            title: "Tracked", updated: ago(120)),
            ]))!, now: now)
            check("tracked session adopted",               tracker.sessions["devin-tracked"] != nil)

            // Later poll: the discovery page (first 200) no longer contains it —
            // 200 newer sessions pushed it out — but the by-id refresh does.
            let discovery = DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-new", status: "running", detail: "working",
                            title: "New", updated: ago(10)),
            ]))!
            let refresh = DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-tracked", status: "running", detail: "working",
                            title: "Tracked", updated: ago(40)),
            ]))!
            let events = tracker.ingest(DevinSessionPage.merge([refresh, discovery]), now: now)
            check("crowded-out session stays tracked",
                  tracker.sessions["devin-tracked"] != nil)
            check("no suspended event for a session the refresh returns",
                  !events.contains { $0.sessionId == "devin-tracked" })
            check("new session discovered",
                  tracker.sessions["devin-new"] != nil)
        }

        print("DevinSessionPage.merge — archived session really gone")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-arch", status: "running", detail: "working",
                            title: "Arch", updated: ago(120)),
            ]))!, now: now)
            // Archived server-side: in neither the discovery page nor the
            // by-id refresh (is_archived=false excludes it).
            let events = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-other", status: "running", detail: "working",
                            title: "Other", updated: ago(10)),
            ]))!, now: now)
            check("archived session removed from tracker",
                  tracker.sessions["devin-arch"] == nil)
            check("archived session reports suspended",
                  events.contains { $0.sessionId == "devin-arch" && $0.kind == .suspended })
        }

        print("DevinSessionPage.merge — deduplication")
        do {
            let a = DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-d1", status: "running", detail: "working",
                            title: "First", updated: 100),
            ]))!
            let b = DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-d1", status: "running", detail: "working",
                            title: "Second", updated: 100),
                sessionJSON(id: "devin-d2", status: "exit", detail: nil,
                            title: "Other", updated: 90),
            ], hasNext: true, cursor: "cur=2"))!
            let merged = DevinSessionPage.merge([a, b])
            check("merge dedupes by id",             merged.items.count == 2)
            check("merge keeps first occurrence",   merged.items.first?.title == "First")
            check("merge keeps unique sessions",    merged.items.last?.id == "devin-d2")
            check("merge propagates has_next_page", merged.hasNextPage)
        }
    }

    // MARK: - Unknown statuses reconcile

    static func testUnknownReconciliation() {
        let now = Date()
        let ago = { (s: TimeInterval) in epoch(s, from: now) }

        print("DevinTracker — unrecognized status degrades safely and recovers")
        do {
            var tracker = DevinTracker()
            // Fresh unknown status: watched as active — never success, never failure.
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-u1", status: "migrated", detail: nil,
                            title: "U1", updated: ago(3600)),
            ]))!, now: now)
            check("fresh unknown session tracked",
                  tracker.sessions["devin-u1"] != nil)
            check("unknown degrades to working aggregate",
                  tracker.aggregatePhase == .working)

            // The status resolves on a later poll: the session recovers.
            let events = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-u1", status: "exit", detail: nil,
                            title: "U1", updated: ago(5)),
            ]))!, now: now)
            check("unknown → known status fires the transition",
                  events.first?.kind == .finished)
            check("recovered session is terminal",
                  tracker.sessions["devin-u1"]?.phase == .finished)
        }

        print("DevinTracker — unresolved unknown does not stay working forever")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-u2", status: "migrated", detail: nil,
                            title: "U2", updated: ago(48 * 3600)),
            ]))!, now: now)
            check("stale unknown ignored at first poll",
                  tracker.totalCount == 0)

            // And a session that goes stale while watched leaves silently:
            // "suspended" would claim a state the API never confirmed.
            var tracker2 = DevinTracker()
            _ = tracker2.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-u3", status: "migrated", detail: nil,
                            title: "U3", updated: ago(10)),
            ]))!, now: now)
            let later = now.addingTimeInterval(DevinTracker.unknownWindow + 60)
            let events = tracker2.ingest(DevinSessionPage.parse(pageData([
                sessionJSON(id: "devin-u3", status: "migrated", detail: nil,
                            title: "U3", updated: ago(10)),
            ]))!, now: later)
            check("stale unknown leaves the pill",
                  tracker2.sessions["devin-u3"] == nil)
            check("stale unknown leaves silently",
                  !events.contains { $0.sessionId == "devin-u3" })
        }
    }

    // MARK: - bestSession (the URL the pill opens)

    static func testBestSession() {
        let now = Date()
        let ago = { (s: TimeInterval) in epoch(s, from: now) }
        let session = { (id: String, status: String, detail: String?, title: String, updatedAgo: TimeInterval) in
            sessionJSON(id: id, status: status, detail: detail, title: title, updated: ago(updatedAgo))
        }

        print("DevinTracker.bestSession — deterministic rule")
        do {
            var tracker = DevinTracker()
            // A working session updated 10 s ago, a waiting session updated 100 s
            // ago, a finished session updated 1 s ago: waiting wins, even though
            // it is not the most recently updated.
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-a", "running", "working", "A", 10),
                session("devin-b", "running", "waiting_for_user", "B", 100),
                session("devin-c", "exit", nil, "C", 1),
            ]))!, now: now)
            check("waiting session wins",          tracker.bestSession?.id == "devin-b")

            // B answers: the newest live session beats the newer terminal one.
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-a", "running", "working", "A", 5),
                session("devin-b", "running", "working", "B", 4),
                session("devin-c", "exit", nil, "C", 1),
            ]))!, now: now)
            check("newest live beats newest terminal", tracker.bestSession?.id == "devin-b")

            // Nothing live: the newest terminal session.
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-c", "exit", nil, "C", 1),
                session("devin-c2", "exit", nil, "C2", 30),
            ]))!, now: now)
            check("terminal only → newest terminal",   tracker.bestSession?.id == "devin-c")
        }

        print("DevinTracker.bestSession — updated_at tie breaks on session id")
        do {
            var tracker = DevinTracker()
            _ = tracker.ingest(DevinSessionPage.parse(pageData([
                session("devin-x1", "running", "waiting_for_user", "X1", 50),
                session("devin-x2", "running", "waiting_for_user", "X2", 50),
            ]))!, now: now)
            check("tie → higher session id (stable choice)",
                  tracker.bestSession?.id == "devin-x2")
        }
    }

    // MARK: - Main

    static func main() {
        testIdentity()
        testPage()
        testPhases()
        testTracker()
        testMultipleSessions()
        testDiscoveryRefresh()
        testUnknownReconciliation()
        testBestSession()
        testSchedule()

        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
