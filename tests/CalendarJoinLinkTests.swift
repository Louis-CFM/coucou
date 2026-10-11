import Foundation

@main
struct CalendarJoinLinkTests {
    static func main() {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
        }
        func timed(_ body: () -> URL?) -> (URL?, Double) {
            let start = Date()
            let url = body()
            return (url, Date().timeIntervalSince(start) * 1000)
        }

        check(CalendarJoinLink.find(["Room 4", "Join: https://meet.google.com/abc-defg-hij."])?.absoluteString
              == "https://meet.google.com/abc-defg-hij", "a Meet link, trailing dot trimmed")
        check(CalendarJoinLink.find(["https://acme.zoom.us/j/123456789?pwd=xyz)"])?.absoluteString
              == "https://acme.zoom.us/j/123456789?pwd=xyz", "a Zoom link, trailing bracket trimmed")
        check(CalendarJoinLink.find(["https://example.com/agenda", nil]) == nil, "no meeting link")

        // A run of dots made the trailing trim quadratic: seconds on the main thread.
        let (dots, dotsMs) = timed { CalendarJoinLink.find(["https://zoom.us/j/" + String(repeating: ".", count: 10_000) + "x"]) }
        check(dotsMs < 50, "10 000 dots then a letter: \(Int(dotsMs)) ms")
        check(dots == nil, "an endless link is not a meeting link")
        let (trailing, trailingMs) = timed { CalendarJoinLink.find(["https://zoom.us/j/123" + String(repeating: ").,;", count: 2_500)]) }
        check(trailingMs < 50, "10 000 trailing marks: \(Int(trailingMs)) ms")
        check(trailing?.absoluteString == "https://zoom.us/j/123", "the link before the marks is kept")
        check(CalendarJoinLink.find(["https://acme.zoom.us/j/" + String(repeating: "1", count: 3000),
                                     "https://meet.google.com/abc-defg-hij"])?.absoluteString
              == "https://meet.google.com/abc-defg-hij", "a link over 2 048 characters is skipped")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("CalendarJoinLink: all passed")
    }
}
