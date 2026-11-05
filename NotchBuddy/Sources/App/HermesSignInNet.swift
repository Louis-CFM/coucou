import Foundation
import Network

// MARK: - Hermes sign in: session store, loopback listener, REST calls, one chat turn over the dashboard WebSocket.
// The only logging is `HermesChat.Diagnostics` (step names and attempt counts, never a URL, token or text). Tokens go only to HermesSignIn.endpoint(agent.baseURL, …) and into the Keychain through `HermesSessionStorage`.

struct HermesSessionStorage: Sendable {
    var load: @Sendable () -> String
    /// An empty string means "remove the item".
    var save: @Sendable (String) -> Void
}

/// The sign in sessions of all agents (one record per agent name, each bound to its base URL).
/// The only writer of the Keychain item: sign in, sign out, disconnect and refresh all go through here, so
/// their read-modify-write steps never interleave. Reads the storage on every call.
actor HermesSessions {
    enum RefreshOutcome: Sendable {
        case refreshed(HermesSignIn.SessionRecord)
        /// The server said the session is over (401).
        case expired
        /// Server busy, provider unreachable, network error: the tokens are kept.
        case unavailable
        /// The record was removed or replaced (sign out, disconnect, sign in again) while the request was in
        /// flight: the answer no longer applies and is neither stored nor used to remove anything.
        case superseded
    }

    private let storage: HermesSessionStorage
    private let now: @Sendable () -> Double
    private let connectRetry: HermesChat.ConnectRetry
    private var inflight: [String: Task<RefreshOutcome, Never>] = [:]

    init(storage: HermesSessionStorage, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
         connectRetry: HermesChat.ConnectRetry = .standard) {
        self.storage = storage
        self.now = now
        self.connectRetry = connectRetry
    }

    private func all() -> [String: HermesSignIn.SessionRecord] { HermesSignIn.decodeSessions(storage.load()) }

    func record(for agent: HermesAgent) -> Result<HermesSignIn.SessionRecord, HermesChatError> {
        HermesSignIn.boundSession(for: agent, in: all())
    }

    func store(_ r: HermesSignIn.SessionRecord, name: String) {
        var a = all()
        a[name] = r
        storage.save(HermesSignIn.encodeSessions(a))
    }

    /// Removes the record only while it still holds `accessToken` (the one that was refused): a newer sign in stays.
    func remove(name: String, ifAccessToken accessToken: String) {
        guard all()[name]?.accessToken == accessToken else { return }
        remove(name: name)
    }

    func remove(name: String) {
        var a = all()
        guard a[name] != nil else { return }
        a[name] = nil
        storage.save(a.isEmpty ? "" : HermesSignIn.encodeSessions(a))
    }

    /// One refresh per agent at a time. The rotated record is saved before any caller gets the new token.
    /// `deadline` is the turn's connect deadline: the refresh counts against the same budget as the tickets and
    /// handshakes (when a refresh is already in flight, the deadline of its first caller applies).
    private func refreshOutcome(name: String, record: HermesSignIn.SessionRecord,
                                deadline: ContinuousClock.Instant?) async -> RefreshOutcome {
        if let t = inflight[name] { return await t.value }
        let t = Task { () -> RefreshOutcome in
            var out = await HermesSignInNet.refresh(record: record, retry: connectRetry, deadline: deadline)
            // Only a record that still exists and still holds the refresh token this request was made with may
            // be rotated or removed by its answer.
            if self.all()[name]?.refreshToken != record.refreshToken { out = .superseded }
            switch out {
            case .refreshed(let r): self.store(r, name: name)
            case .expired: self.remove(name: name)
            case .unavailable, .superseded: break
            }
            self.inflight[name] = nil
            return out
        }
        inflight[name] = t
        return await t.value
    }

    /// An access token that is fresh enough to use, refreshing first when needed.
    /// `forceRefresh` is for a token the server just refused.
    func validToken(for agent: HermesAgent, forceRefresh: Bool = false,
                    deadline: ContinuousClock.Instant? = nil) async throws -> String {
        let rec: HermesSignIn.SessionRecord
        switch record(for: agent) {
        case .success(let r): rec = r
        case .failure(let e): throw e
        }
        let action: HermesSignIn.TokenAction
        if forceRefresh { action = rec.refreshToken.isEmpty ? .signInAgain : .refresh }
        else { action = HermesSignIn.tokenAction(rec, now: now()) }
        switch action {
        case .use:
            return rec.accessToken
        case .signInAgain:
            if forceRefresh { remove(name: agent.name) }
            throw HermesChatError.signInNeeded(agent.shownName)
        case .refresh:
            switch await refreshOutcome(name: agent.name, record: rec, deadline: deadline) {
            case .refreshed(let r): return r.accessToken
            case .expired: throw HermesChatError.signInNeeded(agent.shownName)
            case .superseded:
                // Whatever is stored now (a new sign in) wins; nothing stored means signed out.
                switch record(for: agent) {
                case .success(let r): return r.accessToken
                case .failure(let e): throw e
                }
            case .unavailable:
                if !forceRefresh, rec.expiresAt <= 0 || now() < rec.expiresAt { return rec.accessToken }
                throw HermesChatError.busy
            }
        }
    }
}

// MARK: - Loopback listener (sign in callback)

