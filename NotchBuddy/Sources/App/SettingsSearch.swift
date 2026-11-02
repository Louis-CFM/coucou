import SwiftUI

#if !APPSTORE

// Search in the Coucou window: every setting of Flow, the notch and Mail, by its words in
// the app's language. A result opens its page, scrolls to its box and makes it glow.
//
// The index lists each box (a GroupBox of Settings, a card of a Flow or Mail page) with the
// labels inside it, by their catalog keys: what is searched is exactly what is shown. A box
// is found by its anchor (`.settingsAnchor("…")` on the view).

struct SettingsSearchEntry: Identifiable, Sendable {
    /// The box's anchor, unique.
    let id: String
    let page: HubPage
    /// The box's title (a catalog key, or a name that is never translated).
    let title: String
    /// The labels inside the box (catalog keys).
    let terms: [String]
}

/// A result: the box, and the label that matched when it isn't the title.
struct SettingsSearchHit: Identifiable {
    let entry: SettingsSearchEntry
    let label: String?
    var id: String { entry.id + "|" + (label ?? "") }
}

@MainActor
final class SettingsSearch: ObservableObject {
    static let shared = SettingsSearch()

    @Published var query = ""
    /// The box to show, and a fresh token each time it is asked (the same box twice glows twice).
    @Published private(set) var target: String?
    @Published private(set) var token = UUID()
    /// The last box opened from the results (its row stays selected).
    @Published private(set) var shown: String?

    /// The words of the app's language for a key (names stay as they are).
    nonisolated static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    func results() -> [SettingsSearchHit] {
        let words = SettingsSearchMatch.words(query)
        guard !words.isEmpty else { return [] }
        // The boxes named by the words first, then the settings inside the others.
        var boxes: [SettingsSearchHit] = []
        var labels: [SettingsSearchHit] = []
        for entry in Self.entries {
            switch SettingsSearchMatch.match(words, title: Self.text(entry.title), page: entry.page.title,
                                             labels: entry.terms.map(Self.text)) {
            case .box?: boxes.append(SettingsSearchHit(entry: entry, label: nil))
            case .label(let label)?: labels.append(SettingsSearchHit(entry: entry, label: label))
            case nil: break
            }
        }
        return Array((boxes + labels).prefix(30))
    }

