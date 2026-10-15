#if !APPSTORE
import AudioToolbox
import AVFoundation
import CoreAudio
import os

/// One side of a call (your microphone, or what the Mac plays): written to a 16 kHz WAV file as
/// it comes, with the stretch not transcribed yet kept in memory for the live transcript.
final class ChannelRecorder: @unchecked Sendable {
    static let sampleRate = 16_000.0

    let url: URL
    private let queue: DispatchQueue
    /// Touched on `queue` only.
    private var file: AVAudioFile?

    private struct Live {
        var pending: [Float] = []
        /// Where `pending` starts, in seconds from the start of the recording.
        var pendingStart = 0.0
        var total = 0
        var level: Float = 0
        /// Seconds with sound in them, to tell an empty side (no call, no headphones) from a real one.
        var voiced = 0.0
    }
    private let live = OSAllocatedUnfairLock(initialState: Live())

    init(url: URL, label: String) throws {
        self.url = url
        queue = DispatchQueue(label: label, qos: .userInitiated)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// From the audio thread.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let rms = Self.rms(samples[...])
        live.withLock { state in
            state.pending.append(contentsOf: samples)
            state.total += samples.count
            state.level = rms
            if rms > 0.01 { state.voiced += Double(samples.count) / Self.sampleRate }
        }
        queue.async { [self] in
            guard let file,
                  let buffer = AVAudioPCMBuffer(pcmFormat: Resampler16k.format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
            }
            try? file.write(from: buffer)
        }
    }

    var level: Float { live.withLock { $0.level } }
    var voicedSeconds: Double { live.withLock { $0.voiced } }

    /// The stretch not transcribed yet, once it is long enough and ends on a pause (or has become
    /// too long to wait). Silent stretches are dropped without a word.
    func takeChunk(minSeconds: Double = 4, maxSeconds: Double = 18, force: Bool = false) -> (start: Double, samples: [Float])? {
        live.withLock { state -> (start: Double, samples: [Float])? in
            let seconds = Double(state.pending.count) / Self.sampleRate
            guard seconds >= (force ? 0.5 : minSeconds) else { return nil }
            let tail = state.pending.suffix(Int(Self.sampleRate / 2))
            guard force || Self.rms(tail) < 0.012 || seconds >= maxSeconds else { return nil }
            let chunk = (start: state.pendingStart, samples: state.pending)
            state.pendingStart = Double(state.total) / Self.sampleRate
            state.pending.removeAll(keepingCapacity: true)
            return Self.rms(chunk.samples[...]) < 0.004 ? nil : chunk
        }
    }

    /// Closes the file at once, waiting for what is queued (when Coucou quits).
    func closeNow() {
        queue.sync { file = nil }
    }

    /// Closes the file once everything queued is written.
    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                file = nil
                continuation.resume()
            }
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - Microphone

/// The microphone, as 16 kHz mono samples.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(sink: @escaping @Sendable ([Float]) -> Void) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = Resampler16k(from: format) else { return false }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            sink(resampler.convert(buffer))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - The Mac's sound

/// Everything the Mac plays (the other people of a call, whatever the app), through a Core Audio
/// process tap (macOS 14.2+). macOS asks once for the "System Audio Recording" permission.
/// Nothing is muted: you keep hearing the call.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .failed(let step, let status): return "\(step) (\(status))"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The tap's own buffers, when the aggregate also brings the output device's inputs (a headset's mic).
    private var tapList: UnsafeMutableAudioBufferListPointer?
    private let queue = DispatchQueue(label: "fr.louisraille.NotchBuddy.notetaker.system", qos: .userInitiated)

    func start(sink: @escaping @Sendable ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Coucou Notetaker"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.failed("process tap", status) }
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var description16 = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &description16)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &description16),
              let resampler = Resampler16k(from: format) else {
            stop()
            throw TapError.failed("tap format", status)
        }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Coucou Notetaker",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            stop()
            throw TapError.failed("aggregate device", status)
        }
        aggregateID = device

        // The aggregate's input is the output device's own inputs (a headset's microphone), if it has
        // any, then the tap: the tap's buffers are the last ones.
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let scratch = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        tapList = scratch
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var list = input
            if all.count > tapBuffers {
                for i in 0..<tapBuffers { scratch[i] = all[all.count - tapBuffers + i] }
                list = UnsafePointer(scratch.unsafePointer)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
            sink(resampler.convert(buffer))
        }
        guard status == noErr, let proc else {
            stop()
            throw TapError.failed("io proc", status)
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            stop()
            throw TapError.failed("start", status)
        }
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        if let tapList { free(tapList.unsafeMutablePointer) }
        tapList = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { throw TapError.failed("output device", status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.stride)
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw TapError.failed("output device uid", status) }
        return uid as String
    }
}
#endif
