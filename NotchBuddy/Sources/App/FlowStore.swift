#if !APPSTORE
import AppKit

/// One dictation, kept for the history of the Coucou Flow window.
struct FlowEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var text: String
    /// The app it was pasted in ("Slack"), when known.
    var app: String?
    var words: Int
    /// How long you spoke.
    var seconds: Double
}

/// The numbers of one day. Kept even when the history is emptied, so Statistics stay right.
struct FlowDayStats: Codable, Sendable {
    var words = 0
    var seconds = 0.0
    var dictations = 0
}

struct FlowStats: Codable, Sendable {
    /// "2026-10-14" → that day's numbers.
    var days: [String: FlowDayStats] = [:]
    /// App name → words dictated in it.
    var apps: [String: Int] = [:]
}

/// How the words are written in an app, when the clean-up is on.
enum FlowStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Only the dictionary, replacements and snippets: for code, terminals and AI chats.
    case verbatim
    /// Without the "euh" and the repeats, punctuation fixed, the tone kept.
    case natural
    /// Full sentences, for mails.
    case polished

    var id: String { rawValue }

    var label: String {
        switch self {
        case .verbatim: return String(localized: "hub.style.verbatim")
        case .natural:  return String(localized: "hub.style.natural")
        case .polished: return String(localized: "hub.style.polished")
        }
    }

    var detail: String {
        switch self {
        case .verbatim: return String(localized: "hub.style.verbatim-detail")
        case .natural:  return String(localized: "hub.style.natural-detail")
        case .polished: return String(localized: "hub.style.polished-detail")
        }
    }
}

/// An app with its own style.
struct FlowAppStyle: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    var name: String
    var style: FlowStyle
    var id: String { bundleID }
}

/// Everything the Coucou Flow window shows and edits: the history, the numbers, the dictionary,
/// the snippets and the styles. Stored as small JSON files in Application Support/NotchBuddy/Flow,
/// on this Mac only.
@MainActor
final class FlowStore: ObservableObject {
    static let shared = FlowStore()

    /// Newest first.
    @Published private(set) var history: [FlowEntry] = []
    @Published private(set) var stats = FlowStats()
    @Published var words: [String] = [] { didSet { saveWords() } }
    @Published var replacements: [FlowReplacement] = [] { didSet { saveWords() } }
    @Published var snippets: [FlowSnippet] = [] { didSet { save(snippets, to: "snippets.json") } }
    @Published var appStyles: [FlowAppStyle] = [] { didSet { save(appStyles, to: "styles.json") } }

    /// Days the history is kept: 0 = not kept, -1 = forever.
    @Published var keepDays: Int = UserDefaults.standard.object(forKey: FlowStore.keepDaysKey) as? Int ?? 30 {
        didSet {
            UserDefaults.standard.set(keepDays, forKey: Self.keepDaysKey)
            prune()
        }
    }
    /// Clean the words with Claude before pasting them (needs the Claude key from Settings).
    @Published var cleanupEnabled: Bool = UserDefaults.standard.bool(forKey: FlowStore.cleanupKey) {
        didSet { UserDefaults.standard.set(cleanupEnabled, forKey: Self.cleanupKey) }
    }
    /// The style of the apps that have none of their own.
    @Published var defaultStyle: FlowStyle = FlowStyle(rawValue: UserDefaults.standard.string(forKey: FlowStore.defaultStyleKey) ?? "") ?? .natural {
        didSet { UserDefaults.standard.set(defaultStyle.rawValue, forKey: Self.defaultStyleKey) }
    }

