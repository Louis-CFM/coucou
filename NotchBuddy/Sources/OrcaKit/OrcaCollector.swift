import Foundation

/// Reads the four read-only sources, keeping the last good value of each. All commands are read-only:
/// `worktree ps`, `account list`, `orchestration worker-list`, `status`.
public actor OrcaCollector {
    public static let minInterval: TimeInterval = 5
    public static let defaultInterval: TimeInterval = 15
    public static let commandTimeout: TimeInterval = 10
    static let maxWorkerPages = 50

    private let runner: any OrcaCommandRunning
    private let timeout: TimeInterval
    private var raw = OrcaRawState()
    private var health: [OrcaSource: OrcaSourceHealth] = Dictionary(
        uniqueKeysWithValues: OrcaSource.allCases.map { ($0, OrcaSourceHealth(ok: false)) })
    private var lastCompleteAt: Int?
    public private(set) var pollInterval: TimeInterval

    public init(runner: any OrcaCommandRunning, pollInterval: TimeInterval = OrcaCollector.defaultInterval,
                commandTimeout: TimeInterval = OrcaCollector.commandTimeout) {
        self.runner = runner
        self.timeout = commandTimeout
        self.pollInterval = max(pollInterval, Self.minInterval)
    }

    public func setPollInterval(_ interval: TimeInterval) { pollInterval = max(interval, Self.minInterval) }

    /// One collection cycle: all sources concurrently, then the derived snapshot.
    public func collect(includeRemote: Bool = true, now: Date = Date(), calendar: Calendar = .current) async -> OrcaSnapshot {
        async let ps = attempt { try await self.fetchWorktrees() }
        async let acc = attempt { try await self.fetchRateLimits() }
        async let wk = attempt { try await self.fetchWorkers() }
        async let st = attempt { try await self.fetchStatus() }
        let results = await (ps, acc, wk, st)
        let at = Int(now.timeIntervalSince1970)

        func record<T>(_ source: OrcaSource, _ result: Result<T, OrcaCommandError>, _ apply: (T) -> Void) {
            switch result {
            case .success(let value): apply(value); health[source] = OrcaSourceHealth(ok: true, lastSuccessAt: at)
            case .failure(let e):
                health[source] = OrcaSourceHealth(ok: false, lastSuccessAt: health[source]?.lastSuccessAt, error: e.summary)
            }
        }
        record(.worktrees, results.0) { raw.worktrees = $0 }
        record(.accounts, results.1) { raw.rateLimits = $0 }
        record(.workers, results.2) { raw.workers = $0 }
        record(.status, results.3) { raw.status = $0 }
        if health.values.allSatisfy(\.ok) { lastCompleteAt = at }
        return snapshot(includeRemote: includeRemote, now: now, calendar: calendar)
    }

    /// Re-derives from the last good data without touching the CLI.
    public func snapshot(includeRemote: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> OrcaSnapshot {
        OrcaDerivation.derive(raw: raw, sources: health, lastCompleteCycleAt: lastCompleteAt, pollInterval: pollInterval,
                              includeRemote: includeRemote, now: now, calendar: calendar)
    }

    // MARK: - Sources

    private func attempt<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, OrcaCommandError> {
        do { return .success(try await body()) }
        catch let e as OrcaCommandError { return .failure(e) }
        catch { return .failure(.launchFailed(error.localizedDescription)) }
    }

    private func decode<R: Decodable>(_ type: R.Type, _ args: [String]) async throws -> R {
        let data = try await runner.run(arguments: args, timeout: timeout)
        let envelope: OrcaEnvelope<R>
        do { envelope = try JSONDecoder().decode(OrcaEnvelope<R>.self, from: data) }
        catch { throw OrcaCommandError.invalidOutput("not JSON") }
        guard envelope.ok == true, let result = envelope.result else {
            throw OrcaCommandError.invalidOutput(envelope.error?.message ?? envelope.error?.code ?? "ok=false")
        }
        return result
    }

    private func fetchWorktrees() async throws -> [RawWorktree] {
        try await decode(RawWorktreesResult.self, ["worktree", "ps", "--json"]).worktrees ?? []
    }

    private func fetchRateLimits() async throws -> [String: RawRateLimit] {
        try await decode(RawAccountsResult.self, ["account", "list", "--json"]).rateLimits ?? [:]
    }

    private func fetchStatus() async throws -> RawStatusResult.Runtime {
        guard let runtime = try await decode(RawStatusResult.self, ["status", "--json"]).runtime else {
            throw OrcaCommandError.invalidOutput("no runtime")
        }
        return runtime
    }

    /// All pages (`--cursor`); a failing page fails the source so a partial list never replaces the last good one.
    private func fetchWorkers() async throws -> [RawWorker] {
        var all: [RawWorker] = []
        var cursor: String?
        for _ in 0..<Self.maxWorkerPages {
            var args = ["orchestration", "worker-list", "--json"]
            if let cursor { args += ["--cursor", cursor] }
            let page = try await decode(RawWorkersResult.self, args)
            all += page.workers ?? []
            guard page.page?.hasMore == true, let next = page.page?.nextCursor, next != cursor else { return all }
            cursor = next
        }
        return all
    }
}
