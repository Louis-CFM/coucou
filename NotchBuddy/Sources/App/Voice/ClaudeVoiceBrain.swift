#if !APPSTORE
import Foundation

// MARK: - ClaudeVoiceBrain
//
// "OK Coucou, …" handled by Claude (the user's Anthropic key, Settings → Voice), not by
// the phrase parser or the on-device model: Claude understands any wording, keeps the
// thread of the conversation and calls Coucou's tools to act.
//
// Tools: pills, music, service_info (Stripe, GitHub, agents…), open_app, prepare_email
// (the island's mail card opens filled in, the user clicks Send) and Anthropic's
// web_search. The conversation lives in memory only and is forgotten with the rest of
// the voice context (90 s after the last turn). Nothing is sent, approved or deleted
// without a click: the tools can't.
@MainActor
final class ClaudeVoiceBrain {
    static let shared = ClaudeVoiceBrain()

    struct Reply {
        let text: String      // spoken and shown
        let acted: Bool       // a tool changed something (pills, music, mail…)
        let failed: Bool      // nothing usable came back
    }

    /// Claude is Coucou's brain whenever an Anthropic key is saved (Settings → Chat).
    static var isActive: Bool {
        !(ClaudeService.shared.apiKey ?? "").isEmpty
    }

    private var messages: [[String: Any]] = []
    /// One turn at a time: a second "OK Coucou" during the wait must not interleave.
    private var busy = false

    func reset() { messages = [] }

    // MARK: Turn

