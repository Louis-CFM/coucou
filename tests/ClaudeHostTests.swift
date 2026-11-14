import Foundation

@main @MainActor
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
        check("Conductor by bundle id, no TERM_PROGRAM",
              ClaudeHost.terminal(termProgram: "", bundleId: "com.conductor.app")?.name == "Conductor")
        check("Conductor keeps its own bundle id",
              ClaudeHost.terminal(termProgram: "", bundleId: "com.conductor.app")?.bundleId == "com.conductor.app")
        check("VS Code → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.microsoft.VSCode") == nil)
        check("Cursor → nil", ClaudeHost.terminal(termProgram: "vscode", bundleId: "com.todesktop.230313mzl4w4u92") == nil)
        check("unknown → nil", ClaudeHost.terminal(termProgram: "", bundleId: "com.example.app") == nil)

        print("ClaudeHost.name / pillName")
        check("nil host = VS Code", ClaudeHost.name(for: nil) == "VS Code")
        check("Warp host", ClaudeHost.name(for: "dev.warp.Warp-Stable") == "Warp")
        check("Conductor host = Open Conductor", ClaudeHost.name(for: "com.conductor.app") == "Conductor")
        check("unknown host = VS Code", ClaudeHost.name(for: "com.example.app") == "VS Code")
        check("editor session → VS Code", ClaudeHost.pillName(hostApp: nil) == "VS Code")
        check("terminal session → Claude Code", ClaudeHost.pillName(hostApp: "dev.warp.Warp-Stable") == "Claude Code")
        check("Conductor session → Claude Code", ClaudeHost.pillName(hostApp: "com.conductor.app") == "Claude Code")

        print("ClaudeHost.terminalCardsEnabled")
        UserDefaults.standard.removeObject(forKey: ClaudeHost.terminalCardsKey)
        check("off by default", ClaudeHost.terminalCardsEnabled == false)

        print("ClaudeHost session focus helpers")
        check("valid tty accepted", ClaudeHost.validatedTty("/dev/ttys003") == "/dev/ttys003")
        check("injected tty rejected", ClaudeHost.validatedTty("/dev/ttys003\" ; evil") == nil)
        check("non-tty path rejected", ClaudeHost.validatedTty("/tmp/foo") == nil)
        check("iTerm uid extracted from w0t0p0 prefix", ClaudeHost.normalizedItermUniqueId("w0t1p0:ABC-123_def") == "ABC-123_def")
        check("iTerm uid rejects quotes", ClaudeHost.normalizedItermUniqueId("w0t1p0:BAD\"ID") == nil)
        check("Terminal script matches tty", ClaudeHost.focusTerminalScript(tty: "/dev/ttys003").contains("tty of t is \"/dev/ttys003\""))
        check("iTerm script includes uid and tty",
              ClaudeHost.focusItermScript(uniqueId: "ABC-123", tty: "/dev/ttys003")
                  .contains("unique id of s is \"ABC-123\" or tty of s is \"/dev/ttys003\""))

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
