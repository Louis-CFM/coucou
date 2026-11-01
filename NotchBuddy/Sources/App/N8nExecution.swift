import Foundation

// Pure parts of N8nPoller, kept free of network access so they can be tested on
// fixtures (scripts/test-n8n-poller.sh).

/// Statuses of an n8n execution that has finished.
let n8nTerminalStatuses = ["success", "error", "crashed", "canceled", "failed"]

// ISO8601DateFormatter is thread-safe; only read after creation.
nonisolated(unsafe) private let n8nISOFormatterFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

// ISO8601DateFormatter is thread-safe; only read after creation.
nonisolated(unsafe) private let n8nISOFormatterStandard: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// When an execution stopped (or started), now when n8n sent neither or an unreadable date.
func n8nExecutionDate(from json: [String: Any]) -> Date {
    let dateString = (json["stoppedAt"] as? String) ?? (json["startedAt"] as? String)
    if let dateString {
        if let date = n8nISOFormatterFractional.date(from: dateString) ?? n8nISOFormatterStandard.date(from: dateString) {
            return date
        }
    }
    return Date()
}
