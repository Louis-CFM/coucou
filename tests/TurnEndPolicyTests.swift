import Foundation

@main
enum TurnEndPolicyTests {
    static func main() {
        // baseSilence for empty transcript
        precondition(TurnEndPolicy.silenceDelay(for: "") == TurnEndPolicy.baseSilence,
            "empty → baseSilence")

        // baseSilence for normal word
        precondition(TurnEndPolicy.silenceDelay(for: "mets gemini") == TurnEndPolicy.baseSilence,
            "normal word → baseSilence")

        // extendedSilence for conjunction
        precondition(TurnEndPolicy.silenceDelay(for: "mets gemini et") == TurnEndPolicy.extendedSilence,
            "ends with 'et' → extendedSilence")

        // extendedSilence for article
        precondition(TurnEndPolicy.silenceDelay(for: "ajoute le") == TurnEndPolicy.extendedSilence,
            "ends with 'le' → extendedSilence")

        // extendedSilence for bare verb
        precondition(TurnEndPolicy.silenceDelay(for: "ajoute") == TurnEndPolicy.extendedSilence,
            "bare action verb → extendedSilence")

        // extendedSilence for EN conjunction
        precondition(TurnEndPolicy.silenceDelay(for: "add github and") == TurnEndPolicy.extendedSilence,
            "ends with 'and' → extendedSilence")

        // baseSilence for complete command
        precondition(TurnEndPolicy.silenceDelay(for: "ajoute github") == TurnEndPolicy.baseSilence,
            "complete command → baseSilence")

        // Constants
        precondition(TurnEndPolicy.baseSilence == 1.6,    "baseSilence == 1.6")
        precondition(TurnEndPolicy.extendedSilence == 2.6, "extendedSilence == 2.6")
        precondition(TurnEndPolicy.silenceDelay(for: "l objet c est", longAnswer: true) == TurnEndPolicy.answerSilence,
            "free-text answer → answerSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "mets euh") == TurnEndPolicy.extendedSilence,
            "ends with 'euh' → extendedSilence")
        // Portuguese: extending words and end phrases
        precondition(TurnEndPolicy.silenceDelay(for: "adiciona o github e", portuguese: true) == TurnEndPolicy.extendedSilence,
            "pt 'e' → extendedSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "troca o github pelo vercel mas", portuguese: true) == TurnEndPolicy.extendedSilence,
            "pt 'mas' → extendedSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "adiciona", portuguese: true) == TurnEndPolicy.extendedSilence,
            "pt bare verb → extendedSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "toca", portuguese: true) == TurnEndPolicy.extendedSilence,
            "pt 'toca' → extendedSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "tira a", portuguese: true) == TurnEndPolicy.extendedSilence,
            "pt article → extendedSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "manda pra", portuguese: true) == TurnEndPolicy.extendedSilence,
            "pt 'pra' → extendedSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "adiciona github", portuguese: true) == TurnEndPolicy.baseSilence,
            "pt complete command → baseSilence")
        precondition(TurnEndPolicy.silenceDelay(for: "toca musica", portuguese: true) == TurnEndPolicy.baseSilence,
            "pt complete music command → baseSilence")
        for p in ["obrigado", "obrigada", "valeu", "so isso", "só isso",
                  "cancela", "deixa pra la", "deixa pra lá", "tchau", "ate mais", "até mais"] {
            precondition(TurnEndPolicy.conversationEndPhrases.contains(p), "\(p) must end conversation")
        }
        // Regression (M1): Portuguese linkers must not stretch English/French turns
        for t in ["no", "what should i do", "as", "tell him no", "i said no", "do", "em", "na"] {
            precondition(TurnEndPolicy.silenceDelay(for: t) == TurnEndPolicy.baseSilence,
                "'\(t)' without Portuguese must stay baseSilence")
        }
        precondition(TurnEndPolicy.silenceDelay(for: "diz que nao", portuguese: true) == TurnEndPolicy.baseSilence,
            "pt 'nao' is not a linker")
        precondition(TurnEndPolicy.silenceDelay(for: "manda no", portuguese: true) == TurnEndPolicy.extendedSilence,
            "pt 'no' extends when speaking Portuguese")
        // Regression (M4): openings of normal sentences must not end the conversation
        for p in ["pode parar", "e isso", "é isso"] {
            precondition(!TurnEndPolicy.conversationEndPhrases.contains(p), "'\(p)' must NOT end conversation")
        }
        precondition(!TurnEndPolicy.conversationEndPhrases.contains("para"), "bare 'para' must NOT end conversation")
        precondition(TurnEndPolicy.maxTurnTime == 15.0,    "maxTurnTime == 15.0")

        print("TurnEndPolicyTests: all cases passed")
    }
}
