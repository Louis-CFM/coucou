import Foundation

@main
enum SessionLaunchTests {
    static func main() {
        precondition(LaunchScript.quote("it's") == "'it'\\''s'", "single quote escaped")
        let s = LaunchScript.script(prompt: "fix the \"login\" bug; rm -rf / && echo $HOME `id`", folder: "/Users/me/My Project's")
        precondition(s.hasPrefix("#!/bin/sh\nrm -f \"$0\"\n"), "removes itself first")
        precondition(s.contains("cd '/Users/me/My Project'\\''s' || exit 1"), "folder quoted")
        precondition(s.contains("export COUCOU_PROMPT='fix the \"login\" bug; rm -rf / && echo $HOME `id`'"),
                     "prompt kept whole in single quotes: nothing in it runs")
        precondition(s.contains("claude \"$COUCOU_PROMPT\""), "Claude Code gets the prompt from the variable")
        let empty = LaunchScript.script(prompt: "   ", folder: "/tmp")
        precondition(empty.contains("-lic 'claude; exec $SHELL -l'"), "no prompt: plain claude")

        precondition(LaunchScript.way(for: "com.apple.Terminal") == .open)
        precondition(LaunchScript.way(for: "com.mitchellh.ghostty") == .args(["-e", "%s"]))
        precondition(LaunchScript.way(for: "dev.warp.Warp-Stable") == nil)
        precondition(LaunchScript.terminal(lastSession: "com.googlecode.iterm2", running: []) == "com.googlecode.iterm2")
        precondition(LaunchScript.terminal(lastSession: "dev.warp.Warp-Stable", running: ["dev.warp.Warp-Stable", "com.mitchellh.ghostty"]) == "com.mitchellh.ghostty",
                     "Warp can't run it: the next running terminal that can")
        precondition(LaunchScript.terminal(lastSession: nil, running: []) == "com.apple.Terminal")

        var list = LaunchScript.remember("/Users/me/a/", in: [], home: "/Users/me")
        list = LaunchScript.remember("/Users/me/b", in: list, home: "/Users/me")
        list = LaunchScript.remember("/Users/me/a", in: list, home: "/Users/me")
        precondition(list == ["/Users/me/a", "/Users/me/b"], "most recent first, no duplicates")
        precondition(LaunchScript.remember("/Users/me", in: list, home: "/Users/me") == list, "home folder skipped")
        precondition(LaunchScript.remember("/", in: list, home: "/Users/me") == list, "/ skipped")
        var many: [String] = []
        for i in 0..<15 { many = LaunchScript.remember("/p/\(i)", in: many, home: "/h") }
        precondition(many.count == 10 && many.first == "/p/14", "ten at most")
        precondition(LaunchScript.dropText(["/tmp/Screenshot 2026-11-06 at 14.03.22.png"]) == "/tmp/Screenshot\\ 2026-11-06\\ at\\ 14.03.22.png ",
                     "spaces escaped like a terminal drag, then a space")
        precondition(LaunchScript.dropText(["/a/b.txt", "/c/it's (1).md"]) == "/a/b.txt /c/it\\'s\\ \\(1\\).md ",
                     "several files, quotes and parentheses escaped")
        print("SessionLaunch: all tests passed")
    }
}
