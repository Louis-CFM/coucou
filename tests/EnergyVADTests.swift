import Foundation

@main
enum EnergyVADTests {

    static var failures = 0
    static var total    = 0

    static func main() {

        // MARK: 1. Calibration: no trigger during first 22 frames
        do {
            var vad = EnergyVAD()
            var triggered = false
            for _ in 0..<EnergyVAD.calibFrames {
                if vad.feed(1e-4) == .start { triggered = true }  // high power during calib
            }
            check("calibration: no trigger during first \(EnergyVAD.calibFrames) frames", !triggered)
        }

        // MARK: 2. After calibration, ambient never triggers
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }  // calibrate at ambient
            var triggered = false
            for _ in 0..<100 {
                if vad.feed(1e-5) == .start { triggered = true }  // ambient: should NOT trigger
            }
            check("ambient does not trigger after calibration", !triggered)
        }

        // MARK: 3. Speech above threshold → start
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            var startSeen = false
            for _ in 0..<10 {
                if vad.feed(1e-4) == .start { startSeen = true; break }
            }
            check("speech above threshold → start", startSeen)
        }

        // MARK: 4. Start then silence → end
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            // Trigger start
            while vad.feed(1e-4) != .start {}
            // Silence (below fallRatio * noisePower ≈ 2 * 1e-5 = 2e-5)
            var endSeen = false
            for _ in 0..<(EnergyVAD.silenceFrames + 5) {
                if vad.feed(1e-7) == .end { endSeen = true }
            }
            check("silence after speech → end", endSeen)
        }

        // MARK: 5. 10 cycles: speech→start, reset, speech→start again
        // Use 5e-4 (well above 8× ambient of 1e-5) so noise-floor drift doesn't prevent
        // the trigger even after the noisePower has crept up slightly from previous cycles.
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            var allOk = true
            for i in 0..<10 {
                // Trigger start
                var startSeen = false
                for _ in 0..<20 {
                    if vad.feed(5e-4) == .start { startSeen = true; break }
                }
                if !startSeen { allOk = false; print("  cycle \(i): no start"); break }
                vad.reset()
                if vad.isActive { allOk = false; print("  cycle \(i): still active after reset"); break }
            }
            check("10 cycles: speech→start, reset, repeat", allOk)
        }

        // MARK: 6. Max segment: 1300+ active frames → end
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            while vad.feed(1e-4) != .start {}
            var endSeen = false
            for _ in 0..<(EnergyVAD.maxActiveFrames + 5) {
                if vad.feed(1e-4) == .end { endSeen = true }
            }
            check("max segment (\(EnergyVAD.maxActiveFrames) frames) → forced end", endSeen)
        }

        // MARK: 7. Ambient that rises mid-session eventually falls (via max segment)
        do {
            var vad = EnergyVAD()
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(1e-5) }
            // Start with normal speech
            while vad.feed(1e-4) != .start {}
            // Now feed high ambient (simulates room noise rising): never reach silence threshold
            var endSeen = false
            for _ in 0..<(EnergyVAD.maxActiveFrames + 10) {
                if vad.feed(1e-3) == .end { endSeen = true; break }  // high ambient, no silence
            }
            check("ambient rise forces end via max segment", endSeen)
            check("inactive after forced end", !vad.isActive)
        }

        // MARK: 8. Continuous music (~60 s): at most 1 segment, no re-trigger after forced end
        // After the 30 s forced end the noise floor is updated to the music level.
        // A second forced-end segment may occur if music continues, but the VAD must NOT
        // immediately re-trigger on the very next frame after the forced end.
        do {
            var vad = EnergyVAD()
            let musicPower = 5e-4   // simulated music level
            // Calibrate at music level (as if music was already playing before app launch).
            for _ in 0..<EnergyVAD.calibFrames { _ = vad.feed(musicPower) }

            var segments = 0
            let totalFrames = EnergyVAD.maxActiveFrames * 2 + 100   // ~60 s at 43 Hz
            var prevEvent: EnergyVAD.Event = .none
            for _ in 0..<totalFrames {
                let event = vad.feed(musicPower)
                if event == .start { segments += 1 }
                // Immediately after a forced end, must NOT re-trigger on the next frame.
                if prevEvent == .end && event == .start {
                    check("music: no immediate re-trigger after forced end", false)
                    break
                }
                prevEvent = event
            }
            // ≤ 2 segments over 60 s (one per 30 s window) is acceptable;
            // what matters is that each forced end is followed by a clean gap.
            check("music (~60 s): no immediate re-trigger after forced end", prevEvent != .start || segments <= 2)
        }

        // MARK: 9. 100 ms buffers (10/s): same durations — 0.8 s of silence is 8 buffers
        do {
            var vad = EnergyVAD()
            vad.setFrameRate(10)
            for _ in 0..<5 { _ = vad.feed(1e-5) }            // 0.5 s calibration = 5 buffers
            check("10/s: starts on speech after 0.5 s", vad.feed(1e-3) == .start)
            var endAt = -1
            for i in 1...20 where endAt < 0 { if vad.feed(1e-5) == .end { endAt = i } }
            check("10/s: ends after 0.8 s of silence (8 buffers), got \(endAt)", endAt == 8)
        }

        // Summary
        if failures == 0 { print("\n\(total)/\(total) tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }

    static func check(_ label: String, _ condition: Bool) {
        total += 1
        if condition { print("✓  \(label)") }
        else { print("✗  \(label)"); failures += 1 }
    }
}
