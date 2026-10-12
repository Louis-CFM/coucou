import Foundation

@main
enum ShortcutTests {
    static func main() {
        testDefaultsExhaustive()
        testAllDefaultsHaveModifier()
        testNoDefaultDuplicates()
        testCarbonModifiers()
        testDisplayString()
        testDuplicateDetection()
        testLoadSaveRoundTrip()
        testLegacyKeysForToggleIsland()
        testEnabledByDefault()
        testKeyCodeToString()
        testCardNavigation()
        print("ShortcutLogic: all cases passed")
    }

    // MARK: - testDefaultsExhaustive

    static func testDefaultsExhaustive() {
        for action in ShortcutAction.allCases {
            precondition(ShortcutLogic.defaults[action] != nil,
                         "missing default for \(action.rawValue)")
        }
        precondition(ShortcutLogic.defaults.count == ShortcutAction.allCases.count,
                     "defaults table must cover every ShortcutAction")
    }

    // MARK: - testAllDefaultsHaveModifier

    static func testAllDefaultsHaveModifier() {
        for (action, spec) in ShortcutLogic.defaults {
            precondition(spec.hasModifier,
                         "default for \(action.rawValue) has no modifier — bare keys not allowed")
        }
    }

    // MARK: - testNoDefaultDuplicates

    static func testNoDefaultDuplicates() {
        let dups = ShortcutLogic.duplicates(in: ShortcutLogic.defaults)
        precondition(dups.isEmpty,
                     "duplicate default shortcuts: \(dups.map { $0.rawValue })")
    }

    // MARK: - testCarbonModifiers

    static func testCarbonModifiers() {
        // cmdShift = ⌘⇧
        let cmdShiftCarbon = ShortcutLogic.carbonModifiers(fromNS: ShortcutSpec.cmdShift)
        // Carbon: cmdKey = 256, shiftKey = 512
        precondition(cmdShiftCarbon & 256 != 0, "⌘ must set cmdKey bit in Carbon")
        precondition(cmdShiftCarbon & 512 != 0, "⇧ must set shiftKey bit in Carbon")
        precondition(cmdShiftCarbon & 2048 == 0, "⌘⇧ must not set optionKey")
        precondition(cmdShiftCarbon & 4096 == 0, "⌘⇧ must not set controlKey")

        // ctrlOpt = ⌃⌥
        let ctrlOptCarbon = ShortcutLogic.carbonModifiers(fromNS: ShortcutSpec.ctrlOpt)
        precondition(ctrlOptCarbon & 256  == 0, "⌃⌥ must not set cmdKey")
        precondition(ctrlOptCarbon & 512  == 0, "⌃⌥ must not set shiftKey")
        precondition(ctrlOptCarbon & 2048 != 0, "⌥ must set optionKey bit in Carbon")
        precondition(ctrlOptCarbon & 4096 != 0, "⌃ must set controlKey bit in Carbon")

        // Zero flags → zero Carbon flags
        precondition(ShortcutLogic.carbonModifiers(fromNS: 0) == 0,
                     "no modifiers must produce zero Carbon flags")

        // All four modifiers
        let allNS = ShortcutSpec.cmdBit | ShortcutSpec.shiftBit |
                    ShortcutSpec.optBit  | ShortcutSpec.ctrlBit
        let allCarbon = ShortcutLogic.carbonModifiers(fromNS: allNS)
        precondition(allCarbon & (256 | 512 | 2048 | 4096) == (256 | 512 | 2048 | 4096),
                     "all four NS modifiers must map to all four Carbon bits")
    }

    // MARK: - testDisplayString

