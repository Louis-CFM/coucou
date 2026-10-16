import Foundation

@main
struct ItermLaunchTests {
    static func main() {
        var failures = 0
        func check(_ cond: Bool, _ msg: String) {
            if cond { print("✓ \(msg)") } else { print("✗ \(msg)"); failures += 1 }
        }

        // Single quotes survive the shell
        check(ItermLaunch.shellQuoted("it's") == "'it'\\''s'", "single quote is escaped for the shell")
        check(ItermLaunch.shellQuoted("$HOME `x` \"y\"") == "'$HOME `x` \"y\"'", "nothing expands inside single quotes")

        // The command: cd, then claude with -- and the prompt as one word
        check(ItermLaunch.command(prompt: "-fix the tests", directory: "/Users/a b")
                == "cd '/Users/a b' && claude -- '-fix the tests'",
              "directory quoted, prompt after --")
        check(ItermLaunch.command(prompt: "one\ntwo\r\n", directory: "/tmp") == "cd '/tmp' && claude -- 'one two'",
              "newlines are flattened so the line isn't submitted early")

        // AppleScript string literal
        check(ItermLaunch.appleScriptString("a \"b\" \\c") == "\"a \\\"b\\\" \\\\c\"",
              "quotes and backslashes are escaped for AppleScript")

        // A fresh launch reuses the window iTerm2 opens; otherwise a new tab
        let fresh = ItermLaunch.script(prompt: "hi", directory: "/tmp", freshLaunch: true)
        let running = ItermLaunch.script(prompt: "hi", directory: "/tmp", freshLaunch: false)
        check(fresh.contains("else if not true then"), "fresh launch does not add a tab")
        check(running.contains("else if not false then"), "running iTerm2 gets a new tab")
        check(running.contains("write text \"cd '/tmp' && claude -- 'hi'\""), "the command is written in the session")

        // The shell really reads back the same prompt
        let tricky = "it's \"quoted\" $HOME `date` \\ ; rm -rf x"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", "printf %s \(ItermLaunch.shellQuoted(tricky))"]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let echoed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        check(echoed == tricky, "zsh gets the prompt back byte for byte")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("All iTerm launch tests passed")
    }
}
