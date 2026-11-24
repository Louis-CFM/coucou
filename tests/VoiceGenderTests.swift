import Foundation

// MARK: - VoiceGenderNames tests
//
// Pure test. Compiles with:
//   swiftc -o /tmp/voice-gender-tests \
//     NotchBuddy/Sources/App/Voice/VoiceGenderNames.swift \
//     tests/VoiceGenderTests.swift

@main
enum VoiceGenderTests {
    static var pass = 0
    static var fail = 0

    static func main() {
        check("Ava Premium", VoiceGenderNames.gender(name: "Ava (Premium)", identifier: "com.apple.voice.premium.en-US.Ava"), "female")
        check("Zoe Enhanced", VoiceGenderNames.gender(name: "Zoe (Enhanced)", identifier: "com.apple.voice.enhanced.en-US.Zoe"), "female")
        check("Jamie Premium", VoiceGenderNames.gender(name: "Jamie (Premium)", identifier: "com.apple.voice.premium.en-GB.Jamie"), "male")
        check("Evan", VoiceGenderNames.gender(name: "Evan", identifier: "com.apple.voice.enhanced.en-US.Evan"), "male")
        check("Amélie accent", VoiceGenderNames.gender(name: "Amélie", identifier: "com.apple.voice.compact.fr-CA.Amelie"), "female")
        check("Thomas", VoiceGenderNames.gender(name: "Thomas", identifier: "com.apple.voice.compact.fr-FR.Thomas"), "male")
        check("Siri female id", VoiceGenderNames.gender(name: "Siri Voice 2", identifier: "com.apple.ttsbundle.siri_female_en-US_compact"), "female")
        check("Siri male id", VoiceGenderNames.gender(name: "Siri Voice 1", identifier: "com.apple.ttsbundle.siri_male_en-US_compact"), "male")
        check("unknown", VoiceGenderNames.gender(name: "Zarvox", identifier: "com.apple.speech.synthesis.voice.Zarvox"), nil)

        // Portuguese
        check("Luciana", VoiceGenderNames.gender(name: "Luciana", identifier: "com.apple.voice.compact.pt-BR.Luciana"), "female")
        check("Joana", VoiceGenderNames.gender(name: "Joana", identifier: "com.apple.voice.compact.pt-PT.Joana"), "female")
        check("Inês accent", VoiceGenderNames.gender(name: "Inês", identifier: "x.pt-PT.Ines"), "female")
        check("Felipe", VoiceGenderNames.gender(name: "Felipe (Premium)", identifier: "com.apple.voice.premium.pt-BR.Felipe"), "male")
        check("Tiago", VoiceGenderNames.gender(name: "Tiago", identifier: "x.pt-PT.Tiago"), "male")

        // ElevenLabs picker
        func voice(_ id: String, _ gender: String, language: String? = nil, accent: String? = nil, age: String? = nil) -> [String: Any] {
            var l = ["gender": gender]
            if let language { l["language"] = language }
            if let accent { l["accent"] = accent }
            if let age { l["age"] = age }
            return ["voice_id": id, "name": id, "labels": l]
        }
        let account: [[String: Any]] = [
            voice("rachel", "female", language: "en"),
            voice("bia", "female", language: "pt"),
            voice("sam", "male", language: "en", age: "young"),
            voice("caio", "male", accent: "brazilian"),
            voice("deep", "male", language: "pt", age: "middle_aged"),
        ]
        check("pt prefers a Portuguese woman", ElevenVoicePicker.pick(account, gender: "female", language: "pt")?.id, "bia")
        check("pt prefers a Portuguese man (accent label)", ElevenVoicePicker.pick(account, gender: "male", language: "pt")?.id, "caio")
        check("en keeps the English woman", ElevenVoicePicker.pick(account, gender: "female", language: "en")?.id, "rachel")
        check("fr keeps the English rule", ElevenVoicePicker.pick(account, gender: "male", language: "fr")?.id, "sam")
        let noPt = Array(account.filter { ($0["voice_id"] as? String) != "bia" })
        check("pt without Portuguese voice falls back to English", ElevenVoicePicker.pick(noPt, gender: "female", language: "pt")?.id, "rachel")
        check("empty account", ElevenVoicePicker.pick([], gender: "female", language: "pt")?.id, nil)

        print("\n\(pass)/\(pass + fail) passed.")
        if fail > 0 { exit(1) }
    }

    static func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want { pass += 1; print("✓  \(name)") }
        else { fail += 1; print("✗  \(name) — got \(got), want \(want)") }
    }
}
