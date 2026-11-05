#if !APPSTORE
import Foundation

/// Brazilian Portuguese word tables for the voice parsers, written normalised (lowercase, no accents:
/// "proxima", "musica", "voce"). Upstream tables take them with `+ VoicePT.x`.
enum VoicePT {

    // `["a", "b"].union(VoicePT.x)` below builds a `Set<String>` straight from an upstream array literal.

    // MARK: - IntentParser: prefixes and fillers

    /// "voce pode", "eu quero que voce", "por favor"… (longest first, matched at the start).
    static let politenessPrefixes: [[String]] = [
        ["eu", "quero", "que", "voce"], ["eu", "queria", "que", "voce"], ["queria", "que", "voce"],
        ["tem", "como", "voce"], ["tem", "como"],
        ["voce", "poderia"], ["voce", "pode"], ["poderia"], ["pode"],
        ["por", "favor"],
    ]

    /// Spoken interjections dropped from the start of a phrase.
    static let interjections: Set<String> = [
        "obrigado", "obrigada", "valeu", "beleza", "entao", "tipo", "ne", "ahn", "hum", "opa",
        "ai", "sim", "pois", "e", "bom", "certo", "ei",
    ]

    /// Infinitives, subjunctives ("quero que voce adicione") and the 3rd person → the imperative trigger.
    static let infinitiveMap: [String: String] = [
        "adicionar": "adiciona", "adicione": "adiciona",
        "acrescentar": "acrescenta", "acrescente": "acrescenta",
        "incluir": "inclui", "inclua": "inclui",
        "colocar": "coloca", "coloque": "coloca", "botar": "coloca", "bote": "coloca",
        "tirar": "tira",
        "remover": "remove", "remova": "remove",
        "excluir": "exclui", "exclua": "exclui",
        "apagar": "apaga", "apague": "apaga",
        "tocar": "toca", "toque": "toca",
        "ativar": "ativa", "ative": "ativa",
        "desativar": "desativa", "desative": "desativa",
        "trocar": "troca", "troque": "troca",
        "substituir": "substitui", "substitua": "substitui",
        "mostrar": "mostra", "mostre": "mostra",
        "esconder": "esconde", "esconda": "esconde",
        "aumentar": "aumenta", "aumente": "aumenta",
        "abaixar": "abaixa", "abaixe": "abaixa",
        "baixar": "baixa",
        "diminuir": "diminui", "diminua": "diminui",
        "subir": "sobe", "suba": "sobe",
        "pausar": "pausa",
        "parar": "para", "pare": "para",
        "pular": "pula", "pule": "pula",
        "voltar": "volta", "volte": "volta",
        "abrir": "abre", "abra": "abre",
        "ligar": "liga", "ligue": "liga",
        "desligar": "desliga", "desligue": "desliga",
        "usar": "usa",
        "mudar": "muda", "mude": "muda",
        "deixar": "deixa", "deixe": "deixa",
        "manter": "mantem", "mantenha": "mantem",
        "continuar": "continua",
        "retomar": "retoma", "retome": "retoma",
    ]

    /// Possessives → definite article (like ma→la), so "minha playlist" reads "a playlist".
    static let possessives: [String: String] = [
        "meu": "o", "minha": "a", "meus": "os", "minhas": "as",
    ]

    /// Dropped from the end of a phrase ("… por favor", "… no lugar").
    static let trailingTails: [[String]] = [
        ["no", "lugar"], ["em", "vez", "disso"], ["por", "favor"], ["pra", "mim"], ["para", "mim"], ["ai"],
    ]

    // MARK: - IntentParser: music

    static let pausePrefixes: [[String]] = [
        ["pausa"], ["pausar"], ["para", "a", "musica"], ["para", "de", "tocar"], ["para", "de", "toca"], ["para", "a", "cancao"],
        ["desliga", "a", "musica"],
    ]

    static let nextPrefixes: [[String]] = [
        ["proxima"], ["proximo"], ["pula"], ["pular"], ["avanca"],
        ["passa", "a", "proxima"], ["passa", "a", "musica"],
    ]

    static let prevPrefixes: [[String]] = [
        ["anterior"], ["volta"], ["volta", "a", "musica"],
    ]

    static let volUpPrefixes: [[String]] = [
        ["aumenta", "o", "som"], ["aumenta", "o", "volume"], ["sobe", "o", "volume"], ["sobe", "o", "som"],
        ["mais", "alto"],
    ]

    static let volDownPrefixes: [[String]] = [
        ["abaixa", "o", "som"], ["abaixa", "o", "volume"], ["baixa", "o", "volume"], ["baixa", "o", "som"],
        ["diminui", "o", "volume"], ["diminui", "o", "som"], ["mais", "baixo"],
    ]

