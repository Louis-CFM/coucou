import Foundation

/// How a followed edit is revealed (Settings → Follow edits live): lines come in one
/// after another, added lines are typed. Pure timing, so it can be tested without UI.
enum LiveReveal {
    struct Line: Equatable, Sendable {
        /// Added lines are typed; context and removed lines appear whole.
        let typed: Bool
        let length: Int
    }

    struct Shown: Equatable, Sendable {
        let started: Bool
        let opacity: Double
        let characters: Int
        /// The line being typed right now: it carries the caret.
        let typing: Bool
    }

    static let charactersPerSecond = 90.0
    static let plainLineSeconds = 0.04
    static let fadeSeconds = 0.15
    static let maxDuration = 1.6
    static let maxAnimatedLines = 60

    /// Diffs longer than this are shown at once, and so is an empty one.
    static func animates(lineCount: Int) -> Bool {
        lineCount > 0 && lineCount <= maxAnimatedLines
    }

    private static func naturalSeconds(_ line: Line) -> Double {
        line.typed ? max(plainLineSeconds, Double(line.length) / charactersPerSecond) : plainLineSeconds
    }

    private static func scale(for lines: [Line]) -> Double {
        let natural = lines.reduce(0) { $0 + naturalSeconds($1) }
        return natural > maxDuration ? maxDuration / natural : 1
    }

    /// Seconds until every line is whole and done fading: the lines' own time, capped,
    /// plus the last line's fade.
    static func duration(of lines: [Line]) -> Double {
        guard !lines.isEmpty else { return 0 }
        let natural = lines.reduce(0) { $0 + naturalSeconds($1) }
        return min(natural, maxDuration) + fadeSeconds
    }

    /// Each line's state `t` seconds into the reveal.
    static func shown(lines: [Line], at t: Double) -> [Shown] {
        let factor = scale(for: lines)
        var start = 0.0
        return lines.map { line in
            let seconds = naturalSeconds(line) * factor
            defer { start += seconds }
            guard t >= start else { return Shown(started: false, opacity: 0, characters: 0, typing: false) }
            let opacity = min(1, (t - start) / fadeSeconds)
            let progress = min(1, max(0, (t - start) / seconds))
            let characters = line.typed ? Int((progress * Double(line.length)).rounded(.down)) : line.length
            let typing = line.typed && characters < line.length
            return Shown(started: true, opacity: opacity, characters: characters, typing: typing)
        }
    }
}
