import Foundation

/// Language of the short activity steps shown in the island ticker ("Lit · file.swift").
/// Portuguese when the app language is Portuguese. Otherwise (System, or English since there is no
/// English table) Portuguese when the first preferred language is Portuguese or the region is Brazil,
/// French otherwise.
enum StepLanguage {
    case french, portuguese

    static func choose(appLanguage: AppLanguage = .system, preferred: [String], regionCode: String?) -> StepLanguage {
        if appLanguage == .portuguese { return .portuguese }
        if let first = preferred.first, first.lowercased().hasPrefix("pt") { return .portuguese }
        if regionCode?.uppercased() == "BR" { return .portuguese }
        return .french
    }

    static var current: StepLanguage {
        let app = AppLanguage.launched
        // With an explicit app language, Locale.preferredLanguages is that choice: read the system's own list.
        let preferred = app == .system ? Locale.preferredLanguages : systemPreferredLanguages
        return choose(appLanguage: app, preferred: preferred, regionCode: Locale.current.region?.identifier)
    }

    private static var systemPreferredLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
            ?? Locale.preferredLanguages
    }

    private static let frenchTable: [String: String] = [
        "Bash": "Exécute", "Read": "Lit", "Write": "Écrit", "Edit": "Modifie",
        "Glob": "Cherche", "Grep": "Recherche", "WebSearch": "Recherche web",
        "WebFetch": "Récupère", "TodoWrite": "Tâches", "Task": "Agent", "LS": "Liste",
        "MultiEdit": "Modifie", "NotebookEdit": "Notebook",
        "apply_patch": "Modifie", "update_plan": "Tâches", "spawn_agent": "Agent",
    ]

    private static let portugueseTable: [String: String] = [
        "Bash": "Executa", "Read": "Lê", "Write": "Escreve", "Edit": "Edita",
        "Glob": "Busca", "Grep": "Pesquisa", "WebSearch": "Pesquisa web",
        "WebFetch": "Obtém", "TodoWrite": "Tarefas", "Task": "Agente", "LS": "Lista",
        "MultiEdit": "Edita", "NotebookEdit": "Notebook",
        "apply_patch": "Edita", "update_plan": "Tarefas", "spawn_agent": "Agente",
    ]

    /// Label for a tool name, or the tool name itself when it has none.
    static func label(tool: String, in language: StepLanguage) -> String {
        let table = language == .portuguese ? portugueseTable : frenchTable
        return table[tool] ?? tool
    }

    /// Verb for a shell command's first word.
    static func bashVerb(_ command: String, in language: StepLanguage) -> String {
        let pt = language == .portuguese
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl": return pt ? "Lê" : "Lit"
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":    return pt ? "Busca" : "Cherche"
        default: break
        }
        let testRunners = ["pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test",
                           "xcodebuild test", "unittest"]
        if testRunners.contains(where: { command.contains($0) }) { return pt ? "Testa" : "Teste" }
        return pt ? "Executa" : "Exécute"
    }
}
