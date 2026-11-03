import CryptoKit
import Foundation
import Security

// Checks the Mac side of the Android link against the vectors of the Windows/Linux server
// (windows/src-tauri/src/phone_link/: pairing.rs, discovery.rs, admission.rs, hub.rs, server.rs) and
// the Android client (ProtocolTest.kt): the bytes the Mac produces must be the bytes the phone expects.
// Compiled by scripts/test-android-link.sh with the pure files of NotchBuddy/Sources/App/AndroidLink/.

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { failures += 1; print("FAIL line \(line): \(what)") }
}

final class MemStore: AndroidLinkSecretStore, @unchecked Sendable {
    var values: [String: String] = [:]
    var refuse = false
    func get(_ key: String) -> String? { values[key] }
    func set(_ key: String, _ value: String) -> Bool {
        if refuse { return false }
        values[key] = value
        return true
    }
}

final class Recorder: AndroidLinkHost, @unchecked Sendable {
    var decisions: [(String, Bool)] = []
    var answers: [(String, [[String]])] = []
    func decide(requestId: String, allow: Bool) { decisions.append((requestId, allow)) }
    func answer(requestId: String, picks: [[String]]) { answers.append((requestId, picks)) }
}

/// A fake phone: collects the lines the hub sends it.
final class Phone: @unchecked Sendable {
    var lines: [String] = []
    var closed: (String, String)?
    var full = false
    func send(_ out: AndroidLinkOut) -> Bool {
        if full { return false }
        switch out {
        case .line(let l): lines.append(l)
        case .close(let c, let m): closed = (c, m)
        }
        return true
    }
    func types() -> [String] {
        lines.compactMap { l in
            ((try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any])?["type"] as? String
        }
    }
    func last(_ type: String) -> [String: Any]? {
        for l in lines.reversed() {
            if let o = (try? JSONSerialization.jsonObject(with: Data(l.utf8))) as? [String: Any], o["type"] as? String == type { return o }
        }
        return nil
    }
}

@main
enum AndroidLinkTests {
    static func main() {
        let P = AndroidLinkProtocol.self
        fingerprints(P); pairing(P); discovery(P); local(P); text(P)
        framing(); incoming(); admission(); identity(); hub(); questions(); caps(); usage()
        if failures > 0 { print("\(failures) FAILED"); exit(1) }
        print("AndroidLink tests: all passed")
    }

    // MARK: Vectors shared with Rust and Kotlin

