import Foundation

/// Language the app shows. System follows macOS; English and Português (Brasil)
/// write the standard per-app AppleLanguages preference, which AppKit reads at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, portuguese

    var id: String { rawValue }

    static let defaultsKey = "AppleLanguages"

    /// Value written to the per-app AppleLanguages preference (nil removes it).
    var appleLanguages: [String]? {
        switch self {
        case .system:     return nil
        case .english:    return ["en"]
        case .portuguese: return ["pt-BR"]
        }
    }

    /// Choice a stored AppleLanguages array stands for. Anything else is System.
    static func from(appleLanguages: [String]?) -> AppLanguage {
        guard let first = appleLanguages?.first?.lowercased() else { return .system }
        if first.hasPrefix("pt") { return .portuguese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    /// AppleLanguages as the app itself stored it (not the one inherited from the system).
    static var storedAppleLanguages: [String]? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return UserDefaults.standard.persistentDomain(forName: id)?[defaultsKey] as? [String]
    }

    static var stored: AppLanguage { from(appleLanguages: storedAppleLanguages) }

    /// The choice in force since launch (AppKit reads it once). Touched at launch so a later change
    /// in Settings does not move it.
    static let launched: AppLanguage = stored

    /// True when the app shows Portuguese (the language AppKit picked at launch).
    static var isPortugueseUI: Bool {
        Bundle.main.preferredLocalizations.first?.lowercased().hasPrefix("pt") == true
    }

    /// Writes the choice. AppKit only reads it at launch, so it applies after a restart.
    static func store(_ language: AppLanguage) {
        if let value = language.appleLanguages {
            UserDefaults.standard.set(value, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
