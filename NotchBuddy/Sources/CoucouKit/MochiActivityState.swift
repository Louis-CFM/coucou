import Foundation

// What the iPhone's Live Activity (Lock Screen and Dynamic Island) shows:
// the most urgent agent session, while the Mac is locked. The Mac builds it,
// the relay forwards it as the Live Activity's "content-state", ActivityKit
// decodes it on the iPhone. It passes through the relay and Apple's push
// service, so it holds no project name, step text, command or path: only the
// agent, its state and counts.

struct MochiActivityState: Codable, Hashable, Sendable {
    var pillId: String
    var agent: String       // "VS Code", "Codex"…
    var color: String       // agent color, hex
    var state: String       // BotState raw value
    var statusText: String  // "working · 3/7", "waiting for your OK"…
    var tone: String        // waiting, question, error, working, done, idle
    var stepIndex: Int
    var stepCount: Int
    var others: Int         // other sessions still going

    var botState: BotState { BotState(rawValue: state) ?? .idle }
    var isActive: Bool { ["waiting", "question", "working", "error"].contains(tone) }

    /// Lower = more urgent, same order as the iPhone list.
    static func urgency(state: BotState, waitingForOK: Bool, hasQuestion: Bool) -> Int {
        if waitingForOK || state == .approval { return 0 }
        if hasQuestion || state == .question { return 1 }
        switch state {
        case .error, .ratelimit, .dizzy: return 2
        case .working, .thinking, .searching: return 3
        case .finished: return 4
        default: return 5
        }
    }

    static func tone(urgency: Int) -> String {
        ["waiting", "question", "error", "working", "done"].indices.contains(urgency)
            ? ["waiting", "question", "error", "working", "done"][urgency] : "idle"
    }

    static func statusText(state: BotState, urgency: Int, stepIndex: Int, stepCount: Int) -> String {
        switch urgency {
        case 0: return "waiting for your OK"
        case 1: return "has a question"
        default: break
        }
        switch state {
        case .working, .thinking, .searching:
            return stepCount == 0 ? "working" : "working · \(min(stepIndex + 1, stepCount))/\(stepCount)"
        case .finished: return "✓ done"
        case .error: return "error"
        case .ratelimit: return "rate limited"
        case .sleeping: return "asleep"
        case .dizzy: return "dizzy"
        default: return "idle"
        }
    }

    static let placeholder = MochiActivityState(
        pillId: "integration_claude", agent: "VS Code", color: "#4A86E8",
        state: "working", statusText: "working · 3/7", tone: "working",
        stepIndex: 2, stepCount: 7, others: 1)
}
