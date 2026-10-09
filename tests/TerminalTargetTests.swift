import Foundation

@main
struct TerminalTargetTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if cond { print("✓ \(msg)") } else { print("✗ \(msg)"); failures += 1 }
        }

        // The session's own app wins over the fixed list
        check(TerminalTarget.pick(sessionBundleId: "com.cmuxterm.app",
                                  running: ["com.apple.Terminal", "com.cmuxterm.app"]) == "com.cmuxterm.app",
              "session app (cmux) is preferred over a running Terminal")

        // VS Code integrated terminal goes back to VS Code
        check(TerminalTarget.pick(sessionBundleId: "com.microsoft.VSCode",
                                  running: ["com.microsoft.VSCode", "com.googlecode.iterm2"]) == "com.microsoft.VSCode",
              "VS Code session goes back to VS Code")

        // Session app not running → fall back to known terminals, in order
        check(TerminalTarget.pick(sessionBundleId: "com.cmuxterm.app",
                                  running: ["com.googlecode.iterm2", "com.mitchellh.ghostty"]) == "com.googlecode.iterm2",
              "falls back to the first running known terminal")

        // No bundle id → known terminals only, cmux included
        check(TerminalTarget.pick(sessionBundleId: nil, running: ["com.cmuxterm.app"]) == "com.cmuxterm.app",
              "cmux is in the fallback list")
        check(TerminalTarget.pick(sessionBundleId: "  ", running: ["dev.warp.Warp-Stable"]) == "dev.warp.Warp-Stable",
              "blank bundle id is ignored")

        // Nothing running → nil (caller opens Terminal.app as before)
        check(TerminalTarget.pick(sessionBundleId: "com.cmuxterm.app", running: []) == nil,
              "nothing running returns nil")

        // No duplicates when the session app is already a known terminal
        let c = TerminalTarget.candidates(sessionBundleId: "com.mitchellh.ghostty")
        check(c.first == "com.mitchellh.ghostty" && c.filter { $0 == "com.mitchellh.ghostty" }.count == 1,
              "session app is listed once, first")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All terminal target tests passed")
    }
}
