import Foundation

@main
enum GitHubActivityTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    // MARK: - Fixture JSON
    //
    // Week 1 (complete, Jan 5–11 2026):
    //   Jan 5 wd=0 NONE(0), Jan 6 wd=1 FIRST_QUARTILE(1), Jan 7 wd=2 SECOND_QUARTILE(2),
    //   Jan 8 wd=3 THIRD_QUARTILE(3), Jan 9 wd=4 FOURTH_QUARTILE(4),
    //   Jan 10 wd=5 FIRST_QUARTILE(1), Jan 11 wd=6 NONE(0)
    //   counts: 0+1+4+8+12+2+0 = 27
    //
    // Week 2 (incomplete, Jan 12–13 2026):
    //   Jan 12 wd=0 SECOND_QUARTILE(2), Jan 13 wd=1 THIRD_QUARTILE(3)
    //   counts: 5+10 = 15
    //
    // Total: 42
    static let validJSON: Data = """
    {
      "data": {
        "viewer": {
          "login": "testuser",
          "contributionsCollection": {
            "contributionCalendar": {
              "totalContributions": 42,
              "weeks": [
                {
                  "contributionDays": [
                    {"date": "2026-01-05", "contributionCount": 0,  "contributionLevel": "NONE",            "weekday": 0},
                    {"date": "2026-01-06", "contributionCount": 1,  "contributionLevel": "FIRST_QUARTILE",  "weekday": 1},
                    {"date": "2026-01-07", "contributionCount": 4,  "contributionLevel": "SECOND_QUARTILE", "weekday": 2},
                    {"date": "2026-01-08", "contributionCount": 8,  "contributionLevel": "THIRD_QUARTILE",  "weekday": 3},
                    {"date": "2026-01-09", "contributionCount": 12, "contributionLevel": "FOURTH_QUARTILE", "weekday": 4},
                    {"date": "2026-01-10", "contributionCount": 2,  "contributionLevel": "FIRST_QUARTILE",  "weekday": 5},
                    {"date": "2026-01-11", "contributionCount": 0,  "contributionLevel": "NONE",            "weekday": 6}
                  ]
                },
                {
                  "contributionDays": [
                    {"date": "2026-01-12", "contributionCount": 5,  "contributionLevel": "SECOND_QUARTILE", "weekday": 0},
                    {"date": "2026-01-13", "contributionCount": 10, "contributionLevel": "THIRD_QUARTILE",  "weekday": 1}
                  ]
                }
              ]
            }
          }
        }
      }
    }
    """.data(using: .utf8)!

    static let unknownLevelJSON: Data = """
    {
      "data": {
        "viewer": {
          "login": "testuser",
          "contributionsCollection": {
            "contributionCalendar": {
              "totalContributions": 1,
              "weeks": [
                {
                  "contributionDays": [
                    {"date": "2026-03-01", "contributionCount": 1, "contributionLevel": "EXTRA_SPECIAL", "weekday": 0}
                  ]
                }
              ]
            }
          }
        }
      }
    }
    """.data(using: .utf8)!

    // MARK: - Main

    static func main() {

        // ── GitHubActivity.parse ──────────────────────────────────────────────
        print("GitHubActivity.parse")
        do {
            let act = GitHubActivity.parse(validJSON)
            check("parse returns non-nil", act != nil)
            check("total == 42",           act?.total == 42)
            check("2 weeks",               act?.weeks.count == 2)
            check("week 0 has 7 days",     act?.weeks[0].count == 7)
            check("week 1 has 2 days (incomplete)", act?.weeks[1].count == 2)
            // Level mapping
            check("NONE → level 0",            act?.weeks[0][0].level == 0)
            check("FIRST_QUARTILE → level 1",  act?.weeks[0][1].level == 1)
            check("SECOND_QUARTILE → level 2", act?.weeks[0][2].level == 2)
            check("THIRD_QUARTILE → level 3",  act?.weeks[0][3].level == 3)
            check("FOURTH_QUARTILE → level 4", act?.weeks[0][4].level == 4)
            // Dates and counts
            check("first day date",  act?.weeks[0][0].date    == "2026-01-05")
            check("first day count", act?.weeks[0][0].count   == 0)
            check("first day wd",    act?.weeks[0][0].weekday == 0)
            check("last day date",   act?.weeks[1][1].date    == "2026-01-13")
            check("last day count",  act?.weeks[1][1].count   == 10)
        }

        // ── GitHubActivity.parse — unknown level ─────────────────────────────
        print("GitHubActivity.parse — unknown level → 0")
        do {
            let act = GitHubActivity.parse(unknownLevelJSON)
            check("unknown level → 0", act?.weeks[0][0].level == 0)
        }

        // ── GitHubActivity.parse — bad data → nil ────────────────────────────
        print("GitHubActivity.parse — bad data")
        do {
            check("garbage → nil",  GitHubActivity.parse("garbage".data(using: .utf8)!) == nil)
            check("no data key → nil", GitHubActivity.parse("{}".data(using: .utf8)!) == nil)
        }

        // ── GitHubActivity.lastWeeks ─────────────────────────────────────────
        print("GitHubActivity.lastWeeks")
        do {
            let act = GitHubActivity.parse(validJSON)!
            check("lastWeeks(2) returns both",       act.lastWeeks(2).count == 2)
            check("lastWeeks(1) returns last week",  act.lastWeeks(1).count == 1)
            check("lastWeeks(1)[0] is incomplete",   act.lastWeeks(1)[0].count == 2)
            check("lastWeeks(1)[0][0].date",         act.lastWeeks(1)[0][0].date == "2026-01-12")
            check("lastWeeks(99) clamps to available", act.lastWeeks(99).count == 2)
            check("lastWeeks(0) returns empty",      act.lastWeeks(0).isEmpty)
        }

        // ── GitHubActivity.lastDays ──────────────────────────────────────────
        print("GitHubActivity.lastDays")
        do {
            let act = GitHubActivity.parse(validJSON)!
            // All 9 days flat, last 3 = Jan 11, Jan 12, Jan 13
            check("lastDays(3) count",          act.lastDays(3).count == 3)
            check("lastDays(3)[0].date",        act.lastDays(3)[0].date == "2026-01-11")
            check("lastDays(3)[2].date",        act.lastDays(3)[2].date == "2026-01-13")
            check("lastDays(9) all days",       act.lastDays(9).count == 9)
            check("lastDays(99) clamps to all", act.lastDays(99).count == 9)
            check("lastDays(0) empty",          act.lastDays(0).isEmpty)
        }

        // ── finish ────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
