#if !APPSTORE
import Foundation

// MARK: - VoiceQuery
//
// Questions about what Coucou already knows ("combien d'étoiles sur GitHub ?",
// "mon déploiement Vercel est passé ?", "quel temps il fait ?") and the two
// requests that are not pill or music commands (prepare an email, open an app).
//
// Pure: no AppKit, no AppState, no network. The Mac side fills a VoiceSnapshot
// (VoiceDataSources.swift) and VoiceAnswer turns it into one or two spoken sentences.
// Answers are French or English (the spoken language); other languages get English.

enum VoiceTopic: String, Equatable, CaseIterable {
    case stripe, github, vercel, resend, n8n, notion, calcom
    case agents          // Claude Code and the other agent sessions
    case claudePlan, codexPlan
    case music, pills
    case weatherToday, weatherTomorrow
}

enum VoiceQuery {

    // MARK: Detection

    /// The topic of a question, or nil when the phrase is a command or not a question.
    /// A phrase with an action verb ("est-ce que tu peux ajouter GitHub") stays a command.
    static func topic(of raw: String) -> VoiceTopic? {
        let norm  = IntentParser.normalise(raw)
        let words = norm.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        let text  = " " + norm + " "
        func has(_ s: String) -> Bool { text.contains(" " + s + " ") }
        func hasAny(_ list: [String]) -> Bool { list.contains(where: has) }

        if !Set(words).isDisjoint(with: actionVerbs) { return nil }

        let asks = raw.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            || hasAny(questionMarkers)

        // Weather words are clear enough on their own ("météo", "il pleut ?").
        if hasAny(["meteo", "weather", "quel temps", "il pleut", "va pleuvoir", "pleuvoir",
                   "temperature", "il fait chaud", "il fait froid", "fait il beau", "il fait beau",
                   "forecast", "rain", "parapluie", "umbrella"]) {
            return hasAny(["demain", "tomorrow"]) ? .weatherTomorrow : .weatherToday
        }
        guard asks else { return nil }

        // Named services first.
        if has("stripe") { return .stripe }
        if hasAny(["github", "git hub", "gt"]) { return .github }
        if has("vercel") { return .vercel }
        if has("resend") { return .resend }
        if hasAny(["n8n", "n 8 n", "workflow", "workflows", "automatisation", "automatisations"]) { return .n8n }
        if has("notion") { return .notion }
        if hasAny(["cal com", "calcom", "rendez vous", "rdv", "agenda", "reunion", "reunions",
                   "meeting", "meetings", "booking", "bookings", "reservation", "reservations"]) { return .calcom }
        if hasAny(["quota", "limite", "limites", "forfait", "usage", "plan"]) {
            return has("codex") ? .codexPlan : .claudePlan
        }
        if hasAny(["claude", "codex", "cursor", "gemini", "copilot", "agent", "agents",
                   "session", "sessions", "qu est ce qui se passe", "ou en est", "il fait quoi",
                   "what s happening", "whats happening"]) { return .agents }
        // Generic words.
        if hasAny(["argent", "vendu", "vente", "ventes", "chiffre", "revenu", "revenus", "gagne",
                   "encaisse", "paiement", "paiements", "solde", "money", "sales", "revenue",
                   "earned", "payments", "balance"]) { return .stripe }
        if hasAny(["etoile", "etoiles", "star", "stars", "pull request", "pull requests", "pr", "prs",
                   "repo", "repos", "ci"]) { return .github }
        if hasAny(["deploiement", "deploiements", "deploy", "deploye", "deployment", "push", "pousse"]) { return .vercel }
        if hasAny(["mail", "mails", "email", "emails"]) { return .resend }
        if hasAny(["chanson", "musique", "titre", "morceau", "song", "track", "playing", "ecoute"]) { return .music }
        if hasAny(["pilule", "pilules", "pill", "pills"]) { return .pills }
        return nil
    }

    private static let questionMarkers = [
        "combien", "quel", "quelle", "quels", "quelles", "est ce", "c est quoi", "qu est ce",
        "ou en", "comment", "dis moi", "donne moi", "montre moi", "y a t il", "il y a",
        "how", "what", "whats", "did", "is", "are", "any", "tell me", "show me", "statut", "status",
        "etat", "est il", "est elle", "a t il", "a t elle",
    ]

