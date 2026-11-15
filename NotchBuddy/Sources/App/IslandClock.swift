import Foundation

/// The island's clock (Settings → General): what goes before the time, and 12 or 24 hours.
/// The same choices as Windows and Linux (windows/src/core/clock.ts).
enum ClockDate: String, CaseIterable {
    case date, weekday, timeOnly = "none"
}

/// `auto` follows the language.
enum ClockHours: String, CaseIterable {
    case auto, h24 = "24", h12 = "12"
}

enum IslandClock {
    static func timeText(_ now: Date, hours: ClockHours, locale: Locale = .autoupdatingCurrent) -> String {
        switch hours {
        case .h24:  return format(now, "HHmm", locale)
        case .h12:  return format(now, "hmma", locale)
        case .auto: return format(now, "jmm", locale)
        }
    }

    static func text(_ now: Date, date: ClockDate, hours: ClockHours, locale: Locale = .autoupdatingCurrent) -> String {
        let time = timeText(now, hours: hours, locale: locale)
        switch date {
        case .timeOnly: return time
        case .weekday: return "\(format(now, "EEE", locale))  \(time)"
        case .date:    return "\(format(now, "EEEdMMM", locale))  \(time)"
        }
    }

    private static func format(_ date: Date, _ template: String, _ locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }
}
