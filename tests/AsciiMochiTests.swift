import Foundation

@main
enum AsciiMochiTests {
    static func main() {
        grid()
        mochi()
        greeting()
        print("AsciiMochi tests: all passed")
    }

    static func grid() {
        var g = AsciiGrid(cols: 4, rows: 2)
        g.put(1, 0, "a", tint: 0xFF0000)
        g.put(2, 0, "b", tint: 0xFF0000)
        g.put(9, 9, "x")                       // outside: ignored
        precondition(g.line(0) == " ab ")
        precondition(g.runs(row: 0).map(\.text) == [" ", "ab", " "])
        precondition(g.runs(row: 0)[1].tint == 0xFF0000)
        g.shiftRow(0, by: 1)
        precondition(g.line(0) == "  ab" && g.tint(3, 0) == 0xFF0000)
        g.shiftRow(0, by: -3)
        precondition(g.line(0) == "b   ")
        precondition(g.text == "b   \n    ")
        precondition(AsciiMath.lerpColor(0x000000, 0xFFFFFF, 0.5) == 0x808080)
        precondition(AsciiMath.hash(1, 2, 3) == AsciiMath.hash(1, 2, 3))
        precondition(AsciiMath.seg(1, 5, 5) == 0)
        precondition(AsciiMochi.glitch(mood: .idle, t: 1.0, rows: 0) == nil)
        precondition(AsciiMochi.glitch(mood: .idle, t: 1.0, rows: -1) == nil)
    }

    static func cells(_ g: AsciiGrid, where f: (Character) -> Bool) -> Int {
        g.chars.filter(f).count
    }

    static func mochi() {
        precondition(AsciiMochi.rows(forCols: 30) == 15)
        // The same moment always draws the same frame.
        precondition(AsciiMochi.frame(mood: .idle, t: 1.234, cols: 30) == AsciiMochi.frame(mood: .idle, t: 1.234, cols: 30))
        let idle = AsciiMochi.frame(mood: .idle, t: 0.5, cols: 30)
        precondition(idle.cols == 30 && idle.rows == 15)
        let body = cells(idle) { $0 != " " }
        precondition(body > 200 && body < 450, "a body, not a full block: \(body)")
        // Eyes are holes in the middle row band.
        precondition(idle.line(8).contains("  ") || idle.line(7).contains("  "))
        // Thinking: the body turns to binary.
        let think = AsciiMochi.frame(mood: .thinking, t: 2.0, cols: 30)
        precondition(cells(think) { $0 == "0" || $0 == "1" } > 40)
        // Working: a scan bar crosses him.
        let scans = (0..<40).map { AsciiMochi.frame(mood: .working, t: Double($0) * 0.11, cols: 30) }
        precondition(scans.contains { cells($0) { $0 == "█" } > 5 })
        // Finished and sleeping never glitch; approval glitches often.
        for i in 0..<300 {
            let t = Double(i) * 0.037
            precondition(AsciiMochi.glitch(mood: .finished, t: t, rows: 15) == nil)
            precondition(AsciiMochi.glitch(mood: .sleeping, t: t, rows: 15) == nil)
        }
        let busy = (0..<1000).filter { AsciiMochi.glitch(mood: .approval, t: Double($0) * 0.01, rows: 15) != nil }.count
        let calm = (0..<1000).filter { AsciiMochi.glitch(mood: .idle, t: Double($0) * 0.01, rows: 15) != nil }.count
        precondition(busy > calm && calm > 0, "approval \(busy), idle \(calm)")
        // Sleeping: eyes shut.
        let sleep = AsciiMochi.frame(mood: .sleeping, t: 0.5, cols: 30)
        precondition(cells(sleep) { $0 == "_" } >= 2)
        if ProcessInfo.processInfo.environment["ASCII_PRINT"] != nil {
            for m in [AsciiMood.idle, .working, .thinking, .approval, .finished, .sleeping] {
                print("--- \(m)"); print(AsciiMochi.frame(mood: m, t: 0.5, cols: 30).text)
            }
        }
    }

    static let particles: AsciiGreetParticles = {
        var seed: UInt32 = 7
        func rnd() -> Double { seed = (seed &* 1103515245 &+ 12345) & 0x7fffffff; return Double(seed) / Double(0x7fff_ffff) }
        let warps = (0..<70).map { _ -> AsciiGreetParticles.Warp in
            let x = rnd(), s = 400 + rnd() * 300, l = 6 + rnd() * 16; _ = rnd()
            return .init(xNorm: x, speed: s, len: l, alpha: 0.25 + rnd() * 0.55, t0: rnd() * 0.35)
        }
        let ring = (0..<90).map { _ -> AsciiGreetParticles.Dot in
            let a = rnd() * .pi * 2, j = (rnd() - 0.5) * 0.22; _ = rnd()
            return .init(a: a, j: j, al: 0.45 + rnd() * 0.55)
        }
        return .init(warps: warps, ring: ring)
    }()

    static func pose(hands: Double = 1, card: Double = 1, minis: Double = 0, wave: Double = 0.2) -> AsciiGreetPose {
        AsciiGreetPose(hb: 58, x: 271, y: 90, sx: 1, sy: 1, eye: .dot, open: 1, lookX: 0.55, lookY: -0.45,
                       handL: hands, handR: hands, wave: wave, halo: 1, haloBlue: 0, minis: minis, fx: 1,
                       card: card, iw: 640)
    }

    static func greeting() {
        let g = AsciiGreeting.render(pose: pose(), t: 1.7, now: 1.0, cols: 200, particles: particles)
        precondition(g.cols == 200 && g.rows == 28)
        precondition(g.text.contains("╭") && g.text.contains("╯"), "the card frame")
        let body = cells(g) { "-=+*#%@".contains($0) }
        precondition(body > 150, "Mochi's body: \(body)")
        // Hands: drawn further out than the body alone.
        let noHands = AsciiGreeting.render(pose: pose(hands: 0), t: 1.7, now: 1.0, cols: 200, particles: particles)
        precondition(cells(g) { "-=+*#%@".contains($0) } > cells(noHands) { "-=+*#%@".contains($0) } + 20)
        // The halo is golden, then blue.
        precondition(g.tints.contains(AsciiGreeting.gold))
        // The ring of bubbles comes in the minis' colours.
        let ring = AsciiGreeting.render(pose: pose(), t: 0.9, now: 1.0, cols: 200, particles: particles)
        for c in AsciiGreeting.miniColors { precondition(ring.tints.contains(c), "ring colour \(c)") }
        // Folded: no card, the four minis.
        let folded = AsciiGreeting.render(pose: pose(hands: 0, card: 0, minis: 1), t: 6, now: 1.0, cols: 200,
                                          particles: particles, minis: (x: 449, y: 18.5, spacing: 6))
        precondition(!folded.text.contains("╭"))
        precondition(cells(folded) { $0 == "■" } == 4)
        // A cropped view around Mochi (the States board) still finds him.
        let crop = AsciiGreeting.render(pose: pose(), t: 1.7, now: 1.0, cols: 46,
                                        viewport: .init(x: 200, y: 0, w: 230, h: 150), particles: particles)
        precondition(crop.rows == 18 && cells(crop) { "=+*#%@".contains($0) } > 40)
        if ProcessInfo.processInfo.environment["ASCII_PRINT"] != nil { print(g.text); print(crop.text) }
    }
}
