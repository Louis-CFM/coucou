#if !APPSTORE
import AVFoundation
import Speech

/// Flow dictation with the Mac's newer speech model (SpeechAnalyzer, macOS 26), when the Mac's
/// recognizer is chosen and the languages it listens for are installed on this Mac. It is more
/// accurate than SFSpeechRecognizer, writes the punctuation, and runs on the Mac only.
///
/// Like MacDictation, "Automatic" listens in up to three languages at once and keeps the one it
/// was the most confident about. Nothing is downloaded: a language that isn't installed leaves
/// Flow on MacDictation.
@available(macOS 26.0, *)
final class AnalyzerDictation: @unchecked Sendable {
    @MainActor private(set) var isRecording = false
    /// Flow dictation's pill: the microphone's levels by frequency, fed from the same tap.
    var bands: FlowAudioBands?

    private let locales: [Locale]
    private let engine = AVAudioEngine()
    @MainActor private var lanes: [Lane] = []

    /// One language: its transcriber, its analyzer and the audio going in.
    private final class Lane: @unchecked Sendable {
        let locale: Locale
        let transcriber: SpeechTranscriber
        let analyzer: SpeechAnalyzer
        let input: AsyncStream<AnalyzerInput>.Continuation
        private let stream: AsyncStream<AnalyzerInput>
        private var collecting: Task<Heard, Never>?

        struct Heard {
            var text = ""
            /// Mean confidence of the words, 0 when none were heard.
            var confidence = 0.0
        }

        init(locale: Locale) {
            self.locale = locale
            transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.transcriptionConfidence])
            analyzer = SpeechAnalyzer(modules: [transcriber])
            (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        }

        func begin() {
            let transcriber = transcriber
            collecting = Task {
                var heard = Heard()
                var total = 0.0
                var count = 0
                do {
                    // Final results only: each one is a stretch of speech, in order.
                    for try await result in transcriber.results {
                        heard.text = AnalyzerDictation.join(heard.text, String(result.text.characters))
                        for run in result.text.runs {
                            if let confidence = run.transcriptionConfidence { total += confidence; count += 1 }
                        }
                    }
                } catch {
                    appendAppLog("nb.log", "[Flow] SpeechAnalyzer failed: \(error.localizedDescription)")
                }
                heard.confidence = count > 0 ? total / Double(count) : 0
                return heard
            }
            let analyzer = analyzer
            let stream = stream
            Task { try? await analyzer.start(inputSequence: stream) }
        }

        /// The words, once the audio sent so far is transcribed (or after a few seconds, never longer).
        func finish() async -> Heard {
            input.finish()
            let analyzer = analyzer
            let done = Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            let timeout = Task {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { await analyzer.cancelAndFinishNow() }
            }
            _ = await done.value
            timeout.cancel()
            return await collecting?.value ?? Heard()
        }

        func cancel() {
            input.finish()
            collecting?.cancel()
            let analyzer = analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    init(locales: [Locale]) {
        self.locales = locales
    }

    /// The languages to listen for with this engine, or nil when one of them can't be (not
    /// supported, or not installed on this Mac): MacDictation listens then, as before.
    static func locales(for language: String) async -> [Locale]? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let wanted = language == MacDictation.automatic ? MacDictation.automaticLocales() : [Locale(identifier: language)]
        guard !wanted.isEmpty else { return nil }
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        var out: [Locale] = []
        for locale in wanted {
            guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
                  installed.contains(match.identifier(.bcp47)) else { return nil }
            out.append(match)
        }
        return out
    }

    // MARK: Start / finish

    @MainActor func start() async {
        guard !isRecording, !locales.isEmpty, await AVAudioApplication.requestRecordPermission() else { return }
        let built = locales.map(Lane.init)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: built.map(\.transcriber)),
              Self.startEngine(engine, to: format, feeding: built.map(\.input), bands: bands) else {
            built.forEach { $0.cancel() }
            return
        }
        built.forEach { $0.begin() }
        lanes = built
        isRecording = true
        NotificationCenter.default.post(name: .dictationDidStart, object: nil)
    }

    /// Stops the microphone and returns the words of the language it was the most sure of.
    @MainActor func finish() async -> String {
        guard isRecording else { return "" }
        stopEngine()
        let finishing = lanes
        lanes = []
        var results: [(locale: Locale, heard: Lane.Heard)] = []
        for lane in finishing {
            results.append((lane.locale, await lane.finish()))
        }
        let best = results.filter { !$0.heard.text.isEmpty }.max { $0.heard.confidence < $1.heard.confidence }
        if let best, results.count > 1 {
            UserDefaults.standard.set(best.locale.identifier, forKey: MacDictation.lastHeardKey)
        }
        return best?.heard.text ?? ""
    }

    /// Stops without words (Esc, another key).
    @MainActor func stop() {
        guard isRecording else { return }
        stopEngine()
        lanes.forEach { $0.cancel() }
        lanes = []
    }

    @MainActor private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        NotificationCenter.default.post(name: .dictationDidEnd, object: nil)
    }

    /// Two stretches of speech, with a space between them unless one is already there.
    static func join(_ text: String, _ more: String) -> String {
        let more = more.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return more }
        if more.isEmpty { return text }
        return text + " " + more
    }

    // MARK: Audio (off the main actor: the tap calls back on its own thread)

    nonisolated private static func startEngine(_ engine: AVAudioEngine, to format: AVAudioFormat,
                                                feeding inputs: [AsyncStream<AnalyzerInput>.Continuation],
                                                bands: FlowAudioBands?) -> Bool {
        let input = engine.inputNode
        let source = input.outputFormat(forBus: 0)
        guard source.sampleRate > 0, let converter = AVAudioConverter(from: source, to: format) else { return false }
        converter.downmix = true
        let ratio = format.sampleRate / source.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { buffer, _ in
            bands?.consume(buffer)
            guard let out = convert(buffer, with: converter, to: format, ratio: ratio) else { return }
            for input in inputs { input.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                            to format: AVAudioFormat, ratio: Double) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }
}
#endif
