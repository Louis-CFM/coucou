import Foundation

@main
enum HookClientTests {
    static func main() {
        // VS Code and its forks: the integrated terminal sets TERM_PROGRAM=vscode
        precondition(HookClient(termProgram: "vscode", bundleId: "com.microsoft.VSCode") == .vscode)
        precondition(HookClient(termProgram: "vscode", bundleId: "") == .vscode)
        precondition(HookClient(termProgram: "", bundleId: "com.microsoft.VSCodeInsiders") == .vscode)
        precondition(HookClient(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92") == .vscode)

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

        // Not tracked: plain terminals, Coucou's own processes, unknown
        precondition(HookClient(termProgram: "Apple_Terminal", bundleId: "com.apple.Terminal") == nil)
        precondition(HookClient(termProgram: "iTerm.app", bundleId: "com.googlecode.iterm2") == nil)
        precondition(HookClient(termProgram: "", bundleId: "fr.louisraille.NotchBuddy") == nil)
        precondition(HookClient(termProgram: "", bundleId: "") == nil)

        // Pill label and the app brought forward by "Open …"
        precondition(HookClient.vscode.name == "VS Code")
        precondition(HookClient.vscode.bundleIds.first == "com.microsoft.VSCode")
        precondition(HookClient.claudeDesktop.name == "Claude")
        precondition(HookClient.claudeDesktop.bundleIds == ["com.anthropic.claudefordesktop"])
        precondition(HookClient.orca.name == "Orca")
        precondition(HookClient.orca.bundleIds == ["com.stablyai.orca"])

        print("Hook clients: 20 cases passed")
    }
}
