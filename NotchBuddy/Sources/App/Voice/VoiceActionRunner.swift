#if !APPSTORE
import Foundation

// MARK: - Protocols (injectable for tests)

/// Abstraction over Apple Music + Spotify playback.
protocol MusicControlling: Sendable {
    var isMusicRunning: Bool { get }
    var isSpotifyRunning: Bool { get }
    @MainActor func play()
    @MainActor func pause()
    @MainActor func nextTrack()
    @MainActor func previousTrack()
    @MainActor func volumeUp()
    @MainActor func volumeDown()
    @MainActor func setVolume(_ pct: Int)
    @MainActor func playSearch(_ name: String) async -> Bool
    @MainActor func playPlaylist(_ name: String) async -> Bool
    @MainActor func launchAndPlay() async
    @MainActor func launchSpotify() async
    @MainActor func openSearch(_ name: String)
}

/// Abstraction over AppState pill management.
@MainActor
protocol PillControlling {
    func activeIds() -> Set<String>
    func mainPillId() -> String
    func activeCount() -> Int
    func toggleIntegration(_ id: String)
    func setMainPill(_ id: String)
}

/// Answers questions and prepares mail / opens apps (Mac side: VoiceDataSources.swift).
@MainActor
protocol VoiceInfoProviding {
    func answer(_ topic: VoiceTopic, locale: Locale?) async -> String
    /// Opens a compose window (Mail) — never sends: I click Send myself.
    func composeMail(_ request: VoiceQuery.MailRequest, locale: Locale?) async -> VoiceActionResult
    func openApp(_ name: String, locale: Locale?) -> VoiceActionResult
}

@MainActor
private final class NullInfo: VoiceInfoProviding {
    func answer(_ topic: VoiceTopic, locale: Locale?) async -> String { "" }
    func composeMail(_ request: VoiceQuery.MailRequest, locale: Locale?) async -> VoiceActionResult {
        .init(outcome: .failure, message: "")
    }
    func openApp(_ name: String, locale: Locale?) -> VoiceActionResult { .init(outcome: .failure, message: "") }
}

// MARK: - Null implementations (test-safe, no AppKit)

private final class NullMusic: MusicControlling, @unchecked Sendable {
    var isMusicRunning: Bool   { false }
    var isSpotifyRunning: Bool { false }
    @MainActor func play()                           {}
    @MainActor func pause()                          {}
    @MainActor func nextTrack()                      {}
    @MainActor func previousTrack()                  {}
    @MainActor func volumeUp()                       {}
    @MainActor func volumeDown()                     {}
    @MainActor func setVolume(_ pct: Int)            {}
    @MainActor func playSearch(_ n: String) async -> Bool   { false }
    @MainActor func playPlaylist(_ n: String) async -> Bool { false }
    @MainActor func launchAndPlay() async            {}
    @MainActor func launchSpotify() async            {}
    @MainActor func openSearch(_ name: String)       {}
}

@MainActor
private final class NullPills: PillControlling {
    func activeIds() -> Set<String>        { [] }
    func mainPillId() -> String            { "" }
    func activeCount() -> Int              { 0 }
    func toggleIntegration(_ id: String)   {}
    func setMainPill(_ id: String)         {}
}

// MARK: - VoiceActionRunner

@MainActor
final class VoiceActionRunner {
    static let shared = VoiceActionRunner()

    var music: MusicControlling = NullMusic()
    var pills: PillControlling  = NullPills()
    var info:  VoiceInfoProviding = NullInfo()

    /// Pending follow-up question (4-pill limit, ambiguity). Set when outcome is .question.
    var pendingQuestion: PendingVoiceQuestion? = nil

    /// Set to true when the runner executes a volume-changing command (volumeUp/Down/setVolume).
    /// VoiceEngine reads this flag in endCommand to skip music volume restoration.
    var volumeCommandExecuted = false

    /// Locale of the current recognition session — set by IslandWindowController before calling
    /// run() or handleAnswer(). Used to produce responses in the spoken language rather than the UI language.
    var commandLocale: Locale? = nil

    init() {}

