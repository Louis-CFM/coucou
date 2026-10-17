import Foundation

// MARK: - Session link (captured by a card when it appears)

/// The app a Claude Code session runs in and the link back to it. Several sessions share the
/// integration_claude pill, which keeps only one of them: a card keeps the session it belongs to.
struct SessionLink: Equatable, Sendable {
    var hostApp: String?
    var sessionURL: URL?
}
