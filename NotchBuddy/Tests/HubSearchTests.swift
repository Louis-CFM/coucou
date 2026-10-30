// HubSearchTests.swift: standalone test for the matching behind the Coucou window's search box.
// Run from the repo root:
//   swiftc -parse-as-library NotchBuddy/Sources/App/HubSearchCore.swift NotchBuddy/Tests/HubSearchTests.swift -o /tmp/hub-search-tests && /tmp/hub-search-tests

import Foundation

@main
struct HubSearchTests {
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        print(ok ? "ok   " : "FAIL ", what)
        if !ok { failures += 1 }
    }

    typealias C = HubSearchCandidate<String>

    // A little window, in Spanish, with the English names behind.
    static let candidates: [C] = [
        C(page: "general", names: ["General", "General"], text: "General", place: "Notch", find: nil),
        C(page: "voice", names: ["Voz", "Voice"], text: "Voz", place: "Notch", find: nil),
        C(page: "settings", names: ["Ajustes", "Settings"], text: "Ajustes", place: "Flow", find: nil),
        C(page: "general", names: ["Idioma", "Language"], text: "Idioma", place: "Notch · General", find: "Language"),
        C(page: "voice", names: ["Idioma", "Language"], text: "Idioma", place: "Notch · Voz", find: "Language"),
        C(page: "general", names: ["Abrir al pasar el ratón", "Open on hover"], text: "Abrir al pasar el ratón", place: "Notch · General", find: "Open on hover"),
        C(page: "settings", names: ["Mantener el historial", "Keep the history"], text: "Mantener el historial", place: "Flow · Ajustes", find: "hub.settings.keep"),
        C(page: "settings", names: ["Reglas de teclado", "Keyboard rules"], text: "Reglas de teclado", place: "Flow · Ajustes", find: "x"),
    ]

    static func found(_ query: String, in list: [C] = candidates) -> [String] {
        HubSearchCore.search(query, in: list).map { "\($0.page)/\($0.text)" }
    }

    static func main() {
        check(found("").isEmpty, "an empty query finds nothing")
        check(found("   ").isEmpty, "a query of spaces finds nothing")
        check(found("idioma") == ["general/Idioma", "voice/Idioma"], "the setting, once per page that has it, in order")
        check(found("language") == ["general/Idioma", "voice/Idioma"], "the English name finds it too")
        check(found("IDIOMA") == found("idioma"), "case is ignored")
        check(found("ajustes") == ["settings/Ajustes"], "a page by its name")
        check(found("raton") == ["general/Abrir al pasar el ratón"], "accents are ignored in the text")
        check(found("ratón") == found("raton"), "and in the query")
        check(found("historial mantener") == ["settings/Mantener el historial"], "every word, in any order")
        check(found("historial zzz").isEmpty, "a word that is nowhere finds nothing")
        check(found("keep history") == ["settings/Mantener el historial"], "words in English, in any order")
        // The name that starts with the query comes before the one that only has it in a later word.
        let ranked = [
            C(page: "b", names: ["Mostrar el reloj", "Show clock"], text: "Mostrar el reloj", place: "", find: "a"),
            C(page: "a", names: ["Reloj", "Clock"], text: "Reloj", place: "", find: "b"),
        ]
        check(found("reloj", in: ranked) == ["a/Reloj", "b/Mostrar el reloj"], "starts with the query first, then a word start")
        check(found("relo", in: ranked).first == "a/Reloj", "a part of a word counts")
        // 20 results at most.
        let many = (0..<50).map { C(page: "p", names: ["Ajuste \($0)", "Setting \($0)"], text: "Ajuste \($0)", place: "", find: nil) }
        check(HubSearchCore.search("ajuste", in: many).count == HubSearchCore.maxHits, "20 results at most")
        check(HubSearchCore.search("ajuste", in: many).first?.text == "Ajuste 0", "and in the order they were listed")
        // A page opens, a setting is underlined.
        check(HubSearchCore.search("ajustes", in: candidates).first?.find == nil, "a page has nothing to underline")
        check(HubSearchCore.search("historial", in: candidates).first?.find == "hub.settings.keep", "a setting says what to underline")
        print(failures == 0 ? "\nAll good." : "\n\(failures) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
