#if !APPSTORE
import AVFoundation
import Carbon
import Speech

/// Speech to text for the notch chat (GitHub build), on-device when the Mac supports it.
///
/// Apple's recognizer only understands one language per request, so "Automatic" (the default)
/// listens with up to three recognizers at once — the user's languages (macOS languages,
/// keyboard layouts, then English) — shows the one that won last time while you speak, and when
/// you stop keeps the transcript the recognizers were the most confident about. A fixed language
/// can be chosen from the mic's right-click menu.
///
/// Not main-actor bound, because the audio tap and the recognizers call back on their own
/// threads; the published values are set on the main actor.
@Observable
final class MacDictation: @unchecked Sendable {
    static let automatic = "auto"
    private static let languageKey = "dictationLanguage"
    /// The language that won the last automatic dictation: shown first next time.
    private static let lastHeardKey = "dictationLastLocale"
    private static let maxCandidates = 3

    var isRecording = false
    private(set) var isStarting = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var onEnd: (@MainActor (String) -> Void)?
    var transcript = ""
    /// What was typed before dictating, kept in front of the words.
    var prefix = ""
    /// `automatic` or a locale identifier (the mic's right-click menu).
    var language: String = UserDefaults.standard.string(forKey: MacDictation.languageKey) ?? MacDictation.automatic {
        didSet { UserDefaults.standard.set(language, forKey: Self.languageKey) }
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    typealias Report = @Sendable (String?, [DictationTranscript.Piece], Float, Bool, Bool) -> Void
    /// The OS boundary: contracts substitute audio/recognizer callbacks, while
    /// admission, result handling and teardown remain the shipping code.
    struct Recognition {
        let locale: Locale
        let request: SFSpeechAudioBufferRecognitionRequest
        let start: (@escaping Report) -> (() -> Void)
    }
    struct Input {
        let candidates: ([Locale]) -> [Recognition]
        let startAudio: ([SFSpeechAudioBufferRecognitionRequest], FlowAudioBands?) -> Bool
        let stopAudio: () -> Void
    }
    @ObservationIgnored private let authorization: () async -> Bool
    @ObservationIgnored private let input: Input?

    init(authorization: @escaping () async -> Bool = { await MacDictation.authorized() }, input: Input? = nil) {
        self.authorization = authorization
        self.input = input
    }
    @ObservationIgnored private var candidates: [Candidate] = []
    /// The candidate whose words are shown while speaking.
    @ObservationIgnored private var lead = 0
    @ObservationIgnored private var finishing: CheckedContinuation<Void, Never>?
    private(set) var isFinishing = false
    @ObservationIgnored private var tapInstalled = false
    /// Flow dictation's pill: the microphone's levels by frequency, fed from the same tap.
    @ObservationIgnored var bands: FlowAudioBands?

    /// The text field's content: what was typed, then the words heard so far.
    var text: String { prefix + transcript }

    /// One recognizer listening in one language.
    private final class Candidate {
        let recognition: Recognition
        var locale: Locale { recognition.locale }
        var request: SFSpeechAudioBufferRecognitionRequest { recognition.request }
        var cancel: (() -> Void)?
        /// What was heard, kept whole when the recognizer starts over after a pause.
        var heard = DictationTranscript()
        var words: String { heard.text }
        /// Mean confidence of the words (Apple fills it in on the final result).
        var confidence: Float = 0
        var finished = false

        init(_ recognition: Recognition) { self.recognition = recognition }
    }

    // MARK: Start / finish

    @MainActor func start(from text: String, onEnd: (@MainActor (String) -> Void)? = nil) async {
        guard !Task.isCancelled, !isRecording, !isStarting, !AgentsOnlyPreference.shared.enabled else { return }
        generation += 1
        let token = generation
        operation = AppState.shared.optionalWork.begin()
        self.onEnd = onEnd
        isStarting = true
        defer {
            if generation == token {
                isStarting = false
                if !isRecording { self.onEnd = nil; endOwnership() }
            }
        }
        let authorized = await authorization()
        guard authorized, token == generation, !Task.isCancelled,
              !AgentsOnlyPreference.shared.enabled else { return }
        let locales = language == Self.automatic ? Self.automaticLocales() : [Locale(identifier: language)]
        let built = (input?.candidates(locales) ?? Self.makeCandidates(locales)).map(Candidate.init)
        guard !built.isEmpty else { return }
        let started = input?.startAudio(built.map(\.request), bands)
            ?? Self.startEngine(engine, feeding: built.map(\.request), bands: bands)
        guard started else { return }
        tapInstalled = true
        prefix = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        transcript = ""
        candidates = built
        lead = 0
        isRecording = true
        NotificationCenter.default.post(name: .dictationDidStart, object: nil)
        for (index, candidate) in built.enumerated() {
            candidate.cancel = candidate.recognition.start { [weak self] words, pieces, confidence, final, failed in
                Task { @MainActor in
                    self?.update(index, generation: token, words: words, pieces: pieces, confidence: confidence, final: final, failed: failed)
                }
            }
        }
    }

    /// Stops listening and returns the field's text with the most likely transcript.
    @MainActor func finish() async -> String {
        guard isRecording else { return text }
        let token = generation
        isFinishing = true
        stopEngine()
        candidates.forEach { $0.request.endAudio() }
        // Wait a moment for the final results: they carry the last words (and, with several
        // languages, the confidence that picks one).
        if !candidates.allSatisfy(\.finished) {
            await withCheckedContinuation { continuation in
                finishing = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(1500))
                    if self?.generation == token { self?.resumeFinishing() }
                }
            }
        }
        guard generation == token else { return text }
        if let best = bestCandidate() {
            transcript = best.words
            if candidates.count > 1 {
                UserDefaults.standard.set(best.locale.identifier, forKey: Self.lastHeardKey)
            }
        }
        tearDown()
        return text
    }

    /// Cancels without waiting (the view went away).
    @MainActor func stop() {
        generation += 1
        isStarting = false
        if isRecording || !candidates.isEmpty { tearDown() }
        else { onEnd = nil; endOwnership() }
    }

    @MainActor private func stopEngine() {
        if let input { input.stopAudio() }
        else {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
    }

    @MainActor private func tearDown() {
        generation += 1 // Queued results from this recognizer cannot touch its replacement.
        stopEngine()
        candidates.forEach { $0.request.endAudio(); $0.cancel?() }
        candidates = []
        lead = 0
        NotificationCenter.default.post(name: .dictationDidEnd, object: nil)
        isRecording = false
        isFinishing = false
        resumeFinishing()
        let completed = onEnd
        onEnd = nil
        completed?(text) // Preserve final words before reopening the mode gate.
        endOwnership()
    }

    @MainActor private func endOwnership() {
        guard let operation else { return }
        self.operation = nil
        AppState.shared.optionalWork.end(operation)
    }

    @MainActor private func resumeFinishing() {
        finishing?.resume()
        finishing = nil
    }

    // MARK: Results

    @MainActor private func update(_ index: Int, generation token: Int, words: String?, pieces: [DictationTranscript.Piece], confidence: Float, final: Bool, failed: Bool) {
        guard token == generation, index < candidates.count else { return }
        let candidate = candidates[index]
        if let words { candidate.heard.absorb(words, pieces: pieces) }
        if confidence > 0 { candidate.confidence = confidence }
        if final || failed { candidate.finished = true }

        if isFinishing {
            if candidates.allSatisfy(\.finished) { resumeFinishing() }
            return
        }
        // A recognizer that gives up while you speak (no model, busy…) hands over to the next one.
        if index == lead, candidate.finished, candidate.words.isEmpty,
           let next = candidates.firstIndex(where: { !$0.finished }) {
            lead = next
            transcript = candidates[next].words
            return
        }
        // When Apple reports confidences while speaking, follow the clearly better language.
        let current = candidates[lead]
        if index != lead, candidate.confidence > current.confidence + 0.15,
           candidate.words.split(separator: " ").count >= 3 {
            lead = index
        }
        if index == lead { transcript = candidate.words }
        if candidates.allSatisfy(\.finished) { tearDown() }
    }

    @MainActor private func bestCandidate() -> Candidate? {
        guard lead < candidates.count else { return nil }
        let leader = candidates[lead]
        let best = candidates
            .filter { !$0.words.isEmpty }
            .max { $0.confidence < $1.confidence }
        guard let best, best.confidence > leader.confidence else { return leader }
        return best
    }

    // MARK: Audio and recognizers (off the main actor: they call back on their own threads)

    nonisolated private static func startEngine(_ engine: AVAudioEngine, feeding requests: [SFSpeechAudioBufferRecognitionRequest],
                                                bands: FlowAudioBands? = nil) -> Bool {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            for request in requests { request.append(buffer) }
            bands?.consume(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    nonisolated private static func recognize(
        _ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
        report: @escaping Report
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let words = result?.bestTranscription.formattedString
            let segments = result?.bestTranscription.segments ?? []
            let confidence = segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
            let pieces = segments.map {
                DictationTranscript.Piece(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
            }
            report(words, pieces, confidence, result?.isFinal ?? false, error != nil)
        }
    }

    /// Recognizers that can run now. Extra languages in Automatic only listen on-device,
    /// so the audio never goes to Apple in a language you didn't speak.
    private static func makeCandidates(_ locales: [Locale]) -> [Recognition] {
        var out: [Recognition] = []
        for locale in locales {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { continue }
            if !out.isEmpty && !recognizer.supportsOnDeviceRecognition { continue }
            out.append(recognition(recognizer))
        }
        if out.isEmpty, let fallback = SFSpeechRecognizer(), fallback.isAvailable {
            out.append(recognition(fallback))
        }
        return out
    }

    private static func recognition(_ recognizer: SFSpeechRecognizer) -> Recognition {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return Recognition(locale: recognizer.locale, request: request, start: { report in
            let task = recognize(recognizer, request: request, report: report)
            return { task.cancel() }
        })
    }

    // MARK: Languages

    /// The languages Automatic listens for: last winner, macOS languages, keyboard layouts,
    /// Coucou's own language, then English — one per language, up to three.
    static func automaticLocales() -> [Locale] {
        var ids: [String] = []
        if let last = UserDefaults.standard.string(forKey: lastHeardKey) { ids.append(last) }
        // The Mac's languages (not Coucou's override in Settings → General → Language).
        ids += (CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]) ?? []
        ids += keyboardLanguages()
        ids += Locale.preferredLanguages
        ids.append("en-US")

        let supported = Array(SFSpeechRecognizer.supportedLocales())
        var seen = Set<String>()
        var out: [Locale] = []
        for id in ids {
            guard let locale = match(id, in: supported) else { continue }
            let language = locale.language.languageCode?.identifier ?? locale.identifier
            guard seen.insert(language).inserted else { continue }
            out.append(locale)
            if out.count == maxCandidates { break }
        }
        return out
    }

    /// Every language the recognizer knows, by name.
    static var allLanguages: [String] {
        SFSpeechRecognizer.supportedLocales()
            .map(\.identifier)
            .sorted { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
    }

    static func name(of identifier: String) -> String {
        let name = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "fr" or "fr_FR" → the recognizer locale for it, preferring the Mac's region.
    private static func match(_ id: String, in supported: [Locale]) -> Locale? {
        let wanted = id.replacingOccurrences(of: "_", with: "-").lowercased()
        if let exact = supported.first(where: { $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == wanted }) {
            return exact
        }
        let language = Locale(identifier: id).language.languageCode?.identifier
        let sameLanguage = supported.filter { $0.language.languageCode?.identifier == language }
        let region = Locale(identifier: id).region ?? Locale.current.region
        return sameLanguage.first { $0.region == region }
            ?? sameLanguage.min { $0.identifier < $1.identifier }
    }

    /// The main language of each enabled keyboard layout ("fr" for AZERTY, "en" for ABC…).
    private static func keyboardLanguages() -> [String] {
        let filter = ["TISPropertyInputSourceCategory": "TISCategoryKeyboardInputSource"] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard let raw = TISGetInputSourceProperty(source, "TISPropertyInputSourceLanguages" as CFString) else { return nil }
            let languages = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String]
            return languages?.first
        }
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

// MARK: - Dictation notification names
// Defined here so both MacDictation and VoiceEngine can reference them without
// cross-file ordering issues in SourceKit.
extension Notification.Name {
    static let dictationDidStart = Notification.Name("notchBuddy.dictationDidStart")
    static let dictationDidEnd   = Notification.Name("notchBuddy.dictationDidEnd")
}
#endif
