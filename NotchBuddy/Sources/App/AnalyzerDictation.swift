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

    /// Every language supported by either SFSpeechRecognizer or SpeechTranscriber
    static func allLanguages() async -> [String] {
        var out = MacDictation.allLanguages
        var seen = Set(out.map { Locale(identifier: $0).identifier(.bcp47).lowercased() })
        if SpeechTranscriber.isAvailable {
            for locale in await SpeechTranscriber.supportedLocales {
                let id = locale.identifier(.bcp47)
                if seen.insert(id.lowercased()).inserted { out.append(id) }
            }
        }
        return out.sorted {
            MacDictation.name(of: $0).localizedCaseInsensitiveCompare(MacDictation.name(of: $1)) == .orderedAscending
        }
    }

    /// The SpeechTranscriber locales requested by `language` (whether installed yet or not).
    static func wantedLocales(for language: String, maxAutomatic: Int = 4) async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        if language != MacDictation.automatic {
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
                return [match]
            }
            return []
        }
        let ids = await MacDictation.preferredLanguageIDs()
        var seen = Set<String>()
        var out: [Locale] = []
        for id in ids {
            guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { continue }
            let code = match.language.languageCode?.identifier ?? match.identifier
            guard seen.insert(code).inserted else { continue }
            out.append(match)
            if out.count == maxAutomatic { break }
        }
        return out
    }

    /// The languages to listen for with this engine, or nil when none of them are installed on this
    /// Mac (or a fixed chosen language is not installed): MacDictation listens then, as before.
    static func locales(for language: String, maxAutomatic: Int = 4) async -> [Locale]? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let wanted = await wantedLocales(for: language, maxAutomatic: maxAutomatic)
        guard !wanted.isEmpty else { return nil }
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let ready = wanted.filter { installed.contains($0.identifier(.bcp47)) }
        if language != MacDictation.automatic {
            return ready.count == wanted.count ? ready : nil
        }
        return ready.isEmpty ? nil : ready
    }

    /// Requested SpeechTranscriber locales that are supported by macOS but not yet downloaded.
    static func missingLocales(for language: String, maxAutomatic: Int = 4) async -> [Locale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        let wanted = await wantedLocales(for: language, maxAutomatic: maxAutomatic)
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        return wanted.filter { !installed.contains($0.identifier(.bcp47)) }
    }

    /// Downloads and installs Apple's on-device SpeechTranscriber models for `locales`.
    static func install(_ locales: [Locale], progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !locales.isEmpty else { progress(1); return }
        let wantedIDs = Set(locales.map { $0.identifier(.bcp47) })
        var reserved = await AssetInventory.reservedLocales
        let limit = AssetInventory.maximumReservedLocales
        for locale in locales where !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            if reserved.count >= limit, let evict = reserved.first(where: { !wantedIDs.contains($0.identifier(.bcp47)) }) {
                _ = await AssetInventory.release(reservedLocale: evict)
                reserved.removeAll { $0.identifier(.bcp47) == evict.identifier(.bcp47) }
            }
            if (try? await AssetInventory.reserve(locale: locale)) == true {
                reserved.append(locale)
            }
        }
        let modules = locales.map {
            SpeechTranscriber(locale: $0, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            let tracker = request.progress
            let monitor = Task {
                while !Task.isCancelled {
                    progress(tracker.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { monitor.cancel() }
            try await request.downloadAndInstall()
        }
        progress(1)
    }

    // MARK: Offline / Notetaker transcription

    private struct SegmentResult: Sendable {
        var text = ""
        var confidence = 0.0
        var words: [TimedWord] = []
    }

    /// 16 kHz mono samples → text in the highest-confidence locale among `locales`.
    static func transcribe(_ samples: [Float], locales: [Locale]) async throws -> String {
        guard !samples.isEmpty, !locales.isEmpty else { return "" }
        return try await bestSegment(samples, locales: locales).text
    }

    /// Words with timestamps for a recording: single-locale directly from file, or pause-split
    /// per-segment best-confidence language selection when multiple languages are active.
    static func words(in url: URL, locales: [Locale]) async throws -> [TimedWord] {
        guard !locales.isEmpty else { return [] }
        if locales.count == 1 {
            return try await transcribeFile(url, locale: locales[0]).words
        }
        let (samples, rate) = try readMonoSamples(from: url)
        guard !samples.isEmpty else { return [] }
        let segments = NoteBuilder.speechSegments(samples: samples, sampleRate: rate)
        var out: [TimedWord] = []
        for segment in segments {
            let slice = Array(samples[segment.range])
            let best = try await bestSegment(slice, locales: locales)
            for word in best.words {
                out.append(TimedWord(text: word.text, start: word.start + segment.start, end: word.end + segment.start))
            }
        }
        return out
    }

    private static func bestSegment(_ samples: [Float], locales: [Locale]) async throws -> SegmentResult {
        if locales.count == 1 {
            return try await transcribeSamples(samples, locale: locales[0])
        }
        return await withTaskGroup(of: SegmentResult?.self) { group in
            for locale in locales {
                group.addTask { try? await transcribeSamples(samples, locale: locale) }
            }
            var best: SegmentResult?
            for await candidate in group {
                guard let candidate, !candidate.text.isEmpty else { continue }
                if best == nil || candidate.confidence > best!.confidence { best = candidate }
            }
            return best ?? SegmentResult()
        }
    }

    private static func transcribeFile(_ url: URL, locale: Locale) async throws -> SegmentResult {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else { return SegmentResult() }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collecting = Task { try await collect(from: transcriber) }
        if let lastTime = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collecting.value
    }

    private static func transcribeSamples(_ samples: [Float], locale: Locale) async throws -> SegmentResult {
        var padded = samples
        padded.append(contentsOf: [Float](repeating: 0, count: 3_200))
        let sourceFormat = Resampler16k.format
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(padded.count)),
              let dst = source.floatChannelData?[0] else { return SegmentResult() }
        source.frameLength = AVAudioFrameCount(padded.count)
        padded.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { dst.update(from: base, count: padded.count) }
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                         considering: sourceFormat) ?? sourceFormat
        let buffer: AVAudioPCMBuffer
        if targetFormat == sourceFormat {
            buffer = source
        } else if let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
                  let converted = convert(source, with: converter, to: targetFormat,
                                          ratio: targetFormat.sampleRate / sourceFormat.sampleRate) {
            buffer = converted
        } else {
            return SegmentResult()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let collecting = Task { try await collect(from: transcriber) }
        try await analyzer.start(inputSequence: stream)
        input.yield(AnalyzerInput(buffer: buffer))
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collecting.value
    }

    private static func collect(from transcriber: SpeechTranscriber) async throws -> SegmentResult {
        var text = ""
        var total = 0.0
        var count = 0
        var words: [TimedWord] = []
        for try await result in transcriber.results {
            text = join(text, String(result.text.characters))
            for run in result.text.runs {
                if let confidence = run.transcriptionConfidence { total += confidence; count += 1 }
                let piece = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !piece.isEmpty else { continue }
                let range = run.audioTimeRange ?? result.range
                let start = range.start.seconds.isFinite ? max(0, range.start.seconds) : 0
                let end = range.end.seconds.isFinite ? max(start, range.end.seconds) : start
                let parts = piece.split(whereSeparator: \.isWhitespace)
                if parts.count <= 1 {
                    words.append(TimedWord(text: piece, start: start, end: end))
                } else {
                    let span = (end - start) / Double(parts.count)
                    for (i, part) in parts.enumerated() {
                        words.append(TimedWord(text: String(part), start: start + Double(i) * span,
                                               end: start + Double(i + 1) * span))
                    }
                }
            }
        }
        return SegmentResult(text: text, confidence: count > 0 ? total / Double(count) : 0, words: words)
    }

    private static func readMonoSamples(from url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0, format.sampleRate > 0 else { return ([], ChannelRecorder.sampleRate) }
        let resampler = format == Resampler16k.format ? nil : Resampler16k(from: format)
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return ([], ChannelRecorder.sampleRate) }
        var out: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }
            if let resampler {
                out.append(contentsOf: resampler.convert(buffer))
            } else if let data = buffer.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            }
        }
        return (out, ChannelRecorder.sampleRate)
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
