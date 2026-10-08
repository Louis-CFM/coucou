#if !APPSTORE
import Foundation
import Combine
import CoreFoundation

enum CodexHooksStatus: String {
    case done, missing, untrusted, modified, disabled, incomplete, unknown
}
struct CodexUsageWindow: Identifiable, Equatable {
    let id: String
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    var isExpired: Bool { resetsAt.map { $0 <= Date() } ?? false }
}
struct CodexDailyTokens: Identifiable, Equatable {
    let date: String
    let tokens: Int64
    var id: String { date }
}
struct CodexTokenUsage: Equatable, Sendable {
    let input: Int64
    let output: Int64
    let total: Int64
    let cachedInput: Int64?
    let reasoningOutput: Int64?
    let source: String
}

@MainActor
final class CodexAgentsInfo: ObservableObject {
    static let shared = CodexAgentsInfo()
    @Published private(set) var hooksStatus: CodexHooksStatus = .unknown
    @Published private(set) var hookDetail = String(localized: "Refresh to check Codex hooks.")
    @Published private(set) var limits: [CodexUsageWindow] = []
    @Published private(set) var planUsage: CodexPlanUsage?
    @Published private(set) var lifetimeTokens: Int64?
    @Published private(set) var dailyTokens: [CodexDailyTokens] = []
    @Published private(set) var threadTokens: CodexTokenUsage?
    @Published private(set) var threadId: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var cliVersion: String?
    private let connection: CodexConnection
    private var accountGeneration = UUID()
    private var observer: UUID?
    var dominantPercent: Double? { limits.filter { !$0.isExpired }.map(\.usedPercent).max() }
    var isStale: Bool { isStale(at: Date()) }
    func isStale(at date: Date) -> Bool { error != nil || updatedAt.map { date.timeIntervalSince($0) > 300 } ?? true }

    init(connection: CodexConnection = .shared) {
        self.connection = connection
        observer = connection.observe { [weak self] method, params, _ in
            guard let self else { return }
            if method == "account/updated" {
                self.accountGeneration = UUID()
                self.limits = []; self.planUsage = nil; self.lifetimeTokens = nil; self.dailyTokens = []
                self.threadTokens = nil; self.threadId = nil; self.updatedAt = nil; self.error = nil
                return
            }
            if method == "account/rateLimits/updated", let snapshot = params["rateLimits"] as? [String: Any],
               snapshot["limitId"] as? String == "codex" || snapshot["limitId"] as? String == nil {
                let next = Self.parseLimits(params)
                self.planUsage = CodexPlanGauge.parse(result: params)
                if !next.isEmpty { self.limits = next; self.updatedAt = Date() }
            } else if method == "thread/tokenUsage/updated", let thread = params["threadId"] as? String,
                      CodexChatService.shared.owns(threadId: thread), params["turnId"] as? String == CodexChatService.shared.turnId,
                      let usage = params["tokenUsage"] as? [String: Any], let total = usage["total"] as? [String: Any],
                      let input = Self.integer(total["inputTokens"]), let output = Self.integer(total["outputTokens"]),
                      let count = Self.integer(total["totalTokens"]) {
                self.threadId = thread
                self.threadTokens = CodexTokenUsage(input: input, output: output, total: count,
                    cachedInput: Self.integer(total["cachedInputTokens"]), reasoningOutput: Self.integer(total["reasoningOutputTokens"]), source: String(localized: "Exact local Codex thread"))
            }
        }
    }

