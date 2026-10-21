import Foundation

public enum OrcaCommandError: Error, Equatable, Sendable {
    case executableNotFound
    case timeout
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case invalidOutput(String)

    /// Short, path-free description, safe to expose.
    public var summary: String {
        switch self {
        case .executableNotFound: "orca CLI not found"
        case .timeout: "orca timed out"
        case .launchFailed(let m): OrcaCommandError.redact("launch failed: \(m)")
        case .nonZeroExit(let code, let m): OrcaCommandError.redact(m.isEmpty ? "exit \(code)" : "exit \(code): \(m)")
        case .invalidOutput(let m): OrcaCommandError.redact("invalid output: \(m)")
        }
    }

    static func redact(_ text: String) -> String {
        let noPaths = text.replacingOccurrences(of: #"(/[^\s:'"]+)+"#, with: "<path>", options: .regularExpression)
        return OrcaFormatting.oneLine(noPaths, limit: 120) ?? ""
    }
}

/// Runs the orca CLI. Tests inject a fake; production uses `ProcessCommandRunner`.
public protocol OrcaCommandRunning: Sendable {
    /// Returns stdout. Throws `OrcaCommandError`.
    func run(arguments: [String], timeout: TimeInterval) async throws -> Data
}

/// Resolves the orca executable: `ORCA_CLI_COMMAND`, `/usr/local/bin/orca`, `/opt/homebrew/bin/orca`, then PATH
/// (plus the Orca.app bundle as a last resort). GUI apps have a minimal PATH, hence the fixed candidates.
public struct OrcaExecutableResolver: Sendable {
    public var environment: [String: String]
    public var isExecutable: @Sendable (String) -> Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.environment = environment
        self.isExecutable = isExecutable
    }

    public func candidates() -> [String] {
        var list: [String] = []
        if let custom = environment["ORCA_CLI_COMMAND"]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty {
            list.append((custom as NSString).expandingTildeInPath)
        }
        list += ["/usr/local/bin/orca", "/opt/homebrew/bin/orca"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            list.append("\(dir)/orca")
        }
        list.append("/Applications/Orca.app/Contents/Resources/bin/orca")
        return list
    }

    public func resolve() -> String? { candidates().first(where: isExecutable) }
}

public struct ProcessCommandRunner: OrcaCommandRunning {
    public var resolver: OrcaExecutableResolver

    public init(resolver: OrcaExecutableResolver = OrcaExecutableResolver()) { self.resolver = resolver }

    public func run(arguments: [String], timeout: TimeInterval) async throws -> Data {
        guard let path = resolver.resolve() else { throw OrcaCommandError.executableNotFound }
        var env = resolver.environment
        // The orca launcher is a shell script that may call node/open etc.
        let extra = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        env["PATH"] = [env["PATH"], extra].compactMap { $0 }.joined(separator: ":")
        let environment = env
        // Blocking work lives on a global queue: never on the main actor, no polling.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(with: Result { try Self.runBlocking(path: path, arguments: arguments, environment: environment, timeout: timeout) })
            }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    static func runBlocking(path: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw OrcaCommandError.launchFailed(error.localizedDescription) }

        let timedOut = Flag()
        let timer = DispatchWorkItem {
            timedOut.set()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Drain stderr concurrently so a full pipe can never block the child.
        let errBox = DataBox()
        let errThread = Thread { errBox.data = err.fileHandleForReading.readDataToEndOfFile() }
        errThread.start()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        while !errThread.isFinished { Thread.sleep(forTimeInterval: 0.001) }

        if timedOut.isSet { throw OrcaCommandError.timeout }
        guard process.terminationStatus == 0 else {
            // `orca --json` reports errors on stdout with a non-zero exit; keep it parseable.
            if !data.isEmpty, (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
            throw OrcaCommandError.nonZeroExit(process.terminationStatus, String(decoding: errBox.data.prefix(400), as: UTF8.self))
        }
        return data
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}
