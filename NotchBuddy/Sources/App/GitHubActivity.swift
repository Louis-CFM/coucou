import Foundation

// MARK: - ContributionDay

struct ContributionDay: Equatable {
    var date: String    // YYYY-MM-DD
    var count: Int
    var level: Int      // 0…4 (NONE, FIRST_QUARTILE, SECOND_QUARTILE, THIRD_QUARTILE, FOURTH_QUARTILE)
    var weekday: Int    // 0 = Sunday … 6 = Saturday
}

// MARK: - GitHubActivity

struct GitHubActivity: Equatable {
    var total: Int
    var weeks: [[ContributionDay]]
    var fetchedAt: Date

    // MARK: - Parse

    static func parse(_ data: Data) -> GitHubActivity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let viewer = dataNode["viewer"] as? [String: Any],
              let cc = viewer["contributionsCollection"] as? [String: Any],
              let cal = cc["contributionCalendar"] as? [String: Any],
              let total = cal["totalContributions"] as? Int,
              let weeksRaw = cal["weeks"] as? [[String: Any]] else { return nil }

        var weeks: [[ContributionDay]] = []
        for weekRaw in weeksRaw {
            guard let daysRaw = weekRaw["contributionDays"] as? [[String: Any]] else { continue }
            var days: [ContributionDay] = []
            for dayRaw in daysRaw {
                guard let date     = dayRaw["date"]              as? String,
                      let count    = dayRaw["contributionCount"] as? Int,
                      let levelStr = dayRaw["contributionLevel"] as? String,
                      let weekday  = dayRaw["weekday"]           as? Int else { continue }
                let level: Int
                switch levelStr {
                case "FIRST_QUARTILE":  level = 1
                case "SECOND_QUARTILE": level = 2
                case "THIRD_QUARTILE":  level = 3
                case "FOURTH_QUARTILE": level = 4
                default:                level = 0  // NONE or unknown
                }
                days.append(ContributionDay(date: date, count: count, level: level, weekday: weekday))
            }
            if !days.isEmpty { weeks.append(days) }
        }

        return GitHubActivity(total: total, weeks: weeks, fetchedAt: Date())
    }

    // MARK: - Helpers

    /// Returns the last n weeks in chronological order (oldest first).
    /// The last week may be incomplete (current week in progress).
    func lastWeeks(_ n: Int) -> [[ContributionDay]] {
        guard n > 0 else { return [] }
        let start = max(0, weeks.count - n)
        return Array(weeks[start...])
    }

    /// Returns the last n days in chronological order (oldest first).
    func lastDays(_ n: Int) -> [ContributionDay] {
        guard n > 0 else { return [] }
        let all = weeks.flatMap { $0 }
        let start = max(0, all.count - n)
        return Array(all[start...])
    }
}
