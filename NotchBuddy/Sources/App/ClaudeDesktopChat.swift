import Foundation

// Which button tells that Claude Desktop is still writing a reply (tests/ClaudeDesktopChatTests.swift).
// Its accessibility label is "Stop response" in English; the other languages Claude's app
// speaks are matched by their usual wording. Best effort: the app may rename it.
enum ClaudeDesktopChat {
    static let stopLabels: Set<String> = [
        "stop response", "stop generating",
        "arrêter la réponse", "arrêter la génération",
        "detener respuesta", "detener la respuesta",
        "parar resposta", "parar a resposta", "interromper resposta",
        "antwort stoppen", "antwort anhalten",
        "interrompi risposta", "interrompi la risposta",
        "hentikan respons", "hentikan tanggapan",
        "応答を停止", "回答を停止", "응답 중지", "停止响应", "停止回答", "停止回應",
    ]

    static func isStopLabel(_ labels: [String?]) -> Bool {
        labels.contains { label in
            guard let raw = label else { return false }
            let l = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l.isEmpty { return false }
            if stopLabels.contains(l) { return true }
            // "Stop the response", "Stop responding": a stop that is about the reply.
            return l.contains("stop") && l.contains("respon")
        }
    }
}