    private static let actionVerbs: Set<String> = [
        "ajoute", "ajouter", "ajoutes", "rajoute", "enleve", "enlever", "enleves", "retire", "retirer",
        "supprime", "supprimer", "mets", "mettre", "met", "lance", "lancer", "joue", "jouer",
        "remplace", "remplacer", "active", "activer", "desactive", "vire", "virer",
        "envoie", "envoyer", "ouvre", "ouvrir", "add", "remove", "play", "open", "send",
    ]

    // MARK: Email: "envoie un mail à Tana", "envoie le fichier facture des téléchargements à Tana"

    struct MailRequest: Equatable {
        var recipient: String
        var file: String?
        var folder: Folder?
        enum Folder: String, Equatable { case downloads, desktop, documents }
    }

    static func mail(of raw: String) -> MailRequest? {
        let norm = IntentParser.normalise(raw)
        let n = norm.split(separator: " ").map(String.init)
        let r = rawWords(raw)
        guard n.count == r.count, !n.isEmpty else { return nil }
        let sendVerbs: Set<String> = ["envoie", "envoyer", "envoies", "ecris", "ecrire", "send", "email", "mail"]
        guard let v = n.firstIndex(where: { sendVerbs.contains($0) }) else { return nil }
        let rest = Array(n[(v + 1)...])
        let isMail = rest.contains(where: { ["mail", "email", "mel", "courriel", "fichier", "file", "document", "pdf"].contains($0) })
            || ["email", "mail"].contains(n[v])
        guard isMail else { return nil }
        // Recipient: after the last "à" / "to".
        guard let to = n.lastIndex(where: { $0 == "a" || $0 == "to" }), to > v, to + 1 < n.count else { return nil }
        let recipient = r[(to + 1)...].joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard !recipient.isEmpty else { return nil }

        // Optional file: after "fichier"/"file"/"document", up to the folder words or "à".
        var file: String? = nil
        var folder: MailRequest.Folder? = nil
        let middle = Array(n[(v + 1)..<to])
        if middle.contains(where: { ["telechargements", "telechargement", "downloads"].contains($0) }) { folder = .downloads }
        else if middle.contains(where: { ["bureau", "desktop"].contains($0) }) { folder = .desktop }
        else if middle.contains(where: { ["documents"].contains($0) }) { folder = .documents }
        if let f = n[(v + 1)..<to].firstIndex(where: { ["fichier", "file", "document", "pdf"].contains($0) }) {
            let stop: Set<String> = ["des", "du", "de", "dans", "from", "in", "telechargements", "telechargement",
                                     "downloads", "bureau", "desktop", "documents", "mes", "my", "par", "en"]
            var end = f + 1
            while end < to && !(stop.contains(n[end]) && end > f + 1) { end += 1 }
            let name = r[(f + 1)..<end].joined(separator: " ")
            if !name.isEmpty { file = name }
            if n[f] == "pdf", file == nil { file = "pdf" }
        }
        return MailRequest(recipient: recipient, file: file, folder: folder)
    }

    // MARK: Open an app: "ouvre Figma", "open Safari"

    static func appToOpen(_ raw: String) -> String? {
        let n = IntentParser.normalise(raw).split(separator: " ").map(String.init)
        let r = rawWords(raw)
        guard n.count == r.count,
              let i = n.firstIndex(where: { ["ouvre", "ouvrir", "open"].contains($0) }),
              i + 1 < n.count else { return nil }
        var start = i + 1
        while start < n.count, ["moi", "l", "la", "le", "app", "application", "the", "appli"].contains(n[start]) { start += 1 }
        guard start < n.count else { return nil }
        let name = r[start...].joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        return name.isEmpty ? nil : name
    }

    /// Same splits as IntentParser.normalise, original casing kept, one entry per word.
    static func rawWords(_ raw: String) -> [String] {
        var s = raw
        for c in ["'", "\u{2019}", "-"] { s = s.replacingOccurrences(of: c, with: " ") }
        return s.split(separator: " ").map(String.init).filter { w in
            !IntentParser.normalise(w).isEmpty
        }
    }
}

// MARK: - Snapshot (filled on the Mac side)