    static let playlistTriggers: [[String]] = [
        ["toca", "a", "playlist"], ["coloca", "a", "playlist"], ["bota", "a", "playlist"],
        ["liga", "a", "playlist"], ["toca", "playlist"], ["coloca", "playlist"],
    ]

    /// Verbs that put the playlist name before the word "playlist" ("toca a Focus playlist").
    static let playlistVerbs: [String] = ["toca", "coloca", "bota", "liga"]

    static let musicPillTriggers: [[String]] = [
        ["toca"], ["coloca"], ["bota"], ["liga"], ["poe"], ["retoma"],
    ]

    static let bareMusicVerbs: Set<String> = ["toca", "tocar", "continua", "retoma"]

    static let musicGenericWords: Set<String> = [
        "musica", "musicas", "som", "um som", "cancao", "cancoes", "algo", "alguma coisa", "qualquer coisa",
    ]

    static let playPrefixes: [[String]] = [
        ["toca", "musica"], ["toca", "uma", "musica"], ["coloca", "uma", "musica"], ["bota", "um", "som"],
        ["continua", "a", "musica"], ["retoma", "a", "musica"],
    ]

    /// "toca Drake no Spotify": the word before the music service.
    static let musicTargetPrepositions: [String] = ["no", "na", "pelo", "pela", "em"]

    // MARK: - IntentParser: pills

    static let pillMainTriggers: [[String]] = [
        ["muda", "para"], ["muda", "pra"], ["troca", "para"], ["troca", "pra"], ["usa", "o"], ["usa", "a"],
        ["coloca", "como", "principal"], ["bota", "como", "principal"], ["define", "como", "principal"],
    ]

    /// "a pilula principal PARA/PRA Cursor", "a principal E o Cursor".
    static let mainSeparators: [String] = ["para", "pra", "e"]

    /// Verbs stripped before the pill in "coloca o Cursor como principal".
    static let mainLeadVerbs: Set<String> = ["coloca", "bota", "usa", "deixa", "define", "muda", "poe", "liga"]

    static let pillAddOnlyTriggers: [[String]] = [
        ["adiciona"], ["ativa"], ["mostra"], ["inclui"], ["acrescenta"], ["eu", "quero"],
    ]

    static let pillRemoveTriggers: [[String]] = [
        ["tira"], ["desativa"], ["esconde"], ["apaga"], ["exclui"],
        ["nao", "preciso", "mais", "de"], ["nao", "preciso", "mais", "do"], ["nao", "preciso", "mais", "da"],
        ["nao", "precisa", "mais", "de"], ["nao", "precisa", "mais", "do"], ["nao", "precisa", "mais", "da"],
        ["nao", "quero", "mais"],
    ]

    static let replaceStarts: [[String]] = [["troca"], ["substitui"]]
    /// "troca o GitHub PELO Vercel", "substitui X POR Y".
    static let replaceSeparators: [String] = ["pelo", "pela", "pelos", "pelas", "por"]

    /// "coloca o Vercel NO LUGAR DO GitHub" → replace GitHub by Vercel.
    /// (Not "pelo": "troca A pelo B" reads old→new, the opposite of these markers.)
    static let insteadMarkers: [[String]] = [
        ["no", "lugar", "de"], ["no", "lugar", "do"], ["no", "lugar", "da"],
        ["em", "vez", "de"], ["em", "vez", "do"], ["em", "vez", "da"],
    ]
    static let insteadLeadVerbs: Set<String> = [
        "coloca", "bota", "poe", "adiciona", "ativa", "usa", "mostra", "inclui", "acrescenta", "liga",
    ]
    static let insteadNoise: Set<String> = ["o", "a", "os", "as", "um", "uma", "pilula", "pilulas"]

    static let onlyStarts: [[String]] = [
        ["deixa", "so"], ["deixa", "apenas"], ["mantem", "so"], ["mantem", "apenas"],
        ["so", "deixa"], ["so", "mantem"], ["fica", "so"],
    ]

    // MARK: - IntentParser: inline sets

    /// Dropped from the start of an entity name ("o GitHub", "a pilula", "uma playlist"). Only words that
    /// are not also English or French words, so "no doubt" or "as it was" keep their first word.
    static let articles: Set<String> = [
        "o", "os", "dos", "das", "uma", "nos", "nas",
        "meu", "minha", "meus", "minhas", "pilula", "pilulas",
    ]
    /// Articles that are also English words ("do", "no", "as", "um", "da", "na"): dropped only after one of
    /// the words above ("a pilula DO Stripe"), never as the first word of a name.
    static let articlesAfterArticle: Set<String> = ["a", "as", "do", "da", "um", "no", "na"]

