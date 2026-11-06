import Foundation

// MARK: - Android link: who may open a connection (docs/ANDROID_LINK.md, "Admission")
//
// The server accepts connections from the local network before it knows who is
// calling. Left alone, one noisy or hostile device could fill every slot with
// silent connections and keep the paired phone out. So, as in the Rust
// `admission.rs` (same numbers, same rules):
//   * one source address may hold at most 2 connections that have not yet said a valid hello;
//   * strangers (addresses that never authenticated) share a pool of 4 such connections, so at
//     least half of the 8 slots are always left for a phone the Mac already knows;
//   * an address that authenticated before is remembered (in memory only, 8 addresses) and is
//     not held to the stranger pool;
//   * when the pool is getting full the TLS handshake and the hello get 3 s instead of 10 s.
// Pure bookkeeping: no sockets, no clock, so every rule is a unit test.

final class AndroidLinkAdmission: @unchecked Sendable {
    static let maxConnections = 8
    /// Connections from one address that have not yet sent a valid hello.
    static let maxUnauthPerAddress = 2
    /// Unauthenticated connections from addresses that never authenticated, all together.
    static let maxUnauthStrangers = 4
    /// Addresses remembered as "authenticated before".
    static let knownAddresses = 8
    static let patient: TimeInterval = 10
    static let hurried: TimeInterval = 3

    private let lock = NSLock()
    private var total = 0
    private var strangersUnauth = 0
    private var unauth: [String: Int] = [:]
    /// Most recent first.
    private var known: [String] = []

    /// A slot for this caller (its canonical textual address), or nil: the connection is closed unserved.
    /// The slot is given back when the ticket is released, however the connection ends.
    func admit(_ address: String) -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        if total >= Self.maxConnections { return nil }
        if (unauth[address] ?? 0) >= Self.maxUnauthPerAddress { return nil }
        let stranger = !known.contains(address)
        if stranger && strangersUnauth >= Self.maxUnauthStrangers { return nil }
        // Looked at before this caller is counted: "is the pool getting full already?"
        let hurried = total + 2 >= Self.maxConnections || strangersUnauth * 2 >= Self.maxUnauthStrangers
        total += 1
        unauth[address, default: 0] += 1
        if stranger { strangersUnauth += 1 }
        return Ticket(admission: self, address: address, stranger: stranger, wait: hurried ? Self.hurried : Self.patient)
    }

    /// (total connections, unauthenticated strangers), for the tests.
    var counts: (Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (total, strangersUnauth)
    }

    func knows(_ address: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return known.contains(address)
    }

    fileprivate func authenticated(_ address: String, stranger: Bool) {
        lock.lock(); defer { lock.unlock() }
        releaseUnauth(address, stranger: stranger)
        known.removeAll { $0 == address }
        known.insert(address, at: 0)
        if known.count > Self.knownAddresses { known.removeLast(known.count - Self.knownAddresses) }
    }

    fileprivate func release(_ address: String, stranger: Bool, unauthenticated: Bool) {
        lock.lock(); defer { lock.unlock() }
        total -= 1
        if unauthenticated { releaseUnauth(address, stranger: stranger) }
    }

    private func releaseUnauth(_ address: String, stranger: Bool) {
        if let n = unauth[address] {
            if n <= 1 { unauth[address] = nil } else { unauth[address] = n - 1 }
        }
        if stranger { strangersUnauth -= 1 }
    }

    /// One accepted connection's slot. Released once, explicitly or when it goes away.
    final class Ticket: @unchecked Sendable {
        private let admission: AndroidLinkAdmission
        let address: String
        private let stranger: Bool
        /// How long the TLS handshake and then the hello may take (shorter when the pool is nearly full).
        let wait: TimeInterval
        private let lock = NSLock()
        private var unauthenticated = true
        private var released = false

        fileprivate init(admission: AndroidLinkAdmission, address: String, stranger: Bool, wait: TimeInterval) {
            self.admission = admission
            self.address = address
            self.stranger = stranger
            self.wait = wait
        }

        /// The caller said a valid hello: it no longer counts against the unauthenticated limits and its
        /// address is remembered, so a flood from elsewhere cannot keep it out. Counted once.
        func authenticated() {
            lock.lock()
            guard unauthenticated, !released else { lock.unlock(); return }
            unauthenticated = false
            lock.unlock()
            admission.authenticated(address, stranger: stranger)
        }

        /// The connection ended, whatever way: the slot is given back.
        func release() {
            lock.lock()
            guard !released else { lock.unlock(); return }
            released = true
            let wasUnauth = unauthenticated
            lock.unlock()
            admission.release(address, stranger: stranger, unauthenticated: wasUnauth)
        }

        deinit { release() }
    }
}