struct VoiceSnapshot {
    struct Payment { var amount: String; var description: String?; var ago: String; var succeeded: Bool }
    struct Stripe {
        var balance: String            // "1 240,00 €"
        var today: String?             // nil when the day total could not be fetched
        var todayCount: Int = 0
        var last: [Payment] = []
    }
    struct PR { var title: String; var repo: String; var ci: String; var review: String }
    struct GitHub {
        var stars: Int?; var repos: Int?
        var myPRs: [PR] = []; var toReview: Int = 0; var failingRepos: [String] = []
    }
    struct Deploy { var project: String; var state: String; var ago: String; var commit: String? }
    struct Session { var name: String; var state: String; var detail: String? }
    struct Plan { var fiveHourPct: Int?; var sevenDayPct: Int?; var resetsIn: String? }
    struct Booking { var title: String; var when: String; var with: String? }
    struct Weather {
        var city: String
        var nowTemp: Int?; var code: Int
        var min: Int; var max: Int; var rainChance: Int?; var wind: Int?
    }

    var configured: Bool = true          // false → "<service> n'est pas connecté"
    var stripe: Stripe?
    var github: GitHub?
    var deploys: [Deploy] = []
    var emailsTotal: Int?; var emails: [(to: String, subject: String, state: String)] = []
    var runs: [(workflow: String, ok: Bool, ago: String)] = []
    var pages: [(title: String, ago: String)] = []
    var bookings: [Booking] = []
    var sessions: [Session] = []
    var approvalPending: String?         // tool waiting for approval
    var plan: Plan?
    var nowPlaying: (title: String, artist: String?)?
    var mainPill: String?; var activePills: [String] = []
    var weather: Weather?
    var weatherOff = false               // feature disabled in Settings
    var weatherNoCity = false
}

// MARK: - Answers

enum VoiceAnswer {

