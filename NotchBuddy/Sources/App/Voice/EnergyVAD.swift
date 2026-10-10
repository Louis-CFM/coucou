import Foundation

// MARK: - EnergyVAD
//
// Pure energy-based voice-activity detector.
// No AVFoundation dependency; usable in standalone test scripts.
//
// Algorithm:
//   - Calibration phase (~0.5 s): fast noise-floor learning, no triggers.
//   - After calibration: noise floor drifts slowly; rise when power > noise×8.
//   - Max segment (~30 s): forces an end so the VAD never stays permanently active.
//   - reset() after a command ends: clears activity counters, preserves the learned
//     noise floor so the next speech cycle starts from a valid baseline.

struct EnergyVAD {

    enum Event { case none, start, end }

    // MARK: - Tunables
    static let calibFrames     = 22     // ≈ 0.5 s at 43 Hz before triggering
    static let riseRatio       = 8.0    // power/noise to start a segment
    static let fallRatio       = 2.0    // power/noise to count silence
    static let silenceFrames   = 35     // ≈ 800 ms at 43 Hz
    static let maxActiveFrames = 1300   // ≈ 30 s safety limit

    // MARK: - Readable state
    private(set) var isActive:   Bool   = false
    private(set) var noisePower: Double = 1e-7

    // MARK: - Internal counters
    private var calibCount  = 0
    private var silentCount = 0
    private var activeCount = 0

    // Power accumulator for the current active segment (used to update noise on forced end).
    private var segmentPowerSum:   Double = 0
    private var segmentPowerCount: Int    = 0

    // MARK: - API

    /// Hard-reset to inactive. Preserves the calibrated noise floor.
    /// Call after a command ends so the next speech triggers a fresh VAD start.
    mutating func reset() {
        isActive          = false
        silentCount       = 0
        activeCount       = 0
        segmentPowerSum   = 0
        segmentPowerCount = 0
        // noisePower/calibCount: keep — calibration is done, ambient is known.
    }

    /// Feed one frame's mean-square power. Returns whether a segment started/ended.
    mutating func feed(_ power: Double) -> Event {
        // Phase 1 — fast calibration: converge noisePower to ambient in ~0.5 s.
        if calibCount < Self.calibFrames {
            calibCount += 1
            noisePower  = noisePower * 0.85 + power * 0.15
            return .none
        }

        if !isActive {
            noisePower = noisePower * 0.995 + power * 0.005
            if power > noisePower * Self.riseRatio {
                isActive          = true
                silentCount       = 0
                activeCount       = 0
                segmentPowerSum   = power
                segmentPowerCount = 1
                return .start
            }
            return .none
        } else {
            activeCount       += 1
            segmentPowerSum   += power
            segmentPowerCount += 1
            if activeCount >= Self.maxActiveFrames {
                // Update noise floor to the average power of this forced-end segment
                // (continuous music/noise → treat it as new ambient level).
                if segmentPowerCount > 0 {
                    noisePower = segmentPowerSum / Double(segmentPowerCount)
                }
                isActive          = false
                silentCount       = 0
                activeCount       = 0
                segmentPowerSum   = 0
                segmentPowerCount = 0
                return .end
            }
            if power < noisePower * Self.fallRatio {
                silentCount += 1
                noisePower = noisePower * 0.999 + power * 0.001
                if silentCount >= Self.silenceFrames {
                    isActive    = false
                    silentCount = 0
                    activeCount = 0
                    return .end
                }
            } else {
                silentCount = 0
            }
            return .none
        }
    }
}
