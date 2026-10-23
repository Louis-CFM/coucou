import Darwin
import Foundation
import CryptoKit
import Security

// Google Calendar — the next events of every calendar you show in Google Calendar,
// and a reminder when Google Calendar itself would ring. Same rules as
// windows/src-tauri/src/gcal.rs; the network side lives in GcalPoller.
//
// Read-only scopes. Nothing is ever written to the calendar.

enum Gcal {
    /// Read-only: events, and the list of calendars to read them from.
    static let scope = "https://www.googleapis.com/auth/calendar.events.readonly "
        + "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let revokeURL = "https://oauth2.googleapis.com/revoke"

    /// Minutes before an event Mochi speaks up when neither the event, its
    /// calendar nor your primary calendar sets any reminder.
    static let fallbackLead = 5

    static let expired = "Google sign-in expired — reconnect in Settings"
}

// MARK: - Calendars and events

/// A calendar to read: the ones ticked in Google Calendar's sidebar.
struct GcalCalendar: Equatable, Sendable {
    var id: String
    var name: String
    var color: String?
    var primary: Bool

    /// The calendar list, keeping what Google Calendar shows; the primary calendar
    /// first, since its default reminders stand in for calendars that have none.
    static func parseList(_ json: [String: Any]) -> [GcalCalendar] {
        let list: [GcalCalendar] = (json["items"] as? [Any] ?? []).compactMap { c in
            let shown = jsonBool(jsonValue(c, "selected")) == true || jsonBool(jsonValue(c, "primary")) == true
            guard shown, jsonBool(jsonValue(c, "hidden")) != true,
                  let id = jsonValue(c, "id") as? String else { return nil }
            return GcalCalendar(
                id: id,
                // What you renamed it to, else its own name.
                name: (jsonValue(c, "summaryOverride") as? String) ?? (jsonValue(c, "summary") as? String) ?? "",
                color: jsonValue(c, "backgroundColor") as? String,
                primary: jsonBool(jsonValue(c, "primary")) == true
            )
        }
        return list.filter(\.primary) + list.filter { !$0.primary }
    }
}

struct GcalEvent: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    /// RFC 3339 for timed events, YYYY-MM-DD for all-day ones.
    var start: String
    var end: String
    var startSecs: Int?
    var endSecs: Int?
    var allDay: Bool
    var meetURL: String?
    var url: String
    /// The calendar's colour in Google Calendar, for the row's dot.
    var color: String?
    var calendar: String
    var location: String?
    /// Minutes before the start at which to speak up, ascending. Empty when the
    /// event says "no notification".
    var reminders: [Int]

    /// `defaults`: the calendar's default reminders, already resolved to the
    /// primary calendar's (or Gcal.fallbackLead) when it has none.
    static func parse(_ item: Any, calendar: GcalCalendar, defaults: [Int]) -> GcalEvent? {
        if jsonString(item, "status") == "cancelled" || jsonString(item, "eventType") == "workingLocation" {
            return nil
        }
        // Declined meetings aren't yours to go to.
        let attendees = jsonValue(item, "attendees") as? [Any] ?? []
        if attendees.contains(where: {
            jsonBool(jsonValue($0, "self")) == true && jsonString($0, "responseStatus") == "declined"
        }) { return nil }

        func when(_ k: String) -> (String, Bool) {
            if let t = jsonValue(item, k, "dateTime") as? String { return (t, false) }
            return (jsonString(item, k, "date"), true)
        }
        let (start, allDay) = when("start")
        let (end, _) = when("end")
        if start.isEmpty { return nil }

        let video = (jsonValue(item, "conferenceData", "entryPoints") as? [Any] ?? [])
            .first { jsonString($0, "entryPointType") == "video" }
        let location = jsonValue(item, "location") as? String
        let meetURL = (jsonValue(item, "hangoutLink") as? String)
            ?? (video.flatMap { jsonValue($0, "uri") as? String })
            // Zoom and Teams links pasted into the location field.
            ?? location.flatMap { $0.hasPrefix("https://") ? $0 : nil }

        let title = jsonString(item, "summary")
        return GcalEvent(
            id: jsonString(item, "id"),
            title: title.isEmpty ? "(No title)" : title,
            start: start,
            end: end,
            startSecs: allDay ? nil : RFC3339.parse(start),
            endSecs: allDay ? nil : RFC3339.parse(end),
            allDay: allDay,
            meetURL: meetURL,
            url: jsonString(item, "htmlLink"),
            color: calendar.color,
            calendar: calendar.name,
            location: (location?.isEmpty ?? true) ? nil : location,
            // Your own overrides on this event win — including "none at all".
            reminders: jsonBool(jsonValue(item, "reminders", "useDefault")) == false
                ? reminderMinutes(jsonValue(item, "reminders", "overrides"))
                : defaults
        )
    }

    var key: String { "\(id)@\(start)" }

    /// Chronological across calendars; an all-day event counts from midnight UTC.
    var sortKey: Int {
        startSecs ?? RFC3339.parse("\(start)T00:00:00Z") ?? Int.max
    }

    /// An invitation can sit in two calendars at once: keep the first, then sort
    /// chronologically (ties keep their order).
    static func merge(_ events: [GcalEvent]) -> [GcalEvent] {
        var seen = Set<String>()
        let unique = events.filter { seen.insert($0.id).inserted }
        return unique.enumerated()
            .sorted { ($0.element.sortKey, $0.offset) < ($1.element.sortKey, $1.offset) }
            .map(\.element)
    }
}