    /// Parakeet (once downloaded) or the Mac's recognizer.
    @Published var engine: FlowEngine = FlowEngine(rawValue: UserDefaults.standard.string(forKey: FlowStore.engineKey) ?? "") ?? .parakeet {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: Self.engineKey)
            if engine == .parakeet { Parakeet.shared.preload() }
        }
    }

    static let engineKey = "flowEngine"
    static let keepDaysKey = "flowKeepDays"
    static let cleanupKey = "flowCleanup"
    static let defaultStyleKey = "flowDefaultStyle"

    private struct WordsFile: Codable {
        var words: [String]
        var replacements: [FlowReplacement]
    }

    private var loading = false

    static var folder: URL { HookServer.supportDir.appendingPathComponent("Flow", isDirectory: true) }

    private init() {
        loading = true
        history = load([FlowEntry].self, from: "history.json") ?? []
        stats = load(FlowStats.self, from: "stats.json") ?? FlowStats()
        if let file = load(WordsFile.self, from: "words.json") {
            words = file.words
            replacements = file.replacements
        }
        snippets = load([FlowSnippet].self, from: "snippets.json") ?? []
        appStyles = load([FlowAppStyle].self, from: "styles.json") ?? Self.defaultAppStyles
        loading = false
        prune()
    }

    /// Apps that get a style from the start: mails polished, chats natural, code and AI chats verbatim.
    static let defaultAppStyles: [FlowAppStyle] = [
        FlowAppStyle(bundleID: "com.apple.mail", name: "Mail", style: .polished),
        FlowAppStyle(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", style: .natural),
        FlowAppStyle(bundleID: "com.apple.MobileSMS", name: "Messages", style: .natural),
        FlowAppStyle(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", style: .natural),
        FlowAppStyle(bundleID: "com.anthropic.claudefordesktop", name: "Claude", style: .verbatim),
        FlowAppStyle(bundleID: "com.apple.Terminal", name: "Terminal", style: .verbatim),
        FlowAppStyle(bundleID: "com.googlecode.iterm2", name: "iTerm", style: .verbatim),
        FlowAppStyle(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", style: .verbatim),
        FlowAppStyle(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor", style: .verbatim),
    ]

    // MARK: - Dictation

    /// The words with the replacements and the dictionary's spelling, snippets set aside (FlowText.finish).
    func prepare(_ raw: String) -> FlowText.Prepared {
        FlowText.prepare(raw, words: words, replacements: replacements, snippets: snippets)
    }

    func style(for bundleID: String?) -> FlowStyle {
        guard let bundleID else { return defaultStyle }
        return appStyles.first(where: { $0.bundleID == bundleID })?.style ?? defaultStyle
    }

    /// The last thing dictated, for "paste again".
    var lastText: String? { history.first?.text ?? lastUnkeptText }
    /// When the history is not kept, the last dictation still waits here (memory only) for "paste again".
    private var lastUnkeptText: String?

    func record(text: String, app: String?, seconds: Double) {
        let count = FlowText.wordCount(text)
        guard count > 0 else { return }
        let now = Date()
        let day = FlowText.dayKey(now)
        var dayStats = stats.days[day] ?? FlowDayStats()
        dayStats.words += count
        dayStats.seconds += seconds
        dayStats.dictations += 1
        stats.days[day] = dayStats
        if let app, !app.isEmpty { stats.apps[app, default: 0] += count }
        save(stats, to: "stats.json")

        if keepDays == 0 {
            lastUnkeptText = text
            return
        }
        history.insert(FlowEntry(date: now, text: text, app: app, words: count, seconds: seconds), at: 0)
        prune()
        saveHistory()
    }

    func delete(_ entry: FlowEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    /// Empties the history; the numbers stay.
    func clearHistory() {
        history = []
        lastUnkeptText = nil
        saveHistory()
    }

    /// Empties the history and the numbers.
    func clearEverything() {
        clearHistory()
        stats = FlowStats()
        save(stats, to: "stats.json")
    }

    private func prune() {
        guard !loading else { return }
        let before = history.count
        if keepDays == 0 {
            history = []
        } else if keepDays > 0, let limit = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) {
            history.removeAll { $0.date < limit }
        }
        if history.count != before { saveHistory() }
    }

    // MARK: - Dictionary and snippets

    func addWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        words.append(w)
    }

    func addReplacement(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty, !t.isEmpty else { return }
        replacements.removeAll { $0.from.caseInsensitiveCompare(f) == .orderedSame }
        replacements.append(FlowReplacement(from: f, to: t))
    }

    // MARK: - Numbers

    var totalWords: Int { stats.days.values.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { stats.days.values.reduce(0) { $0 + $1.seconds } }
    var wordsPerMinute: Int { FlowText.wordsPerMinute(words: totalWords, seconds: totalSeconds) }
    var streak: Int { FlowText.streak(days: Set(stats.days.filter { $0.value.words > 0 }.keys), today: Date()) }

    /// The words of the last `count` days, oldest first.
    func dailyWords(last count: Int) -> [(date: Date, words: Int)] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { back in
            guard let day = Calendar.current.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, stats.days[FlowText.dayKey(day)]?.words ?? 0)
        }
    }

    /// Words and seconds since `date`.
    func totals(since date: Date?) -> (words: Int, seconds: Double, dictations: Int) {
        let from = date.map { FlowText.dayKey($0) }
        var words = 0, seconds = 0.0, dictations = 0
        for (key, day) in stats.days where from == nil || key >= from! {
            words += day.words
            seconds += day.seconds
            dictations += day.dictations
        }
        return (words, seconds, dictations)
    }

    // MARK: - Files

    private func saveHistory() { save(history, to: "history.json") }
    private func saveWords() { save(WordsFile(words: words, replacements: replacements), to: "words.json") }

    private func save<T: Encodable>(_ value: T, to name: String) {
        guard !loading else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(value).write(to: Self.folder.appendingPathComponent(name), options: .atomic)
        } catch {
            appendAppLog("nb.log", "[Flow] could not save \(name): \(error.localizedDescription)")
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: Self.folder.appendingPathComponent(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}
#endif
