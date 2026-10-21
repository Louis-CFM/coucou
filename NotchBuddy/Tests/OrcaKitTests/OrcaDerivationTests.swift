import XCTest
@testable import OrcaKit

final class OrcaDerivationTests: XCTestCase {
    private func snapshot(includeRemote: Bool = true) async -> OrcaSnapshot {
        let collector = OrcaCollector(runner: FakeRunner.standard())
        return await collector.collect(includeRemote: includeRemote, now: TestClock.now, calendar: TestClock.utc)
    }

    private func ws(_ s: OrcaSnapshot, _ name: String, repo: String? = nil) -> OrcaWorkspace? {
        s.workspaces.first { $0.name == name && (repo == nil || $0.repo == repo) }
    }

    func testArchivedExcludedAndKeyIsStableSha1Prefix() async {
        let s = await snapshot()
        XCTAssertNil(ws(s, "archived-one"))
        XCTAssertEqual(s.workspaces.count, 14)
        XCTAssertEqual(OrcaDerivation.key(for: "abc"), "a9993e364706")
        XCTAssertEqual(Set(s.workspaces.map(\.key)).count, 14)
        XCTAssertEqual(ws(s, "strip-rebrand")?.branch, "henriquefps/strip-rebrand")
    }

    func testActiveWorkspaceAndRunningAgent() async {
        let s = await snapshot()
        // active = status active|working or terminalVerdict live
        XCTAssertTrue(ws(s, "strip-rebrand")!.isActive)
        XCTAssertFalse(ws(s, "ctx-1m-b")!.isActive)
        XCTAssertEqual(s.counts.running, 3)
        XCTAssertEqual(s.counts.runningAgents, 3)
        XCTAssertTrue(ws(s, "orcakit")!.hasRunningAgent)
        XCTAssertEqual(ws(s, "orcakit")!.primaryAgent?.type, "claude")
    }

    func testNeedsYouRequiresRecentActivity() async {
        let s = await snapshot()
        XCTAssertEqual(ws(s, "needs-input")?.state, .attention)        // waiting-permission agent, recent
        XCTAssertEqual(ws(s, "fresh-unread")?.state, .attention)       // unread, recent
        XCTAssertEqual(ws(s, "requests")?.state, .done)                // 317 h old, not attention
        let old = ws(s, "old-unread")!                                  // unread but > 24 h
        XCTAssertFalse(old.needsAttention)
        XCTAssertNotEqual(old.state, .attention)
        XCTAssertEqual(old.state, .done)                                // falls to the next rule
        // A worker that requires action on an OLD workspace does not count either.
        let stale = ws(s, "requests")!
        XCTAssertTrue(stale.workers.contains { $0.requiresAction })
        XCTAssertFalse(stale.needsAttention)
        XCTAssertEqual(s.counts.attention, 2)   // needs-input + fresh-unread
        XCTAssertEqual(s.counts.attention, s.workspaces.filter(\.needsAttention).count)
    }

    func testWorkerRequiresActionOnRecentWorkspaceNeedsYou() throws {
        let ps = #"{"ok":true,"result":{"worktrees":[{"worktreeId":"r::/x","repo":"r","displayName":"x","lastActivityAt":1792610000000,"agents":[{"state":"done","stateStartedAt":1792000000000}]}]}}"#
        let wl = #"{"ok":true,"result":{"workers":[{"taskId":"t","projection":{"outcome":"in_progress","workspace":{"id":"r::/x"},"attention":{"requiresAction":true}}}]}}"#
        let raw = OrcaRawState(
            worktrees: try JSONDecoder().decode(OrcaEnvelope<RawWorktreesResult>.self, from: Data(ps.utf8)).result!.worktrees!,
            workers: try JSONDecoder().decode(OrcaEnvelope<RawWorkersResult>.self, from: Data(wl.utf8)).result!.workers!)
        let s = OrcaDerivation.derive(raw: raw, sources: [:], lastCompleteCycleAt: nil, pollInterval: 15, now: TestClock.now, calendar: TestClock.utc)
        XCTAssertEqual(s.workspaces[0].state, .attention)
        XCTAssertEqual(s.counts.attention, 1)
    }

    func testStatePriority() async {
        let s = await snapshot()
        XCTAssertEqual(ws(s, "main", repo: "tortola-ventures")?.state, .failed)   // failed worker beats in-review
        XCTAssertEqual(ws(s, "strip-rebrand")?.state, .running)
        XCTAssertEqual(ws(s, "ctx-1m-b")?.state, .review)                         // open PR
        XCTAssertEqual(ws(s, "main", repo: "writting-assistant")?.state, .done)   // completed
        XCTAssertEqual(ws(s, "master", repo: "kindle-apps")?.state, .idle)
        let order = s.workspaces.map(\.state.priority)
        XCTAssertEqual(order, order.sorted())
    }

