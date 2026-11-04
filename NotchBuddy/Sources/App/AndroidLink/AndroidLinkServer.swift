import Foundation
import Network
import Security

// MARK: - Android link: the TLS server (docs/ANDROID_LINK.md, protocol v1)
//
// Network.framework only: an `NWListener` with the Mac's self-signed certificate, TLS 1.2 or 1.3,
// IPv4. One accepted connection is an `AndroidLinkConnection`: it reads the phone's lines, checks
// them, and writes what the hub queues. Everything runs on one private serial queue and every
// timer is a one-shot work item of a connection, so nothing runs while no phone is connected and
// nothing at all runs while the link is off (the listener, and with it the Bonjour announcement,
// is cancelled).
//
// What it refuses, on purpose (the same as the Rust `server.rs`):
//   * anyone who is not on the local network (private, loopback, link-local);
//   * a first message that is not a valid `hello` within a few seconds;
//   * a wrong token or protocol version (after a short pause, so guessing is slow);
//   * a line over 64 KiB, or silence for 20 minutes;
//   * more than a handful of connections at once, and more than two silent ones from one address:
//     see AndroidLinkAdmission.
// It never touches the agent: a decision goes through `AndroidLinkHub.decide`, which only applies the
// request still pending.

/// Which optional features the user has switched on, read again for every connection.
protocol AndroidLinkFeatures: AnyObject, Sendable {
    func details() -> Bool
    func answers() -> Bool
    func usage() -> Bool
}

final class AndroidLinkServer: @unchecked Sendable {
    /// An authenticated phone may be silent this long. A sleeping phone cannot ping every 20 s (its
    /// timers stop with the CPU); its alarm checks in every few minutes.
    static let idleTimeout: TimeInterval = 20 * 60
    /// Pause before answering a wrong token.
    static let authPenalty: TimeInterval = 0.4

    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.androidlink", qos: .utility)
    private let hub: AndroidLinkHub
    private let features: AndroidLinkFeatures
    private let admission = AndroidLinkAdmission()
    private let name: String
    private var token: String
    private let tokenLock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: AndroidLinkConnection] = [:]

    /// Called on the server's queue when the listener is ready (with the port) or has failed.
    var onState: (@Sendable (State) -> Void)?

    enum State: Equatable, Sendable {
        case ready(port: UInt16)
        case failed(String)
    }

    init(hub: AndroidLinkHub, features: AndroidLinkFeatures, name: String, token: String) {
        self.hub = hub
        self.features = features
        self.name = name
        self.token = token
    }

    var currentToken: String {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return token
    }

    /// Pairing again: the old token stops working at once. The caller disconnects the phones.
    func replaceToken(_ new: String) {
        tokenLock.lock()
        token = new
        tokenLock.unlock()
    }

    // MARK: Start and stop

    /// Starts listening on the default port, else any free one. `txt` is the Bonjour TXT record.
    func start(identity: SecIdentity, txt: [String: String]) {
        queue.async { [self] in
            guard listener == nil else { return }
            listen(identity: identity, txt: txt, port: NWEndpoint.Port(rawValue: AndroidLinkProtocol.defaultPort))
        }
    }

    private func listen(identity: SecIdentity, txt: [String: String], port: NWEndpoint.Port?) {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            onState?(.failed("no identity"))
            return
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // The same as the Rust server: IPv4 only, so what is announced is what answers.
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        parameters.allowLocalEndpointReuse = true

        let made: NWListener
        do {
            made = try port.map { try NWListener(using: parameters, on: $0) } ?? NWListener(using: parameters)
        } catch {
            if port != nil {
                listen(identity: identity, txt: txt, port: nil)
            } else {
                onState?(.failed(error.localizedDescription))
            }
            return
        }
        // Announced on the local network with the listener, withdrawn with it: off means silent.
        var record = NWTXTRecord()
        for (k, v) in txt { record[k] = v }
        made.service = NWListener.Service(name: AndroidLinkProtocol.instanceName(name), type: AndroidLinkProtocol.serviceType,
                                          domain: nil, txtRecord: record)
        // SecIdentity is a CF type without Sendable; it is only read again to retry on another port.
        let retryIdentity = AndroidLinkUncheckedBox(identity)
        made.stateUpdateHandler = { [weak self, weak made] state in
            guard let self, let made, self.listener === made || self.listener == nil else { return }
            switch state {
            case .ready:
                self.onState?(.ready(port: made.port?.rawValue ?? 0))
            case .failed(let error):
                made.cancel()
                self.listener = nil
                // The default port is busy: take any other.
                if port != nil, case .posix(let code) = error, code == .EADDRINUSE {
                    self.listen(identity: retryIdentity.value, txt: txt, port: nil)
                } else {
                    self.onState?(.failed(error.localizedDescription))
                }
            default:
                break
            }
        }
        made.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = made
        made.start(queue: queue)
    }

    /// Stops listening (and so announcing) and closes every connection.
    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            hub.kickAll(code: "closed", message: "the phone link was turned off")
            for c in connections.values { c.cancel() }
            connections = [:]
        }
    }

    // MARK: Accepting

    private func accept(_ nw: NWConnection) {
        guard let address = Self.localAddress(of: nw.endpoint) else {
            nw.cancel()   // dropped before any byte is read
            return
        }
        // The slot is held until the connection ends (the ticket is released), whatever way it ends.
        guard let ticket = admission.admit(address) else {
            nw.cancel()
            return
        }
        let connection = AndroidLinkConnection(nw: nw, ticket: ticket, server: self, queue: queue)
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.onEnd = { [weak self] in
            self?.queue.async { self?.connections[id] = nil }
        }
        connection.start()
    }

    /// The textual IPv4 address of a peer that is on the local network, else nil.
    static func localAddress(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a):
            let bytes = Array(a.rawValue)
            return AndroidLinkProtocol.isLocal(ipv4: bytes) ? bytes.map(String.init).joined(separator: ".") : nil
        case .ipv6(let a):
            let bytes = Array(a.rawValue)
            guard AndroidLinkProtocol.isLocal(ipv6: bytes) else { return nil }
            // An IPv4-mapped address is the same caller as its IPv4 form.
            if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
                return bytes[12..<16].map(String.init).joined(separator: ".")
            }
            return AndroidLinkProtocol.hex(bytes)
        default:
            return nil
        }
    }

    // MARK: What a connection needs

    fileprivate var hubRef: AndroidLinkHub { hub }
    fileprivate var featuresRef: AndroidLinkFeatures { features }
    fileprivate var computerName: String { name }
}

