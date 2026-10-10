import Foundation

/// A coding-agent command line the user already signed in to. Coucou chats through it by running
/// the tool's own non-interactive command: the tool does the sign-in, Coucou never sees a key or token.
struct CLIChatTool: Equatable, Sendable {
    struct Model: Equatable, Sendable { let id: String; let label: String }
    /// Which command line it is: each one has its own arguments and output format.
    enum Kind: Equatable, Sendable { case claudeCode, copilot, gemini, codex, opencode }

    let kind: Kind
    let id: String
    let name: String
    let binary: String
    let colorHex: String
    let models: [Model]
    let defaultModel: String
    /// Shown when the tool is installed but not signed in.
    let signInHint: String
    /// False for a tool whose chat command was written from its documentation and never run here.
    var isVerified = true
}

/// What a tool says about its sign-in.
struct CLIAuthStatus: Equatable, Sendable {
    let isSignedIn: Bool
    /// e.g. "Pro" or "Max"; nil when the tool does not say.
    let plan: String?
    /// Why a tool that is signed in, or looks it, still cannot chat. Shown instead of the sign-in hint.
    var problem: String? = nil
}

/// One line of the "Connected on this Mac" list.
struct ConnectedItem: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable { case connected, attention }
    let id: String
    let name: String
    let detail: String
    let status: Status
    /// The chat command of this tool was never run by the Coucou authors.
    var isUntested = false
}

/// One event of a tool's streamed reply.
enum CLIStreamEvent: Equatable, Sendable {
    case text(String)
    case finished(String)
    case failed(String)
}

enum CLIChatTools {

