import Foundation

@main
enum ClaudeHostTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("ClaudeHost.terminal")
        check("Warp by bundle id", ClaudeHost.terminal(termProgram: "", bundleId: "dev.warp.Warp-Stable")?.name == "Warp")
        check("Warp by TERM_PROGRAM", ClaudeHost.terminal(termProgram: "WarpTerminal", bundleId: "")?.bundleId == "dev.warp.Warp-Stable")
        check("Terminal.app", ClaudeHost.terminal(termProgram: "Apple_Terminal", bundleId: "")?.name == "Terminal")
        check("iTerm", ClaudeHost.terminal(termProgram: "iTerm.app", bundleId: "")?.name == "iTerm")
        check("tmux inside Ghostty: bundle id wins",
              ClaudeHost.terminal(termProgram: "tmux", bundleId: "com.mitchellh.ghostty")?.name == "Ghostty")
        check("cmux: bundle id wins over TERM_PROGRAM=ghostty",
              ClaudeHost.terminal(termProgram: "ghostty", bundleId: "com.cmuxterm.app")?.name == "cmux")
        check("Orca by bundle id", ClaudeHost.terminal(termProgram: "", bundleId: "com.stablyai.orca")?.name == "Orca")
        check("Conductor by bundle id", ClaudeHost.terminal(termProgram: "", bundleId: "com.conductor.app")?.name == "Conductor")
        check("VS Code → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.microsoft.VSCode") == nil)
        check("Cursor → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92") == nil)
        check("unknown → nil", ClaudeHost.terminal(termProgram: "", bundleId: "com.example.app") == nil)

        print("ClaudeHost.name / pillName")
        check("nil host = VS Code", ClaudeHost.name(for: nil) == "VS Code")
        check("Warp host", ClaudeHost.name(for: "dev.warp.Warp-Stable") == "Warp")
        check("unknown host = VS Code", ClaudeHost.name(for: "com.example.app") == "VS Code")
        check("editor session → VS Code", ClaudeHost.pillName(hostApp: nil) == "VS Code")
        check("terminal session → Claude Code", ClaudeHost.pillName(hostApp: "dev.warp.Warp-Stable") == "Claude Code")

        print("ClaudeHost.keepsSessionLink")
        check("Claude Code keeps its host", ClaudeHost.keepsSessionLink(pillId: "integration_claude"))
        check("Codex keeps its host", ClaudeHost.keepsSessionLink(pillId: "agent_codex"))
        check("Cursor doesn't", !ClaudeHost.keepsSessionLink(pillId: "agent_cursor"))
        check("no pill doesn't", !ClaudeHost.keepsSessionLink(pillId: nil))

        print("ClaudeHost.isConductor")
        check("Conductor is", ClaudeHost.isConductor("com.conductor.app"))
        check("Warp isn't", !ClaudeHost.isConductor("dev.warp.Warp-Stable"))
        check("VS Code (nil host) isn't", !ClaudeHost.isConductor(nil))

        print("ClaudeHost.sessionURL")
        let conductor = "com.conductor.app"
        let workspace = "a1f5ba4e-8f43-4648-9e05-4a87c51f5168"
        let chat = "8b2c171b-1417-4340-a5a6-61fb8d8e99f9"
        check("Conductor workspace and chat",
              ClaudeHost.sessionURL(bundleId: conductor, workspaceId: workspace, sessionId: chat)?.absoluteString
              == "conductor://workspace?id=\(workspace)&session=\(chat)")
        check("Conductor workspace only",
              ClaudeHost.sessionURL(bundleId: conductor, workspaceId: workspace, sessionId: "")?.absoluteString
              == "conductor://workspace?id=\(workspace)")
        check("Conductor without workspace → nil",
              ClaudeHost.sessionURL(bundleId: conductor, workspaceId: "", sessionId: chat) == nil)
        check("Conductor missing ids → nil",
              ClaudeHost.sessionURL(bundleId: conductor, workspaceId: nil, sessionId: nil) == nil)
        check("Conductor odd id → nil",
              ClaudeHost.sessionURL(bundleId: conductor, workspaceId: "x&session=y", sessionId: chat) == nil)
        check("other host → nil",
              ClaudeHost.sessionURL(bundleId: "dev.warp.Warp-Stable", workspaceId: workspace, sessionId: chat) == nil)

        print("ClaudeHost.terminalCardsEnabled")
        UserDefaults.standard.removeObject(forKey: ClaudeHost.terminalCardsKey)
        check("off by default", ClaudeHost.terminalCardsEnabled == false)

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
