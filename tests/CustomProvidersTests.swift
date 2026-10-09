import Foundation

@main
enum CustomProvidersTests {
    static func main() throws {
        var cases = 0
        func check(_ ok: Bool, _ what: String, line: UInt = #line) {
            precondition(ok, "\(what) (line \(line))")
            cases += 1
        }

        // URL normalisation keeps the version path and strips the endpoint people paste.
        check(CustomProviders.normaliseBaseURL("https://api.groq.com/openai/v1/") == "https://api.groq.com/openai/v1", "trailing slash")
        check(CustomProviders.normaliseBaseURL("  https://openrouter.ai/api/v1/chat/completions ") == "https://openrouter.ai/api/v1", "pasted completions URL")
        check(CustomProviders.normaliseBaseURL("https://x.ai/v1/models") == "https://x.ai/v1", "pasted models URL")
        check(CustomProviders.normaliseBaseURL("http://127.0.0.1:8080/v1") == "http://127.0.0.1:8080/v1", "local http")
        for bad in ["", "groq", "ftp://a.b/v1", "https://", "https://u:p@a.b/v1", "https://a.b/v1?key=1", "https://a.b/v1#x", "javascript:alert(1)"] {
            check(CustomProviders.normaliseBaseURL(bad) == nil, "rejects \(bad)")
        }

        // A key never goes over plain http beyond this Mac and the local network.
        for ok in ["https://api.groq.com/v1", "http://localhost:1234/v1", "http://127.0.0.1:11434/v1", "http://[::1]:8080/v1",
                   "http://192.168.1.20:8000/v1", "http://10.0.0.5/v1", "http://172.20.1.1/v1", "http://studio.local:1234/v1"] {
            check(CustomProviders.isTransportAllowed(ok), "allows \(ok)")
        }
        for bad in ["http://api.groq.com/v1", "http://8.8.8.8/v1", "http://172.32.0.1/v1", "http://192.169.0.1/v1", "http://localhost.evil.com/v1", "ws://localhost/v1"] {
            check(!CustomProviders.isTransportAllowed(bad), "blocks \(bad)")
        }

        // Slugs are stable, ASCII and unique.
        check(CustomProviders.slug(from: "Groq", existing: []) == "groq", "slug basic")
        check(CustomProviders.slug(from: "Groq", existing: ["groq"]) == "groq-2", "slug unique")
        check(CustomProviders.slug(from: "Groq", existing: ["groq", "groq-2"]) == "groq-3", "slug unique twice")
        check(CustomProviders.slug(from: "Z.AI  (China)", existing: []) == "z-ai-china", "slug punctuation")
        check(CustomProviders.slug(from: "Café Möbius", existing: []) == "cafe-mobius", "slug diacritics")
        check(CustomProviders.slug(from: "日本語", existing: []) == "provider", "slug non-ascii falls back")
        check(CustomProviders.slug(from: "../../etc", existing: []) == "etc", "slug has no path characters")
        check(CustomProviders.keychainKey(forID: "groq") == "custom-ai-key-groq", "keychain key")
        check(CustomProviders.color(forID: "groq") == CustomProviders.color(forID: "groq"), "colour stable")

        // Model list: OpenAI shape, chat models only, newest first when dated.
        let dated = Data(#"{"data":[{"id":"old","created":1},{"id":"text-embedding-3","created":9},{"id":"new","created":5},{"id":"models/gem","created":3}]}"#.utf8)
        check(CustomProviders.parseModelList(dated)?.map(\.id) == ["new", "gem", "old"], "dated order + filter + models/ prefix")
        let undated = Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8)
        check(CustomProviders.parseModelList(undated)?.map(\.id) == ["b", "a"], "server order kept")
        check(CustomProviders.parseModelList(Data(#"{"data":[]}"#.utf8))?.isEmpty == true, "empty list is a list")
        check(CustomProviders.parseModelList(Data(#"{"object":"list","data":null}"#.utf8))?.isEmpty == true, "Ollama with no models is an empty list")
        check(CustomProviders.parseModelList(Data(#"{"object":"list"}"#.utf8)) == nil, "list without data is not a model list")
        check(CustomProviders.parseModelList(Data(#"{"data":null}"#.utf8)) == nil, "null data without object=list is not a model list")
        check(CustomProviders.parseModelList(Data("<html>".utf8)) == nil, "html is not a model list")
        check(CustomProviders.parseModelList(Data(#"{"error":"nope"}"#.utf8)) == nil, "error body is not a model list")

        // Storage drops anything unsafe, keeps the rest.
        let good = CustomProvider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", requiresKey: true, model: "m", colorHex: "#fff")
        let leaky = CustomProvider(id: "evil", name: "Evil", baseURL: "http://api.evil.com/v1", requiresKey: true, model: "m", colorHex: "#fff")
        let messy = CustomProvider(id: "messy", name: "Messy", baseURL: "https://a.b/v1/", requiresKey: true, model: "m", colorHex: "#fff")
        let stored = CustomProviders.decodeProviders(CustomProviders.encodeProviders([good, leaky, messy]))
        check(stored == [good], "decode keeps only safe, normalised providers")
        check(CustomProviders.decodeProviders(nil).isEmpty && CustomProviders.decodeProviders(Data("junk".utf8)).isEmpty, "decode survives junk")
        check(good.keychainKey == "custom-ai-key-groq", "provider keychain key")

        // Local scan list: built-ins map to their own settings, ports are distinct.
        let known = CustomProviders.knownLocalServers
        check(known.map(\.baseURL).count == Set(known.map(\.baseURL)).count, "distinct probe URLs")
        check(known.allSatisfy { CustomProviders.normaliseBaseURL($0.baseURL) == $0.baseURL && CustomProviders.isTransportAllowed($0.baseURL) }, "probe URLs are valid and local")
        check(known.filter { $0.builtInID != nil }.map(\.name) == ["Ollama", "LM Studio"], "built-in local servers")

        // Bundled catalog: valid, unique, safe, and never duplicates a built-in provider.
        let catalog = CustomProviders.decodeCatalog(try Data(contentsOf: URL(fileURLWithPath: "NotchBuddy/Resources/providers.json")))
        check(catalog.count > 100, "catalog has \(catalog.count) providers")
        check(Set(catalog.map(\.id)).count == catalog.count, "catalog ids unique")
        check(catalog.allSatisfy { CustomProviders.normaliseBaseURL($0.baseURL) == $0.baseURL && CustomProviders.isTransportAllowed($0.baseURL) }, "catalog URLs are normalised https")
        check(catalog.allSatisfy { !$0.baseURL.contains("${") && !$0.name.isEmpty }, "catalog has no template URLs")
        let builtIns: Set<String> = ["anthropic", "google", "openai", "ollama", "lmstudio"]
        check(catalog.allSatisfy { !builtIns.contains($0.id) }, "catalog skips built-ins")
        check(Array(catalog.prefix(3)).map(\.id) == ["openrouter", "groq", "mistral"], "popular providers first")
        check(CustomProviders.search(catalog, "groq").contains { $0.id == "groq" }, "search by name")
        check(CustomProviders.search(catalog, "OPENROUTER.AI").first?.id == "openrouter", "search by URL, case-insensitive")
        check(CustomProviders.search(catalog, "").count == catalog.count, "empty search returns all")

        // Claude Code through its own command line: arguments, parsing, conversation, storage.
        let claude = CLIChatTools.claudeCode
        let args = CLIChatTools.claudeArguments(model: "sonnet", systemPrompt: "Be brief.")
        check(args?.first == "-p" && args?.contains("stream-json") == true, "headless stream-json")
        check(args?.contains("--no-session-persistence") == true && args?.contains("--strict-mcp-config") == true, "nothing saved, no MCP")
        if let args, let i = args.firstIndex(of: "--tools") { check(args[i + 1] == "", "no tools") } else { check(false, "no tools flag") }
        if let args, let i = args.firstIndex(of: "--setting-sources") { check(args[i + 1] == "", "no hooks or settings loaded") } else { check(false, "setting-sources flag") }
        if let args, let i = args.firstIndex(of: "--system-prompt") { check(args[i + 1] == "Be brief.", "system prompt passed whole") } else { check(false, "system prompt flag") }
        check(CLIChatTools.claudeArguments(model: "sonnet; rm -rf /", systemPrompt: "x") == nil, "unknown model is refused")
        check(CLIChatTools.claudeArguments(model: "--dangerously-skip-permissions", systemPrompt: "x") == nil, "flag-like model is refused")
        check(claude.models.map(\.id).contains(claude.defaultModel), "default model is offered")
        check(claude.models.map(\.id).contains("claude-opus-5-5") && claude.models.map(\.id).contains("claude-haiku-4-5-20251001"), "exact model numbers are offered")
        check(Set(claude.models.map(\.id)).count == claude.models.count, "model ids are unique")
        check(claude.models.allSatisfy { !$0.id.hasPrefix("-") && !$0.id.contains(" ") }, "model ids cannot pass for flags")
        check(CLIChatTools.claudeArguments(model: "claude-sonnet-4-6", systemPrompt: "x") != nil, "exact model id is accepted")

        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"po"}}}"#
        check(CLIChatTools.parseClaudeLine(delta) == .text("po"), "text delta")
        let thinking = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}}"#
        check(CLIChatTools.parseClaudeLine(thinking) == nil, "thinking is not shown")
        check(CLIChatTools.parseClaudeLine(#"{"type":"result","subtype":"success","is_error":false,"result":"pong"}"#) == .finished("pong"), "result")
        check(CLIChatTools.parseClaudeLine(#"{"type":"result","is_error":true,"result":"Not logged in"}"#) == .failed("Not logged in"), "error result")
        check(CLIChatTools.parseClaudeLine(#"{"type":"system","subtype":"init"}"#) == nil, "init is skipped")
        check(CLIChatTools.parseClaudeLine("not json") == nil && CLIChatTools.parseClaudeLine("") == nil, "junk is skipped")

        let signedIn = Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro","email":"a@b.c"}"#.utf8)
        check(CLIChatTools.parseClaudeAuthStatus(signedIn) == CLIAuthStatus(isSignedIn: true, plan: "Pro"), "signed in, plan")
        check(CLIChatTools.parseClaudeAuthStatus(Data(#"{"loggedIn":false}"#.utf8)) == CLIAuthStatus(isSignedIn: false, plan: nil), "signed out")
        check(CLIChatTools.parseClaudeAuthStatus(Data("<html>".utf8)) == nil, "unreadable status")
        check(CLIChatTools.connectedItem(for: claude, status: CLIAuthStatus(isSignedIn: true, plan: "Pro")).detail == "Signed in · Pro", "item detail")
        check(CLIChatTools.connectedItem(for: claude, status: CLIAuthStatus(isSignedIn: false, plan: nil)).status == .attention, "item needs sign-in")

        check(CLIChatTools.transcript([("user", "hi")]) == "hi", "single turn is the bare question")
        let multi = CLIChatTools.transcript([("user", "a"), ("assistant", "b"), ("user", "c")])
        check(multi.contains("User: a") && multi.contains("Assistant: b") && multi.hasSuffix("Reply to the last User message."), "multi-turn transcript")
        check(CLIChatTools.transcript([("system", "s"), ("user", "q")]) == "q", "system turn is not in the transcript")

        let paths = CLIChatTools.binaryCandidates("claude", home: "/Users/me", nodeVersions: ["v22.1.0"])
        check(paths.first == "/Users/me/.local/bin/claude" && paths.contains("/opt/homebrew/bin/claude") && paths.contains("/Users/me/.nvm/versions/node/v22.1.0/bin/claude"), "binary search paths")

        // GitHub Copilot CLI: no tools, JSON stream, prompt on stdin, free sign-in check.
        let copilot = CLIChatTools.copilot
        let cArgs = CLIChatTools.chatArguments(copilot, model: "auto", systemPrompt: "Be brief.")
        check(cArgs?.contains("--available-tools") == true && cArgs?.contains("--disable-builtin-mcps") == true && cArgs?.contains("--no-ask-user") == true, "copilot: no tools, no MCP, no questions")
        check(cArgs?.contains("-p") == false, "copilot: prompt is not in the arguments")
        check(cArgs?.last == "auto" && cArgs?.contains("json") == true, "copilot: model and JSON output")
        check(CLIChatTools.chatArguments(copilot, model: "gpt-9; ls", systemPrompt: "x") == nil, "copilot: unknown model refused")
        check(CLIChatTools.statusArguments(copilot).contains("coucou-sign-in-check"), "copilot: sign-in check uses a model that cannot exist")
        check(CLIChatTools.statusArguments(claude) == ["auth", "status", "--json"], "claude: status command")
        let input = CLIChatTools.promptInput(copilot, systemPrompt: "Be brief.", transcript: "hi")
        check(input.hasPrefix("Instructions for this chat: Be brief.") && input.hasSuffix("hi"), "copilot: instructions lead the prompt")
        check(CLIChatTools.promptInput(claude, systemPrompt: "Be brief.", transcript: "hi") == "hi", "claude: system prompt goes in a flag, not the input")
        check(CLIChatTools.parseStatus(copilot, output: "Error: Model \"coucou-sign-in-check\" from --model flag is not available.\n") == CLIAuthStatus(isSignedIn: true, plan: nil), "copilot: signed in")
        check(CLIChatTools.parseStatus(copilot, output: "Error: No authentication information found.\n\nCopilot can be authenticated") == CLIAuthStatus(isSignedIn: false, plan: nil), "copilot: signed out")
        check(CLIChatTools.parseStatus(copilot, output: "") == nil && CLIChatTools.parseStatus(copilot, output: "something else") == nil, "copilot: unknown answer is unknown")
        let cDelta = #"{"type":"assistant.message_delta","data":{"messageId":"m","deltaContent":"pong"},"ephemeral":true,"id":"i"}"#
        let cFinal = #"{"type":"assistant.message","data":{"messageId":"m","model":"x","content":"pong","toolRequests":[]},"id":"i"}"#
        check(CLIChatTools.parseLine(copilot, cDelta) == .text("pong"), "copilot: text delta")
        check(CLIChatTools.parseLine(copilot, cFinal) == .finished("pong"), "copilot: final message")
        check(CLIChatTools.parseLine(copilot, #"{"type":"result","sessionId":"s","exitCode":0,"usage":{}}"#) == nil, "copilot: clean exit is not an event")
        check(CLIChatTools.parseLine(copilot, #"{"type":"result","sessionId":"s","exitCode":1,"usage":{}}"#) == .failed("Copilot stopped with code 1."), "copilot: failed exit")
        check(CLIChatTools.parseLine(copilot, #"{"type":"session.tools_updated","data":{}}"#) == nil && CLIChatTools.parseLine(copilot, "Error: x") == nil, "copilot: other lines skipped")
        check(CLIChatTools.parseLine(claude, cDelta) == nil, "claude parser ignores copilot lines")
        check(CLIChatTools.all.map(\.id) == ["claude-code", "copilot-cli", "gemini-cli", "codex", "opencode"] && Set(CLIChatTools.all.map(\.id)).count == CLIChatTools.all.count, "tool list")
        check(CLIChatTools.all.filter(\.isVerified).map(\.id) == ["claude-code", "copilot-cli", "codex"], "only run tools are marked verified")
        check(CLIChatTools.all.allSatisfy { CLIChatTools.chatArguments($0, model: $0.defaultModel, systemPrompt: "s", prompt: "p") != nil }, "every tool builds arguments for its default model")
        check(CLIChatTools.all.allSatisfy { CLIChatTools.chatArguments($0, model: "x; rm -rf /", systemPrompt: "s", prompt: "p") == nil }, "every tool refuses an unknown model")

        // Gemini CLI: states seen on a real install, then the chat command from its documentation.
        let gem = CLIChatTools.gemini
        let gemSignedOut = "Please set an Auth method in your /tmp/emptyhome/.gemini/settings.json or specify one of the following environment variables"
        let gemRefused = "Error authenticating: IneligibleTierError: This client is no longer supported for Gemini Code Assist for individuals."
        check(CLIChatTools.parseStatus(gem, output: gemSignedOut) == CLIAuthStatus(isSignedIn: false, plan: nil), "gemini: signed out")
        check(CLIChatTools.parseStatus(gem, output: gemRefused)?.isSignedIn == false && CLIChatTools.parseStatus(gem, output: gemRefused)?.problem?.contains("Antigravity") == true, "gemini: signed in but refused by Google")
        check(CLIChatTools.parseStatus(gem, output: "ModelNotFoundError: Requested entity was not found. model")?.isSignedIn == true, "gemini: working account")
        let gemRejected = #"Error when talking to Gemini API ... _ApiError: {"error":{"code":401,"message":"Request had invalid authentication credentials. Expected OAuth 2 access token"}} at async Models.generateContentStream"#
        check(CLIChatTools.parseStatus(gem, output: gemRejected)?.isSignedIn == false && CLIChatTools.parseStatus(gem, output: gemRejected)?.problem?.contains("sign in again") == true, "gemini: login rejected by Google is not signed in")
        check(CLIChatTools.parseStatus(gem, output: "") == nil, "gemini: no answer")
        let gemItem = CLIChatTools.connectedItem(for: gem, status: CLIChatTools.parseStatus(gem, output: gemRefused)!)
        check(gemItem.status == .attention && gemItem.detail.contains("Antigravity") && gemItem.isUntested, "gemini: refused account is flagged, not connected")
        check(CLIChatTools.statusArguments(gem).contains("coucou-sign-in-check") && CLIChatTools.statusArguments(gem).contains("none"), "gemini: free sign-in check, no extensions")
        let gArgs = CLIChatTools.chatArguments(gem, model: "gemini-2.5-flash", systemPrompt: "s")
        check(gArgs?.contains("stream-json") == true && gArgs?.suffix(2) == ["-m", "gemini-2.5-flash"] && gArgs?.contains("-e") == true, "gemini: headless stream, model flag")
        check(CLIChatTools.chatArguments(gem, model: "default", systemPrompt: "s")?.contains("-m") == false, "gemini: default model has no flag")
        check(CLIChatTools.parseLine(gem, #"{"type":"message","role":"assistant","content":"po","delta":true}"#) == .text("po"), "gemini: assistant text")
        check(CLIChatTools.parseLine(gem, #"{"type":"message","role":"user","content":"hi"}"#) == nil, "gemini: user echo skipped")
        check(CLIChatTools.parseLine(gem, #"{"type":"result","status":"error","error":{"message":"quota"}}"#) == .failed("quota"), "gemini: failed result")
        check(CLIChatTools.parseLine(gem, #"{"type":"result","status":"success"}"#) == nil, "gemini: ok result")

        // Codex: events seen on a real install (codex-cli 0.162). opencode: from its documentation, never run here.
        let cdx = CLIChatTools.codex
        check(CLIChatTools.statusArguments(cdx) == ["login", "status"], "codex: status command")
        check(CLIChatTools.parseStatus(cdx, output: "Logged in using ChatGPT")?.isSignedIn == true, "codex: signed in")
        check(CLIChatTools.parseStatus(cdx, output: "Not logged in")?.isSignedIn == false, "codex: signed out")
        check(CLIChatTools.parseStatus(cdx, output: "boom") == nil, "codex: unknown")
        let cdxArgs = CLIChatTools.chatArguments(cdx, model: "default", systemPrompt: "s")
        check(cdxArgs == ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral", "--ignore-user-config", "--ignore-rules", "-"], "codex: read-only exec, nothing saved, no user hooks, prompt on stdin")
        let extPaths = CLIChatTools.extensionBinaryCandidates(cdx, home: "/Users/me", extensionFolders: ["openai.chatgpt-26.1002.5-darwin-arm64", "openai.chatgpt-26.1007.2-darwin-arm64", "ms-python.python-1"])
        check(extPaths.first == "/Users/me/.vscode/extensions/openai.chatgpt-26.1007.2-darwin-arm64/bin/macos-aarch64/codex" && extPaths.count == 4, "codex: newest VS Code extension binary first, other extensions ignored")
        check(CLIChatTools.extensionBinaryCandidates(claude, home: "/Users/me", extensionFolders: ["openai.chatgpt-1"]).isEmpty, "extension binaries are only searched for codex")
        let realCodexLines = [#"{"type":"thread.started","thread_id":"t"}"#, #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pong"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":5}}"#]
        check(realCodexLines.compactMap { CLIChatTools.parseLine(cdx, $0) } == [.finished("pong")], "codex: a real run yields one message")
        check(CLIChatTools.parseLine(cdx, #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"pong"}}"#) == .finished("pong"), "codex: agent message")
        check(CLIChatTools.parseLine(cdx, #"{"type":"item.completed","item":{"id":"item_1","type":"reasoning","text":"hm"}}"#) == nil, "codex: reasoning skipped")
        check(CLIChatTools.parseLine(cdx, #"{"type":"turn.failed","error":{"message":"nope"}}"#) == .failed("nope"), "codex: failed turn")
        check(!CLIChatTools.sendsPromptAsArgument(cdx) && CLIChatTools.environment(cdx).isEmpty, "codex: stdin, no extra environment")

        let oc = CLIChatTools.opencode
        check(CLIChatTools.statusArguments(oc) == ["auth", "list"], "opencode: status command")
        check(CLIChatTools.parseStatus(oc, output: "┌  Credentials ~/.local/share/opencode/auth.json\n●  GitHub Copilot oauth\n└  1 credentials\n")?.isSignedIn == true, "opencode: one credential")
        check(CLIChatTools.parseStatus(oc, output: "\u{1B}[90m└\u{1B}[0m  0 credentials")?.isSignedIn == false, "opencode: none, with colour codes")
        check(CLIChatTools.parseStatus(oc, output: "0 credentials\n2 environment variables")?.isSignedIn == true, "opencode: environment keys count")
        check(CLIChatTools.parseStatus(oc, output: "hello") == nil, "opencode: unknown")
        check(CLIChatTools.chatArguments(oc, model: "default", systemPrompt: "s", prompt: "hi there") == ["run", "--format", "json", "hi there"], "opencode: message is the last argument")
        check(CLIChatTools.sendsPromptAsArgument(oc), "opencode: prompt as argument")
        check(CLIChatTools.environment(oc)["OPENCODE_CONFIG_CONTENT"]?.contains(#""bash":"deny""#) == true, "opencode: every tool refused")
        check(CLIChatTools.parseLine(oc, #"{"type":"text","part":{"type":"text","text":"pong"}}"#) == .finished("pong"), "opencode: text part")
        check(CLIChatTools.parseLine(oc, #"{"type":"error","error":{"name":"E","data":{"message":"bad key"}}}"#) == .failed("bad key"), "opencode: error")
        check(CLIChatTools.parseLine(oc, #"{"type":"step_finish"}"#) == nil, "opencode: other events skipped")
        check(CLIChatTools.promptInput(oc, systemPrompt: "S", transcript: "T").hasPrefix("Instructions for this chat: S"), "instructions lead the prompt for tools without a system flag")
        check(CLIChatTools.tool(id: "copilot-cli") == copilot && CLIChatTools.tool(id: nil) == nil, "tool lookup")

        let cliProvider = CLIChatTools.provider(for: claude)
        let oldJSON = Data(#"[{"id":"groq","name":"Groq","baseURL":"https://api.groq.com/openai/v1","requiresKey":true,"model":"m","colorHex":"c"}]"#.utf8)
        check(CustomProviders.decodeProviders(oldJSON).first?.cliTool == nil, "old saved lists still decode")
        check(CustomProviders.decodeProviders(CustomProviders.encodeProviders([cliProvider, good])) == [cliProvider, good], "command-line provider survives storage")
        let rogue = CustomProvider(id: "x", name: "X", baseURL: "", requiresKey: false, model: "m", colorHex: "#fff", cliTool: "rm")
        check(CustomProviders.decodeProviders(CustomProviders.encodeProviders([rogue])).isEmpty, "unknown command-line tool is dropped")
        let withURL = CustomProvider(id: "y", name: "Y", baseURL: "https://a.b/v1", requiresKey: false, model: "m", colorHex: "#fff", cliTool: "claude-code")
        check(CustomProviders.decodeProviders(CustomProviders.encodeProviders([withURL])).isEmpty, "command-line provider with a URL is dropped")

        // Auto-connect: connect what is new, never what the user removed, unless they scan again.
        let vllm = CustomProvider(id: "vllm", name: "vLLM", baseURL: "http://127.0.0.1:8000/v1", requiresKey: false, model: "m", colorHex: "#fff")
        func plan(_ found: [CustomProvider], _ connected: [CustomProvider] = [], _ dismissed: Set<String> = [], force: Bool = false) -> [String] {
            CustomProviders.providersToConnect(found: found, connected: connected, dismissed: dismissed, force: force).map(\.id)
        }
        check(plan([cliProvider, vllm]) == ["claude-code", "vllm"], "connects what is new")
        check(plan([cliProvider, vllm], [cliProvider]) == ["vllm"], "skips a tool already connected")
        check(plan([vllm], [vllm]).isEmpty, "skips a server already connected")
        check(plan([cliProvider, vllm], [], ["cli:claude-code"]) == ["vllm"], "removed tool stays removed")
        check(plan([cliProvider, vllm], [], ["cli:claude-code", "url:http://127.0.0.1:8000/v1"]).isEmpty, "removed server stays removed")
        check(plan([cliProvider, vllm], [], ["cli:claude-code"], force: true) == ["claude-code", "vllm"], "Scan button brings it back")
        check(CustomProviders.autoConnectKey(for: cliProvider) == "cli:claude-code" && CustomProviders.autoConnectKey(for: vllm) == "url:http://127.0.0.1:8000/v1", "dismiss keys")
        check(CustomProviders.shouldConnectBuiltIn(id: "ollama", currentURL: "", dismissed: [], force: false), "fills an empty Ollama field")
        check(!CustomProviders.shouldConnectBuiltIn(id: "ollama", currentURL: "http://x", dismissed: [], force: true), "never overwrites a URL")
        check(!CustomProviders.shouldConnectBuiltIn(id: "ollama", currentURL: "", dismissed: ["ollama"], force: false), "disconnected Ollama stays disconnected")
        check(CustomProviders.shouldConnectBuiltIn(id: "ollama", currentURL: "", dismissed: ["ollama"], force: true), "Scan button reconnects Ollama")

        print("Custom providers: \(cases) cases passed")
    }
}
