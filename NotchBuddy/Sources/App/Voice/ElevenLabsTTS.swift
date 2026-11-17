#if !APPSTORE
import Foundation

// MARK: - ElevenLabsTTS
//
// Optional voice for Coucou's answers (Settings → Voice → ElevenLabs), with the user's
// own API key stored in the Keychain ("elevenlabs-api-key"). Network only to
// api.elevenlabs.io, only while Coucou speaks.
//
// No voice ID is hard-coded: ElevenLabs' old default voices expire on 31 Dec 2026 and
// newer accounts don't have them. Coucou lists the voices of the user's account and
// picks the first English one of the chosen gender (female by default), then caches it.
// When Coucou answers in Portuguese, a voice labelled Portuguese comes first.

@MainActor
final class ElevenLabsTTS {
    static let shared = ElevenLabsTTS()

    static let keyName = "elevenlabs-api-key"
    private static let model = "eleven_flash_v2_5"   // low-latency model

    static var isActive: Bool {
        VoiceSettings.ttsEngine == "elevenlabs" && KeychainStore.shared.get(keyName) != nil
    }

    struct Voice: Equatable { let id: String; let name: String }
    private var chosen: (gender: String, language: String, voice: Voice)?

    /// Name of the voice in use, for Settings ("Rachel", "Talia – Warm Soft Guide"…).
    var currentVoiceName: String? { chosen?.voice.name }

    /// Forget the cached voice (gender or key changed).
    func reset() { chosen = nil }

    /// MP3 for one sentence, or nil (no key, network error, quota…) → Mac voice instead.
    func audio(for text: String) async -> Data? {
        guard let key = KeychainStore.shared.get(Self.keyName),
              let voice = await voice(key: key) else { return nil }
        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice.id)")!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "mp3_44100_128")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["text": text, "model_id": Self.model]
        if VoiceSettings.lang == .pt { body["language_code"] = "pt" }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            appendAppLog("nb.log", "[Voice] ElevenLabs request failed, Mac voice used")
            return nil
        }
        return data
    }

    /// The voice for the chosen gender, looked up once in the user's account.
    func voice(key: String) async -> Voice? {
        let gender = VoiceSettings.elevenGender
        let language = VoiceSettings.lang.rawValue
        if let c = chosen, c.gender == gender, c.language == language { return c.voice }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!, timeoutInterval: 8)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let voices = json["voices"] as? [[String: Any]] else {
            appendAppLog("nb.log", "[Voice] ElevenLabs voice list unavailable")
            return nil
        }
        guard let v = Self.pick(voices, gender: gender, language: language) else { return nil }
        chosen = (gender, language, v)
        return v
    }

    /// First English voice of the gender (a young one first for a man); else any voice of
    /// the gender; else the first one. For `language` "pt", Portuguese voices come first.
    nonisolated static func pick(_ voices: [[String: Any]], gender: String, language: String = "en") -> Voice? {
        guard let v = ElevenVoicePicker.pick(voices, gender: gender, language: language) else { return nil }
        return Voice(id: v.id, name: v.name)
    }
}
#endif
