// MARK: - VoiceWakeFilter
//
// Pure decision function: should the engine ignore a new wake phrase?
//
// Rules:
//   - If a permission approval is pending → always block (the user must act on it first).
//   - If the island is NOT expanded → never block (collapsed island → always accept a wake).
//   - If the island IS expanded → block only when showing approval, question, or the chat
//     prompt (views that require focused interaction). voiceResult is NOT a blocker — a new
//     "OK Coucou" replaces the transient result card immediately.
//
// The function is intentionally free of any AppKit / ObservableObject dependency so that it
// can be compiled and unit-tested without a full app context.

enum VoiceWakeFilter {
    /// Returns a human-readable reason string if the wake should be blocked, or nil if allowed.
    static func wakeBlocked(view: IslandView,
                             mode: IslandMode,
                             pendingApproval: Bool) -> String? {
        if pendingApproval { return "approval shown" }
        guard mode == .expanded else { return nil }
        switch view {
        case .approval: return "approval shown"
        case .question: return "question shown"
        case .prompt:   return "chat shown"
        default:        return nil
        }
    }
}
