// The languages Flow can translate into — generated from
// NotchBuddy/Sources/App/FlowLanguages.swift (codes and hints), English names
// from the Unicode CLDR through Intl.DisplayNames. Regional variants are their
// own entries, with what makes them different, so Claude writes the way people
// there write.

/// (code, English name for Claude, what Claude is told on top of the name).
pub const ALL: &[(&str, &str, &str)] = &[
    ("en-US", "American English", "American spelling and vocabulary (color, organize, apartment)."),
    ("en-GB", "British English", "British spelling and vocabulary (colour, organise, flat)."),
    ("en-AU", "Australian English", "Australian English: British spelling, Australian vocabulary."),
    ("en-CA", "Canadian English", "Canadian English: colour and centre, but organize."),
    ("en-IE", "English (Ireland)", "Irish English, British spelling."),
    ("en-NZ", "English (New Zealand)", "New Zealand English, British spelling."),
    ("en-IN", "English (India)", "Indian English, British spelling."),
    ("en-ZA", "English (South Africa)", "South African English, British spelling."),
    ("fr-FR", "French (France)", "French as written in France."),
    ("fr-CA", "Canadian French", "Québec French: Québécois vocabulary where it is natural (courriel, magasiner, fin de semaine), still written French."),
    ("fr-CH", "Swiss French", "Swiss French: septante, huitante, nonante; déjeuner, dîner, souper."),
    ("fr-BE", "French (Belgium)", "Belgian French: septante, nonante."),
    ("de-DE", "German (Germany)", "German as written in Germany."),
    ("de-CH", "Swiss High German", "Swiss Standard German: never write ß, always ss; Swiss vocabulary where natural (Velo, parkieren)."),
    ("de-AT", "Austrian German", "Austrian German vocabulary where natural (Jänner, heuer)."),
    ("es-ES", "European Spanish", "Spanish as written in Spain (vosotros)."),
    ("es-MX", "Mexican Spanish", "Mexican Spanish (ustedes, Mexican vocabulary)."),
    ("es-AR", "Spanish (Argentina)", "Rioplatense Spanish with voseo (vos tenés)."),
    ("es-CO", "Spanish (Colombia)", "Colombian Spanish."),
    ("es-419", "Latin American Spanish", "Neutral Latin American Spanish (ustedes)."),
    ("pt-BR", "Brazilian Portuguese", "Brazilian Portuguese (você, Brazilian spelling)."),
    ("pt-PT", "European Portuguese", "European Portuguese (tu, European spelling)."),
    ("it-IT", "Italian (Italy)", "Italian as written in Italy."),
    ("it-CH", "Italian (Switzerland)", "Swiss Italian."),
    ("nl-NL", "Dutch (Netherlands)", "Dutch as written in the Netherlands."),
    ("nl-BE", "Flemish", "Flemish (Belgian Dutch)."),
    ("zh-Hans", "Simplified Chinese", "Simplified Chinese, as written in mainland China."),
    ("zh-Hant", "Traditional Chinese", "Traditional Chinese, as written in Taiwan."),
    ("zh-HK", "Chinese (Hong Kong SAR China)", "Traditional Chinese, as written in Hong Kong."),
    ("tr", "Turkish", ""),
    ("ar", "Arabic", "Modern Standard Arabic."),
    ("he", "Hebrew", ""),
    ("fa", "Persian", "Persian (Farsi)."),
    ("hi", "Hindi", "Hindi in Devanagari script."),
    ("bn", "Bangla", ""),
    ("ur", "Urdu", ""),
    ("ta", "Tamil", ""),
    ("te", "Telugu", ""),
    ("mr", "Marathi", ""),
    ("ja", "Japanese", "Natural Japanese, polite form unless the speaker is casual."),
    ("ko", "Korean", "Natural Korean, polite form unless the speaker is casual."),
    ("th", "Thai", ""),
    ("vi", "Vietnamese", ""),
    ("id", "Indonesian", ""),
    ("ms", "Malay", ""),
    ("fil", "Filipino", "Filipino (Tagalog)."),
    ("ru", "Russian", ""),
    ("uk", "Ukrainian", "Ukrainian."),
    ("pl", "Polish", ""),
    ("cs", "Czech", ""),
    ("sk", "Slovak", ""),
    ("hu", "Hungarian", ""),
    ("ro", "Romanian", ""),
    ("bg", "Bulgarian", ""),
    ("el", "Greek", ""),
    ("hr", "Croatian", ""),
    ("sr", "Serbian", "Serbian in Cyrillic script."),
    ("sl", "Slovenian", ""),
    ("lt", "Lithuanian", ""),
    ("lv", "Latvian", ""),
    ("et", "Estonian", ""),
    ("sv", "Swedish", ""),
    ("da", "Danish", ""),
    ("nb", "Norwegian Bokmål", "Norwegian Bokmål."),
    ("fi", "Finnish", ""),
    ("is", "Icelandic", ""),
    ("ca", "Catalan", "Catalan."),
    ("eu", "Basque", "Basque."),
    ("gl", "Galician", "Galician."),
    ("ga", "Irish", "Irish (Gaelic)."),
    ("cy", "Welsh", "Welsh."),
    ("sw", "Swahili", "Swahili."),
    ("af", "Afrikaans", "Afrikaans."),
];

/// The language picked by its code, if it is one of Flow's: (English name, hint).
pub fn find(code: &str) -> Option<(&'static str, &'static str)> {
    ALL.iter().find(|(c, _, _)| *c == code).map(|(_, name, hint)| (*name, *hint))
}

/// Every code, for the picker (the page names them in the user's language).
pub fn codes() -> Vec<&'static str> {
    ALL.iter().map(|(c, _, _)| *c).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_macs_languages_are_all_here() {
        assert!(ALL.len() >= 60, "{}", ALL.len());
        assert_eq!(find("en-GB").map(|(n, _)| n), Some("British English"));
        assert!(find("fr-CH").unwrap().1.contains("septante"));
        assert!(find("xx").is_none());
        let mut seen = std::collections::HashSet::new();
        assert!(ALL.iter().all(|(c, _, _)| seen.insert(*c)), "no code twice");
    }
}