    static let claudeCode = CLIChatTool(
        kind: .claudeCode, id: "claude-code", name: "Claude Code", binary: "claude", colorHex: "#E07950",
        // Newest first, then the aliases that always follow the newest of each family. Claude Code
        // has no command that lists models, so the exact IDs are kept here; each was checked to run.
        models: [
            .init(id: "claude-fable-5-1", label: "Fable 5.1"),
            .init(id: "claude-opus-5-5", label: "Opus 5.5"),
            .init(id: "claude-sonnet-5-5", label: "Sonnet 5.5"),
            .init(id: "claude-haiku-5-5", label: "Haiku 5.5"),
            .init(id: "claude-opus-4-5", label: "Opus 4.5"),
            .init(id: "claude-sonnet-4-6", label: "Sonnet 4.6"),
            .init(id: "claude-sonnet-4-5", label: "Sonnet 4.5"),
            .init(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5"),
            .init(id: "opus", label: "Opus (always the latest)"),
            .init(id: "sonnet", label: "Sonnet (always the latest)"),
            .init(id: "haiku", label: "Haiku (always the latest)"),
        ],
        defaultModel: "sonnet",
        signInHint: String(localized: "Run `claude` in Terminal and sign in, then scan again."))

    /// GitHub Copilot CLI. It cannot list its models without a chat, so only "auto" is offered.
    static let copilot = CLIChatTool(
        kind: .copilot, id: "copilot-cli", name: "GitHub Copilot", binary: "copilot", colorHex: "#818CF8",
        models: [.init(id: "auto", label: "Auto (Copilot picks)")],
        defaultModel: "auto",
        signInHint: String(localized: "Run `copilot` in Terminal, type /login, then scan again."))

    /// Gemini CLI. Sign-in states were checked; a reply never was (Google refused the test account).
    static let gemini = CLIChatTool(
        kind: .gemini, id: "gemini-cli", name: "Gemini CLI", binary: "gemini", colorHex: "#8AB4F8",
        models: [
            .init(id: "default", label: "Default (Gemini picks)"),
            .init(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro"),
            .init(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash"),
            .init(id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash-Lite"),
        ],
        defaultModel: "default",
        signInHint: String(localized: "Run `gemini` in Terminal and sign in, then scan again."),
        isVerified: false)

    /// OpenAI Codex CLI (the one inside VS Code's ChatGPT extension works too). Its model list is
    /// not offered: "default" lets Codex use the one set for the user's account.
    static let codex = CLIChatTool(
        kind: .codex, id: "codex", name: "Codex", binary: "codex", colorHex: "#2DD4BF",
        models: [.init(id: "default", label: "Default (Codex picks)")],
        defaultModel: "default",
        signInHint: String(localized: "Run `codex login` in Terminal, then scan again."))

    /// opencode CLI. Not installed where this was written: from its documentation only.
    static let opencode = CLIChatTool(
        kind: .opencode, id: "opencode", name: "opencode", binary: "opencode", colorHex: "#4ADE80",
        models: [.init(id: "default", label: "Default (opencode picks)")],
        defaultModel: "default",
        signInHint: String(localized: "Run `opencode auth login` in Terminal, then scan again."),
        isVerified: false)

    /// Add a tool here, with its arguments and parser below, to offer it in the chat.
    static let all: [CLIChatTool] = [claudeCode, copilot, gemini, codex, opencode]

    static func tool(id: String?) -> CLIChatTool? { all.first { $0.id == id } }

    // MARK: Finding the binary

    /// Where a GUI app should look: it does not inherit the shell's PATH.
    static func binaryCandidates(_ binary: String, home: String, nodeVersions: [String] = []) -> [String] {
        var dirs = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                    "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.opencode/bin"]
        dirs += nodeVersions.map { "\(home)/.nvm/versions/node/\($0)/bin" }
        return dirs.map { "\($0)/\(binary)" }
    }

    /// Codex also ships inside VS Code's ChatGPT extension, one folder per version.
    static func extensionBinaryCandidates(_ tool: CLIChatTool, home: String, extensionFolders: [String]) -> [String] {
        guard tool.kind == .codex else { return [] }
        return extensionFolders.filter { $0.hasPrefix("openai.chatgpt-") }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .flatMap { folder in ["macos-aarch64", "macos-x86_64"].map { "\(home)/.vscode/extensions/\(folder)/bin/\($0)/codex" } }
    }

    // MARK: Claude Code

    static let claudeStatusArguments = ["auth", "status", "--json"]

    /// Headless, no tools, no hooks, no MCP servers, no skills and nothing saved to disk:
    /// a plain chat that does not start an agent session, so it never shows up as one in the island.
    /// Returns nil for a model the tool does not offer, so nothing odd reaches the command line.
    static func claudeArguments(model: String, systemPrompt: String) -> [String]? {
        guard claudeCode.models.contains(where: { $0.id == model }) else { return nil }
        return ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                "--model", model, "--tools", "", "--no-session-persistence",
                "--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands",
                "--system-prompt", systemPrompt]
    }

    static func parseClaudeAuthStatus(_ data: Data) -> CLIAuthStatus? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signedIn = json["loggedIn"] as? Bool else { return nil }
        let plan = (json["subscriptionType"] as? String).flatMap { $0.isEmpty ? nil : $0.capitalized }
        return CLIAuthStatus(isSignedIn: signedIn, plan: plan)
    }

    /// Reads one line of `--output-format stream-json`. Lines that are not text or a result are skipped.
    static func parseClaudeLine(_ line: String) -> CLIStreamEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "result":
            let text = json["result"] as? String ?? ""
            return json["is_error"] as? Bool == true ? .failed(text) : .finished(text)
        default:
            return nil
        }
    }

    // MARK: GitHub Copilot CLI

    /// A model name that cannot exist: a signed-in Copilot answers "is not available" at once and a
    /// signed-out one says it has no authentication, and neither spends a request.
    static let copilotStatusArguments = ["-p", "x", "-s", "--no-ask-user", "--available-tools",
                                         "--model", "coucou-sign-in-check"]

    /// No tools, no MCP servers, nothing to ask the user: a plain chat. The prompt comes on stdin.
    static func copilotArguments(model: String) -> [String]? {
        guard copilot.models.contains(where: { $0.id == model }) else { return nil }
        return ["-s", "--no-ask-user", "--available-tools", "--disable-builtin-mcps",
                "--output-format", "json", "--stream", "on", "--model", model]
    }

    static func parseCopilotStatus(_ output: String) -> CLIAuthStatus? {
        if output.contains("No authentication information found") { return CLIAuthStatus(isSignedIn: false, plan: nil) }
        if output.contains("is not available") { return CLIAuthStatus(isSignedIn: true, plan: nil) }
        return nil
    }

    /// One JSON line of `--output-format json`: text deltas, the final message, and the exit result.
    static func parseCopilotLine(_ line: String) -> CLIStreamEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "assistant.message_delta":
            guard let text = (json["data"] as? [String: Any])?["deltaContent"] as? String else { return nil }
            return .text(text)
        case "assistant.message":
            guard let text = (json["data"] as? [String: Any])?["content"] as? String else { return nil }
            return .finished(text)
        case "result":
            let code = json["exitCode"] as? Int ?? 0
            return code == 0 ? nil : .failed("Copilot stopped with code \(code).")
        default:
            return nil
        }
    }

    // MARK: Per tool

    static func statusArguments(_ tool: CLIChatTool) -> [String] {
        switch tool.kind {
        case .claudeCode: return claudeStatusArguments
        case .copilot:    return copilotStatusArguments
        case .gemini:     return geminiStatusArguments
        case .codex:      return ["login", "status"]
        case .opencode:   return ["auth", "list"]
        }
    }

    static func parseStatus(_ tool: CLIChatTool, output: String) -> CLIAuthStatus? {
        switch tool.kind {
        case .claudeCode: return parseClaudeAuthStatus(Data(output.utf8))
        case .copilot:    return parseCopilotStatus(output)
        case .gemini:     return parseGeminiStatus(output)
        case .codex:      return parseCodexStatus(output)
        case .opencode:   return parseOpencodeStatus(output)
        }
    }

    /// nil for a model the tool does not offer. `prompt` only matters to a tool that takes it as an argument.
    static func chatArguments(_ tool: CLIChatTool, model: String, systemPrompt: String, prompt: String = "") -> [String]? {
        guard tool.models.contains(where: { $0.id == model }) else { return nil }
        switch tool.kind {
        case .claudeCode: return claudeArguments(model: model, systemPrompt: systemPrompt)
        case .copilot:    return copilotArguments(model: model)
        case .gemini:     return geminiArguments(model: model)
        case .codex:      return codexArguments(model: model)
        case .opencode:   return opencodeArguments(model: model, prompt: prompt)
        }
    }

    /// The whole prompt. Only Claude Code has a system-prompt option; for the others the
    /// instructions lead the prompt.
    static func promptInput(_ tool: CLIChatTool, systemPrompt: String, transcript: String) -> String {
        tool.kind == .claudeCode ? transcript : "Instructions for this chat: \(systemPrompt)\n\n\(transcript)"
    }

    /// opencode takes the message as an argument; every other tool reads it on stdin.
    static func sendsPromptAsArgument(_ tool: CLIChatTool) -> Bool { tool.kind == .opencode }

    /// Extra environment for the command. opencode runs without asking, so it is told to refuse every tool.
    static func environment(_ tool: CLIChatTool) -> [String: String] {
        tool.kind == .opencode
            ? ["OPENCODE_CONFIG_CONTENT": #"{"permission":{"edit":"deny","bash":"deny","webfetch":"deny"}}"#]
            : [:]
    }

    static func parseLine(_ tool: CLIChatTool, _ line: String) -> CLIStreamEvent? {
        switch tool.kind {
        case .claudeCode: return parseClaudeLine(line)
        case .copilot:    return parseCopilotLine(line)
        case .gemini:     return parseGeminiLine(line)
        case .codex:      return parseCodexLine(line)
        case .opencode:   return parseOpencodeLine(line)
        }
    }

    /// The tool prints its errors on stderr for some commands and stdout for others.
    static func statusNeedsStderr(_ tool: CLIChatTool) -> Bool { tool.kind != .claudeCode }

    // MARK: Gemini CLI

    /// A model name that cannot exist, like Copilot's: the answer shows the sign-in state at no cost.
    static let geminiStatusArguments = ["-p", "x", "-m", "coucou-sign-in-check", "--skip-trust", "-e", "none", "-o", "json"]

    /// Headless, no extensions, tools that need approval are refused. The conversation arrives on stdin.
    static func geminiArguments(model: String) -> [String] {
        var args = ["-p", "Reply to the conversation given on stdin. Answer the last User message.",
                    "-o", "stream-json", "--skip-trust", "--approval-mode", "default", "-e", "none"]
        if model != "default" { args += ["-m", model] }
        return args
    }

    /// Seen on a real install: signed out, and signed in but refused by Google. The working case is
    /// recognised by the model error a signed-in, eligible account gets for an unknown model.
    static func parseGeminiStatus(_ output: String) -> CLIAuthStatus? {
        if output.contains("Please set an Auth method") { return CLIAuthStatus(isSignedIn: false, plan: nil) }
        if output.contains("IneligibleTierError") {
            return CLIAuthStatus(isSignedIn: false, plan: nil, problem: String(localized: "Signed in, but Google no longer lets Gemini CLI chat with a personal account. Use a Gemini API key, or Antigravity."))
        }
        // The login is there but Google no longer accepts it (expired or revoked).
        if output.contains("invalid authentication credentials") || output.contains("UNAUTHENTICATED") {
            return CLIAuthStatus(isSignedIn: false, plan: nil, problem: String(localized: "Gemini CLI is signed in, but Google rejects the login. Run `gemini` in Terminal and sign in again."))
        }
        let lower = output.lowercased()
        if lower.contains("not found") && lower.contains("model") { return CLIAuthStatus(isSignedIn: true, plan: nil) }
        return nil
    }

    /// `--output-format stream-json`: one object per line; assistant `message` events carry the text.
    static func parseGeminiLine(_ line: String) -> CLIStreamEvent? {
        guard let json = jsonObject(line), json["type"] as? String == "message",
              json["role"] as? String == "assistant", let text = json["content"] as? String else {
            if let json = jsonObject(line), json["type"] as? String == "result",
               json["status"] as? String == "error" {
                let message = (json["error"] as? [String: Any])?["message"] as? String
                return .failed(message ?? "Gemini CLI failed.")
            }
            return nil
        }
        return .text(text)
    }

    // MARK: Codex

    /// Read-only sandbox, nothing saved, the user's own config and rules left out (so no hooks run),
    /// prompt on stdin (`-`). The reply arrives as one message.
    static func codexArguments(model: String) -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                    "--ignore-user-config", "--ignore-rules"]
        if model != "default" { args += ["-m", model] }
        return args + ["-"]
    }

    static func parseCodexStatus(_ output: String) -> CLIAuthStatus? {
        let lower = output.lowercased()
        if lower.contains("not logged in") { return CLIAuthStatus(isSignedIn: false, plan: nil) }
        if lower.contains("logged in") { return CLIAuthStatus(isSignedIn: true, plan: nil) }
        return nil
    }

    static func parseCodexLine(_ line: String) -> CLIStreamEvent? {
        guard let json = jsonObject(line), let type = json["type"] as? String else { return nil }
        if type == "item.completed", let item = json["item"] as? [String: Any],
           item["type"] as? String == "agent_message", let text = item["text"] as? String {
            return .finished(text)
        }
        if type == "turn.failed" {
            return .failed((json["error"] as? [String: Any])?["message"] as? String ?? "Codex failed.")
        }
        return nil
    }

    // MARK: opencode

    /// `opencode run` with the message as the last argument and JSON events out.
    static func opencodeArguments(model: String, prompt: String) -> [String] {
        var args = ["run", "--format", "json"]
        if model != "default" { args += ["--model", model] }
        return args + [prompt]
    }

    /// `opencode auth list` ends with a count such as "1 credentials"; a count above 0 means a provider is set up.
    static func parseOpencodeStatus(_ output: String) -> CLIAuthStatus? {
        let clean = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let counts = clean.matches(of: /(\d+)\s+(?:credentials?|environment variables?)/).compactMap { Int($0.1) }
        guard !counts.isEmpty else { return nil }
        return CLIAuthStatus(isSignedIn: counts.reduce(0, +) > 0, plan: nil)
    }

    static func parseOpencodeLine(_ line: String) -> CLIStreamEvent? {
        guard let json = jsonObject(line), let type = json["type"] as? String else { return nil }
        if type == "text", let part = json["part"] as? [String: Any], let text = part["text"] as? String {
            return .finished(text)
        }
        if type == "error" {
            let error = json["error"] as? [String: Any]
            let message = (error?["data"] as? [String: Any])?["message"] as? String ?? error?["message"] as? String
            return .failed(message ?? "opencode failed.")
        }
        return nil
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: Conversation

    /// The tool is asked one question at a time, so earlier turns travel inside the prompt.
    static func transcript(_ messages: [(role: String, content: String)]) -> String {
        let turns = messages.filter { $0.role == "user" || $0.role == "assistant" }
        guard turns.count > 1 else { return turns.first?.content ?? "" }
        let body = turns.map { ($0.role == "user" ? "User: " : "Assistant: ") + $0.content }
            .joined(separator: "\n\n")
        return "This is the conversation so far.\n\n\(body)\n\nReply to the last User message."
    }

    // MARK: Connected list

    static func connectedItem(for tool: CLIChatTool, status: CLIAuthStatus) -> ConnectedItem {
        if status.isSignedIn {
            return .init(id: tool.id, name: tool.name,
                         detail: status.plan.map { String(format: String(localized: "Signed in · %@"), $0) }
                                 ?? String(localized: "Signed in"),
                         status: .connected, isUntested: !tool.isVerified)
        }
        return .init(id: tool.id, name: tool.name, detail: status.problem ?? tool.signInHint,
                     status: .attention, isUntested: !tool.isVerified)
    }

    /// A provider that talks through a command line instead of a URL.
    static func provider(for tool: CLIChatTool) -> CustomProvider {
        CustomProvider(id: tool.id, name: tool.name, baseURL: "", requiresKey: false,
                       model: tool.defaultModel, colorHex: tool.colorHex, cliTool: tool.id)
    }
}