    static func fingerprints(_ P: AndroidLinkProtocol.Type) {
        // Vector computed independently (Node, Python) and used by android ProtocolTest.kt.
        check(P.fingerprint(pillId: "agent_codex", sessionId: "sess-1", tool: "Bash", command: "rm -rf build", inputKey: "k1")
              == "0b2944f472c9dda6c1d369e7c161730641be8e67174c8eb67c887a2fe0ccd30d", "fingerprint vector")
        let base = P.fingerprint(pillId: "p", sessionId: "s", tool: "t", command: "c", inputKey: "i")
        check(base != P.fingerprint(pillId: "p", sessionId: "s", tool: "t", command: "c2", inputKey: "i"), "command matters")
        check(base != P.fingerprint(pillId: "p", sessionId: "s2", tool: "t", command: "c", inputKey: "i"), "session matters")
        check(P.fingerprint(pillId: "a", sessionId: "bc", tool: "t", command: "c", inputKey: "i")
              != P.fingerprint(pillId: "ab", sessionId: "c", tool: "t", command: "c", inputKey: "i"), "field boundaries matter")
        check(P.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 of nothing")
    }

    static func pairing(_ P: AndroidLinkProtocol.Type) {
        let link = P.pairingLink(host: "192.168.1.20", port: 47821, fingerprint: String(repeating: "ab", count: 32),
                                 token: "tok_en-1234567890abcd", name: "Léa's PC & co")
        check(link == "coucou://pair?v=1&host=192.168.1.20&port=47821&fp=\(String(repeating: "ab", count: 32))&token=tok_en-1234567890abcd&name=L%C3%A9a%27s%20PC%20%26%20co",
              "pairing link vector (pairing.rs)")
        check(P.isToken(String(repeating: "a", count: 16)), "16 chars")
        check(P.isToken(String(repeating: "A-_9", count: 32)), "128 chars of the alphabet")
        check(!P.isToken(String(repeating: "a", count: 15)), "15 chars")
        check(!P.isToken(String(repeating: "a", count: 129)), "129 chars")
        check(!P.isToken("aaaaaaaaaaaaaaa!"), "bad char")
        check(!P.isToken("aaaaaaaaaaaaaaa "), "space")
        check(!P.isToken(""), "empty")
        let a = P.randomToken(), b = P.randomToken()
        check(P.isToken(a) && P.isToken(b) && a != b && a.count == 32, "random tokens are valid and differ")
        // The longest realistic link stays under what the phone accepts (2 048 characters).
        let long = P.pairingLink(host: "2001:db8:aaaa:bbbb:cccc:dddd:eeee:ffff", port: 47821, fingerprint: String(repeating: "ab", count: 32),
                                 token: String(repeating: "t", count: 128), name: String(repeating: "é", count: 48))
        check(long.count < 2048, "long link \(long.count)")
    }

    static func discovery(_ P: AndroidLinkProtocol.Type) {
        let fp = "AB12CD34EF56AB78901234567890ABCDEF1234567890ABCDEF1234567890ABCD"
        check(P.fingerprintId(fp) == "ab12cd34ef56ab78", "id is 16 lowercase hex")
        check(P.fingerprintId(fp.lowercased()) == "ab12cd34ef56ab78", "lowercase input")
        check(P.fingerprintId("zz12cd34ef56ab78901234") == nil, "not hex")
        check(P.fingerprintId("abcd") == nil && P.fingerprintId("") == nil, "too short")
        check(P.txtRecord(fingerprint: fp) == ["v": "1", "fp": "ab12cd34ef56ab78"], "TXT: v and fp, nothing else")
        check(P.txtRecord(fingerprint: "not a fingerprint") == nil, "no TXT without a fingerprint")
        check(P.serviceType == "_coucou._tcp", "service type")
        check(P.instanceName("Rhytam's Mac") == "Rhytam's Mac", "instance is the name")
        check(P.instanceName("   ") == "Coucou", "empty name")
        check(P.instanceName(String(repeating: "x", count: 100)).count == 48, "name cut at 48")
    }

    static func local(_ P: AndroidLinkProtocol.Type) {
        for ok in ["192.168.1.20", "10.0.0.5", "172.16.3.4", "172.31.255.255", "127.0.0.1", "169.254.7.7", "::1", "fd12:3456::1", "fe80::1", "::ffff:192.168.0.9"] {
            check(P.isLocal(address: ok), "\(ok) is local")
        }
        for no in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "2001:db8::1", "::ffff:8.8.8.8", "0.0.0.0", "nonsense"] {
            check(!P.isLocal(address: no), "\(no) is not local")
        }
    }

    static func text(_ P: AndroidLinkProtocol.Type) {
        check(P.projectName("/Users/someone/private/proj") == "proj", "only the folder name")
        check(P.projectName("C:\\Users\\x\\proj\\") == "proj", "windows path")
        check(P.projectName("/") == nil && P.projectName("..") == nil && P.projectName("") == nil, "nothing usable")
        check(P.isColor("#2DD4BF") && P.isColor("#abcdef") && !P.isColor("2DD4BF") && !P.isColor("#2DD4B") && !P.isColor("#GGGGGG"), "colours")
        check(P.clip("héllo", 2) == "hé", "clip on a character")
        check(P.cleanSteps(["", " ", "a", String(repeating: "x", count: 300)]).map(\.count) == [1, 200], "steps")
        check(P.cleanSteps((0..<30).map { "s\($0)" }).count == 20, "at most 20 steps")
        check(P.constantEq("abc", "abc") && !P.constantEq("abc", "abd") && !P.constantEq("abc", "ab"), "constant-time equality")
    }

    // MARK: Framing

    static func framing() {
        var r = AndroidLinkLineReader()
        check(r.feed(Data("{\"a\":1}\n{\"b\"".utf8))?.count == 1, "one complete line")
        check(r.feed(Data(":2}\r\n\n".utf8))?.count == 1, "the rest, CRLF dropped, empty line skipped")
        // A line of exactly 64 KiB is accepted, one byte more is a protocol error.
        var exact = AndroidLinkLineReader()
        let ok = exact.feed(Data(String(repeating: "a", count: AndroidLinkProtocol.maxLine).utf8 + [0x0A]))
        check(ok?.count == 1, "64 KiB line accepted")
        var over = AndroidLinkLineReader()
        check(over.feed(Data(String(repeating: "a", count: AndroidLinkProtocol.maxLine + 1).utf8 + [0x0A])) == nil, "64 KiB + 1 refused")
        var endless = AndroidLinkLineReader()
        check(endless.feed(Data(String(repeating: "a", count: AndroidLinkProtocol.maxLine + 10).utf8)) == nil, "no newline within the limit")
        var split = AndroidLinkLineReader()
        check(split.feed(Data(String(repeating: "a", count: 40_000).utf8))?.isEmpty == true, "half a big line waits")
        check(split.feed(Data((String(repeating: "a", count: 20_000) + "\n").utf8))?.count == 1, "and completes")
    }

