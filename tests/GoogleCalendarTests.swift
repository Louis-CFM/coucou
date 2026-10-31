import Foundation

// Same cases as the tests in windows/src-tauri/src/gcal.rs, plus the calendar list.

@main
enum GoogleCalendarTests {
    nonisolated(unsafe) static var passed = 0

    static func check(_ condition: Bool, _ what: String, line: Int = #line) {
        precondition(condition, "line \(line): \(what)")
        passed += 1
    }

    static func main() {
        dates()
        encodings()
        pkcePrimitives()
        loopbackListener()
        calendarList()
        allDayEventsSortAmongTimedOnes()
        eventsAreFilteredAndParsed()
        reminderMinutesAreReadAndSorted()
        remindersRingLikeGoogleCalendar()
        startsInReadsNaturally()
        print("Google Calendar: \(passed) checks passed")
    }

    // RFC 3339 lives in IntegrationNews.swift; same cases as windows/src-tauri/src/time.rs.
    static func dates() {
        check(RFC3339.utc(0) == "1970-01-01T00:00:00Z", "epoch")
        check(RFC3339.utc(1_790_000_000) == "2026-09-21T14:13:20Z", "utc")
        check(RFC3339.parse("2026-09-21T14:13:20Z") == 1_790_000_000, "Z")
        check(RFC3339.parse("2026-09-21T16:13:20+02:00") == 1_790_000_000, "offset")
        check(RFC3339.parse("2026-09-21T09:13:20.250-05:00") == 1_790_000_000, "fraction + negative offset")
        check(RFC3339.parse("2024-02-29T00:00:00Z").map(RFC3339.utc) == "2024-02-29T00:00:00Z", "leap day")
        check(RFC3339.parse("2026-10-01") == nil, "a date alone is not a time")
        check(RFC3339.parse("") == nil, "empty")
    }

    static func encodings() {
        check(GcalOAuth.b64url([]) == "", "b64 empty")
        check(GcalOAuth.b64url(Array("f".utf8)) == "Zg", "b64 f")
        check(GcalOAuth.b64url(Array("fo".utf8)) == "Zm8", "b64 fo")
        check(GcalOAuth.b64url(Array("foo".utf8)) == "Zm9v", "b64 foo")
        check(GcalOAuth.b64url([0xfb, 0xff]) == "-_8", "b64 url alphabet")
        check(GcalOAuth.pct("a b/c:d") == "a%20b%2Fc%3Ad", "pct")
        check(GcalOAuth.pct("é") == "%C3%A9", "pct utf-8")
        check(GcalOAuth.pctDecode("4%2F0Ab+x%zz%4") == "4/0Ab x%zz%4", "pct decode")
        let q = GcalOAuth.parseQuery("state=abc&code=4%2F0AX&scope=x")
        check(q.count == 3 && q[1].0 == "code" && q[1].1 == "4/0AX", "query")
        check(GcalOAuth.form([("a", "1 2"), ("b", "x&y")]) == "a=1%202&b=x%26y", "form")
    }

    static func pkcePrimitives() {
        // FIPS 180-2's "abc" vector.
        let hex = GcalOAuth.sha256(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        check(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256")
        let a = try! GcalOAuth.randomBytes(32)
        check(a.count == 32 && a != (try! GcalOAuth.randomBytes(32)), "random")
        // 32 bytes → the 43-character verifier RFC 7636 asks for.
        check(GcalOAuth.b64url(a).count == 43, "verifier length")
    }

    /// The loopback listener: strays are ignored, the right redirect yields its
    /// code, and Cancel ends the wait even though Google never came back.
    static func loopbackListener() {
        check(GcalOAuth.route("GET /?state=s&error=access_denied HTTP/1.1", state: "s") == .denied("access_denied"), "denied")
        check(GcalOAuth.route("GET /?state=s HTTP/1.1", state: "s") == .badRequest, "no code")
        check(GcalOAuth.route("POST /?state=s&code=c HTTP/1.1", state: "s") == .stray, "not a GET")
        check(GcalOAuth.route("GET /other?state=s&code=c HTTP/1.1", state: "s") == .stray, "other path")

        let listener = try! LoopbackListener()
        defer { listener.close() }
        let port = listener.port
        check(port > 0, "free port")

        // One after the other, like a browser: the listener stops at the redirect
        // it wants, so anything sent after it would go unanswered.
        nonisolated(unsafe) var replies: [String] = []
        let browser = Thread {
            for path in ["/favicon.ico", "/?state=wrong&code=evil", "/?state=s3cr3t&code=4%2F0Abc&scope=x"] {
                replies.append(get(port: port, path: path))
            }
        }
        browser.start()
        let code = listener.waitForCode(state: "s3cr3t", deadline: Date().addingTimeInterval(10), stillWanted: { true })
        while !browser.isFinished { usleep(10_000) }
        check(code == .success("4/0Abc"), "code")
        check(replies.count == 3, "three replies")
        check(replies[0].hasPrefix("HTTP/1.1 404"), "favicon 404")
        check(replies[1].hasPrefix("HTTP/1.1 404"), "forged state 404")
        check(replies[2].contains("connected to Google Calendar"), "success page")

        // Google's "access blocked" page: no redirect ever arrives.
        let started = Date()
        let cancelAt = started.addingTimeInterval(0.3)
        let result = listener.waitForCode(state: "s3cr3t", deadline: started.addingTimeInterval(10),
                                          stillWanted: { Date() < cancelAt })
        check(result == .failure(.shown("Sign-in cancelled.")), "cancel")
        check(Date().timeIntervalSince(started) < 3, "cancel is quick")

        let timedOut = listener.waitForCode(state: "s3cr3t", deadline: Date().addingTimeInterval(0.2), stillWanted: { true })
        check(timedOut == .failure(.shown("Timed out waiting for Google.")), "timeout")
    }

    /// A minimal HTTP GET over a raw socket, like the browser's redirect.
    static func get(port: UInt16, path: String) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return "" }
        let request = Array("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress!, request.count, 0) }
        var reply: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            reply += buf[0..<n]
        }
        return String(decoding: reply, as: UTF8.self)
    }

