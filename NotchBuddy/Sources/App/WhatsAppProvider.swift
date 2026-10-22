#if !APPSTORE
import Foundation

// The two local WhatsApp gateways Coucou can talk to. Each call goes to the URL set in
// Settings (127.0.0.1 by default) and nowhere else: no photo, no media, nothing from
// WhatsApp's own servers. Endpoints, headers and bodies follow each gateway's docs (see
// WhatsAppGateway.swift for the references).

enum WAError: Error, Equatable {
    /// Nothing answers at that URL.
    case unreachable
    /// Wrong user:pass (GOWA) or API key (OpenWA).
    case unauthorized
    /// The gateway answered with an error (its own message, never a message's content).
    case refused(String)
    /// WhatsApp isn't linked yet.
    case notLoggedIn
}

protocol WhatsAppProvider: Sendable {
    var kind: WAGatewayKind { get }
    /// The link to WhatsApp (sets up the gateway's device or session the first time).
    func status() async throws -> WAStatus
    /// The QR to scan, as PNG bytes, and how long it stays valid; nil when there is none to
    /// show (already linked, not ready yet).
    func qrCode() async throws -> (png: Data, seconds: Int)?
    /// Tells the gateway to post new messages to Coucou's local webhook, signed with `secret`.
    func registerWebhook(url: String, secret: String) async throws
    /// Messages of every chat since `date` (the polling fallback), oldest first.
    func recentMessages(since date: Date, me: String?) async throws -> [WAMessage]
    /// The latest `limit` messages of one chat, oldest first.
    func messages(chat: String, limit: Int, me: String?) async throws -> [WAMessage]
    /// Sends a text to an existing chat; returns the new message's id when the gateway gives it.
    func send(text: String, to chat: String) async throws -> String?
    /// Marks the chat read up to `lastIncoming` (the newest message received in it).
    func markRead(chat: String, lastIncoming: String?) async throws
    /// A group's name, when the messages don't carry it.
    func groupName(_ chat: String) async -> String?
}

/// Never follows a redirect: a request (with its credentials and, for a send, the reply's
/// text) goes to the configured gateway and nowhere else.
final class WANoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// HTTP to the local gateway: no cookies, no cache, no redirect, nothing stored on disk.
final class WAHTTP: Sendable {
    let base: URL
    let headers: [String: String]
    private let session: URLSession

    init(base: URL, headers: [String: String]) {
        self.base = base
        self.headers = headers
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 60   // each request sets its own (10 s, longer for a QR)
        config.connectionProxyDictionary = [:]   // straight to the local gateway
        session = URLSession(configuration: config, delegate: WANoRedirect(), delegateQueue: nil)
    }

    /// `path` is appended to the base URL as given (already percent-encoded where needed).
    func call(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil,
              timeout: TimeInterval = 10) async throws -> (Data, Int) {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw WAError.unreachable }
        comps.percentEncodedPath = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? path : "/" + comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw WAError.unreachable }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: req)
            // Second lock: an answer from anywhere but the gateway is not one.
            if let final = response.url, final.host != url.host || final.port != url.port { throw WAError.unreachable }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        } catch {
            throw WAError.unreachable
        }
    }

    static func pathComponent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~@"))) ?? s
    }
}

// MARK: - GOWA