    static func incoming() {
        func parse(_ s: String) -> AndroidLinkIncoming? { AndroidLinkIncoming.parse(Data(s.utf8)) }
        check(parse("{\"type\":\"hello\",\"v\":1,\"token\":\"tok\",\"device\":\"Pixel\",\"caps\":[\"details\",\"chat\"]}")
              == .hello(token: "tok", version: 1, device: "Pixel", caps: ["details", "chat"]), "hello")
        check(parse("{\"type\":\"hello\"}") == .hello(token: "", version: nil, device: "", caps: []), "bare hello")
        check(parse("{\"type\":\"ping\"}") == .ping && parse("{\"type\":\"bye\"}") == .bye, "ping, bye")
        check(parse("{\"type\":\"decision\",\"fingerprint\":\"f\",\"decision\":\"allow\"}") == .decision(fingerprint: "f", decision: "allow"), "decision")
        check(parse("{\"type\":\"answer\",\"fingerprint\":\"f\",\"picks\":[[\"a\"],[\"b\",\"c\"]]}") == .answer(fingerprint: "f", picks: [["a"], ["b", "c"]]), "answer")
        check(parse("{\"type\":\"answer\",\"fingerprint\":\"f\",\"picks\":[]}") == .other(type: "answer"), "empty picks")
        check(parse("{\"type\":\"answer\",\"fingerprint\":\"f\",\"picks\":[[1]]}") == .other(type: "answer"), "picks must be strings")
        check(parse("{\"type\":\"answer\",\"fingerprint\":\"f\",\"picks\":[[\"a\"],[\"a\"],[\"a\"],[\"a\"],[\"a\"]]}") == .other(type: "answer"), "at most 4 questions")
        check(parse("{\"type\":\"chatSend\"}") == .other(type: "chatSend"), "unknown types are ignored, not errors")
        check(parse("not json") == nil && parse("[1]") == nil, "not an object")
    }

    // MARK: Admission (admission.rs)

    static func admission() {
        typealias A = AndroidLinkAdmission
        let a = A()
        let t1 = a.admit("192.168.1.50")
        let t2 = a.admit("192.168.1.50")
        check(t1 != nil && t2 != nil, "two silent connections from one address")
        check(a.admit("192.168.1.50") == nil, "the third from one address")
        check(a.admit("192.168.1.51") != nil, "another address is not affected")
        t1?.release()
        check(a.admit("192.168.1.50") != nil, "a closed connection frees its place")

        // Strangers share a pool smaller than the whole.
        let b = A()
        var held: [A.Ticket] = []
        for n in 0..<(A.maxUnauthStrangers / A.maxUnauthPerAddress) {
            for _ in 0..<A.maxUnauthPerAddress { if let t = b.admit("10.0.0.\(n + 1)") { held.append(t) } }
        }
        check(held.count == A.maxUnauthStrangers, "stranger pool is \(A.maxUnauthStrangers)")
        check(b.admit("10.0.0.99") == nil, "the stranger pool is full")
        check(held.count < A.maxConnections, "slots are left for known phones")

        // A flood from many addresses cannot lock out the paired phone.
        let c = A()
        c.admit("192.168.1.20")?.authenticated()
        check(c.knows("192.168.1.20"), "authenticated address remembered")
        var flood: [A.Ticket] = []
        for n in 0..<50 { if let t = c.admit("192.168.1.\(100 + n)") { flood.append(t) } }
        check(flood.count == A.maxUnauthStrangers, "the flood is capped")
        let phone = c.admit("192.168.1.20")
        check(phone != nil, "the paired phone still gets in")
        phone?.authenticated()
        let again = c.admit("192.168.1.20")
        check(again != nil, "and can reconnect during the flood")
        again?.authenticated()
        check(c.counts.1 == A.maxUnauthStrangers && c.counts.0 <= A.maxConnections, "counts")

        // A flood from one address leaves every other address alone.
        let d = A()
        var one: [A.Ticket] = []
        for _ in 0..<20 { if let t = d.admit("192.168.1.66") { one.append(t) } }
        check(d.admit("192.168.1.20") != nil, "a newcomer still connects")

        // Authenticating is counted once and frees the unauthenticated place.
        let e = A()
        let t = e.admit("192.168.1.20")!
        t.authenticated(); t.authenticated()
        check(e.counts.0 == 1 && e.counts.1 == 0, "authenticated once")
        let u1 = e.admit("192.168.1.20"), u2 = e.admit("192.168.1.20")
        check(u1 != nil && u2 != nil, "authenticated connection no longer counts against the per-address limit")

        // The total never goes over eight, even for known phones.
        let f = A()
        var all: [A.Ticket] = []
        for n in 0..<A.maxConnections { let x = f.admit("192.168.1.\(10 + n)")!; x.authenticated(); all.append(x) }
        check(f.admit("192.168.1.10") == nil, "no ninth connection")

        // Places come back when tickets are released or dropped, whatever their state.
        let g = A()
        do {
            let x = g.admit("192.168.1.20")!
            _ = g.admit("192.168.1.21")
            x.authenticated()
        }
        check(g.counts.0 == 0 && g.counts.1 == 0, "dropped tickets give their places back")

        // The wait is shorter when the pool is filling up.
        let h = A()
        check(h.admit("192.168.1.1")!.wait == A.patient, "an empty server is patient")
        var more: [A.Ticket] = []
        for n in 0..<2 { more.append(h.admit("192.168.2.\(n)")!) }
        check(h.admit("192.168.3.1")!.wait == A.hurried, "hurried when strangers fill up")

        // At most eight addresses are remembered.
        let i = A()
        for n in 0..<(A.knownAddresses + 3) { i.admit("192.168.5.\(n)")?.authenticated() }
        check(!i.knows("192.168.5.0") && i.knows("192.168.5.\(A.knownAddresses + 2)"), "the oldest is forgotten")
    }