    /// Joins between two actions or two pills ("adiciona X e depois tira Y").
    static let conjunctions: Set<String> = ["e", "depois", "entao"]

    /// Prepositions that open a trailing place ("… no notch", "… nas pilulas").
    static let locationPrepositions: Set<String> = ["no", "na", "nos", "nas"]
    static let places: Set<String> = ["pilulas", "pilula", "notch", "barra"]

    /// Action verbs that start a new action inside one sentence.
    static let segmentVerbs: Set<String> = [
        "adiciona", "adicionar", "acrescenta", "inclui", "coloca", "colocar", "bota", "botar",
        "tira", "tirar", "remove", "remover", "exclui", "apaga", "ativa", "ativar", "desativa", "desativar",
        "mostra", "esconde", "toca", "tocar", "troca", "substitui", "liga",
    ]

    // MARK: - VoiceQuery: topics

    /// Weather words clear enough on their own. Bare "tempo" is handled by `isWeather`.
    static let weatherWords: [String] = [
        "previsao", "vai chover", "chover", "chuva", "chovendo", "guarda chuva", "temperatura",
        "calor", "frio", "clima",
    ]
    /// "tempo" is weather ("como ta o tempo") unless it is time ("quanto tempo", "o tempo todo").
    static let notWeatherTempo: [String] = [
        "quanto tempo", "muito tempo", "pouco tempo", "tempo todo", "tempo de", "tempo real",
        "mesmo tempo", "tempo livre", "tempo que", "algum tempo", "um tempo", "tempo inteiro",
        "tempo of", "the tempo",
    ]
    /// `padded` is the normalised phrase with a space on each side.
    static func isWeather(_ padded: String) -> Bool {
        if weatherWords.contains(where: { padded.contains(" " + $0 + " ") }) { return true }
        guard padded.contains(" tempo ") else { return false }
        return !notWeatherTempo.contains(where: { padded.contains(" " + $0 + " ") })
    }

    static let tomorrow: [String] = ["amanha"]
    static let moneyWords: [String] = [
        "vendi", "vendeu", "vendas", "venda", "faturamento", "faturei", "receita", "dinheiro", "saldo",
        "pagamentos", "pagamento", "ganhei",
    ]
    static let githubWords: [String] = ["estrelas", "estrela", "repositorio", "repositorios"]
    static let vercelWords: [String] = ["deploys", "implantacao", "publicacao"]
    static let n8nWords: [String] = ["automacao", "automacoes"]
    static let calcomWords: [String] = [
        "reuniao", "reunioes", "agenda", "compromisso", "compromissos", "agendamento", "agendamentos",
    ]
    static let quotaWords: [String] = ["limite", "limites", "cota", "uso", "plano"]
    static let agentWords: [String] = [
        "agente", "agentes", "sessao", "sessoes", "o que esta acontecendo", "o que ta rolando",
        "o que esta rolando", "como esta indo", "como ta indo",
    ]
    static let musicWords: [String] = ["musica", "tocando", "cancao", "ouvindo", "faixa"]
    static let pillWords: [String] = ["pilula", "pilulas"]
    static let mailCountWords: [String] = [
        "quantos", "quantas", "ultimos", "ultimo", "enviados", "enviado", "enviei", "entregues",
    ]

    static let questionMarkers: [String] = [
        "quanto", "quantos", "quantas", "qual", "quais", "como", "o que", "me diz", "me mostra",
        "tem", "status", "esta",
    ]

    static let actionVerbs: Set<String> = [
        "adiciona", "adicionar", "adicione", "acrescenta", "inclui", "coloca", "colocar", "coloque",
        "bota", "botar", "tira", "tirar", "tire", "remover", "remova", "exclui", "apaga", "ativa", "ativar",
        "ative", "desativa", "desativar", "desative", "toca", "tocar", "toque", "troca", "trocar", "troque",
        "substitui", "esconde", "liga", "pausa", "manda", "mandar", "mande", "envia", "enviar", "envie",
        "escreve", "escrever", "escreva", "abre", "abrir", "abra",
    ]

    // MARK: - VoiceQuery: mail

