import SwiftUI

// The Terminal theme's views (Settings → Display → Look). What is drawn comes from
// AsciiMochi.swift; this file only paints it. The classic island never goes through here.

enum TerminalStyle {
    static let text = Color(hex: "#EDEDED")
    static let dim = Color(hex: "#8A8A8A")
    static let border = Color(hex: "#2E2E2E")
    /// Expanded island corners: almost square.
    static let corner: CGFloat = 4
    static let font = Font.system(size: 10.5, weight: .semibold, design: .monospaced)
}

extension AsciiMood {
    init(_ state: BotState) {
        switch state {
        case .idle, .dizzy: self = .idle
        case .working, .searching: self = .working
        case .thinking: self = .thinking
        case .approval, .question, .error, .ratelimit: self = .approval
        case .finished: self = .finished
        case .sleeping: self = .sleeping
        }
    }
}

enum AsciiPainter {
    /// SF Mono's advance is 0.6 em: a font this size fills a cell `cellW` wide,
    /// and rows `cellW / 0.6` tall make square-looking cells of characters.
    static func fontSize(cellW: CGFloat) -> CGFloat { cellW / 0.6 }

    /// Paints the grid from `origin`, one run of same-coloured characters at a time,
    /// each placed at its own column so the grid never drifts.
    static func draw(_ grid: AsciiGrid, in context: GraphicsContext, origin: CGPoint = .zero,
                     cellW: CGFloat, color: Color) {
        let size = fontSize(cellW: cellW)
        let font = Font.system(size: size, weight: .bold, design: .monospaced)
        for j in 0..<grid.rows {
            var col = 0
            for run in grid.runs(row: j) {
                defer { col += run.text.count }
                guard run.text.contains(where: { $0 != " " }) else { continue }
                let c = run.tint.map { rgb in
                    Color(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255,
                          blue: Double(rgb & 0xff) / 255)
                } ?? color
                context.draw(Text(verbatim: run.text).font(font).foregroundColor(c),
                             at: CGPoint(x: origin.x + CGFloat(col) * cellW, y: origin.y + CGFloat(j) * size),
                             anchor: .topLeading)
            }
        }
    }
}

/// Mochi in characters, centred in its frame. 20 frames a second is plenty for ASCII;
/// paused, it draws nothing new (0 % CPU when the island is hidden).
struct TerminalMochiView: View {
    let mood: AsciiMood
    var color: Color = TerminalStyle.text
    var paused: Bool = false
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: paused)) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                // Small Mochi (the compact island): fewer, bigger characters.
                let cols = size.width < 48 ? 13 : min(34, max(16, Int(size.width / 3.4)))
                let rows = AsciiMochi.rows(forCols: cols)
                let cellW = min(size.width / CGFloat(cols), size.height * 0.6 / CGFloat(rows))
                let grid = AsciiMochi.frame(mood: mood, t: t, cols: cols, rows: rows)
                let w = cellW * CGFloat(cols), h = AsciiPainter.fontSize(cellW: cellW) * CGFloat(rows)
                AsciiPainter.draw(grid, in: context,
                                  origin: CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2),
                                  cellW: cellW, color: color)
            }
        }
    }
}

/// A session or pill as a coloured block: ▐■▌ in the pill's colour. Waiting on the
/// user (approval, question), it blinks ! in negative.
struct TerminalMiniView: View {
    let task: AgentTask
    @Environment(\.islandViewActive) private var viewActive

    private var waiting: Bool { task.state == .approval || task.state == .question }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            Group {
                if waiting {
                    TimelineView(.animation(minimumInterval: 0.25, paused: !viewActive)) { tl in
                        let on = Int(tl.date.timeIntervalSinceReferenceDate * 4) % 2 == 0
                        Text(verbatim: "!")
                            .font(.system(size: side * 0.8, weight: .heavy, design: .monospaced))
                            .foregroundColor(on ? .black : Color(hex: task.color))
                            .frame(width: side, height: side)
                            .background(on ? Color(hex: task.color) : .clear)
                    }
                } else {
                    Text(verbatim: "■")
                        .font(.system(size: side * 0.95, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color(hex: task.color))
                        .opacity(task.state == .sleeping ? 0.45 : 1)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// A header word of the Terminal theme (HOME, CHAT, SET…): grey, white on hover,
/// black on white when it is the open view.
struct TerminalKey: View {
    let label: String
    let on: Bool
    let hovered: Bool

    var body: some View {
        Text(verbatim: label)
            .font(TerminalStyle.font)
            .tracking(0.6)
            .foregroundColor(on ? .black : (hovered ? TerminalStyle.text : TerminalStyle.dim))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(on ? TerminalStyle.text : (hovered ? Color.white.opacity(0.07) : .clear))
    }
}

/// Faint horizontal scanlines over the open island. Drawn once, never animated.
struct TerminalScanlines: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 0
            var path = Path()
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += 3
            }
            context.fill(path, with: .color(.white.opacity(0.035)))
        }
        .allowsHitTesting(false)
    }
}
