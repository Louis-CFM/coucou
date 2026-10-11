import Foundation

/// A host that is this Mac, parsed as an address rather than matched as text:
/// "127.attacker.example" is not. Same rule as is_loopback_host in net.rs.
enum LoopbackHost {
    static func matches(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") { return true }

        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr)
            return ip >> 24 == 127 || ip == 0
        }

        var v6 = in6_addr()
        guard inet_pton(AF_INET6, h, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        let lowZero = b[0..<15].allSatisfy { $0 == 0 }
        let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
        return (lowZero && b[15] <= 1) || (mapped && b[12] == 127)
    }
}
