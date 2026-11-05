import Foundation

/// What the overview card of a Hermes pill shows while its agent works: the rows of the turn as ticker lines.
/// Pure, display only: it reads the rows the chat already draws (tool name, its one line preview, sentences, the label of
/// a file or a voice note), nothing else, and nothing here is logged, stored or sent.
enum HermesTicker {
    /// Lines kept on the pill, above the 60 steps a turn keeps in the chat. Past the cap the count stays and the card
    /// still advances: it follows the last line (`Signature`).
    static let maxLines = 100

    /// The lines of a turn, in order: one per step (`tool · preview`), one per finished sentence. The text still
    /// being written is left out until something follows it (its first words would stay on the card), the
    /// sentences the app wrote (notes) and the "earlier steps hidden" row are not agent activity.
    static func lines(from segments: [ChatSegment]) -> [String] {
        var out: [String] = []
        for segment in segments {
            switch segment.kind {
            case .step(let step):
                out.append(step.label.isEmpty || step.label == step.tool ? step.tool : "\(step.tool) · \(step.label)")
            case .text(let text, let role):
                guard role != .open else { continue }
                // The directives of a file or a voice note are not text: the sentence, then one label for the files
                // (never a path).
                let found = ChatMediaDirectives.extractCached(text, streaming: false)
                let line = DiffEngine.toOneLine(found.text)
                if !line.isEmpty { out.append(line) }
                if let label = ChatMediaDirectives.tickerLabel(for: found.attachments) { out.append(label) }
            case .note, .hiddenSteps, .edit, .moment:
                continue
            }
        }
        return Array(out.suffix(maxLines))
    }

    /// Step index a card list gets: the last line, and -1 for no line (the ticker reads it as "nothing shown yet",
    /// so the first row of a card that appeared empty is drawn).
    static func stepIndex(forCount count: Int) -> Int { count > 0 ? count - 1 : -1 }

    /// What the ticker view watches on a Hermes pill: the count and the last line, so a list that keeps its length
    /// (the chat keeps 60 steps) still advances.
    struct Signature: Equatable {
        var count: Int
        var last: String?
    }

    enum TickerPlan: Equatable {
        case nothing
        /// Back to the placeholder rows.
        case placeholder
        /// Draw this index at once (nothing, or something older, was shown).
        case show(Int)
        /// Animate to this index.
        case animate(Int)
    }

    /// What the ticker view of a Hermes pill does for the list it has now. `shownIndex` is -1 while it shows the
    /// placeholder, `shownLast` the text of its current row. While a transition runs nothing is decided: its end
    /// asks again, so a change that arrived meanwhile is not lost.
    static func tickerPlan(count: Int, shownIndex: Int, shownLast: String?, last: String?, transitioning: Bool) -> TickerPlan {
        guard !transitioning else { return .nothing }
        if count == 0 { return shownIndex >= 0 ? .placeholder : .nothing }
        let index = stepIndex(forCount: count)
        if shownIndex < 0 || index < shownIndex { return .show(index) }
        return (index != shownIndex || last != shownLast) ? .animate(index) : .nothing
    }
}

/// The card of one Hermes agent across its turns. Turns are numbered as they start; the newest running turn owns the
/// lines, an older one writes nothing. A turn that ends without success, and a cleared conversation, leave no row.
/// A turn that ends with success leaves its rows: the last publish of the turn already holds the answer row.
struct HermesCard: Equatable {
    private(set) var lines: [String] = []
    private var next = 0
    private var running: Set<Int> = []
    /// Turns started before the conversation was cleared: they write nothing any more.
    private var cleared: Set<Int> = []

    /// The turn that wrote the lines on the card now: only that turn may empty them when it ends without success.
    private var lastWriter: Int?

    private var owner: Int? { running.subtracting(cleared).max() }

    /// A turn starts: the card starts from scratch. Returns the number of the turn.
    mutating func start() -> Int {
        let turn = next
        next += 1
        running.insert(turn)
        lines = []
        lastWriter = turn
        return turn
    }

    mutating func rows(_ turn: Int, _ new: [String]) {
        guard turn == owner else { return }
        lines = new
        lastWriter = turn
    }

    mutating func end(_ turn: Int, finished: Bool) {
        let owned = turn == owner
        running.remove(turn)
        cleared.remove(turn)
        if owned, !finished, lastWriter == turn { lines = [] }
    }

    mutating func clear() {
        lines = []
        lastWriter = nil
        cleared = running
    }

    /// The agent is gone: nothing is shown and no running turn writes any more, but the numbering goes on, so a turn
    /// of an agent added again under the same name never shares a number with one still unwinding.
    mutating func discard() {
        lines = []
        lastWriter = nil
        running = []
        cleared = []
    }
}
