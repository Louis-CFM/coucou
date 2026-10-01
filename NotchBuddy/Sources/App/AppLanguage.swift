import AppKit

/// In-app language override. `.system` follows macOS (System Settings › Language & Region);
/// the others pin `AppleLanguages` in the app's own defaults domain, applied on next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case portugueseBrazil = "pt-BR"

    var id: String { rawValue }

    private static let defaultsKey = "AppleLanguages"
    private static let choiceKey = "appLanguage"

    /// Native names are not translated: a user must recognise their own language.
    var displayName: String {
        switch self {
        case .system:           return String(localized: "System default")
        case .english:          return "English"
        case .portugueseBrazil: return "Português (Brasil)"
        }
    }

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: choiceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(rawValue, forKey: Self.choiceKey)
        if self == .system {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    /// Quits and reopens the app so the new language is picked up. The reopen waits a
    /// moment so this instance releases the hook socket before the next one binds it.
    @MainActor
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("Coucou: relaunch failed: \(error.localizedDescription)")
        }
    }
}