    static func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    static func calendarList() {
        let list = GcalCalendar.parseList(json("""
        { "items": [
          { "id": "team", "summary": "Team", "selected": true, "backgroundColor": "#16a765" },
          { "id": "hidden", "summary": "Hidden", "selected": true, "hidden": true },
          { "id": "unticked", "summary": "Unticked" },
          { "id": "me@x.com", "summary": "me@x.com", "summaryOverride": "Mine", "primary": true }
        ] }
        """))
        check(list.map(\.id) == ["me@x.com", "team"], "shown calendars, primary first")
        check(list[0].name == "Mine" && list[0].primary && list[1].color == "#16a765", "names and colours")
    }

    static let cal = GcalCalendar(id: "primary", name: "Main", color: "#16a765", primary: true)

    static func allDayEventsSortAmongTimedOnes() {
        func parse(_ text: String) -> GcalEvent { GcalEvent.parse(json(text), calendar: cal, defaults: [5])! }
        let events = GcalEvent.merge([
            parse(#"{"id": "poker", "start": {"dateTime": "2026-10-02T17:30:00Z"}, "end": {"dateTime": "2026-10-02T21:30:00Z"}}"#),
            parse(#"{"id": "holiday", "start": {"date": "2026-10-02"}, "end": {"date": "2026-10-03"}}"#),
            parse(#"{"id": "today", "start": {"dateTime": "2026-10-01T19:00:00+02:00"}, "end": {"dateTime": "2026-10-01T20:00:00+02:00"}}"#),
            // The same invitation seen through a second calendar.
            parse(#"{"id": "today", "start": {"dateTime": "2026-10-01T19:00:00+02:00"}, "end": {"dateTime": "2026-10-01T20:00:00+02:00"}}"#),
        ])
        check(events.map(\.id) == ["today", "holiday", "poker"], "chronological, deduplicated")
    }

    static func event(_ id: String, _ start: String) -> [String: Any] {
        ["id": id, "summary": id, "start": ["dateTime": start], "end": ["dateTime": start]]
    }

    static func eventsAreFilteredAndParsed() {
        let declined = json("""
        { "id": "d", "start": { "dateTime": "2026-10-01T10:00:00Z" }, "end": { "dateTime": "2026-10-01T11:00:00Z" },
          "attendees": [{ "self": true, "responseStatus": "declined" }] }
        """)
        check(GcalEvent.parse(declined, calendar: cal, defaults: [5]) == nil, "declined")
        check(GcalEvent.parse(json(#"{"id": "c", "status": "cancelled", "start": {"date": "2026-10-02"}}"#),
                              calendar: cal, defaults: [5]) == nil, "cancelled")
        check(GcalEvent.parse(json(#"{"id": "w", "eventType": "workingLocation", "start": {"date": "2026-10-02"}}"#),
                              calendar: cal, defaults: [5]) == nil, "working location")
        let allDay = GcalEvent.parse(json(#"{"id": "a", "start": {"date": "2026-10-02"}, "end": {"date": "2026-10-03"}}"#),
                                     calendar: cal, defaults: [5])!
        check(allDay.allDay && allDay.startSecs == nil && allDay.title == "(No title)", "all day")
        let meet = GcalEvent.parse(json("""
        { "id": "m", "summary": "Standup", "start": { "dateTime": "2026-10-01T10:00:00Z" },
          "end": { "dateTime": "2026-10-01T10:15:00Z" }, "htmlLink": "https://calendar.google.com/x",
          "conferenceData": { "entryPoints": [
            { "entryPointType": "phone", "uri": "tel:+1" },
            { "entryPointType": "video", "uri": "https://meet.google.com/abc" }
          ] } }
        """), calendar: cal, defaults: [5])!
        check(meet.meetURL == "https://meet.google.com/abc" && meet.calendar == "Main" && meet.color == "#16a765",
              "video link")
        let zoom = GcalEvent.parse(json("""
        { "id": "z", "start": { "dateTime": "2026-10-01T10:00:00Z" }, "end": { "dateTime": "2026-10-01T10:15:00Z" },
          "location": "https://zoom.us/j/1" }
        """), calendar: cal, defaults: [5])!
        check(zoom.meetURL == "https://zoom.us/j/1", "link in the location")
    }

    static func reminderMinutesAreReadAndSorted() {
        let list = json(#"{"r": [{"method": "popup", "minutes": 30}, {"method": "email", "minutes": 1440}, {"method": "popup", "minutes": 30}]}"#)["r"]
        check(reminderMinutes(list) == [30, 1440], "sorted, deduplicated")
        check(reminderMinutes(nil) == [], "none")
        var e = event("x", "2026-10-02T17:30:00Z")
        e["reminders"] = ["useDefault": false, "overrides": [Any]()]
        // "No notification" on the event beats the calendar's defaults.
        check(GcalEvent.parse(e, calendar: cal, defaults: [30])!.reminders.isEmpty, "no notification")
        e["reminders"] = ["useDefault": false, "overrides": [["method": "popup", "minutes": 10]]]
        check(GcalEvent.parse(e, calendar: cal, defaults: [30])!.reminders == [10], "overrides")
        e["reminders"] = ["useDefault": true]
        check(GcalEvent.parse(e, calendar: cal, defaults: [30, 1440])!.reminders == [30, 1440], "defaults")
    }

    static func remindersRingLikeGoogleCalendar() {
        let t = RFC3339.parse("2026-10-02T17:30:00Z")!
        let min = 60
        let poker = { [GcalEvent.parse(event("poker", "2026-10-02T17:30:00Z"), calendar: cal, defaults: [30, 1440])!] }

        // A day ahead, then 30 minutes ahead; once each.
        var r = GcalReminders()
        let events = poker()
        check(r.next(events, now: t - 25 * 60 * min) == nil, "too early")
        check(r.next(events, now: t - 1440 * min + 30)?.news.detail == "Starts in a day", "day before")
        check(r.next(events, now: t - 1439 * min) == nil, "once")
        check(r.next(events, now: t - 31 * min) == nil, "not yet")
        let e = r.next(events, now: t - 30 * min)
        check(e?.news.label == "poker" && e?.news.detail == "Starts in 30 min" && e?.news.attention == true, "30 min")
        check(e?.minutes == 30 && e?.event.calendar == "Main", "the event")
        check(r.next(events, now: t - 29 * min) == nil, "once again")

        // Started 20 minutes before the meeting: one reminder, not both.
        r = GcalReminders()
        check(r.next(events, now: t - 20 * min)?.news.detail == "Starts in 20 min", "late start")
        check(r.next(events, now: t - 19 * min) == nil, "no burst")

        // "At the time of the event" still rings, within its minute.
        r = GcalReminders()
        let standup = [GcalEvent.parse(event("standup", "2026-10-02T17:30:00Z"), calendar: cal, defaults: [0])!]
        check(r.next(standup, now: t - 30) == nil, "before")
        check(r.next(standup, now: t + 10)?.news.detail == "Starting now", "at the time")
        r = GcalReminders()
        check(r.next(standup, now: t + 90) == nil, "too late")

        // Two due at once: the earlier one now, the other on the next poll.
        r = GcalReminders()
        let two = [
            GcalEvent.parse(event("a", "2026-10-02T17:30:00Z"), calendar: cal, defaults: [30])!,
            GcalEvent.parse(event("b", "2026-10-02T17:40:00Z"), calendar: cal, defaults: [30])!,
        ]
        check(r.next(two, now: t - 5 * min)?.news.label == "a", "first")
        check(r.next(two, now: t - 4 * min)?.news.label == "b", "second")
        check(r.next(two, now: t - 3 * min) == nil, "done")

        // Moved: rings again.
        r = GcalReminders()
        _ = r.next(two, now: t - 5 * min)
        let moved = [GcalEvent.parse(event("a", "2026-10-02T17:35:00Z"), calendar: cal, defaults: [30])!]
        check(r.next(moved, now: t - 4 * min)?.news.label == "a", "moved event")
    }

    static func startsInReadsNaturally() {
        check(GcalReminders.startsIn(0) == "Starting now", "0")
        check(GcalReminders.startsIn(1) == "Starts in a minute", "1")
        check(GcalReminders.startsIn(90) == "Starts in 1 h 30 min", "90")
        check(GcalReminders.startsIn(120) == "Starts in 2 h", "120")
        check(GcalReminders.startsIn(3000) == "Starts in 2 days", "3000")
    }
}
