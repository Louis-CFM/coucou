import Foundation

enum AntigravityExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let override = environment["ANTIGRAVITY_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/agy" })
        }
        candidates.append(contentsOf: [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path,
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ])

        return candidates.lazy
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func version(at executableURL: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }
}

@MainActor
final class AntigravityAgentRuntimeAdapter: AgentRuntimeAdapter, AgentRuntimeEventIngress {
    let id: AgentRuntimeID = .antigravity
    let capabilities = AgentRuntimeCapabilities(
        observeSessions: true,
        startSession: false,
        resumeSession: false,
        interrupt: false,
        approvals: false,
        userInputRequests: false,
        toolEvents: true,
        fileChanges: false,
        commandEvents: false,
        subagents: true,
        runtimeModelSelection: false,
        runtimeReasoningSelection: false
    )
    let events: AsyncStream<AgentEvent>

    private let eventContinuation: AsyncStream<AgentEvent>.Continuation

    init() {
        let pair = AsyncStream<AgentEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    func detectAvailability() async -> RuntimeAvailability {
        guard let executable = AntigravityExecutableLocator.locate() else {
            return .unavailable(reason: "Antigravity CLI was not found")
        }
        let version = await Task.detached {
            AntigravityExecutableLocator.version(at: executable)
        }.value
        return .available(version: version)
    }

    func connect() async throws {}
    func disconnect() async {}
    func listModels() async throws -> [ModelDescriptor] { [] }
    func listSessions() async throws -> [AgentSession] { [] }

    func startSession(_ request: StartAgentSessionRequest) async throws -> AgentSession {
        throw AgentRuntimeError.unsupportedFeature("Starting Antigravity sessions")
    }

    func resumeSession(id: String) async throws -> AgentSession {
        throw AgentRuntimeError.unsupportedFeature("Resuming Antigravity sessions")
    }

    func interrupt(sessionID: String) async throws {
        throw AgentRuntimeError.unsupportedFeature("Interrupting Antigravity sessions")
    }

    func resolveApproval(
        sessionID: String,
        requestID: String,
        decision: ApprovalDecision
    ) async throws {
        throw AgentRuntimeError.unsupportedFeature("Antigravity approvals")
    }

    func respondToUserInput(
        sessionID: String,
        requestID: String,
        answers: [String: [String]]
    ) async throws {
        throw AgentRuntimeError.unsupportedFeature("Answering Antigravity questions in Coucou")
    }

    func ingest(_ event: AgentEvent) {
        guard event.runtime == id else { return }
        eventContinuation.yield(event)
    }
}