#if !APPSTORE
/// One shot HTTP listener on 127.0.0.1 for the browser redirect. Accepts a single callback, always answers a
/// static page, and is torn down on every outcome (callback, timeout, cancellation, `stop`).
final class HermesLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.hermes-loopback")
    private let listener: NWListener
    private let lock = NSLock()
    private var cont: CheckedContinuation<String?, Never>?
    private var started: CheckedContinuation<UInt16?, Never>?
    private var settled = false
    private var line: String?
    private let expectedState: String
    private var boundPort: UInt16 = 0

    private init(_ l: NWListener, expectedState: String) { listener = l; self.expectedState = expectedState }

    /// Binds 127.0.0.1 on an ephemeral port and waits until the listener is ready. Nil when it cannot bind.
    /// Only a request that carries `expectedState` (and `Host: 127.0.0.1:<port>`) ends the wait.
    static func start(expectedState: String) async -> (HermesLoopback, UInt16)? {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.acceptLocalOnly = true
        guard let l = try? NWListener(using: params) else { return nil }
        let lb = HermesLoopback(l, expectedState: expectedState)
        guard let port = await lb.begin() else { lb.stop(); return nil }
        lb.lock.withLock { lb.boundPort = port }
        return (lb, port)
    }

    private func begin() async -> UInt16? {
        await withCheckedContinuation { (c: CheckedContinuation<UInt16?, Never>) in
            lock.withLock { started = c }
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: finishStart(listener.port?.rawValue)
                case .failed, .cancelled: finishStart(nil)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] conn in accept(conn) }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [self] in finishStart(nil) }
        }
    }

    private func finishStart(_ port: UInt16?) {
        let c = lock.withLock { () -> CheckedContinuation<UInt16?, Never>? in
            let c = started
            started = nil
            return c
        }
        c?.resume(returning: port)
    }

    /// The `GET /callback?…` request line, or nil on timeout or cancellation.
    func waitForCallback(timeout: TimeInterval) async -> String? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                let ready = lock.withLock { () -> (Bool, String?) in
                    if settled { return (true, line) }
                    cont = c
                    return (false, nil)
                }
                if ready.0 { c.resume(returning: ready.1); return }
                queue.asyncAfter(deadline: .now() + timeout) { [self] in settle(nil) }
            }
        } onCancel: {
            settle(nil)
        }
    }

    /// Ends the wait once (first outcome wins) and stops accepting connections.
    private func settle(_ requestLine: String?) {
        let c = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            guard !settled else { return nil }
            settled = true
            line = requestLine
            let c = cont
            cont = nil
            return c
        }
        listener.cancel()
        c?.resume(returning: requestLine)
    }

    func stop() { settle(nil) }

    private var isSettled: Bool { lock.withLock { settled } }

    private func accept(_ conn: NWConnection) {
        if isSettled { conn.cancel(); return }
        let peer = Peer(conn: conn, owner: self)
        peer.start(queue: queue)
    }

    /// Settles only on a callback whose state matches, addressed to this listener (a web page cannot make the
    /// browser send another Host). Anything else is answered with the static page and ignored.
    fileprivate func requestSeen(_ requestLine: String, host: String?) {
        let port = lock.withLock { boundPort }
        guard port != 0, host == "127.0.0.1:\(port)",
              HermesSignIn.isCallback(requestLine: requestLine, expectedState: expectedState) else { return }
        settle(requestLine)
    }

    /// A static page, no script, nothing taken from the request.
    fileprivate static let response: Data = {
        let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Coucou</title></head>"
            + "<body style=\"font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh\">"
            + "<h2>" + String(localized: "Back to Coucou") + "</h2><p>"
            + String(localized: "You can close this window and return to the app.") + "</p></body></html>"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
            + "Connection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        return Data((head + body).utf8)
    }()

    /// One accepted connection. Everything runs on the listener queue.
    private final class Peer: @unchecked Sendable {
        let conn: NWConnection
        weak var owner: HermesLoopback?
        var buf = Data()
        var answered = false

        init(conn: NWConnection, owner: HermesLoopback) { self.conn = conn; self.owner = owner }

        func start(queue: DispatchQueue) {
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { [self] in conn.cancel() }
            pump()
        }

        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] data, _, isComplete, error in
                if let data { buf.append(data) }
                let end = buf.range(of: Data("\r\n\r\n".utf8)) != nil
                if end || buf.count >= 8192 || isComplete || error != nil {
                    finish()
                } else {
                    pump()
                }
            }
        }

        func finish() {
            guard !answered else { return }
            answered = true
            let head = buf.prefix(8192)
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            if let firstLine = lines.first, !firstLine.isEmpty {
                let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }
                    .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
                owner?.requestSeen(firstLine, host: host)
            }
            conn.send(content: HermesLoopback.response, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [self] _ in conn.cancel() })
        }
    }
}
#endif

// MARK: - Network

enum HermesSignInNet {

    // MARK: REST

