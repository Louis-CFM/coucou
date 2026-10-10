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
    ]
    static let male: Set<String> = [
        // English
        "alex", "aaron", "arthur", "daniel", "evan", "fred", "gordon", "lee", "malcolm", "nathan",
        "oliver", "reed", "rishi", "ralph", "tom", "jamie", "junior", "rocko", "eddy", "albert",
        "bruce", "grandpa", "james", "noah",
        // French
        "thomas", "nicolas", "jacques", "henri", "felix", "antoine", "sebastien",
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
#endif
