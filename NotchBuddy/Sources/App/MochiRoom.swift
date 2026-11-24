import Foundation

/// Mochi's room (the Coucou window, GitHub build): where Mochi stands, the weather at the window,
/// the plant, the day and the night. Every object of the room is read from data Coucou already
/// has; nothing here asks a service anything. Foundation only, so the rules are tested alone
/// (scripts/test-mochi-room.sh).
enum MochiRoom {
    /// Off by default: the page shows what the room is and a button to turn it on.
    static let enabledKey = "mochiRoomEnabled"
    /// Mochi walks to the door when an agent asks something, and the card opens in the room.
    static let doorKey = "mochiRoomDoor"
    /// The window shows the CI and the deploys (sun, rain, storm).
    static let weatherKey = "mochiRoomWeather"
    /// The room gets dark at night.
    static let dayNightKey = "mochiRoomDayNight"
    /// The tools hidden from the walls, by id ("stripe,calcom").
    static let hiddenToolsKey = "mochiRoomHiddenTools"

    // MARK: - Where Mochi stands

    enum Spot: Equatable {
        /// An agent asks something: Mochi waits at the door.
        case door
        /// An agent works: Mochi sits at the desk.
        case desk
        /// Nothing runs: Mochi naps on the bed.
        case bed
    }

    /// The door first (someone waits for you), then the desk, then the bed.
    static func spot(waiting: Bool, busy: Bool, useDoor: Bool = true) -> Spot {
        if waiting && useDoor { return .door }
        if waiting || busy { return .desk }
        return .bed
    }

    // MARK: - The window

    enum Weather: Equatable {
        /// Every build and the last deploy are green.
        case sun
        /// Something builds or deploys right now.
        case cloudy
        /// A build failed on a main branch.
        case rain
        /// The last deploy failed: production may be down.
        case storm
        /// Nothing to show (no GitHub, no Vercel).
        case clear
    }

    /// `ci`: the CI of the main branches. `deploys`: the Vercel states, newest first
    /// ("READY", "ERROR", "BUILDING"…). The worst news wins.
    static func weather(ci: [CIState], deploys: [String]) -> Weather {
        let lastDeploy = deploys.first?.uppercased()
        if lastDeploy == "ERROR" { return .storm }
        if ci.contains(.failure) { return .rain }
        let deploying = lastDeploy.map { ["BUILDING", "QUEUED", "INITIALIZING"].contains($0) } ?? false
        if ci.contains(.pending) || deploying { return .cloudy }
        if ci.contains(.success) || lastDeploy == "READY" { return .sun }
        return .clear
    }

    // MARK: - Day and night

    /// Night from 20:00 to 6:59.
    static func isNight(hour: Int) -> Bool { hour >= 20 || hour < 7 }

    // MARK: - The plant

    /// Days in a row with at least one agent session, ending today or yesterday (today still
    /// counts while you have not started yet). `days`: any dates with work, in any order.
    static func streak(days: [Date], today: Date, calendar: Calendar = .current) -> Int {
        let worked = Set(days.map { calendar.startOfDay(for: $0) })
        var day = calendar.startOfDay(for: today)
        if !worked.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
                  worked.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while worked.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    enum Plant: Equatable { case seed, sprout, leafy, bloom }

    /// Grows with the streak: a seed, then a sprout (1 day), leaves (3), a flower (7).
    static func plant(streak: Int) -> Plant {
        switch streak {
        case ..<1: return .seed
        case 1..<3: return .sprout
        case 3..<7: return .leafy
        default: return .bloom
        }
    }

    // MARK: - The frames on the wall

    /// What a tool shows in its frame today, from the data its poller already has.
    /// Amounts are in the smallest unit (cents): only today's succeeded payments count.
    static func paidToday(_ payments: [(amount: Int, date: Date, succeeded: Bool)], today: Date,
                          calendar: Calendar = .current) -> Int {
        payments.filter { $0.succeeded && calendar.isDate($0.date, inSameDayAs: today) }
            .reduce(0) { $0 + $1.amount }
    }

    /// "1.2k" for the stars on a frame.
    static func shortCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let k = Double(n) / 1000
        let text = k < 10 ? String(format: "%.1f", k) : String(format: "%.0f", k)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
    }

    /// "2 h 14" or "38 min".
    static func duration(minutes: Int) -> (hours: Int, minutes: Int) {
        (max(0, minutes) / 60, max(0, minutes) % 60)
    }

    // MARK: - Hidden tools

    static func hiddenTools(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    static func hiddenToolsRaw(_ set: Set<String>) -> String { set.sorted().joined(separator: ",") }
}
