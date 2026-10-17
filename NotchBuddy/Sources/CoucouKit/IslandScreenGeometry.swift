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

/// Shared by the compact view and the greeting's collapse destination.
struct IslandRestingLayout {
    let width: CGFloat
    let height: CGFloat

    var botDiameter: CGFloat { min(20, max(0, height - 6)) }
    var botCenterY: CGFloat { height / 2 }
    var miniGridScale: CGFloat { min(1, max(0.35, min(max(0, height - 4) / 28, (miniGridCenterX - botCenterX - 18) / 28))) }
    // Keep Mochi on the left and the mini grid inside the visible compact extension.
    private var compactExtension: CGFloat { max(0, width - IslandScreenGeometry.fallbackNotchWidth) }
    var botCenterX: CGFloat { min(40, max(18, compactExtension * 0.22)) }
    var miniGridCenterX: CGFloat { max(botCenterX + 38, width - min(40, compactExtension * 0.22)) }
}
