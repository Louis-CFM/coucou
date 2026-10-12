#if !APPSTORE
import AVFoundation
import Speech

// MARK: - WakeSpotter
//
// Runs a single SFSpeechRecognizer window to detect the "OK Coucou" wake phrase,
// then switches to command mode in the same recognition session so words spoken
// immediately after the wake phrase are not lost.
//
// Thread model: `beginWindow`, `endWindow` called on the main actor.
// `feed(_:)` may be called from any thread (audio tap thread).
// Recognition callbacks arrive on an internal Apple thread.
// All shared state is protected by a single NSLock.
//
// Stale-callback filtering: every task captures a generation number at creation.
// `endWindow()` bumps the generation, so callbacks from cancelled/superseded tasks
// are silently ignored when they arrive after a new window has opened.
//
// Logging (to nb.log, prefix [Voice] for one-grep coverage):
//   [Voice] spotter task start
//   [Voice] spotter task refused (already active)
//   [Voice] spotter task refused (unavailable)
//   [Voice] spotter task end: final, partials N
//   [Voice] spotter task end: error <domain>/<code>, partials N
//   [Voice] spotter stale callback ignored (gen X/Y)
final class WakeSpotter: @unchecked Sendable {

    // MARK: - Callbacks (all delivered on the main thread)

    var onWake:           ((String) -> Void)?
    var onCommandUpdate:  ((String) -> Void)?
    var onCommandEnd:     (() -> Void)?
    /// Fired when the session ends in wake phase (no command captured).
    /// `wasError` is true for real errors; false for clean finals, no-speech
    /// timeout (1110) and cancellations — those do not count as backoff failures.
    var onWakeWindowEnded: ((Bool) -> Void)?

    /// Extra strings to add to the recognizer's contextual hints (e.g. pill names).
    /// Set before calling `beginWindow`. Thread-safe (read under `lock`).
    var additionalContextualStrings: [String] = []

    // MARK: - State (all guarded by `lock`)

    private let lock = NSLock()
    private var recognizer:   SFSpeechRecognizer?
    /// One recognizer per locale for the life of this spotter (a pipeline rebuild makes a
    /// new spotter): creating one per window cost a speech-service round trip at each wake.
    private var cachedRecognizer: (id: String, recognizer: SFSpeechRecognizer)?
    private var request:      SFSpeechAudioBufferRecognitionRequest?
    private var task:         SFSpeechRecognitionTask?
    private var active        = false
    private var phase:        Phase = .wake
    private var partialCount  = 0
    private var maxWords      = 0       // diagnostics only — never the words themselves
    private var nearWake      = false   // a partial had a "coucou"-like token
    private var gen           = SpotterGeneration()   // stale-callback filter

    /// What a wake window heard, without any text: lets the log tell "recognizer
    /// returned nothing" apart from "heard speech but not the wake phrase".
    struct WindowStats { let partials: Int; let maxWords: Int; let nearWake: Bool }

    private enum Phase { case wake, command }

    // MARK: - Public API

    var isInCommandPhase: Bool { lock.withLock { phase == .command } }
    var isActive: Bool { lock.withLock { active } }