    /// Opens the box's page; the page scrolls to the box and makes it glow.
    func reveal(_ entry: SettingsSearchEntry) {
        FlowHubController.shared.router.page = entry.page
        target = entry.id
        shown = entry.id
        let mine = UUID()
        token = mine
        // Once shown, the box is no longer asked for: coming back to its page later doesn't
        // scroll or glow again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.token == mine else { return }
            self.target = nil
        }
    }

    // MARK: - The index

    static let entries: [SettingsSearchEntry] = {
        func e(_ id: String, _ page: HubPage, _ title: String, _ terms: [String] = []) -> SettingsSearchEntry {
            SettingsSearchEntry(id: id, page: page, title: title, terms: terms)
        }
        var list = [
            // Flow
            e("flow.history", .dictation, "hub.history", ["hub.page.dictation"]),
            e("flow.notes", .notes, "hub.page.notes", ["notes.live", "notes.key-points"]),
            e("flow.insights", .insights, "hub.page.insights"),
            e("flow.dictionary", .dictionary, "hub.page.dictionary", ["hub.replacements"]),
            e("flow.snippets", .snippets, "hub.page.snippets"),
            e("flow.styles", .styles, "hub.page.styles", ["hub.cleanup", "hub.style-default", "hub.style-apps"]),
            e("flow.keys", .settings, "hub.settings.keys",
              ["flow.enable", "hub.settings.hold", "flow.edge", "hub.settings.handsfree", "hub.settings.paste-again", "hub.settings.cancel"]),
            e("flow.ai", .settings, "flow.ai.title", ["flow.prompt-mode", "flow.translate"]),
            e("flow.permission", .settings, "hub.settings.permission", ["flow.accessibility-open"]),
            e("flow.recognition", .settings, "hub.settings.recognition", ["Dictation language"]),
            e("flow.summary", .settings, "hub.page.notes", ["notes.engine"]),
            e("flow.app", .settings, "hub.settings.app", ["hub.settings.dock", "hub.settings.open-at-launch"]),
            e("flow.privacy", .settings, "hub.settings.privacy", ["hub.settings.keep"]),
            // Notch → General
            e("general.demo", .general, "demo.groupbox.title"),
            e("general.sound", .general, "Sound", ["Enable sounds", "Volume", "Open sounds folder", "Reload sounds"]),
            e("general.behavior", .general, "Behavior", ["Open on hover", "Close after", "Hide after", "alerts.all-pills"]),
            e("general.display", .general, "Display", ["Show Mochi on", "Screen with the notch", "Main screen (menu bar)", "Follow the mouse",
                                                     "island.position", "island.position.top-left", "island.position.top-right",
                                                     "island.position.bottom-left", "island.position.bottom-right"]),
            e("general.vitals", .general, "vitals.title", ["vitals.toggle"]),
            e("general.hotkey", .general, "Hotkey", ["Show island with shortcut", "Shortcut"]),
            e("general.startup", .general, "Startup", ["Launch at Mac startup"]),
            e("general.update", .general, "update.settings.title"),
            e("general.recap", .general, "Weekly recap",
              ["Keep a history of my coding sessions", "Hide project names in shared images", "Clear history"]),
            e("general.language", .general, "Language", ["Restart Coucou"]),
            e("general.iphone", .general, "iPhone", ["iphone.sync.toggle", "iphone.live-activity.toggle", "iphone.instruction.toggle"]),
            // Notch → Active pills, Agents, Chat, Integrations
            e("pills.main", .pills, "settings.main-pill", ["Active pills"]),
            e("agents.claude", .agents, "hooks.claude-code.title",
              ["Answer questions and permissions from terminal sessions in the notch"]),
            e("agents.claude-desktop", .agents, "claude-desktop.chat.title"),
            e("agents.gemini", .agents, "hooks.gemini.title"),
            e("agents.antigravity", .agents, "hooks.antigravity.title"),
            e("agents.codex", .agents, "hooks.codex.title"),
            e("agents.copilot", .agents, "hooks.copilot.title"),
            e("agents.muse", .agents, "hooks.muse.title"),
            e("agents.opencode", .agents, "plugin.opencode.title"),
            e("agents.amp", .agents, "plugin.amp.title"),
            e("agents.hermes", .agents, "plugin.hermes.title", ["plugin.hermes.approvals"]),
            e("agents.plan", .agents, "plan.title", ["plan.show-in-notch", "Show Codex plan in the notch"]),
            e("chat.subscriptions", .chat, "chat.subscriptions.title", ["chat.subscriptions.use"]),
            e("chat.anthropic", .chat, "chat.anthropic-api.title", ["chat.model", "Anthropic", "Claude"]),
            e("chat.others", .chat, "chat.other-providers.title", ["Google AI", "OpenAI", "DeepSeek", "Gemini"]),
            e("chat.local", .chat, "chat.local.title", ["Ollama", "LM Studio"]),
            e("integrations.all", .integrations, "Integrations",
              ["Stripe", "GitHub", "Vercel", "n8n", "Notion", "Resend", "Cal.com", "WhatsApp", "Spotify", "Crypto",
               "crypto.exchange", "crypto.currency"]),
            // Notch → Voice, Shortcuts
            e("voice.wake", .voice, "«\u{202F}OK Coucou\u{202F}» — voice wake word", ["Enable voice command", "Request permissions"]),
            e("voice.language", .voice, "Language", ["voice.listen-language", "voice.language"]),
            e("voice.tts", .voice, "voice.tts-engine", ["voice.tts-gender", "voice.tts-test"]),
            e("voice.history", .voice, "voice.history-title"),
            e("shortcuts.global", .shortcuts, "shortcut.group.global"),
            e("shortcuts.island", .shortcuts, "shortcut.group.island"),
            // Mail
            e("mail.autosort", .mailOverview, "hub.mail.autosort", ["hub.mail.journal", "hub.mail.sent", "hub.mail.undo"]),
            e("mail.rules", .mailRules, "hub.mail.rules", ["hub.mail.field.sender", "hub.mail.field.subject", "hub.mail.do.junk"]),
            e("mail.banned", .mailBanned, "hub.mail.banned"),
            e("mail.vip", .mailVIP, "hub.mail.vip"),
        ]
        #if !PHONE_LINK
        list.removeAll { $0.id == "general.iphone" }
        #endif
        return list
    }()
}