    func run(_ intent: VoiceIntent,
             availablePills: [PillDefinition] = [],
             rawTranscript: String = "") async -> VoiceActionResult {
        switch intent {

        // ── Music ─────────────────────────────────────────────────────────────

        case .musicPlay(let target):
            switch target {
            case .spotify:
                if !music.isSpotifyRunning { await music.launchSpotify() }
                else { music.play() }
                return ok("voice.music-playing")
            case .appleMusic:
                if !music.isMusicRunning { await music.launchAndPlay() }
                else { music.play() }
                return ok("voice.music-playing")
            case nil:
                if music.isMusicRunning || music.isSpotifyRunning {
                    music.play()
                    return ok("voice.music-playing")
                }
                await music.launchAndPlay()
                return ok("voice.music-launch")
            }

        case .musicPause:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.pause()
            return ok("voice.music-paused")

        case .musicNext:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.nextTrack()
            return ok("voice.music-next")

        case .musicPrevious:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.previousTrack()
            return ok("voice.music-prev")

        case .musicVolumeUp:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            volumeCommandExecuted = true
            music.volumeUp()
            return ok("voice.music-vol-up")

        case .musicVolumeDown:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            volumeCommandExecuted = true
            music.volumeDown()
            return ok("voice.music-vol-down")

        case .musicSetVolume(let pct):
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            volumeCommandExecuted = true
            music.setVolume(pct)
            let fmt = Self.localizedString("voice.music-vol-set", locale: commandLocale)
            return .init(outcome: .success, message: fmt.contains("%") ? String(format: fmt, pct) : "\(pct)%")

        case .musicPlaySearch(let name):
            if !music.isMusicRunning && !music.isSpotifyRunning {
                await music.launchAndPlay()
            }
            let found = await music.playSearch(name)
            if found { return ok("voice.music-playing") }
            // Not in library — open Apple Music search
            music.openSearch(name)
            let fmt = Self.localizedString("voice.music-search-opened", locale: commandLocale)
            return .init(outcome: .success,
                         message: fmt.contains("%@") ? String(format: fmt, name) : name)

        case .musicPlayPlaylist(let name) where name.trimmingCharacters(in: .whitespaces).isEmpty:
            return ask(.whichPlaylist, "voice.ask-which-playlist")

        case .musicPlayPlaylist(let name):
            if !music.isMusicRunning && !music.isSpotifyRunning {
                await music.launchAndPlay()
            }
            let found = await music.playPlaylist(name)
            if found { return ok("voice.music-playing") }
            let fmt = Self.localizedString("voice.music-artist-err", locale: commandLocale)
            return .init(outcome: .failure,
                         message: fmt.contains("%@") ? String(format: fmt, name) : name)

        // ── Pills ─────────────────────────────────────────────────────────────

        case .pillAdd(let id):
            if pills.activeIds().contains(id) {
                return ok("voice.pill-already-active")
            }
            guard pills.activeCount() < 4 else {
                let qFmt = Self.localizedString("voice.ask-which-remove", locale: commandLocale)
                pendingQuestion = PendingVoiceQuestion(kind: .removeWhich(toAdd: id), text: qFmt)
                return .init(outcome: .question(text: qFmt), message: qFmt)
            }
            pills.toggleIntegration(id)
            let name = pillName(id, from: availablePills)
            let fmt  = Self.localizedString("voice.pill-added", locale: commandLocale)
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            return .init(outcome: .success, message: msg)

        case .pillAddMultiple(let ids):
            var added: [String] = []
            for id in ids {
                guard !pills.activeIds().contains(id), pills.activeCount() < 4 else { continue }
                pills.toggleIntegration(id)
                added.append(pillName(id, from: availablePills))
            }
            let names = added.joined(separator: ", ")
            let fmt   = Self.localizedString("voice.pill-added", locale: commandLocale)
            let msg   = fmt.contains("%@") ? String(format: fmt, names) : names
            return .init(outcome: added.isEmpty ? .failure : .success,
                         message: added.isEmpty ? Self.localizedString("voice.unknown", locale: commandLocale) : msg)

        case .pillRemove(let id):
            guard pills.activeIds().contains(id) else {
                return fail("voice.pill-not-active")
            }
            pills.toggleIntegration(id)
            let name = pillName(id, from: availablePills)
            let fmt  = Self.localizedString("voice.pill-removed", locale: commandLocale)
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            return .init(outcome: .success, message: msg)

        case .pillRemoveMultiple(let ids):
            var removed: [String] = []
            for id in ids {
                guard pills.activeIds().contains(id) else { continue }
                pills.toggleIntegration(id)
                removed.append(pillName(id, from: availablePills))
            }
            let names = removed.joined(separator: ", ")
            let fmt   = Self.localizedString("voice.pill-removed", locale: commandLocale)
            let msg   = fmt.contains("%@") ? String(format: fmt, names) : names
            return .init(outcome: removed.isEmpty ? .failure : .success,
                         message: removed.isEmpty ? Self.localizedString("voice.unknown", locale: commandLocale) : msg)

        case .pillSetMain(let id):
            pills.setMainPill(id)
            let name = pillName(id, from: availablePills)
            let fmt  = Self.localizedString("voice.pill-main", locale: commandLocale)
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            return .init(outcome: .success, message: msg)

        case .pillReplace(let oldId, let newId):
            if pills.activeIds().contains(oldId) { pills.toggleIntegration(oldId) }
            if !pills.activeIds().contains(newId) { pills.toggleIntegration(newId) }
            let n1  = pillName(oldId, from: availablePills)
            let n2  = pillName(newId, from: availablePills)
            let fmt = Self.localizedString("voice.pill-replaced", locale: commandLocale)
            let msg = fmt.contains("%@") ? String(format: fmt, n1, n2) : "\(n1) → \(n2)"
            return .init(outcome: .success, message: msg)

        case .pillOnly(let ids):
            let current = pills.activeIds()
            for id in current { if !ids.contains(id) { pills.toggleIntegration(id) } }
            for id in ids { if !pills.activeIds().contains(id) { pills.toggleIntegration(id) } }
            let names = ids.map { pillName($0, from: availablePills) }.joined(separator: ", ")
            let fmt   = Self.localizedString("voice.pill-only", locale: commandLocale)
            let msg   = fmt.contains("%@") ? String(format: fmt, names) : names
            return .init(outcome: .success, message: msg)

        // ── Questions, mail, apps ─────────────────────────────────────────────

        case .query(let topic):
            let text = await info.answer(topic, locale: commandLocale)
            return text.isEmpty ? fail("voice.unknown") : .init(outcome: .success, message: text)

        case .mail(let request):
            return await info.composeMail(request, locale: commandLocale)

        case .openApp(let name):
            return info.openApp(name, locale: commandLocale)

        case .unknown:
            if rawTranscript.isEmpty { return fail("voice.unknown") }
            let fmt = Self.localizedString("voice.unknown-transcript", locale: commandLocale)
            let msg = fmt.contains("%@") ? String(format: fmt, rawTranscript) : rawTranscript
            return .init(outcome: .failure, message: msg)
        }
    }

