#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Compile real hook identity and usage logic; RPC and the local sessions root are fixtures.
# No native thread is resumed, credentials read, or user rollout files opened.
python3 - "$task_tmp/Check.swift" <<'PY'
from pathlib import Path
import sys

info = Path('NotchBuddy/Sources/App/CodexAgentsInfo.swift').read_text()
info = info.replace('FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")', 'fixtureSessionsRoot')
hook = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
hook = hook[hook.index('    @MainActor\n    private func sessionDisplay('):hook.index('    /// Uses the registry', hook.index('    private func sessionDisplay('))]
hook = hook.replace('private func sessionDisplay', 'func sessionDisplay')
Path(sys.argv[1]).write_text('''import Foundation
import Combine
let fixtureSessionsRoot = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("sessions")
struct PlanWindow { var usedPct: Double; var resetsAt: Date }
struct CodexPlanUsage { var fiveHour: PlanWindow?; var sevenDay: PlanWindow?; var updatedAt = Date() }
enum CodexPlanGauge { static func parse(result: [String: Any]) -> CodexPlanUsage? { nil } }
enum SessionTarget { static func bundleId(payload: [String: Any]) -> String? { payload["bundle_id"] as? String } }
struct PillSessionRegistry {
    struct Display {
        var session: String; var projectName: String; var cwd: String
        var hostApp: String?; var bundleId: String; var hookSessionId: String?
        var codexThreadId: String?; var codexTurnId: String?; var codexRolloutPath: String?
        var sessionTerminalId: String?; var codexManaged: Bool
    }
}
final class HookServer {
    static let codexRequiredHookEvents = ["SessionStart", "Stop"]
''' + hook + '''}
@MainActor final class CodexChatService {
    static let shared = CodexChatService()
    var owned = Set<String>(); var turnId: String? = "native-turn"
    func owns(threadId: String) -> Bool { owned.contains(threadId) }
}
enum FixtureError: Error { case unsupported }
@MainActor final class CodexConnection {
    static let shared = CodexConnection()
    var cliVersion: String? = "fixture"
    var observers: [(String, [String: Any], Any?) -> Void] = []
    var requests: [(String, String?)] = []
    var threads: [String: [String: Any]] = [:]
    var usages: [String: [String: Any]] = [:]
    var supportsUsage = true
    var holdThread: String?; var holdUsageThread: String?; var held = false; var waiting: CheckedContinuation<Void, Never>?
    func observe(_ handler: @escaping (String, [String: Any], Any?) -> Void) -> UUID { observers.append(handler); return UUID() }
    func retainConnection() -> UUID { UUID() }
    func releaseConnection(_ lease: UUID) {}
    func emit(_ method: String, params: [String: Any]) { for callback in observers { callback(method, params, nil) } }
    func release() { holdThread = nil; holdUsageThread = nil; let pending = waiting; waiting = nil; pending?.resume() }
    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let thread = params["threadId"] as? String
        requests.append((method, thread))
        switch method {
        case "hooks/list": return ["data": []]
        case "account/rateLimits/read": return ["rateLimits": ["primary": ["usedPercent": 20]]]
        case "thread/read":
            assert(params["includeTurns"] as? Bool == false, "Usage inspection requested full conversation contents")
            let result = threads[thread ?? ""] ?? [:]
            if holdThread == thread {
                held = true
                await withCheckedContinuation { waiting = $0 }
            }
            return ["thread": result]
        case "account/usage/read":
            guard supportsUsage else { throw FixtureError.unsupported }
            let result = thread.flatMap { usages[$0] } ?? ["summary": ["lifetimeTokens": 99]]
            if let thread, holdUsageThread == thread {
                held = true
                await withCheckedContinuation { waiting = $0 }
            }
            return result
        default: preconditionFailure("Read-only usage crossed into native control: " + method)
        }
    }
}
''' + info + '''
@main enum Check {
    @MainActor static func main() async throws {
        let project = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("project")
        let other = project.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixtureSessionsRoot, withIntermediateDirectories: true)
        let server = HookServer()
        let external = server.sessionDisplay(payload: ["coucou_agent": "codex", "thread_id": "child", "rollout_path": "/fake.jsonl", "turn_id": "fake"],
            session: "hook-root", projectName: "Project", cwd: project.path, hostApp: nil)
        assert(external.session == "hook-root" && external.hookSessionId == "hook-root" && external.codexThreadId == "child")
        assert(!external.codexManaged && external.codexRolloutPath == nil && external.codexTurnId == nil, "External hook gained native ownership")
        let rootOnly = server.sessionDisplay(payload: ["coucou_agent": "codex"], session: "root-only", projectName: "Project", cwd: project.path, hostApp: nil)
        assert(rootOnly.codexThreadId == nil, "Hook root was guessed to be the current child thread")
        let nonCodex = server.sessionDisplay(payload: ["coucou_agent": "gemini", "thread_id": "not-codex"], session: "other", projectName: "Project", cwd: project.path, hostApp: nil)
        assert(nonCodex.codexThreadId == nil)
        let native = server.sessionDisplay(payload: ["coucou_managed": true, "thread_id": "native", "rollout_path": "/native.jsonl"],
            session: "native-root", projectName: "Project", cwd: project.path, hostApp: nil)
        assert(native.session == "native" && native.codexManaged && native.codexRolloutPath == "/native.jsonl")
        let connection = CodexConnection(), info = CodexAgentsInfo(connection: connection)
        func usage(_ id: String, _ count: Int) -> [String: Any] {
            ["threadUsage": ["threadId": id, "groups": [["inputTokens": count, "outputTokens": 2, "totalTokens": count + 2]]]]
        }
        connection.threads["child"] = ["id": "child", "cwd": project.path]
        connection.usages["child"] = usage("child", 10)
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens?.input == 10 && info.threadId == "child" && info.threadCwd == project.path, "Confirmed external usage was lost without a local path")
        assert(connection.requests.contains { $0.0 == "thread/read" && $0.1 == "child" })
        connection.threads["child"] = ["id": "different", "cwd": project.path]
        connection.requests = []
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens == nil && !connection.requests.contains { $0.0 == "account/usage/read" && $0.1 != nil }, "Wrong thread metadata was accepted")
        connection.threads["child"] = ["id": "child", "cwd": other.path]
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens == nil, "Thread belonging to a different project was accepted")
        connection.threads["child"] = ["id": "child", "cwd": project.path]
        connection.usages["child"] = usage("root", 500)
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens == nil, "Account usage for the hook root was accepted as child usage")
        connection.usages["child"] = usage("child", 10)
        await info.refresh(threadId: "child")
        assert(info.threadTokens == nil, "External thread without a project was trusted")
        connection.supportsUsage = false
        let exact = fixtureSessionsRoot.appendingPathComponent("child.jsonl")
        func writeRollout(_ id: String, _ cwd: String) throws {
            let records: [[String: Any]] = [
                ["type": "session_meta", "payload": ["id": id, "cwd": cwd]],
                ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 21, "output_tokens": 3, "total_tokens": 24]]]]]
            var data = Data()
            for record in records { data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10) }
            try data.write(to: exact)
        }
        try writeRollout("child", project.path)
        connection.threads["child"] = ["id": "child", "cwd": project.path, "path": exact.path]
        await info.refresh(threadId: "child", rolloutPath: "/untrusted-hook.jsonl", cwd: project.path)
        assert(info.threadTokens?.total == 24, "Verified exact rollout fallback failed when account usage was unsupported")
        try writeRollout("wrong", project.path)
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens == nil, "Rollout for another child was accepted")
        try writeRollout("child", other.path)
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens == nil, "Rollout project mismatch was accepted")
        try writeRollout("child", "relative")
        let invalidProjectRollout = try CodexAgentsInfo.readRollout(path: exact.path, threadId: "child", cwd: "relative")
        assert(invalidProjectRollout == nil, "Two invalid rollout projects were accepted as matching")
        try writeRollout("child", project.path)
        let outside = project.appendingPathComponent("outside.jsonl")
        try FileManager.default.copyItem(at: exact, to: outside)
        connection.threads["child"] = ["id": "child", "cwd": project.path, "path": outside.path]
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens == nil, "External path escaped the native sessions root")
        let symlink = fixtureSessionsRoot.appendingPathComponent("outside-symlink.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        connection.threads["child"] = ["id": "child", "cwd": project.path, "path": symlink.path]
        await info.refresh(threadId: "child", cwd: project.path)
        assert(info.threadTokens == nil, "Symlink escaped the native sessions root")
        connection.supportsUsage = true
        connection.threads["child"] = ["id": "child", "cwd": project.path]
        connection.threads["new"] = ["id": "new", "cwd": other.path]
        connection.usages["new"] = usage("new", 50)
        connection.holdThread = "child"
        let late = Task { await info.refresh(threadId: "child", cwd: project.path) }
        for _ in 0..<100 where !connection.held { await Task.yield() }
        assert(connection.held)
        await info.refresh(threadId: "new", cwd: other.path)
        assert(info.threadTokens == nil && info.threadId == "new" && info.threadCwd == other.path, "Owner switch retained the old snapshot")
        connection.release()
        await late.value
        for _ in 0..<1000 where info.threadTokens == nil || info.isRefreshing { await Task.yield() }
        assert(info.threadId == "new" && info.threadCwd == other.path && info.threadTokens?.input == 50, "Late old result replaced the selected owner or latest owner never refreshed")
        CodexChatService.shared.owned.insert("native")
        connection.emit("thread/tokenUsage/updated", params: ["threadId": "native", "turnId": "native-turn", "tokenUsage": ["total": ["inputTokens": 999, "outputTokens": 1, "totalTokens": 1000]]])
        assert(info.threadId == "new" && info.threadTokens?.input == 50, "Hidden native session replaced the external owner's usage")
        connection.requests = []
        connection.usages["native"] = usage("native", 60)
        connection.threads["native"] = ["id": "native", "cwd": project.path]
        await info.refresh(threadId: "native", cwd: project.path)
        assert(info.threadTokens?.input == 60 && connection.requests.contains { $0.0 == "thread/read" }, "Owned native thread skipped project confirmation")
        connection.holdThread = "native"; connection.held = false
        let wrongProject = Task { await info.refresh(threadId: "native", cwd: other.path) }
        for _ in 0..<100 where !connection.held { await Task.yield() }
        assert(connection.held)
        connection.emit("thread/tokenUsage/updated", params: ["threadId": "native", "turnId": "native-turn", "tokenUsage": ["total": ["inputTokens": 999, "outputTokens": 1, "totalTokens": 1000]]])
        assert(info.threadTokens == nil, "Native notification bypassed pending project confirmation")
        connection.release(); await wrongProject.value
        assert(info.threadTokens == nil, "Native ownership overrode mismatched project metadata")
        connection.requests = []
        await info.refresh(threadId: "native")
        assert(info.threadTokens?.input == 60 && !connection.requests.contains { $0.0 == "thread/read" }, "Owned thread without hook project lost its existing fast path")
        connection.emit("thread/tokenUsage/updated", params: ["threadId": "native", "turnId": "native-turn", "tokenUsage": ["total": ["inputTokens": 61, "outputTokens": 1, "totalTokens": 62]]])
        assert(info.threadTokens?.input == 61, "Confirmed current-turn native usage did not update")
        CodexChatService.shared.turnId = nil
        connection.emit("thread/tokenUsage/updated", params: ["threadId": "native", "tokenUsage": ["total": ["inputTokens": 999, "outputTokens": 1, "totalTokens": 1000]]])
        assert(info.threadTokens?.input == 61, "Missing turn ID updated idle native usage")
        CodexChatService.shared.turnId = "native-turn"
        for invalidCwd in ["relative", ""] {
            await info.refresh(threadId: "native")
            assert(info.threadTokens?.input == 60)
            connection.requests = []
            await info.refresh(threadId: "native", cwd: invalidCwd)
            assert(info.threadTokens == nil && info.threadCwd == nil,
                   "Invalid project inherited the no-project native cache")
            assert(!connection.requests.contains { $0.0 == "account/usage/read" && $0.1 == "native" },
                   "Invalid project was treated as an omitted project")
        }
        connection.requests = []
        connection.holdUsageThread = "native"; connection.held = false
        let lateNoProject = Task { await info.refresh(threadId: "native") }
        for _ in 0..<1000 where !connection.held { await Task.yield() }
        assert(connection.held, "No-project usage request was not held")
        await info.refresh(threadId: "native", cwd: "relative")
        assert(info.threadTokens == nil, "Invalid project kept an in-flight no-project snapshot")
        connection.release(); await lateNoProject.value
        for _ in 0..<1000 {
            await Task.yield()
            if !info.isRefreshing && connection.requests.contains(where: { $0.0 == "thread/read" && $0.1 == "native" }) { break }
        }
        assert(info.threadTokens == nil && info.threadCwd == nil && !info.isRefreshing,
               "Late no-project response replaced the invalid project selection")
        assert(connection.requests.contains { $0.0 == "thread/read" && $0.1 == "native" },
               "Invalid project selection was lost while no-project usage was in flight")
        print("PASS explicit hook child candidate, read-only metadata, exact rollout bounds, late owner and invalid project switches, missing-turn notification rejection")
    }
}
''')
PY
swiftc -swift-version 6 -parse-as-library "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check" "$task_tmp"