    private static func config() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        return c
    }

    /// One request, no redirect followed (the Authorization header never leaves the stored origin), body capped.
    /// A connection that fails to open is retried (`step` names it in the diagnostics); an answer of any status never is.
    /// `rule` is stated at every call site: a POST with side effects is repeated only when no body byte left the machine.
    private static func call(_ method: String, _ url: URL, bearer: String?, json: [String: Any]?,
                             host: String, step: String, rule: HermesChat.ConnectRetry.Rule,
                             retry: HermesChat.ConnectRetry = .standard,
                             deadline: ContinuousClock.Instant? = nil,
                             timeout: TimeInterval = 15) async -> Result<(Int, Data), HermesChatError> {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        var data = Data()
        let response: URLResponse
        do {
            let opened = try await HermesChat.open(req, step: step, host: host, policy: retry, rule: rule, deadline: deadline,
                                                   makeSession: { URLSession(configuration: config()) })
            defer { opened.session.finishTasksAndInvalidate() }
            response = opened.response
            for try await b in opened.bytes {
                data.append(b)
                if data.count > HermesChat.Limits.standard.connectBodyBytes {
                    return .failure(.server(String(localized: "The server answer is too large for a Hermes server.")))
                }
            }
        } catch {
            return .failure(.unreachable(host))
        }
        return .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data))
    }

    /// `POST /auth/native/refresh`. Never throws; the caller decides what each outcome means.
    static func refresh(record: HermesSignIn.SessionRecord, retry: HermesChat.ConnectRetry = .standard,
                        deadline: ContinuousClock.Instant? = nil) async -> HermesSessions.RefreshOutcome {
        guard !record.refreshToken.isEmpty,
              let url = HermesSignIn.endpoint(record.baseURL, "/auth/native/refresh") else { return .unavailable }
        let r = await call("POST", url, bearer: nil,
                           json: ["refresh_token": record.refreshToken, "provider": record.provider],
                           host: HermesChat.hostLabel(record.baseURL), step: "refresh",
                           rule: .sideEffects, retry: retry, deadline: deadline)
        guard case .success(let (status, body)) = r else { return .unavailable }
        if status == 401 { return .expired }
        guard status == 200,
              case .success(let rotated) = HermesSignIn.parseTokenResponse(body, baseURL: record.baseURL, previous: record) else {
            return .unavailable
        }
        return .refreshed(rotated)
    }

    /// Label for Settings (`GET /api/auth/me`); nil on any failure.
    static func me(baseURL: String, token: String, retry: HermesChat.ConnectRetry = .standard) async -> String? {
        guard let url = HermesSignIn.endpoint(baseURL, "/api/auth/me"),
              case .success(let (status, body)) = await call("GET", url, bearer: token, json: nil,
                                                               host: HermesChat.hostLabel(baseURL), step: "me",
                                                               rule: .idempotent, retry: retry),
              status == 200 else { return nil }
        return HermesSignIn.parseMe(body)
    }

    static func profiles(baseURL: String, token: String,
                         retry: HermesChat.ConnectRetry = .standard) async -> Result<[HermesSignIn.Profile], HermesChatError> {
        guard let url = HermesSignIn.endpoint(baseURL, "/api/profiles") else { return .failure(.invalidURL) }
        switch await call("GET", url, bearer: token, json: nil, host: HermesChat.hostLabel(baseURL), step: "profiles",
                        rule: .idempotent, retry: retry) {
        case .failure(let e): return .failure(e)
        case .success(let (status, body)):
            if HermesSignIn.isSessionExpired(status: status, body: body) {
                return .failure(.signInFailed(String(localized: "Hermes refused the session. Sign in again.")))
            }
            guard status == 200 else { return .failure(.server("HTTP \(status)")) }
            return .success(HermesSignIn.parseProfiles(body))
        }
    }

    // MARK: Sign in

    #if !APPSTORE
    /// The whole browser flow. `open` is called once, after the listener is ready; it is the only place a browser opens.
    /// Nothing is stored here: the caller stores the record when the user confirms.
    static func signIn(baseURL: String, timeout: TimeInterval = 300,
                       open: @MainActor @escaping (URL) -> Void) async -> Result<HermesSignIn.SessionRecord, HermesChatError> {
        guard case .success(let normalised) = HermesChat.normaliseBaseURL(baseURL), normalised == baseURL else {
            return .failure(.invalidURL)
        }
        guard HermesSignIn.isAllowedSignInBase(baseURL) else {
            return .failure(.signInFailed(HermesSignIn.httpsOnlyMessage))
        }
        let host = HermesChat.hostLabel(baseURL)
        let pkce = HermesSignIn.makePKCE()
        guard let (listener, port) = await HermesLoopback.start(expectedState: pkce.state) else {
            return .failure(.signInFailed(String(localized: "Coucou could not open a local port for sign in.")))
        }
        defer { listener.stop() }
        guard let url = HermesSignIn.authorizeURL(baseURL: baseURL, pkce: pkce,
                                                  redirectURI: HermesSignIn.redirectURI(port: port), provider: nil) else {
            return .failure(.invalidURL)
        }
        await MainActor.run { open(url) }
        guard let line = await listener.waitForCallback(timeout: timeout) else {
            return .failure(.signInFailed(String(localized: "Sign in timed out. Try again.")))
        }
        listener.stop()
        let code: String
        switch HermesSignIn.parseCallback(requestLine: line, expectedState: pkce.state) {
        case .success(let c): code = c
        case .failure(let e): return .failure(e)
        }
        guard let tokenURL = HermesSignIn.endpoint(baseURL, "/auth/native/token") else { return .failure(.invalidURL) }
        switch await call("POST", tokenURL, bearer: nil, json: ["code": code, "code_verifier": pkce.verifier],
                        host: host, step: "token", rule: .sideEffects, retry: HermesChat.ConnectRetry(attempts: 1, attemptTimeout: 15)) {
        case .failure(let e): return .failure(e)
        case .success(let (status, body)):
            guard status == 200 else {
                return .failure(.signInFailed(String(localized: "Hermes refused the sign in code. Try again.")))
            }
            return HermesSignIn.parseTokenResponse(body, baseURL: baseURL, previous: nil)
        }
    }
    #endif

    // MARK: Ticket

    /// A fresh single use ticket. A refused token is refreshed once; a second refusal ends the session.
    /// `turnToken` holds the access token of the turn: the token check (and its refresh, when due) runs once per turn,
    /// not on every ticket, so a refresh that cannot connect is not repeated for each handshake attempt. A token the
    /// server refuses is still refreshed (`forceRefresh`). Refreshes count against the turn's connect `deadline`.
    private static func mintTicket(agent: HermesAgent, sessions: HermesSessions, host: String,
                                   retry: HermesChat.ConnectRetry, deadline: ContinuousClock.Instant,
                                   turnToken: inout String?) async throws -> String {
        guard let url = HermesSignIn.endpoint(agent.baseURL, "/api/auth/ws-ticket") else { throw HermesChatError.invalidURL }
        var token: String
        if let t = turnToken { token = t } else { token = try await sessions.validToken(for: agent, deadline: deadline) }
        turnToken = token
        for attempt in 0..<2 {
            switch await call("POST", url, bearer: token, json: [:], host: host, step: "ticket", rule: .idempotent, retry: retry, deadline: deadline) {
            case .failure(let e):
                if Task.isCancelled { throw CancellationError() }
                throw e
            case .success(let (status, body)):
                if HermesSignIn.isSessionExpired(status: status, body: body) {
                    if attempt == 0 { token = try await sessions.validToken(for: agent, forceRefresh: true, deadline: deadline); turnToken = token; continue }
                    await sessions.remove(name: agent.name, ifAccessToken: token)
                    throw HermesChatError.signInNeeded(agent.shownName)
                }
                guard status == 200 else {
                    throw (status == 429 || status == 503) ? HermesChatError.busy : HermesChatError.server("HTTP \(status)")
                }
                guard let t = HermesSignIn.parseTicket(body) else { throw HermesChatError.notHermes }
                return t
            }
        }
        throw HermesChatError.signInNeeded(agent.shownName)
    }

    // MARK: Chat turn

    /// One chat turn on its own socket: ticket, handshake, create or resume, submit, stream, close.
    /// Returns the final text. `onSession` gets the stored session id to resume on the next turn.
    static func streamTurn(
        agent: HermesAgent,
        sessions: HermesSessions,
        storedSession: String?,
        text: String,
        limits: HermesChat.Limits = .standard,
        onSession: @MainActor @escaping (String) -> Void,
        onToken: @MainActor @escaping (String) -> Void,
        onSegments: @MainActor @escaping ([ChatSegment]) -> Void = { _ in },
        onTurn: (@MainActor (String?, [ChatSegment]?) -> Void)? = nil,
        approvals: HermesApprovalHooks = .none
    ) async throws -> String {
        guard agent.connection == .signIn, HermesChat.isValidAgent(agent) else { throw HermesChatError.invalidURL }
        let host = HermesChat.hostLabel(agent.baseURL)

        // Handshake: ticket in the subprotocol; once, the query form when that form is refused (or never gets ready).
        // The socket is registered for closing the moment it exists, so a cancellation anywhere below cannot leak it.
        // Opening is separate from ready: a handshake that does not complete in `attemptTimeout` (or drops) is retried
        // with a fresh ticket; a handshake the server REFUSED is not. Once open, the `readyTimeout` wait applies.
        let policy = limits.connectRetry
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: .seconds(policy.budget))   // opening connections; ready waits are excluded
        var turnToken: String?
        var opened: HermesSocket?
        defer { opened?.close() }
        forms: for queryForm in [false, true] {
            if queryForm && !limits.allowQueryTicketFallback { break }
            // The fallback form gets only what is left of the budget.
            if queryForm, clock.now.advanced(by: .seconds(policy.attemptTimeout)) > deadline { break }
            var attempt = 0
            while true {
                try Task.checkCancellation()
                attempt += 1
                let ticket = try await mintTicket(agent: agent, sessions: sessions, host: host, retry: policy,
                                                  deadline: deadline, turnToken: &turnToken)
                guard let url = HermesSignIn.socketURL(baseURL: agent.baseURL, queryTicket: queryForm ? ticket : nil) else {
                    if queryForm { break forms }   // no query ticket for a target that is not wss (or loopback)
                    throw HermesChatError.invalidURL
                }
                let protocols = queryForm ? [] : (HermesSignIn.ticketProtocols(ticket) ?? [])
                // The request timeout is not an idle limit here: the ready, rpc and turn timers below are.
                let s = HermesSocket(url: url, protocols: protocols,
                                     requestTimeout: limits.duration + limits.readyTimeout + 60)
                opened = s
                s.start()
                switch await s.waitOpen(timeout: policy.attemptTimeout) {
                case .open:
                    if attempt > 1 { HermesChat.Diagnostics.recovered(step: "socket", attempts: attempt) }
                    let waitStart = clock.now
                    let ready = await s.waitReady(timeout: limits.readyTimeout)
                    deadline = deadline.advanced(by: waitStart.duration(to: clock.now))
                    if ready { break forms }
                    if !Task.isCancelled { HermesChat.Diagnostics.failed(step: "ready", attempts: 1) }
                    s.close()
                    opened = nil
                    continue forms
                case .refused:
                    s.close()
                    opened = nil
                    continue forms
                case .failed(let code):
                    s.close()
                    opened = nil
                    try Task.checkCancellation()
                    if policy.isRetryable(code, rule: .idempotent, bytesSent: 0),
                       let wait = policy.mayRetry(afterAttempt: attempt, now: clock.now, deadline: deadline) {
                        try await Task.sleep(for: .seconds(wait))
                        continue
                    }
                    HermesChat.Diagnostics.failed(step: "socket", attempts: attempt)
                    continue forms
                }
            }
        }
        try Task.checkCancellation()
        guard let socket = opened else { throw HermesChatError.unreachable(host) }
        let approvalTurn0 = HermesApproval.nextTurnToken()

        defer {
            // Whatever the way out (even a throw): no answer stays waiting, and the app drops what this turn asked.
            socket.stopAccepting()
            socket.failAllAnswers()
            let h = approvals
            let token = approvalTurn0
            Task { @MainActor in h.turnEnded(token, .turnEnded) }
        }
        var turn = HermesSignIn.Turn()
        var nextID = 1
        var resumedFresh = false
        var submitSent = false
        // Per turn budget: every text frame counts, ignored ones too.
        var frames = 0
        var bytes = 0
        func overBudget(bytes n: Int) -> Bool {
            frames += 1
            bytes += n
            return frames > limits.maxFrames || bytes > limits.maxBytes
        }

        func profileParams() -> [String: Any] {
            (agent.profile.isEmpty || agent.profile == "default") ? [:] : ["profile": agent.profile]
        }

        // MARK: Approvals. Nothing below ever answers a request by itself: an answer leaves only as the result of
        // `.answer`, which the app posts after a click on a button of the card of exactly that request.
        let approvalTurn = approvalTurn0
        var approvalsAdvertised = false
        var known: [String: HermesApprovalRequest] = [:]          // taken by the app, by request id
        var frameToRequest: [String: String] = [:]                // server request frame id -> request id
        var answers: [Int: HermesAnswerCommand] = [:]             // `approval.respond` in flight, by rpc id
        var answering = Set<String>()
        var failedRequests: [String: HermesApprovalRequest] = [:] // answers the server did not take
        var pendingQuery: (id: Int, known: Set<String>, at: Date)?
        var lastRaw = ""

        func makeAnswer(for request: HermesApprovalRequest) -> HermesApprovalAnswer {
            return { [socket] choice in
                let waiter = HermesAnswerWaiter()
                let command = HermesAnswerCommand(request: request, choice: choice, waiter: waiter)
                guard socket.post(.answer(command)) else { return .unknown }
                return await waiter.wait()
            }
        }

        func forget(_ requestID: String) {
            known[requestID] = nil
            for (frame, rid) in frameToRequest where rid == requestID { frameToRequest[frame] = nil }
        }

        func withdraw(_ requestID: String, _ reason: HermesApproval.WithdrawReason) async {
            guard known[requestID] != nil, !answering.contains(requestID) else { return }
            forget(requestID)
            await MainActor.run { approvals.withdrawn(requestID, reason) }
            turn.addNote(HermesApproval.chatNote(withdrawn: reason))
        }

        func finishAnswer(_ rpcID: Int, _ outcome: HermesApproval.AnswerOutcome) {
            guard let c = answers.removeValue(forKey: rpcID) else { return }
            let rid = c.request.requestID
            answering.remove(rid)
            forget(rid)
            if outcome == .failed { failedRequests[rid] = c.request }
            turn.addNote(HermesApproval.chatNote(choice: c.choice, outcome: outcome))
            c.waiter.settle(outcome)
        }

        func handleAnswer(_ c: HermesAnswerCommand) async {
            guard known[c.request.requestID] != nil, !answering.contains(c.request.requestID) else { c.waiter.settle(.tooLate); return }
            // A choice that was not offered is never built into a frame: nothing leaves, and the answer says it was not taken.
            guard let params = HermesApproval.respondParams(c.request, c.choice) else { c.waiter.settle(.failed); return }
            let id = nextID
            nextID += 1
            answers[id] = c
            answering.insert(c.request.requestID)
            do { try await socket.sendText(HermesSignIn.request(id: id, method: "approval.respond", params: params)) }
            catch { finishAnswer(id, .unknown); return }
            _ = socket.arm(limits.rpcTimeout, .answerTimeout(id))
        }

        /// Frames about approvals. True when the frame was dealt with here and must not reach the reducer or the refusal.
        func inbound(_ t: String, _ f: HermesSignIn.Frame) async -> Bool {
            switch f {
            case .serverRequest(let frameID, "approval"):
                if approvalsAdvertised, !turn.session.isEmpty,
                   let request = HermesApproval.parseSignIn(t, agent: agent.name),
                   case .signIn(_, let session) = request.origin, session == turn.session {
                    if known[request.requestID] != nil { return true }
                    let answer = makeAnswer(for: request)
                    let accepted = await MainActor.run { approvals.offer(request, approvalTurn, answer) }
                    if accepted {
                        known[request.requestID] = request
                        frameToRequest[frameID] = request.requestID
                        turn.approvalsHandled = true
                        if let p = HermesApproval.receivedParams(request) {
                            let id = nextID
                            nextID += 1
                            await socket.sendBestEffort(HermesSignIn.request(id: id, method: "approval.received", params: p), timeout: 2)
                        }
                        return true
                    }
                }
                // Not showable: this client declines it (4404: not shown here), so the agent does not wait for the whole
                // server timeout and the request stays alive for any other client. The old error answer (-32601) would
                // settle it for every client. 4404 only goes to a server that advertised `approval` in its answer to
                // `client.capabilities`: a frame that comes before that answer, a server that does not know the method and
                // one that answers without `approval` keep today's refusal (-32601). The sentence stays.
                let reply = approvalsAdvertised ? HermesSignIn.decline(id: frameID) : HermesSignIn.rejection(id: frameID)
                await socket.sendBestEffort(reply, timeout: 2)
                _ = turn.ingest(f, maxChars: limits.textChars)
                return true
            case .result(let rid, _):
                if answers[rid] != nil {
                    finishAnswer(rid, HermesApproval.interpretRespond(resolved: HermesApproval.parseResolved(t, id: rid)))
                    return true
                }
                if let q = pendingQuery, q.id == rid {
                    pendingQuery = nil
                    guard let ids = HermesApproval.parsePendingIDs(t, id: rid) else { return true }
                    let gone = q.known.filter { !ids.contains($0) && known[$0] != nil && !answering.contains($0) }
                    if !gone.isEmpty {
                        await MainActor.run { approvals.retain(ids, q.known, approvalTurn) }
                        for r in gone { forget(r); turn.addNote(HermesApproval.chatNote(withdrawn: .stale)) }
                    }
                    // An answer the server did not take comes back as a fresh card, once, while the server still lists it.
                    for (r, request) in failedRequests {
                        failedRequests[r] = nil
                        guard ids.contains(r), known[r] == nil else { continue }
                        let answer = makeAnswer(for: request)
                        if await MainActor.run(body: { approvals.offer(request, approvalTurn, answer) }) {
                            known[r] = request
                            // The frame id is registered again: a `request.cancel` for it withdraws the card at once.
                            if case .signIn(let frameID, _) = request.origin { frameToRequest[frameID] = r }
                        }
                    }
                    return true
                }
                return false
            case .failure(let rid, _, _):
                if answers[rid] != nil { finishAnswer(rid, .failed); return true }
                if let q = pendingQuery, q.id == rid { pendingQuery = nil; return true }
                return false
            default:
                break
            }
            if t.contains("request.cancel"), let c = HermesApproval.parseCancel(t), let rid = frameToRequest[c.frameID] {
                await withdraw(rid, c.reason)
                return true
            }
            if t.contains("approval.cancelled"), let c = HermesApproval.parseCancelled(t) {
                for rid in c.ids { await withdraw(rid, c.reason) }
                return true
            }
            return false
        }

        /// Sends a request and waits for its answer. Server requests are refused, never answered (an approval the app
        /// took is answered only after a click).
        func rpc(_ method: String, _ params: [String: Any]) async throws -> HermesSignIn.Frame {
            let id = nextID
            nextID += 1
            if method == "prompt.submit" { submitSent = true }   // from here on the server may run the turn
            do { try await socket.sendText(HermesSignIn.request(id: id, method: method, params: params)) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw HermesChatError.unreachable(host)
            }
            let timer = socket.arm(limits.rpcTimeout, .timeout)
            defer { timer.cancel() }
            while let ev = await socket.next() {
                switch ev {
                case .text(let t):
                    if overBudget(bytes: t.utf8.count) { throw HermesChatError.server(String(localized: "Hermes sent more data than Coucou accepts.")) }
                    let f = HermesSignIn.decode(t)
                    if await inbound(t, f) {
                    } else if case .serverRequest(let sid, _) = f {
                        await socket.sendBestEffort(HermesSignIn.rejection(id: sid), timeout: 2)
                        _ = turn.ingest(f, maxChars: limits.textChars)
                    } else if !turn.session.isEmpty {
                        _ = turn.ingest(f, maxChars: limits.textChars)
                    }
                    switch f {
                    case .result(let rid, _) where rid == id: lastRaw = t; return f
                    case .failure(let rid, _, _) where rid == id: return f
                    default: break
                    }
                case .answer(let c): await handleAnswer(c)
                case .answerTimeout(let rid): finishAnswer(rid, .unknown)
                case .binary(let n):
                    if overBudget(bytes: n) { throw HermesChatError.server(String(localized: "Hermes sent more data than Coucou accepts.")) }
                case .closed: throw HermesChatError.unreachable(host)
                case .timeout: throw HermesChatError.server(String(localized: "Hermes did not answer in time."))
                case .ping, .deadline: break
                }
            }
            if Task.isCancelled { throw CancellationError() }
            throw HermesChatError.unreachable(host)
        }

        // The app says once per connection that it answers server requests: without it Hermes withdraws an approval
        // at once. An older server that does not know the method keeps today's behaviour.
        let capabilitiesID = nextID
        do {
            switch try await rpc("client.capabilities", HermesApproval.capabilitiesParams()) {
            case .result:
                approvalsAdvertised = HermesApproval.parseCapabilities(lastRaw, id: capabilitiesID)?.contains("approval") == true
            default:
                break
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch HermesChatError.unreachable(let h) {
            throw HermesChatError.unreachable(h)
        } catch {
            // Not answered in time: the session calls below tell whether the socket is still usable.
        }

        // Session: resume the stored one, else create (also when the resume failed: the server may have lost it).
        var runtimeID = ""
        var storedID: String?
        if let stored = storedSession {
            var p = profileParams()
            p["session_id"] = stored
            p["omit_messages"] = true
            if case .result(_, let m) = try await rpc("session.resume", p), let sid = m["session_id"], !sid.isEmpty {
                runtimeID = sid
                storedID = m["resumed"] ?? stored
            } else {
                resumedFresh = true
            }
        }
        if runtimeID.isEmpty {
            var p = profileParams()
            p["idempotency_key"] = UUID().uuidString
            switch try await rpc("session.create", p) {
            case .result(_, let m):
                guard let sid = m["session_id"], !sid.isEmpty else { throw HermesChatError.server(String(localized: "Hermes did not open a session.")) }
                runtimeID = sid
                storedID = m["stored_session_id"]
            case .failure(_, _, let msg):
                throw HermesChatError.server(msg.isEmpty ? String(localized: "Hermes did not open a session.") : msg)
            default:
                throw HermesChatError.server(String(localized: "Hermes did not open a session."))
            }
        }
        turn.session = runtimeID
        if let storedID, !storedID.isEmpty { await MainActor.run { onSession(storedID) } }
        else if resumedFresh { await MainActor.run { onSession("") } }   // the old id is gone: forget it

        func interruptFrame() -> String {
            let id = nextID
            nextID += 1
            return HermesSignIn.request(id: id, method: "session.interrupt", params: ["session_id": runtimeID])
        }

        let submitAnswer: HermesSignIn.Frame
        do { submitAnswer = try await rpc("prompt.submit", ["session_id": runtimeID, "text": text]) }
        catch is CancellationError {
            // The server may already be running the turn nobody will read.
            if submitSent { await socket.sendBestEffort(interruptFrame(), timeout: 2) }
            throw CancellationError()
        }
        switch submitAnswer {
        case .result(_, let m):
            // `streaming`, `steered`, `redirected` and `queued` all mean the server accepted the message: it will
            // run, so never report busy and never drop it. A queued message runs after the live turn, on this socket.
            if m["status"] == "queued" { turn.queuedBehindRunningTurn() }
        case .failure(_, let code, let msg):
            throw code == 4009 ? HermesChatError.busy : HermesChatError.server(msg.isEmpty ? String(localized: "Hermes refused the message.") : msg)
        default:
            throw HermesChatError.server(String(localized: "Hermes refused the message."))
        }

        // Stream until the terminal event. The turn may already be over: the server starts it before it answers.
        var tooSlow = false
        var closed = false
        var lastTextUpdate = Date.distantPast
        let minInterval: TimeInterval = 1.0 / 15.0
        var stepBudget = StepPublishBudget()
        var pingTimer = socket.arm(limits.pingInterval, .ping)
        let deadlineTimer = socket.arm(limits.duration, .deadline)
        defer { pingTimer.cancel(); deadlineTimer.cancel() }

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

        // The text keeps its gate (15 a second). A step, an interim text or a note change is published at once while
        // the budget lasts (15 in any second, no timer: a round of a few tools always fits); when it is spent it waits,
        // and goes out with the next frame of any kind or with the end of the turn.
        var rowsPending = false
        func flush(textChanged: Bool) async {
            guard textChanged || rowsPending else { return }
            let now = Date()
            if textChanged, now.timeIntervalSince(lastTextUpdate) >= minInterval {
                lastTextUpdate = now
                rowsPending = false
                await publish(content: LocalChat.progressiveFilter(turn.visibleSource),
                              rows: HermesChat.displaySegments(turn.rows.segments))
            } else if rowsPending, stepBudget.take(at: now) {
                rowsPending = false
                await publish(content: nil, rows: HermesChat.displaySegments(turn.rows.segments))
            }
        }

        loop: while !(turn.done || turn.overLimit), let ev = await socket.next() {
            switch ev {
            case .text(let t):
                if overBudget(bytes: t.utf8.count) { turn.overLimit = true; break loop }   // ends the turn like the text cap
                let f = HermesSignIn.decode(t)
                var textChanged = false
                if await !inbound(t, f) {
                    if case .serverRequest(let sid, _) = f { await socket.sendBestEffort(HermesSignIn.rejection(id: sid), timeout: 2) }
                    textChanged = turn.ingest(f, maxChars: limits.textChars)
                }
                if turn.stepsTouched { turn.stepsTouched = false; rowsPending = true }
                await flush(textChanged: textChanged)
            case .binary(let n):
                if overBudget(bytes: n) { turn.overLimit = true; break loop }
            case .ping:
                let id = nextID
                nextID += 1
                await socket.sendBestEffort(HermesSignIn.request(id: id, method: "gateway.ping", params: [:]), timeout: 2)
                pingTimer = socket.arm(limits.pingInterval, .ping)
                // Another client may have answered without a withdrawal reaching us: ask what is still pending.
                if !known.isEmpty || !failedRequests.isEmpty, pendingQuery == nil || Date().timeIntervalSince(pendingQuery!.at) > 45 {
                    let qid = nextID
                    nextID += 1
                    pendingQuery = (qid, Set(known.keys), Date())
                    await socket.sendBestEffort(HermesSignIn.request(id: qid, method: "approval.pending",
                                                                     params: HermesApproval.pendingParams(session: runtimeID)), timeout: 2)
                }
                await flush(textChanged: false)
            case .deadline:
                tooSlow = true
                break loop
            case .closed:
                closed = true
                break loop
            case .timeout:
                await flush(textChanged: false)
            case .answer(let c):
                await handleAnswer(c)
                if turn.stepsTouched { turn.stepsTouched = false; rowsPending = true }
                await flush(textChanged: false)
            case .answerTimeout(let rid):
                finishAnswer(rid, .unknown)
                if turn.stepsTouched { turn.stepsTouched = false; rowsPending = true }
                await flush(textChanged: false)
            }
        }
        let cancelled = Task.isCancelled
        if !cancelled, !turn.done, !tooSlow, !turn.overLimit { closed = true }
        // The turn is over: nothing it asked is answerable any more, and no answer in flight stays waiting.
        socket.stopAccepting()
        socket.failAllAnswers()
        let endReason: HermesApproval.WithdrawReason = closed && !turn.done ? .socketLost : .turnEnded
        await MainActor.run { approvals.turnEnded(approvalTurn, endReason) }

        /// Whatever the way out from here on, no row stays running.
        /// The last text (when the way out sends one) goes out in the same write as the last rows.
        func settle(content: String? = nil) async {
            if cancelled {
                turn.settleRows(ok: false, notes: [])
            } else {
                let o = turn.outcome(tooSlow: tooSlow, closedEarly: closed, resumedFresh: resumedFresh)
                turn.settleRows(ok: o.ok, notes: o.notes)
            }
            await publish(content: content, rows: HermesChat.finalDisplaySegments(turn.rows.segments))
        }

        // A cap or a cancellation stops the agent too (best effort), unless the server already ended the turn.
        if !turn.done, !closed, cancelled || tooSlow || turn.overLimit {
            await socket.sendBestEffort(interruptFrame(), timeout: 2)
        }
        if cancelled { await settle(); throw CancellationError() }
        if closed, !turn.done, turn.visibleSource.isEmpty { await settle(); throw HermesChatError.unreachable(host) }

        let visible = LocalChat.progressiveFilter(turn.visibleSource)
        await settle(content: visible)
        return try turn.finalText(tooSlow: tooSlow, closedEarly: closed, resumedFresh: resumedFresh)
    }
}

