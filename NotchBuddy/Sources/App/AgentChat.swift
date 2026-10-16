import Foundation

/// Branche le lanceur d'agent sur le chat de l'île, sans toucher à ses vues :
/// `/agent <demande>` lance `claude -p` en lecture seule, `/stop` l'annule,
/// `/projet` liste les projets (ceux ouverts dans VS Code d'abord) et `/projet <n° ou nom>` en choisit un.
/// Le projet choisi est gardé dans la clé `agentProjectPath`.
@MainActor
enum AgentChat {
    static let command = "/agent "
    static let stopCommand = "/stop"
    static let projectCommand = "/projet"
    private static let projectKey = "agentProjectPath"
    private static let githubRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/GitHub")
    private static let launcher = AgentLauncher()

    static func handles(_ query: String) -> Bool {
        query.hasPrefix(command) || query == stopCommand
            || query == projectCommand || query.hasPrefix(projectCommand + " ")
    }

    /// Dossiers ouverts dans VS Code (le premier est la fenêtre active), puis les autres projets de ~/Documents/GitHub.
    static func availableProjects() -> [URL] {
        var result: [URL] = []
        func add(_ url: URL) {
            let u = url.standardizedFileURL
            if !result.contains(u) { result.append(u) }
        }
        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
        if let data = try? Data(contentsOf: storage),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let windows = json["windowsState"] as? [String: Any] {
            var entries: [[String: Any]] = []
            if let last = windows["lastActiveWindow"] as? [String: Any] { entries.append(last) }
            entries += (windows["openedWindows"] as? [[String: Any]]) ?? []
            for entry in entries {
                if let folder = entry["folder"] as? String, let url = URL(string: folder), url.isFileURL {
                    add(url)
                }
            }
        }
        let others = (try? FileManager.default.contentsOfDirectory(
            at: githubRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        for url in others.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               !url.lastPathComponent.hasSuffix(".glb") {
                add(url)
            }
        }
        return result
    }

    static var projectURL: URL {
        if let path = UserDefaults.standard.string(forKey: projectKey), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return githubRoot
    }

    static func handle(_ query: String, state: AppState) async {
        if query == stopCommand {
            launcher.cancel()
            return
        }
        if query == projectCommand || query.hasPrefix(projectCommand + " ") {
            chooseProject(String(query.dropFirst(projectCommand.count)).trimmingCharacters(in: .whitespaces), state: state)
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

    private static func chooseProject(_ argument: String, state: AppState) {
        let projects = availableProjects()
        if argument.isEmpty {
            let lines = projects.prefix(30).enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }
            reply("Projet actuel : \(projectURL.lastPathComponent)\n" + lines.joined(separator: "\n")
                  + "\nChoisis avec /projet <n° ou nom>.", state: state)
            return
        }
        let match: URL?
        if let index = Int(argument), projects.indices.contains(index - 1) {
            match = projects[index - 1]
        } else {
            let wanted = argument.lowercased()
            match = projects.first { $0.lastPathComponent.lowercased() == wanted }
                ?? projects.first { $0.lastPathComponent.lowercased().contains(wanted) }
        }
        guard let chosen = match else {
            reply("Projet introuvable : \(argument). Tape /projet pour la liste.", state: state)
            return
        }
        UserDefaults.standard.set(chosen.path, forKey: projectKey)
        reply("Projet choisi : \(chosen.lastPathComponent)", state: state)
    }

    private static func reply(_ text: String, state: AppState) {
        state.chatHistory.append(ChatMessage(role: .assistant, content: text))
        state.stateOverride = nil
        state.view = .prompt
    }
}
