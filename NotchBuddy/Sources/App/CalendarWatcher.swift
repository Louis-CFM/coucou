import AppKit
import EventKit

// MARK: - CalendarWatcher
// Today's and tomorrow's events from EventKit: every calendar of the Calendar app,
// Google accounts added in System Settings → Internet Accounts included. No key,
// no network of its own. Reads again when the store changes and every 5 min while
// the pill is declared; one timer reminds 5 minutes before the next meeting.
// Windows and Linux read a secret iCal address instead (windows/src/core/calendar.ts).

struct CalendarMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let joinURL: URL?
}

/// What the card shows: the meeting on now or next, the rest of today, today's all-day events.
struct CalendarAgenda: Equatable {
    var next: CalendarMeeting?
    var later: [CalendarMeeting]
    var allDay: [CalendarMeeting]

    init(_ meetings: [CalendarMeeting], now: Date, calendar: Calendar = .current) {
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let tomorrowEnd = calendar.date(byAdding: .day, value: 1, to: todayEnd)!
        let timed = meetings.filter { !$0.isAllDay && $0.end > now && $0.start < tomorrowEnd }
            .sorted { $0.start < $1.start }
        next = timed.first
        later = timed.dropFirst().filter { $0.start < todayEnd }
        allDay = meetings.filter { $0.isAllDay && $0.start < todayEnd && $0.end > now }
    }
}

@MainActor
final class CalendarWatcher {
    static let shared = CalendarWatcher()
    nonisolated static let pillId = "integration_calendar"
    static let reminderLead: TimeInterval = 5 * 60

    private static let refreshInterval: TimeInterval = 300
    private static let clearAfterStart: TimeInterval = 60
    private static let joinPattern = try! NSRegularExpression(
        pattern: #"https://(?:meet\.google\.com/[a-z0-9-]+|(?:[\w-]+\.)?zoom\.us/(?:j|my|w|s)/[^\s"<>\\]+|teams\.microsoft\.com/l/meetup-join/[^\s"<>\\]+|teams\.live\.com/meet/[^\s"<>\\]+)"#,
        options: [.caseInsensitive])

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var reminderTimer: Timer?
    private var reminderKey = ""

    private init() {}

    nonisolated static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Asked already and refused (or limited to adding events): only System Settings can change it.
    nonisolated static var accessDenied: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .denied, .restricted, .writeOnly: return true
        default: return false
        }
    }

    func start() {
        guard refreshTimer == nil else { return }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { CalendarWatcher.shared.refresh() }
        }
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { CalendarWatcher.shared.refresh() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    /// Shows the system prompt the first time; afterwards answers at once.
    func requestAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        if granted { refresh() }
        return granted
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Work (Google)", one per calendar, for the filter in Settings.
    func calendarLabels() -> [String] {
        guard Self.hasAccess else { return [] }
        return store.calendars(for: .event).map(label).sorted()
    }

    func refresh() {
        let state = AppState.shared
        guard !DemoEngine.isPollerPaused else { return }
        guard Self.hasAccess else {
            // Access taken back in System Settings: no stale meetings left on the card.
            state.setIfChanged(\.calendarMeetings, [])
            state.setIfChanged(\.calendarLoaded, false)
            return
        }
        guard state.activeIntegrations.contains(Self.pillId) else { return }

        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        let to = cal.date(byAdding: .day, value: 2, to: from)!
        let filter = state.calendarFilter
        let calendars = store.calendars(for: .event).filter { filter.isEmpty || filter.contains(label($0)) }
        let meetings: [CalendarMeeting] = calendars.isEmpty ? [] : store
            .events(matching: store.predicateForEvents(withStart: from, end: to, calendars: calendars))
            .filter { $0.status != .canceled }
            .map { e in
                CalendarMeeting(id: "\(e.calendarItemIdentifier)|\(e.startDate.timeIntervalSince1970)",
                                title: e.title ?? "", start: e.startDate, end: e.endDate,
                                isAllDay: e.isAllDay,
                                joinURL: Self.joinURL(e.url?.absoluteString, e.location, e.notes))
            }
            .sorted { $0.start < $1.start }

        state.setIfChanged(\.calendarMeetings, meetings)
        state.setIfChanged(\.calendarLoaded, true)
        scheduleReminder()
    }

    /// The first Meet, Zoom or Teams link in these texts, in order.
    static func joinURL(_ texts: String?...) -> URL? {
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = joinPattern.firstMatch(in: text, range: range),
                  let r = Range(match.range, in: text) else { continue }
            let link = String(text[r]).replacingOccurrences(of: #"[).,;]+$"#, with: "", options: .regularExpression)
            if let url = URL(string: link) { return url }
        }
        return nil
    }

    private func label(_ calendar: EKCalendar) -> String {
        "\(calendar.title) (\(calendar.source.title))"
    }

    // MARK: - Reminder

    private func scheduleReminder() {
        let next = CalendarAgenda(AppState.shared.calendarMeetings, now: Date()).next
        let key = next.map { $0.id } ?? ""
        guard key != reminderKey else { return }
        reminderKey = key
        reminderTimer?.invalidate()
        reminderTimer = nil
        guard let next, next.start > Date() else { return }

        let fireAt = max(Date(), next.start.addingTimeInterval(-Self.reminderLead))
        let timer = Timer(fire: fireAt, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { CalendarWatcher.shared.remind(next) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
    }

    private func remind(_ meeting: CalendarMeeting) {
        reminderTimer = nil
        let state = AppState.shared
        guard !DemoEngine.isPollerPaused, Date() < meeting.start,
              let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }

        state.tasks[idx].state = .question
        state.tasks[idx].steps = [meeting.title]
        if state.focusId != Self.pillId { state.tasks[idx].pillBadge = .approval }
        SoundEngine.shared.play("question")
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        let clearAt = meeting.start.timeIntervalSinceNow + Self.clearAfterStart
        DispatchQueue.main.asyncAfter(deadline: .now() + clearAt) {
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
                  state.tasks[i].state == .question else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }
}
