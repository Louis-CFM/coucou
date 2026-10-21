import XCTest
@testable import OrcaKit

final class OrcaCollectorTests: XCTestCase {
    func testEveryCommandIsReadOnlyAndAllPagesAreRequested() async {
        let runner = FakeRunner.standard()
        _ = await OrcaCollector(runner: runner).collect(now: TestClock.now, calendar: TestClock.utc)
        let verbs = Set(runner.calls.map { $0.prefix(2).joined(separator: " ") })
        XCTAssertEqual(verbs, ["worktree ps", "account list", "orchestration worker-list", "status --json"])
        XCTAssertTrue(runner.calls.contains(["orchestration", "worker-list", "--json", "--cursor", "CURSOR-PAGE-2"]))
        XCTAssertTrue(runner.calls.allSatisfy { $0.contains("--json") })
    }

    func testFailedSourceKeepsLastGoodValueAndFlagsError() async {
        let runner = FakeRunner.standard()
        let collector = OrcaCollector(runner: runner)
        let good = await collector.collect(now: TestClock.now, calendar: TestClock.utc)

        runner.fail("worktree ps --json", .timeout)
        runner.fail("account list --json", .nonZeroExit(1, "boom at /Users/someone/secret/path"))
        let later = TestClock.now.addingTimeInterval(15)
        let bad = await collector.collect(now: later, calendar: TestClock.utc)

        XCTAssertEqual(bad.workspaces.count, good.workspaces.count)         // last good retained
        XCTAssertEqual(bad.usage, good.usage)
        XCTAssertFalse(bad.sources[.worktrees]!.ok)
        XCTAssertEqual(bad.sources[.worktrees]!.error, "orca timed out")
        XCTAssertEqual(bad.sources[.worktrees]!.lastSuccessAt, 1_792_610_700)
        XCTAssertFalse(bad.sources[.accounts]!.ok)
        XCTAssertFalse(bad.sources[.accounts]!.error!.contains("/Users"))      // paths redacted
        XCTAssertTrue(bad.sources[.workers]!.ok)                               // other sources unaffected
        XCTAssertTrue(bad.sources[.status]!.ok)
        XCTAssertFalse(bad.stale)                                              // 1 cycle old only
    }

    func testBecomesStaleAfterThreeIntervalsWithoutCompleteCycle() async {
        let runner = FakeRunner.standard()
        let collector = OrcaCollector(runner: runner, pollInterval: 15)
        _ = await collector.collect(now: TestClock.now, calendar: TestClock.utc)
        runner.fail("status --json", .timeout)
        let s = await collector.collect(now: TestClock.now.addingTimeInterval(50), calendar: TestClock.utc)
        XCTAssertTrue(s.stale)
        XCTAssertFalse(s.orca.ok)
        XCTAssertEqual(s.orca.version, "1.4.233")                              // last good version kept
    }

