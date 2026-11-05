import Foundation

@main
struct DictationOrderTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok  \(name)" : "  FAIL \(name)")
            if !ok { failures += 1 }
        }

        // The recognizers this pretend Mac has: an id resolves to itself when supported, otherwise to the
        // same language's recognizer (en-BR → en-US), like MacDictation.match does.
        let supported = ["en-US", "en-GB", "pt-BR", "pt-PT", "fr-FR", "fr-CA", "es-ES"]
        func resolve(_ id: String) -> Locale? {
            let wanted = id.replacingOccurrences(of: "_", with: "-")
            if supported.contains(wanted) { return Locale(identifier: wanted) }
            let language = Locale(identifier: id).language.languageCode?.identifier
            return supported.first { Locale(identifier: $0).language.languageCode?.identifier == language }
                .map { Locale(identifier: $0) }
        }
        func order(listen: String, last: String? = nil, mac: [String] = [], keyboard: [String] = [],
                   app: [String] = []) -> [String] {
            // What MacDictation passes: the voice languages with their fallback locale, nil for anything else.
            let fallback = ["en": "en-US", "fr": "fr-FR", "pt": "pt-BR"]
            let chosen = fallback[listen].map { (language: listen, fallbackLocale: $0) }
            return DictationOrder.locales(chosen: chosen, lastHeard: last, mac: mac, keyboard: keyboard, app: app,
                                          max: 3, resolve: resolve).map(\.identifier)
        }

        print("dictation order")
        check("App Store build: no chosen language behaves like auto",
              DictationOrder.locales(chosen: nil, lastHeard: nil, mac: ["en-BR", "pt-BR"], keyboard: [], app: [],
                                     max: 3, resolve: resolve).map(\.identifier) == ["en-US", "pt-BR"])
        check("auto keeps today's order (Mac languages, then English)",
              order(listen: "auto", mac: ["en-BR", "pt-BR"]) == ["en-US", "pt-BR"])
        check("auto: last heard first, then Mac languages",
              order(listen: "auto", last: "pt-BR", mac: ["en-BR", "fr-FR"]) == ["pt-BR", "en-US", "fr-FR"])
        check("unknown value behaves like auto",
              order(listen: "xx", mac: ["fr-FR"]) == ["fr-FR", "en-US"])
        check("pt voice language puts pt-BR first on an en-BR, pt-BR Mac",
              order(listen: "pt", mac: ["en-BR", "pt-BR"]) == ["pt-BR", "en-US"])
        check("pt voice language beats the last winner",
              order(listen: "pt", last: "en-US", mac: ["en-BR", "pt-BR"]) == ["pt-BR", "en-US"])
        check("en voice language: en first, pt-BR second",
              order(listen: "en", mac: ["pt-BR"]) == ["en-US", "pt-BR"])
        check("fr voice language maps to fr-FR",
              order(listen: "fr", mac: ["en-US"]) == ["fr-FR", "en-US"])
        check("pt voice language keeps the Mac's pt-PT",
              order(listen: "pt", mac: ["pt-PT"]) == ["pt-PT", "en-US"])
        check("en voice language keeps en-GB (no en-US)",
              order(listen: "en", mac: ["en-GB"]) == ["en-GB"])
        check("fr voice language keeps fr-CA",
              order(listen: "fr", mac: ["fr-CA", "en-US"]) == ["fr-CA", "en-US"])
        check("one locale per language: duplicates collapse",
              order(listen: "pt", last: "pt-BR", mac: ["pt-BR", "pt-PT", "en-GB", "en-US"]) == ["pt-BR", "en-GB"])
        check("capped at three",
              order(listen: "pt", mac: ["en-BR", "fr-FR", "es-ES"], keyboard: ["es-ES"]) == ["pt-BR", "en-US", "fr-FR"])
        check("keyboard and app languages come after the Mac languages",
              order(listen: "auto", mac: ["fr-FR"], keyboard: ["es-ES"], app: ["pt-BR"]) == ["fr-FR", "es-ES", "pt-BR"])
        check("unsupported ids are skipped",
              order(listen: "pt", mac: ["zz-ZZ"]) == ["pt-BR", "en-US"])

        print(failures == 0 ? "All dictation order tests passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
