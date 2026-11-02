import Foundation

@main
enum SystemHUDLogicTests {
    static func main() {
        testDecodeDownUpRepeat()
        testDecodeIgnoresUnknownKeysAndStates()
        testVolumeKeys()
        testMuteIgnoresRepeatAndKeyUp()
        testBrightnessKeysGoToScreen()
        testOptionBrightnessGoesToKeyboard()
        testShiftOptionIsFineScreenStep()
        testBacklightKeys()
        testKeyUpDoesNothing()
        testSteppedSnapsToGrid()
        testSteppedClamps()
        testSteppedFine()
        testSteppedBadInput()
        testVolumeStepUnmutes()
        testPercent()
        testMood()
        testSoundRate()
        print("SystemHUDLogic: all cases passed")
    }

    /// data1 as macOS builds it: key code in the high 16 bits, state (0x0A down,
    /// 0x0B up) in bits 8-15, repeat in bit 0.
    static func data1(_ code: Int, down: Bool, repeating: Bool = false) -> Int {
        (code << 16) | ((down ? 0x0A : 0x0B) << 8) | (repeating ? 1 : 0)
    }

    static func press(_ key: MediaKey, down: Bool = true, repeating: Bool = false) -> MediaKeyPress {
        MediaKeyPress(key: key, isDown: down, isRepeat: repeating)
    }

    static func testDecodeDownUpRepeat() {
        precondition(SystemHUDLogic.decode(data1: data1(0, down: true)) == press(.soundUp))
        precondition(SystemHUDLogic.decode(data1: data1(3, down: false)) == press(.brightnessDown, down: false))
        precondition(SystemHUDLogic.decode(data1: data1(1, down: true, repeating: true))
                     == press(.soundDown, repeating: true))
        precondition(SystemHUDLogic.decode(data1: data1(7, down: true)) == press(.mute))
        precondition(SystemHUDLogic.decode(data1: data1(21, down: true)) == press(.illuminationUp))
    }

    static func testDecodeIgnoresUnknownKeysAndStates() {
        // 16 = NX_KEYTYPE_PLAY: left to macOS and to Coucou's music controls.
        precondition(SystemHUDLogic.decode(data1: data1(16, down: true)) == nil, "play is not a HUD key")
        precondition(SystemHUDLogic.decode(data1: (0 << 16) | (0x05 << 8)) == nil, "unknown state")
        precondition(SystemHUDLogic.decode(data1: 0) == nil)
    }

    static func testVolumeKeys() {
        precondition(SystemHUDLogic.action(for: press(.soundUp), option: false, shift: false)
                     == .step(.volume, direction: 1, fine: false))
        precondition(SystemHUDLogic.action(for: press(.soundDown), option: false, shift: false)
                     == .step(.volume, direction: -1, fine: false))
        precondition(SystemHUDLogic.action(for: press(.soundUp), option: true, shift: true)
                     == .step(.volume, direction: 1, fine: true))
        // ⌥ alone on volume keys stays the volume (only brightness keys are rerouted).
        precondition(SystemHUDLogic.action(for: press(.soundUp), option: true, shift: false)
                     == .step(.volume, direction: 1, fine: false))
    }

    static func testMuteIgnoresRepeatAndKeyUp() {
        precondition(SystemHUDLogic.action(for: press(.mute), option: false, shift: false) == .toggleMute)
        precondition(SystemHUDLogic.action(for: press(.mute, repeating: true), option: false, shift: false) == nil)
        precondition(SystemHUDLogic.action(for: press(.mute, down: false), option: false, shift: false) == nil)
    }

    static func testBrightnessKeysGoToScreen() {
        precondition(SystemHUDLogic.action(for: press(.brightnessUp), option: false, shift: false)
                     == .step(.display, direction: 1, fine: false))
        precondition(SystemHUDLogic.action(for: press(.brightnessDown), option: false, shift: false)
                     == .step(.display, direction: -1, fine: false))
        // ⇧ alone does nothing special.
        precondition(SystemHUDLogic.action(for: press(.brightnessUp), option: false, shift: true)
                     == .step(.display, direction: 1, fine: false))
    }

    static func testOptionBrightnessGoesToKeyboard() {
        precondition(SystemHUDLogic.action(for: press(.brightnessUp), option: true, shift: false)
                     == .step(.keyboard, direction: 1, fine: false))
        precondition(SystemHUDLogic.action(for: press(.brightnessDown), option: true, shift: false)
                     == .step(.keyboard, direction: -1, fine: false))
        precondition(SystemHUDLogic.action(for: press(.brightnessDown, repeating: true), option: true, shift: false)
                     == .step(.keyboard, direction: -1, fine: false), "held keys repeat")
    }

    static func testShiftOptionIsFineScreenStep() {
        precondition(SystemHUDLogic.action(for: press(.brightnessUp), option: true, shift: true)
                     == .step(.display, direction: 1, fine: true))
    }

