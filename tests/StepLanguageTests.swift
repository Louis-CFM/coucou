import Foundation

@main
struct StepLanguageTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print(ok ? "  ok  \(name)" : "  FAIL \(name)")
            if !ok { failures += 1 }
        }
        print("StepLanguage.choose")
        check("fr is French", StepLanguage.choose(preferred: ["fr-FR"], regionCode: "FR") == .french)
        check("en-US is French", StepLanguage.choose(preferred: ["en-US"], regionCode: "US") == .french)
        check("no info is French", StepLanguage.choose(preferred: [], regionCode: nil) == .french)
        check("pt-BR is Portuguese", StepLanguage.choose(preferred: ["pt-BR"], regionCode: "BR") == .portuguese)
        check("pt-PT is Portuguese", StepLanguage.choose(preferred: ["pt-PT", "en"], regionCode: "PT") == .portuguese)
        check("en-BR is Portuguese", StepLanguage.choose(preferred: ["en-BR"], regionCode: "BR") == .portuguese)
        check("region BR alone is Portuguese", StepLanguage.choose(preferred: ["en-US"], regionCode: "br") == .portuguese)
        check("pt only second is French", StepLanguage.choose(preferred: ["fr", "pt-BR"], regionCode: "FR") == .french)

        print("StepLanguage.choose with the app language")
        check("app pt wins over fr system", StepLanguage.choose(appLanguage: .portuguese, preferred: ["fr-FR"], regionCode: "FR") == .portuguese)
        check("app pt wins over en-US", StepLanguage.choose(appLanguage: .portuguese, preferred: ["en-US"], regionCode: "US") == .portuguese)
        check("app English with en-US system is French", StepLanguage.choose(appLanguage: .english, preferred: ["en-US"], regionCode: "US") == .french)
        check("app English follows region BR", StepLanguage.choose(appLanguage: .english, preferred: ["en-BR"], regionCode: "BR") == .portuguese)
        check("app English follows system pt", StepLanguage.choose(appLanguage: .english, preferred: ["pt-BR"], regionCode: "BR") == .portuguese)
        check("app English with fr system is French", StepLanguage.choose(appLanguage: .english, preferred: ["fr-FR"], regionCode: "FR") == .french)
        check("app system keeps the old rule", StepLanguage.choose(appLanguage: .system, preferred: ["pt-BR"], regionCode: "BR") == .portuguese)

        print("AppLanguage")
        check("no stored value is System", AppLanguage.from(appleLanguages: nil) == .system)
        check("empty is System", AppLanguage.from(appleLanguages: []) == .system)
        check("pt-BR is Portuguese", AppLanguage.from(appleLanguages: ["pt-BR"]) == .portuguese)
        check("pt-PT is Portuguese", AppLanguage.from(appleLanguages: ["pt-PT", "en"]) == .portuguese)
        check("en is English", AppLanguage.from(appleLanguages: ["en"]) == .english)
        check("en-US is English", AppLanguage.from(appleLanguages: ["en-US"]) == .english)
        check("fr is System", AppLanguage.from(appleLanguages: ["fr"]) == .system)
        check("System writes nothing", AppLanguage.system.appleLanguages == nil)
        check("English writes en", AppLanguage.english.appleLanguages == ["en"])
        check("Portuguese writes pt-BR", AppLanguage.portuguese.appleLanguages == ["pt-BR"])
        for l in AppLanguage.allCases {
            check("round trip \(l.rawValue)", AppLanguage.from(appleLanguages: l.appleLanguages) == l)
        }

        print("StepLanguage.label")
        let fr: [(String, String)] = [("Bash", "Exécute"), ("Read", "Lit"), ("Write", "Écrit"), ("Edit", "Modifie"),
            ("Glob", "Cherche"), ("Grep", "Recherche"), ("WebSearch", "Recherche web"), ("WebFetch", "Récupère"),
            ("TodoWrite", "Tâches"), ("Task", "Agent"), ("LS", "Liste"), ("MultiEdit", "Modifie"),
            ("NotebookEdit", "Notebook"), ("apply_patch", "Modifie"), ("update_plan", "Tâches"), ("spawn_agent", "Agent")]
        for (tool, want) in fr { check("fr \(tool)", StepLanguage.label(tool: tool, in: .french) == want) }
        let pt: [(String, String)] = [("Bash", "Executa"), ("Read", "Lê"), ("Write", "Escreve"), ("Edit", "Edita"),
            ("Glob", "Busca"), ("WebFetch", "Obtém"), ("TodoWrite", "Tarefas"), ("LS", "Lista")]
        for (tool, want) in pt { check("pt \(tool)", StepLanguage.label(tool: tool, in: .portuguese) == want) }
        check("unknown tool kept", StepLanguage.label(tool: "Foo", in: .portuguese) == "Foo")

        print("StepLanguage.bashVerb")
        check("fr cat", StepLanguage.bashVerb("cat a", in: .french) == "Lit")
        check("fr grep", StepLanguage.bashVerb("grep x", in: .french) == "Cherche")
        check("fr pytest", StepLanguage.bashVerb("pytest -q", in: .french) == "Teste")
        check("fr other", StepLanguage.bashVerb("make", in: .french) == "Exécute")
        check("pt cat", StepLanguage.bashVerb("cat a", in: .portuguese) == "Lê")
        check("pt rg", StepLanguage.bashVerb("rg x", in: .portuguese) == "Busca")
        check("pt swift test", StepLanguage.bashVerb("swift test", in: .portuguese) == "Testa")
        check("pt other", StepLanguage.bashVerb("make", in: .portuguese) == "Executa")

        print(failures == 0 ? "\nAll step language tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