    func testEnvelopeOkFalseIsAnErrorAndFirstFailureHasNoData() async {
        let runner = FakeRunner.standard()
        runner.set("worktree ps --json", #"{"ok":false,"error":{"code":"runtime_unavailable","message":"Orca is not running"}}"#)
        runner.set("orchestration worker-list --json", "not json")
        let s = await OrcaCollector(runner: runner).collect(now: TestClock.now, calendar: TestClock.utc)
        XCTAssertTrue(s.workspaces.isEmpty)
        XCTAssertEqual(s.sources[.worktrees]?.error, "invalid output: Orca is not running")
        XCTAssertEqual(s.sources[.workers]?.error, "invalid output: not JSON")
        XCTAssertNil(s.sources[.worktrees]?.lastSuccessAt)
        XCTAssertTrue(s.stale)
    }

    func testFailingLaterWorkerPageKeepsPreviousFullList() async {
        let runner = FakeRunner.standard()
        let collector = OrcaCollector(runner: runner)
        let good = await collector.collect(now: TestClock.now, calendar: TestClock.utc)
        runner.fail("orchestration worker-list --json --cursor CURSOR-PAGE-2", .timeout)
        let bad = await collector.collect(now: TestClock.now.addingTimeInterval(15), calendar: TestClock.utc)
        XCTAssertFalse(bad.sources[.workers]!.ok)
        XCTAssertEqual(bad.workers, good.workers)                              // no partial list
    }

    func testPollIntervalHasFiveSecondFloor() async {
        let c = OrcaCollector(runner: FakeRunner.standard(), pollInterval: 1)
        let interval = await c.pollInterval
        XCTAssertEqual(interval, 5)
    }

    func testPrivacyNothingSensitiveReachesTheSnapshot() async {
        let s = await OrcaCollector(runner: FakeRunner.standard()).collect(now: TestClock.now, calendar: TestClock.utc)
        let dump = String(reflecting: s)
        for secret in ["SECRET-PROMPT-DO-NOT-LEAK", "SECRET-TOOLINPUT-DO-NOT-LEAK", "secret.user@example.com",
                       "ORG-UUID-DO-NOT-LEAK", "ACCOUNT-ID-DO-NOT-LEAK", "Secret Org", "/redacted/", "repo-"] {
            XCTAssertFalse(dump.contains(secret), "leaked \(secret)")
        }
        XCTAssertFalse(dump.contains(String(repeating: "L", count: 161)))
    }
}

final class OrcaResolverAndStoreTests: XCTestCase {
    func testResolverOrder() {
        let all: @Sendable (String) -> Bool = { _ in true }
        var r = OrcaExecutableResolver(environment: ["ORCA_CLI_COMMAND": "/custom/orca", "PATH": "/a:/b"], isExecutable: all)
        XCTAssertEqual(r.resolve(), "/custom/orca")
        XCTAssertEqual(r.candidates(), ["/custom/orca", "/usr/local/bin/orca", "/opt/homebrew/bin/orca", "/a/orca", "/b/orca",
                                        "/Applications/Orca.app/Contents/Resources/bin/orca"])
        r = OrcaExecutableResolver(environment: ["PATH": "/a"], isExecutable: all)
        XCTAssertEqual(r.resolve(), "/usr/local/bin/orca")
        r = OrcaExecutableResolver(environment: ["PATH": "/a"], isExecutable: { $0 == "/opt/homebrew/bin/orca" })
        XCTAssertEqual(r.resolve(), "/opt/homebrew/bin/orca")
        r = OrcaExecutableResolver(environment: ["ORCA_CLI_COMMAND": "/missing", "PATH": "/a"], isExecutable: { $0 == "/a/orca" })
        XCTAssertEqual(r.resolve(), "/a/orca")
        r = OrcaExecutableResolver(environment: [:], isExecutable: { _ in false })
        XCTAssertNil(r.resolve())
    }

    func testMissingExecutableIsReportedNotThrown() async throws {
        let runner = ProcessCommandRunner(resolver: OrcaExecutableResolver(environment: [:], isExecutable: { _ in false }))
        do { _ = try await runner.run(arguments: ["status", "--json"], timeout: 1); XCTFail() }
        catch { XCTAssertEqual(error as? OrcaCommandError, .executableNotFound) }
    }

    func testProcessRunnerTimeoutAndLargeOutput() async throws {
        let sleepRunner = ProcessCommandRunner(resolver: OrcaExecutableResolver(environment: ["ORCA_CLI_COMMAND": "/bin/sleep"], isExecutable: { $0 == "/bin/sleep" }))
        let started = Date()
        do { _ = try await sleepRunner.run(arguments: ["5"], timeout: 0.5); XCTFail() }
        catch { XCTAssertEqual(error as? OrcaCommandError, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        // 1 MB on stdout and stderr must not deadlock on a full pipe.
        let sh = ProcessCommandRunner(resolver: OrcaExecutableResolver(environment: ["ORCA_CLI_COMMAND": "/bin/sh"], isExecutable: { $0 == "/bin/sh" }))
        let data = try await sh.run(arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\0' a; head -c 1000000 /dev/zero >&2"], timeout: 10)
        XCTAssertEqual(data.count, 1_000_000)
    }

    @MainActor func testStorePublishesSnapshotAndStops() async {
        let store = OrcaStore(runner: FakeRunner.standard(), pollInterval: 1)
        XCTAssertEqual(store.pollInterval, 5)
        XCTAssertEqual(store.snapshot, .empty)
        await store.refresh()
        XCTAssertEqual(store.snapshot.workspaces.count, 14)
        store.includeRemote = false
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.snapshot.workspaces.count, 13)
        store.start(); XCTAssertTrue(store.isPolling)
        store.stop(); XCTAssertFalse(store.isPolling)
    }
}
