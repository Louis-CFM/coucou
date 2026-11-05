#if !APPSTORE
import AVFoundation
import Speech

// MARK: - VoiceSettings

/// Persisted voice feature settings and permission helpers.
enum VoiceSettings {
    static let enabledKey      = "voiceEnabled"
    static let speakEnabledKey = "voiceSpeakEnabled"
    static let captionEnabledKey = "voiceCaptionEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Coucou responds aloud after each command. Default: on.
    static var speakEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: speakEnabledKey) == nil { return true }   // default on
            return d.bool(forKey: speakEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: speakEnabledKey) }
    }

    /// Show caption capsule below notch during voice. Default: on.
    static var captionEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: captionEnabledKey) == nil { return true }  // default on
            return d.bool(forKey: captionEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: captionEnabledKey) }
    }

    /// Language Coucou ANSWERS in: "en", "fr" or "pt" (Brazilian Portuguese). When nothing is stored
    /// it follows the app and Mac language (pt on a Portuguese app or Mac, en otherwise); a stored
    /// value is never overwritten.
    static var language: String {
        get { UserDefaults.standard.string(forKey: "voiceLanguage") ?? defaultLanguage }
        set { UserDefaults.standard.set(newValue, forKey: "voiceLanguage") }
    }
    static var lang: VoiceLang { VoiceLang(code: language) }
    static var answerLocale: Locale { lang.locale }

    private static var defaultLanguage: String {
        let app = AppLanguage.launched
        // With an explicit app language, Locale.preferredLanguages is that choice: read the system's own list.
        let preferred = app == .system
            ? Locale.preferredLanguages
            : (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
               ?? Locale.preferredLanguages)
        return VoiceLang.defaultCode(appPortuguese: app == .portuguese, preferred: preferred,
                                     region: Locale.current.region?.identifier)
    }

    /// Language Coucou LISTENS to: "auto" (the Mac's dictation language, default), "en", "fr" or "pt".
    /// Independent from the answer language: speak French, hear English.
    /// Flow dictation's Automatic mode also follows it (that language is tried first).
    static var listenLanguage: String {
        get { UserDefaults.standard.string(forKey: "voiceListenLanguage") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceListenLanguage") }
    }

    /// Coucou already offered to answer in the language you speak (asked once).
    static var languageOfferDone: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceLanguageOfferDone") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceLanguageOfferDone") }
    }

    /// Voice used to answer: "system" (macOS voices) or "elevenlabs" (user's API key).
    static var ttsEngine: String {
        get { UserDefaults.standard.string(forKey: "voiceTTSEngine") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceTTSEngine") }
    }
    /// ElevenLabs voice_id chosen in Settings; empty = Automatic (picked from gender/language).
    static var elevenVoiceId: String {
        get { UserDefaults.standard.string(forKey: "voiceElevenVoiceId") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceElevenVoiceId") }
    }
    /// ElevenLabs expressiveness: "calm", "normal" (default) or "lively".
    static var elevenExpressiveness: String {
        get { UserDefaults.standard.string(forKey: "voiceElevenExpressiveness") ?? "normal" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceElevenExpressiveness") }
    }
    /// ElevenLabs voice: "female" (default) or "male".
    static var elevenGender: String {
        get { UserDefaults.standard.string(forKey: "voiceElevenGender") ?? "female" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceElevenGender") }
    }

    /// Mac voice pitch per voice type (Settings → Voice). The male default is higher than
    /// the voice's own, so it sounds younger. Range 0.8–1.6 (AVSpeech accepts 0.5–2).
    static let defaultPitchFemale = 1.1
    static let defaultPitchMale   = 1.25
    static func pitchKey(for gender: String) -> String { gender == "male" ? "voicePitchMale" : "voicePitchFemale" }
    static func pitch(for gender: String) -> Double {
        let v = UserDefaults.standard.double(forKey: pitchKey(for: gender))
        let fallback = gender == "male" ? defaultPitchMale : defaultPitchFemale
        return v == 0 ? fallback : min(1.6, max(0.8, v))
    }

    /// Claude is Coucou's brain (the user's Anthropic API key): what I say after
    /// "OK Coucou" goes to Claude, which acts with Coucou's tools and searches the web.
    /// Off by default: my words leave the Mac only once this is turned on.
    static var claudeBrainEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceClaudeBrain") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceClaudeBrain") }
    }
    /// The older web-search-only path follows the same switch.
    static var webSearchEnabled: Bool { claudeBrainEnabled }

    /// Weather by voice (Open-Meteo, no key). Off by default: network only when the user
    /// turned it on and set a city.
    static var weatherEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "voiceWeatherEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "voiceWeatherEnabled") }
    }
    static var weatherCity: String {
        get { UserDefaults.standard.string(forKey: "voiceWeatherCity") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "voiceWeatherCity") }
    }

    // MARK: - Permissions

    enum PermissionStatus { case granted, denied, undetermined }

    static var micStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    static var speechStatus: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    /// Request microphone then speech recognition. Returns true if both granted.
    @MainActor
    static func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
#endif
