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

        // Chosen voice vs automatic pick
        check("stored voice wins", ElevenVoicePicker.resolve(stored: "deep", voices: account, gender: "female", language: "pt")?.id, "deep")
        check("empty stored id = automatic", ElevenVoicePicker.resolve(stored: "", voices: account, gender: "female", language: "pt")?.id, "bia")
        check("nil stored id = automatic", ElevenVoicePicker.resolve(stored: nil, voices: account, gender: "male", language: "pt")?.id, "caio")
        check("stored voice gone from account = automatic", ElevenVoicePicker.resolve(stored: "removed", voices: account, gender: "female", language: "pt")?.id, "bia")
        check("stored on empty account", ElevenVoicePicker.resolve(stored: "deep", voices: [], gender: "female", language: "pt")?.id, nil)
        check("stored() unknown", ElevenVoicePicker.stored("nope", in: account)?.id, nil)
        check("display name with labels", ElevenVoicePicker.displayName(voice("x", "male", language: "pt", accent: "brazilian")), "x (pt · brazilian · male)")
        check("display name without labels", ElevenVoicePicker.displayName(["voice_id": "y", "name": "Y"]), "Y")

        // Expressiveness
        check("normal sends no voice_settings", ElevenExpressiveness.normal.voiceSettings == nil, true)
        check("unknown raw = normal", ElevenExpressiveness.from("???"), .normal)
        check("nil raw = normal", ElevenExpressiveness.from(nil), .normal)
        check("lively raw", ElevenExpressiveness.from("lively"), .lively)
        let calm = ElevenExpressiveness.calm.voiceSettings, lively = ElevenExpressiveness.lively.voiceSettings
        check("calm steadier than lively", (calm?["stability"] as? Double ?? 0) > (lively?["stability"] as? Double ?? 1), true)
        check("lively has more style", (lively?["style"] as? Double ?? 0) > (calm?["style"] as? Double ?? 1), true)
        check("speaker boost on", (calm?["use_speaker_boost"] as? Bool, lively?["use_speaker_boost"] as? Bool) == (true, true), true)
        for e in [ElevenExpressiveness.calm, .lively] {
            let ok = ["stability", "similarity_boost", "style"].allSatisfy { k in (e.voiceSettings?[k] as? Double).map { (0...1).contains($0) } ?? false }
            check("\(e) values in 0...1", ok, true)
        }

        print("\n\(pass)/\(pass + fail) passed.")
        if fail > 0 { exit(1) }
    }

    static func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
        if got == want { pass += 1; print("✓  \(name)") }
        else { fail += 1; print("✗  \(name) — got \(got), want \(want)") }
    }
}
