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
        check("guided mail (no recipient)", VoiceQuery.mail(of: "envoie un mail"),
              VoiceQuery.MailRequest(recipient: "", file: nil, folder: nil))
        check("guided mail EN", VoiceQuery.mail(of: "send an email"),
              VoiceQuery.MailRequest(recipient: "", file: nil, folder: nil))
        check("recipient answer", VoiceQuery.recipientAnswer("c'est Tana"), "Tana")
        check("recipient spoken email", VoiceQuery.recipientAnswer("tana arobase gmail point com"), "tana@gmail.com")
        check("subject answer", VoiceQuery.subjectAnswer("l'objet c'est Voilà votre image"), "Voilà votre image")
        check("no subject", VoiceQuery.subjectAnswer("pas d'objet"), "")
        check("body verbatim only on request", VoiceQuery.bodyAnswer("mot pour mot : Image en 1980 par 1080").body, "Image en 1980 par 1080")
        check("body plain answer is drafted", VoiceQuery.bodyAnswer("Image en 1980 par 1080").instruction, "Image en 1980 par 1080")
        check("body faut dire que", VoiceQuery.bodyAnswer("Faut dire que l'image est prête").instruction, "l'image est prête")
        check("body faut dire → no literal", VoiceQuery.bodyAnswer("Faut dire que l'image est prête").body, nil)
        check("body tell her", VoiceQuery.bodyAnswer("tell her that the file is ready").instruction, "the file is ready")
        check("simple mail fr", VoiceQuery.simpleMail(from: "faut dire que l'image est prête"), "Bonjour,\n\nL'image est prête.\n\nBonne journée !")
        check("simple mail en", VoiceQuery.simpleMail(from: "the file is ready"), "Hi,\n\nThe file is ready.\n\nBest,")
        check("looks French", VoiceQuery.looksFrench("l'image est prête"), true)
        check("looks English", VoiceQuery.looksFrench("the image is ready"), false)
        check("mail pour lui dire → drafted", VoiceQuery.mail(of: "envoie un mail à Tana pour lui dire que l'image est prête")?.instruction, "l'image est prête")
        check("mail description → literal", VoiceQuery.mail(of: "envoie un mail à Tana avec le texte rendez-vous demain")?.body, "rendez-vous demain")
        check("body draft", VoiceQuery.bodyAnswer("écris-lui que je serai en retard").instruction, "je serai en retard")
        check("attachment name", VoiceQuery.attachmentAnswer("oui, Goku point png"), "Goku.png")
        // Louis's example, as dictated
        check("Goku mail", VoiceQuery.mail(of: "Il y a une image qui s'appelle Goku.png. J'aimerais que tu la prennes et que tu l'envoies par mail à tana@gmail.com. En objet, tu écris : Voilà votre image. En description, tu écris : Image en 1980 × 1080."),
              VoiceQuery.MailRequest(recipient: "tana@gmail.com", file: "Goku.png", folder: nil,
                                     subject: "Voilà votre image", body: "Image en 1980 × 1080"))
        check("Goku mail EN", VoiceQuery.mail(of: "email the image called Goku.png to tana@gmail.com, subject Here is your image, body Image in 1980 by 1080"),
              VoiceQuery.MailRequest(recipient: "tana@gmail.com", file: "Goku.png", folder: nil,
                                     subject: "Here is your image", body: "Image in 1980 by 1080"))
        check("spoken address", VoiceQuery.mail(of: "envoie un mail à tana arobase gmail point com"),
              VoiceQuery.MailRequest(recipient: "tana@gmail.com", file: nil, folder: nil))
        check("spoken address EN", VoiceQuery.spokenEmail("tana at gmail dot com"), "tana@gmail.com")
        check("file point png", VoiceQuery.mail(of: "envoie l'image goku point png à Tana")?.file, "goku.png")
        check("draft instruction", VoiceQuery.mail(of: "write an email to Tana thanking her for yesterday"),
              VoiceQuery.MailRequest(recipient: "Tana", file: nil, folder: nil, instruction: "thanking her for yesterday"))
        check("écris un mail = command", VoiceQuery.topic(of: "tu peux écrire un mail à Tana"), nil)
        check("parse écris un mail", IntentParser.parse("tu peux écrire un mail à Tana", pills: pills),
              .mail(VoiceQuery.MailRequest(recipient: "Tana", file: nil, folder: nil)))
        check("resend stats still work", VoiceQuery.topic(of: "combien de mails j'ai envoyé ?"), .resend)
        check("VS Code question", VoiceQuery.topic(of: "qu'est-ce qui se passe sur VS Code ?"), .agents)
        check("parse mail", IntentParser.parse("Envoie un mail à Intel", pills: pills),
              .mail(VoiceQuery.MailRequest(recipient: "Intel", file: nil, folder: nil)))

        // ── Apps ──────────────────────────────────────────────────────────────
        check("ouvre Figma", VoiceQuery.appToOpen("ouvre Figma"), "Figma")
        check("ouvre l'app Notes", VoiceQuery.appToOpen("ouvre l'app Notes"), "Notes")
        check("open Safari", VoiceQuery.appToOpen("open Safari"), "Safari")
        check("parse open app", IntentParser.parse("ouvre Figma", pills: pills), .openApp(name: "Figma"))

        // Guided mail: names and repeats
        check("recipient il s'appelle", VoiceQuery.recipientAnswer("Il s'appelle Enzo"), "Enzo")
        check("recipient son nom c'est", VoiceQuery.recipientAnswer("son nom c'est Enzo Martin"), "Enzo Martin")
        check("recipient his name is", VoiceQuery.recipientAnswer("his name is Paul"), "Paul")
        check("contact candidates", VoiceQuery.contactCandidates("mon pote Enzo"), ["mon pote Enzo", "Enzo"])
        check("collapse repeat", VoiceQuery.collapseRepeat("image image"), "image")
        check("collapse repeat two words", VoiceQuery.collapseRepeat("Voilà l'image voilà l'image"), "Voilà l'image")
        check("no collapse", VoiceQuery.collapseRepeat("bonjour Enzo"), "bonjour Enzo")

        // Web search
        check("web fr lead", VoiceQuery.webQuery(of: "cherche sur internet qui a gagné l'Euro"), "qui a gagné l'Euro")
        check("web fr tail", VoiceQuery.webQuery(of: "Cherche les horaires du Louvre sur internet"), "les horaires du Louvre")
        check("web fr recherche", VoiceQuery.webQuery(of: "fais une recherche internet sur Tesla"), "Tesla")
        check("web fr peux-tu", VoiceQuery.webQuery(of: "Est-ce que tu peux chercher sur le web le prix de l'iPhone 17 ?"), "le prix de l'iPhone 17")
        check("web en", VoiceQuery.webQuery(of: "search the web for the latest Apple news"), "the latest Apple news")
        check("web en look up", VoiceQuery.webQuery(of: "can you look up who won the Champions League"), "who won the Champions League")
        check("web google", VoiceQuery.webQuery(of: "Google the weather in Tokyo"), "the weather in Tokyo")
        check("web nothing after", VoiceQuery.webQuery(of: "cherche sur internet"), "")
        check("web not: open Google Chrome", VoiceQuery.webQuery(of: "ouvre Google Chrome"), nil)
        check("web not: plain search", VoiceQuery.webQuery(of: "cherche Daft Punk"), nil)
        check("parse web", IntentParser.parse("cherche sur internet la météo à Tokyo", pills: pills),
              .webSearch(query: "la météo à Tokyo"))
        check("question fr qui", VoiceQuery.looksLikeQuestion("qui a gagné le match hier"), true)
        check("question fr c'est quoi", VoiceQuery.looksLikeQuestion("c'est quoi un trou noir"), true)
        check("question fr et", VoiceQuery.looksLikeQuestion("et à Paris ?"), true)
        check("question en", VoiceQuery.looksLikeQuestion("what's the capital of Australia"), true)
        check("question en how", VoiceQuery.looksLikeQuestion("how tall is the Eiffel Tower"), true)
        check("not a question: request", VoiceQuery.looksLikeQuestion("tu peux mettre de la musique ?"), false)
        check("not a question: can you", VoiceQuery.looksLikeQuestion("can you play something chill"), false)
        check("not a question: command", VoiceQuery.looksLikeQuestion("mets du Daft Punk"), false)
        check("spoken markdown", VoiceQuery.spokenText("**Spain** won [the Euro](https://uefa.com) [1].\n- Final: 2-1"),
              "Spain won the Euro. Final: 2-1")
        check("spoken url", VoiceQuery.spokenText("See https://example.com for more."), "See for more.")

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
