#if !APPSTORE
import AppKit
import AVFoundation
import Speech

// MARK: - VoiceEngine
//
// Coordinator for the «OK Coucou» voice feature.
//
// Reliability features:
// - Backoff: onWakeWindowEnded reopens with WakeWindowBackoff (0.5 → 5 s exp.);
//   after maxFastFails consecutive fast-fails, waits for the next VAD segment.
// - Continuous stall watchdog: if no audio buffer arrives for 2 s while the
//   pipeline is active, triggers a pipeline rebuild (regardless of VAD state).
// - Rate-limited rebuilds: ≥5 s between rebuilds, ≤5 per minute. If the limit
//   is exceeded, audioError is set (shown in Settings → Voice).
// - AVAudioEngineConfigurationChange (headphone events) triggers rebuild, but
//   config changes within 1 s of our own engine.start() are ignored (the OS
//   fires one spuriously on start).
// - endCommand() is idempotent: if not in command mode, only cancels timers.
@MainActor
final class VoiceEngine: ObservableObject {
    static let shared = VoiceEngine()

    // MARK: - Published state

    @Published var isEnabled: Bool = VoiceSettings.isEnabled {
        didSet { VoiceSettings.isEnabled = isEnabled; handleEnabledChanged() }
    }
    @Published private(set) var isListeningForCommand: Bool = false
    @Published private(set) var commandTranscript: String = ""
    @Published private(set) var recognizerUnavailable: Bool = false
    @Published private(set) var audioError: String? = nil
    /// Read by Mochi's canvas every frame; not published, so ~20 updates/s while I talk
    /// don't re-render Settings or the island views.
    private(set) var micLevel: Double = 0

    // MARK: - Pause reasons

    private var screenLocked    = false
    private var screenSleeping  = false
    private var lowPowerMode    = false
    private var dictationActive = 0

    var isPaused: Bool { screenLocked || screenSleeping || lowPowerMode || dictationActive > 0 }

    // MARK: - Audio pipeline (main-thread owned)

    private var audio:   VoiceAudio?
    private var spotter: WakeSpotter?
    private var locale:  Locale?

    private var voiceSegmentActive = false

    // Command session timers
    private var silenceWork:    DispatchWorkItem?
    private var commandMaxWork: DispatchWorkItem?
    private var loggedDropWhileSpeaking = false
    private var wakeWindowWork: DispatchWorkItem?   // 20 s periodic restart

    private var lastWordCount = 0

    // Backoff / loop prevention
    private var backoff           = WakeWindowBackoff()
    private var windowOpenedAt:   Date = .distantPast
    private var consecErrorStreak = 0
    private static let maxConsecErrors = 3

    // Music ducking during command (main thread)
    private var savedMusicVolume:   Int?  = nil
    private var savedSpotifyVolume: Int?  = nil
    private var isDuckingMusic             = false

    // Unavailability retry
    private var unavailableWork:    DispatchWorkItem?
    private var firstUnavailableAt: Date? = nil

    // Continuous stall watchdog (always active while pipeline is up)
    private var stallTask:       Task<Void, Never>? = nil
    private var pipelineStartTime: Date = .distantPast

    // Rebuild rate-limiting
    private var lastRebuildTime:    Date = .distantPast
    private var rebuildsThisMinute: Int  = 0
    private var minuteWindowStart:  Date = .distantPast

    private static let initialTimeout:           TimeInterval = 3.0
    private static let directListenInitialTimeout: TimeInterval = 5.0   // follow-up: user reads question first
    private static let directListenMaxTime:        TimeInterval = 20.0

    /// Initial silence timeout for the current direct-listen session.
    private var directInitialTimeout: TimeInterval = 3.0
    private static let wakeFirstWordTimeout: TimeInterval = 5.0
    private static let silenceTimeout:           TimeInterval = 1.5
    private static let commandMaxTime:           TimeInterval = 20.0

    // Conversation window
    private(set) var isInConversation: Bool = false
    private var conversationTurnWork: DispatchWorkItem? = nil
    private static let wakeWindowMax:            TimeInterval = 20.0
    private static let stallTimeout:             TimeInterval = 2.0
    private static let unavailableRebuildDelay:  TimeInterval = 10.0
    private static let minRebuildInterval:       TimeInterval = 5.0
    private static let maxRebuildsPerMinute                   = 5

