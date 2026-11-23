import Foundation

// CLIRelay.ask on stand-in tools: small shell scripts that answer the way Claude Code does,
// so the run itself is checked (stdin, environment, folder, time limit), not only its parts.
@main
enum CLIRelayRunTests {
    static let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    static let workdir = root.appendingPathComponent("relay", isDirectory: true)

    /// What Flow's clean-up asks Claude Code (FlowCleanup.ask): no tools, no web, no thinking.
    static func flowRequest(timeout: TimeInterval = 10) -> CLIRequest {
        CLIRequest(model: "claude-haiku-4-5", system: "Rewrite the dictation.",
                   prompt: "<dictation>\nso um we should uh meet on Friday\n</dictation>",
                   web: false, readDir: nil, noWebPolicy: nil, timeout: timeout, thinking: false)
    }

    static func tool(_ name: String, _ script: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    static func read(_ name: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    static func main() async throws {
        // As the app does (AppDelegate): a write to a tool that quit fails instead of killing us.
        signal(SIGPIPE, SIG_IGN)
        try await answers()
        try await signedOut()
        try await tooSlow()
        try await startedAhead()
        try await cancelled()
        try await quitWhileWaiting()
        try await dropped()
        print("CLIRelay run tests: all passed")
    }

    /// The prompt goes in on stdin, the run starts in Coucou's folder with thinking off, and
    /// the answer is the result's text.
    static func answers() async throws {
        let out = root.path
        let exe = try tool("claude-answers", """
        cat > "\(out)/stdin.txt"
        printf '%s' "$MAX_THINKING_TOKENS" > "\(out)/thinking.txt"
        pwd > "\(out)/pwd.txt"
        for a in "$@"; do printf '[%s]\\n' "$a"; done > "\(out)/args.txt"
        echo '{"type":"result","subtype":"success","is_error":false,"result":" We should meet on Friday. "}'
        """)
        let text = try await CLIRelay.ask(.claude, flowRequest(), exe: exe, workdir: workdir)
        precondition(text == "We should meet on Friday.", text)
        precondition(read("stdin.txt") == "<dictation>\nso um we should uh meet on Friday\n</dictation>", read("stdin.txt"))
        precondition(read("thinking.txt") == "0", "thinking off for Flow")
        precondition(URL(fileURLWithPath: read("pwd.txt").trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().path == workdir.resolvingSymlinksInPath().path)
        let args = read("args.txt")
        precondition(args.contains("[--tools]\n[]\n"), "no tools at all")
        precondition(!args.contains("--allowedTools") && !args.contains("WebSearch"), "no web")
        precondition(args.contains("[--model]\n[claude-haiku-4-5]\n"))
    }

    /// Claude Code signed out (its real output, 2.1.x): the error says how to sign in again.
    static func signedOut() async throws {
        let exe = try tool("claude-signed-out", """
        cat > /dev/null
        echo '{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","result":"Failed to authenticate: OAuth session expired and could not be refreshed"}'
        """)
        do {
            _ = try await CLIRelay.ask(.claude, flowRequest(), exe: exe, workdir: workdir)
            preconditionFailure("a signed-out Claude Code gives no answer")
        } catch let failure as CLIFailure {
            guard case .failed(let why) = failure else { preconditionFailure("\(failure)") }
            precondition(why == "Claude Code is not signed in. Sign in once in Terminal: claude", why)
            precondition(CLIRelay.needsSignIn(why), "what Flow looks for to say so on the pill")
        }
    }

    /// A tool that never answers, and doesn't stop when asked, is gone a second past the
    /// request's time limit.
    static func tooSlow() async throws {
        let exe = try tool("claude-slow", "trap '' TERM\nexec sleep 30\n")
        let started = Date()
        do {
            _ = try await CLIRelay.ask(.claude, flowRequest(timeout: 1), exe: exe, workdir: workdir)
            preconditionFailure("a tool that never answers gives no answer")
        } catch let failure as CLIFailure {
            precondition(failure == .timedOut("Claude Code"), "\(failure)")
        }
        let waited = Date().timeIntervalSince(started)
        precondition(waited < 3, "stopped after \(waited) s")
    }

    /// Started when the key goes down: the tool waits with the first line in, longer than its
    /// time limit, which starts only with the rest; the answer is the same.
    static func startedAhead() async throws {
        let out = root.path
        let exe = try tool("claude-ahead", """
        cat > "\(out)/ahead-stdin.txt"
        echo '{"type":"result","subtype":"success","is_error":false,"result":"We should meet on Friday."}'
        """)
        let pending = try CLIRelay.start(.claude, flowRequest(timeout: 1), head: "<dictation>\n", exe: exe, workdir: workdir)
        try await Task.sleep(for: .milliseconds(1500))
        precondition(pending.isRunning, "waits for the rest")
        let text = try await pending.finish("so um we should uh meet on Friday\n</dictation>")
        precondition(text == "We should meet on Friday.", text)
        precondition(read("ahead-stdin.txt") == "<dictation>\nso um we should uh meet on Friday\n</dictation>", read("ahead-stdin.txt"))
    }

    /// Not needed after all: gone a second later, even when it ignores SIGTERM.
    static func cancelled() async throws {
        let exe = try tool("claude-cancelled", "trap '' TERM\nexec sleep 30\n")
        let pending = try CLIRelay.start(.claude, flowRequest(), head: "<dictation>\n", exe: exe, workdir: workdir)
        pending.cancel()
        try await Task.sleep(for: .milliseconds(1600))
        precondition(!pending.isRunning, "stopped")
    }

    /// One that quit while it waited: no answer, and writing the rest to it is harmless.
    static func quitWhileWaiting() async throws {
        let exe = try tool("claude-quits", "exit 1\n")
        let pending = try CLIRelay.start(.claude, flowRequest(), head: "<dictation>\n", exe: exe, workdir: workdir)
        try await Task.sleep(for: .milliseconds(300))
        precondition(!pending.isRunning)
        do {
            _ = try await pending.finish(String(repeating: "word ", count: 50_000) + "\n</dictation>")
            preconditionFailure("a tool that quit gives no answer")
        } catch let failure as CLIFailure {
            precondition(failure == .noAnswer("Claude Code"), "\(failure)")
        }
    }

    /// Dropped without being finished: stopped at once, not left waiting until its lifetime ends.
    static func dropped() async throws {
        let out = root.path
        let exe = try tool("claude-dropped", "echo $$ > \"\(out)/dropped.pid\"\nexec cat > /dev/null\n")
        do {
            let pending = try CLIRelay.start(.claude, flowRequest(), head: "<dictation>\n", exe: exe, workdir: workdir)
            try await Task.sleep(for: .milliseconds(300))
            precondition(pending.isRunning)
        }
        guard let pid = Int32(read("dropped.pid").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preconditionFailure("the stand-in wrote no pid")
        }
        try await Task.sleep(for: .milliseconds(1500))
        precondition(kill(pid, 0) != 0, "the dropped run is still there")
    }
}