    // MARK: Identity (pairing.rs)

    static func identity() {
        let store = MemStore()
        guard let first = AndroidLinkIdentity.loadOrCreate(store: store) else { check(false, "identity created"); return }
        let again = AndroidLinkIdentity.loadOrCreate(store: store)
        check(again?.certificateDER == first.certificateDER && again?.fingerprint == first.fingerprint, "the certificate is made once and kept")
        check(first.fingerprint.count == 64 && first.fingerprint == AndroidLinkProtocol.sha256Hex(first.certificateDER), "fingerprint is the SHA-256 of the DER")
        // The system's own parser accepts it, and it carries the key we signed with.
        if let cert = SecCertificateCreateWithData(nil, first.certificateDER as CFData) {
            check((SecCertificateCopySubjectSummary(cert) as String?) == "Coucou phone link", "subject")
            var trust: SecTrust?
            check(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess, "usable as a trust object")
        } else {
            check(false, "Security parses the certificate")
        }
        // The signature verifies with the certificate's own public key.
        let parsed = parseCertificate(Array(first.certificateDER))
        check(parsed != nil, "DER structure")
        if let (tbs, signature) = parsed,
           let sig = try? P256.Signing.ECDSASignature(derRepresentation: Data(signature)) {
            check(first.privateKey.publicKey.isValidSignature(sig, for: Data(tbs)), "self-signature verifies")
        } else {
            check(false, "signature parsed")
        }
        // A damaged key means a new identity, not a crash; the new one is what is kept.
        store.values[AndroidLinkIdentity.privateKeyKey] = "zz-not-hex"
        let next = AndroidLinkIdentity.loadOrCreate(store: store)
        check(next != nil && next?.fingerprint != first.fingerprint, "damaged key: new identity")
        check(AndroidLinkIdentity.loadOrCreate(store: store)?.fingerprint == next?.fingerprint, "and kept")
        // A store that refuses writes: no identity, nothing half-saved.
        let locked = MemStore(); locked.refuse = true
        check(AndroidLinkIdentity.loadOrCreate(store: locked) == nil, "no identity without secure storage")
        check(locked.values.isEmpty, "nothing kept")
        // Tokens.
        let t = AndroidLinkIdentity.token(store: store)!
        check(AndroidLinkProtocol.isToken(t) && AndroidLinkIdentity.token(store: store) == t, "token kept")
        let n = AndroidLinkIdentity.newToken(store: store)!
        check(n != t && AndroidLinkIdentity.token(store: store) == n, "new token replaces it")
        store.values[AndroidLinkIdentity.tokenKey] = "short"
        check(AndroidLinkProtocol.isToken(AndroidLinkIdentity.token(store: store)!), "a damaged token is replaced")
        // Nothing but the store is written: the secrets are exactly what the store holds.
        check(store.values[AndroidLinkIdentity.privateKeyKey]?.count == 64, "raw key kept in the store only")
    }