    private static let cancelPhrases = ["annule", "annuler", "cancel", "laisse tomber", "never mind"]

    // MARK: - Init

    private init() {
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let buildHash = Bundle.main.object(forInfoDictionaryKey: "CoucouGitHash") as? String ?? "unknown"
        appendAppLog("nb.log", "[Voice] build \(buildHash)")
        observeSystemEvents()
        if isEnabled && !isPaused { startAudioPipeline() }
    }

    // MARK: - Enable / pause

    private func handleEnabledChanged() {
        if isEnabled && !isPaused { startAudioPipeline() }
        else                      { stopAudioPipeline() }
    }

    private func updatePause() {
        if isPaused { stopAudioPipeline() }
        else if isEnabled { startAudioPipeline() }
    }

    func cancelListening() { endCommand(postFinished: false) }

    /// Settings → Voice language changed: restart recognition in the new language.
    func reloadLanguage() {
        guard audio != nil else { return }
        stopAudioPipeline()
        if isEnabled && !isPaused { startAudioPipeline() }
        VoiceBrain.shared.endConversation()   // next session gets instructions in the new language
    }

    /// Start the next conversation turn (re-listen for 8 s without wake phrase).
    /// Called by IslandWindowController after showing a command result.
    func startConversationTurn(firstWordTimeout: TimeInterval = 8.0) {
        isInConversation = true
        audio?.resetVAD()
        startListeningDirectly(firstWordTimeout: firstWordTimeout)
    }

    /// End the conversation window and return to normal wake-phrase mode.
    func endConversation() {
        isInConversation = false
        conversationTurnWork?.cancel()
        conversationTurnWork = nil
        endCommand(postFinished: false)
    }

