#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/Check.swift" <<'PY'
from pathlib import Path
import sys
service = Path('NotchBuddy/Sources/App/AndroidLink/AndroidLinkService.swift').read_text()
start = service.index('    private func observe() {')
end = service.index('    private func publish() {', start)
observe = service[start:end].replace('private func observe()', 'func observe()', 1)
info = Path('NotchBuddy/Sources/App/CodexAgentsInfo.swift').read_text()
start = info.index('    var currentPlanUsage: CodexPlanUsage? {')
end = info.index('    init(connection:', start)
current = info[start:end]
state = Path('NotchBuddy/Sources/App/AppState.swift').read_text()
bridge = next(line for line in state.splitlines() if line.strip().startswith('var codexPlanUsage: CodexPlanUsage?'))
fixture = r'''import Foundation
import Combine
struct PlanWindow { var usedPct: Double; var resetsAt: Date }
struct CodexPlanUsage { var fiveHour: PlanWindow?; var sevenDay: PlanWindow?; var updatedAt: Date }
@MainActor final class CodexAgentsInfo: ObservableObject {
    static let shared = CodexAgentsInfo()
    @Published var planUsage: CodexPlanUsage?
CURRENT
}
@MainActor final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var tasks: [Int] = []
    @Published var pendingApproval: Int?
    @Published var waitingQuestions: [Int] = []
    @Published var claudePlanUsage: Int?
BRIDGE
}
@MainActor final class AndroidLinkService {
    var cancellable: AnyCancellable?
    var published: [Double?] = []
    func publish() { published.append(AppState.shared.codexPlanUsage?.fiveHour?.usedPct) }
OBSERVE
}
@main enum Check {
    @MainActor static func main() {
        let service = AndroidLinkService(), info = CodexAgentsInfo.shared
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        service.observe(); settle()
        assert(service.published.count == 1 && service.published[0] == nil)
        info.planUsage = CodexPlanUsage(fiveHour: PlanWindow(usedPct: 37, resetsAt: Date().addingTimeInterval(600)), sevenDay: nil, updatedAt: Date())
        settle()
        assert(service.published.count == 2 && service.published[1] == 37)
        // A stale shared snapshot must trigger a publication without reporting a stale quota.
        info.planUsage = CodexPlanUsage(fiveHour: PlanWindow(usedPct: 41, resetsAt: Date().addingTimeInterval(600)), sevenDay: nil, updatedAt: Date().addingTimeInterval(-301))
        settle()
        assert(service.published.count == 3 && service.published[2] == nil)
        info.planUsage = nil
        settle()
        assert(service.published.count == 4 && service.published[3] == nil)
        service.cancellable = nil
        info.planUsage = CodexPlanUsage(fiveHour: PlanWindow(usedPct: 22, resetsAt: Date().addingTimeInterval(600)), sevenDay: nil, updatedAt: Date())
        settle()
        assert(service.published.count == 4)
        print("PASS actual Android observer: shared quota update, stale suppression, account clear and unsubscribe")
    }
}
'''
Path(sys.argv[1]).write_text(fixture.replace('CURRENT', current).replace('BRIDGE', bridge).replace('OBSERVE', observe))
PY
swiftc -swift-version 6 -parse-as-library "$test_dir/Check.swift" -o "$test_dir/check"
"$test_dir/check"
