import Foundation

/// Shared by the refresh tests: what the fake server was asked, in order.
actor Calls {
    var tokens: [String] = []
    var refreshes = 0
    func sent(_ token: String) { tokens.append(token) }
    func refreshed() { refreshes += 1 }
}

@main
enum TimelyAPITests {
    static func data(_ s: String) -> Data { Data(s.utf8) }

    // Field names and shapes as Timely returns them (trimmed).
    static let stopped = """
    {"id": 1, "day": "2026-10-09", "note": "  Review  ",
     "project": {"name": "Website", "color": "7b00ff", "client": {"name": "Acme"}},
     "duration": {"formatted": "00:09", "total_seconds": 591},
     "timer_state": "stop", "timer_started_on": 0, "timer_stopped_on": 1791567705}
    """
    static let running = """
    {"id": 2, "day": "2026-10-09", "note": "",
     "project": {"name": "Support", "color": "#22C55E"},
     "duration": {"total_seconds": 600},
     "timer_state": "start", "timer_started_on": 1000, "timer_stopped_on": 0}
    """

    static func main() async {
        var passed = 0
        func check(_ ok: Bool, _ what: String) {
            precondition(ok, what)
            passed += 1
        }

        // Authorize URL carries the out-of-band redirect.
        let url = TimelyAPI.authorizeURL(clientId: "abc")!.absoluteString
        check(url.hasPrefix("https://api.timelyapp.com/1.1/oauth/authorize?"), "authorize host")
        check(url.contains("response_type=code"), "response_type")
        check(url.contains("client_id=abc"), "client_id")
        check(url.contains("redirect_uri=urn:ietf:wg:oauth:2.0:oob"), "oob redirect")

        // Request bodies.
        let code = TimelyAPI.codeBody(clientId: "i", clientSecret: "s", code: "c")
        check(code["grant_type"] == "authorization_code" && code["code"] == "c"
              && code["redirect_uri"] == TimelyAPI.redirectURI, "code body")
        let refresh = TimelyAPI.refreshBody(clientId: "i", clientSecret: "s", refreshToken: "r")
        check(refresh["grant_type"] == "refresh_token" && refresh["refresh_token"] == "r", "refresh body")

        // Tokens.
        let t1 = TimelyTokens.parse(data(#"{"access_token":"a1","refresh_token":"r1","created_at":1}"#))
        check(t1 == TimelyTokens(access: "a1", refresh: "r1"), "token pair")
        let t2 = TimelyTokens.parse(data(#"{"access_token":"a2"}"#), keeping: "r1")
        check(t2 == TimelyTokens(access: "a2", refresh: "r1"), "refresh kept when left out")
        check(TimelyTokens.parse(data(#"{"error":"invalid_grant"}"#)) == nil, "error body")
        check(TimelyTokens.parse(data("<html>")) == nil, "not json")

        // Entries.
        let entries = TimelyParse.entries(data("[\(stopped), \(running), {\"no\": \"id\"}]"))!
        check(entries.count == 2, "entry without id dropped")
        let first = entries[0]
        check(first.project == "Website" && first.client == "Acme" && first.color == "#7b00ff",
              "project, client, colour gets its #")
        check(first.note == "Review" && first.loggedSeconds == 591 && !first.isRunning, "stopped entry")
        let second = entries[1]
        check(second.isRunning && second.timerStartedAt == Date(timeIntervalSince1970: 1000), "running entry")
        check(second.color == "#22C55E" && second.client == nil, "colour already prefixed")
        let now = Date(timeIntervalSince1970: 1000 + 125)
        check(second.seconds(at: now) == 725, "running entry counts the run in progress")
        check(first.seconds(at: now) == 591, "stopped entry does not grow")

        let day = TimelyDay(entries: entries, capacityHours: 7.5)
        check(day.running?.id == 2, "running entry found")
        check(day.loggedSeconds(at: now) == 591 + 725, "day total")
        check(TimelyDay(entries: [first], capacityHours: nil).running == nil, "nothing running")
        check(TimelyParse.entries(data("{}")) == nil, "object is not a list")

        // Account, user, capacity.
        check(TimelyParse.firstAccountId(data(#"[{"id": 21, "name": "A"}, {"id": 22}]"#)) == 21, "first account")
        check(TimelyParse.firstAccountId(data("[]")) == nil, "no account")
        check(TimelyParse.userId(data(#"{"id": 7, "name": "Me"}"#)) == 7, "current user")
        let caps = #"[{"daily_capacity": 6, "current": false}, {"daily_capacity": 7.5, "current": true}]"#
        check(TimelyParse.dailyCapacity(data(caps)) == 7.5, "current capacity period")
        check(TimelyParse.dailyCapacity(data(#"[{"daily_capacity": 0}]"#)) == nil, "zero capacity is none")

        // Formatting.
        check(TimelyFormat.hm(3725) == "1:02" && TimelyFormat.hm(59) == "0:00", "h:mm")
        check(TimelyFormat.hm(hours: 7.5) == "7:30", "capacity h:mm")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        check(TimelyFormat.day(Date(timeIntervalSince1970: 0), calendar: utc) == "1970-01-01", "day key")

        // Refresh once on 401, then retry with the new token.
        let calls = Calls()
        let ok = await TimelyAPI.withRefresh(
            access: "old",
            send: { token in await calls.sent(token); return (token == "new" ? 200 : 401, nil) },
            refresh: { await calls.refreshed(); return "new" })
        check(ok.status == 200, "retried after refresh")
        let sent = await calls.tokens, refreshes = await calls.refreshes
        check(sent == ["old", "new"] && refreshes == 1, "one refresh, two sends")

        // No refresh when the first call works.
        let quiet = Calls()
        _ = await TimelyAPI.withRefresh(
            access: "good",
            send: { token in await quiet.sent(token); return (200, nil) },
            refresh: { await quiet.refreshed(); return "x" })
        let quietSent = await quiet.tokens, quietRefreshes = await quiet.refreshes
        check(quietRefreshes == 0 && quietSent == ["good"], "no refresh on 200")

        // A failed refresh hands back the first 401 and sends nothing more.
        let failed = Calls()
        let denied = await TimelyAPI.withRefresh(
            access: "old",
            send: { token in await failed.sent(token); return (401, nil) },
            refresh: { await failed.refreshed(); return nil })
        let failedSent = await failed.tokens
        check(denied.status == 401 && failedSent == ["old"], "failed refresh stops")

        // A 401 after a successful refresh is not refreshed again.
        let twice = Calls()
        let still = await TimelyAPI.withRefresh(
            access: "old",
            send: { token in await twice.sent(token); return (401, nil) },
            refresh: { await twice.refreshed(); return "new" })
        let twiceRefreshes = await twice.refreshes
        check(still.status == 401 && twiceRefreshes == 1, "refreshes at most once")

        print("Timely API: \(passed) cases passed")
    }
}
