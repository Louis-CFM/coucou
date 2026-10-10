#if !APPSTORE
import Foundation

// MARK: - TurnEndPolicy
//
// Decides silence duration before ending a command turn.
// Standalone compilable (used by test scripts via swiftc).
enum TurnEndPolicy {
    static let baseSilence:     TimeInterval = 1.2
    static let extendedSilence: TimeInterval = 2.2
    static let maxTurnTime:     TimeInterval = 15.0

    /// Returns the silence timeout given the current *normalised* partial transcript.
    /// Call with `IntentParser.normalise(rawTranscript)`.
    static func silenceDelay(for transcript: String) -> TimeInterval {
        guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
            return baseSilence
        }
        let lastWord = transcript.split(separator: " ").last.map(String.init) ?? ""
        return extendingWords.contains(lastWord) ? extendedSilence : baseSilence
    }

    /// Phrases that end the conversation window.
    /// Single source of truth — used by VoiceEngine and IslandWindowController.
    static let conversationEndPhrases: Set<String> = [
        "merci", "c est bon", "c'est bon", "that s all", "that's all", "stop",
        "laisse tomber", "annule", "annuler", "cancel", "never mind", "bye", "au revoir",
    ]

    // Words that suggest the utterance is mid-thought and should get extra silence.
    static let extendingWords: Set<String> = [
        // FR conjunctions / linkers
        "et", "puis", "ensuite", "mais", "ou",
        // EN conjunctions
        "and", "then", "but", "or",
        // FR articles / prepositions
        "de", "du", "le", "la", "les", "des", "un", "une",
        "a", "au", "aux", "sur", "dans", "avec", "pour",
        // EN articles / prepositions
        "the", "to", "on", "of", "in", "at", "with", "for",
        // FR bare action verbs (imperative without object)
        "ajoute", "enleve", "retire", "supprime", "desactive", "active",
        "mets", "met", "lance", "joue", "balance", "demarre",
        "monte", "baisse", "coupe", "arrete",
        // EN bare action verbs
        "add", "remove", "disable", "enable", "play", "start",
        "increase", "decrease", "set",
    ]
}
#endif
