#if !APPSTORE
import SwiftUI

// The Mail section of the Coucou window: the automatic sorting and its journal, the rules,
// the banned words and the VIPs. What they decide lives in MailTriage.swift.

private let mailBlue = "#2F8CFF"

// MARK: - Overview

struct HubMailOverviewPage: View {
    @ObservedObject private var store = MailTriageStore.shared
    @ObservedObject private var mail = MailController.shared

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.mail.overview"),
                        subtitle: String(localized: "hub.mail.overview-sub")) {
            HubCard {
                HubRow(title: String(localized: "hub.mail.autosort"),
                       detail: String(localized: "hub.mail.autosort-detail")) {
                    Toggle("", isOn: Binding(get: { store.settings.autoSort }, set: { store.setAutoSort($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                if store.settings.autoSort && !mail.isMailRunning {
                    HubDivider()
                    HStack(spacing: 10) {
                        Text("hub.mail.mail-closed")
                            .font(.system(size: 12.5))
                            .foregroundColor(HubTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(String(localized: "Open Mail")) { mail.openMail() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
                if mail.automationDenied {
                    HubDivider()
                    HStack(spacing: 10) {
                        Text("hub.mail.denied")
                            .font(.system(size: 12.5))
                            .foregroundColor(HubTheme.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(String(localized: "Open Settings…")) { mail.openAutomationSettings() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
                .settingsAnchor("mail.autosort", cornerRadius: 14)

            let today = store.today
            HStack(spacing: 12) {
                MailStat(value: today.sorted, label: String(localized: "hub.mail.stat.sorted"), color: mailBlue)
                MailStat(value: today.junk, label: String(localized: "hub.mail.stat.junk"), color: "#8E939C")
                MailStat(value: today.important, label: String(localized: "hub.mail.stat.important"), color: "#F5A524")
            }

            HubMailSentList()

            HStack {
                HubLabel(String(localized: "hub.mail.journal"))
                Spacer()
                if !store.journal.isEmpty {
                    Button(String(localized: "hub.mail.journal-clear")) { store.clearJournal() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.muted)
                }
            }
            HubCard {
                if store.journal.isEmpty {
                    // Sorting on and messages looked at: say so, it works, nothing matched yet.
                    HubEmptyState(text: store.settings.autoSort && store.checkedToday > 0
                                  ? String(format: String(localized: "hub.mail.checked %lld"), Int64(store.checkedToday))
                                  : String(localized: "hub.mail.journal-empty"),
                                  state: .idle, color: mailBlue)
                } else {
                    ForEach(Array(store.journal.prefix(100).enumerated()), id: \.element.id) { i, entry in
                        if i > 0 { HubDivider() }
                        MailJournalRow(entry: entry)
                    }
                }
            }
        }
    }
}

private struct MailStat: View {
    let value: Int
    let label: String
    let color: String

    var body: some View {
        HubCard {
            Text("\(value)")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Color(hex: color))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(HubTheme.secondary)
        }
    }
}

/// One line of the journal: what was done, to which message, why, and Undo.
private struct MailJournalRow: View {
    let entry: MailJournalEntry

    private var senderName: String {
        MailMessage(messageId: 0, account: "", mailbox: "", sender: entry.sender, subject: "",
                    date: entry.date, isRead: true).senderName
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: entry.action.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(hex: entry.action == .important ? "#F5A524" : mailBlue))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.subject)
                        .font(.system(size: 12.5))
                        .foregroundColor(HubTheme.secondary)
                        .lineLimit(1)
                }
                Text(entry.action.journalLine + " · " + entry.reason.line)
                    .font(.system(size: 11.5))
                    .foregroundColor(HubTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.system(size: 11.5))
                .foregroundColor(HubTheme.muted)
                .monospacedDigit()
            if entry.undone {
                Text("hub.mail.undone")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.muted)
                    .frame(width: 84)
            } else if !entry.rfcId.isEmpty {
                Button(String(localized: "hub.mail.undo")) { MailController.shared.undo(entry) }
                    .buttonStyle(HubButtonStyle())
                    .frame(width: 84)
            }
        }
    }
}

extension MailRuleAction {
    var symbol: String {
        switch self {
        case .junk: return "xmark.bin"
        case .important: return "flag.fill"
        case .markRead: return "envelope.open"
        case .move: return "tray.and.arrow.down"
        }
    }

    /// "Moved to Junk", in the journal.
    var journalLine: String {
        switch self {
        case .junk: return String(localized: "hub.mail.done.junk")
        case .important: return String(localized: "hub.mail.done.important")
        case .markRead: return String(localized: "hub.mail.done.read")
        case .move(let name): return String(format: String(localized: "hub.mail.done.move %@"), name)
        }
    }

    /// "Move to Junk", in a rule.
    var ruleLine: String {
        switch self {
        case .junk: return String(localized: "hub.mail.do.junk")
        case .important: return String(localized: "hub.mail.do.important")
        case .markRead: return String(localized: "hub.mail.do.read")
        case .move(let name): return String(format: String(localized: "hub.mail.do.move-to %@"), name)
        }
    }
}

extension MailReason {
    var line: String {
        switch self {
        case .vip(let v): return String(format: String(localized: "hub.mail.reason.vip %@"), v)
        case .banned(let w): return String(format: String(localized: "hub.mail.reason.banned %@"), w)
        case .rule(let r): return String(format: String(localized: "hub.mail.reason.rule %@"), r)
        case .manual: return String(localized: "hub.mail.reason.manual")
        }
    }
}

extension MailRuleField {
    var title: String {
        switch self {
        case .sender: return String(localized: "hub.mail.field.sender")
        case .domain: return String(localized: "hub.mail.field.domain")
        case .subject: return String(localized: "hub.mail.field.subject")
        case .text: return String(localized: "hub.mail.field.text")
        case .account: return String(localized: "hub.mail.field.account")
        }
    }
}

/// When the automatic sorting is off, the pages that feed it say so, with the switch.
private struct MailAutoSortHint: View {
    @ObservedObject private var store = MailTriageStore.shared

    var body: some View {
        if !store.settings.autoSort {
            HubCard {
                HubRow(title: String(localized: "hub.mail.autosort-off")) {
                    Button(String(localized: "hub.mail.turn-on")) { store.setAutoSort(true) }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }
        }
    }
}

// MARK: - Rules

struct HubMailRulesPage: View {
    @ObservedObject private var store = MailTriageStore.shared
    @State private var field: MailRuleField = .sender
    @State private var value = ""
    @State private var kind: Kind = .junk
    @State private var mailbox = ""

    private enum Kind: CaseIterable { case junk, important, read, move }

    private var action: MailRuleAction? {
        switch kind {
        case .junk: return .junk
        case .important: return .important
        case .read: return .markRead
        case .move:
            let m = mailbox.trimmingCharacters(in: .whitespaces)
            return m.isEmpty ? nil : .move(m)
        }
    }

    private var canAdd: Bool { !value.trimmingCharacters(in: .whitespaces).isEmpty && action != nil }

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.mail.rules"),
                        subtitle: String(localized: "hub.mail.rules-sub")) {
            MailAutoSortHint()
            HubCard {
                HStack(spacing: 8) {
                    Text("hub.mail.if")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, alignment: .leading)
                    Picker("", selection: $field) {
                        ForEach(MailRuleField.allCases, id: \.self) { f in Text(f.title).tag(f) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Text("hub.mail.contains")
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.secondary)
                    HubField(placeholder: String(localized: "hub.mail.value-placeholder"), text: $value, onSubmit: add)
                }
                HStack(spacing: 8) {
                    Text("hub.mail.then")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, alignment: .leading)
                    Picker("", selection: $kind) {
                        Text(MailRuleAction.junk.ruleLine).tag(Kind.junk)
                        Text(MailRuleAction.important.ruleLine).tag(Kind.important)
                        Text(MailRuleAction.markRead.ruleLine).tag(Kind.read)
                        Text("hub.mail.do.move").tag(Kind.move)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    if kind == .move {
                        HubField(placeholder: String(localized: "hub.mail.mailbox-placeholder"), text: $mailbox, onSubmit: add)
                    }
                    Spacer(minLength: 0)
                    Button(String(localized: "hub.add"), action: add)
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(!canAdd)
                }
            }

            HubCard {
                if store.settings.rules.isEmpty {
                    HubEmptyState(text: String(localized: "hub.mail.rules-empty"), state: .idle, color: "#34D399")
                } else {
                    ForEach(Array(store.settings.rules.enumerated()), id: \.element.id) { i, rule in
                        if i > 0 { HubDivider() }
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { on in
                                    if let k = store.settings.rules.firstIndex(where: { $0.id == rule.id }) {
                                        store.settings.rules[k].enabled = on
                                    }
                                }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .controlSize(.small)
                            Text(rule.name)
                                .font(.system(size: 13))
                                .foregroundColor(rule.enabled ? HubTheme.text : HubTheme.muted)
                            Spacer()
                            HubIconButton(symbol: "trash", help: String(localized: "hub.delete")) {
                                store.settings.rules.removeAll { $0.id == rule.id }
                            }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, let action else { return }
        let name = String(format: String(localized: "hub.mail.rule-name %@ %@ %@"), field.title, v, action.ruleLine)
        store.settings.rules.append(MailRule(name: name, conditions: [MailCondition(field: field, value: v)], action: action))
        value = ""
        mailbox = ""
    }
}

// MARK: - Banned words and VIPs

struct HubMailBannedPage: View {
    @ObservedObject private var store = MailTriageStore.shared
    @State private var word = ""

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.mail.banned"),
                        subtitle: String(localized: "hub.mail.banned-sub")) {
            MailAutoSortHint()
            HubCard {
                HStack(spacing: 8) {
                    HubField(placeholder: String(localized: "hub.mail.banned-placeholder"), text: $word, onSubmit: add)
                    Button(String(localized: "hub.add"), action: add)
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if store.settings.banned.isEmpty {
                    HubEmptyState(text: String(localized: "hub.mail.banned-empty"), state: .idle, color: "#FF453A")
                } else {
                    HubWrap(spacing: 8) {
                        ForEach(store.settings.banned, id: \.self) { w in
                            HubChip(text: w) { store.settings.banned.removeAll { $0 == w } }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        store.addBanned(word)
        word = ""
    }
}

struct HubMailVIPPage: View {
    @ObservedObject private var store = MailTriageStore.shared
    @State private var entry = ""

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.mail.vip"),
                        subtitle: String(localized: "hub.mail.vip-sub")) {
            MailAutoSortHint()
            HubCard {
                HStack(spacing: 8) {
                    HubField(placeholder: String(localized: "hub.mail.vip-placeholder"), text: $entry, onSubmit: add)
                    Button(String(localized: "hub.add"), action: add)
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(entry.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if store.settings.vip.isEmpty {
                    HubEmptyState(text: String(localized: "hub.mail.vip-empty"), state: .idle, color: "#F5A524")
                } else {
                    HubWrap(spacing: 8) {
                        ForEach(store.settings.vip, id: \.self) { v in
                            HubChip(text: v) { store.settings.vip.removeAll { $0 == v } }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        store.addVIP(entry)
        entry = ""
    }
}
#endif
