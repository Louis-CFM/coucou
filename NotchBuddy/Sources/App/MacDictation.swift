#if !APPSTORE
import AVFoundation
import Speech

/// Speech to text for the notch chat (GitHub build), on-device when the Mac supports it.
/// Same model as the iPhone's Dictation: not main-actor bound, because the audio tap and the
/// recognizer call back on their own threads; the published values are set on the main actor.
@Observable
final class MacDictation: @unchecked Sendable {
    var isRecording = false
    var transcript = ""
    /// What was typed before dictating, kept in front of the words.
    var prefix = ""

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    /// The text field's content: what was typed, then the words heard so far.
    var text: String { prefix + transcript }

    @MainActor func toggle(startingFrom text: String) async {
        if isRecording { stop(); return }
        guard await Self.authorized() else { return }
        prefix = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        transcript = ""
        start()
    }

    nonisolated private func start() {
        // The app's language first (Settings → General → Language), then the system's.
        let localeID = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return
        }
        self.request = request
        Task { @MainActor in self.isRecording = true }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let words { self.transcript = words }
                if done { self.stop() }
            }
        }
    }

    @MainActor func stop() {
        guard isRecording || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
#endif