// MARK: - WebSocket (one per turn)

/// A `URLSessionWebSocketTask` that turns frames and timers into one event stream with a single consumer.
/// No cookies, no Origin, no Authorization header, no redirects: the ticket is the only credential.
/// Frames are read one at a time: the next `receive()` starts only after the consumer handled the previous text
/// frame and asked for more, so a flood of frames waits in the network stack, not in memory.
final class HermesSocket: @unchecked Sendable {
    enum Event: Sendable {
        case text(String)
        /// A non text frame (its size): never decoded, but it counts against the turn budget.
        case binary(Int)
        case closed
        case ping
        case deadline
        case timeout
        /// An answer to an approval, posted by the app after a click. Handled by the loop that owns the socket.
        case answer(HermesAnswerCommand)
        /// The `approval.respond` with this rpc id got no answer in time.
        case answerTimeout(Int)
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let continuation: AsyncStream<Event>.Continuation
    private var iterator: AsyncStream<Event>.Iterator
    private let credit: AsyncStream<Void>.Continuation
    private let creditStream: AsyncStream<Void>
    private var owed = false
    private var reader: Task<Void, Never>?
    private let handshaker: Handshaker
    private let answerLock = NSLock()
    private var accepting = true
    private var posted: [HermesAnswerWaiter] = []

