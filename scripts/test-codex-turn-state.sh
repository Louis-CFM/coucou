#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
python3 - "$task_tmp/TurnStateCheck.swift" <<'PY'
from pathlib import Path
import sys
state = Path('NotchBuddy/Sources/App/AppState.swift').read_text()
start = state.index('    @discardableResult\n    func appendSessionDiff(')
end = state.index('    private func resetSessionDiffTimer(', start)
methods = state[start:end].replace('@Published ', '')
recap = Path('NotchBuddy/Sources/App/RecapStore.swift').read_text()
draft = recap[recap.index('private struct TurnDraft {'):recap.index('// MARK: - Store')].replace('private struct', 'struct')
start = recap.index('    func userPromptSubmit(')
end = recap.index('    /// Called when the user sends answers', start)
recording = recap[start:end]
hooks = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
start = hooks.index('    @MainActor\n    func reconcileCodexDiffs(')
end = hooks.index('    #endif', start)
reconcile = hooks[start:end]
Path(sys.argv[1]).write_text('''import Foundation
struct AgentTask {
    var id = "agent_codex"
    var codexManaged = true
    var codexThreadId: String? = "thread"
    var codexTurnId: String? = "turn"
    var steps = ["Inspect", "Run tests"]
    var stepIndex = 0
}
@MainActor final class AppState {
    static let shared = AppState()
    var tasks = [AgentTask()]
    var sessionDiffs: [String: [FileDiff]] = [:]
    var sessionDiffTimers: [String: DispatchWorkItem] = [:]
    var nextDiffId = 0
    func resetSessionDiffTimer(for pillId: String) {}
''' + methods + '''
}
''' + draft + '''
@MainActor final class RecapStore {
    static let shared = RecapStore()
    var drafts: [String: TurnDraft] = [:]
    var isEnabled = true
    func pruneStale() {}
''' + recording + '''
}
@MainActor final class HookServer {
    static let shared = HookServer()
''' + reconcile + '''
}
''')
PY
cat >> "$task_tmp/TurnStateCheck.swift" <<'SWIFT'
@main enum TurnStateCheck {
    @MainActor static func main() {
        func unified(_ path: String, _ count: Int) -> String {
            "diff --git a/\(path) b/\(path)\n--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(count) @@\n" + String(repeating: "+line\n", count: count)
        }
        func change(_ path: String, _ count: Int) -> [String: Any] {
            ["path": path, "kind": ["type": "add"], "diff": unified(path, count)]
        }
        let app = AppState.shared, recap = RecapStore.shared, server = HookServer.shared
        recap.userPromptSubmit(sessionId: "thread", pillId: "agent_codex", project: "Project")
        recap.userPromptSubmit(sessionId: "external", pillId: "agent_codex", project: "Other")
        recap.recordFileDiff(sessionId: "external", path: "/other.txt", added: 30, removed: 20)
        recap.preToolUse(sessionId: "thread", tool: "Bash")
        let sibling = FileDiff(path: "/external.txt", added: 9, removed: 4, hunks: [], tooLarge: false, isNewFile: false)
        let siblingID = app.appendSessionDiff(sibling, for: "agent_codex")
        app.tasks[0].steps.append(.makeDiffStep(filename: sibling.name, added: sibling.added, removed: sibling.removed, diffId: siblingID))
        var turn = CodexTurnDiffState()
        func publish() { server.reconcileCodexDiffs(turn.files, threadId: "thread", turnId: "turn", moves: turn.moveSources) }
        assert(turn.updateSnapshot(unified("a.swift", 2) + unified("b.swift", 1), cwd: "/project"))
        publish()
        let aID = app.sessionDiffs["agent_codex"]!.first { $0.path == "/project/a.swift" }!.id
        let bID = app.sessionDiffs["agent_codex"]!.first { $0.path == "/project/b.swift" }!.id
        assert(Set([aID, bID, siblingID]).count == 3)
        assert(recap.drafts["thread"]?.linesAdded == 3 && recap.drafts["thread"]?.changedPaths.count == 2)
        assert(recap.drafts["thread"]?.commandsRun == 1)
        for _ in 0..<3 { assert(turn.updateSnapshot(unified("a.swift", 2) + unified("b.swift", 1), cwd: "/project")); publish() }
        assert(app.sessionDiffs["agent_codex"]!.count == 3 && app.tasks[0].steps.count == 5)
        assert(recap.drafts["thread"]?.linesAdded == 3, "Repeated aggregate inflated recap")
        assert(app.sessionDiffs["agent_codex"]!.first { $0.path == "/project/a.swift" }!.id == aID)
        assert(turn.updateSnapshot(unified("a.swift", 1), cwd: "/project")); publish()
        assert(app.sessionDiffs["agent_codex"]!.map(\.path) == ["/external.txt", "/project/a.swift"])
        assert(recap.drafts["thread"]?.linesAdded == 1 && recap.drafts["thread"]?.changedPaths.count == 1)
        _ = turn.recordItem([change("a.swift", 1), change("c.swift", 2)], cwd: "/project"); publish()
        assert(turn.files.count == 2 && turn.files.reduce(0) { $0 + $1.added } == 3, "Item plus aggregate doubled an existing path")
        assert(turn.updateSnapshot(unified("a.swift", 2) + unified("c.swift", 2), cwd: "/project")); publish()
        assert(turn.files.reduce(0) { $0 + $1.added } == 4)
        assert(recap.drafts["external"]?.linesAdded == 30 && recap.drafts["external"]?.linesRemoved == 20)
        let before = app.sessionDiffs
        app.tasks[0].codexManaged = false
        assert(!app.replaceCodexSessionDiffs([], threadId: "thread", turnId: "turn", moves: [:]))
        app.tasks[0].codexManaged = true
        assert(!app.replaceCodexSessionDiffs([], threadId: "thread", turnId: "old", moves: [:]))
        assert(!app.replaceCodexSessionDiffs([], threadId: "other", turnId: "turn", moves: [:]))
        assert(app.sessionDiffs == before, "Snapshot touched another display owner")
        assert(!turn.updateSnapshot(String(repeating: "x", count: FileDiff.maxBytes + 1), cwd: "/project"))
        assert(turn.files.count == 2)
        assert(turn.updateSnapshot("", cwd: "/project")); publish()
        assert(app.sessionDiffs["agent_codex"]!.map(\.id) == [siblingID])
        assert(app.tasks[0].steps.count == 3 && recap.drafts["thread"]?.linesAdded == 0)
        // A later turn retains earlier/native/external history, with fresh stable IDs.
        app.tasks[0].codexTurnId = "next"
        server.reconcileCodexDiffs([sibling], threadId: "thread", turnId: "next", moves: [:])
        assert(app.sessionDiffs["agent_codex"]!.count == 2)
        assert(app.sessionDiffs["agent_codex"]!.last!.id > max(aID, bID))
        app.clearSessionDiffs(for: "agent_codex")
        assert(app.sessionDiffs["agent_codex"] == nil)
        let newID = app.appendSessionDiff(sibling, for: "agent_codex")
        assert(newID > max(aID, bID), "Clearing diffs reset the global ID counter")
        let renamedApp = AppState()
        let original = FileDiff(path: "/project/old.swift", added: 1, removed: 0, hunks: [], tooLarge: false, isNewFile: false)
        assert(renamedApp.replaceCodexSessionDiffs([original], threadId: "thread", turnId: "turn", moves: [:]))
        let originalID = renamedApp.sessionDiffs["agent_codex"]![0].id
        var destination = original; destination.path = "/project/new.swift"
        assert(renamedApp.replaceCodexSessionDiffs([destination], threadId: "thread", turnId: "turn", moves: [original.path: destination.path]))
        assert(renamedApp.sessionDiffs["agent_codex"]!.count == 1 && renamedApp.sessionDiffs["agent_codex"]![0].id == originalID, "Rename invalidated a file's selected diff ID")
        var moved = CodexTurnDiffState()
        _ = moved.recordItem([change("old.swift", 1)], cwd: "/project")
        _ = moved.recordItem([["path": "old.swift", "kind": ["type": "update", "move_path": "new.swift"], "diff": ""]], cwd: "/project")
        assert(moved.files.count == 1 && moved.files[0].path == "/project/new.swift")
        assert(moved.files[0].added == 1 && !moved.files[0].hunks.isEmpty, "Pure rename discarded earlier item changes")
        var snapshotMove = CodexTurnDiffState()
        assert(snapshotMove.updateSnapshot(unified("old.swift", 2), cwd: "/project"))
        _ = snapshotMove.recordItem([["path": "old.swift", "kind": ["type": "update", "move_path": "new.swift"], "diff": ""]], cwd: "/project")
        assert(snapshotMove.files.count == 1 && snapshotMove.files[0].path == "/project/new.swift" && snapshotMove.files[0].added == 2,
               "Pure rename discarded earlier aggregate changes")
        assert(snapshotMove.files[0].hunks.count == 1)
        assert(moved.updateSnapshot("diff --git a/old.swift b/new.swift\nsimilarity index 100%\nrename from old.swift\nrename to new.swift\n" + "diff --git a/empty.txt b/empty.txt\nnew file mode 100644\n" + "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n", cwd: "/project"))
        assert(moved.files.map(\.path) == ["/project/new.swift", "/project/empty.txt", "/project/gone.txt"])
        assert(moved.files[1].isNewFile && moved.files.allSatisfy { $0.added == 0 && $0.removed == 0 })
        var sequential = CodexTurnDiffState()
        assert(sequential.updateSnapshot(unified("same.swift", 1), cwd: "/project"))
        sequential.itemStarted("later")
        _ = sequential.recordItem([change("same.swift", 2)], cwd: "/project", itemId: "later")
        assert(sequential.files.count == 1 && sequential.files[0].added == 3, "Later same-path item disappeared without another aggregate")
        assert(sequential.files[0].hunks.count == 2)
        sequential.itemStarted("during")
        assert(sequential.updateSnapshot(unified("same.swift", 3), cwd: "/project"))
        _ = sequential.recordItem([change("same.swift", 2)], cwd: "/project", itemId: "during")
        assert(sequential.files[0].added == 3, "Aggregate during an item counted the item twice")
        var reverted = CodexTurnDiffState()
        assert(reverted.updateSnapshot(unified("undone.swift", 1), cwd: "/project"))
        reverted.itemStarted("undo")
        assert(reverted.updateSnapshot("", cwd: "/project"))
        let removal = "diff --git a/undone.swift b/undone.swift\n--- a/undone.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-line\n"
        _ = reverted.recordItem([["path": "undone.swift", "kind": ["type": "delete"], "diff": removal]], cwd: "/project", itemId: "undo")
        assert(reverted.files.isEmpty, "Older item completion resurrected a reverted file after an empty aggregate")
        reverted.itemStarted("old-rename")
        assert(reverted.updateSnapshot(unified("remaining.swift", 1), cwd: "/project"))
        _ = reverted.recordItem([["path": "undone.swift", "kind": ["type": "update", "move_path": "renamed.swift"], "diff": unified("undone.swift", 1)]], cwd: "/project", itemId: "old-rename")
        assert(reverted.files.map(\.path) == ["/project/remaining.swift"] && reverted.moveSources.isEmpty,
               "Older rename changed an authoritative snapshot or its path mapping")
        assert(sequential.updateSnapshot(unified("same.swift", 1), cwd: "/project"))
        assert(sequential.files[0].added == 1 && sequential.files[0].hunks.count == 1, "Correction retained provisional chunks")
        let quotedBefore = #""a/\346\270\254\350\251\246.swift""#
        let quotedAfter = #""b/\346\270\254\350\251\246.swift""#
        assert(sequential.updateSnapshot("diff --git \(quotedBefore) \(quotedAfter)\n--- \(quotedBefore)\n+++ \(quotedAfter)\n@@ -1 +1 @@\n-old\n+new\n", cwd: "/project"))
        assert(sequential.files.count == 1 && sequential.files[0].path == "/project/測試.swift" && sequential.files[0].added == 1)
        let spacePath = "a b/name.swift"
        let spaced = "diff --git a/\(spacePath) b/\(spacePath)\n--- a/\(spacePath)\n+++ b/\(spacePath)\n@@ -1 +1 @@\n-old\n+new\n"
        var spacedFiles = CodexTurnDiffState()
        assert(spacedFiles.updateSnapshot(spaced, cwd: "/project"))
        assert(spacedFiles.files.count == 1 && spacedFiles.files[0].path == "/project/a b/name.swift" && spacedFiles.files[0].added == 1,
               "Metadata fallback invented a file from a spaced git header")
        let emptySpaced = "diff --git a/\(spacePath) b/\(spacePath)\nnew file mode 100644\n"
        assert(spacedFiles.updateSnapshot(emptySpaced, cwd: "/project"))
        assert(spacedFiles.files.count == 1 && spacedFiles.files[0].path == "/project/a b/name.swift" && spacedFiles.files[0].isNewFile,
               "Empty spaced filename was split at its own b/ segment")
        assert(spacedFiles.updateSnapshot("diff --git a/\(spacePath) b/\(spacePath)\nold mode 100644\nnew mode 100755\n", cwd: "/project"))
        assert(spacedFiles.files.count == 1 && spacedFiles.files[0].path == "/project/a b/name.swift")
        let ambiguous = "diff --git a/a b/old.swift b/c b/new.swift\nold mode 100644\nnew mode 100755\n"
        assert(!spacedFiles.updateSnapshot(ambiguous, cwd: "/project"), "Ambiguous git header invented a path")
        assert(spacedFiles.updateSnapshot(ambiguous + "--- a/a b/old.swift\n+++ b/c b/new.swift\n", cwd: "/project"))
        assert(spacedFiles.files.count == 1 && spacedFiles.files[0].path == "/project/c b/new.swift")
        assert(!sequential.updateSnapshot("malformed update", cwd: "/project"))
        assert(sequential.files[0].path == "/project/測試.swift")
        // Raw item batches and cumulative state remain bounded in a long turn.
        var bounded = CodexTurnDiffState()
        for n in 0..<80 { _ = bounded.recordItem([change("file\(n)", 1)], cwd: "/project") }
        assert(bounded.files.count == 50)
        var plan = CodexTurnPlan(threadId: "thread", turnId: "turn")
        plan.update(["plan": [["step": "Inspect", "status": "pending"]]])
        plan.update(["plan": [["step": "Inspect", "status": "completed"], ["step": "Verify", "status": "inProgress"]], "explanation": "Corrected plan"])
        assert(plan.steps.count == 2 && plan.steps[0].status == .completed && plan.explanation == "Corrected plan")
        let known = plan
        plan.update(["plan": Array(repeating: ["step": "Too many", "status": "pending"], count: 33)])
        assert(plan == known)
        plan.update(["plan": [["step": String(repeating: "x", count: 2000), "status": "pending"]]])
        assert(plan.steps[0].text.count == 500)
        print("PASS actual Mac/recap snapshot reconciliation, stable IDs, corrected/repeated/mixed snapshots, empty/moved/deleted files, owner guards and bounded plans")
    }
}
SWIFT
swiftc -swift-version 6 -parse-as-library NotchBuddy/Sources/CoucouKit/DiffEngine.swift \
    NotchBuddy/Sources/App/CodexTurnState.swift "$task_tmp/TurnStateCheck.swift" -o "$task_tmp/check"
"$task_tmp/check"
