import Foundation

/// Pure decision for a finished Hermes chat turn: does the user need to be told, and how.
enum HermesAnnounce {
    enum Outcome: Equatable {
        /// The chat of the agent is on screen: nothing to announce.
        case none
        /// Sound and pill badge only: an approval or question card must keep the screen.
        case badgeOnly
        /// Sound, badge, and the island comes back to the chat (or to the error note).
        case expand
    }

    /// - expanded: the island is expanded.
    /// - viewIsChat: the current view is the prompt (chat) view.
    /// - cmuxPromptOpen: the cmux reply / new chat prompt occupies the prompt slot.
    /// - alertPending: an approval or question card is on screen, or cmux cards are queued.
    ///
    /// A cmux reply being typed counts like a card: the Hermes chat never replaces it, the badge brings the chat back.
    ///
    /// - chatIsOfThisAgent: the chat on screen (if any) is the conversation of the agent whose turn ended. When it is
    ///   another conversation, the user is chatting elsewhere: sound and badge, but that chat keeps the screen.
    static func decide(expanded: Bool, viewIsChat: Bool, cmuxPromptOpen: Bool, alertPending: Bool,
                       chatIsOfThisAgent: Bool = true) -> Outcome {
        if chatIsShown(expanded: expanded, viewIsChat: viewIsChat, cmuxPromptOpen: cmuxPromptOpen) {
            return chatIsOfThisAgent ? .none : .badgeOnly
        }
        return (alertPending || cmuxPromptOpen) ? .badgeOnly : .expand
    }

    /// The Hermes chat itself is on screen. `cmuxPromptOpen` must also be true while the cmux prompt is being
    /// opened (the view changes before the prompt mode is set): that prompt is not the chat.
    static func chatIsShown(expanded: Bool, viewIsChat: Bool, cmuxPromptOpen: Bool) -> Bool {
        expanded && viewIsChat && !cmuxPromptOpen
    }

    /// What the bot override of the chat should be. The typing dots (`thinking`) show while a turn waits for its
    /// first text; a `thinking` or `error` left by a turn that ended is dropped once no turn waits any more.
    /// Any other override (drag, dizzy...) is never touched.
    enum Override: Equatable { case none, thinking, error, other }

    static func typingOverride(current: Override, anyTurnWaiting: Bool) -> Override {
        if anyTurnWaiting { return current == .none ? .thinking : current }
        return (current == .thinking || current == .error) ? .none : current
    }
}
