import Foundation

// The Terminal theme: Mochi and his launch "coucou" drawn in characters.
// Pure Foundation (no SwiftUI): what is drawn is decided here and tested on
// any machine (scripts/test-ascii-mochi.sh); TerminalViews.swift only paints it.

/// How the island looks. Classic is the app as it ships; Terminal is the raw,
/// all-ASCII look the user can pick in Settings.
enum IslandTheme: String, CaseIterable, Sendable {
    case classic, terminal

    static let storageKey = "islandTheme"
    static var stored: IslandTheme {
        UserDefaults.standard.string(forKey: storageKey).flatMap(IslandTheme.init(rawValue:)) ?? .classic
    }
}

// MARK: - Grid

/// A screen of characters: one character per cell and, for some cells, a colour
/// (0xRRGGBB). Cells without a colour take the text colour.
struct AsciiGrid: Equatable, Sendable {
    let cols: Int
    let rows: Int
    private(set) var chars: [Character]
    private(set) var tints: [UInt32?]

    init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        chars = Array(repeating: " ", count: self.cols * self.rows)
        tints = Array(repeating: nil, count: self.cols * self.rows)
    }

    func char(_ i: Int, _ j: Int) -> Character {
        guard i >= 0, i < cols, j >= 0, j < rows else { return " " }
        return chars[j * cols + i]
    }

    func tint(_ i: Int, _ j: Int) -> UInt32? {
        guard i >= 0, i < cols, j >= 0, j < rows else { return nil }
        return tints[j * cols + i]
    }

    mutating func put(_ i: Int, _ j: Int, _ ch: Character, tint: UInt32? = nil) {
        guard i >= 0, i < cols, j >= 0, j < rows else { return }
        chars[j * cols + i] = ch
        tints[j * cols + i] = tint
    }

    func line(_ j: Int) -> String {
        guard j >= 0, j < rows else { return "" }
        return String(chars[(j * cols)..<((j + 1) * cols)])
    }

    var text: String { (0..<rows).map(line).joined(separator: "\n") }

    /// One row cut where the colour changes, for drawing.
    func runs(row j: Int) -> [(text: String, tint: UInt32?)] {
        var out: [(text: String, tint: UInt32?)] = []
        for i in 0..<cols {
            let c = char(i, j), t = tint(i, j)
            if let last = out.last, last.tint == t {
                out[out.count - 1].text.append(c)
            } else {
                out.append((String(c), t))
            }
        }
        return out
    }

    /// Slides one row sideways (a glitch), filling with spaces.
    mutating func shiftRow(_ j: Int, by k: Int) {
        guard j >= 0, j < rows, k != 0 else { return }
        let row = (0..<cols).map { (chars[j * cols + $0], tints[j * cols + $0]) }
        for i in 0..<cols {
            let src = i - k
            let cell: (Character, UInt32?) = (src >= 0 && src < cols) ? row[src] : (" ", nil)
            chars[j * cols + i] = cell.0
            tints[j * cols + i] = cell.1
        }
    }

    mutating func copyRow(_ from: Int, to: Int) {
        guard from >= 0, from < rows, to >= 0, to < rows, from != to else { return }
        for i in 0..<cols {
            chars[to * cols + i] = chars[from * cols + i]
            tints[to * cols + i] = tints[from * cols + i]
        }
    }

    mutating func mapChars(_ f: (Int, Int, Character) -> Character) {
        for j in 0..<rows { for i in 0..<cols { chars[j * cols + i] = f(i, j, chars[j * cols + i]) } }
    }
}

// MARK: - Shared helpers

