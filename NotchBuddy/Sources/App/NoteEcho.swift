import Foundation

/// Without headphones, the others' voices come out of the speakers and back into the microphone,
/// and Parakeet writes them as yours (often heard a little differently, so comparing the words is
/// not enough). The Mac's own sound is the reference: where the microphone holds no more energy
/// than the echo of that sound explains, what it heard is the others, not you.
/// Pure functions on 16 kHz samples (tests/NoteModelsTests.swift).
enum NoteEcho {
    /// Levels are measured on 20 ms frames.
    static let frameSeconds = 0.02
    /// How much louder than the echo the microphone must be for a word to be yours (≈ 10 dB).
    static let margin: Float = 3
    /// The microphone lags behind what the Mac plays: searched from -100 ms to +500 ms.
    static let lags = -5...25

    struct Analysis: Sendable {
        /// Frames the microphone lags behind the Mac's sound.
        var lag: Int
        /// The microphone's level for one unit of the Mac's sound: the echo's strength (≈ 0 with headphones).
        var gain: Float
        /// Below this, the Mac plays nothing.
        var sysActive: Float
        /// The microphone's level in silence.
        var micFloor: Float
        var mic: [Float]
        var sys: [Float]
    }

    /// RMS level of each 20 ms frame.
    static func levels(_ samples: [Float], sampleRate: Double = 16_000) -> [Float] {
        let size = Int(sampleRate * frameSeconds)
        guard size > 0, !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / size + 1)
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + size)
            var sum: Float = 0
            for k in index..<end { sum += samples[k] * samples[k] }
            out.append((sum / Float(end - index)).squareRoot())
            index = end
        }
        return out
    }

    static func percentile(_ values: [Float], _ p: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[index]
    }

    /// How the Mac's sound reaches the microphone: the delay and the strength of the echo.
    /// nil when the Mac played too little sound to tell.
    static func analyze(mic: [Float], sys: [Float]) -> Analysis? {
        guard !mic.isEmpty, !sys.isEmpty else { return nil }
        let sysActive = max(0.004, percentile(sys, 0.1) * 4)
        let active = sys.indices.filter { sys[$0] > sysActive }
        guard active.count >= 50 else { return nil }
        let micFloor = percentile(mic, 0.1)

        // The delay: where the microphone's levels follow the Mac's best.
        var best = (lag: 0, corr: -Float.infinity)
        for lag in lags {
            var xs: [Float] = [], ys: [Float] = []
            for t in active where t + lag >= 0 && t + lag < mic.count {
                xs.append(sys[t])
                ys.append(mic[t + lag])
            }
            guard xs.count >= 50 else { continue }
            let corr = pearson(xs, ys)
            if corr > best.corr { best = (lag, corr) }
        }

        // The echo's strength: while only the others speak, the microphone is the Mac's sound times
        // this. When you speak over them the ratio is far higher, so a low percentile skips those moments.
        var ratios: [Float] = []
        for t in active where t + best.lag >= 0 && t + best.lag < mic.count {
            ratios.append(mic[t + best.lag] / sys[t])
        }
        guard ratios.count >= 50 else { return nil }
        return Analysis(lag: best.lag, gain: percentile(ratios, 0.35), sysActive: sysActive,
                        micFloor: micFloor, mic: mic, sys: sys)
    }

    /// For one frame of the microphone: nil when the Mac plays nothing then, true when the
    /// microphone holds nothing more than the echo.
    static func isEcho(frame f: Int, in a: Analysis) -> Bool? {
        let t = f - a.lag
        guard f >= 0, f < a.mic.count, t >= 0, t < a.sys.count, a.sys[t] > a.sysActive else { return nil }
        return a.mic[f] <= margin * a.gain * a.sys[t] + 2 * a.micFloor
    }

    /// Which of the microphone's words are the echo of the others.
    static func echoWords(_ words: [TimedWord], analysis a: Analysis) -> [Bool] {
        var flags = words.map { word -> Bool in
            let first = max(0, Int(((word.start - 0.04) / frameSeconds).rounded(.down)))
            let last = max(first, Int(((word.end + 0.04) / frameSeconds).rounded(.up)))
            var active = 0, echo = 0
            for f in first...last {
                guard let isEcho = isEcho(frame: f, in: a) else { continue }
                active += 1
                if isEcho { echo += 1 }
            }
            let frames = last - first + 1
            return active * 2 >= frames && Double(echo) >= Double(active) * 0.6
        }
        // A lone word in the middle of the other kind, close to both neighbours, goes with them.
        let original = flags
        if words.count >= 3 {
            for i in 1..<(words.count - 1) where original[i - 1] == original[i + 1] && original[i] != original[i - 1] {
                if words[i].start - words[i - 1].end < 0.6, words[i + 1].start - words[i].end < 0.6 {
                    flags[i] = original[i - 1]
                }
            }
        }
        return flags
    }

    /// The microphone's words without the echo, from both recordings' levels.
    static func removing(_ words: [TimedWord], micLevels: [Float], sysLevels: [Float]) -> (words: [TimedWord], removed: Int) {
        guard let analysis = analyze(mic: micLevels, sys: sysLevels) else { return (words, 0) }
        let flags = echoWords(words, analysis: analysis)
        let kept = zip(words, flags).filter { !$0.1 }.map(\.0)
        return (kept, words.count - kept.count)
    }

    static func removing(_ words: [TimedWord], micSamples: [Float], sysSamples: [Float]) -> (words: [TimedWord], removed: Int) {
        removing(words, micLevels: levels(micSamples), sysLevels: levels(sysSamples))
    }

    private static func pearson(_ xs: [Float], _ ys: [Float]) -> Float {
        let n = Float(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in xs.indices {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }
}
