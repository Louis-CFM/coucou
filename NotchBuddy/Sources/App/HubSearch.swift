#if !APPSTORE
import SwiftUI

// The search box at the top of the Coucou window's sidebar: what you type finds a page or a
// setting, in the language you read it in or in English, and picking one opens its page, scrolls
// to the setting and lights it for a moment (HubFind.swift). The matching is in HubSearchCore.swift.
//
// The settings are listed here by hand: the key of the label as the page draws it, and the id
// the page marks that setting with (`.hubFindable("…")`, in SettingsView, ShortcutsSettingsView and
// the Flow pages). A setting whose group is not on the page when it opens still opens its page,
// just without the light.

extension HubPage {
    /// The key of the page's name in the catalog, as `title` draws it.
    fileprivate var titleKey: String {
        switch self {
        case .general:      return "General"
        case .pills:        return "Active pills"
        case .agents:       return "Agents"
        case .chat:         return "Chat"
        case .integrations: return "Integrations"
        case .voice:        return "Voice"
        case .shortcuts:    return "Shortcuts"
        case .dictation:    return "hub.page.dictation"
        case .notes:        return "hub.page.notes"
        case .insights:     return "hub.page.insights"
        case .dictionary:   return "hub.page.dictionary"
        case .snippets:     return "hub.page.snippets"
        case .styles:       return "hub.page.styles"
        case .settings:     return "hub.page.settings"
        }
    }

    /// Where it is: "Flow" or "Notch".
    fileprivate var groupName: String {
        HubPage.flowPages.contains(self) ? "Flow" : String(localized: "hub.section.notch")
    }
}

enum HubSearchIndex {
    private struct Entry {
        let page: HubPage
        /// The key of the label, in the string catalog.
        let key: String
        /// The id the page marks the setting with.
        let find: String
    }

    private static let settings: [Entry] = {
        var list: [Entry] = [
            // Flow
            Entry(page: .settings, key: "flow.enable", find: "flow.enable"),
            Entry(page: .settings, key: "hub.settings.hold", find: "hub.settings.hold"),
            Entry(page: .settings, key: "flow.edge", find: "flow.edge"),
            Entry(page: .settings, key: "hub.settings.handsfree", find: "hub.settings.handsfree"),
            Entry(page: .settings, key: "hub.settings.paste-again", find: "hub.settings.paste-again"),
            Entry(page: .settings, key: "hub.settings.cancel", find: "hub.settings.cancel"),
            Entry(page: .settings, key: "flow.prompt-mode", find: "flow.prompt-mode"),
            Entry(page: .settings, key: "flow.translate", find: "flow.translate"),
            Entry(page: .settings, key: "Dictation language", find: "dictation-language"),
            Entry(page: .settings, key: "hub.settings.dock", find: "hub.settings.dock"),
            Entry(page: .settings, key: "hub.settings.open-at-launch", find: "hub.settings.open-at-launch"),
            Entry(page: .settings, key: "hub.settings.keep", find: "hub.settings.keep"),
            Entry(page: .styles, key: "hub.cleanup", find: "hub.cleanup"),
            Entry(page: .styles, key: "hub.style-default", find: "hub.style-default"),
            // Notch
            Entry(page: .general, key: "Sound", find: "Sound"),
            Entry(page: .general, key: "Enable sounds", find: "Sound"),
            Entry(page: .general, key: "Behavior", find: "Behavior"),
            Entry(page: .general, key: "Open on hover", find: "Behavior"),
            Entry(page: .general, key: "alerts.all-pills", find: "Behavior"),
            Entry(page: .general, key: "Display", find: "Display"),
            Entry(page: .general, key: "Show Mochi on", find: "Display"),
            Entry(page: .general, key: "vitals.title", find: "vitals"),
            Entry(page: .general, key: "vitals.toggle", find: "vitals"),
            Entry(page: .general, key: "Hotkey", find: "Hotkey"),
            Entry(page: .general, key: "Show island with shortcut", find: "Hotkey"),
            Entry(page: .general, key: "Startup", find: "Startup"),
            Entry(page: .general, key: "Launch at Mac startup", find: "Startup"),
            Entry(page: .general, key: "Weekly recap", find: "recap"),
            Entry(page: .general, key: "Keep a history of my coding sessions", find: "recap"),
            Entry(page: .general, key: "Hide project names in shared images", find: "recap"),
            Entry(page: .general, key: "Language", find: "Language"),
            Entry(page: .agents, key: "hooks.claude-code.title", find: "hooks.claude-code"),
            Entry(page: .agents, key: "hooks.gemini.title", find: "hooks.gemini"),
            Entry(page: .agents, key: "hooks.antigravity.title", find: "hooks.antigravity"),
            Entry(page: .agents, key: "hooks.codex.title", find: "hooks.codex"),
            Entry(page: .agents, key: "hooks.copilot.title", find: "hooks.copilot"),
            Entry(page: .agents, key: "hooks.muse.title", find: "hooks.muse"),
            Entry(page: .agents, key: "plugin.opencode.title", find: "plugin.opencode"),
            Entry(page: .agents, key: "plugin.amp.title", find: "plugin.amp"),
            Entry(page: .agents, key: "plugin.hermes.title", find: "plugin.hermes"),
            Entry(page: .agents, key: "plan.title", find: "plan"),
            Entry(page: .agents, key: "plan.show-in-notch", find: "plan"),
            Entry(page: .agents, key: "Show Codex plan in the notch", find: "plan"),
            Entry(page: .chat, key: "chat.anthropic-api.title", find: "chat.anthropic"),
            Entry(page: .chat, key: "chat.model", find: "chat.anthropic"),
            Entry(page: .chat, key: "chat.other-providers.title", find: "chat.providers"),
            Entry(page: .chat, key: "chat.local.title", find: "chat.local"),
            Entry(page: .voice, key: "Enable voice command", find: "voice.wake"),
            Entry(page: .voice, key: "voice.listen-language", find: "voice.language"),
            Entry(page: .voice, key: "voice.language", find: "voice.language"),
            Entry(page: .voice, key: "voice.tts-engine", find: "voice.tts"),
            Entry(page: .voice, key: "voice.tts-gender", find: "voice.tts"),
            Entry(page: .voice, key: "voice.history-title", find: "voice.history"),
            Entry(page: .shortcuts, key: "shortcut.group.global", find: "shortcut.group.global"),
            Entry(page: .shortcuts, key: "shortcut.group.island", find: "shortcut.group.island"),
        ]
        #if PHONE_LINK
        list += [
            Entry(page: .general, key: "iPhone", find: "iPhone"),
            Entry(page: .general, key: "iphone.sync.toggle", find: "iPhone"),
            Entry(page: .general, key: "iphone.live-activity.toggle", find: "iPhone"),
            Entry(page: .general, key: "iphone.instruction.toggle", find: "iPhone"),
        ]
        #endif
        return list
    }()