    // MARK: - Follow-up question answer

    /// Handle a follow-up answer transcript after a .question outcome.
    func handleAnswer(_ transcript: String, availablePills: [PillDefinition] = []) async -> VoiceActionResult {
        guard let pending = pendingQuestion else { return fail("voice.unknown") }
        pendingQuestion = nil

        guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ok("voice.question-cancelled")
        }

        // A playlist name is free text, not a pill.
        if case .whichPlaylist = pending.kind {
            var name = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .musicPlayPlaylist(let n) = IntentParser.parse(transcript, pills: availablePills),
               !n.isEmpty { name = n }
            for prefix in ["la playlist ", "ma playlist ", "playlist ", "the playlist "]
            where name.lowercased().hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            return await run(.musicPlayPlaylist(name: name), availablePills: availablePills)
        }

        guard let entity = Self.answerEntity(transcript, active: pills.activeIds(),
                                             availablePills: availablePills) else {
            // Not understood: ask once more, then give up.
            if !pending.askedAgain {
                var again = pending
                again.askedAgain = true
                pendingQuestion = again
                return .init(outcome: .question(text: pending.text), message: pending.text)
            }
            return fail("voice.unknown")
        }

        switch pending.kind {
        case .whichPlaylist:
            return fail("voice.unknown")   // handled above
        case .whichPill(let add):
            return await run(add ? .pillAdd(id: entity) : .pillRemove(id: entity),
                             availablePills: availablePills)
        case .removeWhich(let toAdd):
            if pills.activeIds().contains(entity) {
                pills.toggleIntegration(entity)
            }
            if !pills.activeIds().contains(toAdd), pills.activeCount() < 4 {
                pills.toggleIntegration(toAdd)
            }
            let removedName = pillName(entity, from: availablePills)
            let addedName   = pillName(toAdd,  from: availablePills)
            let fmt = Self.localizedString("voice.pill-replaced", locale: commandLocale)
            let msg = fmt.contains("%@") ? String(format: fmt, removedName, addedName)
                                         : "\(removedName) → \(addedName)"
            return .init(outcome: .success, message: msg)
        }
    }

    /// "Je veux que tu ajoutes" (no pill named) → asks which pill, and listens for it.
    /// Returns nil when the phrase has no add/remove verb either.
    func askIfIncomplete(_ transcript: String) -> VoiceActionResult? {
        let words = Set(IntentParser.normalise(transcript).split(separator: " ").map(String.init))
        let addVerbs: Set<String> = ["ajoute", "ajoutes", "ajouter", "rajoute", "rajoutes", "rajouter",
                                     "active", "actives", "activer", "add"]
        let removeVerbs: Set<String> = ["enleve", "enleves", "enlever", "retire", "retires", "retirer",
                                        "supprime", "supprimes", "supprimer", "vire", "virer", "remove"]
        if !words.isDisjoint(with: removeVerbs) { return ask(.whichPill(add: false), "voice.ask-which-pill-remove") }
        if !words.isDisjoint(with: addVerbs)    { return ask(.whichPill(add: true),  "voice.ask-which-pill-add") }
        return nil
    }

    private func ask(_ kind: PendingVoiceQuestion.Kind, _ key: String) -> VoiceActionResult {
        let text = Self.localizedString(key, locale: commandLocale)
        pendingQuestion = PendingVoiceQuestion(kind: kind, text: text)
        return .init(outcome: .question(text: text), message: text)
    }

    /// The pill named in an answer, whether it is a bare name ("Stripe") or a sentence
    /// ("je retire la pilule Stripe", "enlève GitHub", "plutôt Vercel").
    /// Active pills win when several names could match.
    static func answerEntity(_ transcript: String, active: Set<String>,
                             availablePills: [PillDefinition]) -> String? {
        switch IntentParser.parse(transcript, pills: availablePills) {
        case .pillRemove(let id), .pillAdd(let id):        return id
        case .pillRemoveMultiple(let ids) where !ids.isEmpty: return ids[0]
        default: break
        }
        let norm = IntentParser.normalise(transcript)
        if let id = EntityResolver.resolve(norm, from: availablePills) { return id }
        // Look for a pill name inside the sentence: 3-, 2- then 1-word windows.
        let words = norm.split(separator: " ").map(String.init)
        var found: [String] = []
        for size in stride(from: min(3, words.count), through: 1, by: -1) {
            for start in 0...(words.count - size) {
                let gram = words[start..<(start + size)].joined(separator: " ")
                guard gram.count >= 3,
                      let id = EntityResolver.resolve(gram, from: availablePills) else { continue }
                if !found.contains(id) { found.append(id) }
            }
            if !found.isEmpty { break }
        }
        return found.first(where: { active.contains($0) }) ?? found.first
    }

    // MARK: - Helpers

    private func ok(_ key: String) -> VoiceActionResult {
        .init(outcome: .success, message: Self.localizedString(key, locale: commandLocale))
    }

    private func fail(_ key: String) -> VoiceActionResult {
        .init(outcome: .failure, message: Self.localizedString(key, locale: commandLocale))
    }

    private func pillName(_ id: String, from available: [PillDefinition]) -> String {
        available.first(where: { $0.id == id })?.name ?? id
    }

    /// Look up `key` in the lproj bundle matching `locale`, falling back to NSLocalizedString.
    static func localizedString(_ key: String, locale: Locale?) -> String {
        guard let locale else { return NSLocalizedString(key, comment: "") }
        // Try locale.identifier ("fr-FR" → "fr_FR"), hyphenated form, then base language code.
        let langCode = locale.language.languageCode?.identifier ?? ""
        let candidates = [locale.identifier,
                          locale.identifier.replacingOccurrences(of: "_", with: "-"),
                          langCode].filter { !$0.isEmpty }
        for code in candidates {
            if let path   = Bundle.main.path(forResource: code, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                let s = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                if s != key { return s }
            }
        }
        return NSLocalizedString(key, comment: "")
    }
}
#endif