    func refresh(threadId requestedThreadId: String? = nil, rolloutPath: String? = nil) async {
        guard !isRefreshing else {
            if threadId != requestedThreadId { threadId = requestedThreadId; threadTokens = nil }
            return
        }
        isRefreshing = true
        error = nil
        if threadId != requestedThreadId { threadTokens = nil }
        threadId = requestedThreadId
        let lease = connection.retainConnection()
        defer { isRefreshing = false; connection.releaseConnection(lease) }
        refreshAttempt: for _ in 0..<2 {
            let generation = accountGeneration
            var failures: [String] = []
            do {
                let response = try await connection.request("hooks/list", params: ["cwds": []])
                guard accountGeneration == generation else { continue refreshAttempt }
                guard !Task.isCancelled else { return }
                cliVersion = connection.cliVersion
                let result = Self.parseHooks(response, requiredEvents: HookServer.codexRequiredHookEvents)
                hooksStatus = result.status; hookDetail = result.detail
            } catch {
                guard accountGeneration == generation else { continue refreshAttempt }
                hooksStatus = .unknown; hookDetail = error.localizedDescription
                failures.append(String(format: String(localized: "Hooks: %@"), error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            do {
                let response = try await connection.request("account/rateLimits/read")
                guard accountGeneration == generation else { continue refreshAttempt }
                guard !Task.isCancelled else { return }
                limits = Self.parseLimits(response)
                planUsage = CodexPlanGauge.parse(result: response)
                if limits.isEmpty { failures.append(String(localized: "Plan usage is unavailable for this Codex account.")) }
            } catch {
                guard accountGeneration == generation else { continue refreshAttempt }
                planUsage = nil
                failures.append(String(format: String(localized: "Plan usage: %@"), error.localizedDescription))
            }
            guard !Task.isCancelled else { return }
            do {
                let response = try await connection.request("account/usage/read")
                guard accountGeneration == generation else { continue refreshAttempt }
                guard !Task.isCancelled else { return }
                lifetimeTokens = Self.integer((response["summary"] as? [String: Any])?["lifetimeTokens"])
                dailyTokens = (response["dailyUsageBuckets"] as? [[String: Any]] ?? []).compactMap {
                    guard let date = $0["startDate"] as? String, let count = Self.integer($0["tokens"]) else { return nil }
                    return CodexDailyTokens(date: date, tokens: count)
                }.sorted { $0.date < $1.date }
                if let requestedThreadId, threadId == requestedThreadId {
                    let usage = try await connection.request("account/usage/read", params: ["threadId": requestedThreadId])
                    guard accountGeneration == generation else { continue refreshAttempt }
                    guard threadId == requestedThreadId, !Task.isCancelled else { return }
                    threadTokens = Self.parseThreadTokens(usage, threadId: requestedThreadId)
                }
            } catch {
                guard accountGeneration == generation else { continue refreshAttempt }
                failures.append(String(format: String(localized: "Tokens: %@"), error.localizedDescription))
            }
            if let requestedThreadId, threadTokens == nil, let rolloutPath, threadId == requestedThreadId {
                let snapshot = try? await Task.detached(priority: .utility) {
                    try Self.readRollout(path: rolloutPath, threadId: requestedThreadId)
                }.value
                guard accountGeneration == generation else { continue refreshAttempt }
                guard threadId == requestedThreadId, !Task.isCancelled else { return }
                threadTokens = snapshot
            }
            updatedAt = Date()
            error = failures.isEmpty ? nil : failures.joined(separator: "\n")
            return
        }
        error = String(localized: "Codex account changed while refreshing. Refresh again.")
    }

    nonisolated static func parseHooks(_ response: [String: Any], requiredEvents: [String]) -> (status: CodexHooksStatus, detail: String) {
        guard let entries = response["data"] as? [[String: Any]] else { return (.unknown, String(localized: "Update Codex to read hook trust.")) }
        if entries.contains(where: { !($0["errors"] as? [Any] ?? []).isEmpty }) {
            return (.unknown, String(localized: "Codex reported a hook configuration error. Check its hook settings."))
        }
        let hooks = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter {
            guard let command = $0["command"] as? String else { return false }
            return command.contains("nb-hook") && command.range(of: #"--agent\s+['"]?codex(?:['"]|\s|$)"#, options: .regularExpression) != nil
        }
        guard !hooks.isEmpty else { return (.missing, String(localized: "Install the Coucou hooks for Codex.")) }
        let required = Set(requiredEvents.map { $0.prefix(1).lowercased() + $0.dropFirst() })
        let relevant = hooks.filter { required.contains($0["eventName"] as? String ?? "") }
        if relevant.contains(where: { ($0["trustStatus"] as? String) == "modified" }) {
            return (.modified, String(localized: "Hooks changed. Confirm them again in Codex."))
        }
        if relevant.contains(where: { !["trusted", "managed"].contains($0["trustStatus"] as? String ?? "") }) {
            return (.untrusted, String(localized: "Confirm Coucou hooks in Codex."))
        }
        let enabled = relevant.filter { $0["enabled"] as? Bool == true }
        let present = Set(enabled.compactMap { $0["eventName"] as? String })
        if !required.isSubset(of: present) {
            let missing = required.subtracting(present).sorted().joined(separator: ", ")
            return (enabled.count < relevant.count ? .disabled : .incomplete, String(format: String(localized: "Missing or disabled events: %@"), missing))
        }
        return (.done, String(localized: "Coucou hooks are enabled and trusted by Codex."))
    }

    nonisolated static func parseLimits(_ response: [String: Any]) -> [CodexUsageWindow] {
        let buckets = response["rateLimitsByLimitId"] as? [String: Any]
        guard let snapshot = buckets?["codex"] as? [String: Any] ?? response["rateLimits"] as? [String: Any] else { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let value = snapshot[key] as? [String: Any], let percent = value["usedPercent"] as? NSNumber,
                  CFGetTypeID(percent) != CFBooleanGetTypeID(), percent.doubleValue.isFinite, percent.doubleValue >= 0 else { return nil }
            let duration = integer(value["windowDurationMins"]).flatMap { $0 > 0 && $0 <= Int.max ? Int($0) : nil }
            let reset = integer(value["resetsAt"]).map { Date(timeIntervalSince1970: Double($0)) }
            return CodexUsageWindow(id: key, usedPercent: percent.doubleValue, windowDurationMins: duration, resetsAt: reset)
        }
    }

    nonisolated static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue < Double(Int64.max),
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return number.int64Value
    }

    nonisolated static func parseThreadTokens(_ response: [String: Any], threadId: String) -> CodexTokenUsage? {
        guard let usage = response["threadUsage"] as? [String: Any], usage["threadId"] as? String == threadId,
              let groups = usage["groups"] as? [[String: Any]], !groups.isEmpty else { return nil }
        var input: Int64 = 0, output: Int64 = 0, total: Int64 = 0
        for group in groups {
            guard let i = integer(group["inputTokens"]), let o = integer(group["outputTokens"]), let t = integer(group["totalTokens"]),
                  i <= Int64.max - input, o <= Int64.max - output, t <= Int64.max - total else { return nil }
            input += i; output += o; total += t
        }
        return CodexTokenUsage(input: input, output: output, total: total, cachedInput: nil, reasoningOutput: nil, source: String(localized: "Codex account thread usage"))
    }

    /// Caller must supply a path learned from this exact native thread. Never guess the latest rollout.
    nonisolated static func readRollout(path: String, threadId: String, sessionsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")) throws -> CodexTokenUsage? {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let home = sessionsRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard url.path.hasPrefix(home), url.pathExtension == "jsonl" else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data(), count = 0, confirmed = false
        var result: CodexTokenUsage?
        while let bytes = try handle.read(upToCount: 65_536), !bytes.isEmpty {
            count += bytes.count
            guard count <= 32 * 1_048_576 else { return nil }
            buffer.append(bytes)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
                guard line.count <= 2_097_152 else { return nil }
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let payload = message["payload"] as? [String: Any] else { continue }
                if message["type"] as? String == "session_meta" {
                    guard payload["id"] as? String == threadId else { return nil }
                    confirmed = true
                }
                guard confirmed, message["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any], let usage = info["total_token_usage"] as? [String: Any],
                      let input = integer(usage["input_tokens"]), let output = integer(usage["output_tokens"]),
                      let total = integer(usage["total_tokens"]) else { continue }
                result = CodexTokenUsage(input: input, output: output, total: total,
                                        cachedInput: integer(usage["cached_input_tokens"]), reasoningOutput: integer(usage["reasoning_output_tokens"]), source: String(localized: "Exact local Codex thread"))
            }
            guard buffer.count <= 2_097_152 else { return nil }
        }
        return confirmed ? result : nil // An incomplete final JSONL line is intentionally ignored.
    }
}
#endif
