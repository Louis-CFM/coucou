import Foundation

enum Outfit: String, CaseIterable {
    case auto, none, partyHat, beanie, crown, sunglasses, roundGlasses,
         bow, scarf, witchHat, pumpkin, santaHat, bunnyEars

    var displayName: String {
        switch self {
        case .auto:         return "Auto (seasons)"
        case .none:         return "None"
        case .partyHat:     return "Party hat"
        case .beanie:       return "Beanie"
        case .crown:        return "Crown"
        case .sunglasses:   return "Sunglasses"
        case .roundGlasses: return "Round glasses"
        case .bow:          return "Bow"
        case .scarf:        return "Scarf"
        case .witchHat:     return "Witch hat"
        case .pumpkin:      return "Pumpkin"
        case .santaHat:     return "Santa hat"
        case .bunnyEars:    return "Bunny ears"
        }
    }

    // Returns the seasonal outfit for the given date (user's local calendar).
    // Priority: partyHat > santaHat > witchHat > bunnyEars > sunglasses > none
    static func seasonal(for date: Date, calendar: Calendar) -> Outfit {
        let day   = calendar.component(.day,   from: date)
        let month = calendar.component(.month, from: date)
        let year  = calendar.component(.year,  from: date)

        // Dec 31 – Jan 2 → party hat
        if (month == 12 && day == 31) || (month == 1 && day <= 2) { return .partyHat }

        // Dec 1–26 → santa hat
        if month == 12 && day <= 26 { return .santaHat }

        // Oct 1 – Nov 1 → witch hat
        if month == 10 || (month == 11 && day == 1) { return .witchHat }

        // Easter −2 / +1 → bunny ears (Meeus/Jones/Butcher algorithm)
        let (eMonth, eDay) = easterDate(year: year)
        let eComps         = DateComponents(year: year, month: eMonth, day: eDay)
        if let easterDate  = calendar.date(from: eComps) {
            let delta = calendar.dateComponents([.day], from: easterDate, to: date).day ?? 0
            if delta >= -2 && delta <= 1 { return .bunnyEars }
        }

        // Jun 21 – Aug 31 → sunglasses
        if (month == 6 && day >= 21) || month == 7 || month == 8 { return .sunglasses }

        return .none
    }

    // If selection == .auto → seasonal; otherwise selection itself.
    static func resolved(selection: Outfit, date: Date, calendar: Calendar) -> Outfit {
        selection == .auto ? seasonal(for: date, calendar: calendar) : selection
    }

    // UserDefaults key "mochiOutfit", default "auto", unknown value → .auto
    static var stored: Outfit {
        get {
            let raw = UserDefaults.standard.string(forKey: "mochiOutfit") ?? "auto"
            return Outfit(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "mochiOutfit")
        }
    }
}

// Meeus/Jones/Butcher algorithm — returns (month, day) of Easter Sunday for the given year.
private func easterDate(year: Int) -> (Int, Int) {
    let a = year % 19
    let b = year / 100
    let c = year % 100
    let d = b / 4
    let e = b % 4
    let f = (b + 8) / 25
    let g = (b - f + 1) / 3
    let h = (19 * a + b - d - g + 15) % 30
    let i = c / 4
    let k = c % 4
    let l = (32 + 2 * e + 2 * i - h - k) % 7
    let m = (a + 11 * h + 22 * l) / 451
    let month = (h + l - 7 * m + 114) / 31
    let day   = (h + l - 7 * m + 114) % 31 + 1
    return (month, day)
}