/// Minutes from a Calendar `reminders` list (`[{method, minutes}]`), ascending.
/// Email and pop-up alike: either way you asked to be told then.
func reminderMinutes(_ list: Any?) -> [Int] {
    let minutes = (list as? [Any] ?? []).compactMap { jsonInt(jsonValue($0, "minutes")) }.filter { $0 >= 0 }
    return Array(Set(minutes)).sorted()
}

// MARK: - Reminders

struct GcalReminder: Equatable, Sendable {
    var event: GcalEvent
    /// Minutes until the start, rounded up.
    var minutes: Int
    var news: IntegrationNews
}

/// "id@start#minutes" of every reminder already rung, so each rings once (and
/// again if the event is moved).
struct GcalReminders {
    private(set) var reminded = Set<String>()

    mutating func clear() { reminded.removeAll() }

    /// The reminder that has just come due, the way Google Calendar itself would
    /// ring it: at each of the event's reminder times.
    ///
    /// Only the latest reminder due is ever shown — after a restart, a meeting in
    /// 20 minutes says "in 20 min" once, not its day-before and its 30-minute
    /// reminders back to back. One per poll; a second meeting due at the same
    /// moment comes a minute later.
    mutating func next(_ events: [GcalEvent], now: Int) -> GcalReminder? {
        // Forget events that have dropped off the list, so the set stays small.
        let live = events.map(\.key)
        reminded = reminded.filter { k in live.contains { k.hasPrefix($0) } }

        for e in events {
            guard let start = e.startSecs else { continue }
            // A reminder "at the time of the event" still gets its minute.
            if now >= start + 60 { continue }
            let due = e.reminders.filter { start - $0 * 60 <= now }
            guard let latest = due.min() else { continue }
            if reminded.contains("\(e.key)#\(latest)") { continue }
            for m in due { reminded.insert("\(e.key)#\(m)") }
            let minutes = max(0, (start - now + 59) / 60)
            return GcalReminder(
                event: e, minutes: minutes,
                news: IntegrationNews(success: true, label: e.title, detail: Self.startsIn(minutes), attention: true)
            )
        }
        return nil
    }

    static func startsIn(_ minutes: Int) -> String {
        switch minutes {
        case ...0: return "Starting now"
        case 1: return "Starts in a minute"
        case 2...59: return "Starts in \(minutes) min"
        case 60...1439:
            let (h, m) = (minutes / 60, minutes % 60)
            return m == 0 ? "Starts in \(h) h" : "Starts in \(h) h \(m) min"
        default:
            let d = minutes / 1440
            return d == 1 ? "Starts in a day" : "Starts in \(d) days"
        }
    }
}

// MARK: - Signing in (installed-app flow)

enum GcalOAuth {
    /// application/x-www-form-urlencoded, also good for query strings.
    static func form(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(pct($0.0))=\(pct($0.1))" }.joined(separator: "&")
    }