    static func text(_ topic: VoiceTopic, _ s: VoiceSnapshot, french fr: Bool) -> String {
        func t(_ f: String, _ e: String) -> String { fr ? f : e }
        if !s.configured {
            return t("\(serviceName(topic)) n'est pas connecté dans les réglages de Coucou.",
                     "\(serviceName(topic)) isn't connected in Coucou's settings.")
        }
        switch topic {
        case .stripe:
            guard let st = s.stripe else { return t("Je n'ai pas encore les données Stripe.", "I don't have Stripe data yet.") }
            var out: String
            if let today = st.today {
                out = st.todayCount == 0
                    ? t("Aucune vente aujourd'hui pour l'instant.", "No sales yet today.")
                    : t("Aujourd'hui : \(today), \(st.todayCount) paiement\(st.todayCount > 1 ? "s" : "").",
                        "Today: \(today) from \(st.todayCount) payment\(st.todayCount > 1 ? "s" : "").")
                out += t(" Solde : \(st.balance).", " Balance: \(st.balance).")
            } else {
                out = t("Ton solde Stripe est de \(st.balance).", "Your Stripe balance is \(st.balance).")
                if let p = st.last.first {
                    out += t(" Dernier paiement : \(p.amount), il y a \(p.ago).", " Last payment: \(p.amount), \(p.ago) ago.")
                }
            }
            return out

        case .github:
            guard let g = s.github else { return t("Je n'ai pas encore les données GitHub.", "I don't have GitHub data yet.") }
            var parts: [String] = []
            if let stars = g.stars {
                let repos = g.repos.map { t(" sur \($0) repos", " across \($0) repos") } ?? ""
                parts.append(t("Tu as \(stars) étoile\(stars > 1 ? "s" : "")\(repos).", "You have \(stars) star\(stars == 1 ? "" : "s")\(repos)."))
            }
            if !g.myPRs.isEmpty {
                let red = g.myPRs.filter { $0.ci == "failure" }.count
                var p = t("\(g.myPRs.count) PR ouverte\(g.myPRs.count > 1 ? "s" : "")", "\(g.myPRs.count) open PR\(g.myPRs.count > 1 ? "s" : "")")
                if red > 0 { p += t(", dont \(red) avec la CI en échec", ", \(red) with failing CI") }
                parts.append(p + ".")
            }
            if g.toReview > 0 { parts.append(t("\(g.toReview) à relire.", "\(g.toReview) waiting for your review.")) }
            if let repo = g.failingRepos.first { parts.append(t("La CI de \(repo) est rouge.", "CI is red on \(repo).")) }
            return parts.isEmpty ? t("Rien de spécial sur GitHub.", "Nothing new on GitHub.") : parts.joined(separator: " ")

        case .vercel:
            guard let d = s.deploys.first else { return t("Aucun déploiement Vercel récent.", "No recent Vercel deployment.") }
            let ok = d.state == "READY"
            let state = ok ? t("est en ligne", "is live") : (d.state == "ERROR" ? t("a échoué", "failed")
                     : d.state == "CANCELED" ? t("a été annulé", "was canceled") : t("est en cours", "is in progress"))
            var out = t("Le dernier déploiement de \(d.project) \(state), il y a \(d.ago).",
                        "The last \(d.project) deployment \(state), \(d.ago) ago.")
            if !ok, let ready = s.deploys.dropFirst().first(where: { $0.state == "READY" }) {
                out += t(" Le précédent en ligne date de \(ready.ago).", " The previous live one is from \(ready.ago) ago.")
            }
            return out

        case .resend:
            if s.emails.isEmpty { return t("Aucun mail envoyé récemment avec Resend.", "No recent email sent with Resend.") }
            let e = s.emails[0]
            var out = s.emailsTotal.map { t("\($0) mails envoyés au total.", "\($0) emails sent in total.") } ?? ""
            out += t(" Le dernier, « \(e.subject) » à \(e.to) : \(e.state).", " Last one, “\(e.subject)” to \(e.to): \(e.state).")
            return out.trimmingCharacters(in: .whitespaces)

        case .n8n:
            guard let r = s.runs.first else { return t("Aucune exécution n8n récente.", "No recent n8n run.") }
            let failed = s.runs.filter { !$0.ok }.count
            var out = t("Dernier workflow : \(r.workflow), \(r.ok ? "réussi" : "en échec"), il y a \(r.ago).",
                        "Last workflow: \(r.workflow), \(r.ok ? "succeeded" : "failed"), \(r.ago) ago.")
            if failed > 0 && r.ok { out += t(" \(failed) échec\(failed > 1 ? "s" : "") récent\(failed > 1 ? "s" : "").", " \(failed) recent failure\(failed > 1 ? "s" : "").") }
            return out

        case .notion:
            guard let p = s.pages.first else { return t("Aucune page Notion récente.", "No recent Notion page.") }
            return t("Dernière page modifiée : \(p.title), il y a \(p.ago).", "Last edited page: \(p.title), \(p.ago) ago.")

        case .calcom:
            guard let b = s.bookings.first else { return t("Aucun rendez-vous à venir.", "No upcoming booking.") }
            let who = b.with.map { t(" avec \($0)", " with \($0)") } ?? ""
            var out = t("Prochain rendez-vous : \(b.title)\(who), \(b.when).", "Next booking: \(b.title)\(who), \(b.when).")
            if s.bookings.count > 1 { out += t(" \(s.bookings.count) au total.", " \(s.bookings.count) in total.") }
            return out

        case .agents:
            if let tool = s.approvalPending {
                return t("Une demande d'autorisation attend ton clic : \(tool).", "A permission request is waiting for your click: \(tool).")
            }
            let busy = s.sessions.filter { $0.state != "idle" && $0.state != "sleeping" }
            guard !busy.isEmpty else { return t("Aucun agent ne travaille en ce moment.", "No agent is working right now.") }
            return busy.prefix(3).map { a in
                let st = stateText(a.state, fr: fr)
                return a.detail.map { "\(a.name) \(st) : \($0)." } ?? "\(a.name) \(st)."
            }.joined(separator: " ")

        case .claudePlan, .codexPlan:
            let name = topic == .claudePlan ? "Claude" : "Codex"
            guard let p = s.plan, p.fiveHourPct != nil || p.sevenDayPct != nil else {
                return t("Je n'ai pas encore l'usage de ton plan \(name).", "I don't have your \(name) plan usage yet.")
            }
            var parts: [String] = []
            if let h = p.fiveHourPct { parts.append(t("\(h) % sur 5 heures", "\(h)% of the 5-hour window")) }
            if let w = p.sevenDayPct { parts.append(t("\(w) % sur la semaine", "\(w)% of the week")) }
            var out = t("Plan \(name) : ", "\(name) plan: ") + parts.joined(separator: t(" et ", " and ")) + "."
            if let r = p.resetsIn { out += t(" Remise à zéro dans \(r).", " Resets in \(r).") }
            return out

        case .music:
            guard let n = s.nowPlaying else { return t("Rien ne joue en ce moment.", "Nothing is playing right now.") }
            return n.artist.map { t("C'est \(n.title), de \($0).", "It's \(n.title) by \($0).") } ?? n.title

        case .pills:
            let main = s.mainPill.map { t("Pilule principale : \($0).", "Main pill: \($0).") } ?? ""
            let others = s.activePills.isEmpty ? t(" Aucune autre pilule.", " No other pill.")
                : t(" Actives : \(s.activePills.joined(separator: ", ")).", " Active: \(s.activePills.joined(separator: ", ")).")
            return (main + others).trimmingCharacters(in: .whitespaces)

        case .weatherToday, .weatherTomorrow:
            if s.weatherOff { return t("Active la météo dans les réglages de Coucou, section Voix.", "Turn on weather in Coucou's settings, Voice section.") }
            if s.weatherNoCity { return t("Indique ta ville dans les réglages de Coucou, section Voix.", "Set your city in Coucou's settings, Voice section.") }
            guard let w = s.weather else { return t("Je n'arrive pas à avoir la météo pour l'instant.", "I can't get the weather right now.") }
            let sky = weatherText(w.code, fr: fr)
            var out: String
            if topic == .weatherTomorrow {
                out = t("Demain à \(w.city) : \(sky), de \(w.min) à \(w.max) degrés.", "Tomorrow in \(w.city): \(sky), \(w.min) to \(w.max) degrees.")
            } else if let now = w.nowTemp {
                out = t("À \(w.city), \(now) degrés, \(sky). Entre \(w.min) et \(w.max) aujourd'hui.",
                        "In \(w.city), \(now) degrees, \(sky). Between \(w.min) and \(w.max) today.")
            } else {
                out = t("Aujourd'hui à \(w.city) : \(sky), de \(w.min) à \(w.max) degrés.", "Today in \(w.city): \(sky), \(w.min) to \(w.max) degrees.")
            }
            if let rain = w.rainChance, rain >= 30 { out += t(" \(rain) % de risque de pluie.", " \(rain)% chance of rain.") }
            return out
        }
    }

