import Foundation

/// The order of the languages the notch chat's dictation listens for in Automatic mode. Pure and
/// free of any Voice code, so both builds (and the unit test) compile it.
enum DictationOrder {
    /// The locales Automatic listens with, best first, one per language, up to `max`.
    /// `chosen` is the language picked for the voice assistant (GitHub build only; nil = none, which
    /// is the App Store build's behaviour): its language code ("en", "fr", "pt") and the locale to
    /// use when none of the user's languages matches (en-US, fr-FR, pt-BR). It goes first, in the
    /// user's own regional variant when they have one (pt-PT, en-GB, fr-CA), so a Portuguese speaker
    /// is heard in Portuguese before the Mac's English; then come the last winner, the Mac languages,
    /// keyboard layouts and Coucou's own language, then English.
    /// `resolve` turns an id into the recognizer locale the Mac supports (nil when it has none).
    static func locales(chosen: (language: String, fallbackLocale: String)?, lastHeard: String?,
                        mac: [String], keyboard: [String], app: [String], max: Int,
                        resolve: (String) -> Locale?) -> [Locale] {
        var ids: [String] = []
        if let lastHeard { ids.append(lastHeard) }
        ids += mac + keyboard + app
        if let chosen {
            let first = ids.first { Locale(identifier: $0).language.languageCode?.identifier == chosen.language }
            ids.insert(first ?? chosen.fallbackLocale, at: 0)
        }
        ids.append("en-US")
        var seen = Set<String>()
        var out: [Locale] = []
        for id in ids {
            guard let locale = resolve(id) else { continue }
            let language = locale.language.languageCode?.identifier ?? locale.identifier
            guard seen.insert(language).inserted else { continue }
            out.append(locale)
            if out.count == max { break }
        }
        return out
    }
}
