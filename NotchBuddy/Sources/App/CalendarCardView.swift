#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - Calendar Card View (the Calendar tab and pill: the Mac's Calendar and Cal.com)

/// Today's date, then the next events side by side as small cards in their calendar's colour.
/// Calendar is read only while this card shows.
struct CalendarCardView: View {
    @ObservedObject private var calendar = AgendaCalendarStore.shared
    @ObservedObject private var appState = AppState.shared

    static let accent = Color(hex: "#FF5A4F")
    private static let maxRows = 12

    var body: some View {
        // Re-read each minute: "in 12 min" and what has ended move on.
        TimelineView(.everyMinute) { timeline in
            content(now: timeline.date)
        }
        .padding(.leading, 108).padding(.trailing, 36).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .transition(.opacity)
        .whileTabActive(start: { calendar.start() }, stop: { calendar.stop() })
    }

    private func content(now: Date) -> some View {
        // Timed events only (holidays and other all-day ones stay in Calendar), in time order.
        let upcoming = AgendaCalendarStore.merged(calendar.events, appState.calcomBookings)
            .filter { !$0.allDay && $0.end > now }
        return HStack(alignment: .top, spacing: 10) {
            CalendarDateBlock(now: now)
            if !calendar.granted && upcoming.isEmpty {
                accessTile
            } else if upcoming.isEmpty {
                CalendarMessageTile(symbol: "checkmark.circle", text: String(localized: "hub.agenda.empty"))
            } else {
                CalendarTimeline(items: Array(upcoming.prefix(Self.maxRows)), now: now)
            }
        }
    }

    private var accessTile: some View {
        Button {
            if calendar.access == .notDetermined { calendar.requestAccess() } else { calendar.openSystemSettings() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "lock.open")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Self.accent)
                Text("notch.calendar.access")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(calendar.access == .notDetermined ? String(localized: "hub.agenda.calendar-allow")
                                                       : String(localized: "hub.agenda.calendar-settings"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Self.accent)
            }
            .padding(9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Self.accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Self.accent.opacity(0.22)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func openCalendar() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }
}

/// Today, like Calendar's icon: the weekday in red, the day big, the month under it.
private struct CalendarDateBlock: View {
    let now: Date

    var body: some View {
        Button { CalendarCardView.openCalendar() } label: {
            VStack(spacing: 0) {
                Text(now.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(CalendarCardView.accent)
                Text(now.formatted(.dateTime.day()))
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(now.formatted(.dateTime.month(.abbreviated)))
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .frame(width: 54)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "notch.calendar.title"))
    }
}

/// The events from top to bottom on a thin line, the next one lit: time, dot, title, when.
/// Scrolls when there are more than fit.
private struct CalendarTimeline: View {
    let items: [AgendaItem]
    let now: Date

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    CalendarTimelineRow(item: item, now: now, first: index == 0, last: index == items.count - 1,
                                        newDay: index > 0 && !Calendar.current.isDate(item.start, inSameDayAs: items[index - 1].start))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CalendarTimelineRow: View {
    let item: AgendaItem
    let now: Date
    /// The first row is the next event (or the one going on): lit.
    let first: Bool
    let last: Bool
    /// First event of another day: its day is written before the time.
    let newDay: Bool
    @State private var hover = false

    private var live: Bool { item.isNow(now) }

    var body: some View {
        Button {
            if let url = item.url { NSWorkspace.shared.open(url) } else { CalendarCardView.openCalendar() }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Text(timeLabel)
                    .font(.system(size: 10.5, weight: first ? .semibold : .medium).monospacedDigit())
                    .foregroundColor(first ? Color(hex: "#F5F6F8") : Color(hex: "#8E939C"))
                    .lineLimit(1)
                    .frame(width: 66, alignment: .trailing)
                // The line through the events, and this one's dot.
                ZStack {
                    VStack(spacing: 0) {
                        Rectangle().fill(first ? Color.clear : Color.white.opacity(0.12)).frame(width: 1.5)
                        Rectangle().fill(last ? Color.clear : Color.white.opacity(0.12)).frame(width: 1.5)
                    }
                    Circle()
                        .fill(first ? item.color : Color(hex: "#111214"))
                        .overlay(Circle().strokeBorder(item.color, lineWidth: 1.5))
                        .frame(width: first ? 9 : 7, height: first ? 9 : 7)
                        .shadow(color: first ? item.color.opacity(0.7) : .clear, radius: 4)
                }
                .frame(width: 10)
                Text(item.title)
                    .font(.system(size: first ? 12.5 : 11.5, weight: first ? .semibold : .regular))
                    .foregroundColor(first ? Color(hex: "#F5F6F8") : Color(hex: "#C5C8CD"))
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                if item.url != nil {
                    Image(systemName: "video.fill")
                        .font(.system(size: 9))
                        .foregroundColor(hover ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
                }
                if first {
                    Text(whenLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(item.color.lighter(by: 0.2))
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Capsule().fill(item.color.opacity(live ? 0.28 : 0.16)))
                        .fixedSize()
                }
            }
            .padding(.trailing, 6)
            .frame(height: first ? 28 : 22)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hover ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.source)
    }

    /// "09:30" today, "Tomorrow 09:30" / "Fri 09:30" on another day's first row.
    private var timeLabel: String {
        let time = item.start.formatted(date: .omitted, time: .shortened)
        let cal = Calendar.current
        guard !cal.isDate(item.start, inSameDayAs: now), newDay || first else { return time }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(item.start, inSameDayAs: tomorrow) {
            return "\(String(localized: "hub.agenda.tomorrow")) \(time)"
        }
        return "\(item.start.formatted(.dateTime.weekday(.abbreviated))) \(time)"
    }

    /// "Now", "In 12 min", "In 2 h", "Tomorrow", "Thursday".
    private var whenLabel: String {
        let cal = Calendar.current
        if live { return String(localized: "hub.agenda.now") }
        if cal.isDate(item.start, inSameDayAs: now) {
            let minutes = Int(item.start.timeIntervalSince(now) / 60)
            if minutes < 60 { return String(format: String(localized: "hub.agenda.in-min %lld"), max(1, minutes)) }
            return String(format: String(localized: "hub.agenda.in-hours %lld"), minutes / 60)
        }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(item.start, inSameDayAs: tomorrow) {
            return String(localized: "hub.agenda.tomorrow")
        }
        return item.start.formatted(.dateTime.weekday(.wide))
    }
}

/// A free day, or another short message, in place of the events.
private struct CalendarMessageTile: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "#34D399"))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#C5C8CD"))
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}
#endif
