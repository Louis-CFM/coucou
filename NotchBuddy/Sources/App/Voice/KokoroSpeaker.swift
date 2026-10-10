#if !APPSTORE
import Foundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

// MARK: - KokoroSpeaker
//
// Generates WAV audio from text using the locally installed Kokoro-82M MLX model.
// Heavy work (model loading, synthesis) runs on KokoroEngine (a background actor) so the
// main actor is never blocked. Returns Data? to VoiceSpeaker, which plays it with
// AVAudioPlayer — same path as ElevenLabs; nil falls back to the Mac voice.
//
// Cold-start latency (~2–4 s on Apple Silicon) only on the first call after launch or
// after an idle unload. Subsequent sentences are fast (~0.3–1 s).
// Pipelining: VoiceSpeaker starts Task { await audio(for: sentence) } at enqueue time,
// so sentence N+1 generates while sentence N plays.
//
// Idle unload: model released after 5 minutes of silence to free ~350 MB of RAM.
// Voices: af_heart (female) and am_michael (male), English only.

@MainActor
final class KokoroSpeaker {
    static let shared = KokoroSpeaker()

    @MainActor static var isActive: Bool {
        VoiceSettings.ttsEngine == "kokoro" && KokoroModelManager.shared.isDownloaded
    }

    private let engine    = KokoroEngine()
    private var idleTimer: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Generate WAV audio for `text`. Returns nil on any error; caller falls back to Mac TTS.
    func audio(for text: String) async -> Data? {
        guard KokoroModelManager.shared.isDownloaded else { return nil }
        resetIdleTimer()
        let voiceName = VoiceSettings.elevenGender == "male" ? "am_michael.npy" : "af_heart.npy"
        let modelURL  = KokoroModelManager.shared.modelURL
        let voicesURL = KokoroModelManager.shared.voicesURL
        do {
            try await engine.loadIfNeeded(modelURL: modelURL, voicesURL: voicesURL)
            let chunks = splitSentences(text)
            var all: [Float] = []
            let gap = [Float](repeating: 0, count: 3_600)   // 0.15 s silence @ 24 kHz
            for (i, chunk) in chunks.enumerated() {
                let s = try await engine.generate(text: chunk, voiceName: voiceName)
                all.append(contentsOf: s)
                if i < chunks.count - 1 { all.append(contentsOf: gap) }
            }
            return floatsToWAV(all)
        } catch {
            appendAppLog("nb.log", "[Kokoro] \(error)")
            return nil
        }
    }

    /// Release the model from memory. Called by the idle timer and when the model is deleted.
    func unload() {
        idleTimer?.cancel()
        idleTimer = nil
        Task { await engine.unload() }
    }

    // MARK: - Private

    private func resetIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.unload()
        }
    }

    /// Split at sentence terminators to stay well under Kokoro's 510-token limit.
    private func splitSentences(_ text: String) -> [String] {
        var result: [String] = []
        var buf = ""
        for ch in text {
            buf.append(ch)
            if (ch == "." || ch == "!" || ch == "?") && buf.count > 12 {
                let s = buf.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { result.append(s) }
                buf = ""
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [text] : result
    }
}

// MARK: - KokoroEngine  (all heavy work runs off the main actor)

private actor KokoroEngine {
    private var tts:    KokoroTTS?
    private var voices: [String: MLXArray] = [:]

    /// Loads the model and voices on first call; no-op on subsequent calls.
    func loadIfNeeded(modelURL: URL, voicesURL: URL) throws {
        if tts == nil {
            tts = KokoroTTS(modelPath: modelURL)
        }
        if voices.isEmpty {
            guard let v = NpyzReader.read(fileFromPath: voicesURL), !v.isEmpty else {
                throw KokoroError.voicesUnavailable
            }
            voices = v
        }
    }

    func generate(text: String, voiceName: String) throws -> [Float] {
        guard let tts else { throw KokoroError.modelNotLoaded }
        guard let voice = voices[voiceName] else {
            throw KokoroError.voiceNotFound(voiceName)
        }
        let (samples, _) = try tts.generateAudio(voice: voice, language: .enUS, text: text)
        return samples
    }

    func unload() {
        tts    = nil
        voices = [:]
    }
}

// MARK: - Errors

private enum KokoroError: Error, CustomStringConvertible {
    case modelNotLoaded
    case voicesUnavailable
    case voiceNotFound(String)

    var description: String {
        switch self {
        case .modelNotLoaded:       return "Kokoro model not loaded"
        case .voicesUnavailable:    return "voices.npz unavailable or empty"
        case .voiceNotFound(let n): return "voice '\(n)' not found in voices.npz"
        }
    }
}

// MARK: - WAV encoder  (IEEE Float32, 24000 Hz, mono)

private func floatsToWAV(_ samples: [Float]) -> Data {
    let sr: UInt32  = 24000
    let ch: UInt16  = 1
    let bps: UInt16 = 32
    let byteRate    = sr * UInt32(ch) * UInt32(bps / 8)
    let blockAlign  = ch * (bps / 8)
    let dataSize    = UInt32(samples.count * MemoryLayout<Float>.stride)
    var out = Data(capacity: 44 + Int(dataSize))

    func w<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }
    func tag(_ s: String) { out.append(contentsOf: s.utf8) }

    tag("RIFF"); w(36 + dataSize); tag("WAVE")
    tag("fmt "); w(UInt32(16));    w(UInt16(3))   // IEEE_FLOAT
    w(ch); w(sr); w(byteRate); w(blockAlign); w(bps)
    tag("data"); w(dataSize)
    samples.withUnsafeBytes { out.append(contentsOf: $0) }
    return out
}
#endif
