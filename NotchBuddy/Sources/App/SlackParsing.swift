import Foundation

// MARK: - Slack
// Parsing for SlackPoller, kept free of network and AppKit so the tests build it alone
// (scripts/test-slack.sh). Each function reads one Web API response as JSONSerialization
// returns it.

struct SlackIdentity: Equatable {
    let userId: String
    let teamId: String
    /// The workspace's own address, "https://acme.slack.com/".
    let url: String
}

struct SlackIM: Equatable {
    let channelId: String
    let userId: String
    let priority: Double
}

struct SlackMessage: Identifiable, Equatable {
    enum Kind: Equatable { case dm, mention }

    let kind: Kind
    let channelId: String
    /// Mentions only: the channel's name, without "#".
    let channelName: String?
    let userId: String
    var author: String
    var text: String
    let ts: String
    /// Direct messages only: unread messages in the conversation.
    let unread: Int
    let permalink: String?

    var id: String { "\(channelId)-\(ts)" }
    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }

    var timeAgo: String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }
}

enum SlackParsing {
    /// Mentions older than this are not "recent" any more.
    static let mentionWindow: TimeInterval = 24 * 3600
    static let defaultRetry: TimeInterval = 60
    static let maxRetry: TimeInterval = 3600

    /// Seconds to wait after a 429: Retry-After, bounded so no value stops the poller for good.
    static func retryAfter(_ header: String?) -> TimeInterval {
        guard let wait = header.flatMap(Double.init), wait.isFinite else { return defaultRetry }
        return min(max(wait, 0), maxRetry)
    }

    /// The Web API answers HTTP 200 with `ok: false` and an error code.
    static func error(_ json: [String: Any]) -> String? {
        if json["ok"] as? Bool == true { return nil }
        let code = json["error"] as? String ?? "unknown_error"
        if code == "missing_scope", let needed = json["needed"] as? String {
            return "Missing scope: \(needed)"
        }
        switch code {
        case "invalid_auth", "not_authed", "token_revoked", "token_expired", "account_inactive":
            return "Invalid token"
        case "not_allowed_token_type":
            return "Use a user token (xoxp-…)"
        default:
            return "Slack error: \(code)"
        }
    }

    /// Errors about one conversation or person, not the token.
    static let missingCodes: Set<String> = ["channel_not_found", "channel_is_limited_access", "user_not_found"]

    /// One conversation or person Slack no longer finds: skip it, keep polling.
    static func isMissing(_ json: [String: Any]) -> Bool {
        guard json["ok"] as? Bool != true, let code = json["error"] as? String else { return false }
        return missingCodes.contains(code)
    }

    /// auth.test
    static func identity(_ json: [String: Any]) -> SlackIdentity? {
        guard json["ok"] as? Bool == true,
              let userId = json["user_id"] as? String,
              let teamId = json["team_id"] as? String else { return nil }
        return SlackIdentity(userId: userId, teamId: teamId, url: json["url"] as? String ?? "")
    }

    /// conversations.list?types=im — skips conversations with deactivated people.
    static func ims(_ json: [String: Any]) -> [SlackIM] {
        let channels = json["channels"] as? [[String: Any]] ?? []
        return channels.compactMap { c in
            guard c["is_im"] as? Bool == true,
                  c["is_user_deleted"] as? Bool != true,
                  let id = c["id"] as? String,
                  let user = c["user"] as? String else { return nil }
            let priority = (c["priority"] as? Double) ?? Double(c["priority"] as? Int ?? 0)
            return SlackIM(channelId: id, userId: user, priority: priority)
        }
    }

    /// conversations.info only gives unread counts one conversation at a time, so each
    /// poll looks at the `limit` closest people (Slack's `priority`) and at any
    /// conversation that was unread last time, so it is seen being read.
    static func imsToCheck(_ ims: [SlackIM], unread: Set<String>, limit: Int) -> [SlackIM] {
        let ranked = ims.sorted { $0.priority > $1.priority }
        var picked = Array(ranked.prefix(limit))
        for im in ranked.dropFirst(limit) where unread.contains(im.channelId) {
            picked.append(im)
        }
        return picked
    }

    /// conversations.info for a direct message: its latest message when it is unread
    /// and someone else sent it.
    static func unreadDM(_ json: [String: Any], me: String) -> SlackMessage? {
        guard let channel = json["channel"] as? [String: Any],
              let id = channel["id"] as? String else { return nil }
        let unread = (channel["unread_count_display"] as? Int) ?? 0
        guard unread > 0 else { return nil }
        let partner = channel["user"] as? String ?? ""
        let latest = channel["latest"] as? [String: Any]
        let author = latest?["user"] as? String ?? partner
        if author == me { return nil }
        return SlackMessage(kind: .dm, channelId: id, channelName: nil, userId: author,
                            author: author, text: latest?["text"] as? String ?? "",
                            ts: latest?["ts"] as? String ?? channel["last_read"] as? String ?? "0",
                            unread: unread, permalink: nil)
    }

