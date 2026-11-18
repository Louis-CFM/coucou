#if !APPSTORE
import AppKit
import SwiftUI

/// Coucou Flow → Dictation: hello, today's dictations and the numbers.
struct HubHomePage: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var flow = FlowDictation.shared
    @State private var query = ""

    private var greeting: String {
        if let name = resolveUserFirstName() { return String(format: String(localized: "hub.hello %@"), name) }
        return String(localized: "hub.hello")
    }

    var body: some View {
        HubPageScaffold(title: greeting,
                        subtitle: String(format: String(localized: "hub.hint %@"), flow.key.label)) {
            Button {
                router.page = .notes
                if Parakeet.shared.isReady, !NoteTaker.shared.isRecording { Task { await NoteTaker.shared.start() } }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(HubTheme.onAccent).frame(width: 9, height: 9)
                    Text("hub.record-call")
                }
            }
            .buttonStyle(HubButtonStyle(primary: true))
        } content: {
            if !flow.isEnabled || !flow.trusted {
                HubSetupCard()
            }
            HStack(alignment: .top, spacing: 20) {
                history
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(spacing: 14) {
                    HubTotalsCard()
                    HubNotesPromo(router: router)
                }
                .frame(width: 270)
            }
        }
    }

    // MARK: History

    private var filtered: [FlowEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = q.isEmpty ? store.history : store.history.filter { $0.text.localizedCaseInsensitiveContains(q) }
        return Array(all.prefix(400))
    }

    /// The entries by day, newest day first, keeping their order.
    private var groups: [HubDayGroup] {
        var out: [HubDayGroup] = []
        for entry in filtered {
            let key = FlowText.dayKey(entry.date)
            if let last = out.indices.last, out[last].id == key {
                out[last].entries.append(entry)
            } else {
                out.append(HubDayGroup(id: key, date: entry.date, entries: [entry]))
            }
        }
        return out
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HubLabel(String(localized: "hub.history"))
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.muted)
                    TextField(String(localized: "hub.search"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .frame(width: 170)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(HubTheme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HubTheme.line))
            }
            if store.history.isEmpty {
                HubCard {
                    HubEmptyState(text: store.keepDays == 0 ? String(localized: "hub.history-off")
                                  : String(format: String(localized: "hub.history-empty %@"), flow.key.label))
                }
            } else if groups.isEmpty {
                Text("hub.search-empty")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Self.dayTitle(group.date))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(HubTheme.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                if index > 0 { HubDivider() }
                                HubEntryRow(entry: entry)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HubTheme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.line))
                    }
                }
            }
        }
    }

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "hub.today") }
        if calendar.isDateInYesterday(date) { return String(localized: "hub.yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct HubDayGroup: Identifiable {
    let id: String
    let date: Date
    var entries: [FlowEntry]
}

/// One dictation of the history.
private struct HubEntryRow: View {
    let entry: FlowEntry
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.muted)
                if let app = entry.app, !app.isEmpty {
                    Text(app)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#A4A9B1"))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                }
            }
            .frame(width: 70, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundColor(HubTheme.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                HubIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: String(localized: "hub.copy")) {
                    NSPasteboard.copyText(entry.text)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                }
                HubIconButton(symbol: "trash", help: String(localized: "hub.delete")) {
                    FlowStore.shared.delete(entry)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }
}

/// Total words, speed and days in a row.
private struct HubTotalsCard: View {
    @ObservedObject private var store = FlowStore.shared

    var body: some View {
        HubCard(padding: 20) {
            big(FlowText.shortCount(store.totalWords), String(localized: "hub.total-words"))
            big("\(store.wordsPerMinute)", String(localized: "hub.wpm"))
            big("\(store.streak)", String(localized: "hub.streak"))
            HubDivider()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("hub.unlimited")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(HubTheme.green)
        }
    }

    private func big(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.8)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(HubTheme.secondary)
        }
    }
}

private struct HubNotesPromo: View {
    @ObservedObject var router: HubRouter
    @StateObject private var light = HubHeroLight()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("hub.notes-promo-title")
                .font(.system(size: 15, weight: .bold))
            Text("hub.notes-promo")
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundColor(Color(hex: "#A4A9B1"))
                .fixedSize(horizontal: false, vertical: true)
            Button { router.page = .notes } label: {
                Text("hub.notes-promo-open")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(HubTheme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HubHeroBackdrop(color: HubTheme.accent, light: light, cornerRadius: 14).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.accent.opacity(0.2)))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): light.target = point
            case .ended:             light.target = nil
            }
        }
    }
}

/// Shown while the dictation is off, or cannot paste yet.
struct HubSetupCard: View {
    @ObservedObject private var flow = FlowDictation.shared
    @StateObject private var light = HubHeroLight()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: flow.isEnabled ? "lock.shield" : "mic.badge.plus")
                .font(.system(size: 20))
                .foregroundColor(HubTheme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 8) {
                Text(flow.isEnabled ? String(localized: "hub.setup-access-title") : String(localized: "hub.setup-title"))
                    .font(.system(size: 15, weight: .bold))
                Text(flow.isEnabled ? String(localized: "flow.accessibility")
                     : String(format: String(localized: "hub.setup %@"), flow.key.label))
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#C7CAD0"))
                    .fixedSize(horizontal: false, vertical: true)
                if flow.isEnabled {
                    Button(String(localized: "flow.accessibility-open")) { flow.openAccessibilitySettings() }
                        .buttonStyle(HubButtonStyle(primary: true))
                } else {
                    Button(String(localized: "hub.setup-enable")) { flow.isEnabled = true }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(HubHeroBackdrop(color: HubTheme.accent, light: light, cornerRadius: 14).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HubTheme.accent.opacity(0.2)))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): light.target = point
            case .ended:             light.target = nil
            }
        }
        .onAppear { flow.recheckTrust() }
    }
}
#endif
