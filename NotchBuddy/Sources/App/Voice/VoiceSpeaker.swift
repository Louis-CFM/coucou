#if !APPSTORE
import AVFoundation

// MARK: - VoiceSpeaker
//
// Gives Mochi a voice: wraps AVSpeechSynthesizer with a sentence queue.
// Sentence queue: enqueue(text:locale:) adds to queue, playback starts automatically
// and continues through the queue. onDidFinish fires when the queue drains.
//
// All methods: @MainActor.
@MainActor
final class VoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = VoiceSpeaker()

    private let synth = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    private var currentUtterance: AVSpeechUtterance? = nil
    private var queue: [(text: String, locale: Locale?)] = []

    /// Called ~150 ms after the last queued utterance finishes.
    var onDidFinish: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Public API

    /// Clears the queue, stops current speech, and speaks text immediately.
    func speak(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        isSpeaking = false
        currentUtterance = nil
        _enqueueAndPlay(text: text, locale: locale)
    }

    /// Adds text to the end of the playback queue. Starts playing if not already.
    func enqueue(_ text: String, locale: Locale?) {
        guard VoiceSettings.speakEnabled else { return }
        if isSpeaking {
            queue.append((text, locale))
        } else {
            _enqueueAndPlay(text: text, locale: locale)
        }
    }

    func stop() {
        queue.removeAll()
        // Reset now: if the synthesizer never reports the cancel (stopped before the
        // utterance really started), isSpeaking would stay true and the mic would
        // ignore everything until relaunch.
        currentUtterance = nil
        isSpeaking = false
        synth.stopSpeaking(at: .immediate)
    }

    /// What the mic gate should use: the synthesizer's own state (or sentences still
    /// queued), never our flag alone, so a missed delegate callback cannot leave
    /// Coucou deaf.
    var isBusy: Bool { synth.isSpeaking || !queue.isEmpty }

    // MARK: - Private

    private func _enqueueAndPlay(text: String, locale: Locale?) {
        let utt = AVSpeechUtterance(string: text)
        utt.pitchMultiplier = 1.15
        utt.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utt.voice = _bestVoice(for: locale)
        currentUtterance = utt
        isSpeaking = true
        synth.speak(utt)
    }

    /// Picks the best installed voice for the spoken locale: same region first
    /// (fr-FR before fr-CA), then quality (.premium > .enhanced > default).
    /// Novelty voices and the user's Personal Voice are never used.
    private func _bestVoice(for locale: Locale?) -> AVSpeechSynthesisVoice? {
        guard let loc = locale else { return nil }
        let lang = loc.language.languageCode?.identifier ?? ""
        guard !lang.isEmpty else { return nil }
        let region = loc.region?.identifier
        let exact  = region.map { "\(lang)-\($0)" }

        let voices = AVSpeechSynthesisVoice.speechVoices().filter { v in
            (v.language == lang || v.language.hasPrefix(lang + "-"))
                && !v.voiceTraits.contains(.isNoveltyVoice)
                && !v.voiceTraits.contains(.isPersonalVoice)
        }
        guard !voices.isEmpty else { return AVSpeechSynthesisVoice(language: exact ?? lang) }

        func rank(_ v: AVSpeechSynthesisVoice) -> (Int, Int) {
            (v.language == exact ? 1 : 0, v.quality.rawValue)
        }
        return voices.max { rank($0) < rank($1) }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let curr = self.currentUtterance, ObjectIdentifier(curr) == id else { return }
            self.currentUtterance = nil
            if self.queue.isEmpty {
                self.isSpeaking = false
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150 ms gap
                self.onDidFinish?()
            } else {
                let next = self.queue.removeFirst()
                self._enqueueAndPlay(text: next.text, locale: next.locale)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let curr = self.currentUtterance, ObjectIdentifier(curr) == id else { return }
            self.isSpeaking = false
            self.currentUtterance = nil
            self.queue.removeAll()
        }
    }
}
#endif
