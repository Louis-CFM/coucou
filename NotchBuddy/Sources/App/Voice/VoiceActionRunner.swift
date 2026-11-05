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
    func openApp(_ name: String, locale: Locale?) -> VoiceActionResult
    // Guided email
    /// An address for a contact name or a spoken address, nil when not found.
    func resolveEmail(_ recipient: String) async -> String?
    func findFile(_ name: String, folder: VoiceQuery.MailRequest.Folder?) -> URL?
    /// The on-device model writes the text ("thank her for yesterday"); nil if unavailable.
    func draftBody(to recipient: String, about instruction: String) async -> String?
    /// Opens the island's mail card, filled in. Nothing is sent until I click Send.
    func showMailCard(to address: String, subject: String, body: String, file: URL?)
    // Web search (Settings → Voice, opt-in, the user's Anthropic API key)
    var webSearchEnabled: Bool { get }
    var hasWebKey: Bool { get }
    /// A short spoken answer from Claude with web search; nil on any failure.
    func webAnswer(_ question: String, history: [VoiceWebTurn], lang: VoiceLang) async -> String?
}

/// One earlier exchange of the web conversation, kept in memory only.
struct VoiceWebTurn: Equatable {
    let question: String
    let answer: String
}

@MainActor
private final class NullInfo: VoiceInfoProviding {
    func answer(_ topic: VoiceTopic, locale: Locale?) async -> String { "" }
    func openApp(_ name: String, locale: Locale?) -> VoiceActionResult { .init(outcome: .failure, message: "") }
    func resolveEmail(_ recipient: String) async -> String? { VoiceQuery.spokenEmail(recipient) }
    func findFile(_ name: String, folder: VoiceQuery.MailRequest.Folder?) -> URL? { nil }
    func draftBody(to recipient: String, about instruction: String) async -> String? { nil }
    func showMailCard(to address: String, subject: String, body: String, file: URL?) {}
    var webSearchEnabled: Bool { false }
    var hasWebKey: Bool { false }
    func webAnswer(_ question: String, history: [VoiceWebTurn], lang: VoiceLang) async -> String? { nil }
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

    /// Called with "fr" / "en" / "pt" when I accept to be answered in the language I speak.
    var onLanguageSwitch: ((String) -> Void)?

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
            return await startMail(request)

        case .openApp(let name):
            return info.openApp(name, locale: commandLocale)

        case .webSearch(let query):
            return await webSearch(query)

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

        if case .mailStep(let field) = pending.kind {
            return await answerMail(field, transcript, pending: pending)
        }

        guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ok("voice.question-cancelled")
        }

        // "Want me to answer in French?" — yes / no, in any of the three languages.
        if case .switchLanguage(let code) = pending.kind {
            let target = VoiceLang(code: code)
            if Self.isYes(transcript) {
                onLanguageSwitch?(code)
                commandLocale = target.locale
                switch target {
                case .fr: return .init(outcome: .success, message: "D'accord, je te réponds en français maintenant.")
                case .pt: return .init(outcome: .success, message: "Beleza, agora respondo em português.")
                case .en: return .init(outcome: .success, message: "Sure, I'll answer in English from now on.")
                }
            }
            if Self.isNo(transcript) {
                return .init(outcome: .success, message: t("OK, je continue en français.",
                                                           "Okay, I'll keep answering in English.",
                                                           "Ok, continuo em português."))
            }
            if !pending.askedAgain {
                var again = pending; again.askedAgain = true; pendingQuestion = again
                return .init(outcome: .question(text: pending.text), message: pending.text)
            }
            return fail("voice.unknown")
        }

        // "What should I look up?" → the answer is the question.
        if case .webQuery = pending.kind {
            return await webSearch(transcript)
        }

        // A playlist name is free text, not a pill.
        if case .whichPlaylist = pending.kind {
            var name = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if case .musicPlayPlaylist(let n) = IntentParser.parse(transcript, pills: availablePills),
               !n.isEmpty { name = n }
            for prefix in ["la playlist ", "ma playlist ", "playlist ", "the playlist ", "a playlist ", "minha playlist "]
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
        case .whichPlaylist, .switchLanguage, .mailStep, .webQuery:
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

    // MARK: - Web search
    //
    // Claude answers with a web search (opt-in, the user's key). The last exchanges stay
    // in memory so "and in Paris?" or "yes, tell me more" continue the same subject; the
    // island controller forgets them with the rest of the conversation context.

    private(set) var webHistory: [VoiceWebTurn] = []
    var hasWebThread: Bool { !webHistory.isEmpty }
    func resetWebThread() { webHistory = [] }

    func webSearch(_ query: String) async -> VoiceActionResult {
        guard info.webSearchEnabled, info.hasWebKey else {
            let msg = info.hasWebKey
                ? t("La recherche web est coupée. Active-la dans Réglages, Voix.",
                    "Web search is off. Turn it on in Settings, Voice.",
                    "A busca na internet está desligada. Ativa em Ajustes, Voz.")
                : t("Pour chercher sur internet, ajoute ta clé API Anthropic dans Réglages, puis active la recherche web dans Voix.",
                    "To search the web, add your Anthropic API key in Settings, then turn on web search in Voice.",
                    "Pra pesquisar na internet, adiciona sua chave de API da Anthropic em Ajustes e ativa a busca na internet em Voz.")
            return .init(outcome: .failure, message: msg)
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            let text = t("Qu'est-ce que je cherche ?", "What should I look up?", "O que eu pesquiso?")
            pendingQuestion = PendingVoiceQuestion(kind: .webQuery, text: text)
            return .init(outcome: .question(text: text), message: text)
        }
        guard let answer = await info.webAnswer(q, history: webHistory, lang: answerLang),
              !answer.isEmpty else {
            return .init(outcome: .failure, message: t("Je n'arrive pas à chercher sur internet là, réessaie dans un instant.",
                                                       "I can't reach the web right now, try again in a moment.",
                                                       "Não consegui pesquisar na internet agora, tenta de novo daqui a pouco."))
        }
        webHistory.append(VoiceWebTurn(question: q, answer: answer))
        if webHistory.count > 6 { webHistory.removeFirst(webHistory.count - 6) }
        return .init(outcome: .success, message: answer)
    }

    // MARK: - Guided email
    //
    // "envoie un mail" → who? → subject? → text? (or "write it for me") → attachment?
    // (drop it on the notch, or say no) → the island's mail card opens, filled in, and I
    // click Send. Steps already given in the first sentence are skipped.

    private var mail: VoiceQuery.MailRequest?
    private var mailAddress: String?
    private var mailFile: URL?
    private var mailAttachmentAsked = false

    /// True while Coucou waits for a file to be dropped on the notch.
    var isWaitingForAttachment: Bool {
        if case .mailStep(.attachment)? = pendingQuestion?.kind { return true }
        return false
    }

    /// The answer Coucou waits for is free text (who, subject, what the mail says, what to
    /// look up): the mic gives more time to pause and think before the turn ends.
    var expectsLongAnswer: Bool {
        switch pendingQuestion?.kind {
        case .mailStep(let field)?: return field != .attachment
        case .webQuery?:            return true
        default:                    return false
        }
    }

    /// True while Coucou waits for any answer of the voice email (who, subject, text, file).
    var isMailInProgress: Bool {
        if case .mailStep? = pendingQuestion?.kind { return true }
        return false
    }

    private var answerLang: VoiceLang { VoiceLang(locale: commandLocale) }
    private func t(_ fr: String, _ en: String, _ pt: String) -> String {
        switch answerLang {
        case .fr: return fr
        case .en: return en
        case .pt: return pt
        }
    }

    func startMail(_ request: VoiceQuery.MailRequest) async -> VoiceActionResult {
        mail = request
        mailAddress = nil
        mailFile = nil
        mailAttachmentAsked = false
        return await continueMail()
    }

    /// A file dropped on the notch while Coucou asked for an attachment.
    func attachDroppedFile(_ url: URL) async -> VoiceActionResult {
        pendingQuestion = nil
        mailFile = url
        mailAttachmentAsked = true
        return await continueMail()
    }

    private func askMail(_ field: PendingVoiceQuestion.MailField, _ text: String) -> VoiceActionResult {
        pendingQuestion = PendingVoiceQuestion(kind: .mailStep(field), text: text)
        return .init(outcome: .question(text: text), message: text)
    }

    private func continueMail() async -> VoiceActionResult {
        guard var m = mail else { return fail("voice.unknown") }

        if mailAddress == nil {
            let who = m.recipient.trimmingCharacters(in: .whitespaces)
            if who.isEmpty {
                return askMail(.recipient, t("À qui j'envoie le mail ? Dis son nom ou son adresse.",
                                             "Who should I send it to? Say a name or an email address.",
                                             "Pra quem eu mando o e-mail? Diz o nome ou o endereço."))
            }
            if let address = await info.resolveEmail(who) {
                mailAddress = address
            } else {
                m.recipient = ""; mail = m
                return askMail(.recipient, t("Je ne trouve pas \(who) dans tes contacts. Dis-moi son adresse mail.",
                                             "I can't find \(who) in your contacts. What's the email address?",
                                             "Não achei \(who) nos seus contatos. Qual é o endereço de e-mail?"))
            }
        }
        if let name = m.file, mailFile == nil {
            mailAttachmentAsked = true
            m.file = nil; mail = m
            if let url = info.findFile(name, folder: m.folder) {
                mailFile = url
            } else {
                return askMail(.attachment, t("Je ne trouve pas « \(name) ». Glisse-le sur le notch, ou dis non.",
                                              "I can't find “\(name)”. Drop it on the notch, or say no.",
                                              "Não achei “\(name)”. Arrasta pro notch ou diz não."))
            }
        }
        if m.subject == nil {
            return askMail(.subject, t("Quel est l'objet ?", "What's the subject?", "Qual é o assunto?"))
        }
        if m.body == nil {
            if let what = m.instruction {
                m.body = await info.draftBody(to: m.recipient, about: what) ?? VoiceQuery.simpleMail(from: what)
                mail = m
            } else {
                return askMail(.body, t("Qu'est-ce que je lui dis ? Je l'écris pour toi.",
                                        "What should the email say? I'll write it for you.",
                                        "O que eu digo? Eu escrevo pra você."))
            }
        }
        if !mailAttachmentAsked {
            mailAttachmentAsked = true
            return askMail(.attachment, t("Une pièce jointe ? Glisse-la sur le notch, ou dis non.",
                                          "Any attachment? Drop it on the notch, or say no.",
                                          "Tem algum anexo? Arrasta pro notch ou diz não."))
        }

        info.showMailCard(to: mailAddress ?? m.recipient, subject: m.subject ?? "", body: m.body ?? "", file: mailFile)
        mail = nil
        let with = mailFile.map { t(" avec \($0.lastPathComponent)", " with \($0.lastPathComponent)", " com \($0.lastPathComponent)") } ?? ""
        return .init(outcome: .success,
                     message: t("Voilà ton mail\(with). Relis-le et clique sur Envoyer.",
                                "Here's your email\(with). Check it and click Send.",
                                "Aqui está o seu e-mail\(with). Confere e clica em Enviar."))
    }

    private func answerMail(_ field: PendingVoiceQuestion.MailField, _ transcript: String,
                            pending: PendingVoiceQuestion) async -> VoiceActionResult {
        guard var m = mail else { return fail("voice.unknown") }
        // "image image": the same answer said twice in one turn counts once.
        let said = VoiceQuery.collapseRepeat(transcript.trimmingCharacters(in: .whitespacesAndNewlines))

        if said.isEmpty {
            // Silence after "any attachment?" means none; anywhere else it cancels the mail.
            if field == .attachment { return await continueMail() }
            mail = nil
            return .init(outcome: .success, message: t("OK, j'annule le mail.", "Okay, I cancelled the email.", "Ok, cancelei o e-mail."))
        }
        if Self.cancelsMail(said) {
            mail = nil
            return .init(outcome: .success, message: t("OK, j'annule le mail.", "Okay, I cancelled the email.", "Ok, cancelei o e-mail."))
        }
        switch field {
        case .recipient:
            m.recipient = VoiceQuery.recipientAnswer(said)
            mailAddress = nil
        case .subject:
            m.subject = VoiceQuery.subjectAnswer(said)
        case .body:
            let a = VoiceQuery.bodyAnswer(said)
            m.body = a.body
            m.instruction = a.instruction
        case .attachment:
            if !Self.isNo(said), let name = VoiceQuery.attachmentAnswer(said) {
                if let url = info.findFile(name, folder: nil) {
                    mailFile = url
                } else if !pending.askedAgain {
                    var again = PendingVoiceQuestion(kind: .mailStep(.attachment),
                        text: t("Je ne trouve pas « \(name) ». Glisse-le sur le notch, ou dis non.",
                                "I can't find “\(name)”. Drop it on the notch, or say no.",
                                "Não achei “\(name)”. Arrasta pro notch ou diz não."))
                    again.askedAgain = true
                    pendingQuestion = again
                    return .init(outcome: .question(text: again.text), message: again.text)
                }
            }
        }
        mail = m
        return await continueMail()
    }

    /// "Annule", "laisse tomber", "cancel"… as the whole answer stops the voice email.
    static func cancelsMail(_ s: String) -> Bool {
        let t = IntentParser.normalise(s)
        return ["annule", "annuler", "annule le mail", "annule tout", "laisse tomber", "oublie",
                "stop", "cancel", "cancel it", "never mind", "forget it",
                "cancela", "cancelar", "cancela o email", "cancela o e mail", "deixa pra la", "deixa para la",
                "esquece", "para"].contains(t)
    }

    /// Asked once, in the current answer language, when I speak another one.
    func offerLanguageSwitch(to code: String) -> String {
        let target = VoiceLang(code: code)
        let text: String
        switch (target, answerLang) {
        case (.fr, .fr): text = "Tu veux que je te réponde en français ?"
        case (.en, .en): text = "Want me to answer in English?"
        case (.pt, .pt): text = "Quer que eu responda em português?"
        case (.fr, .en): text = "By the way, you're speaking French. Want me to answer in French?"
        case (.pt, .en): text = "By the way, you're speaking Portuguese. Want me to answer in Portuguese?"
        case (.en, .fr): text = "Au fait, tu me parles en anglais. Tu veux que je te réponde en anglais ?"
        case (.pt, .fr): text = "Au fait, tu me parles en portugais. Tu veux que je te réponde en portugais ?"
        case (.fr, .pt): text = "Aliás, você está falando francês. Quer que eu responda em francês?"
        case (.en, .pt): text = "Aliás, você está falando inglês. Quer que eu responda em inglês?"
        }
        pendingQuestion = PendingVoiceQuestion(kind: .switchLanguage(to: code), text: text)
        return text
    }

    static func isYes(_ s: String) -> Bool {
        let t = " " + IntentParser.normalise(s) + " "
        if isNo(s) { return false }
        return ["oui", "ouais", "ouai", "yes", "yeah", "yep", "sure", "ok", "okay", "d accord", "vas y",
                "volontiers", "carrement", "please", "absolument", "bien sur", "go", "of course", "why not",
                "pourquoi pas", "allez",
                "sim", "claro", "pode", "pode ser", "beleza", "bora", "com certeza", "uhum", "quero"].contains { t.contains(" " + $0 + " ") }
    }

    static func isNo(_ s: String) -> Bool {
        let t = " " + IntentParser.normalise(s) + " "
        return ["non", "no", "nope", "nah", "pas besoin", "garde", "keep", "laisse", "c est bon comme ca",
                "stay", "reste", "don t", "dont",
                "nao", "nao precisa", "deixa", "deixa assim", "mantem", "fica"].contains { t.contains(" " + $0 + " ") }
    }

    /// "Je veux que tu ajoutes" (no pill named) → asks which pill, and listens for it.
    /// Returns nil when the phrase has no add/remove verb either.
    func askIfIncomplete(_ transcript: String) -> VoiceActionResult? {
        let words = Set(IntentParser.normalise(transcript).split(separator: " ").map(String.init))
        let addVerbs: Set<String> = ["ajoute", "ajoutes", "ajouter", "rajoute", "rajoutes", "rajouter",
                                     "active", "actives", "activer", "add",
                                     "adiciona", "adicionar", "adicione", "ativa", "ativar", "ative",
                                     "coloca", "colocar", "coloque", "inclui", "incluir"]
        let removeVerbs: Set<String> = ["enleve", "enleves", "enlever", "retire", "retires", "retirer",
                                        "supprime", "supprimes", "supprimer", "vire", "virer", "remove",
                                        "tira", "tirar", "tire", "remover", "remova", "desativa", "desativar",
                                        "desative", "apaga", "apagar"]
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
