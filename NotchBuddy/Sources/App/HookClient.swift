import Foundation

/// The app a Claude Code session runs in, read from the context nb-hook adds to each event.
/// Only these apps feed the Claude pill: plain terminals and Coucou's own processes stay out.
enum HookClient: Equatable {
    case vscode
    case claudeDesktop
    case orca

    /// TERM_PROGRAM names the terminal the session runs in, so it is checked first.
    /// __CFBundleIdentifier can be inherited from whichever app launched that terminal.
    init?(termProgram: String, bundleId: String) {
        let term = termProgram.lowercased()
        let bundle = bundleId.lowercased()
        if term.contains("vscode") {
            self = .vscode
        } else if term == "orca" {
            self = .orca
        } else if bundle.contains("vscode") {
            self = .vscode
        } else if bundle == "com.anthropic.claudefordesktop" {
            self = .claudeDesktop
        } else if bundle == "com.stablyai.orca" {
            self = .orca
        } else {
            return nil
        }
    }

    /// Label of the Claude pill.
    var name: String {
        switch self {
        case .vscode:        return "VS Code"
        case .claudeDesktop: return "Claude"
        case .orca:          return "Orca"
        }
    }

    /// Name used in the "Open …" button.
    var appName: String {
        self == .vscode ? "Visual Studio Code" : name
    }

    /// Apps to bring forward when jumping to the session, preferred first.
    var bundleIds: [String] {
        switch self {
        case .vscode:        return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium.codium"]
        case .claudeDesktop: return ["com.anthropic.claudefordesktop"]
        case .orca:          return ["com.stablyai.orca"]
        }
    }
}