    /// How the WebSocket handshake ended.
    enum Handshake: Sendable, Equatable {
        /// HTTP 101: the socket is open (not yet ready).
        case open
        /// The server answered the handshake with an HTTP status other than 101: never retried in the same form.
        case refused
        /// No answer: the connection failed to open or dropped, or `waitOpen` timed out (`.timedOut`).
        case failed(URLError.Code)
    }

    /// Session delegate: refuses redirects and reports how the handshake ended. Frames and timers do not go through it.
    private final class Handshaker: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var result: Handshake?
        private var waiter: CheckedContinuation<Handshake, Never>?

        func settle(_ r: Handshake) {
            let w = lock.withLock { () -> CheckedContinuation<Handshake, Never>? in
                guard result == nil else { return nil }
                result = r
                let w = waiter
                waiter = nil
                return w
            }
            w?.resume(returning: r)
        }

        func wait() async -> Handshake {
            await withCheckedContinuation { (c: CheckedContinuation<Handshake, Never>) in
                let done = lock.withLock { () -> Handshake? in
                    if let result { return result }
                    waiter = c
                    return nil
                }
                if let done { c.resume(returning: done) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            settle(.open)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // Only reached before `didOpen` when the handshake failed.
            if let http = task.response as? HTTPURLResponse, http.statusCode != 101 { settle(.refused); return }
            settle(.failed((error as? URLError)?.code ?? .unknown))
        }
    }

    /// `requestTimeout` is URLSession's request timeout, which can behave as an idle limit on a WebSocket:
    /// callers pass a value that covers the whole turn. Ready, rpc and turn timers are explicit (`arm`).
    init(url: URL, protocols: [String], requestTimeout: TimeInterval) {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.timeoutIntervalForRequest = requestTimeout
        let hsDelegate = Handshaker()
        handshaker = hsDelegate
        session = URLSession(configuration: c, delegate: hsDelegate, delegateQueue: nil)
        task = protocols.isEmpty ? session.webSocketTask(with: url) : session.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = 4 * 1024 * 1024
        let (stream, cont) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        continuation = cont
        iterator = stream.makeAsyncIterator()
        let (cStream, cCont) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .unbounded)
        creditStream = cStream
        credit = cCont
        cCont.yield(())   // one frame may be read ahead
    }

