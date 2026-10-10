import Foundation

/// What the user typed for a remote host, as one destination `ssh` takes after `--`.
/// A port ("host -p 2222" or "host:2222") becomes ssh's own `ssh://host:2222` form;
/// any other option is refused, so nothing typed here reaches ssh as an option.
enum SSHDestination {
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-:[]/")

    /// A destination `ssh` takes as a host and nothing else: never an option.
    static func valid(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 255 && !host.hasPrefix("-") && host.allSatisfy { allowed.contains($0) }
    }

    /// The destination for `typed`, or nil when it is not a host (with an optional port).
    static func parse(_ typed: String) -> String? {
        var words = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        var port: String?
        if let i = words.firstIndex(where: { $0.hasPrefix("-p") }) {
            if words[i] == "-p", i + 1 < words.count {
                port = words[i + 1]
                words.removeSubrange(i...(i + 1))
            } else {
                port = String(words[i].dropFirst(2))
                words.remove(at: i)
            }
        }
        guard words.count == 1 else { return nil }
        var host = words[0]

        // host:port, only where the colon cannot be part of an IPv6 address
        if port == nil, !host.hasPrefix("ssh://"), let colon = host.lastIndex(of: ":") {
            let before = host[..<colon]
            if !before.contains(":") || (before.hasPrefix("[") && before.hasSuffix("]")) {
                port = String(host[host.index(after: colon)...])
                host = String(before)
            }
        }
        guard valid(host) else { return nil }
        guard let port else { return host }
        guard let n = Int(port), (1...65535).contains(n), port.allSatisfy(\.isNumber), !host.hasPrefix("ssh://") else { return nil }
        return "ssh://\(host):\(n)"
    }

    /// The destination as people read it: no `ssh://`, no port.
    static func label(_ destination: String) -> String {
        guard destination.hasPrefix("ssh://") else { return destination }
        let rest = destination.dropFirst("ssh://".count)
        guard let colon = rest.lastIndex(of: ":"), !rest[colon...].contains("]") else { return String(rest) }
        return String(rest[..<colon])
    }
}