// MARK: - One connection

final class AndroidLinkConnection: @unchecked Sendable {
    private let nw: NWConnection
    private let ticket: AndroidLinkAdmission.Ticket
    private unowned let server: AndroidLinkServer
    private let queue: DispatchQueue
    private var reader = AndroidLinkLineReader()
    private var authenticated = false
    private var subscription: UInt64?
    private var helloTimer: DispatchWorkItem?
    private var idleTimer: DispatchWorkItem?
    private var ended = false
    var onEnd: (@Sendable () -> Void)?

    /// Lines handed to the network and not yet sent. A phone that cannot keep up is dropped rather than waited for.
    private let pendingLock = NSLock()
    private var pending = 0
    private static let maxPending = 64

    init(nw: NWConnection, ticket: AndroidLinkAdmission.Ticket, server: AndroidLinkServer, queue: DispatchQueue) {
        self.nw = nw
        self.ticket = ticket
        self.server = server
        self.queue = queue
    }

    func start() {
        nw.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        // The TLS handshake and then the hello get a few seconds (less when the pool is filling up).
        schedule(&helloTimer, after: ticket.wait) { [weak self] in self?.cancel() }
        nw.start(queue: queue)
    }

    func cancel() {
        nw.cancel()
        finish()
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        helloTimer?.cancel(); helloTimer = nil
        idleTimer?.cancel(); idleTimer = nil
        if let id = subscription { server.hubRef.unsubscribe(id); subscription = nil }
        ticket.release()
        onEnd?()
    }

