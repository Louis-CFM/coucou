#if !APPSTORE
import Foundation

extension VoiceAnswer {
    /// Answer text in the chosen voice language. English and French go through the upstream
    /// `text(_:_:french:)`; Portuguese gets its own switch, so a new `VoiceTopic` breaks the build here.
    static func text(_ t: VoiceTopic, _ s: VoiceSnapshot, lang: VoiceLang) -> String {
        lang == .pt ? textPT(t, s) : text(t, s, french: lang == .fr)
    }

    // MARK: - Português (Brasil)

    private static func textPT(_ topic: VoiceTopic, _ s: VoiceSnapshot) -> String {
        if !s.configured {
            return "\(serviceNamePT(topic)): não conectado nos ajustes do Coucou."
        }
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }

        switch topic {
        case .stripe:
            guard let st = s.stripe else { return "Ainda não tenho os dados do Stripe." }
            var out: String
            if let today = st.today {
                out = st.todayCount == 0
                    ? "Nenhuma venda hoje por enquanto."
                    : "Hoje: \(today) em \(st.todayCount) \(plural(st.todayCount, "pagamento", "pagamentos"))."
                out += " Saldo: \(st.balance)."
            } else {
                out = "Seu saldo no Stripe é \(st.balance)."
                if let p = st.last.first { out += " Último pagamento: \(p.amount), há \(p.ago)." }
            }
            return out

        case .github:
            guard let g = s.github else { return "Ainda não tenho os dados do GitHub." }
            var parts: [String] = []
            if let stars = g.stars {
                let repos = g.repos.map { " em \($0) repositórios" } ?? ""
                parts.append("Você tem \(stars) \(plural(stars, "estrela", "estrelas"))\(repos).")
            }
            if !g.myPRs.isEmpty {
                let n = g.myPRs.count
                let red = g.myPRs.filter { $0.ci == "failure" }.count
                var p = "\(n) \(plural(n, "PR aberto", "PRs abertos"))"
                if red > 0 { p += ", \(red) com a CI falhando" }
                parts.append(p + ".")
            }
            if g.toReview > 0 { parts.append("\(g.toReview) esperando sua revisão.") }
            if let repo = g.failingRepos.first { parts.append("A CI do \(repo) está vermelha.") }
            return parts.isEmpty ? "Nada de novo no GitHub." : parts.joined(separator: " ")

        case .vercel:
            guard let d = s.deploys.first else { return "Nenhum deploy recente na Vercel." }
            let ok = d.state == "READY"
            let state = ok ? "está no ar" : (d.state == "ERROR" ? "falhou"
                     : d.state == "CANCELED" ? "foi cancelado" : "está em andamento")
            var out = "O último deploy de \(d.project) \(state), há \(d.ago)."
            if !ok, let ready = s.deploys.dropFirst().first(where: { $0.state == "READY" }) {
                out += " O último que está no ar foi há \(ready.ago)."
            }
            return out

        case .resend:
            if s.emails.isEmpty { return "Nenhum e-mail enviado recentemente pelo Resend." }
            let e = s.emails[0]
            var out = s.emailsTotal.map { "\($0) \(plural($0, "e-mail enviado", "e-mails enviados")) no total." } ?? ""
            out += " O último, “\(e.subject)” para \(e.to): \(e.state)."
            return out.trimmingCharacters(in: .whitespaces)

        case .n8n:
            guard let r = s.runs.first else { return "Nenhuma execução recente no n8n." }
            let failed = s.runs.filter { !$0.ok }.count
            var out = "Último workflow: \(r.workflow), \(r.ok ? "deu certo" : "falhou"), há \(r.ago)."
            if failed > 0 && r.ok { out += " \(failed) \(plural(failed, "falha recente", "falhas recentes"))." }
            return out

        case .notion:
            guard let p = s.pages.first else { return "Nenhuma página recente no Notion." }
            return "Última página editada: \(p.title), há \(p.ago)."

        case .calcom:
            guard let b = s.bookings.first else { return "Nenhuma reunião marcada." }
            let who = b.with.map { " com \($0)" } ?? ""
            var out = "Próxima reunião: \(b.title)\(who), \(b.when)."
            if s.bookings.count > 1 { out += " \(s.bookings.count) no total." }
            return out

        case .agents:
            if let tool = s.approvalPending { return "Um pedido de autorização está esperando seu clique: \(tool)." }
            let busy = s.sessions.filter { $0.state != "idle" && $0.state != "sleeping" }
            guard !busy.isEmpty else { return "Nenhum agente está trabalhando agora." }
            return busy.prefix(3).map { a in
                let st = stateTextPT(a.state)
                return a.detail.map { "\(a.name) \(st): \($0)." } ?? "\(a.name) \(st)."
            }.joined(separator: " ")

        case .claudePlan, .codexPlan:
            let name = topic == .claudePlan ? "Claude" : "Codex"
            guard let p = s.plan, p.fiveHourPct != nil || p.sevenDayPct != nil else {
                return "Ainda não tenho o uso do seu plano \(name)."
            }
            var parts: [String] = []
            if let h = p.fiveHourPct { parts.append("\(h)% da janela de 5 horas") }
            if let w = p.sevenDayPct { parts.append("\(w)% da semana") }
            var out = "Plano \(name): " + parts.joined(separator: " e ") + "."
            if let r = p.resetsIn { out += " Zera em \(r)." }
            return out

        case .music:
            guard let n = s.nowPlaying else { return "Nada está tocando agora." }
            return n.artist.map { "É \(n.title), de \($0)." } ?? n.title

        case .pills:
            let main = s.mainPill.map { "Pílula principal: \($0)." } ?? ""
            let others = s.activePills.isEmpty ? " Nenhuma outra pílula."
                : " Ativas: \(s.activePills.joined(separator: ", "))."
            return (main + others).trimmingCharacters(in: .whitespaces)

        case .weatherToday, .weatherTomorrow:
            if s.weatherOff { return "Ativa a previsão do tempo nos ajustes do Coucou, na seção Voz." }
            if s.weatherNoCity { return "Coloca sua cidade nos ajustes do Coucou, na seção Voz." }
            guard let w = s.weather else { return "Não consegui pegar a previsão do tempo agora." }
            let sky = weatherTextPT(w.code)
            var out: String
            if topic == .weatherTomorrow {
                out = "Amanhã em \(w.city): \(sky), de \(w.min) a \(w.max) graus."
            } else if let now = w.nowTemp {
                out = "Em \(w.city), \(now) graus, \(sky). Entre \(w.min) e \(w.max) hoje."
            } else {
                out = "Hoje em \(w.city): \(sky), de \(w.min) a \(w.max) graus."
            }
            if let rain = w.rainChance, rain >= 30 { out += " \(rain)% de chance de chuva." }
            return out
        }
    }

    static func serviceNamePT(_ topic: VoiceTopic) -> String {
        switch topic {
        case .music: return "Música"
        case .weatherToday, .weatherTomorrow: return "Tempo"
        default: return serviceName(topic)
        }
    }

    static func stateTextPT(_ state: String) -> String {
        switch state {
        case "working":   return "está trabalhando"
        case "thinking":  return "está pensando"
        case "searching": return "está procurando"
        case "approval":  return "está esperando sua autorização"
        case "question":  return "tem uma pergunta pra você"
        case "error":     return "deu erro"
        case "finished":  return "terminou"
        case "ratelimit": return "atingiu o limite"
        default:          return "está ativo"
        }
    }

    /// WMO weather codes (Open-Meteo).
    static func weatherTextPT(_ code: Int) -> String {
        switch code {
        case 0:            return "céu limpo"
        case 1, 2:         return "algumas nuvens"
        case 3:            return "nublado"
        case 45, 48:       return "neblina"
        case 51, 53, 55, 56, 57: return "garoa"
        case 61, 63, 66:   return "chuva"
        case 65, 67:       return "chuva forte"
        case 71, 73, 75, 77: return "neve"
        case 80, 81:       return "pancadas de chuva"
        case 82:           return "pancadas fortes"
        case 85, 86:       return "pancadas de neve"
        case 95, 96, 99:   return "tempestade"
        default:           return "tempo variável"
        }
    }
}
#endif
