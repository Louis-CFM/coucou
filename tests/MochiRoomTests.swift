import Foundation

@main @MainActor
enum MochiRoomTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        return c
    }()

    /// Noon on 24 November 2026 plus `days`, Paris time.
    static func day(_ days: Int, hour: Int = 12) -> Date {
        let base = calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: hour))!
        return calendar.date(byAdding: .day, value: days, to: base)!
    }

    static func main() {
        print("\nWhere Mochi stands")
        check("asked something → the door", MochiRoom.spot(waiting: true, busy: true) == .door)
        check("working → the desk", MochiRoom.spot(waiting: false, busy: true) == .desk)
        check("nothing runs → the bed", MochiRoom.spot(waiting: false, busy: false) == .bed)
        check("door turned off → he stays at the desk", MochiRoom.spot(waiting: true, busy: false, useDoor: false) == .desk)

        print("\nThe weather at the window")
        check("all green → sun", MochiRoom.weather(ci: [.success, .success], deploys: ["READY"]) == .sun)
        check("a red main branch → rain", MochiRoom.weather(ci: [.success, .failure], deploys: ["READY"]) == .rain)
        check("the last deploy failed → storm", MochiRoom.weather(ci: [.failure], deploys: ["ERROR", "READY"]) == .storm)
        check("an older failed deploy is forgotten", MochiRoom.weather(ci: [.success], deploys: ["READY", "ERROR"]) == .sun)
        check("building → cloudy", MochiRoom.weather(ci: [.pending], deploys: []) == .cloudy)
        check("deploying → cloudy", MochiRoom.weather(ci: [], deploys: ["BUILDING"]) == .cloudy)
        check("no GitHub, no Vercel → clear", MochiRoom.weather(ci: [], deploys: []) == .clear)
        check("Vercel only, ready → sun", MochiRoom.weather(ci: [.unknown], deploys: ["READY"]) == .sun)

        print("\nDay and night")
        check("21 h is night", MochiRoom.isNight(hour: 21))
        check("6 h is night", MochiRoom.isNight(hour: 6))
        check("7 h is day", !MochiRoom.isNight(hour: 7))
        check("19 h is day", !MochiRoom.isNight(hour: 19))

        print("\nThe streak plant")
        let today = day(0)
        check("no work → 0", MochiRoom.streak(days: [], today: today, calendar: calendar) == 0)
        check("three days ending today → 3",
              MochiRoom.streak(days: [day(0), day(-1), day(-2, hour: 23)], today: today, calendar: calendar) == 3)
        check("not started today yet: yesterday's streak still counts",
              MochiRoom.streak(days: [day(-1), day(-2)], today: today, calendar: calendar) == 2)
        check("a day off two days ago breaks it",
              MochiRoom.streak(days: [day(0), day(-2), day(-3)], today: today, calendar: calendar) == 1)
        check("last work two days ago → 0",
              MochiRoom.streak(days: [day(-2), day(-3)], today: today, calendar: calendar) == 0)
        check("several sessions in one day count once",
              MochiRoom.streak(days: [day(0, hour: 9), day(0, hour: 18), day(-1)], today: today, calendar: calendar) == 2)
        check("seed, sprout, leaves, flower",
              MochiRoom.plant(streak: 0) == .seed && MochiRoom.plant(streak: 1) == .sprout
              && MochiRoom.plant(streak: 3) == .leafy && MochiRoom.plant(streak: 7) == .bloom)

        print("\nThe frames")
        let payments: [(amount: Int, date: Date, succeeded: Bool)] = [
            (amount: 4900, date: day(0, hour: 9), succeeded: true),
            (amount: 3500, date: day(0, hour: 15), succeeded: true),
            (amount: 9900, date: day(0, hour: 16), succeeded: false),
            (amount: 1200, date: day(-1), succeeded: true),
        ]
        check("only today's succeeded payments", MochiRoom.paidToday(payments, today: today, calendar: calendar) == 8400)
        check("stars under 1000 as they are", MochiRoom.shortCount(842) == "842")
        check("1234 stars → 1.2k", MochiRoom.shortCount(1234) == "1.2k")
        check("2000 stars → 2k", MochiRoom.shortCount(2000) == "2k")
        check("15400 stars → 15k", MochiRoom.shortCount(15400) == "15k")
        check("134 minutes → 2 h 14", MochiRoom.duration(minutes: 134) == (hours: 2, minutes: 14))

        print("\nHidden tools")
        check("read back", MochiRoom.hiddenTools("stripe, calcom,") == ["stripe", "calcom"])
        check("written sorted", MochiRoom.hiddenToolsRaw(["vercel", "github"]) == "github,vercel")
        check("nothing hidden", MochiRoom.hiddenTools("").isEmpty)

        print(failures == 0 ? "\nAll Mochi's room tests passed." : "\n\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
