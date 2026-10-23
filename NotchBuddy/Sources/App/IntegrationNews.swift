import Foundation

// MARK: - Integration news
// What a poller has to say when something happened since its last poll — the Swift
// side of IntegrationEvent in windows/src-tauri/src/integrations.rs. AppState turns
// it into the pill's state, badge and sound (AppState.announce).

struct IntegrationNews: Equatable, Sendable {
    var success: Bool
    var label: String
    var detail: String?
    /// Something is waiting on the user (a review request, a meeting about to
    /// start) rather than something that finished: amber badge, not green/red.
    var attention: Bool = false
}

// MARK: - Dates
// RFC 3339 both ways, in whole seconds since 1970, UTC — the same rules as
// windows/src-tauri/src/time.rs, so both apps read API timestamps alike.

enum RFC3339 {
    static func now() -> Int { Int(Date().timeIntervalSince1970) }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    private static func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y - 1 : y
        let era = floorDiv(y, 400)
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z: Int) -> (Int, Int, Int) {
        let z = z + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? yoe + era * 400 + 1 : yoe + era * 400, m, d)
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    static func utc(_ secs: Int) -> String {
        let (y, m, d) = civilFromDays(floorDiv(secs, 86_400))
        let t = secs - floorDiv(secs, 86_400) * 86_400
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d, t / 3600, t % 3600 / 60, t % 60)
    }

    /// `2026-10-01T14:30:00+02:00`, `…Z`, with or without fractional seconds.
    static func parse(_ s: String) -> Int? {
        let chars = Array(s.utf8)
        func num(_ r: Range<Int>) -> Int? {
            guard r.upperBound <= chars.count else { return nil }
            let slice = chars[r]
            guard slice.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int(String(decoding: slice, as: UTF8.self))
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10),
              let h = num(11..<13), let mi = num(14..<16), let se = num(17..<19) else { return nil }
        var i = 19
        if i < chars.count, chars[i] == UInt8(ascii: ".") {
            i += 1
            while i < chars.count, chars[i] >= 48, chars[i] <= 57 { i += 1 }
        }
        let rest = Array(chars[min(i, chars.count)...])
        let offset: Int
        if rest == [UInt8(ascii: "Z")] || rest == [UInt8(ascii: "z")] {
            offset = 0
        } else {
            guard let first = rest.first else { return nil }
            let sign: Int
            switch first {
            case UInt8(ascii: "+"): sign = 1
            case UInt8(ascii: "-"): sign = -1
            default: return nil
            }
            func part(_ r: Range<Int>) -> Int? {
                guard r.upperBound <= rest.count else { return nil }
                let slice = rest[r]
                guard slice.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
                return Int(String(decoding: slice, as: UTF8.self))
            }
            guard let oh = part(1..<3), let om = part(4..<6) else { return nil }
            offset = sign * (oh * 3600 + om * 60)
        }
        return daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se - offset
    }
}

// MARK: - Small JSON helpers (JSONSerialization trees)

/// The value at `path` in nested dictionaries, e.g. `json(x, "repository", "nameWithOwner")`.
func jsonValue(_ root: Any?, _ path: String...) -> Any? {
    var cur = root
    for key in path {
        guard let dict = cur as? [String: Any] else { return nil }
        cur = dict[key]
    }
    return cur is NSNull ? nil : cur
}

/// The string at `path`, or "" — like `s(v, "/a/b")` in the Rust pollers.
func jsonString(_ root: Any?, _ path: String...) -> String {
    var cur = root
    for key in path {
        guard let dict = cur as? [String: Any] else { return "" }
        cur = dict[key]
    }
    return cur as? String ?? ""
}

/// Integers come back from JSONSerialization as NSNumber; booleans too, so they are excluded.
func jsonInt(_ value: Any?) -> Int? {
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
    return n.intValue
}

func jsonBool(_ value: Any?) -> Bool? {
    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}
