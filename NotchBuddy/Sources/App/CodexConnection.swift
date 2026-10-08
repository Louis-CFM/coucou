#if !APPSTORE
import Foundation
import Darwin

enum CodexServiceError: LocalizedError {
    case unavailable, disconnected, timeout, invalidResponse, oversized, busy
    case message(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Install or update the Codex CLI, then try again.")
        case .disconnected: String(localized: "The Codex connection closed. Reconnect and try again.")
        case .timeout: String(localized: "Codex did not answer in time. Try again.")
        case .invalidResponse: String(localized: "Codex returned an unsupported response. Update the CLI.")
        case .oversized: String(localized: "The Codex response exceeded the safe size limit.")
        case .busy: String(localized: "A Codex turn is already running. Finish or cancel it first.")
        case .message(let message): message
        }
    }
}

// A queued write can outlive its request. Only this lock-protected flag crosses threads.
private final class CodexWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// A single owning stdio client: metadata and managed turns use this same connection.
@MainActor
final class CodexConnection {
    static let shared = CodexConnection()
    typealias Observer = (String, [String: Any], Any?) -> Void
    var onDisconnect: (() -> Void)?
    private(set) var cliVersion: String?
    private var observers: [UUID: Observer] = [:]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var diagnostics: FileHandle?
    private var buffer = Data()
    private var generation = UUID()
    private var sequence = 0
    private var ready = false
    private var starting: Task<Void, Error>?
    private var leases = Set<UUID>()
    private let writer = DispatchQueue(label: "fr.louisraille.NotchBuddy.codex.stdin", qos: .utility)
    private var queuedWrites: [UUID: (bytes: Int, requestId: Int?, cancellation: CodexWriteCancellation)] = [:]
    private var queuedBytes = 0
    private struct Pending {
        let continuation: CheckedContinuation<Data, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int: Pending] = [:]
    let executable: URL?
    let arguments: [String]
    let requestTimeout: TimeInterval
    var isConnected: Bool { ready && process?.isRunning == true }

    init(executable: URL? = nil, arguments: [String] = ["app-server", "--stdio"], requestTimeout: TimeInterval = 20) {
        self.executable = executable ?? Self.findExecutable()
        self.arguments = arguments
        self.requestTimeout = requestTimeout
    }