    private func schedule(_ slot: inout DispatchWorkItem?, after seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        slot?.cancel()
        let item = DispatchWorkItem(block: work)
        slot = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: Reading

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.ended else { return }
            if let data, !data.isEmpty {
                guard let lines = self.reader.feed(data) else {
                    self.closeWithError(code: "protocol", message: "line too long")
                    return
                }
                for line in lines {
                    if self.ended { return }
                    if !self.handle(line) { return }
                }
            }
            if isComplete || error != nil {
                self.cancel()
                return
            }
            self.receive()
        }
    }

    /// False when the connection is over.
    private func handle(_ line: Data) -> Bool {
        guard let message = AndroidLinkIncoming.parse(line) else {
            cancel()   // not JSON: a protocol error
            return false
        }
        if !authenticated {
            guard case .hello(let sentToken, let version, _, let asked) = message else {
                cancel()   // the first message must be a valid hello
                return false
            }
            return hello(token: sentToken, version: version, asked: asked)
        }
        // Any line from the phone is proof of life.
        schedule(&idleTimer, after: AndroidLinkServer.idleTimeout) { [weak self] in self?.cancel() }
        switch message {
        case .ping:
            sendLine(AndroidLinkProtocol.json(["type": "pong"]))
        case .decision(let fingerprint, let decision):
            // The hub tells every phone when it applies one; an ignored decision changes nothing at all.
            _ = server.hubRef.decide(fingerprint: fingerprint, decision: decision, now: AndroidLinkProtocol.nowMs())
        case .answer(let fingerprint, let picks):
            if askedAnswers {
                _ = server.hubRef.answer(fingerprint: fingerprint, picks: picks, now: AndroidLinkProtocol.nowMs())
            }
        case .bye:
            cancel()
            return false
        case .hello, .other:
            break   // unknown types are ignored
        }
        return true
    }

    private var askedAnswers = false

    private func hello(token sent: String, version: Int?, asked: Set<String>) -> Bool {
        let good = version == AndroidLinkProtocol.version && AndroidLinkProtocol.constantEq(sent, server.currentToken)
        guard good else {
            // A wrong token costs the caller a pause, and is never admitted.
            helloTimer?.cancel(); helloTimer = nil
            queue.asyncAfter(deadline: .now() + AndroidLinkServer.authPenalty) { [weak self] in
                self?.closeWithError(code: "auth", message: "bad token or version")
            }
            return false
        }
        authenticated = true
        helloTimer?.cancel(); helloTimer = nil
        ticket.authenticated()
        schedule(&idleTimer, after: AndroidLinkServer.idleTimeout) { [weak self] in self?.cancel() }

        // Capabilities: offered only if the phone asked and the user's switch is on right now.
        let features = server.featuresRef
        let caps = AndroidLinkCaps(details: asked.contains("details") && features.details(),
                                   answers: asked.contains("answers") && features.answers(),
                                   usage: asked.contains("usage") && features.usage())
        askedAnswers = caps.answers
        var welcome: [String: Any] = ["type": "welcome", "v": AndroidLinkProtocol.version, "desktop": server.computerName, "os": "macos"]
        if !caps.offered.isEmpty { welcome["caps"] = caps.offered }
        sendLine(AndroidLinkProtocol.json(welcome))
        subscription = server.hubRef.subscribe(caps: caps, now: AndroidLinkProtocol.nowMs()) { [weak self] out in
            self?.deliver(out) ?? false
        }
        return true
    }

    // MARK: Writing

    /// The hub's way to this phone. False: it cannot keep up (the hub drops it and the connection closes).
    private func deliver(_ out: AndroidLinkOut) -> Bool {
        switch out {
        case .line(let line):
            pendingLock.lock()
            let full = pending >= Self.maxPending
            if !full { pending += 1 }
            pendingLock.unlock()
            if full {
                queue.async { [weak self] in self?.cancel() }
                return false
            }
            write(line, close: false, counted: true)
        case .close(let code, let message):
            write(AndroidLinkProtocol.json(["type": "error", "code": code, "message": message]), close: true, counted: false)
        }
        return true
    }

    private func sendLine(_ line: String) {
        write(line, close: false, counted: false)
    }

    private func closeWithError(code: String, message: String) {
        write(AndroidLinkProtocol.json(["type": "error", "code": code, "message": message]), close: true, counted: false)
    }

    private func write(_ line: String, close: Bool, counted: Bool) {
        var data = Data(line.utf8)
        data.append(0x0A)
        nw.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if counted {
                self.pendingLock.lock(); self.pending -= 1; self.pendingLock.unlock()
            }
            if close { self.cancel() }
        })
    }
}

/// Carries a value the compiler cannot prove Sendable into a @Sendable closure.
private struct AndroidLinkUncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
