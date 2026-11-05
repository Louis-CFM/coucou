#if !APPSTORE
import Foundation

// MARK: - VoiceLang

/// The languages Coucou can answer in by voice. Stored codes stay short ("en", "fr", "pt").
enum VoiceLang: String, CaseIterable {
    case en, fr, pt

    /// "pt", "pt-BR", "pt_BR" → .pt; "fr-FR" → .fr; anything else → .en.
    init(code: String) {
        let first = code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        self = VoiceLang(rawValue: first) ?? .en
    }

    init(locale: Locale?) {
        self = VoiceLang(code: locale?.identifier ?? "")
    }

    /// Locale for speech, recognition and catalog lookups.
    var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en-US")
        case .fr: return Locale(identifier: "fr-FR")
        case .pt: return Locale(identifier: "pt-BR")
        }
    }

    /// Locale for numbers, money and dates.
    var formatLocale: Locale {
        switch self {
        case .en: return Locale(identifier: "en_US")
        case .fr: return Locale(identifier: "fr_FR")
        case .pt: return Locale(identifier: "pt_BR")
        }
    }

    /// Name used in prompts ("answer in …").
    var englishName: String {
        switch self {
        case .en: return "English"
        case .fr: return "French"
        case .pt: return "Brazilian Portuguese"
        }
    }

    /// Answer language when nothing is stored: Portuguese when the app language is Portuguese, the first
    /// preferred language is Portuguese, or the region is Brazil on a Mac whose first language is not
    /// English or French. English otherwise (an English or French Mac in Brazil keeps answering as before).
    static func defaultCode(appPortuguese: Bool, preferred: [String], region: String?) -> String {
        if appPortuguese { return "pt" }
        if let first = preferred.first, first.lowercased().hasPrefix("pt") { return "pt" }
        if let first = preferred.first?.lowercased(), first.hasPrefix("en") || first.hasPrefix("fr") { return "en" }
        if region?.uppercased() == "BR" { return "pt" }
        return "en"
    }

    /// Guesses the language a sentence is written in, by counting stop-words. English wins ties
    /// and sentences with no recognisable word; French must beat English, Portuguese must beat both and match at least two of its own words.
    static func detect(_ text: String) -> VoiceLang {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split(whereSeparator: { !$0.isLetter }).map(String.init)
        let f = words.filter { frenchWords.contains($0) }.count
        let e = words.filter { englishWords.contains($0) }.count
        let p = words.filter { portugueseWords.contains($0) }.count
        if p >= 2 && p > f && p > e { return .pt }
        if f > e && f >= p { return .fr }
        return .en
    }

    /// True for a (diacritic-folded, lowercase) word that marks Portuguese.
    static func isPortugueseWord(_ w: String) -> Bool { portugueseWords.contains(w) }

    private static let frenchWords: Set<String> = [
        "le", "la", "les", "l", "que", "qu", "est", "sont", "de", "des", "du", "pour", "je", "tu",
        "il", "elle", "nous", "vous", "un", "une", "et", "a", "au", "avec", "pas", "prete", "pret",
        "merci", "demain", "hier", "bien", "c", "ce", "sa", "son", "ton", "ta", "mon", "ma"]
    private static let englishWords: Set<String> = [
        "the", "is", "are", "that", "to", "of", "for", "i", "you", "he", "she", "we", "and",
        "with", "not", "ready", "thanks", "thank", "tomorrow", "yesterday", "it", "my", "your"]
    /// Words that mark Portuguese. Left out: words that are also English or French ("a", "de", "que",
    /// "as", "do", "no", "nos", "e"; "e" is also a token of "e-mail").
    private static let portugueseWords: Set<String> = [
        "o", "os", "um", "uma", "da", "dos", "das", "em", "na", "para", "pra", "pro", "com",
        "nao", "voce", "eu", "esta", "estao", "pronto", "pronta", "obrigado", "obrigada", "amanha", "ontem",
        "meu", "minha", "seu", "sua", "isso", "ele", "ela", "muito", "tambem", "imagem"]
}
#endif