enum AsciiMath {
    /// A repeatable 0…1 value for three integers: the same frame always draws the same.
    static func hash(_ a: Int, _ b: Int, _ c: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: a) &* 374_761_393
        h = h &+ UInt32(truncatingIfNeeded: b) &* 668_265_263
        h = h &+ UInt32(truncatingIfNeeded: c) &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        return Double(h & 0xffff) / Double(0xffff)
    }

    static func clamp(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    static func seg(_ t: Double, _ a: Double, _ b: Double) -> Double {
        guard b != a else { return 0 }
        return clamp((t - a) / (b - a), 0, 1)
    }
    static func out(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    static func lerpColor(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xff) }
        func mix(_ s: UInt32) -> UInt32 { UInt32(lerp(ch(a, s), ch(b, s), clamp(t, 0, 1)).rounded()) << s }
        return mix(16) | mix(8) | mix(0)
    }
}

// MARK: - Mochi in the island

/// What the ASCII Mochi shows. The island's BotState maps onto it.
enum AsciiMood: Sendable {
    case idle, working, thinking, approval, finished, sleeping
}

enum AsciiMochi {
    static let ramp: [Character] = Array(" .,:;-=+*#%@")
    static let noise: [Character] = Array("#$%&@!?/\\|<>01=+*")

    /// The rows that keep Mochi's shape for `cols` columns (a cell is 0.6 as wide as tall).
    static func rows(forCols cols: Int) -> Int {
        max(4, Int((Double(max(8, cols)) * 0.6 * 0.86).rounded()))
    }

    enum Glitch: Int, CaseIterable { case shift, scramble, invert, tear, dissolve, stretch }

    /// The glitch running at `t`, if any. No state: every time window of the mood's
    /// rhythm may hold one short glitch, picked from the window number.
    static func glitch(mood: AsciiMood, t: Double, rows: Int) -> (kind: Glitch, row: Int, k: Int)? {
        guard rows > 0 else { return nil }
        let window: Double
        switch mood {
        case .finished, .sleeping: return nil
        case .approval: window = 0.7
        case .working, .thinking: window = 1.6
        case .idle: window = 3.2
        }
        let slot = Int((t / window).rounded(.down))
        let local = t - Double(slot) * window
        let dur = 0.08 + AsciiMath.hash(slot, 1, 7) * 0.22
        let start = AsciiMath.hash(slot, 2, 7) * (window - dur)
        guard local >= start, local < start + dur else { return nil }
        // One window in four stays quiet: the rhythm is not a metronome.
        guard AsciiMath.hash(slot, 3, 7) > 0.25 else { return nil }
        let kind = Glitch.allCases[min(5, Int(AsciiMath.hash(slot, 4, 7) * 6))]
        let row = min(rows - 1, Int(AsciiMath.hash(slot, 5, 7) * Double(rows)))
        let k = AsciiMath.hash(slot, 6, 7) < 0.5 ? -2 : 2
        return (kind, row, k)
    }