    /// search.messages for "<@me>": the recent ones written by someone else.
    static func mentions(_ json: [String: Any], me: String, now: Date = Date()) -> [SlackMessage] {
        let matches = (json["messages"] as? [String: Any])?["matches"] as? [[String: Any]] ?? []
        return matches.compactMap { m in
            guard let ts = m["ts"] as? String,
                  let channel = m["channel"] as? [String: Any],
                  let channelId = channel["id"] as? String else { return nil }
            let user = m["user"] as? String ?? ""
            if user == me { return nil }
            let date = Date(timeIntervalSince1970: Double(ts) ?? 0)
            guard now.timeIntervalSince(date) <= mentionWindow else { return nil }
            let username = m["username"] as? String
            return SlackMessage(kind: .mention, channelId: channelId,
                                channelName: channel["name"] as? String, userId: user,
                                author: username?.isEmpty == false ? username! : user,
                                text: m["text"] as? String ?? "", ts: ts, unread: 0,
                                permalink: m["permalink"] as? String)
        }
    }

    /// conversations.info: the newest message the user has read there; nil without access.
    static func lastRead(_ json: [String: Any]) -> String? {
        guard json["ok"] as? Bool == true else { return nil }
        return (json["channel"] as? [String: Any])?["last_read"] as? String
    }

    /// Mentions newer than what the user has read in their channel; kept when that is unknown.
    static func unreadMentions(_ mentions: [SlackMessage], lastRead: [String: String]) -> [SlackMessage] {
        mentions.filter { m in lastRead[m.channelId].map { tsLess($0, m.ts) } ?? true }
    }

    /// users.info: the display name, else the real name, else the username.
    static func userName(_ json: [String: Any]) -> String? {
        guard let user = json["user"] as? [String: Any] else { return nil }
        let profile = user["profile"] as? [String: Any]
        for candidate in [profile?["display_name"], profile?["real_name"], user["real_name"], user["name"]] {
            if let name = candidate as? String, !name.isEmpty { return name }
        }
        return nil
    }

    /// Unread direct messages first, then mentions, each newest first.
    static func merged(dms: [SlackMessage], mentions: [SlackMessage]) -> [SlackMessage] {
        dms.sorted { tsLess($1.ts, $0.ts) } + mentions.sorted { tsLess($1.ts, $0.ts) }
    }

    /// The newest message, to tell a new one from one already announced.
    static func newest(_ messages: [SlackMessage]) -> SlackMessage? {
        messages.max { tsLess($0.ts, $1.ts) }
    }

    /// Slack timestamps ("1513718191.000038") carry more digits than a Double keeps:
    /// compare the seconds and the fraction as integers.
    static func tsLess(_ a: String, _ b: String) -> Bool {
        func parts(_ ts: String) -> (Int, Int) {
            let split = ts.split(separator: ".", maxSplits: 1)
            let seconds = Int(split.first ?? "") ?? 0
            let fraction = split.count > 1 ? Int(split[1].padding(toLength: 6, withPad: "0", startingAt: 0)) ?? 0 : 0
            return (seconds, fraction)
        }
        return parts(a) < parts(b)
    }

    /// Message text as one readable line: Slack's `<@U123>`, `<#C123|general>` and
    /// `<https://…|label>` markup resolved, entities unescaped.
    static func snippet(_ text: String, names: [String: String]) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            out += rest[..<open]
            let inner = rest[rest.index(after: open)..<close]
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            let target = parts.first ?? ""
            let label = parts.count > 1 ? parts[1] : nil
            if target.hasPrefix("@") {
                let id = String(target.dropFirst())
                out += "@" + (label ?? names[id] ?? id)
            } else if target.hasPrefix("#") {
                out += "#" + (label ?? String(target.dropFirst()))
            } else if target.hasPrefix("!") {
                out += "@" + (label ?? String(target.dropFirst()))
            } else {
                out += label ?? target
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        let unescaped = out
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return unescaped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Links

enum SlackLinks {
    /// Opens the conversation in the Slack app (docs.slack.dev/interactivity/deep-linking).
    /// With a permalink, also at the message and its thread: `message` and `thread_ts` are
    /// not in those docs, and the app ignores parameters it does not know.
    static func app(team: String, channel: String, permalink: String? = nil) -> URL? {
        var c = URLComponents()
        c.scheme = "slack"
        c.host = "channel"
        c.queryItems = [URLQueryItem(name: "team", value: team), URLQueryItem(name: "id", value: channel)]
        if let (ts, thread) = message(in: permalink) {
            c.queryItems?.append(URLQueryItem(name: "message", value: ts))
            if let thread { c.queryItems?.append(URLQueryItem(name: "thread_ts", value: thread)) }
        }
        return c.url
    }

    /// ".../archives/C1/p1699999000000100?thread_ts=1699998000.000200" gives the message's
    /// ts "1699999000.000100" and, for a reply, its thread's ts.
    static func message(in permalink: String?) -> (ts: String, thread: String?)? {
        func isTs(_ s: String) -> Bool {
            let parts = s.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        }
        guard let permalink, let c = URLComponents(string: permalink),
              let last = c.path.split(separator: "/").last, last.hasPrefix("p") else { return nil }
        let digits = last.dropFirst()
        guard digits.count > 6 else { return nil }
        let ts = "\(digits.dropLast(6)).\(digits.suffix(6))"
        guard isTs(ts) else { return nil }
        let thread = c.queryItems?.first { $0.name == "thread_ts" }?.value
        return (ts, thread.flatMap { isTs($0) && $0 != ts ? $0 : nil })
    }

    /// The same conversation in a browser: the message's permalink when there is one.
    static func web(team: String, channel: String, permalink: String?) -> URL? {
        if let permalink, let url = URL(string: permalink), url.scheme == "https" { return url }
        var c = URLComponents(string: "https://slack.com/app_redirect")!
        c.queryItems = [URLQueryItem(name: "channel", value: channel), URLQueryItem(name: "team", value: team)]
        return c.url
    }
}