    /// `firstWordTimeout`: seconds of silence allowed before the first word (default 3 s;
    /// pass `Self.directListenInitialTimeout` = 5 s for follow-up questions so the user
    /// has time to read the question before speaking).
    func startListeningDirectly(firstWordTimeout: TimeInterval = 3.0) {
        guard isEnabled, !isPaused, !isListeningForCommand else { return }
        guard let audio = audio, let spotter = spotter, let loc = locale else { return }
        wakeWindowWork?.cancel(); wakeWindowWork = nil
        // Close any active wake window first — TTS audio can trigger VAD and leave
        // an active window open; beginWindow returns false (alreadyActive) otherwise.
        if spotter.isActive { spotter.endWindow() }
        isListeningForCommand = true
        commandTranscript     = ""
        lastWordCount         = 0
        directInitialTimeout  = firstWordTimeout
        loggedDropWhileSpeaking = false
        audio.bypassVAD       = true
        duckMusic()
        appendAppLog("nb.log", "[Voice] direct listen start (firstWordTimeout: \(firstWordTimeout)s)")
        NotificationCenter.default.post(name: .voiceWoke, object: "direct" as NSString)
        let preroll = audio.drainPreroll()
        // startInCommandPhase: skip wake-phrase gate, deliver speech directly as command.
        let started = spotter.beginWindow(locale: loc, preroll: preroll, startInCommandPhase: true)
        if !started {
            appendAppLog("nb.log", "[Voice] direct listen refused (alreadyActive/unavailable), retrying in 150ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.isListeningForCommand else { return }
                guard let spotter = self.spotter, let audio = self.audio, let loc = self.locale else { return }
                let preroll2 = audio.drainPreroll()
                let started2 = spotter.beginWindow(locale: loc, preroll: preroll2, startInCommandPhase: true)
                if !started2 {
                    appendAppLog("nb.log", "[Voice] direct listen still refused, giving up")
                    self.endCommand(postFinished: true)
                }
            }
        }
        resetSilenceTimer()
        let maxItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endCommand(postFinished: true) }
        }
        commandMaxWork = maxItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(Self.directListenMaxTime, firstWordTimeout + 10),
                                      execute: maxItem)
    }

    /// Locale used for the current recognition session — nil if pipeline is not running.
    var speechLocale: Locale? { locale }

    // MARK: - Pipeline lifecycle

    private func startAudioPipeline() {
        guard audio == nil else { return }
        guard let loc = suitableLocale() else {
            recognizerUnavailable = true
            appendAppLog("nb.log", "[Voice] no suitable on-device recognizer — voice disabled")
            return
        }
        recognizerUnavailable = false
        audioError = nil
        locale = loc

        let a = VoiceAudio()
        let s = WakeSpotter()
        s.additionalContextualStrings = PillCatalog.available.map { $0.name }

        // ── Spotter callbacks ─────────────────────────────────────────────────

        s.onWake = { [weak self] transcript in
            self?.wakeDetected(transcript: transcript)
        }

        s.onCommandUpdate = { [weak self] command in
            self?.commandUpdate(command)
        }

        s.onCommandEnd = { [weak self] in
            self?.endCommand(postFinished: true)
        }

        s.onWakeWindowEnded = { [weak self] wasError in
            guard let self, !isListeningForCommand, voiceSegmentActive else { return }

            if wasError {
                consecErrorStreak += 1
                if consecErrorStreak >= Self.maxConsecErrors {
                    appendAppLog("nb.log",
                        "[Voice] window error streak \(consecErrorStreak), rebuilding pipeline")
                    self.triggerPipelineRebuild(reason: "window error streak \(consecErrorStreak)")
                    return
                }
            } else {
                consecErrorStreak = 0
            }

            let elapsed = Date().timeIntervalSince(windowOpenedAt)
            switch backoff.windowEnded(elapsed: elapsed, wasError: wasError) {
            case .open:
                self.openWakeWindow(audio: a, spotter: s, locale: loc)
            case .delay(let d):
                appendAppLog("nb.log",
                    "[Voice] window backoff \(String(format: "%.2f", d))s (streak \(backoff.streak))")
                DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                    guard let self, !isListeningForCommand, voiceSegmentActive else { return }
                    self.openWakeWindow(audio: a, spotter: s, locale: loc)
                }
            case .stop:
                appendAppLog("nb.log",
                    "[Voice] window fast-fail limit (\(backoff.maxFastFails)), waiting for next VAD")
            }
        }

        // ── Audio callbacks ───────────────────────────────────────────────────

        a.onMicLevel = { [weak self] level in self?.micLevel = level }

        // Ignore config changes within 1 s of our own engine.start() — the OS
        // fires one spuriously immediately after AVAudioEngine.start().
        a.onConfigChange = { [weak self] in
            guard let self else { return }
            let age = Date().timeIntervalSince(pipelineStartTime)
            guard age > 1.0 else { return }
            self.triggerPipelineRebuild(reason: "AVAudioEngine config change")
        }

        a.onVoiceStart = { [weak self] in
            guard let self else { return }
            guard !VoiceSpeaker.shared.isBusy else {
                // Coucou's own voice. But with music playing the sound never "ends", so
                // this start would be the last one: open the window once Coucou is quiet.
                appendAppLog("nb.log", "[Voice] vad start deferred (speaker active)")
                self.openWindowWhenSpeakerQuiet(audio: a, spotter: s, locale: loc)
                return
            }
            appendAppLog("nb.log", "[Voice] vad start")
            voiceSegmentActive = true
            backoff.reset()
            consecErrorStreak  = 0
            self.openWakeWindow(audio: a, spotter: s, locale: loc)
        }

        a.onVoiceEnd = { [weak self] in
            guard let self else { return }
            appendAppLog("nb.log", "[Voice] vad end")
            voiceSegmentActive  = false
            unavailableWork?.cancel(); unavailableWork = nil
            firstUnavailableAt  = nil
            wakeWindowWork?.cancel(); wakeWindowWork = nil
            if !isListeningForCommand && !s.isInCommandPhase {
                let elapsed = Date().timeIntervalSince(self.windowOpenedAt)
                let st = s.endWindow()
                appendAppLog("nb.log", "[Voice] window close \(Self.describe(st))")
                self.checkDeafRecognizer(st, elapsed: elapsed)
            }
        }

        a.onBuffer = { buf, _ in s.feed(buf) }

        do {
            try a.start()
            audio             = a
            spotter           = s
            pipelineStartTime = Date()
            startAudioStallTask(audio: a)
        } catch {
            let e = error as NSError
            let msg = "[Voice] pipeline start failed: \(e.domain)/\(e.code) \(e.localizedDescription)"
            appendAppLog("nb.log", msg)
            audioError = "\(e.domain)/\(e.code): \(e.localizedDescription)"
        }
    }

    private func stopAudioPipeline() {
        endCommand(postFinished: false)
        wakeWindowWork?.cancel();   wakeWindowWork   = nil
        unavailableWork?.cancel();  unavailableWork  = nil
        firstUnavailableAt  = nil
        stopAudioStallTask()
        // Null callbacks before stop() so queued main-thread dispatches become no-ops.
        audio?.onVoiceStart    = nil
        audio?.onVoiceEnd      = nil
        audio?.onBuffer        = nil
        audio?.onMicLevel      = nil
        audio?.onConfigChange  = nil
        spotter?.onWake            = nil
        spotter?.onCommandUpdate   = nil
        spotter?.onCommandEnd      = nil
        spotter?.onWakeWindowEnded = nil
        deferredStartWork?.cancel(); deferredStartWork = nil
        audio?.stop()
        audio              = nil
        spotter            = nil
        locale             = nil
        voiceSegmentActive = false
        backoff.reset()
        consecErrorStreak  = 0
    }

    // MARK: - Stall watchdog (continuous — not limited to VAD segments)

    /// Polls `audio.lastBufferTime` every 0.5 s. If no buffer arrives for
    /// `stallTimeout` seconds (with a grace period after pipeline start),
    /// triggers a pipeline rebuild.
    private func startAudioStallTask(audio: VoiceAudio) {
        stopAudioStallTask()
        stallTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Tolerance lets macOS batch this wakeup with others (stall seen in 2–3 s).
                try? await Task.sleep(for: .milliseconds(500), tolerance: .milliseconds(400))
                guard let self, let audio = self.audio else { return }
                // Grace period: don't fire within stallTimeout of pipeline start.
                let sinceStart = Date().timeIntervalSince(self.pipelineStartTime)
                guard sinceStart > Self.stallTimeout else { continue }
                let age = Date().timeIntervalSince(audio.lastBufferTime)
                guard age > Self.stallTimeout else { continue }
                appendAppLog("nb.log",
                    "[Voice] audio stall \(String(format: "%.1f", age))s, rebuilding")
                self.triggerPipelineRebuild(reason: "audio stall \(String(format: "%.1f", age))s")
                return
            }
        }
    }

    private func stopAudioStallTask() {
        stallTask?.cancel()
        stallTask = nil
    }

    // MARK: - Wake window helpers

    @discardableResult
    private func openWakeWindow(audio: VoiceAudio, spotter: WakeSpotter, locale: Locale) -> Bool {
        let preroll = audio.drainPreroll()
        let started = spotter.beginWindow(locale: locale, preroll: preroll)
        if started {
            windowOpenedAt     = Date()
            firstUnavailableAt = nil
            unavailableWork?.cancel(); unavailableWork = nil
            appendAppLog("nb.log", "[Voice] window open")
            scheduleWakeWindowRestart(audio: audio, spotter: spotter, locale: locale)
        } else {
            if firstUnavailableAt == nil { firstUnavailableAt = Date() }
            let age = Date().timeIntervalSince(firstUnavailableAt!)
            if age >= Self.unavailableRebuildDelay {
                appendAppLog("nb.log", "[Voice] recognizer unavailable \(Int(age))s, rebuilding")
                triggerPipelineRebuild(reason: "recognizer unavailable \(Int(age))s")
            } else {
                unavailableWork?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self, voiceSegmentActive, !isListeningForCommand else { return }
                    self.openWakeWindow(audio: audio, spotter: spotter, locale: locale)
                }
                unavailableWork = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
            }
        }
        return started
    }

    private func scheduleWakeWindowRestart(audio: VoiceAudio, spotter: WakeSpotter, locale: Locale) {
        wakeWindowWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, !isListeningForCommand else { return }
            let st = spotter.endWindow()
            // Log only: a 20 s window can be steady background noise with no words.
            appendAppLog("nb.log", "[Voice] window close (20s) \(Self.describe(st))")
            self.openWakeWindow(audio: audio, spotter: spotter, locale: locale)
        }
        wakeWindowWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeWindowMax, execute: item)
    }

    // MARK: - Deferred voice start

    private var deferredStartWork: DispatchWorkItem?

    /// A voice start swallowed while Coucou was talking: with continuous sound (music on
    /// the speakers) the VAD never ends and never starts again, so without this Coucou
    /// stayed deaf until the music stopped. Checks every 0.3 s, then opens the window.
    private func openWindowWhenSpeakerQuiet(audio: VoiceAudio, spotter: WakeSpotter, locale: Locale) {
        guard deferredStartWork == nil else { return }
        scheduleDeferredStartCheck(audio: audio, spotter: spotter, locale: locale)
    }

    private func scheduleDeferredStartCheck(audio: VoiceAudio, spotter: WakeSpotter, locale: Locale) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredStartWork = nil
            if VoiceSpeaker.shared.isBusy {
                self.scheduleDeferredStartCheck(audio: audio, spotter: spotter, locale: locale)
                return
            }
            guard self.audio === audio, !self.isListeningForCommand, !spotter.isActive else { return }
            appendAppLog("nb.log", "[Voice] vad start (deferred)")
            audio.resetVAD()
            self.voiceSegmentActive = true
            self.backoff.reset()
            self.consecErrorStreak  = 0
            self.openWakeWindow(audio: audio, spotter: spotter, locale: locale)
        }
        deferredStartWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Deaf recognizer detection

    /// Speech was heard (VAD) but the recognizer returned no text at all, window after
    /// window: it is stuck. Rebuild the pipeline instead of staying deaf until relaunch.
    private var deafWindows = 0

    private static func describe(_ st: WakeSpotter.WindowStats) -> String {
        "partials=\(st.partials) words=\(st.maxWords) coucou-like=\(st.nearWake ? "yes" : "no")"
    }

    private func checkDeafRecognizer(_ st: WakeSpotter.WindowStats, elapsed: TimeInterval) {
        if st.partials > 0 { deafWindows = 0; return }
        // A short noise (cough, click) legitimately gives no text: only count windows
        // where speech went on for a while.
        guard elapsed >= 3 else { return }
        // Music without words gives no text either: while music plays it takes 6 silent
        // windows, not 2, before a rebuild (each costs a restart and ~0.5 s of deafness).
        let music = AppState.shared.musicPlaying || SpotifyController.shared.isPlaying
        deafWindows += 1
        if deafWindows >= (music ? 6 : 2) {
            deafWindows = 0
            appendAppLog("nb.log", "[Voice] recognizer returned nothing for \(music ? 6 : 2) windows, rebuilding")
            triggerPipelineRebuild(reason: "recognizer deaf")
        }
    }

    // MARK: - Pipeline rebuild (rate-limited)

    private func triggerPipelineRebuild(reason: String) {
        let now = Date()

        // Rate-limit: reset minute window if needed.
        if now.timeIntervalSince(minuteWindowStart) >= 60.0 {
            minuteWindowStart  = now
            rebuildsThisMinute = 0
        }

        // Enforce minimum interval and per-minute cap.
        let tooSoon  = now.timeIntervalSince(lastRebuildTime) < Self.minRebuildInterval
        let tooMany  = rebuildsThisMinute >= Self.maxRebuildsPerMinute
        if tooSoon || tooMany {
            appendAppLog("nb.log", "[Voice] rebuild limit reached (\(reason))")
            if audioError == nil {
                audioError = "Voice recognition stalled — toggle Voice off/on to reset."
            }
            return
        }

        rebuildsThisMinute += 1
        lastRebuildTime     = now
        appendAppLog("nb.log", "[Voice] pipeline rebuild (\(reason))")
        stopAudioPipeline()
        guard isEnabled, !isPaused else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, isEnabled, !isPaused else { return }
            self.startAudioPipeline()
        }
    }

    // MARK: - Music ducking

    /// Lower Apple Music and Spotify to 25 % while a command is in progress.
    /// Saves the current volumes so `restoreMusic()` can undo the change.
    private func duckMusic() {
        guard !isDuckingMusic else { return }
        isDuckingMusic = true

        if SpotifyController.shared.isPlaying {
            savedSpotifyVolume = SpotifyController.shared.volume
            SpotifyController.shared.setVolume(25)
            appendAppLog("nb.log", "[Voice] music duck spotify \(savedSpotifyVolume ?? -1) → 25")
        }

        if AppState.shared.musicPlaying {
            Task {
                if let vol = await MusicController.shared.getVolume() {
                    savedMusicVolume = vol
                    MusicController.shared.setVolume(25)
                    appendAppLog("nb.log", "[Voice] music duck apple \(vol) → 25")
                }
            }
        }
    }

    /// Restore volumes saved by `duckMusic()`.
    /// Skipped when the command was itself a volume command (`volumeCommandExecuted`).
    private func restoreMusic() {
        guard isDuckingMusic else { return }
        isDuckingMusic = false

        if VoiceActionRunner.shared.volumeCommandExecuted {
            // User explicitly changed volume — keep new value, discard saved.
            VoiceActionRunner.shared.volumeCommandExecuted = false
            savedMusicVolume   = nil
            savedSpotifyVolume = nil
            appendAppLog("nb.log", "[Voice] music restore skipped (volume command)")
            return
        }

        if let vol = savedSpotifyVolume {
            SpotifyController.shared.setVolume(vol)
            appendAppLog("nb.log", "[Voice] music restore spotify → \(vol)")
            savedSpotifyVolume = nil
        }
        if let vol = savedMusicVolume {
            MusicController.shared.setVolume(vol)
            appendAppLog("nb.log", "[Voice] music restore apple → \(vol)")
            savedMusicVolume = nil
        }
    }

    // MARK: - Wake detection

    private func wakeDetected(transcript: String) {
        guard isEnabled, !isPaused else {
            let reason = isPaused ? "paused" : "disabled"
            appendAppLog("nb.log", "[Voice] wake ignored: \(reason)")
            spotter?.endWindow(); return
        }
        guard !isListeningForCommand else {
            appendAppLog("nb.log", "[Voice] wake ignored: already listening")
            spotter?.endWindow(); return
        }
        let s = AppState.shared
        if let reason = VoiceWakeFilter.wakeBlocked(
            view: s.view, mode: s.mode, pendingApproval: s.pendingApproval != nil
        ) {
            appendAppLog("nb.log", "[Voice] wake ignored: \(reason)")
            spotter?.endWindow(); return
        }
        wakeWindowWork?.cancel();  wakeWindowWork  = nil
        unavailableWork?.cancel(); unavailableWork = nil
        firstUnavailableAt  = nil
        backoff.reset()
        consecErrorStreak   = 0
        isListeningForCommand = true
        commandTranscript     = ""
        lastWordCount         = 0
        // After "OK Coucou", leave time to start the sentence (the island no longer
        // opens, the caption shows "Je t'écoute…" instead). 3 s was too short.
        directInitialTimeout  = Self.wakeFirstWordTimeout
        audio?.bypassVAD      = true
        duckMusic()
        appendAppLog("nb.log", "[Voice] wake")
        NotificationCenter.default.post(name: .voiceWoke, object: nil)
        resetSilenceTimer()
        let maxItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.endCommand(postFinished: true) }
        }
        commandMaxWork = maxItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commandMaxTime, execute: maxItem)
    }

    private func commandUpdate(_ command: String) {
        // Semi-duplex: ignore updates while Coucou is speaking.
        guard !VoiceSpeaker.shared.isBusy else {
            // Logged once per turn (no words): helps when an answer seems unheard.
            if !loggedDropWhileSpeaking {
                loggedDropWhileSpeaking = true
                appendAppLog("nb.log", "[Voice] words heard while Coucou was speaking: ignored")
            }
            return
        }
        // The recognizer often repeats the same partial: no update, no re-render.
        guard command != commandTranscript else { return }
        commandTranscript = command
        let wc = command.split(separator: " ").count
        if wc > lastWordCount {
            // Load the on-device model once the sentence has started, not at the wake
            // word: loading it at the same moment slowed speech recognition down.
            // Not when Claude is the brain: the on-device model would load for nothing.
            if lastWordCount == 0 && !ClaudeVoiceBrain.isActive { VoiceBrain.shared.prewarmSession() }
            lastWordCount = wc
            resetSilenceTimer()
            let trimmed = command.trimmingCharacters(in: .whitespaces)
            let normTrimmed = WakePhrase.normalise(trimmed)
            if Self.cancelPhrases.contains(normTrimmed) {
                endCommand(postFinished: true)
            } else if isInConversation && TurnEndPolicy.conversationEndPhrases.contains(normTrimmed) {
                // Post voiceFinished with the end phrase so IslandWindowController can handle cleanup
                endCommand(postFinished: true)
            }
        }
    }

    // MARK: - Command session management

    private func resetSilenceTimer() {
        silenceWork?.cancel()
        let timeout: TimeInterval
        if lastWordCount == 0 {
            timeout = directInitialTimeout
        } else {
            timeout = TurnEndPolicy.silenceDelay(for: WakePhrase.normalise(commandTranscript),
                                                 longAnswer: VoiceActionRunner.shared.expectsLongAnswer)
        }
        scheduleSilenceCheck(after: timeout)
    }

    /// The turn ends after the silence delay, unless I'm still making sound (an "euhhh"
    /// while thinking gives no words but is not silence): then it waits a bit more. The
    /// command's max duration still applies.
    private func scheduleSilenceCheck(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.isListeningForCommand else { return }
                if let a = self.audio, Date().timeIntervalSince(a.lastVoicedTime) < 0.5 {
                    self.scheduleSilenceCheck(after: 0.5)
                } else {
                    self.endCommand(postFinished: true)
                }
            }
        }
        silenceWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Idempotent: if not in command mode, only cancels timers.
    /// Does NOT call endWindow() or resetVAD() — prevents closing a freshly
    /// opened wake window when the result view is dismissed.
    private func endCommand(postFinished: Bool) {
        silenceWork?.cancel();    silenceWork    = nil
        commandMaxWork?.cancel(); commandMaxWork = nil
        guard isListeningForCommand else { return }
        audio?.bypassVAD  = false
        audio?.resetVAD()
        voiceSegmentActive = false
        micLevel           = 0
        spotter?.endWindow()
        restoreMusic()
        appendAppLog("nb.log", "[Voice] command end (had transcript: \(!commandTranscript.isEmpty))")
        if !postFinished { commandTranscript = "" }
        isListeningForCommand = false
        if postFinished {
            let cmd = commandTranscript
            NotificationCenter.default.post(name: .voiceFinished,
                                            object: cmd.isEmpty ? nil : cmd as NSString)
        }
    }

    // MARK: - Helpers

    private func suitableLocale() -> Locale? {
        // The language I speak (Settings → Voice → "You speak"): automatic = the Mac's
        // dictation languages first. The answer language is separate (VoiceSettings.language).
        var candidates: [Locale]
        switch VoiceSettings.listenLanguage {
        case "fr": candidates = [Locale(identifier: "fr-FR"), Locale(identifier: "fr-CA")]
        case "en": candidates = [Locale(identifier: "en-US"), Locale(identifier: "en-GB"), Locale(identifier: "en-AU")]
        default:   candidates = []
        }
        candidates += MacDictation.automaticLocales()
        candidates += [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")]
        for locale in candidates {
            if let r = SFSpeechRecognizer(locale: locale),
               r.supportsOnDeviceRecognition, r.isAvailable {
                return locale
            }
        }
        return nil
    }

    // MARK: - System event observers

    private func observeSystemEvents() {
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = true;  self?.updatePause() }
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenLocked = false; self?.updatePause() }
        }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = true;  self?.updatePause() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = false; self?.updatePause() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = true;  self?.updatePause() }
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenSleeping = false; self?.updatePause() }
        }

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.updatePause()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .dictationDidStart, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dictationActive += 1
                self?.updatePause()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .dictationDidEnd, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dictationActive = max(0, (self?.dictationActive ?? 0) - 1)
                self?.updatePause()
            }
        }
    }
}

// MARK: - Voice notification names

extension Notification.Name {
    static let voiceWoke     = Notification.Name("notchBuddy.voiceWoke")
    static let voiceFinished = Notification.Name("notchBuddy.voiceFinished")
}
#endif
