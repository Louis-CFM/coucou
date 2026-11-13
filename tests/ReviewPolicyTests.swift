import Foundation

@main
enum ReviewPolicyTests {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

    static func fresh() -> UserDefaults {
        let name = "review-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static func main() {
        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // Not before enough good moments, not in the first days.
        do {
            let d = fresh()
            for i in 1..<8 { check(!ReviewPolicy.note(needed: 8, defaults: d, now: start + Double(i) * day, version: "0.6.0"), "moment \(i) asks too early") }
            check(ReviewPolicy.note(needed: 8, defaults: d, now: start + 8 * day, version: "0.6.0"), "the 8th moment after 3 days asks")
            // Once per version.
            for i in 1...20 { check(!ReviewPolicy.note(needed: 8, defaults: d, now: start + Double(10 + i) * day, version: "0.6.0"), "asked twice in 0.6.0") }
            // A new version may ask again, after 8 more moments.
            var asked = false
            for i in 1...8 { asked = ReviewPolicy.note(needed: 8, defaults: d, now: start + Double(40 + i) * day, version: "0.6.1") }
            check(asked, "0.6.1 asks again after 8 moments")
        }
        // Many moments on the first day: still waits for the third day.
        do {
            let d = fresh()
            for i in 0..<30 { check(!ReviewPolicy.note(needed: 8, defaults: d, now: start + Double(i) * 60, version: "0.6.0"), "asked on day one") }
            check(ReviewPolicy.note(needed: 8, defaults: d, now: start + 3 * day, version: "0.6.0"), "asks on day three")
        }
        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("ReviewPolicy: all tests passed")
    }
}