    static func testBacklightKeys() {
        precondition(SystemHUDLogic.action(for: press(.illuminationUp), option: false, shift: false)
                     == .step(.keyboard, direction: 1, fine: false))
        precondition(SystemHUDLogic.action(for: press(.illuminationDown), option: true, shift: true)
                     == .step(.keyboard, direction: -1, fine: true))
    }

    static func testKeyUpDoesNothing() {
        for key in MediaKey.allCases {
            precondition(SystemHUDLogic.action(for: press(key, down: false), option: false, shift: false) == nil,
                         "key-up of \(key) must not act")
        }
    }

    static func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    static func testSteppedSnapsToGrid() {
        precondition(approx(SystemHUDLogic.stepped(0.53, direction: 1, fine: false), 9.0 / 16))
        precondition(approx(SystemHUDLogic.stepped(0.5, direction: -1, fine: false), 7.0 / 16))
        precondition(approx(SystemHUDLogic.stepped(0.5, direction: 1, fine: false), 9.0 / 16))
    }

    static func testSteppedClamps() {
        precondition(SystemHUDLogic.stepped(1, direction: 1, fine: false) == 1)
        precondition(SystemHUDLogic.stepped(0, direction: -1, fine: false) == 0)
        precondition(SystemHUDLogic.stepped(0.99, direction: 1, fine: true) == 1)
        // Any positive or negative direction is one step, never more.
        precondition(approx(SystemHUDLogic.stepped(0.5, direction: 5, fine: false), 9.0 / 16))
    }

    static func testSteppedFine() {
        precondition(approx(SystemHUDLogic.stepped(0.5, direction: 1, fine: true), 33.0 / 64))
        precondition(approx(SystemHUDLogic.stepped(0.5, direction: -1, fine: true), 31.0 / 64))
    }

    static func testSteppedBadInput() {
        precondition(SystemHUDLogic.stepped(.nan, direction: 1, fine: false) == 1.0 / 16)
        precondition(SystemHUDLogic.stepped(2, direction: -1, fine: false) == 15.0 / 16)
        precondition(SystemHUDLogic.stepped(-1, direction: 1, fine: false) == 1.0 / 16)
    }

    static func testVolumeStepUnmutes() {
        // Like macOS: any step that leaves some sound unmutes, up or down.
        let up = SystemHUDLogic.volumeStep(level: 0.5, muted: true, direction: 1, fine: false)
        precondition(approx(up.level, 9.0 / 16) && !up.muted)
        let down = SystemHUDLogic.volumeStep(level: 0.5, muted: true, direction: -1, fine: false)
        precondition(approx(down.level, 7.0 / 16) && !down.muted)
        // Down to 0 keeps whatever mute state there was.
        let zero = SystemHUDLogic.volumeStep(level: 1.0 / 16, muted: true, direction: -1, fine: false)
        precondition(zero.level == 0 && zero.muted)
        let zeroOpen = SystemHUDLogic.volumeStep(level: 1.0 / 16, muted: false, direction: -1, fine: false)
        precondition(zeroOpen.level == 0 && !zeroOpen.muted)
    }

    static func testPercent() {
        precondition(SystemHUDLogic.percent(level: 9.0 / 16, muted: false) == 56)
        precondition(SystemHUDLogic.percent(level: 1, muted: false) == 100)
        precondition(SystemHUDLogic.percent(level: 0.7, muted: true) == 0)
        precondition(SystemHUDLogic.percent(level: 1.4, muted: false) == 100)
    }

    static func testMood() {
        precondition(SystemHUDLogic.mood(level: 0, muted: false) == .empty)
        precondition(SystemHUDLogic.mood(level: 1.0 / 16, muted: false) == .low)
        precondition(SystemHUDLogic.mood(level: 0.3, muted: false) == .low)
        precondition(SystemHUDLogic.mood(level: 0.5, muted: false) == .normal)
        precondition(SystemHUDLogic.mood(level: 0.7, muted: false) == .high)
        precondition(SystemHUDLogic.mood(level: 15.0 / 16, muted: false) == .high)
        precondition(SystemHUDLogic.mood(level: 1, muted: false) == .max)
        precondition(SystemHUDLogic.mood(level: 1, muted: true) == .muted)
        precondition(SystemHUDLogic.mood(level: .nan, muted: false) == .empty)
    }

    static func testSoundRate() {
        precondition(approx(SystemHUDLogic.soundRate(level: 0), 0.8))
        precondition(approx(SystemHUDLogic.soundRate(level: 0.5), 1.1))
        precondition(approx(SystemHUDLogic.soundRate(level: 1), 1.4))
        // Out of range or broken input stays inside AVAudioPlayer's 0.5…2.
        precondition(approx(SystemHUDLogic.soundRate(level: 3), 1.4))
        precondition(approx(SystemHUDLogic.soundRate(level: .nan), 0.8))
        precondition(SystemHUDLogic.soundRate(level: 0.25) < SystemHUDLogic.soundRate(level: 0.75),
                     "higher volume, higher pitch")
    }
}
