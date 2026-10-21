import Foundation
import os
@testable import OrcaKit

/// Fake CLI: answers by joined arguments; counts calls; can be switched to fail.
final class FakeRunner: OrcaCommandRunning, @unchecked Sendable {
    private struct State { var responses: [String: Result<String, OrcaCommandError>] = [:]; var calls: [[String]] = [] }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var calls: [[String]] { state.withLock { $0.calls } }

    func set(_ args: String, _ json: String) { state.withLock { $0.responses[args] = .success(json) } }
    func fail(_ args: String, _ error: OrcaCommandError) { state.withLock { $0.responses[args] = .failure(error) } }

    func run(arguments: [String], timeout: TimeInterval) async throws -> Data {
        let r = state.withLock { s -> Result<String, OrcaCommandError>? in
            s.calls.append(arguments)
            return s.responses[arguments.joined(separator: " ")]
        }
        switch r {
        case .success(let s)?: return Data(s.utf8)
        case .failure(let e)?: throw e
        case nil: throw OrcaCommandError.nonZeroExit(1, "unexpected call \(arguments.joined(separator: " "))")
        }
    }

    static func standard() -> FakeRunner {
        let r = FakeRunner()
        r.set("worktree ps --json", Fixtures.worktreePs)
        r.set("account list --json", Fixtures.accountList)
        r.set("orchestration worker-list --json", Fixtures.workersPage1)
        r.set("orchestration worker-list --json --cursor CURSOR-PAGE-2", Fixtures.workersPage2)
        r.set("status --json", Fixtures.status)
        return r
    }
}

enum TestClock {
    /// 2026-10-21 ~13:25 UTC, a few minutes after the fixture capture.
    static let now = Date(timeIntervalSince1970: 1_792_610_700)
    static var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
}
