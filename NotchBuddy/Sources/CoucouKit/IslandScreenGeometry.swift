import CoreGraphics
import Foundation

/// Resting island dimensions, using a physical notch only when the screen has one.
struct IslandScreenGeometry {
    static let fallbackNotchWidth: CGFloat = 184
    private static let noNotchWidth: CGFloat = 80
    private static let noNotchHeight: CGFloat = 24

    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat,
         auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?,
         menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth {
                let measuredWidth = screenWidth - left - right
                width = measuredWidth > 0 && measuredWidth < screenWidth
                    ? measuredWidth : Self.fallbackNotchWidth
            } else {
                width = Self.fallbackNotchWidth
            }
            height = safeAreaTop
        } else {
            width = Self.noNotchWidth
            height = min(Self.noNotchHeight, menuBarHeight)
        }
    }
}

/// Opt-in: on a screen without a notch, the resting bar fades out until the pointer comes near.
enum RestingBarAutoHide {
    /// How far around the bar the pointer brings it back.
    static let revealMarginX: CGFloat = 60
    static let revealMarginY: CGFloat = 16

    static func revealZone(around bar: CGRect) -> CGRect {
        bar.insetBy(dx: -revealMarginX, dy: -revealMarginY)
    }

    /// Only the resting bar hides: an open or compact island, or one held by an
    /// approval or a drag, always stays visible.
    static func isVisible(enabled: Bool, hasNotch: Bool, isResting: Bool,
                          isHeld: Bool, pointerNear: Bool) -> Bool {
        !enabled || hasNotch || !isResting || isHeld || pointerNear
    }
}

/// Shared by the compact view and the greeting's collapse destination.
struct IslandRestingLayout {
    let width: CGFloat
    let height: CGFloat

    var botDiameter: CGFloat { min(20, max(0, height - 6)) }
    var botCenterY: CGFloat { height / 2 }
    var miniGridScale: CGFloat { min(1, max(0, height - 4) / 28) }
    var miniGridCenterX: CGFloat { width - 40 }
}
