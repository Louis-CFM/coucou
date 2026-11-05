#if !APPSTORE
import Foundation

// MARK: - VoiceGenderNames
//
// macOS often reports no gender for Premium and Siri voices, so "female" in Settings
// could still give Jamie. The identifier ("…siri_female_en-US…") or the voice's first
// name tells it instead. Pure Foundation: compiled by scripts/test-voice-gender.sh.
enum VoiceGenderNames {
    static let female: Set<String> = [
        // English
        "ava", "allison", "samantha", "susan", "victoria", "zoe", "karen", "kate", "moira", "serena",
        "tessa", "fiona", "veena", "isha", "catherine", "nicky", "joelle", "noelle", "kathy", "vicki",
        "agnes", "shelley", "sandy", "flo", "grandma", "martha", "stephanie", "siobhan", "matilda",
        "lee-ann", "princess", "kyoko", "sara", "helena",
        // French
        "amelie", "audrey", "aurelie", "marie", "virginie", "chantal", "juliette", "julie", "celine",
        "charlotte", "louise",
        // Portuguese
        "luciana", "fernanda", "joana", "catarina", "francisca", "ines",
    ]
    static let male: Set<String> = [
        // English
        "alex", "aaron", "arthur", "daniel", "evan", "fred", "gordon", "lee", "malcolm", "nathan",
        "oliver", "reed", "rishi", "ralph", "tom", "jamie", "junior", "rocko", "eddy", "albert",
        "bruce", "grandpa", "james", "noah",
        // French
        "thomas", "nicolas", "jacques", "henri", "felix", "antoine", "sebastien",
        // Portuguese
        "felipe", "joaquim", "rafael", "tiago",
    ]

    /// "female", "male", or nil when nothing tells.
    static func gender(name: String, identifier: String) -> String? {
        let id = identifier.lowercased()
        if id.contains("female") { return "female" }
        if id.contains("_male") || id.contains(".male") || id.contains("-male") { return "male" }
        let first = name.split(whereSeparator: { $0 == " " || $0 == "(" }).first.map(String.init) ?? name
        let key = first.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        if female.contains(key) { return "female" }
        if male.contains(key) { return "male" }
        return nil
    }
}

// MARK: - ElevenVoicePicker
//
// Which ElevenLabs voice of the user's account Coucou uses. Pure (no network, no Keychain)
// so scripts/test-voice-gender.sh covers it; ElevenLabsTTS.pick delegates here.
enum ElevenVoicePicker {
    /// Portuguese answers prefer voices labelled Portuguese; any other language keeps the
    /// English rule.
    static func pick(_ voices: [[String: Any]], gender: String, language: String) -> (id: String, name: String)? {
        func labels(_ v: [String: Any]) -> [String: String] { v["labels"] as? [String: String] ?? [:] }
        func isEnglish(_ v: [String: Any]) -> Bool {
            let l = labels(v)
            if let lang = l["language"] { return lang.lowercased().hasPrefix("en") }
            let accent = (l["accent"] ?? "").lowercased()
            return accent.isEmpty || ["american", "british", "australian", "irish", "english", "us", "uk"]
                .contains { accent.contains($0) }
        }
        func isPortuguese(_ v: [String: Any]) -> Bool {
            let l = labels(v)
            if let lang = l["language"]?.lowercased(), lang.hasPrefix("pt") || lang.contains("portuguese") { return true }
            let accent = (l["accent"] ?? "").lowercased()
            return accent.contains("brazilian") || accent.contains("portuguese")
        }
        func isYoung(_ v: [String: Any]) -> Bool { (labels(v)["age"] ?? "").lowercased().contains("young") }
        let ofGender = voices.filter { labels($0)["gender"]?.lowercased() == gender }
        let preferred = language == "pt" ? ofGender.filter(isPortuguese) : []
        let english = ofGender.filter(isEnglish)
        // Male: a young voice first, it sounds closer to Coucou than a deep narrator.
        let pool = preferred.isEmpty ? english : preferred
        let young = gender == "male" ? pool.first(where: isYoung) : nil
        let v = young ?? pool.first ?? ofGender.first ?? voices.first
        guard let v, let id = v["voice_id"] as? String else { return nil }
        return (id, v["name"] as? String ?? id)
    }

    /// The voice saved in Settings if the account still has it; nil means "Automatic"
    /// (empty/unknown id, or a voice removed from the account).
    static func stored(_ id: String?, in voices: [[String: Any]]) -> (id: String, name: String)? {
        guard let id, !id.isEmpty,
              let v = voices.first(where: { ($0["voice_id"] as? String) == id }) else { return nil }
        return (id, v["name"] as? String ?? id)
    }

    /// The chosen voice when it exists in the account, else the automatic pick.
    static func resolve(stored id: String?, voices: [[String: Any]], gender: String, language: String) -> (id: String, name: String)? {
        stored(id, in: voices) ?? pick(voices, gender: gender, language: language)
    }

    /// Short secondary text for the Settings picker: "Nando – calm and Friendly (pt · brazilian · male)".
    static func displayName(_ v: [String: Any]) -> String {
        let name = v["name"] as? String ?? (v["voice_id"] as? String ?? "")
        let l = v["labels"] as? [String: String] ?? [:]
        let tags = ["language", "accent", "gender"].compactMap { l[$0] }.filter { !$0.isEmpty }
        return tags.isEmpty ? name : "\(name) (\(tags.joined(separator: " · ")))"
    }
}

// MARK: - ElevenExpressiveness
//
// How lively the ElevenLabs voice sounds (Settings → Voice). Normal sends no
// voice_settings, so the voice sounds exactly as before. Calm and Lively send them:
// stability 0–1 (high = steady and flat, low = more varied), style 0–1 (exaggeration;
// some models ignore it), similarity_boost 0–1, use_speaker_boost bool.
enum ElevenExpressiveness: String, CaseIterable {
    case calm, normal, lively

    static func from(_ raw: String?) -> ElevenExpressiveness { raw.flatMap(Self.init(rawValue:)) ?? .normal }

    /// Body "voice_settings" for the TTS request; nil = send nothing (the voice's own settings).
    var voiceSettings: [String: Any]? {
        switch self {
        case .normal: return nil
        case .calm:   return ["stability": 0.8, "similarity_boost": 0.75, "style": 0.0, "use_speaker_boost": true]
        case .lively: return ["stability": 0.3, "similarity_boost": 0.75, "style": 0.5, "use_speaker_boost": true]
        }
    }
}
#endif
