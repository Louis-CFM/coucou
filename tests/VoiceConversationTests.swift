import Foundation

@main
enum VoiceConversationTests {

    static func main() {
        let phrases = TurnEndPolicy.conversationEndPhrases

        // ── Members ───────────────────────────────────────────────────────────
        precondition(phrases.contains("stop"),          "stop must end conversation")
        precondition(phrases.contains("merci"),         "merci must end conversation")
        precondition(phrases.contains("annule"),        "annule must end conversation")
        precondition(phrases.contains("annuler"),       "annuler must end conversation")
        precondition(phrases.contains("cancel"),        "cancel must end conversation")
        precondition(phrases.contains("never mind"),    "never mind must end conversation")
        precondition(phrases.contains("bye"),           "bye must end conversation")
        precondition(phrases.contains("au revoir"),     "au revoir must end conversation")
        precondition(phrases.contains("c est bon"),     "c est bon must end conversation")
        precondition(phrases.contains("c'est bon"),     "c'est bon must end conversation")
        precondition(phrases.contains("that s all"),    "that s all must end conversation")
        precondition(phrases.contains("that's all"),    "that's all must end conversation")
        precondition(phrases.contains("laisse tomber"), "laisse tomber must end conversation")
        precondition(phrases.contains("obrigado"),      "obrigado must end conversation")
        precondition(phrases.contains("valeu"),         "valeu must end conversation")
        precondition(phrases.contains("tchau"),         "tchau must end conversation")

        // ── Non-members ───────────────────────────────────────────────────────
        precondition(!phrases.contains("xyz"),              "xyz must NOT end conversation")
        precondition(!phrases.contains("ajoute"),           "ajoute must NOT end conversation")
        precondition(!phrases.contains("merci beaucoup"),   "merci beaucoup must NOT end conversation")

        // ── Partial transcripts: sentence openings must not end the conversation (M4) ──
        // VoiceEngine.commandUpdate tests every partial against this set.
        for opening in ["pode parar", "e isso", "é isso"] {
            precondition(!phrases.contains(opening), "\(opening) must NOT end conversation")
        }
        precondition(phrases.contains("so isso") && phrases.contains("só isso"), "só isso must end conversation")
        precondition(phrases.contains("stop") && phrases.contains("merci"), "en/fr end phrases unchanged")

        // ── Non-empty ─────────────────────────────────────────────────────────
        precondition(!phrases.isEmpty, "conversationEndPhrases must not be empty")

        print("All voice conversation end-phrase tests passed.")
    }
}
