import Foundation

/// A session's own pill ID, never shared with another session: a UUID as it is,
/// anything else its first characters and a hash of the whole ID. Same rule as
/// sessionPillId in windows/src/island/hooks.ts.
enum SessionPillId {
    private static let plainLength = 19

    static func make(_ sessionId: String, prefix: String, taken: Set<String>) -> String {
        if UUID(uuidString: sessionId) != nil, !taken.contains(prefix + sessionId) {
            return prefix + sessionId
        }
        let safe = sessionId.filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        let plain = String(safe.prefix(plainLength))
        var salt = 0
        while true {
            let id = "\(prefix)\(plain)-\(fnv1a64(salt == 0 ? sessionId : "\(salt):\(sessionId)"))"
            if !taken.contains(id) { return id }
            salt += 1
        }
    }

    /// FNV-1a, 64 bits, as 16 hex digits.
    private static func fnv1a64(_ text: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
