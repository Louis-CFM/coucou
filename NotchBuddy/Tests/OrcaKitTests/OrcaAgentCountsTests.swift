import XCTest
@testable import OrcaKit

final class OrcaAgentCountsTests: XCTestCase {
    // TestClock.now = 1_792_610_700 (2026-10-21 ~13:25 UTC): "today" starts at 1_792_540_800.
    private let today = 1_792_600_000_000.0       // ms, today
    private let yesterday = 1_792_500_000_000.0   // ms, before today's start
    private let recent = 1_792_610_000_000.0      // ms, 12 min ago
    private let old = 1_791_000_000_000.0         // ms, ~18 days ago

    private func derive(_ worktrees: String, workers: String = "[]") throws -> OrcaSnapshot {
        let ps = #"{"ok":true,"result":{"worktrees":\#(worktrees)}}"#
        let wl = #"{"ok":true,"result":{"workers":\#(workers)}}"#
        let raw = OrcaRawState(
            worktrees: try JSONDecoder().decode(OrcaEnvelope<RawWorktreesResult>.self, from: Data(ps.utf8)).result!.worktrees!,
            workers: try JSONDecoder().decode(OrcaEnvelope<RawWorkersResult>.self, from: Data(wl.utf8)).result!.workers!)
        return OrcaDerivation.derive(raw: raw, sources: [:], lastCompleteCycleAt: nil, pollInterval: 15,
                                     now: TestClock.now, calendar: TestClock.utc)
    }

    private func worktree(_ id: String, activity: Double, unread: Bool = false, agents: [String]) -> String {
        #"{"worktreeId":"r::/\#(id)","repo":"r","displayName":"\#(id)","unread":\#(unread),"lastActivityAt":\#(Int(activity)),"agents":[\#(agents.joined(separator: ","))]}"#
    }

    private func agent(_ state: String, since: Double) -> String {
        #"{"agentType":"claude","state":"\#(state)","stateStartedAt":\#(Int(since))}"#
    }

    func testCountsAgentsNotWorkspaces() throws {
        let s = try derive("[" + [
            worktree("two-running", activity: recent, agents: [agent("working", since: recent), agent("working", since: recent)]),
            worktree("done-today", activity: recent, agents: [agent("done", since: today), agent("done", since: today)]),
        ].joined(separator: ",") + "]")
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts(running: 2, finished: 2, alert: 0))
        XCTAssertEqual(s.agentCounts.running, s.counts.runningAgents)
        XCTAssertEqual(s.workspaces.count, 2)      // 2 workspaces, 4 agents
    }

    func testFinishedOnlyCountsAgentsDoneToday() throws {
        let s = try derive("[" + worktree("w", activity: recent, agents: [agent("done", since: today), agent("done", since: yesterday)]) + "]")
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts(running: 0, finished: 1, alert: 0))
        XCTAssertEqual(s.workspaces[0].agents.map(\.status), [.finished, .idle])
    }

    func testWaitingAgentIsAlertOnlyWhileWorkspaceIsRecent() throws {
        let s = try derive("[" + [
            worktree("recent", activity: recent, agents: [agent("waiting-permission", since: recent)]),
            worktree("stale", activity: old, agents: [agent("waiting-permission", since: old)]),
        ].joined(separator: ",") + "]")
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts(running: 0, finished: 0, alert: 1))
    }

    func testUnreadRingsOnceOnTheAgentThatFinishedLast() throws {
        let s = try derive("[" + worktree("w", activity: recent, unread: true,
                                          agents: [agent("done", since: today), agent("done", since: today + 5_000), agent("working", since: recent)]) + "]")
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts(running: 1, finished: 1, alert: 1))
        XCTAssertEqual(s.workspaces[0].agents.map(\.status), [.finished, .alert, .running])
    }

    func testUnreadIsIgnoredWhenWorkspaceIsOld() throws {
        let s = try derive("[" + worktree("w", activity: old, unread: true, agents: [agent("done", since: old)]) + "]")
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts())
    }

    func testWorkspaceThatNeedsYouWithoutAgentRingsTheBellOnce() throws {
        let s = try derive("[" + worktree("w", activity: recent, unread: true, agents: []) + "]")
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts(running: 0, finished: 0, alert: 1))
    }

    func testFailedWorkerIsAnAlert() throws {
        let workers = #"[{"taskId":"t","projection":{"outcome":"failed","workspace":{"id":"r::/w"}}}]"#
        let s = try derive("[" + worktree("w", activity: old, agents: [agent("done", since: old)]) + "]", workers: workers)
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts(running: 0, finished: 0, alert: 1))
        XCTAssertEqual(s.workspaces[0].state, .failed)
    }

    func testArchivedWorkspacesAreNotCounted() throws {
        let s = try derive(#"[{"worktreeId":"r::/a","repo":"r","displayName":"a","isArchived":true,"agents":[{"state":"working"}]}]"#)
        XCTAssertEqual(s.agentCounts, OrcaAgentCounts())
    }

    func testIslandStaysVisibleOnlyForRunningOrAlert() {
        XCTAssertFalse(OrcaAgentCounts().keepsIslandVisible)
        XCTAssertFalse(OrcaAgentCounts(running: 0, finished: 5, alert: 0).keepsIslandVisible)
        XCTAssertTrue(OrcaAgentCounts(running: 1).keepsIslandVisible)
        XCTAssertTrue(OrcaAgentCounts(alert: 1).keepsIslandVisible)
        XCTAssertEqual(OrcaAgentCounts(running: 1, finished: 2, alert: 3).total, 6)
    }

    func testStandardFixtureCountersAddUp() async {
        let s = await OrcaCollector(runner: FakeRunner.standard()).collect(now: TestClock.now, calendar: TestClock.utc)
        let all = s.workspaces.flatMap(\.agents)
        XCTAssertEqual(s.agentCounts.running, all.filter { $0.status == .running }.count)
        XCTAssertEqual(s.agentCounts.running, s.counts.runningAgents)
        XCTAssertGreaterThanOrEqual(s.agentCounts.alert, s.counts.attention - 0)  // every attention workspace rings at least once
    }
}

