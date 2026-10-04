import Foundation

@main
enum DesktopMochiTests {
    static func main() {
        testShouldSleep()
        testIsOverBody()
        testLookOrigin()
        testClampOrigin()
        print("DesktopMochiLogic: all cases passed")
    }

    // MARK: - shouldSleep

    static func testShouldSleep() {
        // Agent recently active → awake regardless of mouse distance
        precondition(!DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: 5, mouseDistanceToPanelCenter: 300),
                     "active agent must not sleep")

        // Long idle but mouse near panel → awake
        precondition(!DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: 200, mouseDistanceToPanelCenter: 50),
                     "mouse near panel must not sleep")

        // Long idle AND mouse far → sleep
        precondition(DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: 200, mouseDistanceToPanelCenter: 200),
                     "long idle + far mouse must sleep")

        // Exactly at timeout boundary → still awake (strictly greater than)
        precondition(!DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: 120, mouseDistanceToPanelCenter: 300),
                     "exactly at timeout must not sleep")

        // Just past timeout boundary + far mouse → sleep
        precondition(DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: 120.1, mouseDistanceToPanelCenter: 300),
                     "just over timeout must sleep")

        // Far mouse at exact distance threshold → sleep
        precondition(DesktopMochiLogic.shouldSleep(lastAgentActiveInterval: 200, mouseDistanceToPanelCenter: 150),
                     "at distance threshold must sleep")
    }

    // MARK: - isOverBody

    static func testIsOverBody() {
        let s: CGFloat = 120
        let r = s * DesktopMochiLogic.bodyRadiusFraction   // 28.8

        // Center → inside
        precondition(DesktopMochiLogic.isOverBody(localPoint: CGPoint(x: 60, y: 60), panelSize: s),
                     "center must be inside body")

        // Just inside radius
        precondition(DesktopMochiLogic.isOverBody(localPoint: CGPoint(x: 60 + r - 0.5, y: 60), panelSize: s),
                     "inside radius must hit")

        // Just outside radius
        precondition(!DesktopMochiLogic.isOverBody(localPoint: CGPoint(x: 60 + r + 0.5, y: 60), panelSize: s),
                     "outside radius must miss")

        // Corner → outside
        precondition(!DesktopMochiLogic.isOverBody(localPoint: CGPoint(x: 0, y: 0), panelSize: s),
                     "corner must miss")

        // Diagonal at radius — distance = r/√2 from each axis
        let diag = r / sqrt(2.0) - 0.5
        precondition(DesktopMochiLogic.isOverBody(localPoint: CGPoint(x: 60 + diag, y: 60 + diag), panelSize: s),
                     "diagonal inside must hit")
    }

    // MARK: - lookOrigin

    static func testLookOrigin() {
        // Panel at (200, 300) on a 1440×900 screen starting at x=0
        let o = DesktopMochiLogic.lookOrigin(panelMinX: 200, panelMinY: 300,
                                              screenMinX: 0, screenHeight: 900,
                                              panelSize: 120)
        // cx = 200 + 60 = 260 → x = 260 - 0 = 260
        precondition(o.x == 260, "lookOrigin x must be panel center relative to screen left")
        // cy = 300 + 60 = 360 → y = 900 - 360 = 540
        precondition(o.y == 540, "lookOrigin y must be flipped from bottom-left to top-left")

        // Panel on a secondary screen starting at x=1440
        let o2 = DesktopMochiLogic.lookOrigin(panelMinX: 1540, panelMinY: 100,
                                               screenMinX: 1440, screenHeight: 1080,
                                               panelSize: 120)
        // cx = 1540 + 60 = 1600 → x = 1600 - 1440 = 160
        precondition(o2.x == 160, "lookOrigin x must be relative to screen minX")
        // cy = 100 + 60 = 160 → y = 1080 - 160 = 920
        precondition(o2.y == 920, "lookOrigin y on secondary screen")
    }

    // MARK: - clampOrigin

    static func testClampOrigin() {
        // Typical macOS visible frame (below menu bar)
        let vf = CGRect(x: 0, y: 23, width: 1440, height: 877)   // maxX=1440, maxY=900
        let s:  CGFloat = 120
        let m:  CGFloat = 24

        // Normal position — within bounds
        let normal = DesktopMochiLogic.clampOrigin(CGPoint(x: 600, y: 400), panelSize: s, visibleFrame: vf, margin: m)
        precondition(normal == CGPoint(x: 600, y: 400), "in-bounds origin must be unchanged")

        // Too far left
        let left = DesktopMochiLogic.clampOrigin(CGPoint(x: -50, y: 400), panelSize: s, visibleFrame: vf, margin: m)
        precondition(left.x == vf.minX + m, "too-left must clamp to minX + margin")

        // Too far right
        let right = DesktopMochiLogic.clampOrigin(CGPoint(x: 2000, y: 400), panelSize: s, visibleFrame: vf, margin: m)
        precondition(right.x == vf.maxX - s - m, "too-right must clamp to maxX - panelSize - margin")

        // Too low
        let low = DesktopMochiLogic.clampOrigin(CGPoint(x: 400, y: -50), panelSize: s, visibleFrame: vf, margin: m)
        precondition(low.y == vf.minY + m, "too-low must clamp to minY + margin")

        // Too high
        let high = DesktopMochiLogic.clampOrigin(CGPoint(x: 400, y: 2000), panelSize: s, visibleFrame: vf, margin: m)
        precondition(high.y == vf.maxY - s - m, "too-high must clamp to maxY - panelSize - margin")
    }
}