    static func findExecutable() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin",
                     "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/Library/pnpm"]
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            paths += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvm)/\($0)/bin" }
        }
        paths += (env["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult func observe(_ callback: @escaping Observer) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func retainConnection() -> UUID { let id = UUID(); leases.insert(id); return id }
    func releaseConnection(_ id: UUID) { leases.remove(id); closeWhenIdle() }
    func closeWhenIdle() { if leases.isEmpty && pending.isEmpty { stop() } }

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        try await connect()
        return try await sendRequest(method, params: params)
    }

    func respond(id: Any, result: [String: Any]) throws {
        guard id is String || id is NSNumber else { throw CodexServiceError.invalidResponse }
        try write(["id": id, "result": result])
    }

    func reject(id: Any, message: String) throws {
        try write(["id": id, "error": ["code": -32601, "message": message]])
    }

    private func connect() async throws {
        if isConnected { return }
        if let starting { return try await starting.value }
        let task = Task { @MainActor in
            do {
                try self.launch()
                let initialized = try await self.sendRequest("initialize", params: [
                    "clientInfo": ["name": "coucou", "title": "Coucou", "version": "1.0"],
                    "capabilities": ["experimentalApi": true]
                ])
                if let userAgent = initialized["userAgent"] as? String,
                   let range = userAgent.range(of: #"codex_cli_rs/[0-9]+(?:\.[0-9]+)+"#, options: .regularExpression) {
                    self.cliVersion = String(userAgent[range].split(separator: "/").last ?? "")
                }
                try self.write(["method": "initialized", "params": [:]])
                self.ready = true
            } catch { self.stop(); throw error }
        }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    private func launch() throws {
        guard let executable else { throw CodexServiceError.unavailable }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        let current = UUID(); generation = current
        child.executableURL = executable
        child.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                               "/usr/bin", "/bin", environment["PATH"] ?? ""].joined(separator: ":")
        child.environment = environment
        // Never use a shell or copy credentials. Codex manages its existing login.
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        // A closed child stdin must report EPIPE, never terminate Coucou with SIGPIPE.
        guard fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw CodexServiceError.disconnected
        }
        diagnostics = stderr.fileHandleForReading; process = child
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                if bytes.isEmpty { self.stop() } else { self.receive(bytes) }
            }
        }
        // Drain diagnostics without retaining potentially sensitive contents.
        stderr.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.stop()
            }
        }
        do { try child.run() } catch { stop(); throw CodexServiceError.unavailable }
    }

    private func sendRequest(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        let response: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(self?.requestTimeout ?? 20))
                    guard !Task.isCancelled else { return }
                    self?.finish(id: id, result: .failure(CodexServiceError.timeout))
                }
                pending[id] = Pending(continuation: continuation, timeout: timeout)
                do { try write(["id": id, "method": method, "params": params]) }
                catch { finish(id: id, result: .failure(error)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, result: .failure(CancellationError())) }
        }
        guard let result = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw CodexServiceError.invalidResponse }
        return result
    }

    private func write(_ json: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw CodexServiceError.disconnected }
        var bytes = try JSONSerialization.data(withJSONObject: json)
        guard bytes.count <= 1_048_576 else { throw CodexServiceError.oversized }
        bytes.append(10)
        guard queuedBytes + bytes.count <= 2_097_152 else { throw CodexServiceError.oversized }
        let id = UUID(), current = generation, payload = bytes
        let cancellation = CodexWriteCancellation()
        let requestId = json["method"] != nil ? (json["id"] as? NSNumber)?.intValue : nil
        queuedWrites[id] = (bytes.count, requestId, cancellation); queuedBytes += bytes.count
        // Pipe writes can block if Codex stops reading. Never block the MainActor.
        writer.async { [weak self] in
            var failed = false
            if !cancellation.isCancelled {
                do { try input.write(contentsOf: payload) } catch { failed = true }
            }
            let didFail = failed
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.queuedBytes -= self.queuedWrites.removeValue(forKey: id)?.bytes ?? 0
                if didFail { self.stop() }
            }
        }
    }

    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            guard line.count <= 2_097_152 else { stop(error: CodexServiceError.oversized); return }
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                stop(error: CodexServiceError.invalidResponse); return
            }
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                let callbacks = Array(observers.values)
                if callbacks.isEmpty, let id = message["id"] { try? reject(id: id, message: String(localized: "Coucou cannot handle this request.")) }
                for callback in callbacks { callback(method, params, message["id"]) }
            } else if let id = (message["id"] as? NSNumber)?.intValue {
                if let error = message["error"] as? [String: Any] {
                    finish(id: id, result: .failure(CodexServiceError.message(error["message"] as? String ?? String(localized: "Codex request failed."))))
                } else if let result = message["result"] as? [String: Any] {
                    finish(id: id, result: .success(result))
                } else { finish(id: id, result: .failure(CodexServiceError.invalidResponse)) }
            }
        }
        if buffer.count > 2_097_152 { stop(error: CodexServiceError.oversized) }
    }

    private func finish(id: Int, result: Result<[String: Any], Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel()
        if case .failure = result {
            for write in queuedWrites.values where write.requestId == id { write.cancellation.cancel() }
        }
        // Data is Sendable; untyped JSON never crosses a continuation/actor boundary.
        switch result {
        case .success(let value):
            do { item.continuation.resume(returning: try JSONSerialization.data(withJSONObject: value)) }
            catch { item.continuation.resume(throwing: error) }
        case .failure(let error): item.continuation.resume(throwing: error)
        }
    }

    func stop(error: Error = CodexServiceError.disconnected) {
        let wasActive = process != nil
        generation = UUID(); ready = false
        output?.readabilityHandler = nil; diagnostics?.readabilityHandler = nil
        process?.terminationHandler = nil
        let handles = [input, output, diagnostics].compactMap { $0 }
        let child = process
        input = nil; output = nil; diagnostics = nil; process = nil; buffer.removeAll(keepingCapacity: false)
        for write in queuedWrites.values { write.cancellation.cancel() }
        queuedWrites.removeAll(); queuedBytes = 0
        if child?.isRunning == true {
            child?.terminate()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if let child, child.isRunning { kill(child.processIdentifier, SIGKILL) }
            }
        }
        // Closing a handle can wait for an in-flight write; terminate first and close off-main.
        DispatchQueue.global(qos: .utility).async { for handle in handles { try? handle.close() } }
        for id in Array(pending.keys) { finish(id: id, result: .failure(error)) }
        if wasActive {
            for callback in Array(observers.values) { callback("$connection/disconnected", [:], nil) }
            onDisconnect?()
        }
    }
}
#endif
