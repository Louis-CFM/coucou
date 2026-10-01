import Foundation

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case notConnected
    case invalidMessage
    case requestTimedOut(method: String)
    case server(code: Int?, message: String)
    case terminated(status: Int32)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex CLI was not found"
        case .notConnected:
            "Codex app-server is not connected"
        case .invalidMessage:
            "Codex app-server returned an invalid message"
        case .requestTimedOut(let method):
            "Codex took too long to answer \(method). Try opening the chat again."
        case .server(_, let message):
            message
        case .terminated(let status):
            "Codex app-server exited with status \(status)"
        }
    }
}

enum CodexAppServerStatus: Sendable, Equatable {
    case terminated(status: Int32)
}

enum CodexExecutableLocator {
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let override = environment["CODEX_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
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

actor CodexAppServerTransport {
    nonisolated let messages: AsyncStream<JSONValue>
    nonisolated let statuses: AsyncStream<CodexAppServerStatus>

    private let executableURL: URL
    private let messageContinuation: AsyncStream<JSONValue>.Continuation
    private let statusContinuation: AsyncStream<CodexAppServerStatus>.Continuation
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var outputSearchOffset = 0
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var pendingTimeouts: [Int: Task<Void, Never>] = [:]

    init(executableURL: URL) {
        self.executableURL = executableURL
        let pair = AsyncStream<JSONValue>.makeStream()
        messages = pair.stream
        messageContinuation = pair.continuation
        let statusPair = AsyncStream<CodexAppServerStatus>.makeStream()
        statuses = statusPair.stream
        statusContinuation = statusPair.continuation
    }

    func connect() async throws {
        guard process == nil else { return }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        self.process = process
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = errors.fileHandleForReading
        let outputReader = output.fileHandleForReading
        outputTask = Task.detached { [weak self, outputReader] in
            while !Task.isCancelled {
                let data = outputReader.availableData
                guard !data.isEmpty else { return }
                await self?.receive(data)
            }
        }
        let errorReader = errors.fileHandleForReading
        errorTask = Task.detached { [errorReader] in
            while !Task.isCancelled {
                let data = errorReader.availableData
                guard !data.isEmpty else { return }
                // stderr is intentionally drained but not persisted: it can contain user data.
            }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { await self?.processTerminated(status: status) }
        }

        do {
            try process.run()
            _ = try await request(
                method: "initialize",
                params: .object([
                    "clientInfo": .object([
                        "name": .string("coucou"),
                        "title": .string("Coucou"),
                        "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"),
                    ]),
                ])
            )
            try sendNotification(method: "initialized", params: .object([:]))
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        let process = process
        self.process = nil
        inputHandle = nil
        outputTask?.cancel()
        errorTask?.cancel()
        try? outputHandle?.close()
        try? errorHandle?.close()
        outputHandle = nil
        errorHandle = nil
        outputTask = nil
        errorTask = nil
        outputBuffer.removeAll(keepingCapacity: false)
        outputSearchOffset = 0

        if process?.isRunning == true {
            process?.terminate()
        }
        failPending(with: CodexAppServerError.notConnected)
    }

    func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard process?.isRunning == true else {
            throw CodexAppServerError.notConnected
        }

        let id = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            pendingTimeouts[id] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.expireRequest(id: id, method: method)
            }
            do {
                try write(.object([
                    "id": .number(Double(id)),
                    "method": .string(method),
                    "params": params,
                ]))
            } catch {
                pendingTimeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    func respond(id: JSONValue, result: JSONValue) throws {
        try write(.object(["id": id, "result": result]))
    }

    private func sendNotification(method: String, params: JSONValue) throws {
        try write(.object(["method": .string(method), "params": params]))
    }

    private func write(_ message: JSONValue) throws {
        guard let inputHandle else { throw CodexAppServerError.notConnected }
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        outputBuffer.append(data)
        while outputSearchOffset < outputBuffer.count,
              let newline = outputBuffer[outputSearchOffset...].firstIndex(of: 0x0A) {
            var line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            outputSearchOffset = 0
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            guard let message = Self.decodeMessage(line) else {
                failMalformedResponseIfNeeded(line)
                continue
            }
            receive(message)
        }
        // A newline is one byte, so previously scanned bytes never need to be
        // visited again when the next pipe chunk arrives. This matters for
        // multi-megabyte thread/read responses.
        outputSearchOffset = outputBuffer.count
    }

    nonisolated static func decodeMessage(_ data: Data) -> JSONValue? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return jsonValue(from: object)
    }

    nonisolated private static func jsonValue(from value: Any) -> JSONValue? {
        switch value {
        case let value as String:
            .string(value)
        case let value as NSNumber:
            CFGetTypeID(value) == CFBooleanGetTypeID()
                ? .bool(value.boolValue)
                : .number(value.doubleValue)
        case let value as [String: Any]:
            .object(value.compactMapValues(jsonValue(from:)))
        case let value as [Any]:
            .array(value.compactMap(jsonValue(from:)))
        case is NSNull:
            .null
        default:
            nil
        }
    }

    private func failMalformedResponseIfNeeded(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["method"] == nil,
              let id = (object["id"] as? NSNumber)?.intValue,
              let continuation = pending.removeValue(forKey: id) else { return }
        pendingTimeouts.removeValue(forKey: id)?.cancel()
        continuation.resume(throwing: CodexAppServerError.invalidMessage)
    }

    private func receive(_ message: JSONValue) {
        guard let object = message.objectValue else { return }
        if let id = object["id"]?.numberValue.map(Int.init),
           object["method"] == nil,
           let continuation = pending.removeValue(forKey: id) {
            pendingTimeouts.removeValue(forKey: id)?.cancel()
            if let result = object["result"] {
                continuation.resume(returning: result)
            } else {
                let error = object["error"]?.objectValue
                let code = error?["code"]?.numberValue.map(Int.init)
                let text = error?["message"]?.stringValue ?? "Unknown Codex app-server error"
                continuation.resume(throwing: CodexAppServerError.server(code: code, message: text))
            }
            return
        }

        messageContinuation.yield(message)
    }

    private func processTerminated(status: Int32) {
        guard process != nil else { return }
        process = nil
        inputHandle = nil
        failPending(with: CodexAppServerError.terminated(status: status))
        statusContinuation.yield(.terminated(status: status))
    }

    private func failPending(with error: any Error) {
        for timeout in pendingTimeouts.values { timeout.cancel() }
        pendingTimeouts.removeAll()
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func expireRequest(id: Int, method: String) {
        pendingTimeouts.removeValue(forKey: id)
        pending.removeValue(forKey: id)?.resume(
            throwing: CodexAppServerError.requestTimedOut(method: method)
        )
    }
}
