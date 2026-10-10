import Foundation

@main
enum LiveRevealTests {
    typealias Line = LiveReveal.Line

    static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    static func main() {
        // Nothing to reveal
        precondition(LiveReveal.duration(of: []) == 0, "empty diff has no duration")
        precondition(LiveReveal.shown(lines: [], at: 1).isEmpty, "empty diff shows nothing")

        // Context lines stagger in; an added line is typed at 90 characters per second
        let lines = [
            Line(typed: false, length: 20),
            Line(typed: true, length: 18),
            Line(typed: false, length: 10),
        ]
        // 0.04 + 18/90 + 0.04, then the last line's fade
        precondition(near(LiveReveal.duration(of: lines), 0.28 + LiveReveal.fadeSeconds), "natural duration adds up")

        let start = LiveReveal.shown(lines: lines, at: 0)
        precondition(start[0].started && start[0].opacity == 0, "first line starts at once, still invisible")
        precondition(!start[1].started && !start[2].started, "the others wait their turn")

        let mid = LiveReveal.shown(lines: lines, at: 0.04 + 0.1)
        precondition(mid[0].started && mid[0].characters == 20, "a plain line is whole when it starts")
        precondition(mid[1].started && mid[1].typing && mid[1].characters == 9, "added line half typed after 0.1 s")
        precondition(!mid[2].started, "the line after it waits")

        // Characters only grow, and everything is whole at the end
        var last = -1
        for step in 0...40 {
            let t = Double(step) * 0.01
            let c = LiveReveal.shown(lines: lines, at: t)[1].characters
            precondition(c >= last, "typing never goes backwards")
            last = c
        }
        let end = LiveReveal.shown(lines: lines, at: LiveReveal.duration(of: lines))
        precondition(end.allSatisfy { $0.started && $0.opacity == 1 && !$0.typing }, "all whole and still at the end")
        precondition(end.map(\.characters) == [20, 18, 10], "every character shown at the end")

        // A long edit is sped up to fit the cap, never slowed
        let long = Array(repeating: Line(typed: true, length: 120), count: 20)
        precondition(near(LiveReveal.duration(of: long), LiveReveal.maxDuration + LiveReveal.fadeSeconds), "capped at 1.6 s")
        let atCap = LiveReveal.shown(lines: long, at: LiveReveal.duration(of: long))
        precondition(atCap.allSatisfy { $0.characters == 120 && $0.opacity == 1 }, "complete at the cap")
        let half = LiveReveal.shown(lines: long, at: LiveReveal.maxDuration / 2)
        precondition(half[9].started && !half[11].started, "about half the lines at half time")

        // Too many lines: no animation at all
        precondition(LiveReveal.animates(lineCount: 60), "60 lines still animate")
        precondition(!LiveReveal.animates(lineCount: 61), "61 lines show at once")
        precondition(!LiveReveal.animates(lineCount: 0), "nothing to animate")

        // The caret: only on the line being typed
        precondition(mid[1].typing && !mid[0].typing, "only the typed line carries the caret")
        print("LiveReveal: all passed")
    }
}
