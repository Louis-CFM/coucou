import Foundation
import CoreGraphics

// MARK: - Alert state machine phase

/// Phase of the desktop Mochi lifecycle.
enum DesktopPhase: Equatable {
    /// No panel on screen; `UserDefaults["mochiOnDesktop"]` is `false`.
    case home
    /// Panel animating from notch to saved desktop position.
    case flyingOut
    /// Panel live on the desktop — normal operating state.
    case onDesktop
    /// `pendingApproval`/`pendingQuestion` just went non-nil; panel animating toward notch.
    case retracting
    /// Alert cleared while retract animation was still running.
    case alertResolvedDuringRetract
    /// Retract complete; notch Mochi is showing the alert.
    case atNotchForAlert
}

// MARK: - Pure geometry / logic (no AppKit — fully unit-testable)

/// Stateless helpers for `DesktopMochiController`.
enum DesktopMochiLogic {
    static let panelSize:          CGFloat      = 120
    static let sleepTimeout:       TimeInterval = 120
    static let sleepMouseDistance: CGFloat      = 150
    static let clampMargin:        CGFloat      = 24
    static let bodyRadiusFraction: CGFloat      = 0.24

    /// Whether Mochi should enter sleeping state.
    static func shouldSleep(lastAgentActiveInterval: TimeInterval,
                             mouseDistanceToPanelCenter: CGFloat) -> Bool {
        lastAgentActiveInterval > sleepTimeout && mouseDistanceToPanelCenter >= sleepMouseDistance
    }

    /// Hit-test the circular body inside a square panel (AppKit y-up local coords).
    static func isOverBody(localPoint: CGPoint, panelSize: CGFloat) -> Bool {
        let cx = panelSize / 2
        let cy = panelSize / 2
        let r  = panelSize * bodyRadiusFraction
        let dx = localPoint.x - cx
        let dy = localPoint.y - cy
        return dx * dx + dy * dy <= r * r
    }

    /// Eye-tracking origin: panel center in screen-space with y-down from top of screen.
    /// Matches the coordinate space of `AppState.mousePosition`.
    static func lookOrigin(panelMinX:    CGFloat,
                            panelMinY:    CGFloat,
                            screenMinX:   CGFloat,
                            screenHeight: CGFloat,
                            panelSize:    CGFloat) -> CGPoint {
        let cx = panelMinX + panelSize / 2
        let cy = panelMinY + panelSize / 2
        return CGPoint(x: cx - screenMinX, y: screenHeight - cy)
    }

    /// Clamp a panel origin so the panel stays inside `visibleFrame` with `margin` on each side.
    static func clampOrigin(_ origin:      CGPoint,
                             panelSize:    CGFloat,
                             visibleFrame: CGRect,
                             margin:       CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visibleFrame.minX + margin), visibleFrame.maxX - panelSize - margin),
            y: min(max(origin.y, visibleFrame.minY + margin), visibleFrame.maxY - panelSize - margin)
        )
    }
}
