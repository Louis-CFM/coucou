import Foundation

@main
enum IslandClockTests {

    static var failures = 0

    static func check(_ label: String, _ got: String, _ expected: String) {
        if got == expected {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            print("    got:      \(got.debugDescription)")
            print("    expected: \(expected.debugDescription)")
            failures += 1
        }
    }

    static func main() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (2026, 11, 15, 14, 6)
        let now = Calendar(identifier: .gregorian).date(from: parts)!
        let gb = Locale(identifier: "en_GB"), us = Locale(identifier: "en_US")

        print("Island clock")
        check("24 hours whatever the language", IslandClock.timeText(now, hours: .h24, locale: us), "14:06")
        check("12 hours with the day period", IslandClock.timeText(now, hours: .h12, locale: gb)
            .replacingOccurrences(of: "\u{202F}", with: " ").lowercased(), "2:06 pm")
        check("automatic follows the language", IslandClock.timeText(now, hours: .auto, locale: gb), "14:06")
        check("the time alone", IslandClock.text(now, date: .timeOnly, hours: .h24, locale: gb), "14:06")
        check("with the weekday", IslandClock.text(now, date: .weekday, hours: .h24, locale: gb), "Sun  14:06")
        check("with the date", IslandClock.text(now, date: .date, hours: .h24, locale: gb), "Sun 15 Nov  14:06")
        check("an unknown choice reads as the default", (ClockDate(rawValue: "year") ?? .date).rawValue, "date")

        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All island clock tests passed")
    }
}
