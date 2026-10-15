#if !APPSTORE
import AppKit
import Combine
import SwiftUI

/// A few minutes before a meeting, Mochi jumps out of the notch with the event, big, so it is
/// not forgotten. One timer set for the next reminder, nothing in between: the Mac's Calendar is
/// followed through its change notification only, Cal.com through its poller.
@MainActor
final class CalendarReminder: ObservableObject {
    static let shared = CalendarReminder()

    static let enabledKey = "calendarReminderEnabled"
    static let leadKey = "calendarReminderLead"
    static let leadChoices = [1, 5, 10, 15]

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    /// Minutes before the start.
    static var leadMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: leadKey)
        return v > 0 ? v : 5
    }

    /// The event shown in the notch, until the user closes it.
    @Published private(set) var current: AgendaItem?

    private var timer: Timer?
    private var snoozeTimer: Timer?
    /// Events already reminded of (by id), so each one comes once.
    private var reminded: Set<String> = []
    private var following = false
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// At launch, and when the settings change.
    func start() {
        guard cancellables.isEmpty else { refresh(); return }
        let calendar = AgendaCalendarStore.shared
        calendar.$events.combineLatest(AppState.shared.$calcomBookings)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in self?.schedule() }
            .store(in: &cancellables)
        // Access given later (Agenda page, Calendar tab): follow it from then on.
        calendar.$access
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)
        // A timer doesn't run while the Mac sleeps: look again on waking.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.schedule() } }
            .store(in: &cancellables)
        refresh()
    }

    /// Follows Calendar while reminders are on and allowed; schedules the next one.
    func refresh() {
        let calendar = AgendaCalendarStore.shared
        let want = Self.enabled && calendar.access == .fullAccess
        if want != following {
            following = want
            want ? calendar.start() : calendar.stop()
        }
        schedule()
    }

    // MARK: Timer

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard Self.enabled else { return }
        let now = Date()
        let lead = TimeInterval(Self.leadMinutes * 60)
        let items = AgendaCalendarStore.merged(AgendaCalendarStore.shared.events, AppState.shared.calcomBookings)
            .filter { !$0.allDay && $0.start > now && !reminded.contains($0.id) }
        guard let next = items.first else { return }
        let at = next.start.addingTimeInterval(-lead)
        if at <= now {
            show(next)
            return
        }
        let t = Timer(fire: at, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Showing

    /// Mochi comes out of the notch with the event.
    func show(_ item: AgendaItem) {
        reminded.insert(item.id)
        current = item
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.reminder)
        if AppState.shared.soundEnabled { SoundEngine.shared.play("greeting") }
        // Out of the notch: a wave, then wide eyes at the time.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .botGreet, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
        }
        schedule()
    }

    /// A pretend meeting in two minutes, to see the reminder (Agenda page).
    func preview() {
        let start = Date().addingTimeInterval(120)
        show(AgendaItem(id: "preview-\(start.timeIntervalSince1970)", title: String(localized: "reminder.preview-title"),
                        start: start, end: start.addingTimeInterval(1800), allDay: false,
                        color: Color(hex: "#3B9EFF"), source: String(localized: "notch.calendar.title"),
                        detail: nil, url: nil))
    }

    func join() {
        if let url = current?.url { NSWorkspace.shared.open(url) }
        dismiss()
    }

    /// Again in a minute, while the meeting has not ended.
    func snooze() {
        guard let item = current else { return }
        dismiss()
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, item.end > Date() else { return }
                self.show(item)
            }
        }
    }

    func dismiss() {
        guard current != nil else { return }
        current = nil
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    /// The user went to another tab: the reminder no longer holds the notch open.
    func viewClosed() {
        current = nil
    }
}

// MARK: - The reminder in the notch

/// The event, big, next to Mochi: when it starts (counting down), what, and a button to join.
struct NotchReminderView: View {
    @ObservedObject private var reminder = CalendarReminder.shared
    @Environment(\.islandViewActive) private var active
    @State private var shown = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item = reminder.current {
                card(item)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .whileTabActive(start: { withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.2)) { shown = true } },
                        stop: { shown = false; reminder.viewClosed() })
    }

    private func card(_ item: AgendaItem) -> some View {
        ZStack(alignment: .topLeading) {
            // The event's colour breathing around the card while it shows.
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !active)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let glow = 0.5 + 0.5 * sin(t * 3)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: "#111214"))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(RadialGradient(colors: [item.color.opacity(0.28), .clear],
                                             center: .bottomTrailing, startRadius: 0, endRadius: 360)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(item.color.opacity(0.25 + 0.35 * glow), lineWidth: 1.5))
                    .shadow(color: item.color.opacity(0.25 * glow), radius: 10)
            }
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    badge(item, now: timeline.date)
                }
                Text(item.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.3)
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle(item))
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#A4A9B1"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    if item.url != nil {
                        PrimaryButton(verbatim: String(localized: "reminder.join")) { reminder.join() }
                    }
                    SecondaryButton(verbatim: String(localized: "reminder.snooze")) { reminder.snooze() }
                    SecondaryButton(verbatim: "OK") { reminder.dismiss() }
                }
            }
            .padding(.leading, 140)
            .padding(.trailing, 18)
            .padding(.vertical, 14)
        }
        .scaleEffect(shown ? 1 : 0.86, anchor: .top)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : -14)
    }

    /// "IN 4:32", "STARTING", "NOW".
    private func badge(_ item: AgendaItem, now: Date) -> some View {
        let left = Int(item.start.timeIntervalSince(now).rounded(.up))
        let text: String
        if now >= item.start {
            text = String(localized: "hub.agenda.now")
        } else if left < 3600 {
            text = String(format: String(localized: "reminder.in %@"), String(format: "%d:%02d", left / 60, left % 60))
        } else {
            text = String(format: String(localized: "hub.agenda.in-hours %lld"), left / 3600)
        }
        return HStack(spacing: 5) {
            Image(systemName: "bell.fill")
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .tracking(0.8)
                .textCase(.uppercase)
        }
        .foregroundColor(item.color.lighter(by: 0.2))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(item.color.opacity(0.18)))
    }

    private func subtitle(_ item: AgendaItem) -> String {
        let time = "\(item.start.formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))"
        return [time, item.detail, item.source].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
#endif
