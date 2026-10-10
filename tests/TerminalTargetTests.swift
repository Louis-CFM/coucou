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

        // Tab scripts: only terminals that expose a tab's tty
        check(TerminalTarget.tabScript(bundleId: "com.apple.Terminal", tty: "/dev/ttys003")?
                .contains("\"/dev/ttys003\"") == true, "Terminal script looks for the session's tty")
        check(TerminalTarget.tabScript(bundleId: "com.googlecode.iterm2", tty: "/dev/ttys012")?
                .contains("sessions of t") == true, "iTerm script walks sessions")
        check(TerminalTarget.tabScript(bundleId: "com.mitchellh.ghostty", tty: "/dev/ttys003") == nil,
              "no script for terminals without a tty in AppleScript")

        // tmux: the session's pane tty maps to its pane and session ids
        let listing = "/dev/ttys004 %0 $0\n/dev/ttys007 %3 $1\n"
        let pane = TerminalTarget.tmuxPane(tty: "/dev/ttys007", listing: listing)
        check(pane?.pane == "%3" && pane?.session == "$1", "tmux pane found by its tty")
        check(TerminalTarget.tmuxPane(tty: "/dev/ttys009", listing: listing) == nil,
              "a tty outside tmux is not a pane")

        // WezTerm: the session's pane found by its tty in `wezterm cli list --format json`
        let wez = #"[{"window_id":2,"tab_id":2,"pane_id":2,"title":"coucou-mac","tty_name":"/dev/ttys002"},"# +
                  #"{"window_id":3,"tab_id":3,"pane_id":7,"title":"[mosh] coucou · claude","tty_name":"/dev/ttys003"}]"#
        let wezPane = TerminalTarget.weztermPane(tty: "/dev/ttys003", listing: wez)
        check(wezPane?.id == 7 && wezPane?.title == "[mosh] coucou · claude", "WezTerm pane found by its tty")
        check(TerminalTarget.weztermPane(tty: "/dev/ttys009", listing: wez) == nil, "no WezTerm pane on another tty")
        check(TerminalTarget.weztermPane(tty: "/dev/ttys002", listing: "not json") == nil, "bad WezTerm listing is ignored")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All terminal target tests passed")
    }
}
