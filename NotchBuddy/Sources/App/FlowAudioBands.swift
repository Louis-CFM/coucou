#if !APPSTORE
import Accelerate
import AVFoundation
import os

/// Turns the microphone's buffers into nine levels (0…1) for the pill's dots, from the graves on
/// the left to the aigus on the right. Fed from the audio tap's thread, read by the pill at 60 fps;
/// the levels sit behind a lock. Nothing is kept: only the latest nine numbers.
final class FlowAudioBands: @unchecked Sendable {
    static let fftSize = 1024
    private let log2n = vDSP_Length(10)
    private let fft: vDSP.FFT<DSPSplitComplex>?
    private let window: [Float]
    private let lock = OSAllocatedUnfairLock(initialState: [Float](repeating: 0, count: FlowBands.count))
    private var ranges: [Range<Int>] = []
    private var rate: Double = 0
    // Scratch, used only on the tap's thread.
    private var frame = [Float](repeating: 0, count: FlowAudioBands.fftSize)
    private var real = [Float](repeating: 0, count: FlowAudioBands.fftSize / 2)
    private var imag = [Float](repeating: 0, count: FlowAudioBands.fftSize / 2)
    private var power = [Float](repeating: 0, count: FlowAudioBands.fftSize / 2)

    init() {
        fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.fftSize, isHalfWindow: false)
    }

    /// The latest levels, graves first.
    var levels: [Float] { lock.withLock { $0 } }

    func reset() { lock.withLock { $0 = [Float](repeating: 0, count: FlowBands.count) } }

    /// Called on the audio tap's thread for every buffer.
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let fft, let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n >= Self.fftSize else { return }
        let sampleRate = buffer.format.sampleRate
        if sampleRate != rate {
            rate = sampleRate
            ranges = FlowBands.binRanges(fftSize: Self.fftSize, sampleRate: sampleRate)
        }
        // The last 1024 samples of the buffer: the freshest sound.
        let start = n - Self.fftSize
        for i in 0..<Self.fftSize { frame[i] = data[start + i] * window[i] }

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { fp in
                    fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                var spectrum = split          // the same buffers: vDSP transforms in place
                fft.forward(input: split, output: &spectrum)
                vDSP.squareMagnitudes(spectrum, result: &power)
            }
        }
        // vDSP's real FFT is scaled by 2; with the Hann window, a full-scale sine comes out near 0 dB.
        let scale = Float(1.0 / Double(Self.fftSize * Self.fftSize))
        var out = [Float](repeating: 0, count: FlowBands.count)
        for (i, range) in ranges.enumerated() {
            var sum: Float = 0
            for b in range where b < power.count { sum += power[b] }
            let db = 10 * log10(Double(max(sum * scale, 1e-12)))
            // Speech is weaker in the aigus: a little tilt so the right-hand dots move too.
            out[i] = Float(FlowBands.level(db: db + Double(i) * 2.2))
        }
        let latest = out
        lock.withLock { $0 = latest }
    }
}
#endif
