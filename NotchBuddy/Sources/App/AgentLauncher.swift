import Foundation

/// Lance `claude -p` dans un dossier de projet, en lecture seule (mode plan),
/// et renvoie sa réponse. Aucune interface : utilisé par le chat de l'île.
final class AgentLauncher: @unchecked Sendable {
    enum LaunchError: Error, LocalizedError {
        case claudeNotFound
        case failed(code: Int32, output: String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "Commande `claude` introuvable."
            case .failed(let code, let output): return "claude a échoué (code \(code)) : \(output)"
            case .cancelled: return "Annulé."
            }
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var wasCancelled = false

    /// Une app lancée depuis le Finder n'a pas le PATH du terminal : on cherche aux emplacements usuels.
    static func claudeURL() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.npm-global/bin/claude"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Exécute la demande dans `directory`. Lecture seule : `--permission-mode plan`.
    func run(prompt: String, in directory: URL) async throws -> String {
        guard let claude = Self.claudeURL() else { throw LaunchError.claudeNotFound }

        let task = Process()
        task.executableURL = claude
        task.arguments = ["-p", prompt, "--permission-mode", "plan"]
        task.currentDirectoryURL = directory
        let out = Pipe()
        task.standardOutput = out
        task.standardError = out

        lock.withLock {
            process = task
            wasCancelled = false
        }

        return try await withCheckedThrowingContinuation { continuation in
            // Lecture en continu pour ne pas bloquer le processus si la sortie est longue.
            let reader = Task.detached { () -> Data in
                (try? out.fileHandleForReading.readToEnd()) ?? Data()
            }
            task.terminationHandler = { [weak self] finished in
                Task {
                    let data = await reader.value
                    let text = String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let cancelled = self?.consumeCancelled() ?? false
                    if cancelled {
                        continuation.resume(throwing: LaunchError.cancelled)
                    } else if finished.terminationStatus == 0 {
                        continuation.resume(returning: text)
                    } else {
                        continuation.resume(throwing: LaunchError.failed(code: finished.terminationStatus, output: text))
                    }
                }
            }
            do {
                try task.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        let task = lock.withLock { () -> Process? in
            wasCancelled = true
            return process
        }
        task?.terminate()
    }

    private func consumeCancelled() -> Bool {
        lock.withLock { wasCancelled }
    }
}