// MARK: - Anchors

private struct SettingsAnchor: ViewModifier {
    let anchor: String
    let cornerRadius: CGFloat
    @ObservedObject private var search = SettingsSearch.shared
    @State private var glow = false

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(HubTheme.accent, lineWidth: 2)
                    .shadow(color: HubTheme.accent.opacity(0.6), radius: 8)
                    .opacity(glow ? 1 : 0)
                    .allowsHitTesting(false)
            )
            .onChange(of: search.token) { _, _ in flashIfMine() }
            .onAppear { flashIfMine() }
    }

    private func flashIfMine() {
        guard search.target == anchor else { return }
        withAnimation(.easeOut(duration: 0.25).delay(0.25)) { glow = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            withAnimation(.easeIn(duration: 0.6)) { glow = false }
        }
    }
}

/// Scrolls a page's ScrollView to the box the search asked for.
private struct SettingsSearchScroller: ViewModifier {
    let proxy: ScrollViewProxy
    @ObservedObject private var search = SettingsSearch.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: search.token) { _, _ in scroll() }
            .onAppear { scroll() }
    }

    private func scroll() {
        guard let target = search.target else { return }
        // After the page is laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(target, anchor: .top)
                // A card with its title above it: the title too (a no-op where there is none).
                proxy.scrollTo(target + "#label", anchor: .top)
            }
        }
    }
}

// MARK: - The sidebar's field and results

struct HubSearchField: View {
    @ObservedObject private var search = SettingsSearch.shared
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(HubTheme.muted)
            TextField(String(localized: "hub.search.placeholder"), text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onExitCommand { search.query = "" }
                // Return opens the first result.
                .onSubmit { if let first = search.results().first { search.reveal(first.entry) } }
            if !search.query.isEmpty {
                Button { search.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(HubTheme.muted)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Close"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9).fill(HubTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(focused ? HubTheme.accent.opacity(0.6) : Color.white.opacity(0.07)))
    }
}

/// What the search found, in place of the pages while something is typed.
struct HubSearchResults: View {
    @ObservedObject private var search = SettingsSearch.shared
    @ObservedObject var router: HubRouter

    var body: some View {
        let hits = search.results()
        VStack(alignment: .leading, spacing: 2) {
            if hits.isEmpty {
                Text("hub.search.none")
                    .font(.system(size: 12.5))
                    .foregroundColor(HubTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ForEach(hits) { hit in
                HubSearchRow(hit: hit, selected: search.shown == hit.entry.id && router.page == hit.entry.page) {
                    search.reveal(hit.entry)
                }
            }
        }
    }
}

private struct HubSearchRow: View {
    let hit: SettingsSearchHit
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: hit.entry.page.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.label ?? SettingsSearch.text(hit.entry.title))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(HubTheme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(hit.label == nil
                         ? hit.entry.page.title
                         : hit.entry.page.title + " › " + SettingsSearch.text(hit.entry.title))
                        .font(.system(size: 11))
                        .foregroundColor(HubTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(Color(hex: "#B7BBC2"))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(selected ? 0.08 : (hover ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
#endif

// The App Store build has no Coucou window: its boxes are never searched.
extension View {
    /// A box the search of the Coucou window can find (SettingsSearch.entries).
    func settingsAnchor(_ id: String, cornerRadius: CGFloat = 8) -> some View {
        #if APPSTORE
        self
        #else
        modifier(SettingsAnchor(anchor: id, cornerRadius: cornerRadius))
        #endif
    }

    /// The small title above a box anchored `id`: the search scrolls to it, so it stays in view.
    func settingsHeading(_ id: String) -> some View {
        self.id(id + "#label")
    }

    /// Scrolls to the box the search asked for (inside a ScrollViewReader).
    func settingsSearchScroll(_ proxy: ScrollViewProxy) -> some View {
        #if APPSTORE
        self
        #else
        modifier(SettingsSearchScroller(proxy: proxy))
        #endif
    }
}