/// go-whatsapp-web-multidevice, `./whatsapp rest` (port 3000). Auth: HTTP basic `user:pass`
/// when the gateway was started with `--basic-auth`. Coucou works on one device (the one
/// already logged in, else a new one named "coucou"), named in `X-Device-Id`.
actor GOWAProvider: WhatsAppProvider {
    nonisolated let kind = WAGatewayKind.gowa
    private let http: WAHTTP
    private var deviceId: String?

    init(base: URL, basicAuth: String?) {
        var headers: [String: String] = [:]
        if let auth = basicAuth, auth.contains(":") {
            headers["Authorization"] = "Basic " + Data(auth.utf8).base64EncodedString()
        }
        http = WAHTTP(base: base, headers: headers)
    }

    private func check(_ data: Data, _ code: Int) throws {
        if code == 401 && WAGOWA.errorCode(data) != "AUTHENTICATION_ERROR" { throw WAError.unauthorized }
        if code == 401 { throw WAError.notLoggedIn }
        guard (200..<300).contains(code) else {
            throw WAError.refused(WAGOWA.errorCode(data) ?? "HTTP \(code)")
        }
    }

    /// The device to work on; created ("coucou") when the gateway has none.
    private func device() async throws -> (id: String, status: WAStatus) {
        let (data, code) = try await http.call("GET", "/devices")
        try check(data, code)
        if let found = WAGOWA.device(data) {
            deviceId = found.id
            return found
        }
        let (made, madeCode) = try await http.call("POST", "/devices", json: ["device_id": "coucou"])
        try check(made, madeCode)
        deviceId = "coucou"
        return ("coucou", WAStatus(link: .needsQR, me: nil))
    }

    private func scoped(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil) async throws -> Data {
        let id: String
        if let deviceId { id = deviceId } else { id = try await device().id }
        var q = query
        q.append(URLQueryItem(name: "device_id", value: id))
        let (data, code) = try await http.call(method, path, query: q, json: json)
        try check(data, code)
        return data
    }

    func status() async throws -> WAStatus {
        try await device().status
    }

    func qrCode() async throws -> (png: Data, seconds: Int)? {
        let id: String
        if let deviceId { id = deviceId } else { id = try await device().id }
        // GOWA answers once WhatsApp has handed it the first code: a few seconds.
        let (data, code) = try await http.call("GET", "/devices/\(WAHTTP.pathComponent(id))/login", timeout: 45)
        if WAGOWA.errorCode(data) == "ALREADY_LOGGED_IN" { return nil }
        try check(data, code)
        guard let qr = WAGOWA.qrPath(data) else { return nil }
        // The PNG is served by the gateway itself under /statics: fetched from the configured
        // URL, whatever host the link names.
        let (png, pngCode) = try await http.call("GET", qr.path)
        guard pngCode == 200, png.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        // qr_duration is half the code's life (the PNG is deleted then, the code stays valid):
        // asking again sooner would restart the pairing under the user's phone.
        return (png, max(20, qr.seconds * 2 - 5))
    }

    func registerWebhook(url: String, secret: String) async throws {
        let id: String
        if let deviceId { id = deviceId } else { id = try await device().id }
        let (data, code) = try await http.call("PATCH", "/devices/\(WAHTTP.pathComponent(id))/webhook", json: [
            "webhook_url": url, "webhook_secret": secret, "webhook_events": "message",
        ])
        try check(data, code)
    }

    func recentMessages(since date: Date, me: String?) async throws -> [WAMessage] {
        let chats = WAGOWA.chats(try await scoped("GET", "/chats", query: [URLQueryItem(name: "limit", value: "20")]))
        var out: [WAMessage] = []
        // Only the chats that moved since `date` (sorted newest first by the gateway).
        for chat in chats.prefix(8) where chat.last > date {
            let data = try await scoped("GET", "/chat/\(WAHTTP.pathComponent(chat.jid))/messages", query: [
                URLQueryItem(name: "limit", value: "10"),
                URLQueryItem(name: "start_time", value: WADate.iso(date)),
            ])
            out += WAGOWA.messages(data, me: me).map { m in
                var m = m
                if m.chatName == nil, !chat.name.isEmpty, WAJID.isGroup(chat.jid) { m.chatName = chat.name }
                return m
            }
        }
        return out.sorted { $0.date < $1.date }
    }

    func messages(chat: String, limit: Int, me: String?) async throws -> [WAMessage] {
        let data = try await scoped("GET", "/chat/\(WAHTTP.pathComponent(chat))/messages",
                                    query: [URLQueryItem(name: "limit", value: String(limit))])
        return WAGOWA.messages(data, me: me).sorted { $0.date < $1.date }
    }

    func send(text: String, to chat: String) async throws -> String? {
        let data = try await scoped("POST", "/send/message", json: ["phone": chat, "message": text])
        return (WAGOWA.results(data) as? [String: Any])?["message_id"] as? String
    }

    func markRead(chat: String, lastIncoming: String?) async throws {
        guard let id = lastIncoming else { return }
        _ = try await scoped("POST", "/message/\(WAHTTP.pathComponent(id))/read", json: ["phone": chat])
    }

    func groupName(_ chat: String) async -> String? {
        guard WAJID.isGroup(chat),
              let data = try? await scoped("GET", "/group/info", query: [URLQueryItem(name: "group_id", value: chat)]),
              let r = WAGOWA.results(data) as? [String: Any],
              let name = r["Name"] as? String, !name.isEmpty else { return nil }
        return name
    }
}

// MARK: - OpenWA