    static func serviceName(_ topic: VoiceTopic) -> String {
        switch topic {
        case .stripe:     return "Stripe"
        case .github:     return "GitHub"
        case .vercel:     return "Vercel"
        case .resend:     return "Resend"
        case .n8n:        return "n8n"
        case .notion:     return "Notion"
        case .calcom:     return "Cal.com"
        case .claudePlan: return "Claude"
        case .codexPlan:  return "Codex"
        case .agents:     return "Claude Code"
        case .music:      return "Music"
        case .pills:      return "Coucou"
        case .weatherToday, .weatherTomorrow: return "Météo"
        }
    }

    static func stateText(_ state: String, fr: Bool) -> String {
        switch state {
        case "working":   return fr ? "travaille" : "is working"
        case "thinking":  return fr ? "réfléchit" : "is thinking"
        case "searching": return fr ? "cherche" : "is searching"
        case "approval":  return fr ? "attend ton autorisation" : "is waiting for your approval"
        case "question":  return fr ? "te pose une question" : "has a question for you"
        case "error":     return fr ? "est en erreur" : "hit an error"
        case "finished":  return fr ? "a terminé" : "is done"
        case "ratelimit": return fr ? "a atteint sa limite" : "hit its rate limit"
        default:          return fr ? "est actif" : "is active"
        }
    }

    /// WMO weather codes (Open-Meteo).
    static func weatherText(_ code: Int, fr: Bool) -> String {
        switch code {
        case 0:            return fr ? "ciel dégagé" : "clear sky"
        case 1, 2:         return fr ? "quelques nuages" : "partly cloudy"
        case 3:            return fr ? "couvert" : "overcast"
        case 45, 48:       return fr ? "brouillard" : "fog"
        case 51, 53, 55, 56, 57: return fr ? "bruine" : "drizzle"
        case 61, 63, 66:   return fr ? "pluie" : "rain"
        case 65, 67:       return fr ? "forte pluie" : "heavy rain"
        case 71, 73, 75, 77: return fr ? "neige" : "snow"
        case 80, 81:       return fr ? "averses" : "showers"
        case 82:           return fr ? "fortes averses" : "heavy showers"
        case 85, 86:       return fr ? "averses de neige" : "snow showers"
        case 95, 96, 99:   return fr ? "orages" : "thunderstorms"
        default:           return fr ? "temps variable" : "mixed weather"
        }
    }
}
#endif
