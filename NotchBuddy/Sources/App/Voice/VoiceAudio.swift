#if !APPSTORE
import AVFoundation

// MARK: - VoiceAudio
//
// Wraps AVAudioEngine to deliver a low-level audio tap for voice detection.
//
// Thread model:
// - `start()` / `stop()` / `resetVAD()` called on the main thread.
// - `onVoiceStart`, `onVoiceEnd`, `onMicLevel`, `onConfigChange` dispatched to the main thread.
// - `onBuffer` called on the audio tap thread — its closure must be thread-safe.
//
// VAD modes:
// - Normal (wake): EnergyVAD drives `onVoiceStart`/`onVoiceEnd`.
// - Bypass (`bypassVAD = true`): every buffer is delivered via `onBuffer` regardless of
//   silence; `onMicLevel` fires at ~20 Hz with a smoothed level.
//
// Audio format:
// - Input format is whatever the mic reports (48 kHz 1ch on most Macs, varies by device).
// - Buffers delivered to `onBuffer` / stored in preroll are converted to mono 16 kHz Float32
//   via an AVAudioConverter created once on start. VAD and level metering use the raw format.
final class VoiceAudio: @unchecked Sendable {

    private let engine         = AVAudioEngine()
    private var tapInstalled   = false
    private var configObserver: NSObjectProtocol? = nil

    // Mono 16 kHz Float32 converter — created once per input format, audio tap thread.
    private var converter: AVAudioConverter?

    // VAD — read/written only on the audio tap thread.
    private var vad = EnergyVAD()

    // Smoothed mic level during bypass mode — audio tap thread.
    private var smoothedLevel:  Double = 0
    private var levelFrameCount = 0

    // Pre-roll circular buffer (~500 ms).
    // Read on main (via `drainPreroll()`), written on audio tap thread.
    private let prerollLock    = NSLock()
    private var prerollBuffers: [AVAudioPCMBuffer] = []
    private static let prerollCapacity = 22   // ~500 ms at 43 Hz

    /// Last time a buffer was processed in the tap (audio tap thread).
    /// Read on main for stall detection — nonisolated for cross-thread access.
    nonisolated(unsafe) private(set) var lastBufferTime: Date = .distantPast

    /// When true, every audio buffer is delivered via `onBuffer` regardless of VAD.
    nonisolated(unsafe) var bypassVAD: Bool = false

    /// Set on the main thread after a command ends; consumed by the audio tap thread.
    nonisolated(unsafe) private var pendingVADReset: Bool = false

    // MARK: Callbacks

    var onVoiceStart:   (() -> Void)?
    var onVoiceEnd:     (() -> Void)?
    /// Called on the audio tap thread.
    var onBuffer:       ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var onMicLevel:     ((Double) -> Void)?
    /// Fired on the main thread when AVAudioEngine reports a configuration change
    /// (headphone connect/disconnect, sample-rate change, etc.).
    var onConfigChange: (() -> Void)?

    // MARK: - Control

    func start() throws {
        guard !tapInstalled else { return }

        let input = engine.inputNode
        let fmt   = input.outputFormat(forBus: 0)

        // Build a stateful mono 16 kHz Float32 converter for the recognizer.
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        if let conv = AVAudioConverter(from: fmt, to: target) {
            conv.primeMethod = .none
            conv.downmix      = true   // collapse multi-channel mic (e.g. 3ch) to mono
            converter = conv
            appendAppLog("nb.log",
                "[Voice] audio format: input \(Int(fmt.sampleRate)) Hz \(fmt.channelCount)ch → 16000 Hz 1ch")
        } else {
            appendAppLog("nb.log",
                "[Voice] audio converter unavailable: \(Int(fmt.sampleRate)) Hz \(fmt.channelCount)ch — feeding raw")
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, time in
            self?.processTap(buf, time: time)
        }
        tapInstalled = true

        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            self?.onConfigChange?()
        }

        engine.prepare()
        try engine.start()
        appendAppLog("nb.log", "[Voice] engine started (\(Int(fmt.sampleRate)) Hz \(fmt.channelCount)ch)")
    }

    func stop() {
        guard tapInstalled else { return }
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled   = false
        converter      = nil
        prerollLock.withLock { prerollBuffers.removeAll() }
        if vad.isActive {
            vad.reset()
            DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        }
    }

    func resetVAD() { pendingVADReset = true }

    func drainPreroll() -> [AVAudioPCMBuffer] {
        prerollLock.withLock {
            let snap = prerollBuffers
            prerollBuffers.removeAll()
            return snap
        }
    }

    // MARK: - Tap processing (audio thread)

    private func processTap(_ buf: AVAudioPCMBuffer, time: AVAudioTime) {
        lastBufferTime = Date()

        if pendingVADReset {
            pendingVADReset = false
            vad.reset()
            smoothedLevel   = 0
            levelFrameCount = 0
        }

        // Convert to mono 16 kHz for the recognizer; fall back to raw if converter absent.
        let deliverBuf = convertToMono16k(buf) ?? buf

        prerollLock.withLock {
            if prerollBuffers.count >= Self.prerollCapacity { prerollBuffers.removeFirst() }
            prerollBuffers.append(deliverBuf)
        }

        if bypassVAD {
            onBuffer?(deliverBuf, time)
            let power = buf.meanSquarePower   // raw format for accuracy
            smoothedLevel = smoothedLevel * 0.6 + power * 0.4
            levelFrameCount += 1
            if levelFrameCount % 2 == 0 {
                let level = min(1.0, smoothedLevel * 2000)
                DispatchQueue.main.async { [weak self] in self?.onMicLevel?(level) }
            }
            return
        }

        let power = buf.meanSquarePower   // raw format for accuracy
        let event = vad.feed(power)

        switch event {
        case .start:
            DispatchQueue.main.async { [weak self] in self?.onVoiceStart?() }
        case .end:
            DispatchQueue.main.async { [weak self] in self?.onVoiceEnd?() }
        case .none:
            break
        }

        if vad.isActive { onBuffer?(deliverBuf, time) }
    }

    // MARK: - Conversion

    private func convertToMono16k(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let conv = converter else { return nil }
        let ratio      = conv.outputFormat.sampleRate / buf.format.sampleRate
        let outFrames  = AVAudioFrameCount(ceil(Double(buf.frameLength) * ratio)) + 16
        guard let out  = AVAudioPCMBuffer(pcmFormat: conv.outputFormat,
                                          frameCapacity: max(1, outFrames)) else { return nil }
        var provided   = false
        var convError: NSError?
        let status = conv.convert(to: out, error: &convError) { _, outStatus in
            guard !provided else { outStatus.pointee = .noDataNow; return nil }
            provided = true
            outStatus.pointee = .haveData
            return buf
        }
        guard status != .error, convError == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

// MARK: - AVAudioPCMBuffer mean-square power

private extension AVAudioPCMBuffer {
    var meanSquarePower: Double {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        let frames = Int(frameLength)
        let chans  = Int(format.channelCount)
        var sum: Double = 0
        for ch in 0..<chans {
            let p = data[ch]
            for i in 0..<frames { let s = Double(p[i]); sum += s * s }
        }
        return sum / Double(frames * max(1, chans))
    }
}
#endif
