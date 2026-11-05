import Foundation

// MARK: - Hermes agents (self-hosted, OpenAI-compatible API server)

/// How an agent is reached: with the profile's API key (OpenAI-compatible server) or by signing in
/// with the Hermes server (dashboard gateway). A stored agent without the field reads as `apiKey`.
enum HermesConnection: String, Codable, Sendable {
    case apiKey
    case signIn
}

/// One configured Hermes agent. The API key (or sign-in session) is NOT part of this struct: it lives only in the Keychain.
struct HermesAgent: Codable, Equatable, Sendable {
    /// Unique id and label, e.g. "mark".
    var name: String
    /// Normalised origin, e.g. "https://agent.example.com" (no trailing slash).
    var baseURL: String
    /// "" or "default" = unprefixed routes.
    var profile: String
    /// Id returned by `GET /v1/models` at connect time, fallback "hermes-agent".
    var modelName: String
    /// `nil` reads as `.apiKey` (agents stored before the sign-in kind existed).
    var connection: HermesConnection?
    /// What the user reads instead of `name` (pill, chat, Settings). `nil` = the identity name. Not a secret; it never
    /// takes part in the Keychain binding, the pill id or the conversation, so renaming never disconnects an agent.
    var displayName: String?

    /// The name shown everywhere the agent appears.
    var shownName: String { displayName ?? name }

    /// Same agent at the same destination: ignores the display name, which is only a label.
    func sameDestination(as other: HermesAgent) -> Bool {
        name == other.name && baseURL == other.baseURL && profile == other.profile
            && modelName == other.modelName && connection == other.connection
    }
}

enum HermesChatError: Error, Equatable {
    case invalidURL
    case insecureURL
    case unauthorized
    case notFound
    case busy
    case notHermes
    /// Associated value is the host only (never the full URL).
    case unreachable(String)
    case server(String)
    case agentFailed(String)
    /// The stored agent no longer matches the destination its key was bound to. Associated value is the agent name.
    case notBound(String)
    /// No usable sign-in session for this agent. Associated value is the agent name.
    case signInNeeded(String)
    /// Associated value is a message that is safe to show (never a server text, token or URL).
    case signInFailed(String)

    var userMessage: String {
        switch self {
        case .invalidURL:    return String(localized: "Enter a URL like https://hermes.example.com.")
        case .insecureURL:   return String(localized: "Use https:// for this host. http:// is only allowed for localhost and private addresses.")
        case .unauthorized:  return String(localized: "Hermes refused the API key. Each profile has its own key.")
        case .notFound:      return String(localized: "Hermes has no such profile at this URL. Check the profile name.")
        case .busy:          return String(localized: "The agent is busy. Try again in a moment.")
        case .notHermes:     return String(localized: "This URL doesn't answer like a Hermes API server. Use the API address, not the dashboard.")
        case .unreachable(let host): return String(localized: "Can't reach Hermes at \(host). Is the gateway running?")
        case .server(let m), .agentFailed(let m): return m
        case .notBound(let name): return String(localized: "\(name) changed since it was connected, so its key was not sent. Disconnect it and connect it again in Settings → Chat.")
        case .signInNeeded(let name): return String(localized: "Sign in to \(name) again in Settings → Chat.")
        case .signInFailed(let m): return m
        }
    }
}

enum HermesChat {

    // MARK: URL handling