    /// (to-be-signed bytes, signature DER) of a certificate, or nil if it is not Certificate ::= SEQUENCE { tbs, alg, sig }.
    static func parseCertificate(_ der: [UInt8]) -> ([UInt8], [UInt8])? {
        func read(_ b: [UInt8], _ at: Int) -> (tag: UInt8, start: Int, end: Int)? {
            guard at + 2 <= b.count else { return nil }
            var len = Int(b[at + 1]); var start = at + 2
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard n > 0, n <= 4, at + 2 + n <= b.count else { return nil }
                len = 0
                for k in 0..<n { len = len << 8 | Int(b[at + 2 + k]) }
                start = at + 2 + n
            }
            guard start + len <= b.count else { return nil }
            return (b[at], start, start + len)
        }
        guard let outer = read(der, 0), outer.tag == 0x30, outer.end == der.count,
              let tbs = read(der, outer.start), tbs.tag == 0x30,
              let alg = read(der, tbs.end), alg.tag == 0x30,
              let sig = read(der, alg.end), sig.tag == 0x03, sig.end == outer.end else { return nil }
        return (Array(der[outer.start..<tbs.end]), Array(der[(sig.start + 1)..<sig.end]))
    }

    // MARK: Hub (hub.rs)

    static func approval(_ id: String, _ command: String = "npm run build") -> AndroidApprovalIn {
        AndroidApprovalIn(requestId: id, sessionId: "s1", pillId: "integration_claude", tool: "Bash", command: command)
    }

    static func fp(_ id: String, _ command: String = "npm run build") -> String {
        AndroidLinkProtocol.fingerprint(pillId: "integration_claude", sessionId: "s1", tool: "Bash", command: command, inputKey: id)
    }

    static func hub() {
        let host = Recorder()
        let hub = AndroidLinkHub(host: host)
        let phone = Phone()
        hub.subscribe(caps: AndroidLinkCaps(), now: 1000, send: phone.send)
        check(phone.types() == ["sessions"], "a new phone first gets the sessions")
        hub.publish(sessions: [], approval: approval("req-1"), now: 1000)
        let line = phone.last("approval")
        check(line?["fingerprint"] as? String == fp("req-1"), "approval fingerprint")
        check(line?["command"] as? String == "npm run build" && line?["tool"] as? String == "Bash" && line?["truncated"] as? Bool == false, "approval fields")

        // A decision for another request changes nothing.
        check(hub.decide(fingerprint: fp("req-1", "other"), decision: "allow", now: 2000) == .noMatch, "another command")
        check(host.decisions.isEmpty, "host untouched")
        check(hub.decide(fingerprint: fp("req-1"), decision: "maybe", now: 2000) == .invalid, "neither allow nor deny")
        check(hub.decide(fingerprint: fp("req-1"), decision: "allow", now: 2000) == .applied, "applied")
        check(host.decisions.count == 1 && host.decisions[0].0 == "req-1" && host.decisions[0].1, "host answered once")
        check(phone.last("approvalResolved")?["fingerprint"] as? String == fp("req-1"), "everyone is told")
        check(hub.decide(fingerprint: fp("req-1"), decision: "allow", now: 2100) == .noMatch, "decide once")
        check(host.decisions.count == 1, "still once")

        // Same command asked twice: different requests, a late decision for the first cannot answer the second.
        hub.publish(sessions: [], approval: approval("req-2"), now: 3000)
        check(hub.decide(fingerprint: fp("req-1"), decision: "allow", now: 3001) == .noMatch, "stale request id")
        check(fp("req-1") != fp("req-2"), "same command, different fingerprints")

        // 115 s.
        hub.publish(sessions: [], approval: approval("req-3"), now: 10_000)
        check(hub.decide(fingerprint: fp("req-3"), decision: "deny", now: 10_000 + 116_000) == .late, "too late")
        check(host.decisions.count == 1, "a late decision never reaches the agent")
        hub.publish(sessions: [], approval: approval("req-4"), now: 20_000)
        check(hub.decide(fingerprint: fp("req-4"), decision: "deny", now: 20_000 + 115_000) == .applied, "exactly 115 s is still fine")
        check(host.decisions.last?.1 == false, "denied")

        // A request that waited past the TTL is dismissed when a phone connects.
        hub.publish(sessions: [], approval: approval("req-5"), now: 30_000)
        let late = Phone()
        hub.subscribe(caps: AndroidLinkCaps(), now: 30_000 + 200_000, send: late.send)
        check(!late.types().contains("approval"), "an expired request is not offered")
        check(hub.decide(fingerprint: fp("req-5"), decision: "allow", now: 30_000 + 200_001) == .noMatch, "and is gone")

        // A command over 500 characters: cut, flagged, deny only.
        let big = String(repeating: "é", count: 600)
        hub.publish(sessions: [], approval: approval("req-6", big), now: 40_000)
        let cut = phone.last("approval")
        check((cut?["command"] as? String)?.count == 500 && cut?["truncated"] as? Bool == true, "cut and flagged")
        let cutPrint = AndroidLinkProtocol.fingerprint(pillId: "integration_claude", sessionId: "s1", tool: "Bash", command: String(big.prefix(500)), inputKey: "req-6")
        check(cut?["fingerprint"] as? String == cutPrint, "fingerprint over the text as sent")
        let before = host.decisions.count
        check(hub.decide(fingerprint: cutPrint, decision: "allow", now: 40_100) == .tooLong, "allow refused")
        check(host.decisions.count == before, "agent untouched")
        check(hub.decide(fingerprint: cutPrint, decision: "deny", now: 40_200) == .applied, "deny works")

        // The island moves on: the old request is retracted.
        hub.publish(sessions: [], approval: approval("req-7"), now: 50_000)
        hub.publish(sessions: [], approval: nil, now: 50_100)
        check(phone.last("approvalResolved")?["fingerprint"] as? String == fp("req-7"), "answered at the desk: retracted")
        check(hub.decide(fingerprint: fp("req-7"), decision: "allow", now: 50_200) == .noMatch, "nothing to decide")

        // Sessions: v1 fields only, unchanged pictures are not resent, unknown states are idle.
        let h2 = AndroidLinkHub(host: Recorder())
        let p2 = Phone()
        h2.subscribe(caps: AndroidLinkCaps(), now: 0, send: p2.send)
        let s = AndroidSessionIn(pillId: "integration_claude", agent: "Claude Code", state: "working", statusText: "Editing", stepIndex: 2, stepCount: 6,
                                 steps: ["Read · README.md"], finalLine: "Done", project: "/Users/x/private/proj", color: "#2DD4BF")
        h2.publish(sessions: [s, AndroidSessionIn(pillId: "agent_gemini", agent: "Gemini CLI", state: "banana")], approval: nil, now: 5)
        let sessions = (p2.last("sessions")?["sessions"] as? [[String: Any]]) ?? []
        check(sessions.count == 2, "two sessions")
        check(Set(sessions[0].keys) == ["pillId", "agent", "state", "statusText", "stepIndex", "stepCount", "updatedAt"], "exactly the v1 fields")
        check(sessions[1]["state"] as? String == "idle", "unknown state is idle")
        let count = p2.lines.count
        h2.publish(sessions: [s, AndroidSessionIn(pillId: "agent_gemini", agent: "Gemini CLI", state: "banana")], approval: nil, now: 9)
        check(p2.lines.count == count, "an unchanged picture sends nothing")
        var s2 = s; s2.statusText = "Testing"
        h2.publish(sessions: [s2], approval: nil, now: 12)
        let changed = ((p2.last("sessions")?["sessions"] as? [[String: Any]]) ?? [])
        check(changed.count == 1 && changed[0]["updatedAt"] as? Int == 12, "a change is stamped")
        h2.publish(sessions: (0..<30).map { AndroidSessionIn(pillId: "p\($0)", agent: "a") }, approval: nil, now: 13)
        check(((p2.last("sessions")?["sessions"] as? [[String: Any]]) ?? []).count == 16, "at most 16 sessions")

        // A phone that cannot keep up is dropped, and the others are not affected.
        let slow = Phone(), fast = Phone()
        let h3 = AndroidLinkHub(host: Recorder())
        h3.subscribe(caps: AndroidLinkCaps(), now: 0, send: slow.send)
        h3.subscribe(caps: AndroidLinkCaps(), now: 0, send: fast.send)
        slow.full = true
        h3.publish(sessions: [s], approval: nil, now: 1)
        check(h3.clients == 1 && fast.types().last == "sessions", "slow phone dropped")

        // Turning off: every phone is told and closed.
        h3.kickAll(code: "closed", message: "the phone link was turned off")
        check(fast.closed?.0 == "closed" && h3.clients == 0, "kicked")
    }

    // MARK: Questions

    static func question(_ id: String) -> AndroidQuestionIn {
        AndroidQuestionIn(requestId: id, sessionId: "s1", pillId: "integration_claude", questions: [
            AndroidQuestionItemIn(question: "Which?", options: [AndroidOptionIn(label: "A", description: "first"), AndroidOptionIn(label: "B")]),
            AndroidQuestionItemIn(question: "Which ones?", options: [AndroidOptionIn(label: "X"), AndroidOptionIn(label: "Y"), AndroidOptionIn(label: "Z")], multiSelect: true),
        ])
    }

    static func qfp(_ id: String) -> String {
        AndroidLinkProtocol.fingerprint(pillId: "integration_claude", sessionId: "s1", tool: "AskUserQuestion", command: "Which?\nWhich ones?", inputKey: id)
    }

    static func questions() {
        let host = Recorder()
        let hub = AndroidLinkHub(host: host)
        let with = Phone(), without = Phone()
        hub.subscribe(caps: AndroidLinkCaps(answers: true), now: 0, send: with.send)
        hub.subscribe(caps: AndroidLinkCaps(), now: 0, send: without.send)
        hub.publishQuestion(question("q1"), now: 1000)
        let line = with.last("question")
        check(line?["fingerprint"] as? String == qfp("q1"), "question fingerprint")
        check(!without.types().contains("question"), "a phone without the capability never hears of a question")
        // A phone that connects late still gets it.
        let late = Phone()
        hub.subscribe(caps: AndroidLinkCaps(answers: true), now: 2000, send: late.send)
        check(late.types().contains("question"), "late phone gets the question")

        // Wrong answers change nothing and the question stays open.
        check(hub.answer(fingerprint: qfp("q1"), picks: [["A"]], now: 3000) == .invalid, "one list per question")
        check(hub.answer(fingerprint: qfp("q1"), picks: [["a"], ["X"]], now: 3000) == .invalid, "labels are case-sensitive")
        check(hub.answer(fingerprint: qfp("q1"), picks: [["A", "B"], ["X"]], now: 3000) == .invalid, "one label for a single choice")
        check(hub.answer(fingerprint: qfp("q1"), picks: [["A"], []], now: 3000) == .invalid, "at least one for multiple")
        check(hub.answer(fingerprint: qfp("q1"), picks: [["A"], ["X", "X"]], now: 3000) == .invalid, "distinct labels")
        check(hub.answer(fingerprint: qfp("q1"), picks: [["A"], ["Q"]], now: 3000) == .invalid, "unknown label")
        check(host.answers.isEmpty, "the agent heard nothing")
        check(hub.answer(fingerprint: "nope", picks: [["A"], ["X"]], now: 3000) == .noMatch, "another question")
        check(hub.answer(fingerprint: qfp("q1"), picks: [["B"], ["X", "Z"]], now: 3000) == .applied, "valid answer")
        check(host.answers.count == 1 && host.answers[0].0 == "q1" && host.answers[0].1 == [["B"], ["X", "Z"]], "host got the picks")
        check(with.last("approvalResolved")?["fingerprint"] as? String == qfp("q1"), "the question is closed")
        check(hub.answer(fingerprint: qfp("q1"), picks: [["B"], ["X"]], now: 3100) == .noMatch, "answered once")

        // Too late.
        hub.publishQuestion(question("q2"), now: 10_000)
        check(hub.answer(fingerprint: qfp("q2"), picks: [["A"], ["X"]], now: 10_000 + 116_000) == .late, "late answer")
        check(host.answers.count == 1, "never applied")

        // Questions that do not fit are not offered (they stay on the Mac).
        func offered(_ items: [AndroidQuestionItemIn]) -> Bool { AndroidLinkHub.fitsTheLimits(items) }
        let one = AndroidOptionIn(label: "A")
        check(!offered([]), "no question")
        check(!offered([AndroidQuestionItemIn(question: "q", options: [])]), "no option")
        check(!offered([AndroidQuestionItemIn(question: "q", options: [one, one])]), "two options with the same label")
        check(!offered([AndroidQuestionItemIn(question: String(repeating: "x", count: 501), options: [one])]), "question over 500")
        check(offered([AndroidQuestionItemIn(question: String(repeating: "x", count: 500), options: [one])]), "question of 500")
        check(!offered([AndroidQuestionItemIn(question: "q", options: [AndroidOptionIn(label: String(repeating: "x", count: 121))])]), "label over 120")
        check(!offered([AndroidQuestionItemIn(question: "q", options: [AndroidOptionIn(label: "a", description: String(repeating: "x", count: 301))])]), "description over 300")
        check(!offered((0..<5).map { _ in AndroidQuestionItemIn(question: "q", options: [one]) }), "more than 4 questions")
        check(!offered([AndroidQuestionItemIn(question: "q", options: (0..<9).map { AndroidOptionIn(label: "o\($0)") })]), "more than 8 options")
        let h2 = AndroidLinkHub(host: Recorder())
        let p = Phone()
        h2.subscribe(caps: AndroidLinkCaps(answers: true), now: 0, send: p.send)
        h2.publishQuestion(AndroidQuestionIn(requestId: "q", sessionId: "s", pillId: "p", questions: []), now: 0)
        check(!p.types().contains("question"), "an unfit question is never sent")
    }

    // MARK: Capabilities, details, usage

    static func caps() {
        check(AndroidLinkCaps(details: true, answers: true, usage: true).offered == ["details", "answers", "usage"], "caps order as the Rust server")
        check(AndroidLinkCaps().offered.isEmpty, "no caps, no field")

        let hub = AndroidLinkHub(host: Recorder())
        let v1 = Phone(), rich = Phone()
        hub.subscribe(caps: AndroidLinkCaps(), now: 0, send: v1.send)
        hub.subscribe(caps: AndroidLinkCaps(details: true), now: 0, send: rich.send)
        let s = AndroidSessionIn(pillId: "integration_claude", agent: "Claude Code", state: "working",
                                 steps: ["Read", "Edit"], finalLine: "Fixed", project: "/home/someone/private/proj", color: "#2DD4BF")
        hub.publish(sessions: [s], approval: nil, now: 1)
        let plain = ((v1.last("sessions")?["sessions"] as? [[String: Any]]) ?? [[:]])[0]
        let detailed = ((rich.last("sessions")?["sessions"] as? [[String: Any]]) ?? [[:]])[0]
        check(plain["steps"] == nil && plain["project"] == nil && plain["finalLine"] == nil && plain["color"] == nil, "v1 phone gets no details")
        check(detailed["steps"] as? [String] == ["Read", "Edit"] && detailed["finalLine"] as? String == "Fixed"
              && detailed["project"] as? String == "proj" && detailed["color"] as? String == "#2DD4BF", "details: folder name only")
        check(!rich.lines.joined().contains("someone"), "no path leaves")

        // A full load of details still fits one line.
        let many = (0..<16).map { n in
            AndroidSessionIn(pillId: "agent_\(n)", agent: "Agent", state: "working",
                             steps: (0..<20).map { _ in String(repeating: "x", count: 200) }, finalLine: String(repeating: "y", count: 200))
        }
        let big = AndroidLinkHub(host: Recorder())
        let bp = Phone()
        big.subscribe(caps: AndroidLinkCaps(details: true), now: 0, send: bp.send)
        big.publish(sessions: many, approval: nil, now: 1)
        check((bp.lines.last?.utf8.count ?? Int.max) <= AndroidLinkProtocol.detailsLineBudget, "under the 56 KiB budget")
        check(bp.lines.last?.utf8.count ?? Int.max < AndroidLinkProtocol.maxLine, "and under the 64 KiB limit")
    }

    static func usage() {
        let hub = AndroidLinkHub(host: Recorder())
        let with = Phone(), without = Phone()
        hub.subscribe(caps: AndroidLinkCaps(usage: true), now: 0, send: with.send)
        hub.subscribe(caps: AndroidLinkCaps(), now: 0, send: without.send)
        let u = AndroidUsageIn(claude: AndroidUsagePlanIn(fiveHour: AndroidUsageWindowIn(usedPct: 41.6, resetsAt: 1_900_000_000_000),
                                                         sevenDay: AndroidUsageWindowIn(usedPct: 130, resetsAt: 1_900_500_000_000),
                                                         plan: "max 5x!", updatedAt: 1_899_999_990_000),
                               codex: AndroidUsagePlanIn(sevenDay: AndroidUsageWindowIn(usedPct: 100, resetsAt: 1_900_500_000_000), plan: "plus", resetCredits: 250))
        hub.publishUsage(u)
        let line = with.last("usage")
        let claude = line?["claude"] as? [String: Any]
        check((claude?["fiveHour"] as? [String: Any])?["pct"] as? Int == 42, "rounded percent")
        check((claude?["sevenDay"] as? [String: Any])?["pct"] as? Int == 100, "clamped to 100")
        check(claude?["plan"] as? String == "max 5x", "plan name sanitised")
        check((line?["codex"] as? [String: Any])?["resetCredits"] as? Int == 99, "reset credits clamped")
        check(!without.types().contains("usage"), "a phone without the capability hears nothing")
        let count = with.lines.count
        hub.publishUsage(u)
        check(with.lines.count == count, "an identical usage is sent once")
        // Nothing usable left: a bare usage tells the phone to remove its panel.
        hub.publishUsage(AndroidUsageIn(claude: AndroidUsagePlanIn(), codex: nil))
        check(with.lines.last == "{\"type\":\"usage\"}", "bare usage")
        // A late phone gets the last usage.
        hub.publishUsage(u)
        let late = Phone()
        hub.subscribe(caps: AndroidLinkCaps(usage: true), now: 0, send: late.send)
        check(late.types().contains("usage"), "late phone gets usage")
    }
}
