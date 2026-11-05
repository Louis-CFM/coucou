import Foundation

/// What demo mode may do next to real sessions. Pure decisions; `DemoEngine` feeds them the live state.
/// In both builds, no flag.
enum DemoGuard {
    /// Real things waiting for the user. The demo never covers them and never touches the view while one waits.
    struct Pending: Equatable {
        var approval = false      // a real approval holds its connection open
        var question = false      // a real question holds its connection open
        var cmuxQueued = false    // cmux cards wait for the card slot

        var any: Bool { approval || question || cmuxQueued }
    }

    /// The demo shows its own approval or question, or moves the island to another view, only while nothing real waits.
    /// Asked again right before each write: the state can change between a check and the write that follows an await.
    static func mayShowOwnCard(_ pending: Pending) -> Bool { !pending.any }
    static func mayChangeView(_ pending: Pending) -> Bool { !pending.any }

    /// The demo chat lives in the shared conversation only, whatever the conversation on screen is. With a Hermes
    /// agent selected the shared conversation is not the one on screen: the chat step has nothing to show, so it is
    /// skipped and no conversation is written.
    static func showsChatStep(providerIsHermes: Bool) -> Bool { !providerIsHermes }

    /// While the demo runs, a message for a Hermes agent is neither answered by the demo nor sent for real. The caller
    /// refuses it before anything is consumed: the text stays in the field, no bubble, no state change.
    static func mayChatSend(demoActive: Bool, targetIsHermesAgent: Bool) -> Bool { !(demoActive && targetIsHermesAgent) }
}
