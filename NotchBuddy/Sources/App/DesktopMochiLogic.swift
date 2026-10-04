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

// MARK: - Window surface (pure value type, no AppKit)

/// A window distilled to what the gravity / perching logic needs.
/// All coordinates use AppKit screen space (y-up, origin at bottom-left of main screen).
/// `zIndex` reflects z-order in the CGWindowList (0 = frontmost on screen).
struct WindowSurface: Equatable {
    let id:     CGWindowID  // UInt32
    let frame:  CGRect      // AppKit screen space
    let zIndex: Int         // 0 = frontmost; larger = further back
    var topY: CGFloat { frame.maxY }
}

// MARK: - Pure geometry / logic (no AppKit — fully unit-testable)

/// Stateless helpers for `DesktopMochiController`.
enum DesktopMochiLogic {

    // MARK: - Existing constants

    static let panelSize:          CGFloat      = 120
    static let sleepTimeout:       TimeInterval = 120
    static let sleepMouseDistance: CGFloat      = 150
    static let clampMargin:        CGFloat      = 24
    static let bodyRadiusFraction: CGFloat      = 0.24

    // MARK: - Body geometry

    /// Distance from the panel's AppKit bottom edge to Mochi's feet (body bottom), at rest.
    ///
    /// Derived from BotEngine draw() at rest (oy = 0, particleOverhang = 0):
    ///   R  = panelSize · 0.3
    ///   cy = panelSize / 2 + R · 0.06     (canvas y-down, body center)
    ///   ry = R · 0.88                      (body half-height)
    ///   body bottom (canvas) = cy + ry
    ///   inset = panelSize − (cy + ry)      = panelSize / 2 − R · 0.94
    static let bodyBottomInset: CGFloat = panelSize / 2 - panelSize * 0.3 * 0.94  // ≈ 26.16 pt

    // MARK: - Gravity / perching / wander constants

    static let surfaceMinWidth:   CGFloat      = 160
    static let perchThreshold:    CGFloat      = 30   // pt tolerance around window top edge
    static let fallGravity:       CGFloat      = 2000 // pt/s²
    static let fallMinDuration:   TimeInterval = 0.3
    static let fallMaxDuration:   TimeInterval = 0.6
    static let wanderMinInterval: TimeInterval = 25
    static let wanderMaxInterval: TimeInterval = 70
    static let wanderMinHopDist:  CGFloat      = 25
    static let wanderMaxHopDist:  CGFloat      = 60
    static let wanderMinHops:     Int          = 2
    static let wanderMaxHops:     Int          = 5
    static let wanderHopDuration: TimeInterval = 0.35
    static let wanderHopHeight:   CGFloat      = 16
    static let wanderMouseStop:   CGFloat      = 80
    static let neighborMaxDist:   CGFloat      = 220
    static let neighborChance:    Double       = 0.25

    // MARK: - Existing functions

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

    /// Whether Mochi should immediately retract after landing (alert was active during the flight).
    static func shouldRetractOnLanding(alertActive: Bool) -> Bool { alertActive }

