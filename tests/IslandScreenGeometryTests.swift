import Foundation

@main
enum IslandScreenGeometryTests {
    static func main() {
        // Regression: absent auxiliary areas must never mean "screen-wide notch".
        for screenWidth: CGFloat in [1080, 1920, 2560, 3840] {
            let geometry = IslandScreenGeometry(
                screenWidth: screenWidth, safeAreaTop: 0,
                auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 30
            )
            precondition(!geometry.hasNotch)
            precondition(geometry.width == 80)
            precondition(geometry.height == 24)
        }

        // A shorter menu bar must also contain the resting island.
        let shortMenuBar = IslandScreenGeometry(
            screenWidth: 1920, safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, menuBarHeight: 22
        )
        precondition(shortMenuBar.height == 22)

        // Real MacBook notch measurements retain their physical dimensions.
        let macBook = IslandScreenGeometry(
            screenWidth: 1512, safeAreaTop: 32,
            auxiliaryLeftWidth: 660, auxiliaryRightWidth: 660, menuBarHeight: 32
        )
        precondition(macBook.hasNotch)
        precondition(macBook.width == 192 && macBook.height == 32)

        // Incomplete or invalid measurements use the notch fallback, not the screen.
        for auxiliaryWidth: CGFloat? in [nil, 0, 1000] {
            let geometry = IslandScreenGeometry(
                screenWidth: 1512, safeAreaTop: 32,
                auxiliaryLeftWidth: auxiliaryWidth, auxiliaryRightWidth: auxiliaryWidth,
                menuBarHeight: 32
            )
            precondition(geometry.width == 184 && geometry.height == 32)
        }
        // Compact/greeting destinations share the measured resting height.
        for height: CGFloat in [22, 24, 32, 38] {
            let compact = IslandRestingLayout(width: 240, height: height)
            precondition(compact.botCenterY == height / 2)
            precondition(compact.botDiameter == min(20, height - 6))
            precondition(compact.botCenterY - compact.botDiameter / 2 >= 3)
            precondition(compact.botCenterY + compact.botDiameter / 2 <= height - 3)
            precondition(compact.miniGridCenterX == 200)
            precondition(compact.miniGridScale * 28 <= height - 4)
        }
        // Resting bar auto-hide: hides only a resting bar, on a screen without a notch, when enabled.
        func visible(enabled: Bool = true, hasNotch: Bool = false, isResting: Bool = true,
                     isHeld: Bool = false, pointerNear: Bool = false) -> Bool {
            RestingBarAutoHide.isVisible(enabled: enabled, hasNotch: hasNotch, isResting: isResting,
                                         isHeld: isHeld, pointerNear: pointerNear)
        }
        precondition(!visible())
        precondition(visible(enabled: false))
        precondition(visible(hasNotch: true))
        precondition(visible(isResting: false))
        precondition(visible(isHeld: true))
        precondition(visible(pointerNear: true))
        let bar = CGRect(x: 320, y: 536, width: 80, height: 24)
        let zone = RestingBarAutoHide.revealZone(around: bar)
        precondition(zone.contains(CGPoint(x: 300, y: 530)))    // approaching from below-left
        precondition(!zone.contains(CGPoint(x: 200, y: 536)))   // far to the side
        precondition(!zone.contains(CGPoint(x: 360, y: 500)))   // well below the menu bar
        print("Island screen geometry, resting layout and auto-hide: 22 cases passed")
    }
}
