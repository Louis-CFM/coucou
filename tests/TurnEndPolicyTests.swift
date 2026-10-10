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
        precondition(TurnEndPolicy.baseSilence == 1.2,    "baseSilence == 1.2")
        precondition(TurnEndPolicy.extendedSilence == 2.2, "extendedSilence == 2.2")
        precondition(TurnEndPolicy.maxTurnTime == 15.0,    "maxTurnTime == 15.0")

        print("TurnEndPolicyTests: all cases passed")
    }
}