/// OpenWA (port 2785, every route under /api). Auth: `X-API-Key`. Coucou works on one session
/// (the one ready, else one named "coucou", created and started when missing).
actor OpenWAProvider: WhatsAppProvider {
    nonisolated let kind = WAGatewayKind.openwa
    private let http: WAHTTP
    private var sessionId: String?

    init(base: URL, apiKey: String?) {
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty { headers["X-API-Key"] = apiKey }
        http = WAHTTP(base: base, headers: headers)
    }

    private func check(_ data: Data, _ code: Int) throws {
        if code == 401 || code == 403 { throw WAError.unauthorized }
        guard (200..<300).contains(code) else {
            throw WAError.refused(WAOpenWA.errorMessage(data) ?? "HTTP \(code)")
        }
    }

    private func session() async throws -> (id: String, status: String, phone: String?) {
        let (data, code) = try await http.call("GET", "/api/sessions")
        try check(data, code)
        let all = ((try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []).compactMap(WAOpenWA.session)
        let pick = all.first { $0.status == "ready" }
            ?? all.first { ($0.id == sessionId) }
            ?? named("coucou", in: data) ?? all.first
        if var s = pick {
            sessionId = s.id
            if WAOpenWA.needsStart(s.status) {
                let (started, startCode) = try await http.call("POST", "/api/sessions/\(s.id)/start")
                try check(started, startCode)
                s = WAOpenWA.session(try? JSONSerialization.jsonObject(with: started)) ?? s
            }
            return s
        }
        let (made, madeCode) = try await http.call("POST", "/api/sessions", json: ["name": "coucou"])
        try check(made, madeCode)
        guard let s = WAOpenWA.session(try? JSONSerialization.jsonObject(with: made)) else { throw WAError.refused("session") }
        sessionId = s.id
        let (started, startCode) = try await http.call("POST", "/api/sessions/\(s.id)/start")
        try check(started, startCode)
        return WAOpenWA.session(try? JSONSerialization.jsonObject(with: started)) ?? s
    }

    private func named(_ name: String, in data: Data) -> (id: String, status: String, phone: String?)? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let s = list.first(where: { $0["name"] as? String == name }) else { return nil }
        return WAOpenWA.session(s)
    }

    private func sid() async throws -> String {
        if let sessionId { return sessionId }
        return try await session().id
    }

    private func scoped(_ method: String, _ path: String, query: [URLQueryItem] = [], json: [String: any Sendable]? = nil) async throws -> Data {
        let id = try await sid()
        let (data, code) = try await http.call(method, "/api/sessions/\(id)" + path, query: query, json: json)
        try check(data, code)
        return data
    }

    func status() async throws -> WAStatus {
        WAOpenWA.status(try await session())
    }

    func qrCode() async throws -> (png: Data, seconds: Int)? {
        let id = try await sid()
        let (data, code) = try await http.call("GET", "/api/sessions/\(id)/qr")
        if code == 400 { return nil }   // not started, already linked, or not ready yet
        try check(data, code)
        // The QR turns every 20 s or so on WhatsApp's side: asked again after 15.
        return WAOpenWA.qrPNG(data).map { ($0, 15) }
    }

    func registerWebhook(url: String, secret: String) async throws {
        let id = try await sid()
        let body: [String: any Sendable] = ["url": url, "events": ["message.received", "message.sent"], "secret": secret]
        let (list, listCode) = try await http.call("GET", "/api/sessions/\(id)/webhooks")
        try check(list, listCode)
        let hooks = (try? JSONSerialization.jsonObject(with: list)) as? [[String: Any]] ?? []
        if let mine = hooks.first(where: { $0["url"] as? String == url }), let hookId = mine["id"] as? String {
            let (data, code) = try await http.call("PUT", "/api/sessions/\(id)/webhooks/\(hookId)", json: body)
            try check(data, code)
        } else {
            let (data, code) = try await http.call("POST", "/api/sessions/\(id)/webhooks", json: body)
            try check(data, code)
        }
    }

    func recentMessages(since date: Date, me: String?) async throws -> [WAMessage] {
        let data = try await scoped("GET", "/messages", query: [
            URLQueryItem(name: "since", value: String(Int64(date.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "inlineMedia", value: "false"),
        ])
        return WAOpenWA.messages(data, me: me).sorted { $0.date < $1.date }
    }

    func messages(chat: String, limit: Int, me: String?) async throws -> [WAMessage] {
        let data = try await scoped("GET", "/messages", query: [
            URLQueryItem(name: "chatId", value: Self.openwaId(chat)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "inlineMedia", value: "false"),
        ])
        return WAOpenWA.messages(data, me: me).sorted { $0.date < $1.date }
    }

    func send(text: String, to chat: String) async throws -> String? {
        let data = try await scoped("POST", "/messages/send-text", json: ["chatId": Self.openwaId(chat), "text": text])
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["messageId"] as? String
    }

    func markRead(chat: String, lastIncoming: String?) async throws {
        _ = try await scoped("POST", "/chats/read", json: ["chatId": Self.openwaId(chat)])
    }

    func groupName(_ chat: String) async -> String? {
        guard WAJID.isGroup(chat),
              let data = try? await scoped("GET", "/groups/\(WAHTTP.pathComponent(chat))"),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty else { return nil }
        return name
    }

    /// OpenWA names people `<number>@c.us` (Coucou keeps the @s.whatsapp.net form inside).
    static func openwaId(_ jid: String) -> String {
        jid.hasSuffix("@s.whatsapp.net") ? jid.replacingOccurrences(of: "@s.whatsapp.net", with: "@c.us") : jid
    }
}
#endif
