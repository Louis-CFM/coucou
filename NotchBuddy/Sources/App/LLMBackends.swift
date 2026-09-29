import Foundation

// MARK: - Chat provider selection

enum ChatProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible
    case copilotCLI
    case hermes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic:        return "Anthropic (Claude)"
        case .openAICompatible: return "OpenAI-compatible endpoint"
        case .copilotCLI:       return "GitHub Copilot CLI"
        case .hermes:           return "Hermes (agent on your VPS)"
        }
    }

    var isConfigured: Bool {
        switch self {
        case .anthropic:
            return KeychainStore.shared.get("anthropic-api-key") != nil
        case .openAICompatible:
            return !(UserDefaults.standard.string(forKey: "openaiBaseURL") ?? "").isEmpty
                && !(UserDefaults.standard.string(forKey: "openaiModel") ?? "").isEmpty
        case .copilotCLI:
            #if APPSTORE
            return false
            #else
            return true
            #endif
        case .hermes:
            return !(UserDefaults.standard.string(forKey: "hermesURL") ?? "").isEmpty
        }
    }
}

// MARK: - Non-Anthropic backends

extension ClaudeService {

    /// Plain-text transcript turns for backends that take simple role/content messages.
    /// `state.chatHistory` already contains the message being sent.
    private func transcript(context: PromptContext?, state: AppState) -> [(role: String, content: String)] {
        var turns = state.chatHistory.map { (role: $0.role == .user ? "user" : "assistant", content: $0.content) }
        if state.chatHistory.count == 1, let context, let first = turns.first {
            var prefix = ""
            switch context {
            case .window(let app, let title, let url):
                prefix = "Context — App: \(app), Window: \(title)" + (url.map { ", URL: \($0)" } ?? "")
            case .file(let name, let fileURL):
                prefix = "File: \(name)"
                if let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 200_000,
                   let text = String(data: data, encoding: .utf8) {
                    prefix += "\nFile contents:\n\(text)"
                }
            }
            turns[0] = (first.role, prefix + "\n\n" + first.content)
        }
        return turns
    }

    private func finishChat(_ text: String, state: AppState) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError("No response text.", state: state)
            return
        }
        state.chatHistory.append(ChatMessage(role: .assistant, content: trimmed))
        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: OpenAI-compatible (OpenRouter, Azure AI Foundry, Ollama, LM Studio, …)

    func chatOpenAICompatible(context: PromptContext?, state: AppState) async {
        let ud = UserDefaults.standard
        let base = (ud.string(forKey: "openaiBaseURL") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        let model = ud.string(forKey: "openaiModel") ?? ""
        guard !base.isEmpty, !model.isEmpty, let url = URL(string: base + "/chat/completions") else {
            showError("Set the endpoint URL and model in Settings.", state: state)
            return
        }

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        messages += transcript(context: context, state: state).map { ["role": $0.role, "content": $0.content] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key = KeychainStore.shared.get("openai-api-key"), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 90
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "messages": messages])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "unknown error"
                showError("API error: \(String(msg.prefix(200)))", state: state)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                showError("Unexpected API response.", state: state)
                return
            }
            finishChat(text, state: state)
        } catch {
            showError("Network error: \(error.localizedDescription)", state: state)
        }
    }

    // MARK: GitHub Copilot CLI (`copilot -p`)

    func chatCopilotCLI(context: PromptContext?, state: AppState) async {
        #if APPSTORE
        showError("Copilot CLI is not available in the sandboxed build.", state: state)
        #else
        var prompt = systemPrompt + "\n\nConversation so far:\n"
        for turn in transcript(context: context, state: state) {
            prompt += "\n\(turn.role == "user" ? "User" : "Assistant"): \(turn.content)"
        }
        prompt += "\n\nReply to the last user message."

        let result = await Self.runCopilot(prompt: prompt)
        switch result {
        case .success(let text): finishChat(text, state: state)
        case .failure(let error): showError(error.localizedDescription, state: state)
        }
        #endif
    }

    // MARK: Hermes (agent running on your VPS)

    /// Chats with the Hermes bridge (`POST {text, session}` -> `{reply}`).
    /// The bridge runs a real agent session on the VPS, so it keeps its own thread:
    /// only the newest user turn is sent, and the reply is appended to the notch chat.
    func chatHermes(context: PromptContext?, state: AppState) async {
        let raw = (UserDefaults.standard.string(forKey: "hermesURL") ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !raw.isEmpty, let url = URL(string: raw) else {
            showError("Set the Hermes bridge URL in Settings.", state: state)
            return
        }
        let sessionRaw = UserDefaults.standard.string(forKey: "hermesSession") ?? ""
        let session = sessionRaw.isEmpty ? "coucou" : sessionRaw

        guard let query = state.chatHistory.last(where: { $0.role == .user })?.content,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("Nothing to send.", state: state)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let key = KeychainStore.shared.get("hermes-key"), !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "X-Hermes-Key")
        }
        request.timeoutInterval = 200
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": query, "session": session])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "unknown error"
                showError("Hermes bridge: \(String(msg.prefix(200)))", state: state)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = json["reply"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showError("Empty reply from the Hermes bridge.", state: state)
                return
            }
            finishChat(text, state: state)
        } catch {
            showError("Network error: \(error.localizedDescription)", state: state)
        }
    }

    #if !APPSTORE
    /// Runs the CLI through a login shell so PATH matches Terminal. The prompt travels in the
    /// environment to avoid shell quoting. NB_HOOK_DISABLE stops Coucou's own hooks from
    /// reporting this helper run as a session.
    nonisolated private static func runCopilot(prompt: String) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", #"copilot -p "$COUCOU_PROMPT" -s --no-ask-user --no-custom-instructions --available-tools web_search web_fetch"#]
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            var env = ProcessInfo.processInfo.environment
            env["COUCOU_PROMPT"] = prompt
            env["NB_HOOK_DISABLE"] = "1"
            process.environment = env
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice

            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)

            DispatchQueue.global().async {
                do { try process.run() } catch {
                    timeout.cancel()
                    continuation.resume(returning: .failure(error))
                    return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                let text = String(data: outData, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(text))
                } else {
                    let raw = String(data: errData, encoding: .utf8) ?? text
                    let first = raw.split(separator: "\n").first.map(String.init) ?? "copilot exited with \(process.terminationStatus)"
                    continuation.resume(returning: .failure(NSError(domain: "CopilotCLI", code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: String(first.prefix(200))])))
                }
            }
        }
    }
    #endif
}
