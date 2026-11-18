import Foundation

// MARK: - The chat on your own subscription (GitHub build)
//
// With "Use my subscription" on in Settings → Chat, the chat is answered by the
// official terminal tool of the user's AI, signed in with their own account: Claude
// Code (Claude plan), Antigravity CLI or Gemini CLI (Google AI plan), Codex CLI
// (ChatGPT plan), Cursor CLI and GitHub Copilot CLI. Coucou reads no credential and
// makes no network call of its own: the tool answers exactly as it does in a terminal.
//
// Each run is kept apart from the user's own sessions: nothing saved to resume, no
// user hooks, MCP servers, extensions or plugins where the tool lets us turn them off,
// and it runs in an empty folder of Coucou's, so no project instructions are picked up.
// It may search the web for the chat and nothing else: no shell, no edits. A dropped
// file is read with no web at all (a file written to steer the model could otherwise
// send what it reads to a website): Claude Code reads a copy of that one file, the
// other tools get its text in the prompt.
//
// This file is pure (Foundation only) so scripts/test-cli-relay.sh can test it;
// CLIRelayRun.swift starts the processes. The App Store build is sandboxed and can't
// start them: there the chat still needs a key.

enum SubscriptionCLI: String, CaseIterable, Sendable {
    case claude, antigravity, gemini, codex, cursor, copilot

    var displayName: String {
        switch self {
        case .claude:      "Claude Code"
        case .antigravity: "Antigravity CLI"
        case .gemini:      "Gemini CLI"
        case .codex:       "Codex CLI"
        case .cursor:      "Cursor CLI"
        case .copilot:     "Copilot CLI"
        }
    }

    /// Its executable names, the official one first.
    var binaries: [String] {
        switch self {
        case .claude:      ["claude"]
        case .antigravity: ["agy"]
        case .gemini:      ["gemini"]
        case .codex:       ["codex"]
        case .cursor:      ["cursor-agent", "agent"]
        case .copilot:     ["copilot"]
        }
    }

    /// What to type once in a terminal to sign in.
    var signIn: String {
        switch self {
        case .claude:      "claude"
        case .antigravity: "agy"
        case .gemini:      "gemini"
        case .codex:       "codex login"
        case .cursor:      "cursor-agent login"
        case .copilot:     "copilot"
        }
    }

    /// Where it is installed from (opened in the browser from Settings).
    var installURL: String {
        switch self {
        case .claude:      "https://code.claude.com/docs/en/setup"
        case .antigravity: "https://antigravity.google/docs/cli"
        case .gemini:      "https://geminicli.com"
        case .codex:       "https://developers.openai.com/codex/cli"
        case .cursor:      "https://cursor.com/cli"
        case .copilot:     "https://docs.github.com/copilot/how-tos/copilot-cli"
        }
    }

    /// The prompt goes in on stdin; the others take it as an argument.
    var promptOnStdin: Bool { self == .claude || self == .codex }
}

struct CLIRequest: Sendable {
    /// nil: the tool's own default model.
    var model: String?
    var system: String
    var prompt: String
    /// Web search for the chat; off while a dropped file is read.
    var web: Bool
    /// Claude Code only: the folder holding the copy of the dropped file it may read.
    var readDir: URL?
    /// Gemini CLI only: a policy file that denies its web tools (written by the runner).
    var noWebPolicy: URL?
    var timeout: TimeInterval
}

enum CLIFailure: LocalizedError, Equatable {
    case notInstalled(String)
    case timedOut(String)
    case noAnswer(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): return "\(name) is not installed."
        case .timedOut(let name):     return "\(name) took too long to answer."
        case .noAnswer(let name):     return "\(name) gave no answer."
        case .failed(let why):        return why
        }
    }
}

enum CLIRelay {

    /// The Gemini CLI policy that keeps a run off the web (see `CLIRequest.noWebPolicy`).
    static let noWebPolicyTOML = """
    [[rule]]
    toolName = ["google_web_search", "web_fetch"]
    decision = "deny"
    priority = 900
    denyMessage = "No web while Coucou reads a file."

    """

    /// The prompt as the tool receives it: Claude Code takes the system prompt apart,
    /// the others get it on top.
    static func fullPrompt(_ cli: SubscriptionCLI, _ r: CLIRequest) -> String {
        if cli == .claude { return r.prompt }
        return "<instructions>\n\(r.system)\n</instructions>\n\n\(r.prompt)"
    }

