import Foundation

@main
enum DesktopMochiTests {
    static func main() {
        testShouldSleep()
        testIsOverBody()
        testLookOrigin()
        testClampOrigin()
        testShouldRetractOnLanding()
        testSurfaceBelow()
        testPerchCandidate()
        testIsEdgeCovered()
        testPlanWander()
        testHopY()
        testFallDuration()
        testNextPollInterval()
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

    // MARK: - shouldRetractOnLanding

    static func testShouldRetractOnLanding() {
        precondition(DesktopMochiLogic.shouldRetractOnLanding(alertActive: true),
                     "must retract when alert is active on landing")
        precondition(!DesktopMochiLogic.shouldRetractOnLanding(alertActive: false),
                     "must not retract when no alert on landing")
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

    // MARK: - surfaceBelow

    static func testSurfaceBelow() {
        let pf = CGRect(x: 500, y: 400, width: 120, height: 120)   // panel center X = 560
        let vf = CGRect(x: 0, y: 23, width: 1440, height: 877)

        // No windows → land on screen bottom (visibleFrame.minY = 23)
        let (y0, id0) = DesktopMochiLogic.surfaceBelow(panelFrame: pf, windows: [], visibleFrame: vf)
        precondition(y0 == 23, "empty windows must land on visibleFrame.minY")
        precondition(id0 == nil, "empty windows must give nil id")

        // Window below panel but center X outside its span → not a candidate
        let tooNarrow = WindowSurface(id: 1, frame: CGRect(x: 700, y: 100, width: 400, height: 600))
        let (y1, id1) = DesktopMochiLogic.surfaceBelow(panelFrame: pf, windows: [tooNarrow], visibleFrame: vf)
        precondition(y1 == 23, "window not under panel center must not be chosen")
        precondition(id1 == nil, "window not under panel center must give nil id")

        // Window below panel and center X within its span → land on it
        let under = WindowSurface(id: 2, frame: CGRect(x: 400, y: 50, width: 400, height: 300))
        // topY = 350, which is < panelFrame.minY = 400 ✓
        let (y2, id2) = DesktopMochiLogic.surfaceBelow(panelFrame: pf, windows: [under], visibleFrame: vf)
        precondition(y2 == 350, "should land on window top edge (topY = 350)")
        precondition(id2 == 2, "should return window id 2")

        // Two windows below — land on the higher one
        let lower = WindowSurface(id: 3, frame: CGRect(x: 400, y: 50, width: 400, height: 100))
        // topY = 150
        let (y3, id3) = DesktopMochiLogic.surfaceBelow(panelFrame: pf, windows: [under, lower], visibleFrame: vf)
        precondition(y3 == 350, "should land on higher of two surfaces")
        precondition(id3 == 2, "should return higher window id")

        // Window top edge exactly at panel bottom → land on it (dist == 0)
        let exact = WindowSurface(id: 4, frame: CGRect(x: 400, y: 50, width: 400, height: 350))
        // topY = 400 = pf.minY ✓
        let (y4, id4) = DesktopMochiLogic.surfaceBelow(panelFrame: pf, windows: [exact], visibleFrame: vf)
        precondition(y4 == 400, "window top at panel bottom must be chosen")
        precondition(id4 == 4, "window top at panel bottom must return id 4")
    }

    // MARK: - perchCandidate

    static func testPerchCandidate() {
        let drop = CGPoint(x: 560, y: 400)   // panel bottom-center

        // Window top exactly at drop.y → perch
        let exact = WindowSurface(id: 1, frame: CGRect(x: 400, y: 200, width: 400, height: 200))
        // topY = 400 = drop.y ✓, span [400, 800] contains drop.x = 560 ✓
        precondition(DesktopMochiLogic.perchCandidate(dropBottom: drop, windows: [exact]) != nil,
                     "window top at drop.y must be a perch candidate")

        // Window top 29 pt below drop.y → within threshold
        let below29 = WindowSurface(id: 2, frame: CGRect(x: 400, y: 200, width: 400, height: 171))
        // topY = 371, |400 - 371| = 29 <= 30 ✓
        precondition(DesktopMochiLogic.perchCandidate(dropBottom: drop, windows: [below29]) != nil,
                     "window 29 pt below must be a candidate")

        // Window top 31 pt below drop.y → outside threshold
        let below31 = WindowSurface(id: 3, frame: CGRect(x: 400, y: 200, width: 400, height: 169))
        // topY = 369, |400 - 369| = 31 > 30 ✗
        precondition(DesktopMochiLogic.perchCandidate(dropBottom: drop, windows: [below31]) == nil,
                     "window 31 pt below must not be a candidate")

        // Window within threshold but drop.x outside horizontal span → no candidate
        let wrongX = WindowSurface(id: 4, frame: CGRect(x: 700, y: 200, width: 400, height: 200))
        // topY = 400 but span [700, 1100] does not contain drop.x = 560 ✗
        precondition(DesktopMochiLogic.perchCandidate(dropBottom: drop, windows: [wrongX]) == nil,
                     "window outside horizontal span must not be a candidate")

        // Window top 29 pt above drop.y → within threshold
        let above29 = WindowSurface(id: 5, frame: CGRect(x: 400, y: 200, width: 400, height: 229))
        // topY = 429, |400 - 429| = 29 <= 30 ✓
        precondition(DesktopMochiLogic.perchCandidate(dropBottom: drop, windows: [above29]) != nil,
                     "window 29 pt above drop.y must be a candidate")
    }

    // MARK: - isEdgeCovered

    static func testIsEdgeCovered() {
        let surface = WindowSurface(id: 1, frame: CGRect(x: 200, y: 100, width: 800, height: 400))
        // topY = 500, midX = 600

        // No other windows → not covered
        precondition(!DesktopMochiLogic.isEdgeCovered(surface: surface, windows: [surface]),
                     "no other windows must not be covered")

        // Window covering the top-center of surface → covered
        let cover = WindowSurface(id: 2, frame: CGRect(x: 400, y: 490, width: 400, height: 200))
        // minX=400 <= 600 <= 800=maxX ✓, minY=490 <= 500 < 690=maxY ✓
        precondition(DesktopMochiLogic.isEdgeCovered(surface: surface, windows: [surface, cover]),
                     "covering window must report covered")

        // Window that touches but doesn't cover (maxY == topY, not >)
        let touch = WindowSurface(id: 3, frame: CGRect(x: 400, y: 400, width: 400, height: 100))
        // maxY = 500 = topY; condition is ey < maxY which is 500 < 500 = false → not covered
        precondition(!DesktopMochiLogic.isEdgeCovered(surface: surface, windows: [surface, touch]),
                     "window touching but not overlapping must not be covered")

        // Window covering top-center but same id → ignored (same window)
        let selfCover = WindowSurface(id: 1, frame: CGRect(x: 400, y: 490, width: 400, height: 200))
        let windows2 = [surface, selfCover]
        precondition(!DesktopMochiLogic.isEdgeCovered(surface: surface, windows: windows2),
                     "self-cover must be ignored")
    }

    // MARK: - planWander

    // Simple deterministic RNG for reproducible tests
    struct LCG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func testPlanWander() {
        var rng1 = LCG(seed: 42)
        let hops = DesktopMochiLogic.planWander(rng: &rng1,
                                                 currentX: 500,
                                                 minX: 100,
                                                 maxX: 1000)
        // Count in [2, 5]
        precondition((2...5).contains(hops.count), "hop count must be 2–5")

        let hi = 1000 - DesktopMochiLogic.panelSize   // 880
        precondition(hops.allSatisfy { $0 >= 100 && $0 <= hi },
                     "all hops must be within bounds")

        // Each consecutive hop differs by at most wanderMaxHopDist (60 pt)
        var prev: CGFloat = 500
        for x in hops {
            precondition(abs(x - prev) <= DesktopMochiLogic.wanderMaxHopDist + 1,
                         "consecutive hops must not exceed wanderMaxHopDist (with 1 pt fp tolerance)")
            prev = x
        }

        // Bounds too narrow → empty result
        var rng2 = LCG(seed: 1)
        let empty = DesktopMochiLogic.planWander(rng: &rng2, currentX: 0, minX: 0, maxX: 100)
        // maxX - panelSize = -20 → hi < minX → empty
        precondition(empty.isEmpty, "too-narrow bounds must produce empty hops")

        // Determinism: same seed → same result
        var rng3 = LCG(seed: 42)
        let hops2 = DesktopMochiLogic.planWander(rng: &rng3, currentX: 500, minX: 100, maxX: 1000)
        precondition(hops == hops2, "same seed must produce same result")
    }

    // MARK: - hopY (parabola)

    static func testHopY() {
        // At t=0 and t=1 the arch is 0
        precondition(DesktopMochiLogic.hopY(t: 0) == 0, "hopY at t=0 must be 0")
        precondition(DesktopMochiLogic.hopY(t: 1) == 0, "hopY at t=1 must be 0")

        // Peak at t=0.5 equals height
        let h: CGFloat = 16
        precondition(DesktopMochiLogic.hopY(t: 0.5, height: h) == h,
                     "hopY peak at t=0.5 must equal height")

        // Symmetric around t=0.5
        let l = DesktopMochiLogic.hopY(t: 0.25)
        let r = DesktopMochiLogic.hopY(t: 0.75)
        precondition(abs(l - r) < 0.001, "hopY must be symmetric around t=0.5")

        // Positive throughout (0, 1)
        for i in 1...9 {
            let t = CGFloat(i) / 10
            precondition(DesktopMochiLogic.hopY(t: t) > 0, "hopY must be positive in (0,1)")
        }
    }

    // MARK: - fallDuration

    static func testFallDuration() {
        // Zero distance → minimum duration
        precondition(DesktopMochiLogic.fallDuration(pixelDistance: 0) == DesktopMochiLogic.fallMinDuration,
                     "zero distance must give min duration")

        // Negative distance → clamped to 0 → minimum
        precondition(DesktopMochiLogic.fallDuration(pixelDistance: -100) == DesktopMochiLogic.fallMinDuration,
                     "negative distance must give min duration")

        // Very large distance → maximum duration
        precondition(DesktopMochiLogic.fallDuration(pixelDistance: 100_000) == DesktopMochiLogic.fallMaxDuration,
                     "huge distance must give max duration")

        // Physics: d = 200 → t = sqrt(2*200/2000) = sqrt(0.2) ≈ 0.4472 (within [0.3, 0.6])
        let d: CGFloat = 200
        let expected = sqrt(2 * Double(d) / Double(DesktopMochiLogic.fallGravity))
        let actual = DesktopMochiLogic.fallDuration(pixelDistance: d)
        precondition(abs(actual - expected) < 0.001, "200 pt fall duration must match physics formula")

        // Result always in [fallMinDuration, fallMaxDuration]
        for d in [CGFloat(1), 50, 100, 300, 500, 800] {
            let t = DesktopMochiLogic.fallDuration(pixelDistance: d)
            precondition(t >= DesktopMochiLogic.fallMinDuration && t <= DesktopMochiLogic.fallMaxDuration,
                         "fall duration must be within clamped range")
        }
    }

    // MARK: - nextPollInterval

    static func testNextPollInterval() {
        // In motion → 60 Hz
        let motion = DesktopMochiLogic.nextPollInterval(inMotion: true, sleeping: false)
        precondition(abs(motion - 1.0/60.0) < 0.001, "inMotion must give 1/60 s interval")

        // Sleeping → 1 Hz
        let sleeping = DesktopMochiLogic.nextPollInterval(inMotion: false, sleeping: true)
        precondition(sleeping == 1.0, "sleeping must give 1 s interval")

        // Sleeping + inMotion → sleeping wins (1 Hz)
        let bothTrue = DesktopMochiLogic.nextPollInterval(inMotion: true, sleeping: true)
        precondition(bothTrue == 1.0, "sleeping takes priority over inMotion")

        // Perched and still → 4 Hz
        let perched = DesktopMochiLogic.nextPollInterval(inMotion: false, sleeping: false)
        precondition(abs(perched - 0.25) < 0.001, "perched must give 0.25 s interval")
    }
}