    /// One frame of Mochi, `cols` wide. `look` (−1…1) moves his eyes sideways.
    static func frame(mood: AsciiMood, t: Double, cols: Int, rows: Int? = nil, look: Double? = nil) -> AsciiGrid {
        let W = max(8, cols)
        let H = rows ?? self.rows(forCols: W)
        var grid = AsciiGrid(cols: W, rows: H)

        var sy = 1 + 0.035 * sin(t * 1.8)
        var bob = 0.0
        var lookX = look ?? 0.18 * sin(t * 0.7)
        var open = (t * 1000).truncatingRemainder(dividingBy: 3700) < 130 ? 0.08 : 1.0
        var happy = false
        switch mood {
        case .finished: happy = true; bob = -0.05 * abs(sin(t * 6))
        case .approval: bob = -0.08 * abs(sin(t * 9)); lookX = 0
        case .thinking: lookX = look ?? 0.35
        case .working: lookX = look ?? 0.3 * sin(t * 2.6)
        case .sleeping: open = 0.05; sy = 1 + 0.05 * sin(t * 1.1); lookX = 0
        case .idle: break
        }

        let scan = Int((t * 9).rounded(.down)) % (H + 4) - 2
        // Shut eyes are one row of "_": the band is at least half a row tall.
        let shutBand = max(0.07, 1 / (Double(H) * 0.84 * sy))
        for j in 0..<H {
            for i in 0..<W {
                let x = ((Double(i) + 0.5) / Double(W) * 2 - 1) / 0.9
                let y = (((Double(j) + 0.5) / Double(H) * 2 - 1) - bob) / (0.84 * sy)
                let v = pow(abs(x), 2.7) + pow(abs(y), 2.7)
                guard v < 1 else { continue }
                var shade = 0.98 - 0.32 * ((y + 1) / 2) - 0.12 * ((x + 1) / 2)
                if v > 0.8 { shade *= 0.62 }
                let idx = max(1, min(ramp.count - 1, Int(shade * Double(ramp.count - 1))))
                var ch = ramp[idx]
                for sd in [-1.0, 1.0] {
                    let ex = sd * 0.34 + lookX * 0.25, ey = 0.08
                    let dx = (x - ex) / 0.11
                    guard abs(dx) < 1 else { continue }
                    if happy {
                        let arc = ey - 0.16 * (1 - dx * dx)
                        if abs(y - arc) < 0.09 { ch = " " }
                    } else if abs(y - ey) < 0.24 * open {
                        ch = " "
                    } else if open < 0.2 && abs(y - ey) < shutBand {
                        ch = "_"
                    }
                }
                if mood == .thinking, ch != " ", ch != "_" {
                    let c = UInt32(truncatingIfNeeded: Int((t * 8).rounded(.down)) + i * 7 + j * 13)
                    if (c &* 2_654_435_761) % 3 == 0 { ch = "1" }
                    else if (c >> 3) & 1 == 1 { ch = "0" }
                }
                if mood == .working, j == scan, ch != " " { ch = "█" }
                grid.put(i, j, ch)
            }
        }

        if let g = glitch(mood: mood, t: t, rows: H) {
            let f = Int((t * 15).rounded(.down))
            switch g.kind {
            case .shift:
                for j in g.row..<min(H, g.row + 3) { grid.shiftRow(j, by: g.k) }
            case .scramble:
                grid.mapChars { i, j, c in
                    c == " " || AsciiMath.hash(i, j, f) >= 0.18 ? c
                        : noise[Int(AsciiMath.hash(j, i, f) * Double(noise.count)) % noise.count]
                }
            case .invert:
                grid.mapChars { _, _, c in c == " " ? "░" : " " }
            case .tear:
                for j in (g.row + 1)..<min(H, g.row + 2 + abs(g.k)) { grid.copyRow(g.row, to: j) }
            case .dissolve:
                grid.mapChars { i, j, c in c != " " && AsciiMath.hash(i, j, f) < 0.35 ? " " : c }
            case .stretch:
                let k = Double(abs(g.k))
                let before = grid
                grid.mapChars { i, j, _ in before.char(Int(Double(i) / (1 + k * 0.15)), j) }
            }
        }

        if mood == .approval, Int((t * 7).rounded(.down)) % 4 == 0 {
            grid.mapChars { _, _, c in c == "@" || c == "%" ? "!" : c }
        }
        return grid
    }
}

// MARK: - The launch "coucou"

/// Where Mochi is in the greeting (GreetingCanvasView computes it, the same pose
/// the classic drawing uses), in the greeting's 640×150 space.
struct AsciiGreetPose: Sendable {
    enum Eye: Sendable { case dot, happy, content }
    var hb, x, y, sx, sy: Double
    var eye: Eye
    var open, lookX, lookY: Double
    var handL, handR, wave: Double
    var halo, haloBlue, minis, fx, card, iw: Double
}

struct AsciiGreetParticles: Sendable {
    struct Warp: Sendable { let xNorm, speed, len, alpha, t0: Double }
    struct Dot: Sendable { let a, j, al: Double }
    let warps: [Warp]
    let ring: [Dot]
}

enum AsciiGreeting {
    // The greeting's fixed geometry and the moments the hands use (GreetingCanvasView).
    static let space = (w: 640.0, h: 150.0)
    static let center = (x: 320.0, y: 90.0)
    static let card = (x: 10.0, y: 36.0, w: 620.0, h: 104.0)
    static let aspect = 1.34
    static let pop1 = 1.45, tuck0 = 2.45, tuck1 = 2.70

