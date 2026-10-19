#if !APPSTORE
import AppKit
import SwiftUI

/// Coucou Flow → Dictionary: the words Coucou must always spell right, and the replacements.
struct HubDictionaryPage: View {
    @ObservedObject private var store = FlowStore.shared
    @State private var newWord = ""
    @State private var from = ""
    @State private var to = ""

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.dictionary"),
                        subtitle: String(localized: "hub.dictionary-sub")) {
            HubCard {
                HStack(spacing: 8) {
                    HubField(placeholder: String(localized: "hub.word-placeholder"), text: $newWord, onSubmit: addWord)
                    Button(String(localized: "hub.add"), action: addWord)
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if store.words.isEmpty {
                    HubEmptyState(text: String(localized: "hub.words-empty"), state: .idle, color: "#A78BFA")
                } else {
                    HubWrap(spacing: 8) {
                        ForEach(store.words, id: \.self) { word in
                            HubChip(text: word) { store.words.removeAll { $0 == word } }
                        }
                    }
                }
            }

            HubLabel(String(localized: "hub.replacements"))
            HubCard {
                Text("hub.replacements-sub")
                    .font(.system(size: 13))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    HubField(placeholder: String(localized: "hub.heard-placeholder"), text: $from, onSubmit: addReplacement)
                    Image(systemName: "arrow.right")
                        .foregroundColor(HubTheme.muted)
                    HubField(placeholder: String(localized: "hub.written-placeholder"), text: $to, onSubmit: addReplacement)
                    Button(String(localized: "hub.add"), action: addReplacement)
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(from.trimmingCharacters(in: .whitespaces).isEmpty || to.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(store.replacements) { replacement in
                    HubDivider()
                    HStack(spacing: 12) {
                        Text(replacement.from)
                            .font(.system(size: 13))
                            .foregroundColor(HubTheme.secondary)
                            .frame(width: 200, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11))
                            .foregroundColor(HubTheme.muted)
                        Text(replacement.to)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        HubIconButton(symbol: "trash", help: String(localized: "hub.delete")) {
                            store.replacements.removeAll { $0.id == replacement.id }
                        }
                    }
                }
            }
        }
    }

    private func addWord() {
        store.addWord(newWord)
        newWord = ""
    }

    private func addReplacement() {
        store.addReplacement(from: from, to: to)
        from = ""
        to = ""
    }
}

/// A word of the dictionary, with its × to remove it.
private struct HubChip: View {
    let text: String
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.system(size: 13))
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(hover ? HubTheme.text : HubTheme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "hub.delete"))
        }
        .padding(.leading, 11)
        .padding(.trailing, 9)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(HubTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
        .onHover { hover = $0 }
    }
}

// MARK: - Snippets

/// Coucou Flow → Snippets: say the trigger, Coucou pastes the whole text.
struct HubSnippetsPage: View {
    @ObservedObject private var store = FlowStore.shared
    @State private var trigger = ""
    @State private var text = ""
    @State private var editing: UUID?

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.snippets"),
                        subtitle: String(localized: "hub.snippets-sub")) {
            HubCard {
                Text(editing == nil ? String(localized: "hub.snippet-new") : String(localized: "hub.snippet-edit"))
                    .font(.system(size: 14, weight: .bold))
                HubField(placeholder: String(localized: "hub.trigger-placeholder"), text: $trigger)
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 90)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(HubTheme.field))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("hub.snippet-text-placeholder")
                                .font(.system(size: 13))
                                .foregroundColor(HubTheme.muted)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 8) {
                    Button(editing == nil ? String(localized: "hub.add") : String(localized: "hub.save"), action: save)
                        .buttonStyle(HubButtonStyle(primary: true))
                        .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editing != nil {
                        Button(String(localized: "hub.cancel")) { reset() }
                            .buttonStyle(HubButtonStyle())
                    }
                }
            }
            if store.snippets.isEmpty {
                HubEmptyState(text: String(localized: "hub.snippets-empty"), color: "#F7B32B")
            }
            ForEach(store.snippets) { snippet in
                HubCard {
                    HStack(spacing: 8) {
                        Text("hub.you-say")
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.secondary)
                        Text("« \(snippet.trigger) »")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "#FDBA74"))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 6).fill(HubTheme.accent.opacity(0.14)))
                        Spacer()
                        HubIconButton(symbol: "pencil", help: String(localized: "hub.edit")) {
                            editing = snippet.id
                            trigger = snippet.trigger
                            text = snippet.text
                        }
                        HubIconButton(symbol: "trash", help: String(localized: "hub.delete")) {
                            store.snippets.removeAll { $0.id == snippet.id }
                            if editing == snippet.id { reset() }
                        }
                    }
                    Text(snippet.text)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .foregroundColor(Color(hex: "#D5D7DB"))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func save() {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !body.isEmpty else { return }
        if let editing, let index = store.snippets.firstIndex(where: { $0.id == editing }) {
            store.snippets[index].trigger = t
            store.snippets[index].text = body
        } else {
            store.snippets.append(FlowSnippet(trigger: t, text: body))
        }
        reset()
    }

    private func reset() {
        editing = nil
        trigger = ""
        text = ""
    }
}

