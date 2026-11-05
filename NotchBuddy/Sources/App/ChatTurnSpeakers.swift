import Foundation

// Who speaks in the chat on screen. Mac app only: it reads AppState.

extension AppState {
    /// The speaker of an agent message in the chat on screen. `message` is nil for the answer that is about to
    /// arrive. Names are data (an agent's name, a provider's): the views draw them verbatim.
    func chatSpeaker(for message: ChatMessage?) -> ChatSpeaker {
        if chatProvider == .hermes {
            // The agent of the conversation, read live so a rename shows at once; the colour is its pill's.
            let agent = activeHermesAgent
            var color = ChatProvider.hermes.accentHex
            if let agent, let pill = HermesPills.taskIds(for: hermesAgents.map { $0.name })[agent.name],
               let task = tasks.first(where: { $0.id == pill }) { color = task.color }
            return ChatSpeaker(name: agent?.shownName ?? "Hermes", colorHex: color)
        }
        // The shared chat holds the answers of five providers: the one stored on the message, else the one selected.
        let provider = message?.provider ?? chatProvider
        return ChatSpeaker(name: provider.displayName, colorHex: provider.accentHex)
    }
}
