#if !APPSTORE
import AVFoundation
@preconcurrency import FluidAudio
import os

/// How Flow dictation turns the voice into text.
enum FlowEngine: String, CaseIterable, Identifiable {
    /// NVIDIA's Parakeet, run on the Mac's Neural Engine by FluidAudio: the most accurate, offline.
    case parakeet
    /// The Mac's own speech recognition (MacDictation).
    case apple

    var id: String { rawValue }
}

/// Parakeet (speech to text) and the speaker diarizer of the Notetaker: their models, downloaded
/// once from Hugging Face when the user clicks Download in Coucou Flow → Settings (≈ 650 MB),
/// kept in Application Support/NotchBuddy/Models, then everything runs on this Mac.
@MainActor
final class Parakeet: ObservableObject {
    static let shared = Parakeet()

    /// Parakeet Ultra: v3's 25 languages, more accurate than v3, same speed.
    nonisolated static let version: AsrModelVersion = .ultra

    enum State: Equatable {
        /// Intel Mac: the models need the Neural Engine of Apple silicon.
        case unsupported
        case missing
        case downloading(Double)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    private var loading: Task<AsrManager, Error>?

    private init() { refresh() }

    nonisolated static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Coucou's own copy of the models (not FluidAudio's shared folder, so removing them never
    /// touches another app's).
    nonisolated static var modelsRoot: URL {
        HookServer.supportDir.appendingPathComponent("Models", isDirectory: true)
    }

    nonisolated static var asrDirectory: URL {
        modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }

    nonisolated static var installed: Bool {
        AsrModels.modelsExist(at: asrDirectory, version: version)
    }

    var isReady: Bool { state == .ready }

    func refresh() {
        if !Self.isSupported { state = .unsupported; return }
        if case .downloading = state { return }
        state = Self.installed ? .ready : .missing
    }

    /// Downloads Parakeet and the diarizer, then loads Parakeet so the first dictation is quick.
    func download() {
        guard Self.isSupported else { return }
        if case .downloading = state { return }
        state = .downloading(0)
        Task { @MainActor in
            do {
                try await Self.fetchModels { fraction in
                    Task { @MainActor in
                        if case .downloading(let shown) = Parakeet.shared.state, fraction > shown {
                            Parakeet.shared.state = .downloading(fraction)
                        }
                    }
                }
                state = .ready
                appendAppLog("nb.log", "[Parakeet] models downloaded")
                _ = try? await manager()
            } catch {
                appendAppLog("nb.log", "[Parakeet] download failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    nonisolated private static func fetchModels(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        _ = try await AsrModels.download(to: asrDirectory, version: version, progressHandler: { update in
            progress(min(0.92, update.fractionCompleted * 0.92))
        })
        try await prepareDiarizer()
        progress(1)
    }

    /// Downloads (once) and loads the Notetaker's speaker diarizer.
    nonisolated static func prepareDiarizer() async throws {
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels(directory: modelsRoot)
    }

    /// Removes the models from this Mac (Settings → Remove).
    func remove() {
        loading?.cancel()
        loading = nil
        try? FileManager.default.removeItem(at: Self.modelsRoot)
        refresh()
    }

    /// Loads Parakeet once; later calls get the same instance.
    func manager() async throws -> AsrManager {
        if let loading { return try await loading.value }
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.load(from: Self.asrDirectory, version: Self.version)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            return asr
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    /// Loads the model in the background when dictation will use it, so the first one is quick.
    func preload() {
        guard state == .ready, loading == nil else { return }
        Task { @MainActor in _ = try? await manager() }
    }

    /// 16 kHz mono samples → text.
    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribeWithTimings(samples).text
    }

    func transcribeWithTimings(_ samples: [Float]) async throws -> ASRResult {
        var audio = samples
        // Parakeet wants at least a second, and a little silence at the end keeps the last word.
        audio.append(contentsOf: [Float](repeating: 0, count: max(4_800, 16_000 - audio.count)))
        let asr = try await manager()
        var decoder = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(audio, decoderState: &decoder)
    }
}

// MARK: - 16 kHz mono

/// Turns the microphone's or the Mac's audio, in whatever format it comes, into the 16 kHz mono
/// Float32 samples Parakeet and the diarizer take. Fed from one audio thread at a time.
final class Resampler16k: @unchecked Sendable {
    nonisolated(unsafe) static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                          channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, let converter = AVAudioConverter(from: input, to: Self.format) else { return nil }
        converter.downmix = true
        self.converter = converter
        ratio = 16_000 / input.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
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
        guard status != .error, let data = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}

// MARK: - Dictation with Parakeet

/// Flow dictation with Parakeet: the microphone is recorded while the key is held, then Parakeet
/// writes it all at once (a few hundred milliseconds for a minute of speech). Only the microphone
/// permission is needed; nothing leaves the Mac.
final class ParakeetDictation: @unchecked Sendable {
    @MainActor private(set) var isRecording = false
    /// Flow dictation's pill: the microphone's levels by frequency.
    var bands: FlowAudioBands?

    private let engine = AVAudioEngine()
    private let samples = OSAllocatedUnfairLock(initialState: [Float]())

    @MainActor func start() async {
        guard !isRecording, await AVAudioApplication.requestRecordPermission() else { return }
        samples.withLock { $0.removeAll(keepingCapacity: true) }
        guard Self.startEngine(engine, into: samples, bands: bands) else { return }
        isRecording = true
        NotificationCenter.default.post(name: .dictationDidStart, object: nil)
    }

    /// Stops the microphone and returns the words.
    @MainActor func finish() async -> String {
        guard isRecording else { return "" }
        stopEngine()
        let audio = samples.withLock { $0 }
        do {
            return try await Parakeet.shared.transcribe(audio)
        } catch {
            appendAppLog("nb.log", "[Parakeet] dictation failed: \(error.localizedDescription)")
            return ""
        }
    }

    /// Stops without words (Esc, another key).
    @MainActor func stop() {
        guard isRecording else { return }
        stopEngine()
        samples.withLock { $0.removeAll() }
    }

    @MainActor private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        NotificationCenter.default.post(name: .dictationDidEnd, object: nil)
    }

    nonisolated private static func startEngine(_ engine: AVAudioEngine, into samples: OSAllocatedUnfairLock<[Float]>,
                                                bands: FlowAudioBands?) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = Resampler16k(from: format) else { return false }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            bands?.consume(buffer)
            let out = resampler.convert(buffer)
            if !out.isEmpty { samples.withLock { $0.append(contentsOf: out) } }
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }
}
#endif