    /// Strips a trailing `/v1` and `/p/<profile>`. `profile` is set only when the URL ended in `/p/<profile>/v1`.
    private static func stripAPIPath(_ raw: String) -> (base: String, profile: String?) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        let hadV1 = s.hasSuffix("/v1")
        if hadV1 { s = String(s.dropLast(3)) }
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        var profile: String?
        // trailing /p/<profile>
        if let r = s.range(of: "/p/", options: .backwards),
           !s[r.upperBound...].contains("/"), !s[r.upperBound...].isEmpty {
            if hadV1 { profile = String(s[r.upperBound...]) }
            s = String(s[..<r.lowerBound])
        }
        return (s, profile)
    }

    /// The profile named by a pasted `.../p/NAME/v1` URL, when it is a valid profile name.
    static func profileInURL(_ raw: String) -> String? {
        guard let p = stripAPIPath(raw).profile, !p.isEmpty, isValidProfile(p) else { return nil }
        return p
    }

    static func normaliseBaseURL(_ raw: String) -> Result<String, HermesChatError> {
        let s = stripAPIPath(raw).base
        guard let url = safeWebURL(s),
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host, !host.isEmpty else { return .failure(.invalidURL) }
        if scheme == "http" && !isLocalHost(host) { return .failure(.insecureURL) }
        let hostPart = host.contains(":") ? "[\(host)]" : host
        var out = "\(scheme)://\(hostPart)"
        if let port = url.port { out += ":\(port)" }
        var path = url.path
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        out += path
        return .success(out)
    }

    /// True for hosts where plain http is acceptable (loopback, private IP literals, 100.64.0.0/10,
    /// `.local` names and other single-label names). All-digit and `0x` single labels are rejected:
    /// a resolver may read them as a public IPv4 address.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        if let v4 = ipv4(h) {
            switch (v4[0], v4[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        if h.contains(":") {
            // IPv6 literal: fc00::/7 and fe80::/10
            guard let first = h.split(separator: ":", omittingEmptySubsequences: false).first,
                  let word = UInt16(first.isEmpty ? "0" : String(first), radix: 16) else { return false }
            return (word & 0xFE00) == 0xFC00 || (word & 0xFFC0) == 0xFE80
        }
        // single-label hostname (e.g. "mac-mini")
        guard !h.contains(".") else { return false }
        if h.allSatisfy({ $0.isASCII && $0.isNumber }) { return false }
        if h.hasPrefix("0x") { return false }
        return true
    }

    /// True when `baseURL` is plain http to a host that is a name (not an IP literal, not localhost):
    /// the key then travels unencrypted to whoever answers that name on the network.
    static func sendsKeyUnencryptedToName(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.contains(":") || ipv4(host) != nil { return false }
        return true
    }

    private static func ipv4(_ h: String) -> [Int]? {
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let n = Int(p), (0...255).contains(n), String(n) == p || p == "0" else { return nil }
            out.append(n)
        }
        return out
    }

    static func isValidProfile(_ p: String) -> Bool {
        if p.isEmpty { return true }
        guard p.count <= 64 else { return false }
        return p.unicodeScalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) ||
            ($0.value >= 97 && $0.value <= 122) || $0 == "_" || $0 == "-"
        }
    }

    static func apiRoot(baseURL: String, profile: String) -> String {
        (profile.isEmpty || profile == "default") ? baseURL : "\(baseURL)/p/\(profile)"
    }

    static func chatURL(for agent: HermesAgent) -> URL? {
        guard isValidAgent(agent) else { return nil }
        return URL(string: apiRoot(baseURL: agent.baseURL, profile: agent.profile) + "/v1/chat/completions")
    }

    static func modelsURL(baseURL: String, profile: String) -> URL? {
        guard isValidProfile(profile) else { return nil }
        return URL(string: apiRoot(baseURL: baseURL, profile: profile) + "/v1/models")
    }

    // MARK: Parsing

    /// A chunk whose `finish_reason` is set and not "stop" means the agent failed after the stream started.
    static func parseStreamFailure(_ line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        guard payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let reason = choice["finish_reason"] as? String, reason != "stop" else { return nil }
        let err = (json["error"] as? [String: Any]) ?? (choice["error"] as? [String: Any])
        if let m = err?["message"] as? String, !m.isEmpty { return String(m.prefix(200)) }
        return String(localized: "The agent stopped with an error.")
    }

    static func error(status: Int, body: Data) -> HermesChatError {
        switch status {
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 429, 503: return .busy
        case 300..<400: return .notHermes
        default:
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let m = (json["error"] as? [String: Any])?["message"] as? String, !m.isEmpty {
                return .server(String(m.prefix(200)))
            }
            return .server("HTTP \(status)")
        }
    }

    // MARK: Persistence encoding (agents → UserDefaults, keys → one Keychain item)

    /// An agent as stored: name set, base URL already in normalised form (so it round-trips) and a valid profile.
    static func isValidAgent(_ a: HermesAgent) -> Bool {
        guard !a.name.isEmpty, isValidProfile(a.profile),
              case .success(let n) = normaliseBaseURL(a.baseURL), n == a.baseURL else { return false }
        return true
    }

    /// Drops entries that do not round-trip through the URL and profile rules, and duplicate names (first wins).
    static func sanitiseAgents(_ agents: [HermesAgent]) -> [HermesAgent] {
        var seen = Set<String>()
        return agents.filter { isValidAgent($0) && seen.insert($0.name).inserted }
    }

    static func encodeAgents(_ agents: [HermesAgent]) -> String {
        guard let d = try? JSONEncoder().encode(agents) else { return "[]" }
        return String(decoding: d, as: UTF8.self)
    }

    static func decodeAgents(_ s: String) -> [HermesAgent] {
        sanitiseAgents((try? JSONDecoder().decode([HermesAgent].self, from: Data(s.utf8))) ?? [])
    }

    /// What the Keychain holds per agent: the key and the destination it was connected to.
    struct KeyRecord: Codable, Equatable, Sendable {
        var key: String
        var baseURL: String
        var profile: String
    }

    static func encodeKeys(_ keys: [String: KeyRecord]) -> String {
        guard let d = try? JSONEncoder().encode(keys) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Reads the bound format. The previous format (name to key only) is returned with an empty
    /// `baseURL`, which never matches an agent: it counts as not bound.
    static func decodeKeys(_ s: String) -> [String: KeyRecord] {
        let data = Data(s.utf8)
        if let bound = try? JSONDecoder().decode([String: KeyRecord].self, from: data) { return bound }
        if let old = try? JSONDecoder().decode([String: String].self, from: data) {
            return old.mapValues { KeyRecord(key: $0, baseURL: "", profile: "") }
        }
        return [:]
    }

    /// The key for `agent`, only when the stored record is bound to exactly this base URL and profile.
    /// Otherwise the request must not be made.
    static func boundKey(for agent: HermesAgent, in keys: [String: KeyRecord]) -> Result<String, HermesChatError> {
        guard isValidAgent(agent),
              let r = keys[agent.name], !r.key.isEmpty,
              !r.baseURL.isEmpty, r.baseURL == agent.baseURL, r.profile == agent.profile else {
            return .failure(.notBound(agent.shownName))
        }
        return .success(r.key)
    }

    // MARK: Connection retry

    /// Retry policy for a connection that fails to OPEN. Pure data and functions: nothing here touches the network.
    /// An HTTP answer of any status, and anything after the first response byte, is never retried.
    struct ConnectRetry: Sendable, Equatable {
        /// What a repeat of the request can cause on the server.
        enum Rule: Sendable, Equatable {
            /// GET, WebSocket handshake, ticket POST: repeating changes nothing (a ticket request only mints one more
            /// single use ticket). Connect level errors and "connection lost" are retried.
            case idempotent
            /// A POST whose body has an effect (chat completions, token refresh): retried ONLY when it is certain that
            /// no body byte left the machine (`bytesSent == 0`) and the error is a connect level one.
            case sideEffects
        }

        /// Attempts in total (the first one included).
        var attempts = 3
        /// How long one attempt may wait for its connection to open (REST, WebSocket handshake, response headers).
        var attemptTimeout: TimeInterval = 6
        /// Wait before attempt 2, then before attempt 3.
        var backoff: [TimeInterval] = [0.3, 1]
        /// Total time one turn may spend opening connections (refresh, tickets, handshakes), ready waits excluded.
        /// Three attempts of one step (3 x 6 s + 1.3 s of backoff = 19.3 s) plus about 10 s of round trips that
        /// succeed (tickets) so that the third handshake attempt is still allowed on a real network.
        var budget: TimeInterval = 30
        static let standard = ConnectRetry()

        /// The wait before the next attempt after attempt `n` (1 based) failed; nil when no attempt is left.
        func delay(afterAttempt n: Int) -> TimeInterval? {
            guard n >= 1, n < attempts else { return nil }
            return backoff.isEmpty ? 0 : backoff[min(n - 1, backoff.count - 1)]
        }

        /// Whether a failure with `code` may be repeated. `bytesSent` is the number of request body bytes that left
        /// the machine, read from the task at the moment of the error; nil when it could not be read (unknown).
        /// - `.sideEffects`: "cannot connect", "cannot find host", DNS and TLS setup failures are retried unless the
        ///   task is known to have sent body bytes; "timed out" and "connection lost" only when `bytesSent == 0`
        ///   (known zero). Any error with bytes sent is final, whatever its code.
        /// - `.idempotent`: those and "connection lost"; a timeout only when no body byte went out (a timeout after
        ///   that means a slow server).
        func isRetryable(_ code: URLError.Code, rule: Rule, bytesSent: Int64?) -> Bool {
            switch code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                if rule == .sideEffects, let n = bytesSent, n > 0 { return false }
                return true
            case .networkConnectionLost:
                return rule == .idempotent || bytesSent == 0
            case .timedOut:
                return (bytesSent ?? (rule == .idempotent ? 0 : -1)) == 0
            default:
                return false
            }
        }

        /// Whether another attempt may start now, given the turn's connect deadline (nil: no deadline).
        func mayRetry(afterAttempt n: Int, now: ContinuousClock.Instant, deadline: ContinuousClock.Instant?) -> TimeInterval? {
            guard let d = delay(afterAttempt: n) else { return nil }
            if let deadline, now.advanced(by: .seconds(d + attemptTimeout)) > deadline { return nil }
            return d
        }
    }

    /// Step names and attempt counts only, never a URL, token or text. The app points it at nb.log.
    enum Diagnostics {
        private final class Sink: @unchecked Sendable {
            let lock = NSLock()
            var fn: (@Sendable (String) -> Void)?
        }
        private static let sink = Sink()
        static func setSink(_ f: (@Sendable (String) -> Void)?) { sink.lock.withLock { sink.fn = f } }
        static func log(_ message: String) {
            let f = sink.lock.withLock { sink.fn }
            f?(message)
        }
        static func failed(step: String, attempts: Int) { log("hermes connect failed step=\(step) attempts=\(attempts)") }
        static func recovered(step: String, attempts: Int) { log("hermes connect recovered step=\(step) attempts=\(attempts)") }
        /// A request that failed for a reason that is not "the connection could not be opened" (or that was not safe to
        /// repeat): `sent` is true when body bytes had left the machine.
        static func requestFailed(step: String, attempts: Int, sent: Bool) {
            log("hermes request failed step=\(step) attempts=\(attempts) sent=\(sent)")
        }
    }

    /// Thrown inside a retried operation for a failure that happened before the request could have had any effect.
    struct ConnectFailure: Error { var code: URLError.Code }

    /// Runs `operation` (given its 1 based attempt number) up to `policy.attempts` times while it throws
    /// `ConnectFailure`. Any other error ends it at once. Cancellation is honoured before every attempt and during
    /// every backoff.
    static func withConnectRetry<T>(step: String, policy: ConnectRetry, deadline: ContinuousClock.Instant? = nil,
                                    _ operation: (Int) async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                let v = try await operation(attempt)
                if attempt > 1 { Diagnostics.recovered(step: step, attempts: attempt) }
                return v
            } catch let f as ConnectFailure {
                if Task.isCancelled { throw CancellationError() }
                guard let wait = policy.mayRetry(afterAttempt: attempt, now: .now, deadline: deadline) else {
                    Diagnostics.failed(step: step, attempts: attempt)
                    throw f
                }
                try await Task.sleep(for: .seconds(wait))
                attempt += 1
            }
        }
    }

    /// Task delegate for one request: refuses redirects and keeps the task, so that the number of body bytes that left
    /// the machine is read from the task itself at the moment of an error (not from a delegate callback that may still
    /// be queued). `didSendBodyData` only adds to that, as a second witness.
    final class RequestGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var sentSeen = false
        private var fired = false
        /// Body bytes sent so far; nil when the task was never seen (unknown).
        var bytesSent: Int64? {
            lock.withLock {
                if task == nil && !sentSeen { return nil }
                return max(task?.countOfBytesSent ?? 0, sentSeen ? 1 : 0)
            }
        }
        var watchdogFired: Bool { lock.withLock { fired } }
        func markWatchdog() { lock.withLock { fired = true } }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            lock.withLock { self.task = task }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            lock.withLock { sentSeen = true; self.task = task }
        }
    }

    /// The response headers of one request, plus the session that owns the byte stream (the caller invalidates it).
    struct Opened: @unchecked Sendable {
        let session: URLSession
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
    }

    /// Opens `req` and returns at the response headers, retrying only connect level failures (see `ConnectRetry`).
    /// `rule` says what a repeat can cause: the default `.sideEffects` repeats only when no body byte left the machine.
    /// The connection gets `attemptTimeout` to open: until the body went out (a request that sent bytes is never cut
    /// short or repeated). A request without a body (GET) cannot tell "connecting" from "waiting for the server", so
    /// the first attempts are cut at `attemptTimeout` and the LAST one keeps the request's own timeout: a slow but
    /// healthy server answers within its old allowance, as it did before retries existed.
    /// Once a response arrived nothing is retried. Throws `unreachable(host)` or `CancellationError`.
    static func open(_ req: URLRequest, step: String, host: String, policy: ConnectRetry,
                     rule: ConnectRetry.Rule = .sideEffects,
                     deadline: ContinuousClock.Instant? = nil,
                     makeSession: @Sendable () -> URLSession) async throws -> Opened {
        do {
            return try await withConnectRetry(step: step, policy: policy, deadline: deadline) { attempt in
                let s = makeSession()
                let gate = RequestGate()
                let task = Task { try await s.bytes(for: req, delegate: gate) }
                let boundConnect = !(req.httpBody == nil && attempt >= policy.attempts)
                let watchdog = Task {
                    guard boundConnect else { return }
                    try? await Task.sleep(for: .seconds(policy.attemptTimeout))
                    if !Task.isCancelled, (gate.bytesSent ?? 0) == 0 { gate.markWatchdog(); task.cancel() }
                }
                defer { watchdog.cancel() }
                do {
                    let (bytes, response) = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                    return Opened(session: s, bytes: bytes, response: response)
                } catch {
                    // Decided here, from the task, at the moment of the error.
                    let sent = gate.bytesSent
                    s.invalidateAndCancel()
                    if Task.isCancelled { throw CancellationError() }
                    let code = gate.watchdogFired ? URLError.Code.timedOut : (error as? URLError)?.code
                    if let code, policy.isRetryable(code, rule: rule, bytesSent: sent) { throw ConnectFailure(code: code) }
                    Diagnostics.requestFailed(step: step, attempts: attempt, sent: (sent ?? 0) > 0)
                    throw HermesChatError.unreachable(host)
                }
            }
        } catch is ConnectFailure {
            throw HermesChatError.unreachable(host)
        }
    }

    // MARK: Network

    /// What one server may make the app buffer or wait for.
    struct Limits: Sendable {
        var connectBodyBytes = 64 * 1024
        var lineBytes = 256 * 1024
        var textChars = 200_000
        var duration: TimeInterval = 15 * 60
        // Sign-in transport only (HermesSignInNet).
        /// Retry once with the ticket in the query when the subprotocol form is refused.
        var allowQueryTicketFallback = true
        var readyTimeout: TimeInterval = 15
        /// How a connection that fails to open is retried (REST, WebSocket handshake, API key requests).
        var connectRetry = ConnectRetry.standard
        var rpcTimeout: TimeInterval = 30
        var pingInterval: TimeInterval = 15
        /// Per turn budget of text frames and bytes (ignored frames count); over it the turn ends like the text cap.
        var maxFrames = 100_000
        var maxBytes = 64 * 1024 * 1024
        static let standard = Limits()
    }

    static let interruptedNote = String(localized: "(The answer was interrupted.)")
    static let tooLongNote = String(localized: "(The answer was cut: it went over the size limit.)")
    static let tooSlowNote = String(localized: "(The answer was cut: it took longer than 15 minutes.)")
    /// Shared with the sign in transport (`HermesSignIn.approvalNote`): the one sentence for an approval nobody answered.
    static let approvalNote = String(localized: "(The agent needed an approval that Coucou cannot give yet. Approve it in the Hermes app.)")

    private static func session() -> URLSession { URLSession(configuration: .ephemeral) }

    static func hostLabel(_ baseURL: String) -> String {
        URL(string: baseURL)?.host ?? String(localized: "the server")
    }

    /// `GET /v1/models` with the key. The only request made during setup. Returns the model name.
    static func connect(baseURL: String, profile: String, key: String, limits: Limits = .standard) async -> Result<String, HermesChatError> {
        guard let url = modelsURL(baseURL: baseURL, profile: profile) else { return .failure(.invalidURL) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var data = Data()
        let response: URLResponse
        do {
            let opened = try await open(req, step: "models", host: hostLabel(baseURL), policy: limits.connectRetry,
                                        rule: .idempotent, makeSession: { session() })
            defer { opened.session.finishTasksAndInvalidate() }
            response = opened.response
            for try await b in opened.bytes {
                data.append(b)
                if data.count > limits.connectBodyBytes {
                    return .failure(.server(String(localized: "The server answer is too large for a Hermes API.")))
                }
            }
        } catch {
            return .failure(.unreachable(hostLabel(baseURL)))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { return .failure(error(status: status, body: data)) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]],
              let id = list.first?["id"] as? String, !id.isEmpty else { return .failure(.notHermes) }
        return .success(id)
    }

    /// True when the line says the stream finished normally.
    static func isStreamComplete(_ line: String) -> Bool {
        guard line.hasPrefix("data: ") else { return false }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" { return true }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first else { return false }
        return (choice["finish_reason"] as? String) == "stop"
    }

    // MARK: Steps (named frames)

    /// Pairs an `event:` line with the `data:` line that follows it. A blank line ends the frame.
    struct SSEFrames {
        private var event: String?
        /// The frame a line completes: the event name (nil for a plain data frame) and the JSON text.
        mutating func feed(_ line: String) -> (event: String?, data: String)? {
            if line.isEmpty { event = nil; return nil }
            if line.hasPrefix(":") { return nil }
            if line.hasPrefix("event:") {
                let name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                event = name.isEmpty ? nil : String(name.prefix(64))
                return nil
            }
            if line.hasPrefix("data: ") {
                let name = event
                event = nil
                return (name, String(line.dropFirst(6)))
            }
            return nil
        }
    }

    /// What a `hermes.tool.progress` frame says. Only these four fields are read: `emoji` and anything else are not.
    struct ToolProgress: Equatable {
        var id: String
        var tool: String
        var label: String
        var running: Bool
    }

    static func parseToolProgress(_ data: String) -> ToolProgress? {
        guard let d = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tool = json["tool"] as? String, !ChatTurnBuilder.cleanTool(tool).isEmpty,
              let id = json["toolCallId"] as? String, !id.isEmpty,
              let status = json["status"] as? String else { return nil }
        switch status {
        case "running": return ToolProgress(id: id, tool: tool, label: (json["label"] as? String) ?? "", running: true)
        case "completed": return ToolProgress(id: id, tool: tool, label: "", running: false)
        default: return nil
        }
    }

    /// The messages of a Hermes API key request: the stored history, with a message made of blocks reduced to its
    /// text. Roles and text only: rows, steps, notes and previews live in `ChatMessage.segments` and never get here.
    static func requestMessages(from stored: [[String: Any]]) -> [[String: Any]] {
        var msgs: [[String: Any]] = []
        for m in stored {
            var simplified = m
            if let content = m["content"] as? [[String: Any]],
               let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                simplified["content"] = text
            }
            msgs.append(simplified)
        }
        return msgs
    }

    /// The rows of a turn for the chat: the same think-block filtering as the text, and no row left empty by it.
    /// A block that opens in one row and closes in a later one (a tool in between) is hidden in both: the state
    /// "inside a block" is carried from row to row, as the text is filtered whole. Reasoning never reaches a row.
    static func displaySegments(_ segments: [ChatSegment]) -> [ChatSegment] {
        var inside = false
        return segments.compactMap { seg in
            guard case .text(let t, let role) = seg.kind else { return seg }
            let visible = visibleText(t, inside: &inside)
            return visible.isEmpty ? nil : ChatSegment(id: seg.id, kind: .text(visible, role: role))
        }
    }

    /// The rows at the end of the turn: filtered with the rule of the string the turn returns (closed blocks only,
    /// across rows), so the screen and the stored text agree. A `<think>` that never closes, or one an answer merely
    /// names in inline code, hides nothing: the text holds it too. While the turn runs `displaySegments` may hide it.
    static func finalDisplaySegments(_ segments: [ChatSegment]) -> [ChatSegment] {
        let sep = "\n\n"
        var joined = ""
        var spans: [Int: (start: Int, end: Int)] = [:]      // row index -> UTF-16 range in `joined`
        for (i, seg) in segments.enumerated() {
            guard case .text(let t, _) = seg.kind else { continue }
            if !joined.isEmpty { joined += sep }
            let start = joined.utf16.count
            joined += t
            spans[i] = (start, joined.utf16.count)
        }
        let ns = joined as NSString
        var blocks: [NSRange] = []
        if joined.contains("<think>"), let regex = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>") {
            blocks = regex.matches(in: joined, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        var out: [ChatSegment] = []
        for (i, seg) in segments.enumerated() {
            guard case .text(_, let role) = seg.kind, let span = spans[i] else { out.append(seg); continue }
            var visible = ""
            var pos = span.start
            for b in blocks {
                let lo = max(b.location, span.start), hi = min(b.location + b.length, span.end)
                guard lo < hi else { continue }
                if lo > pos { visible += ns.substring(with: NSRange(location: pos, length: lo - pos)) }
                pos = max(pos, hi)
            }
            if pos < span.end { visible += ns.substring(with: NSRange(location: pos, length: span.end - pos)) }
            visible = visible.trimmingCharacters(in: .whitespacesAndNewlines)
            if !visible.isEmpty { out.append(ChatSegment(id: seg.id, kind: .text(visible, role: role))) }
        }
        return out
    }

    /// `LocalChat.progressiveFilter` for one row, starting inside a block or not, and telling whether it ends inside one.
    private static func visibleText(_ t: String, inside: inout Bool) -> String {
        if !inside, !t.contains("<think>") { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = ""
        var rest = Substring(t)
        while !rest.isEmpty {
            if inside {
                guard let close = rest.range(of: "</think>") else { break }
                rest = rest[close.upperBound...]
                inside = false
            } else {
                guard let open = rest.range(of: "<think>") else { out += rest; break }
                out += rest[..<open.lowerBound]
                rest = rest[open.upperBound...]
                inside = true
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text and end-of-stream state gathered from the SSE lines.
    private struct StreamState {
        var text = ""
        var chars = 0
        var failure: String?
        var complete = false
        var overLimit = false
        var frames = SSEFrames()
        /// Steps, notes and roles: display only. Nothing here reaches `text`, the returned string or a request.
        var turn = ChatTurnBuilder()

        /// What a line changed: the text grew, a step or a note changed.
        struct Change { var text = false; var steps = false }

        /// `approval.request` frames seen and not yet dealt with by the loop.
        var approvalData: [String] = []

        mutating func takeApprovalData() -> [String] {
            let d = approvalData
            approvalData = []
            return d
        }

        /// A request the app did not take: the one sentence, once. True when the rows changed.
        mutating func noteApprovalNotTaken() -> Bool {
            if turn.segments.contains(where: { $0.kind == .note(HermesChat.approvalNote) }) { return false }
            turn.apply(.note(HermesChat.approvalNote))
            return true
        }

        mutating func ingest(_ line: String, maxChars: Int) -> Change {
            var change = Change()
            if let frame = frames.feed(line), let name = frame.event {
                switch name {
                case "hermes.tool.progress":
                    if let p = HermesChat.parseToolProgress(frame.data) {
                        turn.apply(p.running ? .toolStarted(id: p.id, tool: p.tool, label: p.label)
                                             : .toolFinished(id: p.id, detail: nil))
                        change.steps = true
                    }
                case "approval.request":
                    // The loop reads it (`HermesApproval.parseAPIEvent`) and offers it to the app; nothing else here does.
                    if approvalData.count < 16 { approvalData.append(frame.data) }
                default: break   // hermes.status and any other name
                }
            }
            if let f = HermesChat.parseStreamFailure(line) { failure = f }
            if HermesChat.isStreamComplete(line) { complete = true }
            guard let delta = LocalChat.parseSSEDelta(line) else { return change }
            let room = maxChars - chars
            text += delta
            chars += delta.count
            if chars > maxChars {
                text = String(text.prefix(maxChars))
                chars = maxChars
                overLimit = true
            }
            turn.apply(.text(delta.count > room ? String(delta.prefix(max(room, 0))) : delta))
            change.text = true
            return change
        }
    }

    /// The sentences the chat keeps after an answer, handed from the answer (any task) to the loop that owns the rows.
    final class ApprovalNotes: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [String] = []
        func add(_ s: String) { lock.withLock { pending.append(s) } }
        func drain() -> [String] { lock.withLock { let p = pending; pending = []; return p } }
    }

    /// One answer: `POST <root>/v1/runs/<run id>/approval` with the key of the turn. 10 s, no redirect, and NEVER repeated:
    /// a second send after the body left could answer twice. Called only after a click, through the closure of the request.
    static func postApproval(root: String, key: String, request: HermesApprovalRequest,
                             choice: HermesApproval.Choice) async -> HermesApproval.AnswerOutcome {
        guard let req = HermesApproval.answerRequest(apiRoot: root, key: key, request: request, choice: choice) else { return .failed }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (bytes, response) = try await session.bytes(for: req, delegate: RequestGate())
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if body.count >= 4096 { break }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return HermesApproval.interpretHTTP(status: status, resolved: HermesApproval.parseHTTPResolved(body))
        } catch {
            // The connection never opened: nothing left the machine. Anything later: nobody knows.
            switch (error as? URLError)?.code {
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .notConnectedToInternet:
                return .failed
            default:
                return .unknown
            }
        }
    }

    static func streamChat(
        agent: HermesAgent,
        key: String,
        encodedBody: Data,
        limits: Limits = .standard,
        onToken: @MainActor @escaping (String) -> Void,
        onSegments: @MainActor @escaping ([ChatSegment]) -> Void = { _ in },
        onTurn: (@MainActor (String?, [ChatSegment]?) -> Void)? = nil,
        approvals: HermesApprovalHooks = .none
    ) async throws -> String {
        guard let url = chatURL(for: agent) else { throw HermesChatError.invalidURL }
        var req = URLRequest(url: url, timeoutInterval: 300)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = encodedBody

        let host = hostLabel(agent.baseURL)
        let opened: Opened
        do {
            // The POST has side effects (it starts an agent turn): repeated ONLY when no body byte left the machine.
            // Only the opening is retried (never after the body went out); the stream keeps its long idle allowance.
            opened = try await open(req, step: "chat", host: host, policy: limits.connectRetry,
                                    rule: .sideEffects, makeSession: { session() })
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HermesChatError.unreachable(host)
        }
        defer { opened.session.finishTasksAndInvalidate() }
        let bytes = opened.bytes
        let response = opened.response

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var raw = Data()
            do { for try await b in bytes { raw.append(b); if raw.count >= 4096 { break } } } catch {}
            throw error(status: status, body: raw)
        }

        var state = StreamState()
        // Approvals of this stream: what the app took, the notes of the answers (written by the answer, read by the loop).
        let approvalToken = HermesApproval.nextTurnToken()
        let notes = ApprovalNotes()
        var known = Set<String>()
        let root = apiRoot(baseURL: agent.baseURL, profile: agent.profile)
        defer {
            // Whatever the way out (even a throw): the requests of this stream are not answerable any more.
            let h = approvals
            Task { @MainActor in h.turnEnded(approvalToken, .turnEnded) }
        }
        func makeAnswer(for request: HermesApprovalRequest) -> HermesApprovalAnswer {
            return { choice in
                let outcome = await HermesChat.postApproval(root: root, key: key, request: request, choice: choice)
                notes.add(HermesApproval.chatNote(choice: choice, outcome: outcome))
                return outcome
            }
        }
        /// An `approval.request` frame: taken by the app, or left to Hermes with the one sentence. True when rows changed.
        func handleApproval(_ data: String) async -> Bool {
            guard let request = HermesApproval.parseAPIEvent(data, agent: agent.name) else { return state.noteApprovalNotTaken() }
            if known.contains(request.requestID) { return false }
            if known.count < 16 {
                let answer = makeAnswer(for: request)
                if await MainActor.run(body: { approvals.offer(request, approvalToken, answer) }) {
                    known.insert(request.requestID)
                    return false
                }
            }
            return state.noteApprovalNotTaken()
        }
        var line: [UInt8] = []
        var lineTooLong = false
        var tooSlow = false
        var broken = false
        var lastTextUpdate = Date.distantPast
        let minInterval: TimeInterval = 1.0 / 15.0
        var stepBudget = StepPublishBudget()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(limits.duration))

        /// One main actor hop and one write per tick: the text and the rows go out together (`onTurn`), or through the
        /// two callbacks when the caller only has those.
        func publish(content: String?, rows: [ChatSegment]?) async {
            await MainActor.run {
                if let onTurn { onTurn(content, rows) }
                else {
                    if let content { onToken(content) }
                    if let rows { onSegments(rows) }
                }
            }
        }

        /// The turn is over, whatever the way out: no step stays running, and the notes the text gets are rows too.
        /// The last text (when the way out sends one) goes out in the same write as the last rows.
        func settle(ok: Bool, notes: [String], content: String? = nil) async {
            state.turn.apply(.ended(ok: ok, notes: notes))
            await publish(content: content, rows: finalDisplaySegments(state.turn.segments))
        }
        var rowsPending = false

        do {
            // Lines are split here, not by `bytes.lines`, so a line can be capped.
            for try await byte in bytes {
                if clock.now >= deadline { tooSlow = true; break }
                if byte != 0x0A {
                    line.append(byte)
                    if line.count > limits.lineBytes { lineTooLong = true; break }
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                var change = state.ingest(text, maxChars: limits.textChars)
                for data in state.takeApprovalData() where await handleApproval(data) { change.steps = true }
                for n in notes.drain() { state.turn.apply(.note(n)); change.steps = true }
                // The text keeps its gate (15 a second). A step or a note change is published at once while the budget
                // lasts (15 in any second, no timer: a round of a few tools always fits); when the budget is spent it
                // waits, and goes out with the next line of any kind (a keepalive too) or with the end of the turn.
                if change.steps { rowsPending = true }
                if change.text || rowsPending {
                    let now = Date()
                    if change.text, now.timeIntervalSince(lastTextUpdate) >= minInterval {
                        lastTextUpdate = now
                        rowsPending = false
                        await publish(content: LocalChat.progressiveFilter(state.text), rows: displaySegments(state.turn.segments))
                    } else if rowsPending, stepBudget.take(at: now) {
                        rowsPending = false
                        await publish(content: nil, rows: displaySegments(state.turn.segments))
                    }
                }
                if state.overLimit { break }
            }
            if !lineTooLong, !tooSlow, !state.overLimit, !line.isEmpty {
                _ = state.ingest(String(decoding: line, as: UTF8.self), maxChars: limits.textChars)
                for data in state.takeApprovalData() { _ = await handleApproval(data) }
            }
        } catch {
            if Task.isCancelled { await settle(ok: false, notes: []); throw CancellationError() }
            broken = true
        }
        // The stream is over: nothing it asked can be answered any more (a late answer would be refused by the server).
        let endReason: HermesApproval.WithdrawReason = broken ? .socketLost : .turnEnded
        await MainActor.run { approvals.turnEnded(approvalToken, endReason) }
        for n in notes.drain() { state.turn.apply(.note(n)) }
        if Task.isCancelled { await settle(ok: false, notes: []); throw CancellationError() }
        if broken && state.text.isEmpty { await settle(ok: false, notes: []); throw HermesChatError.unreachable(host) }
        let lastVisible = LocalChat.progressiveFilter(state.text)

        let text = LocalChat.filterThinkingBlocks(state.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let capNote: String? = tooSlow ? tooSlowNote : (lineTooLong || state.overLimit) ? tooLongNote : nil
        if text.isEmpty {
            await settle(ok: false, notes: [], content: lastVisible)
            throw HermesChatError.agentFailed(state.failure ?? capNote ?? String(localized: "The agent returned no text."))
        }
        // Some text arrived: keep it, and say so when the stream did not end normally.
        if let capNote { await settle(ok: false, notes: [capNote], content: lastVisible); return text + "\n\n" + capNote }
        if broken || state.failure != nil || !state.complete {
            await settle(ok: false, notes: [interruptedNote], content: lastVisible)
            return text + "\n\n" + interruptedNote
        }
        await settle(ok: true, notes: [], content: lastVisible)
        return text
    }
}
