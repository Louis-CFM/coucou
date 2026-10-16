import Foundation

/// A reminder, never an authority to approve or answer in another application.
struct MainSessionAttention: Equatable, Sendable, Identifiable {
    let source: String
    let requestId: String
    let sessionId: String
    let title: String
    let reason: String
    let kind: String
    var expiresAt: TimeInterval

    var id: String { "\(source):\(sessionId):\(requestId)" }
    var appName: String { source == "codex" ? "Codex" : "OpenCode" }
    var bundleId: String { source == "codex" ? "com.openai.codex" : "ai.opencode.desktop" }
    var chatURL: URL? { source == "codex" ? URL(string: "codex://threads/\(sessionId)") : nil }

    static func parse(_ item: [String: Any], expiresAt: TimeInterval) -> Self? {
        guard let source = item["source"] as? String, ["codex", "opencode"].contains(source),
              let session = item["session_id"] as? String,
              let request = item["id"] as? String, !request.isEmpty, request.utf8.count <= 200,
              let title = item["title"] as? String, title.count <= 160,
              let reason = item["reason"] as? String, !reason.isEmpty, reason.count <= 800,
              let kind = item["kind"] as? String, ["question", "permission"].contains(kind)
        else { return nil }
        if source == "codex" {
            guard UUID(uuidString: session) != nil else { return nil }
        } else {
            guard session.range(of: "^ses_[A-Za-z0-9]+$", options: .regularExpression) != nil,
                  request.range(of: "^per_[A-Za-z0-9]+$", options: .regularExpression) != nil,
                  kind == "permission" else { return nil }
        }
        return Self(source: source, requestId: request, sessionId: session,
                    title: title, reason: reason, kind: kind, expiresAt: expiresAt)
    }
}

/// Full snapshots are reconciled atomically. Refreshing a lease never reopens a dismissed card.
struct MainSessionAttentionQueue {
    private(set) var entries: [MainSessionAttention] = []
    private var seen: [String: TimeInterval] = [:]
    private var dismissed: Set<String> = []
    var visible: [MainSessionAttention] { entries.filter { !dismissed.contains($0.id) } }

    mutating func replace(payload: [String: Any], now: TimeInterval) -> Bool {
        guard payload["action"] as? String == "snapshot",
              let expires = payload["expires_at"] as? TimeInterval,
              expires.isFinite, expires > now, expires <= now + 30,
              let items = payload["requests"] as? [[String: Any]], items.count <= 100
        else { return false }
        var next: [MainSessionAttention] = []
        var keys: Set<String> = []
        var newRequest = false
        for item in items {
            guard let request = MainSessionAttention.parse(item, expiresAt: expires),
                  keys.insert(request.id).inserted else { continue }
            newRequest = newRequest || seen[request.id] == nil
            seen[request.id] = now
            next.append(request)
        }
        // Preserve FIFO order when the provider's list order changes.
        let positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        entries = next.enumerated().sorted {
            (positions[$0.element.id] ?? (100 + $0.offset)) < (positions[$1.element.id] ?? (100 + $1.offset))
        }.map(\.element)
        pruneHistory(now: now)
        return newRequest
    }

    mutating func dismiss(id: String) { dismissed.insert(id) }

    mutating func expire(now: TimeInterval) {
        entries.removeAll { $0.expiresAt <= now }
        pruneHistory(now: now)
    }

    private mutating func pruneHistory(now: TimeInterval) {
        // A brief network failure must not make the same request pop up again on recovery.
        seen = seen.filter { now - $0.value < 3600 }
        if seen.count > 1000 {
            seen = Dictionary(uniqueKeysWithValues: seen.sorted { $0.value > $1.value }.prefix(1000).map { ($0.key, $0.value) })
        }
        dismissed.formIntersection(Set(seen.keys))
    }
}

/// Thread-safe mirror of the opt-in state, read by nonisolated socket threads.
/// False until the user turns the feature on (or the isolated DEBUG smoke test
/// fakes it): with the feature off, attention snapshots are ignored and Codex
/// hook payloads keep their original lifecycle.
enum MainSessionAttentionRoute {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var enabled = false

    static func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        lock.unlock()
    }

    static var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }
}

/// Snapshot acceptance policy, kept pure so the disabled-by-default guarantee
/// is testable without the app: disabled ignores every snapshot; only the
/// feature being on — or the isolated DEBUG smoke test — accepts them.
enum MainSessionAttentionPolicy {
    static func acceptsSnapshots(featureEnabled: Bool, smokeSynthetic: Bool) -> Bool {
        #if DEBUG
        return featureEnabled || smokeSynthetic
        #else
        return featureEnabled
        #endif
    }
}
