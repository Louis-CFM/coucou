import Foundation

/// Runs the provider's own CLI with its existing account login. Credentials stay
/// in the CLI's store; Coucou only sends the prompt and reads the final answer.
enum CLIChatService {
    static func executable(for provider: ChatProvider) -> URL? {
        let name = provider == .anthropic ? "claude" : "codex"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin"]
        return paths.lazy.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func reply(provider: ChatProvider, model: String, prompt: String) async throws -> String {
        guard let executable = executable(for: provider) else {
            throw error("Install \(provider == .anthropic ? "Claude Code" : "Codex CLI") and sign in first.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-chat-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            let process = Process()
            process.executableURL = executable
            process.currentDirectoryURL = work
            if provider == .anthropic {
                process.arguments = ["-p", "--output-format", "json", "--tools", "",
                                     "--strict-mcp-config", "--no-session-persistence",
                                     "--model", model]
            } else {
                process.arguments = ["exec", "--json", "--ephemeral", "--ignore-user-config",
                                     "--skip-git-repo-check", "--sandbox", "read-only",
                                     "--cd", work.path, "-"]
            }
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            input.fileHandleForWriting.write(Data(prompt.utf8))
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let raw = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw error(String(raw.suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if provider == .anthropic {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = object["result"] as? String, !result.isEmpty else {
                    throw error("Claude Code returned no answer. Check its login with `claude auth status`.")
                }
                return result
            }
            let answer = raw.split(separator: "\n").compactMap { line -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      object["type"] as? String == "item.completed",
                      let item = object["item"] as? [String: Any],
                      item["type"] as? String == "agent_message" else { return nil }
                return item["text"] as? String
            }.last
            guard let answer, !answer.isEmpty else { throw error("Codex returned no answer. Check its login with `codex login status`.") }
            return answer
        }.value
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "CLIChat", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