    func start() {
        task.resume()
        reader = Task.detached { [task, continuation, creditStream] in
            for await _ in creditStream {
                // One credit pays for one text frame; non text frames are reported and the reader keeps going.
                receiving: while true {
                    do {
                        switch try await task.receive() {
                        case .string(let s):
                            continuation.yield(.text(s))
                            break receiving
                        case .data(let d):
                            continuation.yield(.binary(d.count))
                        @unknown default:
                            continuation.yield(.binary(0))
                        }
                    } catch {
                        continuation.yield(.closed)
                        continuation.finish()
                        return
                    }
                }
            }
        }
    }

    func next() async -> Event? {
        if owed { owed = false; credit.yield(()) }   // the previous text frame is handled: read the next one
        let ev = await iterator.next()
        if case .text? = ev { owed = true }
        return ev
    }

    /// Waits for the HTTP 101 of the handshake, at most `timeout`. Cancellation ends the wait as `.timedOut`.
    func waitOpen(timeout: TimeInterval) async -> Handshake {
        let h = handshaker
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { h.settle(.failed(.timedOut)) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler { await h.wait() } onCancel: { h.settle(.failed(.cancelled)) }
    }

    /// True when `gateway.ready` arrives in time; false on handshake failure, close or timeout.
    func waitReady(timeout: TimeInterval, maxBinaryFrames: Int = HermesChat.Limits.standard.maxFrames) async -> Bool {
        let timer = arm(timeout, .timeout)
        defer { timer.cancel() }
        var binary = 0
        while let ev = await next() {
            switch ev {
            case .text(let t): if HermesSignIn.decode(t) == .ready { return true }
            case .binary:
                binary += 1
                if binary > maxBinaryFrames { return false }
            case .closed, .timeout: return false
            case .ping, .deadline, .answerTimeout: break
            case .answer(let c): c.waiter.settle(.unknown)
            }
        }
        return false
    }

    /// Hands an event to the loop that owns the socket. False once the loop is gone: the caller must not wait.
    func post(_ event: Event) -> Bool {
        answerLock.withLock {
            guard accepting else { return false }
            if case .answer(let c) = event { posted.append(c.waiter) }
            if case .enqueued = continuation.yield(event) { return true }
            return false
        }
    }

    func stopAccepting() { answerLock.withLock { accepting = false } }

    /// Settles every answer that was posted and never reached the loop (or is still waiting for its result).
    func failAllAnswers() {
        let waiters = answerLock.withLock { () -> [HermesAnswerWaiter] in let w = posted; posted = []; return w }
        for w in waiters { w.settle(.unknown) }
    }

    func arm(_ seconds: TimeInterval, _ event: Event) -> Task<Void, Never> {
        Task { [continuation] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { continuation.yield(event) }
        }
    }

    func sendText(_ text: String) async throws { try await task.send(.string(text)) }

    /// Sends and returns when the frame was handed to the network or after `timeout`; never throws.
    /// Not tied to task cancellation, so a cancelled turn can still say goodbye.
    func sendBestEffort(_ text: String, timeout: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let once = Once(c)
            task.send(.string(text)) { _ in once.fire() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.fire() }
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        continuation.finish()
        credit.finish()
        reader?.cancel()
        session.invalidateAndCancel()
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var c: CheckedContinuation<Void, Never>?
        init(_ c: CheckedContinuation<Void, Never>) { self.c = c }
        func fire() {
            let taken = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                let t = c
                c = nil
                return t
            }
            taken?.resume()
        }
    }
}