    /// Open a recognition window.
    /// - `startInCommandPhase`: when `true`, skip the wake-phrase gate and start
    ///   delivering transcripts directly as command updates (used for follow-up
    ///   answers and the ⌃⌥V direct-listen shortcut).
    /// Returns `true` if the underlying recognition task was successfully started.
    @discardableResult
    func beginWindow(locale: Locale,
                     preroll: [AVAudioPCMBuffer] = [],
                     startInCommandPhase: Bool = false) -> Bool {
        enum Refusal { case alreadyActive, unavailable }
        var refusal:  Refusal? = nil
        var rSnap:    SFSpeechRecognizer?
        var reqSnap:  SFSpeechAudioBufferRecognitionRequest?
        var taskGen   = 0

        let made: SFSpeechRecognizer? = lock.withLock {
            if let c = cachedRecognizer, c.id == locale.identifier { return c.recognizer }
            return nil
        } ?? SFSpeechRecognizer(locale: locale)

        lock.withLock {
            guard !active else { refusal = .alreadyActive; return }
            if let made { cachedRecognizer = (locale.identifier, made) }
            guard let r = made,
                  r.supportsOnDeviceRecognition,
                  r.isAvailable else { refusal = .unavailable; return }

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults  = true
            req.requiresOnDeviceRecognition = true
            let extra = startInCommandPhase ? additionalContextualStrings : [String]()
            req.contextualStrings = ["Coucou", "OK Coucou", "okay Coucou", "hey Coucou"] + extra
            preroll.forEach { req.append($0) }

            recognizer   = r
            request      = req
            active       = true
            phase        = startInCommandPhase ? .command : .wake
            partialCount = 0
            taskGen      = gen.bump()   // new generation for this task
            rSnap        = r
            reqSnap      = req
        }

        if let refusal {
            switch refusal {
            case .alreadyActive:
                appendAppLog("nb.log", "[Voice] spotter task refused (already active)")
            case .unavailable:
                appendAppLog("nb.log", "[Voice] spotter task refused (unavailable)")
            }
            return false
        }

        guard let r = rSnap, let req = reqSnap else { return false }

        appendAppLog("nb.log", "[Voice] spotter task start")
        // Capture taskGen by value so callbacks from this specific task carry its generation.
        let t = r.recognitionTask(with: req) { [weak self, taskGen] result, error in
            self?.handleResult(result, error: error, expectedGen: taskGen)
        }
        lock.withLock { task = t }
        return true
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    /// Close the window. Bumps the generation so any in-flight callbacks from the
    /// cancelled task are ignored even if they arrive after the next `beginWindow`.
    @discardableResult
    func endWindow() -> WindowStats {
        lock.withLock {
            let stats = WindowStats(partials: partialCount, maxWords: maxWords, nearWake: nearWake)
            maxWords = 0
            nearWake = false
            request?.endAudio()
            task?.cancel()
            request      = nil
            task         = nil
            recognizer   = nil
            active       = false
            phase        = .wake
            partialCount = 0
            gen.bump()   // invalidate callbacks from the task we just cancelled
            return stats
        }
    }

    // MARK: - Recognition callback

    private enum RecogAction {
        case woke(String)
        case commandUpdate(String)
        case commandEnd
        case wakeWindowEnded(wasError: Bool)
    }

    private func handleResult(_ result: SFSpeechRecognitionResult?,
                               error: Error?,
                               expectedGen: Int) {
        var logMsg: String? = nil

        let action: RecogAction? = lock.withLock { () -> RecogAction? in
            guard active else { return nil }

            // Stale-callback guard: ignore results from superseded tasks.
            guard gen.isValid(expectedGen) else {
                logMsg = "[Voice] spotter stale callback ignored (gen \(expectedGen)/\(gen.current))"
                return nil
            }

            if let transcript = result?.bestTranscription.formattedString {
                partialCount += 1
                switch phase {
                case .wake:
                    let words = WakePhrase.normalise(transcript).split(separator: " ")
                    maxWords = max(maxWords, words.count)
                    if words.contains(where: { w in
                        ["cou", "kou", "kuku", "cuck", "koukou", "coco"].contains { w.contains($0) }
                    }) { nearWake = true }
                    let r = WakePhrase.split(transcript)
                    if r.matched {
                        phase = .command
                        return .woke(transcript)
                    }
                case .command:
                    let r = WakePhrase.split(transcript)
                    return .commandUpdate(r.matched ? r.command : transcript)
                }
            }

            if result?.isFinal == true || error != nil {
                let wasCommand = phase == .command
                let n          = partialCount
                // 1110 (no speech) and cancellations are normal ends, not backoff failures.
                let wasError   = error.map { !spotterIsExpectedError($0) } ?? false
                request      = nil
                task         = nil
                recognizer   = nil
                active       = false
                phase        = .wake
                // partialCount kept: endWindow() reports it (WindowStats)
                if let err = error as NSError? {
                    logMsg = "[Voice] spotter task end: error \(err.domain)/\(err.code), partials \(n)"
                } else {
                    logMsg = "[Voice] spotter task end: final, partials \(n)"
                }
                return wasCommand ? .commandEnd : .wakeWindowEnded(wasError: wasError)
            }
            return nil
        }

        if let msg = logMsg { appendAppLog("nb.log", msg) }
        guard let action else { return }

        switch action {
        case .woke(let t):
            DispatchQueue.main.async { [weak self] in self?.onWake?(t) }
        case .commandUpdate(let s):
            DispatchQueue.main.async { [weak self] in self?.onCommandUpdate?(s) }
        case .commandEnd:
            DispatchQueue.main.async { [weak self] in self?.onCommandEnd?() }
        case .wakeWindowEnded(let wasError):
            DispatchQueue.main.async { [weak self] in self?.onWakeWindowEnded?(wasError) }
        }
    }
}
#endif
