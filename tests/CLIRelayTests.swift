import Foundation

@main
enum CLIRelayTests {
    static func request(web: Bool = true, readDir: URL? = nil, policy: URL? = nil, model: String? = nil) -> CLIRequest {
        CLIRequest(model: model, system: "SYS", prompt: "Hello?", web: web, readDir: readDir,
                   noWebPolicy: policy, timeout: 60)
    }

    static func main() {
        commandLines()
        answers()
        failures()
        prompt()
        print("CLIRelay tests: all passed")
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func commandLines() {
        // Claude Code: no settings, no MCP, nothing saved; web for the chat, Read for a file.
        let chat = CLIRelay.arguments(.claude, request(model: "claude-sonnet-5"))
        precondition(value(after: "--tools", in: chat) == "WebSearch,WebFetch")
        precondition(value(after: "--setting-sources", in: chat) == "")
        precondition(chat.contains("--strict-mcp-config") && chat.contains("--no-session-persistence"))
        precondition(value(after: "--model", in: chat) == "claude-sonnet-5")
        precondition(value(after: "--system-prompt", in: chat) == "SYS")
        let dir = URL(fileURLWithPath: "/tmp/coucou-relay-x")
        let file = CLIRelay.arguments(.claude, request(web: false, readDir: dir))
        precondition(value(after: "--tools", in: file) == "Read" && value(after: "--add-dir", in: file) == dir.path)
        precondition(!file.contains("--model"), "no model: Claude Code's own default")
        // The others get the system prompt inside the prompt.
        let gemini = CLIRelay.arguments(.gemini, request())
        precondition(value(after: "-p", in: gemini)!.hasPrefix("<instructions>\nSYS\n</instructions>"))
        precondition(value(after: "--approval-mode", in: gemini) == "plan" && value(after: "--extensions", in: gemini) == "none")
        precondition(!gemini.contains("--policy"))
        let policy = URL(fileURLWithPath: "/tmp/no-web.toml")
        let geminiFile = CLIRelay.arguments(.gemini, request(web: false, policy: policy))
        precondition(value(after: "--policy", in: geminiFile) == policy.path, "no web while a file is read")
        let agy = CLIRelay.arguments(.antigravity, request())
        precondition(value(after: "--mode", in: agy) == "plan" && value(after: "--output-format", in: agy) == "json")
        // Codex: read-only, no shell, search only for the chat, prompt on stdin.
        let codex = CLIRelay.arguments(.codex, request())
        precondition(codex.first == "--search" && codex[1] == "exec" && codex.last == "-")
        precondition(value(after: "--sandbox", in: codex) == "read-only" && codex.contains("--ephemeral"))
        precondition(codex.contains("shell_tool") && codex.contains("unified_exec"))
        precondition(!CLIRelay.arguments(.codex, request(web: false)).contains("--search"))
        // Cursor: ask mode, never --force.
        let cursor = CLIRelay.arguments(.cursor, request())
        precondition(value(after: "--mode", in: cursor) == "ask" && !cursor.contains("--force") && !cursor.contains("--yolo"))
        // Copilot: only the web fetch for the chat, nothing that writes or runs.
        let copilot = CLIRelay.arguments(.copilot, request())
        precondition(value(after: "--available-tools", in: copilot) == "web_fetch" && copilot.contains("--silent"))
        precondition(!copilot.contains("--allow-all-tools") && !copilot.contains("--yolo"))
        precondition(value(after: "--available-tools", in: CLIRelay.arguments(.copilot, request(web: false))) == "view")
        precondition(!CLIRelay.arguments(.copilot, request(web: false)).contains("--allow-all-urls"))
        // An empty model is the tool's default too.
        precondition(!CLIRelay.arguments(.cursor, request(model: "")).contains("--model"))
        precondition(SubscriptionCLI.claude.promptOnStdin && SubscriptionCLI.codex.promptOnStdin && !SubscriptionCLI.gemini.promptOnStdin)
    }

    static func ok(_ r: Result<String, CLIFailure>) -> String? {
        if case .success(let s) = r { return s }
        return nil
    }

    static func err(_ r: Result<String, CLIFailure>) -> String? {
        if case .failure(let f) = r { return f.localizedDescription }
        return nil
    }

    static func answers() {
        let none = Data()
        precondition(ok(CLIRelay.parse(.claude, stdout: Data(#"{"result":" Hi ","is_error":false}"#.utf8), stderr: none, exitCode: 0)) == "Hi")
        precondition(ok(CLIRelay.parse(.cursor, stdout: Data("warming up\n{\"type\":\"result\",\"result\":\"Yo\",\"is_error\":false}".utf8), stderr: none, exitCode: 0)) == "Yo")
        precondition(ok(CLIRelay.parse(.gemini, stdout: Data(#"{"response":"Bonjour","stats":{}}"#.utf8), stderr: none, exitCode: 0)) == "Bonjour")
        precondition(ok(CLIRelay.parse(.antigravity, stdout: Data(#"{"status":"SUCCESS","response":"Hey"}"#.utf8), stderr: none, exitCode: 0)) == "Hey")
        let events = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"item.completed","item":{"id":"1","type":"reasoning","text":"thinking"}}
        {"type":"item.completed","item":{"id":"2","type":"agent_message","text":"First"}}
        {"type":"item.completed","item":{"id":"3","type":"agent_message","text":"Final answer"}}
        {"type":"turn.completed","usage":{}}
        """
        precondition(ok(CLIRelay.parse(.codex, stdout: Data(events.utf8), stderr: none, exitCode: 0)) == "Final answer")
        precondition(ok(CLIRelay.parse(.copilot, stdout: Data("  The answer\n".utf8), stderr: none, exitCode: 0)) == "The answer")
    }

    static func failures() {
        let none = Data()
        precondition(err(CLIRelay.parse(.claude, stdout: Data(#"{"result":"Credit balance is too low","is_error":true}"#.utf8), stderr: none, exitCode: 1)) == "Credit balance is too low")
        // Gemini puts its error object on stderr.
        let gErr = Data(#"{"session_id":"x","error":{"type":"Error","message":"Quota exceeded","code":1}}"#.utf8)
        precondition(err(CLIRelay.parse(.gemini, stdout: none, stderr: gErr, exitCode: 1)) == "Quota exceeded")
        // Not signed in: how to sign in.
        let auth = Data(#"{"error":{"message":"Please set an Auth method in your settings.json"}}"#.utf8)
        precondition(err(CLIRelay.parse(.gemini, stdout: none, stderr: auth, exitCode: 41))!.contains("Sign in once in Terminal: gemini"))
        let codexAuth = Data(#"{"type":"error","message":"unexpected status 401 Unauthorized"}"#.utf8)
        precondition(err(CLIRelay.parse(.codex, stdout: codexAuth, stderr: none, exitCode: 1))!.hasSuffix("codex login"))
        let copilotAuth = Data("Error: Authentication token found but could not be validated.\nRun /login\n".utf8)
        precondition(err(CLIRelay.parse(.copilot, stdout: none, stderr: copilotAuth, exitCode: 1))!.contains("not signed in"))
        // Anything else: the tool's last words, without colours.
        let crash = Data("\u{1B}[31mboom: model not found\u{1B}[0m\n".utf8)
        precondition(err(CLIRelay.parse(.copilot, stdout: none, stderr: crash, exitCode: 1)) == "Copilot CLI gave no answer. (boom: model not found)")
        precondition(err(CLIRelay.parse(.claude, stdout: Data("not json".utf8), stderr: none, exitCode: 1)) == "Claude Code gave no answer.")
        let failedTurn = Data(#"{"type":"turn.failed","error":{"message":"Model overloaded"}}"#.utf8)
        precondition(err(CLIRelay.parse(.codex, stdout: failedTurn, stderr: none, exitCode: 1)) == "Model overloaded")
    }

    static func prompt() {
        let first = CLIRelay.chatPrompt(history: [], context: "File: a.txt", query: "What is it?")
        precondition(first == "File: a.txt\n\nWhat is it?")
        let later = CLIRelay.chatPrompt(history: [(user: "Hi", assistant: "Hello")], context: nil, query: "And?")
        precondition(later.contains("<user>\nHi\n</user>\n<assistant>\nHello\n</assistant>") && later.hasSuffix("The user's new message:\nAnd?"))
        precondition(CLIRelay.fullPrompt(.claude, request()) == "Hello?")
        precondition(CLIRelay.noWebPolicyTOML.contains("google_web_search") && CLIRelay.noWebPolicyTOML.contains("\"deny\""))
    }
}