// MARK: - Styles

/// Coucou Flow → Styles: Claude's clean-up, and how the words are written in each app.
struct HubStylesPage: View {
    @ObservedObject var router: HubRouter
    @ObservedObject private var store = FlowStore.shared

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.styles"),
                        subtitle: String(localized: "hub.styles-sub")) {
            HubCard {
                HubRow(title: String(localized: "hub.cleanup"), detail: String(localized: "hub.cleanup-detail")) {
                    Toggle("", isOn: $store.cleanupEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!FlowCleanup.hasKey && !store.cleanupEnabled)
                }
                if !FlowCleanup.hasKey {
                    HStack(spacing: 10) {
                        Image(systemName: "key")
                            .foregroundColor(HubTheme.accent)
                        Text("hub.cleanup-key")
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "#C7CAD0"))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(String(localized: "hub.open-settings")) {
                            NotificationCenter.default.post(name: .openFullSettings, object: "chat")
                        }
                        .buttonStyle(HubButtonStyle())
                    }
                }
                HubDivider()
                HubRow(title: String(localized: "hub.style-default"), detail: store.defaultStyle.detail) {
                    stylePicker($store.defaultStyle)
                }
            }
            .opacity(1)

            HStack {
                HubLabel(String(localized: "hub.style-apps"))
                Spacer()
                Menu {
                    ForEach(addableApps, id: \.bundleID) { app in
                        Button(app.name) {
                            store.appStyles.append(FlowAppStyle(bundleID: app.bundleID, name: app.name, style: store.defaultStyle))
                        }
                    }
                    if addableApps.isEmpty { Text("hub.style-no-app") }
                } label: {
                    Label(String(localized: "hub.style-add"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            HubCard {
                ForEach(Array(store.appStyles.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { HubDivider() }
                    HStack(spacing: 12) {
                        HubAppIcon(bundleID: app.bundleID)
                        Text(app.name).font(.system(size: 13.5, weight: .medium))
                        Spacer()
                        stylePicker(Binding(
                            get: { store.appStyles.first(where: { $0.id == app.id })?.style ?? .natural },
                            set: { value in
                                if let i = store.appStyles.firstIndex(where: { $0.id == app.id }) { store.appStyles[i].style = value }
                            }))
                        HubIconButton(symbol: "xmark", help: String(localized: "hub.delete")) {
                            store.appStyles.removeAll { $0.id == app.id }
                        }
                    }
                }
            }
            .opacity(store.cleanupEnabled ? 1 : 0.55)

            HubCard {
                ForEach(FlowStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.label).font(.system(size: 13, weight: .semibold))
                        Text(style.detail)
                            .font(.system(size: 12.5))
                            .foregroundColor(HubTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("hub.cleanup-privacy")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stylePicker(_ selection: Binding<FlowStyle>) -> some View {
        Picker("", selection: selection) {
            ForEach(FlowStyle.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// Running apps with windows that have no style of their own yet.
    private var addableApps: [(bundleID: String, name: String)] {
        let taken = Set(store.appStyles.map(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (bundleID: String, name: String)? in
                guard let id = app.bundleIdentifier, let name = app.localizedName,
                      id != Bundle.main.bundleIdentifier, !taken.contains(id), seen.insert(id).inserted else { return nil }
                return (id, name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// The icon of an app, from its bundle identifier.
struct HubAppIcon: View {
    let bundleID: String

    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
            }
        }
        .frame(width: 22, height: 22)
    }
}

#endif
