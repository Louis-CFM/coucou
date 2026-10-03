import Foundation

@main
enum MochiWardrobeTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func date(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    static func seasonal(_ year: Int, _ month: Int, _ day: Int) -> Outfit {
        Outfit.seasonal(for: date(year: year, month: month, day: day),
                        calendar: Calendar(identifier: .gregorian))
    }

    static func main() {
        print("Outfit.seasonal — witch hat (Oct 1 – Nov 1)")
        check("Sep 30 → none",      seasonal(2026, 9, 30)  == .none)
        check("Oct 1 → witchHat",   seasonal(2026, 10, 1)  == .witchHat)
        check("Oct 31 → witchHat",  seasonal(2026, 10, 31) == .witchHat)
        check("Nov 1 → witchHat",   seasonal(2026, 11, 1)  == .witchHat)
        check("Nov 2 → none",       seasonal(2026, 11, 2)  == .none)

        print("Outfit.seasonal — santa hat (Dec 1–26)")
        check("Nov 30 → none",      seasonal(2026, 11, 30) == .none)
        check("Dec 1 → santaHat",   seasonal(2026, 12, 1)  == .santaHat)
        check("Dec 26 → santaHat",  seasonal(2026, 12, 26) == .santaHat)
        check("Dec 27 → none",      seasonal(2026, 12, 27) == .none)

        print("Outfit.seasonal — party hat (Dec 31 – Jan 2)")
        check("Dec 30 → none",      seasonal(2026, 12, 30) == .none)
        check("Dec 31 → partyHat",  seasonal(2026, 12, 31) == .partyHat)
        check("Jan 1 → partyHat",   seasonal(2027, 1, 1)   == .partyHat)
        check("Jan 2 → partyHat",   seasonal(2027, 1, 2)   == .partyHat)
        check("Jan 3 → none",       seasonal(2027, 1, 3)   == .none)

        print("Outfit.seasonal — hearts (Feb 13–15)")
        check("Feb 12 → none",        seasonal(2026, 2, 12) == .none)
        check("Feb 13 → hearts",      seasonal(2026, 2, 13) == .heartsHeadband)
        check("Feb 15 → hearts",      seasonal(2026, 2, 15) == .heartsHeadband)
        check("Feb 16 → none",        seasonal(2026, 2, 16) == .none)

        print("Outfit.seasonal — bunny ears (Easter ±)")
        // Easter 2026 = April 5
        check("Apr 3 2026 → bunnyEars",  seasonal(2026, 4, 3)  == .bunnyEars)  // -2
        check("Apr 4 2026 → bunnyEars",  seasonal(2026, 4, 4)  == .bunnyEars)  // -1
        check("Apr 5 2026 → bunnyEars",  seasonal(2026, 4, 5)  == .bunnyEars)  // 0
        check("Apr 6 2026 → bunnyEars",  seasonal(2026, 4, 6)  == .bunnyEars)  // +1
        check("Apr 7 2026 → none",       seasonal(2026, 4, 7)  == .none)       // +2
        check("Apr 2 2026 → none",       seasonal(2026, 4, 2)  == .none)       // -3
        // Easter 2027 = March 28
        check("Mar 26 2027 → bunnyEars", seasonal(2027, 3, 26) == .bunnyEars)
        check("Mar 29 2027 → bunnyEars", seasonal(2027, 3, 29) == .bunnyEars)
        check("Mar 30 2027 → none",      seasonal(2027, 3, 30) == .none)
        // Easter 2028 = April 16
        check("Apr 14 2028 → bunnyEars", seasonal(2028, 4, 14) == .bunnyEars)
        check("Apr 17 2028 → bunnyEars", seasonal(2028, 4, 17) == .bunnyEars)
        check("Apr 18 2028 → none",      seasonal(2028, 4, 18) == .none)

        print("Outfit.seasonal — sunglasses (Jun 21 – Aug 31)")
        check("Jun 20 → none",       seasonal(2026, 6, 20) == .none)
        check("Jun 21 → sunglasses", seasonal(2026, 6, 21) == .sunglasses)
        check("Aug 31 → sunglasses", seasonal(2026, 8, 31) == .sunglasses)
        check("Sep 1 → none",        seasonal(2026, 9, 1)  == .none)

        print("Outfit.resolved")
        let d = date(year: 2026, month: 10, day: 15)
        let cal = Calendar(identifier: .gregorian)
        check("auto → seasonal",     Outfit.resolved(selection: .auto, date: d, calendar: cal) == .witchHat)
        check("none → none",         Outfit.resolved(selection: .none, date: d, calendar: cal) == .none)
        check("beanie → beanie",     Outfit.resolved(selection: .beanie, date: d, calendar: cal) == .beanie)

        print("Outfit.rawValue stability")
        check("auto rawValue",           Outfit.auto.rawValue           == "auto")
        check("none rawValue",           Outfit.none.rawValue           == "none")
        check("partyHat rawValue",       Outfit.partyHat.rawValue       == "partyHat")
        check("beanie rawValue",         Outfit.beanie.rawValue         == "beanie")
        check("crown rawValue",          Outfit.crown.rawValue          == "crown")
        check("topHat rawValue",         Outfit.topHat.rawValue         == "topHat")
        check("cap rawValue",            Outfit.cap.rawValue            == "cap")
        check("sunglasses rawValue",     Outfit.sunglasses.rawValue     == "sunglasses")
        check("roundGlasses rawValue",   Outfit.roundGlasses.rawValue   == "roundGlasses")
        check("bow rawValue",            Outfit.bow.rawValue            == "bow")
        check("scarf rawValue",          Outfit.scarf.rawValue          == "scarf")
        check("witchHat rawValue",       Outfit.witchHat.rawValue       == "witchHat")
        check("pumpkin rawValue",        Outfit.pumpkin.rawValue        == "pumpkin")
        check("santaHat rawValue",       Outfit.santaHat.rawValue       == "santaHat")
        check("bunnyEars rawValue",      Outfit.bunnyEars.rawValue      == "bunnyEars")
        check("heartsHeadband rawValue", Outfit.heartsHeadband.rawValue == "heartsHeadband")
        check("strawHat rawValue",       Outfit.strawHat.rawValue       == "strawHat")

        print("Outfit.stored unknown → auto")
        UserDefaults.standard.set("totallyUnknown", forKey: "mochiOutfit")
        check("unknown → .auto", Outfit.stored == .auto)
        UserDefaults.standard.removeObject(forKey: "mochiOutfit")
        check("missing → .auto", Outfit.stored == .auto)

        if failures == 0 { print("\nAll tests passed.") }
        else              { print("\n\(failures) test(s) FAILED."); exit(1) }
    }
}
