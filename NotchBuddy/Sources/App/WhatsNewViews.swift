#if !APPSTORE
import AppKit
import SwiftUI

// MARK: - When: once, after Coucou updated itself

@MainActor
final class WhatsNewCenter: ObservableObject {
    static let shared = WhatsNewCenter()

    /// The version's entry, from Resources/whats-new.json; nil once seen (or none for this version).
    @Published private(set) var release: WhatsNew.Release?
    /// 0: what the version brings. 1: your Coucou so far.
    @Published var page = 0
    @Published private(set) var stats = WhatsNew.Stats()

    // Not a secret: UserDefaults.
    private static let lastSeenKey = "whatsNewLastVersion"

    /// First thing at launch, before anything else writes its settings: was this Mac on an older
    /// Coucou? The version is recorded at once, so the card comes once per version.
    func noteLaunch() {
        let d = UserDefaults.standard
        let current = MacUpdater.currentVersion
        let last = d.string(forKey: Self.lastSeenKey)
        let show = WhatsNew.shouldShow(lastSeen: last, current: current, usedBefore: last == nil && Self.usedBefore())
        d.set(current, forKey: Self.lastSeenKey)
        guard show, let entry = WhatsNew.release(for: current, in: Self.bundled()) else { return }
        release = entry
        appendAppLog("nb.log", "[WhatsNew] updated from \(last ?? "an earlier version") to \(current)")
        // After the greeting, when nothing waits in the notch.
        tryShow(after: 4, attempts: 12)
    }

    /// Coucou 0.5.2 and earlier kept no version: settings only written once you used Coucou.
    private static func usedBefore() -> Bool {
        let d = UserDefaults.standard
        let keys = ["coucouHooksInstalled", "updateCheckConsent", "activeIntegrations", "recapLastShownWeek",
                    "settingsSection", "soundEnabled", "openOnHover", "hotkeyEnabled"]
        if keys.contains(where: { d.object(forKey: $0) != nil }) { return true }
        let fm = FileManager.default
        let support = HookServer.supportDir
        return fm.fileExists(atPath: support.appendingPathComponent("recap.json").path)
            || fm.fileExists(atPath: FlowStore.folder.appendingPathComponent("stats.json").path)
    }

    private static func bundled() -> [WhatsNew.Release] {
        guard let url = Bundle.main.url(forResource: "whats-new", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return WhatsNew.releases(data)
    }

    private func tryShow(after delay: TimeInterval, attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.release != nil else { return }
            let s = AppState.shared
            let busy = s.pendingApproval != nil || s.pendingQuestion != nil
                || s.view == .greeting || (s.mode == .expanded && s.view != .whatsNew)
            if busy {
                if attempts > 0 { self.tryShow(after: 15, attempts: attempts - 1) }
                return
            }
            self.show()
        }
    }

    func show() {
        guard release != nil else { return }
        stats = Self.collectStats()
        page = 0
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.whatsNew)
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
        SoundEngine.shared.play("proud")
    }

    func next() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { page = 1 }
    }

    func close() {
        release = nil
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    func openCoffee() {
        NSWorkspace.shared.open(WhatsNew.coffeeURL)
    }

    func openReleasePage() {
        NSWorkspace.shared.open(WhatsNew.releasePage(release?.version ?? MacUpdater.currentVersion))
    }

    /// Only what is already on this Mac: the recap's weeks, Flow's counts, the Notetaker's notes.
    private static func collectStats() -> WhatsNew.Stats {
        let recap = RecapStore.shared.keptTotals()
        let flow = FlowStore.shared
        let words = flow.totalWords
        return WhatsNew.Stats(
            sessions: recap.sessions,
            agentMinutes: recap.minutes,
            linesAdded: recap.linesAdded,
            approvals: recap.approvals,
            words: words,
            minutesSaved: Int(FlowText.minutesSaved(words: words, seconds: flow.totalSeconds)),
            notes: NoteTaker.shared.notes.count
        )
    }
}

// MARK: - Notch card

struct WhatsNewCardView: View {
    @ObservedObject private var center = WhatsNewCenter.shared

    private static let blue = Color(hex: "#3B82F6")

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 8) {
                if center.page == 0 {
                    features
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    soFar
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // Step 1: what the version brings

    @ViewBuilder private var features: some View {
        let version = center.release?.version ?? MacUpdater.currentVersion
        header(String(format: String(localized: "whatsnew.title %@"), version), step: 0)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                            GridItem(.flexible(), spacing: 12, alignment: .topLeading)],
                  alignment: .leading, spacing: 9) {
            ForEach(Array((center.release?.items ?? []).enumerated()), id: \.offset) { _, item in
                FeatureRow(item: item)
            }
        }
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            PrimaryButton(verbatim: String(localized: "whatsnew.next")) { center.next() }
            SecondaryButton(verbatim: String(localized: "whatsnew.all-changes")) { center.openReleasePage() }
        }
    }

    // Step 2: your Coucou so far, and the coffee

    @ViewBuilder private var soFar: some View {
        let chips = WhatsNew.chips(center.stats)
        header(String(localized: "whatsnew.so-far"), step: 1)
        if !chips.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .topLeading), count: 3),
                      alignment: .leading, spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                    StatChip(chip: chip)
                }
            }
        }
        Text(String(localized: "whatsnew.thanks"))
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "#8E939C"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        HStack(spacing: 8) {
            PrimaryButton(verbatim: "☕ " + String(localized: "whatsnew.coffee")) { center.openCoffee() }
            SecondaryButton("OK") { center.close() }
        }
    }

    private func header(_ title: String, step: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                ForEach(0..<2, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Self.blue : Color.white.opacity(0.18))
                        .frame(width: i == step ? 14 : 5, height: 5)
                }
            }
        }
    }
}

private struct FeatureRow: View {
    let item: WhatsNew.Item

    var body: some View {
        let langs = Bundle.main.preferredLocalizations
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: WhatsNew.symbol(item.icon))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#93C5FD"))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(hex: "#3B82F6").opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(WhatsNew.text(item.title, languages: langs))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F1F2F4"))
                    .lineLimit(1)
                Text(WhatsNew.text(item.detail, languages: langs))
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StatChip: View {
    let chip: WhatsNew.Chip

    var body: some View {
        let p = parts
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: p.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#93C5FD"))
                Text(verbatim: p.value)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(hex: "#F1F2F4"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(p.label)
                .font(.system(size: 9.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
        }
    }

    private var parts: (icon: String, value: String, label: String) {
        switch chip {
        case .sessions(let n):
            return ("terminal.fill", FlowText.shortCount(n), String(localized: "whatsnew.stat.sessions"))
        case .agentTime(let m):
            return ("clock.fill", HubInsightsPage.duration(minutes: Double(m)), String(localized: "whatsnew.stat.agent-time"))
        case .lines(let n):
            return ("chevron.left.forwardslash.chevron.right", FlowText.shortCount(n), String(localized: "whatsnew.stat.lines"))
        case .approvals(let n):
            return ("checkmark.circle.fill", FlowText.shortCount(n), String(localized: "whatsnew.stat.approvals"))
        case .words(let n):
            return ("mic.fill", FlowText.shortCount(n), String(localized: "whatsnew.stat.words"))
        case .saved(let m):
            return ("bolt.fill", HubInsightsPage.duration(minutes: Double(m)), String(localized: "whatsnew.stat.saved"))
        case .notes(let n):
            return ("phone.fill", FlowText.shortCount(n), String(localized: "whatsnew.stat.notes"))
        }
    }
}
#endif