    static let gold: UInt32 = 0xE8C39A
    static let blue: UInt32 = 0x7FB4EA
    static let miniColors: [UInt32] = [0xE86A6A, 0x3E86E0, 0xEFAE5A, 0x8C73F2]

    struct Viewport: Sendable {
        var x, y, w, h: Double
        static let scene = Viewport(x: 0, y: 0, w: 640, h: 150)
    }

    /// Rows for `cols` columns over a viewport (cells are 0.6 as wide as tall).
    static func rows(cols: Int, viewport: Viewport) -> Int {
        let cw = viewport.w / Double(max(1, cols))
        return max(4, Int((viewport.h / (cw / 0.6)).rounded()))
    }

    /// One frame of the greeting. `t` is the greeting's clock (it drives the particles),
    /// `now` any running clock (the halo's flicker and the glitch). `minis` is where the
    /// compact island's four minis sit, in the 640×150 space.
    static func render(pose p: AsciiGreetPose, t: Double, now: Double, cols: Int,
                       viewport vp: Viewport = .scene, particles: AsciiGreetParticles,
                       minis: (x: Double, y: Double, spacing: Double)? = nil) -> AsciiGrid {
        let COLS = max(20, cols)
        let ROWS = rows(cols: COLS, viewport: vp)
        let cw = vp.w / Double(COLS), chh = cw / 0.6
        var grid = AsciiGrid(cols: COLS, rows: ROWS)
        func cell(_ x: Double, _ y: Double) -> (Int, Int) {
            (Int(((x - vp.x) / cw).rounded(.down)), Int(((y - vp.y) / chh).rounded(.down)))
        }
        func inCard(_ x: Double, _ y: Double, inset: Double = 0) -> Bool {
            x >= card.x + inset && x <= card.x + card.w - inset && y >= card.y + inset && y <= card.y + card.h - inset
        }

        // The card: a frame of box-drawing characters, dashed while it fades in.
        if p.card > 0.25 {
            let (c0, r0) = cell(card.x + 2, card.y + 2), (c1, r1) = cell(card.x + card.w - 2, card.y + card.h - 2)
            let solid = p.card > 0.6
            if c1 > c0 + 1 {
                for i in (c0 + 1)..<c1 { grid.put(i, r0, solid ? "─" : "┄"); grid.put(i, r1, solid ? "─" : "┄") }
            }
            if r1 > r0 + 1 {
                for j in (r0 + 1)..<r1 { grid.put(c0, j, solid ? "│" : "┆"); grid.put(c1, j, solid ? "│" : "┆") }
            }
            grid.put(c0, r0, "╭"); grid.put(c1, r0, "╮"); grid.put(c0, r1, "╰"); grid.put(c1, r1, "╯")
        }

        let hh = p.hb / 2, hw = hh * aspect

        // The halo: a light cloud of dots, golden then blue like the classic glow.
        if p.halo > 0, hh > 0.4 {
            let R1 = hw * 2.6, R2 = hw * 4.2, flick = Int((now * 3).rounded(.down))
            let color = AsciiMath.lerpColor(gold, blue, p.haloBlue)
            for j in 0..<ROWS {
                for i in 0..<COLS {
                    let x = vp.x + (Double(i) + 0.5) * cw, y = vp.y + (Double(j) + 0.5) * chh
                    if p.card > 0.25 && !inCard(x, y, inset: 4) { continue }
                    let d = hypot(x - p.x, y - p.y)
                    let dens = (d < R1 ? 0.1 * pow(1 - d / R1, 1.5) : 0) + (d < R2 ? 0.02 * (1 - d / R2) : 0)
                    if dens > 0, AsciiMath.hash(i, j, flick) < dens * p.halo {
                        grid.put(i, j, AsciiMath.hash(i, j, flick + 7) < 0.5 ? "." : ":", tint: color)
                    }
                }
            }
        }

        // Particles, inside the card like the classic ones: the fall-in streaks,
        // then one ring of coloured bubbles bursting out from Mochi.
        if p.card > 0 {
            if t < 0.55 {
                let fade = 1 - AsciiMath.seg(t, 0.40, 0.55)
                for s in particles.warps where t >= s.t0 {
                    let yBot = (t - s.t0) * s.speed, yTop = yBot - s.len
                    guard yBot > 0 else { continue }
                    let a = s.alpha * p.fx * fade
                    guard a >= 0.12 else { continue }
                    let sx = 320 - p.iw / 2 + s.xNorm * p.iw
                    let (ci, _) = cell(sx, 0)
                    let ja = cell(0, max(card.y, yTop)).1, jb = cell(0, min(card.y + card.h, yBot)).1
                    guard jb >= ja else { continue }
                    for j in ja...jb { grid.put(ci, j, a > 0.5 ? "│" : "╎") }
                }
            }
            let k = AsciiMath.seg(t, 0.45, 1.80)
            if k > 0 && k < 1 {
                let rx = AsciiMath.lerp(14, 380, AsciiMath.out(k)), ry = rx * 0.34
                let fade = (1 - k) * (k < 0.08 ? k / 0.08 : 1) * p.fx * p.card
                for (n, dot) in particles.ring.enumerated() {
                    let a = dot.al * fade
                    guard a >= 0.12 else { continue }
                    let r = 1 + dot.j
                    let px = center.x + cos(dot.a) * rx * r, py = center.y + sin(dot.a) * ry * r
                    guard inCard(px, py) else { continue }
                    let (ci, cj) = cell(px, py)
                    grid.put(ci, cj, a > 0.55 ? "o" : a > 0.3 ? "°" : ".", tint: miniColors[n % miniColors.count])
                }
            }
        }

        // The compact island's minis, popping in as it folds.
        if let m = minis, p.minis > 0.5 {
            let s = m.spacing
            for (n, o) in [(-s, -s), (s, -s), (-s, s), (s, s)].enumerated() {
                let (ci, cj) = cell(m.x + o.0, m.y + o.1)
                grid.put(ci, cj, "■", tint: miniColors[n])
            }
        }

        // Mochi: hands behind him, the body, the eyes as holes.
        if hh > 0.4 {
            let er = p.hb * 0.06, sp = p.hb * 0.19
            let elx = p.lookX * hw * 0.42, ely = p.lookY * hh * 0.28 + hh * 0.12
            let ex = max(er, cw * 0.7), ey = max(er, chh * 0.42)
            let pad = max(hw, hh) * 1.8 + 12
            let (ia, ja) = cell(p.x - pad, p.y - pad), (ib, jb) = cell(p.x + pad, p.y + pad)
            let left = hand(left: true, hw: hw, hh: hh, p: p), right = hand(left: false, hw: hw, hh: hh, p: p)
            let jLo = max(0, ja), jHi = min(ROWS - 1, jb), iLo = max(0, ia), iHi = min(COLS - 1, ib)
            if jLo <= jHi && iLo <= iHi {
                for j in jLo...jHi {
                    for i in iLo...iHi {
                        let x = vp.x + (Double(i) + 0.5) * cw, y = vp.y + (Double(j) + 0.5) * chh
                        let bx = (x - p.x) / p.sx, by = (y - p.y) / p.sy
                        let v = pow(abs(bx / hw), 3.2) + pow(abs(by / hh), 3.2)
                        // Light from the top right, like the classic gradient.
                        let proj = AsciiMath.clamp(((bx - hw * 0.6) * (-1.2 * hw) + (by + hh) * (2 * hh))
                                                   / (1.44 * hw * hw + 4 * hh * hh), 0, 1)
                        var ch: Character? = nil
                        if v < 1 {
                            var shade = 1 - 0.42 * proj
                            if v > 0.78 { shade *= 0.66 }
                            let r = AsciiMochi.ramp
                            ch = r[max(2, min(r.count - 1, Int(shade * Double(r.count - 1))))]
                            for sd in [-1.0, 1.0] {
                                let dx = bx - (sd * sp + elx), dy = by - ely
                                switch p.eye {
                                case .dot:
                                    if p.open < 0.3 {
                                        if abs(dx) < ex && abs(dy) < chh * 0.5 { ch = "_" }
                                    } else if (dx / ex) * (dx / ex) + (dy / (ey * p.open)) * (dy / (ey * p.open)) < 1 {
                                        ch = " "
                                    }
                                case .happy, .content:
                                    let cyA = p.eye == .happy ? er * 0.6 : -er * 0.5
                                    let ddy = dy - cyA, d = hypot(dx, ddy), a = atan2(ddy, dx)
                                    let onArc = abs(d - er * 1.25) < max(er * 0.5, cw * 0.55)
                                    let inRange = p.eye == .happy ? (a > -0.88 * .pi && a < -0.12 * .pi)
                                                                  : (a > 0.12 * .pi && a < 0.88 * .pi)
                                    if onArc && inRange { ch = " " }
                                }
                            }
                        } else if let l = left, hypot(bx - l.x, by - l.y) < max(l.r, cw * 0.6) {
                            ch = handShade(proj)
                        } else if let rh = right {
                            let ca = cos(rh.ang), sa = sin(rh.ang)
                            let px = (bx - rh.x) * ca + (by - rh.y) * sa, py = -(bx - rh.x) * sa + (by - rh.y) * ca
                            let half = max(0, rh.len / 2 - rh.thick / 2)
                            let qx = AsciiMath.clamp(px, -half, half)
                            if hypot(px - qx, py) < max(rh.thick / 2, cw * 0.5) { ch = handShade(proj) }
                        }
                        if let ch { grid.put(i, j, ch) }
                    }
                }
            }
        }

        // Now and then one band slips sideways: the terminal hiccups.
        let gl = Int((now / 2.3).rounded(.down))
        if now.truncatingRemainder(dividingBy: 2.3) < 0.07 {
            let row = Int(AsciiMath.hash(gl, 1, 3) * Double(ROWS)), k = AsciiMath.hash(gl, 2, 5) < 0.5 ? -2 : 2
            for j in row..<min(ROWS, row + 2) { grid.shiftRow(j, by: k) }
        }
        return grid
    }

