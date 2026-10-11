import SwiftUI

// MARK: - Live reveal
//
// Rows that come in one after another, added ones typed, while an edit is followed live
// (Settings → Follow edits live). The clock is one animatable number: SwiftUI drives it
// per frame while it runs and stops by itself, so nothing ticks once the reveal is done.

struct LiveRevealList<Row: View>: View, Animatable {
    let lines: [LiveReveal.Line]
    // A plain number SwiftUI drives per frame: not main actor state.
    nonisolated(unsafe) var elapsed: Double
    let scrollProxy: ScrollViewProxy?
    let row: (Int, LiveReveal.Shown) -> Row

    nonisolated var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    var body: some View {
        let shown = LiveReveal.shown(lines: lines, at: elapsed)
        let started = shown.lastIndex(where: \.started).map { $0 + 1 } ?? 0
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<lines.count, id: \.self) { i in
                if shown[i].started {
                    row(i, shown[i])
                        .opacity(shown[i].opacity)
                        .id(i)
                }
            }
        }
        .onChange(of: started) { _, count in
            guard count > 0 else { return }
            withAnimation(.easeOut(duration: 0.12)) { scrollProxy?.scrollTo(count - 1, anchor: .bottom) }
        }
    }
}

/// Starts the reveal when it appears, and shows everything at once when `animate` is off.
struct LiveRevealHost<Row: View>: View {
    let lines: [LiveReveal.Line]
    let animate: Bool
    var scrollProxy: ScrollViewProxy? = nil
    let row: (Int, LiveReveal.Shown) -> Row

    @State private var elapsed: Double = 0

    private var total: Double { LiveReveal.duration(of: lines) }
    private var plays: Bool { animate && LiveReveal.animates(lineCount: lines.count) }

    var body: some View {
        LiveRevealList(lines: lines, elapsed: plays ? elapsed : total, scrollProxy: scrollProxy, row: row)
            .onAppear {
                guard plays, elapsed == 0 else { return }
                withAnimation(.linear(duration: total)) { elapsed = total }
            }
    }
}

enum LiveRevealStyle {
    /// The caret at the end of the line being typed.
    static let caret = "▍"

    /// The text of a row `shown` into its reveal, with the caret while it is typed.
    static func text(_ full: String, _ shown: LiveReveal.Shown) -> String {
        guard shown.characters < full.count || shown.typing else { return full }
        return String(full.prefix(shown.characters)) + (shown.typing ? caret : "")
    }
}
