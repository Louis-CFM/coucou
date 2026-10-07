import Foundation

@main
enum HookClientTests {
    static func main() {
        // VS Code and its forks: the integrated terminal sets TERM_PROGRAM=vscode
        precondition(HookClient(termProgram: "vscode", bundleId: "com.microsoft.VSCode") == .vscode)
        precondition(HookClient(termProgram: "vscode", bundleId: "") == .vscode)
        precondition(HookClient(termProgram: "", bundleId: "com.microsoft.VSCodeInsiders") == .vscode)

        // Cursor: identified by its exact bundle id, even though its terminal says vscode.
        // ToDesktop builds other apps too, so only the exact id counts.
        precondition(HookClient(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92") == .cursor)
        precondition(HookClient(termProgram: "", bundleId: "com.todesktop.230313mzl4w4u92") == .cursor)
        precondition(HookClient(termProgram: "", bundleId: "com.todesktop.someotherapp") == nil)

        // Claude desktop app (Code tab): no TERM_PROGRAM
        precondition(HookClient(termProgram: "", bundleId: "com.anthropic.claudefordesktop") == .claudeDesktop)

        // Orca terminal
        precondition(HookClient(termProgram: "Orca", bundleId: "com.stablyai.orca") == .orca)
        precondition(HookClient(termProgram: "Orca", bundleId: "") == .orca)
        precondition(HookClient(termProgram: "", bundleId: "com.stablyai.orca") == .orca)

        // TERM_PROGRAM names the terminal the session runs in; the bundle id can be
        // inherited from whichever app launched that terminal
        precondition(HookClient(termProgram: "Orca", bundleId: "com.microsoft.VSCode") == .orca)
        precondition(HookClient(termProgram: "vscode", bundleId: "com.stablyai.orca") == .vscode)

        // Except Cursor's bundle id, which always wins: InstructionRunner tags iPhone
        // instructions for the Cursor pill with it and keeps the inherited TERM_PROGRAM
        precondition(HookClient(termProgram: "Orca", bundleId: "com.todesktop.230313mzl4w4u92") == .cursor)

        // Not tracked: plain terminals, Coucou's own processes, unknown
        precondition(HookClient(termProgram: "Apple_Terminal", bundleId: "com.apple.Terminal") == nil)
        precondition(HookClient(termProgram: "iTerm.app", bundleId: "com.googlecode.iterm2") == nil)
        precondition(HookClient(termProgram: "", bundleId: "fr.louisraille.NotchBuddy") == nil)
        precondition(HookClient(termProgram: "", bundleId: "") == nil)

        // Pill routing: Cursor keeps its own pill; the Claude app and Orca share
        // the Claude Code pill with VS Code
        precondition(HookClient.vscode.pillId == "integration_claude")
        precondition(HookClient.cursor.pillId == "agent_cursor")
        precondition(HookClient.claudeDesktop.pillId == "integration_claude")
        precondition(HookClient.orca.pillId == "integration_claude")

        print("Hook clients: 21 cases passed")
    }
}