    static func pct(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(b))
            default:
                out += String(format: "%%%02X", b)
            }
        }
        return out
    }

    static func parseQuery(_ q: String) -> [(String, String)] {
        q.split(separator: "&", omittingEmptySubsequences: true).map { p in
            if let eq = p.firstIndex(of: "=") {
                return (pctDecode(String(p[..<eq])), pctDecode(String(p[p.index(after: eq)...])))
            }
            return (pctDecode(String(p)), "")
        }
    }

    static func pctDecode(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return b - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return b - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return b - UInt8(ascii: "A") + 10
            default: return nil
            }
        }
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "+"):
                out.append(UInt8(ascii: " "))
            case UInt8(ascii: "%") where i + 2 < bytes.count:
                if let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi * 16 + lo)
                    i += 2
                } else {
                    out.append(UInt8(ascii: "%"))
                }
            case let b:
                out.append(b)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func b64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    /// The system CSPRNG, for the PKCE verifier and the `state` check.
    static func randomBytes(_ n: Int) throws -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: n)
        guard SecRandomCopyBytes(kSecRandomDefault, n, &buf) == errSecSuccess else {
            throw GcalProblem.shown("No randomness available for the sign-in.")
        }
        return buf
    }

    /// What the loopback listener does with one request from the browser.
    enum Answer: Equatable {
        /// A stray request (a favicon, a stale tab, a forged state): 404, keep waiting.
        case stray
        /// Google redirected back without a code: missing parameter, keep waiting.
        case badRequest
        /// The user said no (or Google said no for them).
        case denied(String)
        case code(String)
    }

    /// `firstLine` is the HTTP request line, e.g. `GET /?state=…&code=… HTTP/1.1`.
    static func route(_ firstLine: String, state: String) -> Answer {
        guard firstLine.hasPrefix("GET ") else { return .stray }
        let target = firstLine.dropFirst(4).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let (path, query): (String, String)
        if let q = target.firstIndex(of: "?") {
            (path, query) = (String(target[..<q]), String(target[target.index(after: q)...]))
        } else {
            (path, query) = (target, "")
        }
        let params = parseQuery(query)
        func param(_ k: String) -> String? { params.first { $0.0 == k }?.1 }

        if path != "/" || param("state") != state { return .stray }
        if let error = param("error") { return .denied(error) }
        if let code = param("code") { return .code(code) }
        return .badRequest
    }

    static func response(status: String, message: String) -> String {
        let html = "<!doctype html><meta charset=utf-8><title>Coucou</title>"
            + "<body style=\"font:15px system-ui;background:#0b0b0c;color:#e8e8ea;"
            + "display:grid;place-items:center;height:100vh;margin:0\"><p>\(message)</p>"
        return "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(html)"
    }

    /// The message Google put in an error answer, shortened for the island.
    static func googleError(_ body: [String: Any]) -> String? {
        let message = (jsonValue(body, "error", "message") as? String)
            ?? (body["error_description"] as? String)
            ?? (body["error"] as? String)
        return message.map { String($0.prefix(90)) }
    }
}

/// Why a Google request gave nothing to show.
enum GcalProblem: Error, Equatable {
    /// Offline or timed out: say nothing, try again next poll.
    case offline
    /// A sign-in or API problem worth showing.
    case shown(String)

    var message: String {
        switch self {
        case .offline: return "No connection"
        case .shown(let m): return m
        }
    }
}

// MARK: - One-shot loopback listener (127.0.0.1, a free port)

final class LoopbackListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let closeLock = NSLock()
    private var closed = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GcalProblem.shown("Could not open a local port for the sign-in.") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw GcalProblem.shown("Could not open a local port for the sign-in.")
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        self.fd = fd
        self.port = UInt16(bigEndian: got.sin_port)
    }

    /// Serves the one redirect Google sends back, checking `state`, and answers the
    /// browser with a page saying it can be closed. Stray requests (a favicon, a
    /// stale tab) get a 404 and the wait goes on. Blocking: call off the main thread.
    /// `stillWanted` is checked every second, so Cancel ends the wait even though
    /// Google's "access blocked" page never redirects back.
    func waitForCode(state: String, deadline: Date, stillWanted: () -> Bool) -> Result<String, GcalProblem> {
        while true {
            if !stillWanted() { return .failure(.shown("Sign-in cancelled.")) }
            if Date() >= deadline { return .failure(.shown("Timed out waiting for Google.")) }
            guard let client = accept(timeoutMs: 1000) else { continue }
            switch GcalOAuth.route(Self.readRequestLine(client), state: state) {
            case .stray:
                Self.reply(client, GcalOAuth.response(status: "404 Not Found", message: "Nothing here."))
            case .badRequest:
                Self.reply(client, GcalOAuth.response(status: "400 Bad Request", message: "Missing code."))
            case .denied(let error):
                Self.reply(client, GcalOAuth.response(
                    status: "200 OK", message: "Coucou wasn't given access. You can close this tab."))
                return .failure(.shown("Google sign-in cancelled (\(error))."))
            case .code(let code):
                Self.reply(client, GcalOAuth.response(
                    status: "200 OK", message: "Coucou is connected to Google Calendar. You can close this tab."))
                return .success(code)
            }
        }
    }

    /// The next connection, or nil after `timeoutMs` without one.
    func accept(timeoutMs: Int32) -> Int32? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&pfd, 1, timeoutMs) > 0 else { return nil }
        let client = Darwin.accept(fd, nil, nil)
        return client >= 0 ? client : nil
    }

    /// Reads the request head (at most 16 KB, 5 s) and returns its first line.
    static func readRequestLine(_ client: Int32) -> String {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var head: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 2048)
        let end: [UInt8] = [13, 10, 13, 10]
        while head.count < 16 * 1024, head.firstRange(of: end) == nil {
            let n = recv(client, &chunk, chunk.count, 0)
            if n <= 0 { break }
            head.append(contentsOf: chunk[0..<n])
        }
        let text = String(decoding: head, as: UTF8.self)
        return text.components(separatedBy: "\r\n").first ?? ""
    }

    static func reply(_ client: Int32, _ response: String) {
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { send(client, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 { break }
            sent += n
        }
        shutdown(client, SHUT_RDWR)
        Darwin.close(client)
    }

    func close() {
        closeLock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(fd)
        }
    }
}