final class OrcaPollPolicyTests: XCTestCase {
    func testIntervalFollowsIslandAndSleep() {
        XCTAssertEqual(OrcaPollPolicy.interval(islandVisible: true, asleep: false), 2.5)
        XCTAssertEqual(OrcaPollPolicy.interval(islandVisible: false, asleep: false), 15)
        XCTAssertEqual(OrcaPollPolicy.interval(islandVisible: true, asleep: true), 15)
        XCTAssertEqual(OrcaPollPolicy.interval(islandVisible: false, asleep: true), 15)
    }

    func testActiveRateIsWithinTwoToThreeSeconds() {
        XCTAssertTrue((2.0...3.0).contains(OrcaPollPolicy.activeInterval))
    }

    func testFullCycleDueFirstThenEveryFifteenSeconds() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(OrcaPollPolicy.isFullCycleDue(lastFullAt: nil, now: t0))
        XCTAssertFalse(OrcaPollPolicy.isFullCycleDue(lastFullAt: t0, now: t0.addingTimeInterval(2.5)))
        XCTAssertFalse(OrcaPollPolicy.isFullCycleDue(lastFullAt: t0, now: t0.addingTimeInterval(10)))
        XCTAssertTrue(OrcaPollPolicy.isFullCycleDue(lastFullAt: t0, now: t0.addingTimeInterval(14)))   // within slack
        XCTAssertTrue(OrcaPollPolicy.isFullCycleDue(lastFullAt: t0, now: t0.addingTimeInterval(15)))
    }

    func testFastCycleReadsOnlyWorktrees() async {
        let runner = FakeRunner.standard()
        let collector = OrcaCollector(runner: runner)
        _ = await collector.collect(now: TestClock.now, calendar: TestClock.utc)
        let before = runner.calls.count
        let s = await collector.collectFast(now: TestClock.now, calendar: TestClock.utc)
        XCTAssertEqual(runner.calls.dropFirst(before).map { $0.joined(separator: " ") }, ["worktree ps --json"])
        XCTAssertEqual(s.workspaces.count, 14)
        XCTAssertFalse(s.usage.isEmpty)                  // slow sources keep their last good value
    }

    @MainActor func testStoreSwitchesCadenceWithActivity() {
        let store = OrcaStore(runner: FakeRunner.standard())
        XCTAssertEqual(store.tickInterval, 15)
        store.setActivity(islandVisible: true, asleep: false)
        XCTAssertEqual(store.tickInterval, 2.5)
        store.setActivity(islandVisible: true, asleep: true)
        XCTAssertEqual(store.tickInterval, 15)
        store.setActivity(islandVisible: false, asleep: false)
        XCTAssertEqual(store.tickInterval, 15)
    }
}