    static let sendVerbs: Set<String> = [
        "manda", "mandar", "mande", "envia", "enviar", "envie", "escreve", "escrever", "escreva",
    ]
    static let mailWords: Set<String> = ["emeil"]
    static let fileWords: Set<String> = ["arquivo", "imagem", "foto", "documento", "print"]
    static let subjectMarkers: [String] = ["com o assunto", "assunto", "titulo"]
    static let bodyMarkers: [String] = [
        "dizendo que", "dizendo", "falando que", "falando", "com o texto", "o texto",
        "pra dizer que", "para dizer que", "pra dizer", "para dizer",
    ]
    static let instructionMarkers: Set<String> = [
        "dizendo que", "dizendo", "falando que", "falando", "pra dizer que", "para dizer que",
        "pra dizer", "para dizer",
    ]
    /// Words before the recipient: "manda um e-mail PRO Tana", "PARA O Tana".
    static let mailToWords: Set<String> = ["pro", "pra", "para"]
    static let mailArticles: Set<String> = ["o", "a", "os", "as"]
    /// Words between "imagem" and its file name.
    static let fileSkip: Set<String> = ["chamado", "chamada", "chama", "chamam", "nomeado", "nomeada", "o", "os", "as", "meu", "minha"]
    static let fileNamePrefixes: [[String]] = [["que", "se", "chama"], ["que", "chama"]]
    static let fileStop: Set<String> = ["do", "da", "dos", "das", "no", "na", "nos", "nas", "em", "pro", "pra", "para", "e", "pelo", "pela"]
    static let folderDocuments: Set<String> = ["documentos"]
    static let folderPictures: Set<String> = ["fotos", "imagens"]

    static let recipientLeads: [String] = [
        "manda pro", "manda pra", "manda para o", "manda para a", "pro", "pra", "para o", "para a", "para",
        "ele se chama", "ela se chama", "se chama", "o nome dele é", "o nome dela é", "o nome é",
        "é o", "é a", "é pro", "é pra", "meu amigo", "minha amiga", "meu colega", "minha colega",
    ]
    static let subjectNone: [String] = ["sem assunto", "nenhum assunto", "sem titulo", "nada", "sem nada"]
    static let subjectLeads: [String] = ["o assunto é", "o assunto", "assunto", "o titulo é", "titulo", "põe", "coloca", "escreve"]
    static let literalLeads: [String] = ["palavra por palavra", "texto exato", "o texto exato é", "escreve exatamente", "exatamente"]
    static let instructionLeads: [String] = [
        "diz pra ele que", "diz pra ela que", "diz que", "fala pra ele que", "fala pra ela que", "fala que",
        "avisa ele que", "avisa ela que", "avisa que", "manda dizer que", "tem que dizer que", "precisa dizer que",
        "escreve pra ele que", "escreve pra ela que", "escreve que", "escreve", "pra dizer que", "para dizer que",
        "dizendo que", "falando que", "a mensagem é", "a mensagem",
    ]
    static let freeTextLeads: [String] = ["você escreve", "voce escreve", "escreve", "escreva", "coloca"]

    // MARK: - VoiceQuery: web search

    static let webVerbs: Set<String> = [
        "pesquisa", "pesquisar", "pesquise", "procura", "procurar", "procure", "busca", "buscar", "busque", "ve", "olha",
    ]
    static let webHeads: [[String]] = [
        ["voce", "pode"], ["pode"], ["na", "internet"], ["no", "google"], ["pesquisa", "na", "internet"],
        ["pesquisa"], ["pesquisar"], ["procura"], ["procurar"], ["busca"], ["buscar"], ["ve"], ["olha"],
        ["sobre"], ["pra", "mim"],
    ]
    static let webTails: [[String]] = [
        ["na", "internet"], ["no", "google"], ["online"], ["por", "favor"], ["pra", "mim"], ["obrigado"], ["obrigada"],
    ]

    // MARK: - VoiceQuery: questions

    static let questionLeads: Set<String> = ["entao", "tipo", "opa", "ei", "mas", "e"]
    static let questionStarters: Set<String> = [
        "quem", "quando", "onde", "porque", "qual", "quais", "quanto", "quantos", "quantas", "como",
        "explica", "conta",
    ]
    static let questionPhrases: [String] = [
        "o que", "por que", "o que e", "me fala", "me conta", "me explica",
    ]
    static let questionRequests: [String] = ["voce pode", "pode", "voce poderia", "poderia"]

    // MARK: - VoiceQuery: open an app

    static let appVerbs: Set<String> = ["abre", "abrir", "abra"]
    static let appSkip: Set<String> = ["o", "a", "os", "as", "app", "aplicativo", "pra", "mim"]
}

extension Array where Element == String {
    /// Lets an upstream `Set<String>` table written as an array literal take the Portuguese words.
    func union(_ other: Set<String>) -> Set<String> { Set(self).union(other) }
}
#endif