    static func testDisplayString() {
        // ⌘⇧N
        let cmdShiftN = ShortcutSpec(keyCode: 45, nsFlags: ShortcutSpec.cmdShift)
        let s1 = ShortcutLogic.displayString(for: cmdShiftN)
        precondition(s1.contains("⌘"), "⌘⇧N display must contain ⌘")
        precondition(s1.contains("⇧"), "⌘⇧N display must contain ⇧")
        precondition(s1.contains("N"), "⌘⇧N display must contain N")

        // ⌃⌥A
        let ctrlOptA = ShortcutSpec(keyCode: 0, nsFlags: ShortcutSpec.ctrlOpt)
        let s2 = ShortcutLogic.displayString(for: ctrlOptA)
        precondition(s2.contains("⌃"), "⌃⌥A display must contain ⌃")
        precondition(s2.contains("⌥"), "⌃⌥A display must contain ⌥")
        precondition(s2.contains("A"), "⌃⌥A display must contain A")

        // No duplicate modifiers in the string
        precondition(s1.filter { $0 == "⌘" }.count == 1, "⌘ must appear exactly once")

        // ⌃⌥Space
        let ctrlOptSpace = ShortcutSpec(keyCode: 49, nsFlags: ShortcutSpec.ctrlOpt)
        let s3 = ShortcutLogic.displayString(for: ctrlOptSpace)
        precondition(s3.contains("Space"), "⌃⌥Space display must contain 'Space'")
    }

    // MARK: - testDuplicateDetection

    static func testDuplicateDetection() {
        // No duplicates in an empty dict
        precondition(ShortcutLogic.duplicates(in: [:]).isEmpty,
                     "empty map must have no duplicates")

        // Single entry — no duplicate
        let specA = ShortcutSpec(keyCode: 0, nsFlags: ShortcutSpec.ctrlOpt)
        precondition(ShortcutLogic.duplicates(in: [.goToAlert: specA]).isEmpty,
                     "single entry must have no duplicate")

        // Two different specs — no duplicate
        let specB = ShortcutSpec(keyCode: 17, nsFlags: ShortcutSpec.ctrlOpt)
        let twoUnique: [ShortcutAction: ShortcutSpec] = [.goToAlert: specA, .jumpToTerminal: specB]
        precondition(ShortcutLogic.duplicates(in: twoUnique).isEmpty,
                     "two distinct specs must have no duplicate")

        // Same spec for two actions → both flagged
        let twoSame: [ShortcutAction: ShortcutSpec] = [.goToAlert: specA, .jumpToTerminal: specA]
        let dups = ShortcutLogic.duplicates(in: twoSame)
        precondition(dups.contains(.goToAlert),     "first duped action must be flagged")
        precondition(dups.contains(.jumpToTerminal), "second duped action must be flagged")
        precondition(dups.count == 2, "exactly 2 actions must be flagged for one duplicate pair")

        // Same key code but different flags → not a duplicate
        let specC = ShortcutSpec(keyCode: 0, nsFlags: ShortcutSpec.cmdShift)
        let diffFlags: [ShortcutAction: ShortcutSpec] = [.goToAlert: specA, .jumpToTerminal: specC]
        precondition(ShortcutLogic.duplicates(in: diffFlags).isEmpty,
                     "same key code with different modifiers must not be a duplicate")
    }

    // MARK: - testLoadSaveRoundTrip

    static func testLoadSaveRoundTrip() {
        // Use a test-only suite to avoid polluting the app UserDefaults
        let suiteName = "com.coucou.ShortcutTests.\(Int.random(in: 10000...99999))"
        guard let ud = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("could not create test UserDefaults suite")
        }

        // Save a custom spec for .openChat
        let custom = ShortcutSpec(keyCode: 5, nsFlags: ShortcutSpec.cmdShift)
        ud.set(Int(custom.keyCode), forKey: ShortcutAction.openChat.udKeyCode)
        ud.set(Int(custom.nsFlags), forKey: ShortcutAction.openChat.udFlags)

        // Load it back using the raw UserDefaults API (same path ShortcutLogic.hotKey uses)
        let loadedKC  = ud.object(forKey: ShortcutAction.openChat.udKeyCode) as? Int
        let loadedFl  = ud.object(forKey: ShortcutAction.openChat.udFlags)   as? Int
        precondition(loadedKC == Int(custom.keyCode), "saved key code must round-trip")
        precondition(loadedFl == Int(custom.nsFlags),  "saved flags must round-trip")

