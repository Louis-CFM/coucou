#if !APPSTORE
import Foundation

/// The languages Flow can translate into: speak in any language, the words are pasted in this one.
/// Regional variants are their own entries (British or American English, Swiss or Québec French…)
/// with what makes them different, so Claude writes the way people there write.
struct FlowLanguage: Identifiable, Hashable {
    let code: String
    /// What Claude is told on top of the language's name.
    let hint: String

    var id: String { code }

    /// "anglais (Royaume-Uni)", in the language of the Mac.
    var name: String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// "English (United Kingdom)", for Claude.
    var englishName: String {
        Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }
}

enum FlowLanguages {
    static let all: [FlowLanguage] = [
        // English
        .init(code: "en-US", hint: "American spelling and vocabulary (color, organize, apartment)."),
        .init(code: "en-GB", hint: "British spelling and vocabulary (colour, organise, flat)."),
        .init(code: "en-AU", hint: "Australian English: British spelling, Australian vocabulary."),
        .init(code: "en-CA", hint: "Canadian English: colour and centre, but organize."),
        .init(code: "en-IE", hint: "Irish English, British spelling."),
        .init(code: "en-NZ", hint: "New Zealand English, British spelling."),
        .init(code: "en-IN", hint: "Indian English, British spelling."),
        .init(code: "en-ZA", hint: "South African English, British spelling."),
        // French
        .init(code: "fr-FR", hint: "French as written in France."),
        .init(code: "fr-CA", hint: "Québec French: Québécois vocabulary where it is natural (courriel, magasiner, fin de semaine), still written French."),
        .init(code: "fr-CH", hint: "Swiss French: septante, huitante, nonante; déjeuner, dîner, souper."),
        .init(code: "fr-BE", hint: "Belgian French: septante, nonante."),
        // German
        .init(code: "de-DE", hint: "German as written in Germany."),
        .init(code: "de-CH", hint: "Swiss Standard German: never write ß, always ss; Swiss vocabulary where natural (Velo, parkieren)."),
        .init(code: "de-AT", hint: "Austrian German vocabulary where natural (Jänner, heuer)."),
        // Spanish
        .init(code: "es-ES", hint: "Spanish as written in Spain (vosotros)."),
        .init(code: "es-MX", hint: "Mexican Spanish (ustedes, Mexican vocabulary)."),
        .init(code: "es-AR", hint: "Rioplatense Spanish with voseo (vos tenés)."),
        .init(code: "es-CO", hint: "Colombian Spanish."),
        .init(code: "es-419", hint: "Neutral Latin American Spanish (ustedes)."),
        // Portuguese
        .init(code: "pt-BR", hint: "Brazilian Portuguese (você, Brazilian spelling)."),
        .init(code: "pt-PT", hint: "European Portuguese (tu, European spelling)."),
        // Italian
        .init(code: "it-IT", hint: "Italian as written in Italy."),
        .init(code: "it-CH", hint: "Swiss Italian."),
        // Dutch
        .init(code: "nl-NL", hint: "Dutch as written in the Netherlands."),
        .init(code: "nl-BE", hint: "Flemish (Belgian Dutch)."),
        // Chinese
        .init(code: "zh-Hans", hint: "Simplified Chinese, as written in mainland China."),
        .init(code: "zh-Hant", hint: "Traditional Chinese, as written in Taiwan."),
        .init(code: "zh-HK", hint: "Traditional Chinese, as written in Hong Kong."),
        // Others
        .init(code: "tr", hint: ""),
        .init(code: "ar", hint: "Modern Standard Arabic."),
        .init(code: "he", hint: ""),
        .init(code: "fa", hint: "Persian (Farsi)."),
        .init(code: "hi", hint: "Hindi in Devanagari script."),
        .init(code: "bn", hint: ""),
        .init(code: "ur", hint: ""),
        .init(code: "ta", hint: ""),
        .init(code: "te", hint: ""),
        .init(code: "mr", hint: ""),
        .init(code: "ja", hint: "Natural Japanese, polite form unless the speaker is casual."),
        .init(code: "ko", hint: "Natural Korean, polite form unless the speaker is casual."),
        .init(code: "th", hint: ""),
        .init(code: "vi", hint: ""),
        .init(code: "id", hint: ""),
        .init(code: "ms", hint: ""),
        .init(code: "fil", hint: "Filipino (Tagalog)."),
        .init(code: "ru", hint: ""),
        .init(code: "uk", hint: "Ukrainian."),
        .init(code: "pl", hint: ""),
        .init(code: "cs", hint: ""),
        .init(code: "sk", hint: ""),
        .init(code: "hu", hint: ""),
        .init(code: "ro", hint: ""),
        .init(code: "bg", hint: ""),
        .init(code: "el", hint: ""),
        .init(code: "hr", hint: ""),
        .init(code: "sr", hint: "Serbian in Cyrillic script."),
        .init(code: "sl", hint: ""),
        .init(code: "lt", hint: ""),
        .init(code: "lv", hint: ""),
        .init(code: "et", hint: ""),
        .init(code: "sv", hint: ""),
        .init(code: "da", hint: ""),
        .init(code: "nb", hint: "Norwegian Bokmål."),
        .init(code: "fi", hint: ""),
        .init(code: "is", hint: ""),
        .init(code: "ca", hint: "Catalan."),
        .init(code: "eu", hint: "Basque."),
        .init(code: "gl", hint: "Galician."),
        .init(code: "ga", hint: "Irish (Gaelic)."),
        .init(code: "cy", hint: "Welsh."),
        .init(code: "sw", hint: "Swahili."),
        .init(code: "af", hint: "Afrikaans."),
    ]

    /// Sorted by their name in the language of the Mac: the variants of a language end up together.
    static var sorted: [FlowLanguage] {
        all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func language(_ code: String) -> FlowLanguage? {
        all.first { $0.code == code }
    }
}
#endif