    /// The command line of one run. Pure, so it can be tested.
    static func arguments(_ cli: SubscriptionCLI, _ r: CLIRequest) -> [String] {
        let model = r.model.flatMap { $0.isEmpty ? nil : $0 }
        switch cli {
        case .claude:
            let tools = r.readDir != nil ? ["Read"] : (r.web ? ["WebSearch", "WebFetch"] : [])
            var out = ["-p", "--output-format", "json"]
            if let model { out += ["--model", model] }
            out += ["--system-prompt", r.system, "--tools", tools.joined(separator: ",")]
            if !tools.isEmpty { out += ["--allowedTools", tools.joined(separator: ",")] }
            if let dir = r.readDir { out += ["--add-dir", dir.path] }
            return out + ["--setting-sources", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"]

        case .gemini:
            // Plan mode: read-only tools and Google search, nothing that writes or runs.
            var out = ["-p", fullPrompt(cli, r), "--output-format", "json", "--approval-mode", "plan",
                       "--skip-trust", "--extensions", "none", "--allowed-mcp-server-names", "coucou-none"]
            if let model { out += ["--model", model] }
            if !r.web, let policy = r.noWebPolicy { out += ["--policy", policy.path] }
            return out

        case .antigravity:
            var out = ["-p", fullPrompt(cli, r), "--output-format", "json", "--mode", "plan", "--disable-slash-commands"]
            if let model { out += ["--model", model] }
            return out

        case .codex:
            // Read-only sandbox and no shell at all: it can only answer (and search, for the chat).
            var out = r.web ? ["--search"] : []
            out += ["exec", "--json", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                    "--sandbox", "read-only", "--color", "never"]
            for feature in ["shell_tool", "unified_exec", "apps", "plugins", "hooks"] { out += ["--disable", feature] }
            if let model { out += ["--model", model] }
            return out + ["-"]

        case .cursor:
            // Ask mode: answers and reads, never edits or runs (no --force).
            var out = ["-p", fullPrompt(cli, r), "--output-format", "json", "--mode", "ask", "--trust"]
            if let model { out += ["--model", model] }
            return out

        case .copilot:
            var out = ["-p", fullPrompt(cli, r), "--silent", "--no-custom-instructions", "--disable-builtin-mcps",
                       "--no-ask-user", "--no-auto-update", "--no-color"]
            out += r.web ? ["--available-tools", "web_fetch", "--allow-all-urls"] : ["--available-tools", "view"]
            if let model { out += ["--model", model] }
            return out
        }
    }

    /// The answer's text, or why there is none.
    static func parse(_ cli: SubscriptionCLI, stdout: Data, stderr: Data, exitCode: Int32) -> Result<String, CLIFailure> {
        let detail = lastLine(stderr)
        let result: Result<String, CLIFailure>
        switch cli {
        case .claude, .cursor:
            result = parseResultObject(cli, stdout)
        case .gemini, .antigravity:
            result = parseResponseObject(cli, stdout, stderr)
        case .codex:
            result = parseCodexEvents(cli, stdout)
        case .copilot:
            let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            result = exitCode == 0 && !text.isEmpty ? .success(text) : .failure(.noAnswer(cli.displayName))
        }
        guard case .failure(let failure) = result else { return result }
        // Not signed in: say how to sign in rather than the tool's own wording only.
        let said: String = {
            if case .failed(let why) = failure { return why }
            return detail
        }()
        if needsSignIn(said) {
            return .failure(.failed("\(cli.displayName) is not signed in. Sign in once in Terminal: \(cli.signIn)"))
        }
        if case .failed = failure { return .failure(failure) }
        return detail.isEmpty ? .failure(failure) : .failure(.failed("\(failure.localizedDescription) (\(detail))"))
    }

    /// One chat turn as a single prompt: the earlier turns, the context the first
    /// question carries, then the question.
    static func chatPrompt(history: [(user: String, assistant: String)], context: String?, query: String) -> String {
        var out = ""
        if !history.isEmpty {
            out += "The conversation so far:\n<conversation>\n"
            for turn in history {
                out += "<user>\n\(turn.user)\n</user>\n<assistant>\n\(turn.assistant)\n</assistant>\n"
            }
            out += "</conversation>\n\nThe user's new message:\n"
        }
        if let context { out += context + "\n\n" }
        return out + query
    }

    // MARK: - Output formats

    /// `claude -p` and Cursor's `--output-format json`: `{"result": …, "is_error": …}`.
    private static func parseResultObject(_ cli: SubscriptionCLI, _ stdout: Data) -> Result<String, CLIFailure> {
        guard let json = lastJSONObject(stdout) else { return .failure(.noAnswer(cli.displayName)) }
        let text = (json["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if json["is_error"] as? Bool == true {
            return .failure(.failed(text.isEmpty ? "\(cli.displayName) could not answer." : text))
        }
        return text.isEmpty ? .failure(.noAnswer(cli.displayName)) : .success(text)
    }

    /// Gemini CLI and Antigravity CLI: `{"response": …, "error": {…}}`, the error on stderr too.
    private static func parseResponseObject(_ cli: SubscriptionCLI, _ stdout: Data, _ stderr: Data) -> Result<String, CLIFailure> {
        let out = lastJSONObject(stdout)
        let text = (out?["response"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return .success(text) }
        for json in [out, lastJSONObject(stderr)] {
            guard let json else { continue }
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
                return .failure(.failed(message))
            }
            if let message = json["error"] as? String, !message.isEmpty { return .failure(.failed(message)) }
        }
        return .failure(.noAnswer(cli.displayName))
    }

    /// `codex exec --json`: one event per line; the answer is the last finished agent message.
    private static func parseCodexEvents(_ cli: SubscriptionCLI, _ stdout: Data) -> Result<String, CLIFailure> {
        var answer: String?
        var failure: String?
        for line in String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let text = item["text"] as? String, !text.isEmpty {
                    answer = text
                }
            case "turn.failed":
                if let error = event["error"] as? [String: Any], let message = error["message"] as? String {
                    failure = message
                }
            case "error":
                if let message = event["message"] as? String { failure = message }
            default:
                break
            }
        }
        if let answer { return .success(answer.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let failure { return .failure(.failed(failure)) }
        return .failure(.noAnswer(cli.displayName))
    }

    /// The last JSON object in a tool's output (some print a line or two before it).
    static func lastJSONObject(_ data: Data) -> [String: Any]? {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { return json }
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "\n{", options: .backwards)?.lowerBound else { return nil }
        let tail = text[text.index(after: start)...]
        return (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any]
    }

    /// The last line a tool wrote on stderr, without terminal colours.
    static func lastLine(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }

    static func needsSignIn(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["log in", "login", "logged in", "authenticat", "unauthorized", "401", "sign in", "signed in",
                "auth method", "invalid api key"].contains { t.contains($0) }
    }
}