    func respond(to transcript: String) async -> Reply? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false; repairHistory() }
        messages.append(["role": "user", "content": transcript])
        trimHistory()
        var acted = false
        var spoken = ""

        // Claude may call several tools in a row (look up, then act): at most 5 rounds.
        for _ in 0..<5 {
            guard let turn = await ClaudeService.shared.voiceTurn(system: Self.systemPrompt(),
                                                                   messages: messages,
                                                                   tools: Self.tools) else {
                // Leave the history coherent: drop the question that got no answer.
                if let last = messages.last, last["role"] as? String == "user",
                   last["content"] is String { messages.removeLast() }
                // Something already happened (a pill, the music, the mail card): the
                // parser must not do it again. Say it's done.
                return acted ? Reply(text: "", acted: true, failed: false) : nil
            }
            messages.append(["role": "assistant", "content": turn.content])
            if let text = claudeResponseText(fromContent: turn.content) { spoken = text }

            let uses = turn.content.filter { $0["type"] as? String == "tool_use" }
            if turn.stopReason == "pause_turn" { continue }          // long web search: go on
            guard turn.stopReason == "tool_use", !uses.isEmpty else { break }

            var results: [[String: Any]] = []
            for use in uses {
                let id = use["id"] as? String ?? ""
                let name = use["name"] as? String ?? ""
                let input = use["input"] as? [String: Any] ?? [:]
                let (result, didAct) = await run(tool: name, input: input)
                if didAct { acted = true }
                results.append(["type": "tool_result", "tool_use_id": id, "content": result])
            }
            messages.append(["role": "user", "content": results])
            spoken = ""
        }

        let text = VoiceQuery.spokenText(spoken)
        return Reply(text: text, acted: acted, failed: text.isEmpty && !acted)
    }

    /// The API refuses a history whose last assistant turn calls a tool with no result
    /// after it (cut by max_tokens, a failure, or a pause on the last round): drop it.
    private func repairHistory() {
        guard let last = messages.last, last["role"] as? String == "assistant",
              let content = last["content"] as? [[String: Any]] else { return }
        let calls = content.contains {
            let t = $0["type"] as? String
            return t == "tool_use" || t == "server_tool_use"
        }
        let answered = content.contains { $0["type"] as? String == "web_search_tool_result" }
        if calls && !answered || content.contains(where: { $0["type"] as? String == "tool_use" }) {
            messages.removeLast()
        }
    }

    /// Keeps the last exchanges, never cutting between a tool call and its result.
    private func trimHistory() {
        guard messages.count > 24 else { return }
        var cut = messages.count - 24
        // Start on a plain user message (a string), not on tool results.
        while cut < messages.count,
              !(messages[cut]["role"] as? String == "user" && messages[cut]["content"] is String) {
            cut += 1
        }
        messages.removeFirst(min(cut, messages.count - 1))
    }

    // MARK: Prompt

    private static func systemPrompt() -> String {
        let fr = VoiceSettings.language == "fr"
        let today = Date().formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()
            .locale(Locale(identifier: fr ? "fr_FR" : "en_US")))
        let state = AppState.shared
        let active = ([state.mainPillId] + Array(state.activeIntegrations))
            .compactMap { PillCatalog.definition(for: $0)?.name }
        let available = PillCatalog.available.map(\.name).joined(separator: ", ")
        let language = fr ? "French" : "English"
        return """
        You are Coucou, a voice assistant living in the notch of the user's Mac, a bit like Jarvis: \
        quick, warm, a little playful. It is \(today).
        Everything you write is read aloud: answer in \(language) (the user may speak French or English), \
        in one or two short sentences, no markdown, no lists, no emojis, no links.
        Act with the tools instead of describing: pills, music, service_info for the user's own data \
        (Stripe sales, GitHub, Vercel, Resend, n8n, Notion, Cal.com, agent sessions like Claude Code, \
        plan usage, music), open_app, prepare_email, and web_search for anything current \
        (weather, news, scores, prices, facts you are not sure of). Never invent the user's data.
        Email: gather the recipient, the subject and what to say (write the text yourself from what \
        the user wants to say, in the language they used), asking for what is missing one short \
        question at a time, then call prepare_email. The email is never sent by you: the user checks \
        the card and clicks Send. If they want an attachment and haven't named the file, set \
        wants_attachment and tell them to drop the file on the notch.
        When you need an answer from the user, end with one short question. Otherwise never end \
        with a question.
        Pills in the notch (at most 4 besides the main one). Active: \(active.joined(separator: ", ")). \
        Available: \(available).
        """
    }

    // MARK: Tools

    private static let tools: [[String: Any]] = [
        [
            "name": "pills",
            "description": "Add, remove, set as main or list the pills shown in the notch. At most 4 pills besides the main one: remove one first if needed.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["add", "remove", "set_main", "list"]],
                    "names": ["type": "array", "items": ["type": "string"],
                              "description": "Pill names as listed (e.g. Stripe, GitHub, Cursor). Empty for list."],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "music",
            "description": "Control Apple Music or Spotify: play, pause, next, previous, volume, play a song/artist search or a playlist.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["play", "pause", "next", "previous", "volume_up",
                                                          "volume_down", "set_volume", "play_search", "play_playlist"]],
                    "query": ["type": "string", "description": "Song, artist or playlist name for play_search / play_playlist."],
                    "volume": ["type": "integer", "description": "0-100 for set_volume."],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "service_info",
            "description": "Read the user's real data that Coucou already has: Stripe sales and balance, GitHub stars/PRs/CI, Vercel deployments, Resend emails, n8n runs, Notion pages, Cal.com bookings, agent sessions (Claude Code, Codex…), Claude or Codex plan usage, music now playing, active pills.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "topic": ["type": "string", "enum": VoiceTopic.allCases.map(\.rawValue)
                        .filter { !$0.hasPrefix("weather") }],   // weather: web_search
                ],
                "required": ["topic"],
            ],
        ],
        [
            "name": "open_app",
            "description": "Open an app on the Mac by name (Figma, Safari, VS Code, Notion…).",
            "input_schema": [
                "type": "object",
                "properties": ["name": ["type": "string"]],
                "required": ["name"],
            ],
        ],
        [
            "name": "prepare_email",
            "description": "Open the email card in the notch, filled in, for the user to check and send with a click (it is never sent automatically). The recipient is a contact name or an email address.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "recipient": ["type": "string"],
                    "subject": ["type": "string"],
                    "body": ["type": "string", "description": "The full email text, written for the user."],
                    "attachment_file": ["type": "string", "description": "File name to attach if the user named one (searched in Downloads, Desktop, Documents, Pictures)."],
                    "wants_attachment": ["type": "boolean", "description": "True if the user wants to attach a file without naming it: they drop it on the notch."],
                ],
                "required": ["recipient", "subject", "body"],
            ],
        ],
        webSearchTool,
    ]

    private static var webSearchTool: [String: Any] {
        var location: [String: Any] = ["type": "approximate", "timezone": TimeZone.current.identifier]
        if let country = Locale.current.region?.identifier, country.count == 2 { location["country"] = country }
        return ["type": "web_search_20250305", "name": "web_search", "max_uses": 3, "user_location": location]
    }

    // MARK: Running a tool

    /// Returns the text sent back to Claude, and whether something changed.
    private func run(tool: String, input: [String: Any]) async -> (String, Bool) {
        let runner = VoiceActionRunner.shared
        let pills = PillCatalog.available
        runner.commandLocale = VoiceSettings.answerLocale
        func perform(_ intent: VoiceIntent) async -> VoiceActionResult {
            let r = await runner.run(intent, availablePills: pills)
            // The runner may ask its own follow-up (4-pill limit…): Claude asks instead.
            runner.pendingQuestion = nil
            return r
        }

        switch tool {
        case "pills":
            let action = input["action"] as? String ?? ""
            let names = input["names"] as? [String] ?? []
            if action == "list" {
                return (await LiveVoiceInfo.shared.answer(.pills, locale: VoiceSettings.answerLocale), false)
            }
            var lines: [String] = []
            var acted = false
            for name in names {
                guard let id = EntityResolver.resolve(name, from: pills) else {
                    lines.append("\(name): unknown pill"); continue
                }
                let intent: VoiceIntent
                switch action {
                case "add":      intent = .pillAdd(id: id)
                case "remove":   intent = .pillRemove(id: id)
                case "set_main": intent = .pillSetMain(id: id)
                default:         lines.append("unknown action \(action)"); continue
                }
                let r = await perform(intent)
                if case .question = r.outcome {
                    lines.append("\(name): the notch is full (4 pills). Ask which pill to remove, then remove it and add \(name).")
                } else {
                    if r.outcome == .success { acted = true }
                    lines.append("\(name): \(r.message)")
                }
            }
            return (lines.isEmpty ? "nothing done" : lines.joined(separator: "\n"), acted)

        case "music":
            let action = input["action"] as? String ?? ""
            let query = (input["query"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let intent: VoiceIntent?
            switch action {
            case "play":          intent = .musicPlay(target: nil)
            case "pause":         intent = .musicPause
            case "next":          intent = .musicNext
            case "previous":      intent = .musicPrevious
            case "volume_up":     intent = .musicVolumeUp
            case "volume_down":   intent = .musicVolumeDown
            case "set_volume":    intent = .musicSetVolume(max(0, min(100, input["volume"] as? Int ?? 50)))
            case "play_search":   intent = query.isEmpty ? nil : .musicPlaySearch(name: query)
            case "play_playlist": intent = query.isEmpty ? nil : .musicPlayPlaylist(name: query)
            default:              intent = nil
            }
            guard let intent else { return ("missing query or unknown action", false) }
            let r = await perform(intent)
            return (r.message, r.outcome == .success)

        case "service_info":
            guard let topic = VoiceTopic(rawValue: input["topic"] as? String ?? "") else {
                return ("unknown topic", false)
            }
            let text = await LiveVoiceInfo.shared.answer(topic, locale: VoiceSettings.answerLocale)
            return (text.isEmpty ? "no data" : text, false)

        case "open_app":
            let name = input["name"] as? String ?? ""
            let r = LiveVoiceInfo.shared.openApp(name, locale: VoiceSettings.answerLocale)
            return (r.message, r.outcome == .success)

        case "prepare_email":
            return await prepareEmail(input)

        default:
            return ("unknown tool \(tool)", false)
        }
    }

    private func prepareEmail(_ input: [String: Any]) async -> (String, Bool) {
        let info = LiveVoiceInfo.shared
        let recipient = (input["recipient"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = input["subject"] as? String ?? ""
        let body = input["body"] as? String ?? ""
        guard !recipient.isEmpty else { return ("no recipient: ask who it is for", false) }
        guard let address = await info.resolveEmail(recipient) else {
            return ("No email address found for \(recipient) in the contacts. Ask the user to spell the address.", false)
        }
        var file: URL? = nil
        var note = ""
        if let name = input["attachment_file"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            file = info.findFile(name, folder: nil)
            if file == nil { note = " The file \(name) was not found: the user can drop it on the notch." }
        }
        // A file already dropped on the open card stays attached when Claude revises the mail.
        if file == nil, AppState.shared.voiceMailDraft != nil { file = AppState.shared.droppedFile?.url }
        info.showMailCard(to: address, subject: subject, body: body, file: file)
        let attach = (input["wants_attachment"] as? Bool ?? false) && file == nil
            ? " The user wants an attachment: tell them to drop the file on the notch." : ""
        let with = file.map { " with \($0.lastPathComponent) attached" } ?? ""
        return ("Email card shown to \(address)\(with). Nothing is sent until the user clicks Send.\(note)\(attach)", true)
    }
}
#endif