    /// Clamp a panel origin so the panel stays inside `visibleFrame`.
    /// Sides and top use `margin`; bottom allows Mochi's feet to rest exactly on
    /// `visibleFrame.minY` (panel can extend `bodyBottomInset` below the visible frame).
    static func clampOrigin(_ origin:      CGPoint,
                             panelSize:    CGFloat,
                             visibleFrame: CGRect,
                             margin:       CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visibleFrame.minX + margin), visibleFrame.maxX - panelSize - margin),
            y: min(max(origin.y, visibleFrame.minY - bodyBottomInset),
                   visibleFrame.maxY - panelSize - margin)
        )
    }

    // MARK: - Gravity / surface functions

    /// Highest window surface at or below the body's feet, with Mochi's center X within
    /// its horizontal span and its top edge not covered by a window in front.
    ///
    /// Returns the target **panel origin.y** (= surfaceTopY − bodyBottomInset) and the
    /// window ID. When no surface is found, returns the screen-bottom landing position
    /// (= visibleFrame.minY − bodyBottomInset) with id = nil.
    static func surfaceBelow(panelFrame:   CGRect,
                              windows:     [WindowSurface],
                              visibleFrame: CGRect) -> (y: CGFloat, id: CGWindowID?) {
        let cx          = panelFrame.midX
        let bodyBottomY = panelFrame.minY + bodyBottomInset   // Mochi's feet in AppKit y-up

        let best = windows
            .filter {
                $0.topY <= bodyBottomY &&
                $0.frame.minX < cx && cx < $0.frame.maxX &&
                !isEdgeCovered(surface: $0, atX: cx, windows: windows)
            }
            .max { $0.topY < $1.topY }

        if let w = best {
            return (w.topY - bodyBottomInset, w.id)
        }
        return (visibleFrame.minY - bodyBottomInset, nil)
    }

    /// Window whose top edge is within ±`perchThreshold` of `bodyBottom.y`
    /// and `bodyBottom.x` falls within its horizontal span.
    ///
    /// `bodyBottom` is the panel's bottom-center **adjusted for the body inset**:
    /// `CGPoint(x: panel.frame.midX, y: panel.frame.minY + bodyBottomInset)`.
    static func perchCandidate(bodyBottom: CGPoint,
                                windows: [WindowSurface]) -> WindowSurface? {
        windows.first {
            abs($0.topY - bodyBottom.y) <= perchThreshold &&
            $0.frame.minX <= bodyBottom.x && bodyBottom.x <= $0.frame.maxX
        }
    }

    /// Whether the point `(atX, surface.topY)` is occluded by a window that is strictly
    /// in front of `surface` in z-order (smaller `zIndex`).
    static func isEdgeCovered(surface: WindowSurface, atX: CGFloat,
                               windows: [WindowSurface]) -> Bool {
        let ey = surface.topY
        return windows.contains {
            $0.id != surface.id &&
            $0.zIndex < surface.zIndex &&        // must be in front
            $0.frame.minX <= atX && atX <= $0.frame.maxX &&
            $0.frame.minY <= ey && ey < $0.frame.maxY
        }
    }

    // MARK: - Wander functions

    /// Generate wander hop X positions (absolute `panel.frame.origin.x`).
    /// Each hop moves 25–60 pt left or right, clamped to [minX … maxX − panelSize].
    static func planWander<R: RandomNumberGenerator>(
        rng:      inout R,
        currentX: CGFloat,
        minX:     CGFloat,
        maxX:     CGFloat
    ) -> [CGFloat] {
        let hi = maxX - panelSize
        guard hi > minX else { return [] }
        let count = Int.random(in: wanderMinHops...wanderMaxHops, using: &rng)
        var x = currentX
        var result: [CGFloat] = []
        for _ in 0..<count {
            let dist = CGFloat.random(in: wanderMinHopDist...wanderMaxHopDist, using: &rng)
            let sign: CGFloat = Bool.random(using: &rng) ? 1 : -1
            x = min(max(x + sign * dist, minX), hi)
            result.append(x)
        }
        return result
    }

    /// Parabolic arch height at normalized time `t` ∈ [0, 1].
    /// Peaks at `height` at t = 0.5; zero at t = 0 and t = 1.
    static func hopY(t: CGFloat, height: CGFloat = wanderHopHeight) -> CGFloat {
        4 * height * t * (1 - t)
    }

    /// Fall duration for a vertical drop distance (clamped to 0.3 – 0.6 s).
    static func fallDuration(pixelDistance: CGFloat) -> TimeInterval {
        let raw = sqrt(2 * Double(max(0, pixelDistance)) / Double(fallGravity))
        return min(max(raw, fallMinDuration), fallMaxDuration)
    }

    /// Adaptive timer interval for the desktop poll loop.
    /// - `sleeping`: 1 Hz
    /// - `inMotion` (falling or hopping): 60 Hz
    /// - perched and still: 4 Hz
    static func nextPollInterval(inMotion: Bool, sleeping: Bool) -> TimeInterval {
        if sleeping { return 1.0 }
        if inMotion { return 1.0 / 60.0 }
        return 0.25
    }
}
