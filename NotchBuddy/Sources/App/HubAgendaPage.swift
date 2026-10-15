#if !APPSTORE
import AppKit
import EventKit
import SwiftUI

/// One event of the agenda, from the Mac's Calendar or from Cal.com.
struct AgendaItem: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    /// The calendar's name, or "Cal.com".
    let source: String
    let detail: String?
    let url: URL?

    func isNow(_ now: Date) -> Bool { !allDay && start <= now && now < end }
}

/// The Mac's Calendar (EventKit): every account set up there (iCloud, Google, Outlook…).
/// Read only while the Agenda page or the Calendar pill's card is on screen, never in the background.
@MainActor
final class AgendaCalendarStore: ObservableObject {
    static let shared = AgendaCalendarStore()
    nonisolated static let pillId = "integration_calendar"

    /// The days the page shows, from today.
    static let days = 14

    @Published private(set) var access: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var events: [AgendaItem] = []

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    /// The views showing the events (the page, the pill's card): Calendar is followed while any is.
    private var viewers = 0

    var granted: Bool { access == .fullAccess }

    /// Asks once, after the user's click.
    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            access = EKEventStore.authorizationStatus(for: .event)
            if granted { store.reset() }
            refresh()
        }
    }

    /// A view showing the events appeared: read them and follow Calendar's changes.
    func start() {
        viewers += 1
        refresh()
    }

    /// That view went away: nothing to follow once none is left.
    func stop() {
        viewers = max(0, viewers - 1)
        guard viewers == 0 else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func refresh() {
        access = EKEventStore.authorizationStatus(for: .event)
        guard granted else { return }
        reload()
        guard observer == nil, viewers > 0 else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The Mac's events and the Cal.com bookings, in time order.
    static func merged(_ events: [AgendaItem], _ bookings: [CalcomBooking]) -> [AgendaItem] {
        let cal = bookings.filter(\.isActive).map { b in
            AgendaItem(id: "cal-\(b.id)", title: b.title, start: b.startTime, end: b.endTime, allDay: false,
                       color: Color(hex: "#C9956A"), source: "Cal.com",
                       detail: b.attendeeName ?? b.attendeeEmail, url: nil)
        }
        // The same event in several calendars (a holiday in each account) shows once.
        var seen = Set<String>()
        return (events + cal)
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
            .filter { seen.insert("\($0.title)|\($0.start.timeIntervalSince1970)|\($0.allDay)").inserted }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reload() {
        let cal = Calendar.current
        let from = cal.startOfDay(for: Date())
        guard let to = cal.date(byAdding: .day, value: Self.days, to: from) else { return }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { e in
                AgendaItem(id: "ek-\(e.calendarItemIdentifier)-\(e.startDate.timeIntervalSince1970)",
                           title: e.title?.isEmpty == false ? e.title! : String(localized: "hub.agenda.untitled"),
                           start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                           color: e.calendar.map { Color(cgColor: $0.cgColor) } ?? HubTheme.accent,
                           source: e.calendar?.title ?? "",
                           detail: e.location?.isEmpty == false ? e.location : nil,
                           url: e.url ?? Self.meetingLink(in: e.notes))
            }
    }

    /// A Meet, Zoom or Teams link written in the event's notes.
    nonisolated static func meetingLink(in text: String?) -> URL? {
        guard let text, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let hosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com"]
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first { url in hosts.contains { url.host?.hasSuffix($0) == true } }
    }
}

/// The Agenda page: the next two weeks of the Mac's Calendar and of Cal.com, together.
struct HubAgendaPage: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var calendar = AgendaCalendarStore.shared
    @ObservedObject private var state = AppState.shared
    @AppStorage(CalendarReminder.enabledKey) private var reminderOn = true
    @AppStorage(CalendarReminder.leadKey) private var reminderLead = 5

    private var calcomConnected: Bool { KeychainStore.shared.get("calcom-api-key") != nil }

    private var items: [AgendaItem] { AgendaCalendarStore.merged(calendar.events, state.calcomBookings) }

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.agenda"),
                        subtitle: String(localized: "hub.agenda.subtitle")) {
            if !calendar.granted || !calcomConnected { connect }
            reminderSettings
            // Re-read each minute: "now", "in 12 min" and what has ended move on.
            TimelineView(.everyMinute) { timeline in
                content(now: timeline.date)
            }
        }
        .onAppear { calendar.start() }
        .onDisappear { calendar.stop() }
    }

    // MARK: Sources

    private var connect: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !calendar.granted {
                HubGlowCard(color: Color(hex: "#3B9EFF")) {
                    Text("hub.agenda.calendar-title")
                        .font(.system(size: 16, weight: .bold))
                    Text("hub.agenda.calendar-detail")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#C7CAD0"))
                        .fixedSize(horizontal: false, vertical: true)
                    if calendar.access == .notDetermined {
                        Button(String(localized: "hub.agenda.calendar-allow")) { calendar.requestAccess() }
                            .buttonStyle(HubButtonStyle(primary: true))
                    } else {
                        // Refused once: only System Settings can give it back.
                        Button(String(localized: "hub.agenda.calendar-settings")) { calendar.openSystemSettings() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
            if !calcomConnected {
                HubCard {
                    HubRow(title: "Cal.com", detail: String(localized: "hub.agenda.calcom-detail")) {
                        Button(String(localized: "hub.agenda.calcom-connect")) { router.page = .integrations }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: Reminder

    /// Mochi coming out of the notch before a meeting: on or off, how long before, and a try.
    private var reminderSettings: some View {
        HubCard {
            HubRow(title: String(localized: "hub.agenda.reminder"), detail: String(localized: "hub.agenda.reminder-detail")) {
                Toggle("", isOn: $reminderOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onChange(of: reminderOn) { _, _ in CalendarReminder.shared.refresh() }
            }
            if reminderOn {
                HubDivider()
                HubRow(title: String(localized: "hub.agenda.reminder-lead")) {
                    HStack(spacing: 10) {
                        Picker("", selection: $reminderLead) {
                            ForEach(CalendarReminder.leadChoices, id: \.self) { m in
                                Text(String(format: String(localized: "hub.agenda.minutes %lld"), m)).tag(m)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: reminderLead) { _, _ in CalendarReminder.shared.refresh() }
                        Button(String(localized: "hub.agenda.reminder-try")) { CalendarReminder.shared.preview() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: Events

    @ViewBuilder private func content(now: Date) -> some View {
        let upcoming = items.filter { $0.end > now }
        if upcoming.isEmpty {
            if calendar.granted || calcomConnected {
                HubCard { HubEmptyState(text: String(localized: "hub.agenda.empty"), state: .sleeping, color: "#3B9EFF") }
            }
        } else {
            VStack(alignment: .leading, spacing: 22) {
                if let next = upcoming.first(where: { !$0.allDay }) {
                    HubAgendaNext(item: next, now: now)
                }
                ForEach(Self.days(of: upcoming), id: \.day) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HubLabel(Self.dayTitle(group.day, now: now))
                        HubCard(padding: 6) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { HubDivider().padding(.horizontal, 12) }
                                    HubAgendaRow(item: item, now: now)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func days(of items: [AgendaItem]) -> [(day: Date, items: [AgendaItem])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: items) { cal.startOfDay(for: max($0.start, cal.startOfDay(for: Date()))) }
        return groups.keys.sorted().map { day in
            // All-day events first, then by time.
            (day, groups[day]!.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) })
        }
    }

    private static func dayTitle(_ day: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(day, inSameDayAs: now) { return String(localized: "hub.agenda.today") }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(day, inSameDayAs: tomorrow) {
            return String(localized: "hub.agenda.tomorrow")
        }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

/// The next meeting, big: in how long, and the button to join it.
private struct HubAgendaNext: View {
    let item: AgendaItem
    let now: Date

    var body: some View {
        HubGlowCard(color: item.color) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.isNow(now) ? String(localized: "hub.agenda.now") : Self.countdown(to: item.start, from: now))
                        .font(.system(size: 11.5, weight: .bold))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundColor(item.color)
                    Text(item.title)
                        .font(.system(size: 20, weight: .bold))
                        .lineLimit(2)
                    Text(HubAgendaRow.timeRange(item) + (item.detail.map { " · \($0)" } ?? ""))
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#C7CAD0"))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let url = item.url {
                    Button(String(localized: "hub.agenda.join")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
        }
    }

    /// "In 12 min", "In 2 h", "Tomorrow at 9:00"…
    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes < 60 { return String(format: String(localized: "hub.agenda.in-min %lld"), max(1, minutes)) }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return String(format: String(localized: "hub.agenda.in-hours %lld"), minutes / 60)
        }
        return date.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

private struct HubAgendaRow: View {
    let item: AgendaItem
    let now: Date
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.color)
                .frame(width: 4, height: 34)
            Text(item.allDay ? String(localized: "hub.agenda.all-day") : item.start.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundColor(item.isNow(now) ? item.color : HubTheme.body)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1)
                Text([item.allDay ? nil : Self.timeRange(item), item.source, item.detail]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.isNow(now) {
                Text("hub.agenda.now")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(HubTheme.onAccent)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(item.color))
            }
            if let url = item.url {
                HubIconButton(symbol: "video", help: String(localized: "hub.agenda.join")) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.03 : 0)))
        .opacity(item.end <= now ? 0.45 : 1)
        .onHover { hover = $0 }
    }

    static func timeRange(_ item: AgendaItem) -> String {
        "\(item.start.formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))"
    }
}
#endif
