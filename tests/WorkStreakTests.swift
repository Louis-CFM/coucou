import Foundation

@main
enum WorkStreakTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// An agent busy every `every` minutes from `from` to `to`, the user at the keyboard.
    static func work(_ streak: inout WorkStreak, from: Double, to: Double, every: Double = 5) {
        var m = from
        while m <= to { streak.activity(at: at(m), userIdle: 10); m += every }
    }

    static func main() {
        print("\nSleepy after long work")
        var s = WorkStreak()
        check("fresh with no work", s.tiredness(at: at(0), userIdle: 0) == 0)
        work(&s, from: 0, to: 110)
        check("fresh after 1 h 50", s.tiredness(at: at(110), userIdle: 10) == 0)
        work(&s, from: 115, to: 125)
        check("sleepy after 2 h", s.tiredness(at: at(125), userIdle: 10) == 0.7)
        work(&s, from: 130, to: 185)
        check("very sleepy after 3 h", s.tiredness(at: at(185), userIdle: 10) == 1)

        print("\nA break makes him fresh again")
        var b = WorkStreak()
        work(&b, from: 0, to: 130)
        check("sleepy before the break", b.tiredness(at: at(130), userIdle: 10) == 0.7)
        check("fresh during a 20 min pause with no agent", b.tiredness(at: at(151), userIdle: 10) == 0)
        b.activity(at: at(152), userIdle: 10)
        check("still fresh when the agents start again", b.tiredness(at: at(152), userIdle: 10) == 0)
        check("the streak started over", b.start == at(152))

        print("\nAway from the keyboard is a break")
        var k = WorkStreak()
        work(&k, from: 0, to: 125)
        // The agent keeps working, but nobody touched the Mac for 25 minutes.
        check("fresh while you are away", k.tiredness(at: at(126), userIdle: 25 * 60) == 0)
        var k2 = WorkStreak()
        work(&k2, from: 0, to: 125)
        k2.activity(at: at(130), userIdle: 21 * 60)
        check("an event while you were away starts over", k2.start == at(130))

        print("\nShort pauses don't count")
        var p = WorkStreak()
        work(&p, from: 0, to: 60)
        work(&p, from: 75, to: 125)   // a 15 min pause
        check("still sleepy after a 15 min pause", p.tiredness(at: at(125), userIdle: 10) == 0.7)

        print(failures == 0 ? "\nAll good." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