    private static func handShade(_ proj: Double) -> Character {
        let r = AsciiMochi.ramp
        return r[max(3, Int((1 - 0.42 * proj) * 0.92 * Double(r.count - 1)))]
    }

    /// The hands at their size and place for this pose, relative to Mochi's centre.
    /// Left: the round hand that waves. Right: the capsule resting on his side.
    private static func hand(left: Bool, hw: Double, hh: Double, p: AsciiGreetPose)
        -> (x: Double, y: Double, r: Double, len: Double, thick: Double, ang: Double)? {
        let hb = hh * 2
        if left {
            let k = p.handL
            guard k > 0.01 else { return nil }
            var y = AsciiMath.lerp(hh * 0.85, hh * 0.62, k)
            if p.wave >= 0 {
                let rampIn = AsciiMath.clamp(p.wave / 0.08, 0, 1)
                let rampOut = 1 - AsciiMath.clamp((p.wave - (tuck0 - pop1)) / (tuck1 - tuck0), 0, 1)
                y += sin(p.wave * 2 * .pi * 5) * hb * 0.14 * rampIn * rampOut
            }
            return (AsciiMath.lerp(-hw * 0.35, -hw - hb * 0.22, k), y, hb * 0.15 * k, 0, 0, 0)
        }
        let k = p.handR
        guard k > 0.01 else { return nil }
        let ang = p.wave >= 0 ? -0.61 + sin(p.wave * 2 * .pi * 2.5) * 0.04 : -0.61
        return (AsciiMath.lerp(hw * 0.35, hw + hb * 0.2, k), AsciiMath.lerp(hh * 0.85, hh * 0.2, k),
                0, hb * 0.4 * k, hb * 0.22 * k, ang)
    }
}
