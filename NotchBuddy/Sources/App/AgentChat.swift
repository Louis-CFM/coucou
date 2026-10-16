import Foundation

/// Branche le lanceur d'agent sur le chat de l'île, sans toucher à ses vues :
/// `/agent <demande>` lance `claude -p` en lecture seule, `/stop` l'annule.
/// Le dossier du projet vient de la clé `agentProjectPath` (le sélecteur arrive à l'étape suivante).
@MainActor
enum AgentChat {
    static let command = "/agent "
    static let stopCommand = "/stop"
    private static let launcher = AgentLauncher()

    static func handles(_ query: String) -> Bool {
        query.hasPrefix(command) || query == stopCommand
    }

    static var projectURL: URL {
        if let path = UserDefaults.standard.string(forKey: "agentProjectPath"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/GitHub")
    }

    static func handle(_ query: String, state: AppState) async {
        if query == stopCommand {
            launcher.cancel()
            return
        }
        let prompt = String(query.dropFirst(command.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            reply("Usage : /agent <demande>. Dossier : \(projectURL.path)", state: state)
            return
        }
        state.stateOverride = .thinking
        do {
            let answer = try await launcher.run(prompt: prompt, in: projectURL)
            reply(answer.isEmpty ? "(réponse vide)" : answer, state: state)
        } catch AgentLauncher.LaunchError.cancelled {
            reply("Agent annulé.", state: state)
        } catch {
            reply(error.localizedDescription, state: state)
        }
    }

    private static func reply(_ text: String, state: AppState) {
        state.chatHistory.append(ChatMessage(role: .assistant, content: text))
        state.stateOverride = nil
        state.view = .prompt
    }
}
