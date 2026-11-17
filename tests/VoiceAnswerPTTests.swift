// tests/VoiceAnswerPTTests.swift — spoken answers in Brazilian Portuguese, and en/fr unchanged through the lang: seam.
import Foundation

@main
struct VoiceAnswerPTTests {
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
    static func pt(_ t: VoiceTopic, _ s: VoiceSnapshot) -> String { VoiceAnswer.text(t, s, lang: .pt) }

    static func main() {
        // ── Stripe ────────────────────────────────────────────────────────────
        var s = VoiceSnapshot()
        s.stripe = .init(balance: "R$ 1.240,00", today: "R$ 320,00", todayCount: 4, last: [])
        check("stripe today", pt(.stripe, s), "Hoje: R$ 320,00 em 4 pagamentos. Saldo: R$ 1.240,00.")
        s.stripe = .init(balance: "R$ 1.240,00", today: "R$ 80,00", todayCount: 1, last: [])
        contains("stripe one payment", pt(.stripe, s), "em 1 pagamento.")
        s.stripe = .init(balance: "R$ 1.240,00", today: "R$ 0,00", todayCount: 0, last: [])
        contains("stripe no sale", pt(.stripe, s), "Nenhuma venda hoje")
        s.stripe = .init(balance: "R$ 1.240,00", today: nil, todayCount: 0,
                         last: [.init(amount: "R$ 50,00", description: nil, ago: "3 minutos", succeeded: true)])
        check("stripe balance only", pt(.stripe, s),
              "Seu saldo no Stripe é R$ 1.240,00. Último pagamento: R$ 50,00, há 3 minutos.")
        var empty = VoiceSnapshot()
        contains("stripe no data", pt(.stripe, empty), "Ainda não tenho os dados do Stripe")

        // ── GitHub ────────────────────────────────────────────────────────────
        s.github = .init(stars: 128, repos: 12,
                         myPRs: [.init(title: "a", repo: "r", ci: "failure", review: "pending"),
                                 .init(title: "b", repo: "r", ci: "success", review: "approved")],
                         toReview: 1, failingRepos: ["coucou"])
        let gh = pt(.github, s)
        contains("github stars", gh, "Você tem 128 estrelas em 12 repositórios.")
        contains("github PRs", gh, "2 PRs abertos, 1 com a CI falhando.")
        contains("github review", gh, "1 esperando sua revisão.")
        contains("github CI", gh, "A CI do coucou está vermelha.")
        s.github = .init(stars: 1, repos: nil, myPRs: [], toReview: 0, failingRepos: [])
        contains("github one star", pt(.github, s), "Você tem 1 estrela.")
        s.github = .init(stars: nil, repos: nil, myPRs: [], toReview: 0, failingRepos: [])
        check("github nothing", pt(.github, s), "Nada de novo no GitHub.")

        // ── Vercel ────────────────────────────────────────────────────────────
        s.deploys = [.init(project: "korus", state: "READY", ago: "3 minutos", commit: nil)]
        check("vercel live", pt(.vercel, s), "O último deploy de korus está no ar, há 3 minutos.")
        s.deploys = [.init(project: "korus", state: "ERROR", ago: "5 minutos", commit: nil),
                     .init(project: "korus", state: "READY", ago: "2 horas", commit: nil)]
        let vc = pt(.vercel, s)
        contains("vercel failed", vc, "korus falhou, há 5 minutos.")
        contains("vercel previous", vc, "O último que está no ar foi há 2 horas.")
        s.deploys = []
        contains("vercel none", pt(.vercel, s), "Nenhum deploy recente")

        // ── Resend, n8n, Notion, Cal.com ──────────────────────────────────────
        s.emailsTotal = 3
        s.emails = [(to: "tana@example.com", subject: "Imagem", state: "delivered")]
        check("resend", pt(.resend, s), "3 e-mails enviados no total. O último, “Imagem” para tana@example.com: delivered.")
        s.runs = [(workflow: "Backup", ok: true, ago: "10 minutos"), (workflow: "Sync", ok: false, ago: "1 hora")]
        check("n8n", pt(.n8n, s), "Último workflow: Backup, deu certo, há 10 minutos. 1 falha recente.")
        s.runs = [(workflow: "Sync", ok: false, ago: "1 hora")]
        contains("n8n failed", pt(.n8n, s), "falhou, há 1 hora.")
        s.pages = [(title: "Roadmap", ago: "2 horas")]
        check("notion", pt(.notion, s), "Última página editada: Roadmap, há 2 horas.")
        s.bookings = [.init(title: "Call", when: "amanhã às 10:00", with: "Ana"), .init(title: "Demo", when: "sexta", with: nil)]
        check("calcom", pt(.calcom, s), "Próxima reunião: Call com Ana, amanhã às 10:00. 2 no total.")
        s.bookings = []
        contains("calcom none", pt(.calcom, s), "Nenhuma reunião marcada")

        // ── Agents, plan ──────────────────────────────────────────────────────
        s.sessions = [.init(name: "Claude Code", state: "working", detail: "Edit IntentParser.swift"),
                      .init(name: "Codex", state: "thinking", detail: nil),
                      .init(name: "Gemini", state: "idle", detail: nil)]
        check("agents", pt(.agents, s), "Claude Code está trabalhando: Edit IntentParser.swift. Codex está pensando.")
        s.approvalPending = "Bash"
        contains("approval first", pt(.agents, s), "esperando seu clique: Bash")
        s.approvalPending = nil
        s.sessions = []
        contains("agents idle", pt(.agents, s), "Nenhum agente está trabalhando")
        s.plan = .init(fiveHourPct: 42, sevenDayPct: 18, resetsIn: "2 horas")
        check("claude plan", pt(.claudePlan, s),
              "Plano Claude: 42% da janela de 5 horas e 18% da semana. Zera em 2 horas.")
        contains("codex plan name", pt(.codexPlan, s), "Plano Codex:")
        s.plan = nil
        contains("plan none", pt(.claudePlan, s), "Ainda não tenho o uso do seu plano Claude")

        // ── Music, pills ──────────────────────────────────────────────────────
        s.nowPlaying = (title: "Garota de Ipanema", artist: "Tom Jobim")
        check("music", pt(.music, s), "É Garota de Ipanema, de Tom Jobim.")
        s.nowPlaying = nil
        check("music none", pt(.music, s), "Nada está tocando agora.")
        s.mainPill = "Claude"; s.activePills = ["GitHub", "Stripe"]
        check("pills", pt(.pills, s), "Pílula principal: Claude. Ativas: GitHub, Stripe.")
        s.activePills = []
        contains("pills none", pt(.pills, s), "Nenhuma outra pílula.")

        // ── Weather ───────────────────────────────────────────────────────────
        var w = VoiceSnapshot()
        w.weatherOff = true
        contains("weather off", pt(.weatherToday, w), "Ativa a previsão do tempo")
        w.weatherOff = false; w.weatherNoCity = true
        contains("weather no city", pt(.weatherToday, w), "Coloca sua cidade")
        w.weatherNoCity = false
        contains("weather unavailable", pt(.weatherToday, w), "Não consegui pegar a previsão")
        w.weather = .init(city: "São Paulo", nowTemp: 22, code: 61, min: 18, max: 25, rainChance: 70, wind: 12)
        check("weather tomorrow", pt(.weatherTomorrow, w),
              "Amanhã em São Paulo: chuva, de 18 a 25 graus. 70% de chance de chuva.")
        check("weather now", pt(.weatherToday, w),
              "Em São Paulo, 22 graus, chuva. Entre 18 e 25 hoje. 70% de chance de chuva.")
        w.weather = .init(city: "Recife", nowTemp: nil, code: 0, min: 24, max: 31, rainChance: 10, wind: nil)
        check("weather today no now", pt(.weatherToday, w), "Hoje em Recife: céu limpo, de 24 a 31 graus.")

        // ── Not connected ─────────────────────────────────────────────────────
        var off = VoiceSnapshot(); off.configured = false
        check("not connected", pt(.stripe, off), "Stripe: não conectado nos ajustes do Coucou.")
        check("not connected weather", pt(.weatherToday, off), "Tempo: não conectado nos ajustes do Coucou.")
        check("not connected music", pt(.music, off), "Música: não conectado nos ajustes do Coucou.")

        // ── Every topic has a Portuguese answer (a new topic breaks the exhaustive switch at compile time) ──
        let topics: [VoiceTopic] = [.stripe, .github, .vercel, .resend, .n8n, .notion, .calcom, .agents,
                                    .claudePlan, .codexPlan, .music, .pills, .weatherToday, .weatherTomorrow]
        for topic in topics {
            let text = pt(topic, empty)
            check("pt answer non-empty \(topic)", !text.isEmpty, true)
            check("pt answer differs from en \(topic)", text != VoiceAnswer.text(topic, empty, lang: .en), true)
        }
        empty.configured = false
        for topic in topics { check("pt not-connected \(topic)", pt(topic, empty).contains("não conectado"), true) }

        // ── WMO codes ─────────────────────────────────────────────────────────
        for (code, want) in [(0, "céu limpo"), (2, "algumas nuvens"), (3, "nublado"), (45, "neblina"), (53, "garoa"),
                             (63, "chuva"), (65, "chuva forte"), (73, "neve"), (81, "pancadas de chuva"),
                             (82, "pancadas fortes"), (86, "pancadas de neve"), (95, "tempestade"), (7, "tempo variável")] {
            check("wmo \(code)", VoiceAnswer.weatherTextPT(code), want)
        }
        for state in ["working", "thinking", "searching", "approval", "question", "error", "finished", "ratelimit", "x"] {
            check("state \(state) differs from en", VoiceAnswer.stateTextPT(state) != VoiceAnswer.stateText(state, fr: false), true)
        }

        // ── en and fr go through the unchanged upstream function ──────────────
        var f = VoiceSnapshot()
        f.stripe = .init(balance: "1 240,00 €", today: "85,00 €", todayCount: 2, last: [])
        check("fr same as french:true", VoiceAnswer.text(.stripe, f, lang: .fr), VoiceAnswer.text(.stripe, f, french: true))
        check("en same as french:false", VoiceAnswer.text(.stripe, f, lang: .en), VoiceAnswer.text(.stripe, f, french: false))
        contains("fr text", VoiceAnswer.text(.stripe, f, lang: .fr), "Aujourd'hui : 85,00 €, 2 paiements")
        contains("en text", VoiceAnswer.text(.stripe, f, lang: .en), "Today: 85,00 € from 2 payments")

        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }
}