        // Cleanup
        ud.removePersistentDomain(forName: suiteName)
    }

    // MARK: - testLegacyKeysForToggleIsland

    static func testLegacyKeysForToggleIsland() {
        precondition(ShortcutAction.toggleIsland.udKeyCode == "hotkeyCode",
                     "toggleIsland must use legacy 'hotkeyCode' key")
        precondition(ShortcutAction.toggleIsland.udFlags   == "hotkeyFlags",
                     "toggleIsland must use legacy 'hotkeyFlags' key")
        precondition(ShortcutAction.toggleIsland.udEnabled == "hotkeyEnabled",
                     "toggleIsland must use legacy 'hotkeyEnabled' key")

        // All other actions must NOT use the legacy keys
        for action in ShortcutAction.allCases where action != .toggleIsland {
            precondition(action.udKeyCode != "hotkeyCode",
                         "\(action.rawValue) must not reuse legacy hotkeyCode key")
        }
    }

    // MARK: - testEnabledByDefault

    static func testEnabledByDefault() {
        // toggleIsland is OFF by default (existing behaviour)
        precondition(!ShortcutAction.toggleIsland.enabledByDefault,
                     "toggleIsland must be disabled by default")

        // talkToCoucou is OFF by default (user opts in via Settings → Shortcuts)
        precondition(!ShortcutAction.talkToCoucou.enabledByDefault,
                     "talkToCoucou must be disabled by default")

        // All other global shortcuts are ON by default
        let offByDefault: Set<ShortcutAction> = [.toggleIsland, .talkToCoucou]
        for action in ShortcutAction.allCases where !offByDefault.contains(action) {
            precondition(action.enabledByDefault,
                         "\(action.rawValue) must be enabled by default")
        }
    }

    // MARK: - testKeyCodeToString

    static func testKeyCodeToString() {
        precondition(ShortcutLogic.keyCodeToString(0)  == "A",     "keyCode 0 = A")
        precondition(ShortcutLogic.keyCodeToString(45) == "N",     "keyCode 45 = N")
        precondition(ShortcutLogic.keyCodeToString(49) == "Space", "keyCode 49 = Space")
        precondition(ShortcutLogic.keyCodeToString(30) == "]",     "keyCode 30 = ]")
        precondition(ShortcutLogic.keyCodeToString(33) == "[",     "keyCode 33 = [")
        precondition(ShortcutLogic.keyCodeToString(2)  == "D",     "keyCode 2 = D")
        // Unknown key code returns a placeholder
        let unknown = ShortcutLogic.keyCodeToString(200)
        precondition(!unknown.isEmpty, "unknown key code must return non-empty string")
    }

    // MARK: - testCardNavigation

    static func testCardNavigation() {
        // nil + down → first item
        precondition(ShortcutLogic.navigate(selection: nil,  delta: +1, itemCount: 3) == 0,
                     "nil+down must select first item")
        // nil + up → last item
        precondition(ShortcutLogic.navigate(selection: nil,  delta: -1, itemCount: 3) == 2,
                     "nil+up must select last item")
        // clamp at top
        precondition(ShortcutLogic.navigate(selection: 0,   delta: -1, itemCount: 3) == 0,
                     "selection 0 + up must clamp to 0")
        // clamp at bottom
        precondition(ShortcutLogic.navigate(selection: 2,   delta: +1, itemCount: 3) == 2,
                     "selection last + down must clamp to last")
        // normal step down
        precondition(ShortcutLogic.navigate(selection: 1,   delta: +1, itemCount: 3) == 2,
                     "1+down in 3-item list must yield 2")
        // normal step up
        precondition(ShortcutLogic.navigate(selection: 1,   delta: -1, itemCount: 3) == 0,
                     "1+up in 3-item list must yield 0")
        // delta 0 — no move
        precondition(ShortcutLogic.navigate(selection: 1,   delta:  0, itemCount: 3) == 1,
                     "delta 0 must not move selection")
        // empty card → nil (navigateCard guards on cardItemCount > 0, but test the pure function)
        precondition(ShortcutLogic.navigate(selection: nil, delta: +1, itemCount: 0) == nil,
                     "empty card must return nil")
        precondition(ShortcutLogic.navigate(selection: 0,   delta: +1, itemCount: 0) == nil,
                     "any selection on empty card must return nil")
    }
}