    /// The catalog's English, to look in whatever the language is.
    private static let english: Bundle = {
        Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }()

    private static func text(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// Every page, then every setting, with its name now and in English.
    static func candidates() -> [HubSearchCandidate<HubPage>] {
        var list: [HubSearchCandidate<HubPage>] = []
        for page in HubPage.flowPages + HubPage.notchPages {
            let now = text(page.titleKey, in: .main)
            list.append(HubSearchCandidate(page: page, names: [now, text(page.titleKey, in: english)],
                                           text: now, place: page.groupName, find: nil))
        }
        for entry in settings {
            let now = text(entry.key, in: .main)
            list.append(HubSearchCandidate(page: entry.page, names: [now, text(entry.key, in: english)],
                                           text: now, place: "\(entry.page.groupName) · \(entry.page.title)", find: entry.find))
        }
        return list
    }
}

/// The matches for what is typed, the best first.
@MainActor private func hubHits(_ query: String) -> [HubSearchHit<HubPage>] {
    HubSearchCore.search(query, in: HubSearchIndex.candidates())
}

/// Picks a result: the page opens, and the setting is lit.
@MainActor private func hubOpen(_ hit: HubSearchHit<HubPage>, router: HubRouter, query: Binding<String>) {
    query.wrappedValue = ""
    router.open(hit.page, find: hit.find)
}

/// The search box at the top of the sidebar. Up and down move through the results, Return opens
/// the one lit, Escape clears.
struct HubSidebarSearch: View {
    @ObservedObject var router: HubRouter
    @Binding var query: String
    @Binding var active: Int
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(HubTheme.muted)
            TextField(String(localized: "Search settings"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    let list = hubHits(query)
                    if list.indices.contains(active) { hubOpen(list[active], router: router, query: $query) }
                }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "hub.cancel"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? HubTheme.accent.opacity(0.6) : HubTheme.line))
        .onChange(of: query) { _, _ in active = 0 }
    }

    private func move(_ step: Int) {
        let count = hubHits(query).count
        guard count > 0 else { return }
        active = (active + step + count) % count
    }
}

/// The results, which take the place of the pages in the sidebar while something is typed.
struct HubSidebarResults: View {
    @ObservedObject var router: HubRouter
    @Binding var query: String
    @Binding var active: Int

    var body: some View {
        let list = hubHits(query)
        VStack(alignment: .leading, spacing: 2) {
            if list.isEmpty {
                Text(String(localized: "No results"))
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, hit in
                HubSearchRow(hit: hit, selected: index == active) {
                    hubOpen(hit, router: router, query: $query)
                }
                .onHover { if $0 { active = index } }
            }
        }
    }
}

private struct HubSearchRow: View {
    let hit: HubSearchHit<HubPage>
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.text)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? HubTheme.text : Color(hex: "#B7BBC2"))
                    .lineLimit(1)
                Text(hit.place)
                    .font(.system(size: 11))
                    .foregroundColor(HubTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(selected ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
