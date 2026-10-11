import Foundation

// MARK: - Timely API
// The parts of the Timely integration that touch no UI: URLs, OAuth request
// bodies, response parsing and the refresh-once rule. Foundation only, so
// scripts/test-timely.sh compiles it without the app.

enum TimelyAPI {
    static let base = "https://api.timelyapp.com/1.1"
    /// Out-of-band redirect: Timely shows the code on its own page for the user to paste back.
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
    static let webURL = URL(string: "https://app.timelyapp.com")!
    static let httpOK = 200
    static let httpUnauthorized = 401

    static func authorizeURL(clientId: String) -> URL? {
        var components = URLComponents(string: "\(base)/oauth/authorize")
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        return components?.url
    }

    static var tokenURL: URL { URL(string: "\(base)/oauth/token")! }

    static func codeBody(clientId: String, clientSecret: String, code: String) -> [String: String] {
        ["grant_type": "authorization_code", "client_id": clientId, "client_secret": clientSecret,
         "code": code, "redirect_uri": redirectURI]
    }

    static func refreshBody(clientId: String, clientSecret: String, refreshToken: String) -> [String: String] {
        ["grant_type": "refresh_token", "client_id": clientId, "client_secret": clientSecret,
         "refresh_token": refreshToken]
    }

    /// Calls `send` with the access token; on a 401, refreshes once and calls it again.
    /// A refresh that fails returns the first 401.
    static func withRefresh(access: String,
                            send: @Sendable (String) async -> (status: Int, data: Data?),
                            refresh: @Sendable () async -> String?) async -> (status: Int, data: Data?) {
        let first = await send(access)
        guard first.status == httpUnauthorized else { return first }
        guard let fresh = await refresh() else { return first }
        return await send(fresh)
    }
}

// MARK: - Tokens

struct TimelyTokens: Equatable, Sendable {
    let access: String
    let refresh: String?

    /// A refresh answer may leave out the refresh token: the old one then stays valid.
    static func parse(_ data: Data, keeping oldRefresh: String? = nil) -> TimelyTokens? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        let refresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? oldRefresh
        return TimelyTokens(access: access, refresh: refresh)
    }
}

// MARK: - Entries

struct TimelyEntry: Identifiable, Equatable, Sendable {
    let id: Int
    let project: String
    let client: String?
    let color: String
    let note: String
    /// Time already on the entry, without the run in progress.
    let loggedSeconds: Int
    /// Set while the entry's timer runs.
    let timerStartedAt: Date?

    var isRunning: Bool { timerStartedAt != nil }

    func seconds(at now: Date) -> Int {
        guard let start = timerStartedAt else { return loggedSeconds }
        return loggedSeconds + max(0, Int(now.timeIntervalSince(start)))
    }
}

struct TimelyDay: Equatable, Sendable {
    let entries: [TimelyEntry]
    /// Contracted hours for a day, when Timely has a capacity for the user.
    let capacityHours: Double?

    var running: TimelyEntry? { entries.first { $0.isRunning } }

    func loggedSeconds(at now: Date) -> Int {
        entries.reduce(0) { $0 + $1.seconds(at: now) }
    }
}

enum TimelyParse {
    static func entries(_ data: Data) -> [TimelyEntry]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap(entry)
    }

    static func entry(_ e: [String: Any]) -> TimelyEntry? {
        guard let id = e["id"] as? Int else { return nil }
        let project = e["project"] as? [String: Any]
        let client = project?["client"] as? [String: Any]
        let duration = e["duration"] as? [String: Any]
        let startedOn = (e["timer_started_on"] as? Double) ?? 0
        let running = (e["timer_state"] as? String) != "stop" && startedOn > 0
        let color = (project?["color"] as? String).map { $0.hasPrefix("#") ? $0 : "#\($0)" } ?? "#F5A524"
        return TimelyEntry(
            id: id,
            project: (project?["name"] as? String) ?? "Timely",
            client: client?["name"] as? String,
            color: color,
            note: ((e["note"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            loggedSeconds: (duration?["total_seconds"] as? Int) ?? 0,
            timerStartedAt: running ? Date(timeIntervalSince1970: startedOn) : nil
        )
    }

    /// The first account the token reaches (GET /accounts).
    static func firstAccountId(_ data: Data) -> Int? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.first?["id"] as? Int
    }

    /// GET /{account}/users/current.
    static func userId(_ data: Data) -> Int? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["id"] as? Int
    }

    /// GET /{account}/users/{id}/capacities: the current period's daily hours.
    static func dailyCapacity(_ data: Data) -> Double? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let current = list.first { ($0["current"] as? Bool) == true } ?? list.first
        guard let hours = current?["daily_capacity"] as? Double, hours > 0 else { return nil }
        return hours
    }
}

enum TimelyFormat {
    /// 3725 → "1:02".
    static func hm(_ seconds: Int) -> String {
        let minutes = max(0, seconds) / 60
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// 7.5 → "7:30".
    static func hm(hours: Double) -> String {
        hm(Int((hours * 3600).rounded()))
    }

    /// "2026-10-10" in the user's time zone.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
