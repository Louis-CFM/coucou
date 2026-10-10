// tests/VoiceQueryTests.swift — questions, mail and app requests, spoken answers.
import Foundation

@main
struct VoiceQueryTests {
    nonisolated(unsafe) static var pass = 0
    nonisolated(unsafe) static var fail = 0

    static func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        if got == want { print("✓  \(label)"); pass += 1 }
        else { print("✗  \(label) — got \(got), want \(want)"); fail += 1 }
    }
    static func contains(_ label: String, _ text: String, _ part: String) {
        if text.contains(part) { print("✓  \(label)"); pass += 1 }
        else { print("✗  \(label) — \"\(text)\" has no \"\(part)\""); fail += 1 }
    }

    static func main() {
        let pills = PillFixture.available
        // ── Topics: Louis's own questions ─────────────────────────────────────
        let topics: [(String, VoiceTopic?)] = [
            ("Quel temps il fait aujourd'hui ?", .weatherToday),
            ("il va pleuvoir demain ?", .weatherTomorrow),
            ("météo", .weatherToday),
            ("Combien d'argent j'ai fait aujourd'hui sur Stripe ?", .stripe),
            ("combien j'ai vendu aujourd'hui", .stripe),
            ("Mon push Vercel, est-ce qu'il a été push ?", .vercel),
            ("est-ce que mon déploiement est passé", .vercel),
            ("Combien d'étoiles j'ai sur GitHub ?", .github),
            ("combien d'étoiles j'ai", .github),
            ("Qu'est-ce qui se passe sur mon Claude Code ?", .agents),
            ("il en est où Codex ?", .agents),
            ("il me reste combien sur mon plan Claude ?", .claudePlan),
            ("c'est quoi mon usage Codex", .codexPlan),
            ("j'ai des rendez-vous aujourd'hui ?", .calcom),
            ("c'est quoi cette chanson", .music),
            ("quelles pilules sont actives", .pills),
            ("how many stars do I have on GitHub?", .github),
            ("what's the weather like?", .weatherToday),
            // Commands stay commands
            ("est-ce que tu peux ajouter GitHub", nil),
            ("ajoute Stripe", nil),
            ("mets du Drake", nil),
            ("On s'en fout c'est", nil),
        ]
        for (phrase, want) in topics { check("topic «\(phrase)»", VoiceQuery.topic(of: phrase), want) }

        // ── Through the parser ────────────────────────────────────────────────
        check("parse stripe question", IntentParser.parse("Combien d'argent j'ai fait aujourd'hui sur Stripe ?", pills: pills), .query(.stripe))
        check("parse add stays add", IntentParser.parse("ajoute la pilule Stripe", pills: pills), .pillAdd(id: "integration_stripe"))

        // ── Mail ──────────────────────────────────────────────────────────────
        check("mail to Tana", VoiceQuery.mail(of: "Envoie un mail à Tana"),
              VoiceQuery.MailRequest(recipient: "Tana", file: nil, folder: nil))
        check("mail file from downloads", VoiceQuery.mail(of: "envoie le fichier facture octobre des téléchargements à Tana"),
              VoiceQuery.MailRequest(recipient: "Tana", file: "facture octobre", folder: .downloads))
        check("mail file from desktop", VoiceQuery.mail(of: "envoie le fichier devis du bureau à Paul Martin"),
              VoiceQuery.MailRequest(recipient: "Paul Martin", file: "devis", folder: .desktop))
        check("send an email to", VoiceQuery.mail(of: "send an email to Tana"),
              VoiceQuery.MailRequest(recipient: "Tana", file: nil, folder: nil))
        check("not a mail", VoiceQuery.mail(of: "envoie la musique"), nil)
        check("parse mail", IntentParser.parse("Envoie un mail à Intel", pills: pills),
              .mail(VoiceQuery.MailRequest(recipient: "Intel", file: nil, folder: nil)))

        // ── Apps ──────────────────────────────────────────────────────────────
        check("ouvre Figma", VoiceQuery.appToOpen("ouvre Figma"), "Figma")
        check("ouvre l'app Notes", VoiceQuery.appToOpen("ouvre l'app Notes"), "Notes")
        check("open Safari", VoiceQuery.appToOpen("open Safari"), "Safari")
        check("parse open app", IntentParser.parse("ouvre Figma", pills: pills), .openApp(name: "Figma"))

        // ── Answers ───────────────────────────────────────────────────────────
        var s = VoiceSnapshot()
        s.stripe = .init(balance: "1 240,00 €", today: "85,00 €", todayCount: 2, last: [])
        contains("stripe today fr", VoiceAnswer.text(.stripe, s, french: true), "Aujourd'hui : 85,00 €, 2 paiements")
        s.stripe = .init(balance: "1 240,00 €", today: "0,00 €", todayCount: 0, last: [])
        contains("stripe no sale", VoiceAnswer.text(.stripe, s, french: true), "Aucune vente aujourd'hui")
        s.github = .init(stars: 128, repos: 12,
                         myPRs: [.init(title: "a", repo: "r", ci: "failure", review: "pending"),
                                 .init(title: "b", repo: "r", ci: "success", review: "approved")],
                         toReview: 1, failingRepos: [])
        let gh = VoiceAnswer.text(.github, s, french: true)
        contains("github stars", gh, "128 étoiles sur 12 repos")
        contains("github red CI", gh, "dont 1 avec la CI en échec")
        s.deploys = [.init(project: "korus", state: "ERROR", ago: "5 minutes", commit: nil),
                     .init(project: "korus", state: "READY", ago: "2 heures", commit: nil)]
        contains("vercel failed", VoiceAnswer.text(.vercel, s, french: true), "korus a échoué, il y a 5 minutes")
        s.sessions = [.init(name: "Claude Code", state: "working", detail: "Edit IntentParser.swift")]
        contains("agents", VoiceAnswer.text(.agents, s, french: true), "Claude Code travaille : Edit IntentParser.swift")
        s.approvalPending = "Bash"
        contains("approval first", VoiceAnswer.text(.agents, s, french: true), "autorisation attend ton clic : Bash")
        var off = VoiceSnapshot(); off.configured = false
        contains("not configured", VoiceAnswer.text(.stripe, off, french: true), "Stripe n'est pas connecté")
        var w = VoiceSnapshot()
        w.weatherOff = true
        contains("weather off", VoiceAnswer.text(.weatherToday, w, french: true), "Active la météo")
        w.weatherOff = false
        w.weather = .init(city: "Bordeaux", nowTemp: 17, code: 61, min: 12, max: 19, rainChance: 70, wind: 20)
        let wt = VoiceAnswer.text(.weatherToday, w, french: true)
        contains("weather now", wt, "À Bordeaux, 17 degrés, pluie")
        contains("weather rain", wt, "70 % de risque de pluie")
        contains("weather en", VoiceAnswer.text(.weatherTomorrow, w, french: false), "Tomorrow in Bordeaux: rain, 12 to 19 degrees")
        check("wmo 0", VoiceAnswer.weatherText(0, fr: true), "ciel dégagé")
        check("wmo 95", VoiceAnswer.weatherText(95, fr: false), "thunderstorms")

        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }
}
