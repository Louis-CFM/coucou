import SwiftUI

/// History: everything that happened, every source together (your OKs, the agents' turns,
/// payments, deploys, runs, bookings, emails…), by day, newest first. Filters by theme on top,
/// by source in the menu. A line opens where it comes from.
struct HistoryView: View {
    let link: PhoneLink
    @State private var theme: JournalEntry.Theme?
    @State private var source: String?

    private var journal: Journal { Journal.shared }

    private var filtered: [JournalEntry] {
        journal.entries.filter { entry in
            (theme.map { entry.themes.contains($0) } ?? true) && (source == nil || Self.sourceKey(entry) == source)
        }
    }

    /// The sources present in the journal, agents first, then the services in their usual order.
    private var sources: [String] {
        let present = Set(journal.entries.map(Self.sourceKey))
        return (["agents"] + PillCatalog.phoneServices).filter(present.contains)
    }

    private var days: [(day: Date, entries: [JournalEntry])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { (day: $0, entries: grouped[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip("All", selected: theme == nil) { theme = nil }
                        ForEach(JournalEntry.Theme.allCases, id: \.self) { t in
                            chip(t.title, selected: theme == t) { theme = theme == t ? nil : t }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollClipDisabled()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if filtered.isEmpty {
                ContentUnavailableView(journal.entries.isEmpty ? "Nothing yet" : "Nothing here",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text(journal.entries.isEmpty
                                                         ? "What your agents and services do shows up here, kept on this iPhone for 90 days."
                                                         : "Nothing matches this filter."))
                    .listRowBackground(Color.clear)
            }
            ForEach(days, id: \.day) { day in
                Section(Self.dayTitle(day.day)) {
                    ForEach(day.entries) { entry in
                        Button { link.openPillId = entry.pillId } label: { row(entry) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.1), value: theme)
        .animation(.spring(duration: 0.35, bounce: 0.1), value: source)
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Source", selection: $source) {
                        Text("Everything").tag(String?.none)
                        ForEach(sources, id: \.self) { key in
                            Text(Self.sourceName(key)).tag(Optional(key))
                        }
                    }
                } label: {
                    Image(systemName: source == nil
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.botan : Color.white.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: JournalEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color(hex: PillCatalog.definition(for: entry.pillId)?.color ?? "#C0C4CC"))
                .frame(width: 9, height: 9)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if entry.kind == .decision {
                        Image(systemName: entry.tone == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(entry.tone == .ok ? .green : .red)
                    }
                    Text(entry.title)
                        .font(entry.kind == .decision ? .callout.weight(.semibold) : .callout.weight(.medium))
                        .lineLimit(2)
                    if entry.tone == .error && entry.kind != .decision {
                        Text("Failed").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(entry.kind == .decision ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(Self.sourceName(Self.sourceKey(entry), pillId: entry.pillId))
                    Spacer(minLength: 0)
                    Text(entry.date, format: .dateTime.hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Agents together ("agents"), each service on its own.
    static func sourceKey(_ entry: JournalEntry) -> String {
        PillCatalog.isSession(entry.pillId) ? "agents" : entry.pillId
    }

    static func sourceName(_ key: String, pillId: String? = nil) -> String {
        if key == "agents" { return pillId.flatMap { PillCatalog.definition(for: $0)?.name } ?? "Agents" }
        return PillCatalog.definition(for: key)?.name ?? key
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
