import Foundation

/// The app a Claude Code session runs in, read from the context nb-hook adds to each event
/// (`term_program`, `bundle_id`). Sessions from any other app are ignored: plain terminals
/// and Coucou's own processes stay out of the workspace pills.
enum HookClient: Equatable {
    case vscode
    case cursor
    case claudeDesktop
    case orca

    /// Cursor's bundle id always wins: its terminal says vscode, and InstructionRunner tags
    /// iPhone instructions for the Cursor pill with it alone. Otherwise TERM_PROGRAM names
    /// the terminal the session runs in, so it is checked before the bundle id, which can be
    /// inherited from whichever app launched that terminal.
    init?(termProgram: String, bundleId: String) {
        let term = termProgram.lowercased()
        let bundle = bundleId.lowercased()
        // ToDesktop builds other apps too — do not match on "todesktop" alone.
        if bundle == "com.todesktop.230313mzl4w4u92" {
            self = .cursor
        } else if term == "orca" {
            self = .orca
        } else if term.contains("vscode") || bundle.contains("vscode") {
            self = .vscode
        } else if bundle == "com.anthropic.claudefordesktop" {
            self = .claudeDesktop
        } else if bundle == "com.stablyai.orca" {
            self = .orca
        } else {
            return nil
        }
    }

    /// Workspace pill the session's events and approvals go to.
    var pillId: String {
        self == .cursor ? "agent_cursor" : "integration_claude"
    }
}