    func testReviewFromWorkspaceStatusAndPR() {
        func state(status: String?, pr: String?, agents: String = "[]") -> OrcaWorkspaceState {
            let prJSON = pr.map { #""linkedPR":{"number":1,"state":"\#($0)"},"# } ?? ""
            let json = #"{"ok":true,"result":{"worktrees":[{"worktreeId":"r::/x","repo":"r","displayName":"x",\#(prJSON)"workspaceStatus":\#(status.map { "\"\($0)\"" } ?? "null"),"agents":\#(agents)}]}}"#
            let raw = OrcaRawState(worktrees: try! JSONDecoder().decode(OrcaEnvelope<RawWorktreesResult>.self, from: Data(json.utf8)).result!.worktrees!)
            return OrcaDerivation.derive(raw: raw, sources: [:], lastCompleteCycleAt: nil, pollInterval: 15, now: TestClock.now, calendar: TestClock.utc).workspaces[0].state
        }
        XCTAssertEqual(state(status: "in-review", pr: nil), .review)
        XCTAssertEqual(state(status: "in-progress", pr: "open"), .review)
        XCTAssertEqual(state(status: "in-progress", pr: "merged"), .idle)
        XCTAssertEqual(state(status: "completed", pr: nil), .done)
        XCTAssertEqual(state(status: nil, pr: nil, agents: #"[{"state":"done"}]"#), .done)
        XCTAssertEqual(state(status: nil, pr: "open", agents: #"[{"state":"working"}]"#), .running)
    }

    func testRemoteAndRemoteFilter() async {
        let s = await snapshot()
        XCTAssertEqual(s.counts.remote, 1)
        XCTAssertTrue(ws(s, "remote-box")!.isRemote)
        let local = await snapshot(includeRemote: false)
        XCTAssertNil(ws(local, "remote-box"))
        XCTAssertEqual(local.counts.remote, 0)
        XCTAssertEqual(local.workspaces.count, 13)
    }

    func testDoneTodayCountsEachWorkspaceOnce() async {
        let s = await snapshot()
        // Local day = 2026-10-21 UTC. Contributors: worker s2 (observed today, writting-assistant),
        // worker s3 on orca-monitor main, done agents started today. Workspaces counted once.
        let expected = s.workspaces.filter { w in
            w.workers.contains { ($0.outcome == "succeeded" || $0.outcome == "failed") && ($0.updatedAt ?? 0) >= 1_792_540_800 }
                || w.agents.contains { $0.state == "done" && ($0.since ?? 0) >= 1_792_540_800 }
        }.count
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(s.counts.doneToday, expected)
        // A different local day yields 0 for the same data.
        let tomorrow = TestClock.now.addingTimeInterval(2 * 86400)
        let later = await OrcaCollector(runner: FakeRunner.standard()).collect(now: tomorrow, calendar: TestClock.utc)
        XCTAssertEqual(later.counts.doneToday, 0)
    }

    func testWorkerCountsAndPaginationMerged() async {
        let s = await snapshot()
        XCTAssertEqual(s.workers.succeeded, 4)   // 2 from page 1 + 2 from page 2
        XCTAssertEqual(s.workers.failed, 1)
        XCTAssertEqual(s.workers.running, 3)
        XCTAssertEqual(s.workers.requiresAction, 2)   // failed f1 + running r1
    }

    func testUsagePerProviderWithResetTime() async {
        let s = await snapshot()
        XCTAssertEqual(s.usage.map(\.provider), ["antigravity", "claude"])   // codex has no data, someFlag is not a provider: omitted
        let claude = s.usage.first { $0.provider == "claude" }!
        XCTAssertEqual(claude.label, "Claude")
        XCTAssertEqual(claude.session?.pct, 2)
        XCTAssertEqual(claude.session?.resetsAt, 1_792_627_800)               // ms -> s
        XCTAssertEqual(claude.session?.resetText, "thu")   // 00:10 UTC tomorrow
        XCTAssertEqual(claude.weekly?.resetText, "sun")
        XCTAssertEqual(claude.weekly?.pct, 92)
        XCTAssertNil(s.usage.first { $0.provider == "antigravity" }?.session)
        XCTAssertNotNil(s.usage.first { $0.provider == "antigravity" }?.weekly)
    }

    func testOrcaHealthAndVersion() async {
        let s = await snapshot()
        XCTAssertTrue(s.orca.ok)
        XCTAssertEqual(s.orca.version, "1.4.233")
        XCTAssertFalse(s.stale)
        XCTAssertTrue(s.sources.values.allSatisfy(\.ok))
    }

    func testAgentLastMessageTruncatedTo160OneLine() async {
        let s = await snapshot()
        let last = ws(s, "fresh-unread")!.agents[0].last!
        XCTAssertEqual(last.count, 160)
        XCTAssertTrue(last.hasSuffix("…"))
        XCTAssertEqual(ws(s, "requests")?.agents.first?.last, "Short assistant message")
        XCTAssertEqual(ws(s, "main", repo: "orca-monitor")!.comment?.count, 120)
    }

    func testSortedByStateThenRecentActivity() async {
        let s = await snapshot()
        for (a, b) in zip(s.workspaces, s.workspaces.dropFirst()) where a.state == b.state {
            XCTAssertGreaterThanOrEqual(a.lastActivityAt ?? 0, b.lastActivityAt ?? 0)
        }
    }
}
