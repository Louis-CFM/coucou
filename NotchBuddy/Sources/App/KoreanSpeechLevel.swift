#if !APPSTORE
import Foundation

/// The politeness of Korean text, when Claude rewrites it (clean-up, prompt mode, translation).
enum KoreanSpeechLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Left as spoken.
    case keep
    /// 해요체: polite and soft, the everyday register.
    case haeyo
    /// 합니다체: formal, for work mails and reports.
    case hamnida
    /// 해체: casual, no honorific.
    case banmal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .keep:   return String(localized: "flow.korean-level.keep")
        case .haeyo:  return String(localized: "flow.korean-level.haeyo")
        case .hamnida: return String(localized: "flow.korean-level.hamnida")
        case .banmal: return String(localized: "flow.korean-level.banmal")
        }
    }

    /// The instruction added to Claude's prompt; nil when the words are left as spoken.
    var rule: String? {
        let level: String
        switch self {
        case .keep:    return nil
        case .haeyo:   level = "해요체 (polite and soft, sentences end in -요). Example: 너 뭐 좋아해? → 어떤 걸 좋아하세요?"
        case .hamnida: level = "합니다체 (formal, sentences end in -습니다 or -ㅂ니다, questions in -ㅂ니까). Example: 너 뭐 좋아해? → 어떤 것을 좋아하십니까?"
        case .banmal:  level = "해체 (casual, no honorific, sentences end like -어 or -아). Example: 어떤 걸 좋아하세요? → 너 뭐 좋아해?"
        }
        return "When the result is in Korean, write every sentence in \(level). "
            + "Rewrite each sentence the way a native speaker would say it at that level, not by only changing the verb ending: "
            + "also adjust the words that go with it: drop or replace 너 and 니가 when the level is polite or formal, use the honorific -시- for what the listener does, and prefer the fuller words over the clipped spoken ones (뭐 → 어떤 걸 or 무엇을, 걔 → 그 사람); in the casual level use 너 and the short spoken forms, and no honorific. "
            + "Do not change the meaning or anything else, and leave text in other languages as it is."
    }
}
#endif
