import Foundation

// Same cases as the session pill tests in windows/tests/hooks.test.mjs.

@main
enum SessionPillIdTests {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
        }
        let uuid = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        check(SessionPillId.make(uuid, prefix: "session_", taken: []) == "session_" + uuid, "a UUID keeps its pill ID")

        let long = String(repeating: "x", count: 40)
        var taken: Set<String> = []
        for id in ["abc!", "abc?", long + "1", long + "2"] {
            let pill = SessionPillId.make(id, prefix: "session_", taken: taken)
            check(!taken.contains(pill), "\(id.prefix(12)) gets a pill of its own")
            check(pill.count <= 44 && pill.dropFirst(8).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") },
                  "\(id.prefix(12)) stays a plain ID")
            taken.insert(pill)
        }
        check(SessionPillId.make("abc!", prefix: "session_", taken: []) == SessionPillId.make("abc!", prefix: "session_", taken: []),
              "the same ID always gets the same pill")
        let first = SessionPillId.make("abc!", prefix: "session_", taken: [])
        check(SessionPillId.make("abc!", prefix: "session_", taken: [first]) != first, "a taken pill ID is never reused")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("SessionPillId: all passed")
    }
}
