import Foundation

// MARK: - Loopback listener for the "connection that never completes" failure mode (127.0.0.1 only).
//
// `init(fillBacklog: true)` binds a port, listens with a tiny backlog and fills it with idle clients, so a further
// SYN is dropped by the kernel: the client's connection hangs without any answer, which is what a lossy network does.
// No byte of a request can leave the machine while it hangs, and the server never sees a request.
// `serve(_:)` starts accepting: the idle clients are closed and every real request gets the canned answer.
// `init(port:)` (fillBacklog false) is a plain server on a given port, used to start one after a "connection refused".

final class StallingListener: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var idle: [Int32] = []
    private var answered = 0
    private var stopped = false
    private var response = Data()
    let port: UInt16

    /// Requests that reached the accept loop and were answered.
    var requests: Int { lock.withLock { answered } }

    /// A free port that nothing listens on (connecting to it is refused).
    static func closedPort() -> UInt16? {
        guard let l = StallingListener(port: 0, fillBacklog: false) else { return nil }
        let p = l.port
        l.stop()
        return p
    }

    init?(port wanted: UInt16 = 0, fillBacklog: Bool = false) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(wanted).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, fillBacklog ? 1 : 16) == 0 else { close(fd); return nil }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: got.sin_port)
        listenFD = fd
        if fillBacklog {
            // Connect until one connection does not complete: the accept queue is then full.
            for _ in 0..<32 {
                let c = socket(AF_INET, SOCK_STREAM, 0)
                guard c >= 0 else { break }
                _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = in_port_t(port).bigEndian
                target.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
                _ = withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                idle.append(c)
                var p = pollfd(fd: c, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, 150) == 0 { break }
            }
        }
    }

    /// Starts accepting. `body` is the answer to every request, as a complete HTTP response.
    func serve(_ http: String) {
        let fd: Int32 = lock.withLock {
            response = Data(http.utf8)
            let c = idle
            idle = []
            for f in c { close(f) }
            return listenFD
        }
        let t = Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                handle(c)
            }
        }
        t.start()
    }

    private func handle(_ c: Int32) {
        var buf = [UInt8](repeating: 0, count: 8192)
        var got = Data()
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        while true {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
            guard let r = got.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let head = String(decoding: got[0..<r.lowerBound], as: UTF8.self).lowercased()
            var want = 0
            if let l = head.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("content-length:") }) {
                want = Int(l.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            if got.count - r.upperBound >= want { break }
        }
        if got.isEmpty { close(c); return }   // an idle client, not a request
        let out = lock.withLock { () -> Data in answered += 1; return response }
        out.withUnsafeBytes { p in _ = send(c, p.baseAddress, p.count, 0) }
        close(c)
    }

    func stop() {
        let (fd, c) = lock.withLock { () -> (Int32, [Int32]) in
            let r = (listenFD, idle)
            listenFD = -1
            idle = []
            stopped = true
            return r
        }
        for f in c { close(f) }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
    }
}
