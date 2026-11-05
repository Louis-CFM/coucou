import Foundation
import CoreGraphics

/// Rules of the multi line chat field: what a Return does, and how tall the field is.
/// Pure logic, no UI: `MultilineField` and the tests both read it from here.
enum MultilineInput {
    /// The field grows with its text up to this many lines, then scrolls inside.
    static let maxLines = 5

    /// What the text system asks for. `insertNewline:` is a plain Return; `insertLineBreak:` and
    /// `insertNewlineIgnoringFieldEditor:` are the standard bindings of Control-Return and Option-Return.
    enum Command: Equatable {
        case newline, lineBreak, other
    }

    struct Modifiers: OptionSet {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    enum Action: Equatable {
        /// Send the message, through the function the field always sent with.
        case send
        /// Put a line break at the cursor (it replaces the selection).
        case insertLineBreak
        /// Not ours: let the text system do what it does (arrows, delete, composition…).
        case passthrough
        /// The key is consumed and nothing happens.
        case ignore
        /// A Return reached the field while an input method has marked text: it confirms that text, nothing more.
        case confirmComposition
    }

    /// Return sends, Shift-Return (and Option/Control-Return) breaks the line. Command-Return never gets here
    /// (the island shortcut takes it first); if it did, nothing would be typed and nothing sent from the field.
    /// While an input method composes, the Return belongs to it: it confirms the composition and never sends.
    /// (A real input method takes the Return itself; this covers the one that lets it through.)
    static func action(for command: Command, modifiers: Modifiers, composing: Bool) -> Action {
        if composing && command != .other { return .confirmComposition }
        switch command {
        case .other:
            return .passthrough
        case .lineBreak:
            return .insertLineBreak
        case .newline:
            if modifiers.contains(.command) { return .ignore }
            if !modifiers.isDisjoint(with: [.shift, .option, .control]) { return .insertLineBreak }
            return .send
        }
    }

    /// Return (36) and the keypad Enter (76) are the same key for the field.
    static func isReturnKey(keyCode: UInt16) -> Bool { keyCode == 36 || keyCode == 76 }

    /// The text of a key without raw control characters: C0, DEL and C1 are dropped; the line break `\n` and the
    /// tab stay (plain Tab never gets here, it has its own command; Option+Tab types a tab).
    static func withoutControlCharacters(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where u == "\n" || u == "\t" || !(u.value < 0x20 || (u.value >= 0x7F && u.value <= 0x9F)) {
            out.append(u)
        }
        return String(out)
    }

    /// Maps the selector the text system sends to a `Command`.
    static func command(forSelector name: String) -> Command {
        switch name {
        case "insertNewline:": return .newline
        case "insertLineBreak:", "insertNewlineIgnoringFieldEditor:": return .lineBreak
        default: return .other
        }
    }

    /// Height of the field for a text whose laid out height is `content`: one line at least, `maxLines` at most.
    static func height(content: CGFloat, lineHeight: CGFloat, maxLines: Int = MultilineInput.maxLines) -> CGFloat {
        guard lineHeight > 0, lineHeight.isFinite else { return 0 }
        let cap = lineHeight * CGFloat(max(1, maxLines))
        guard content.isFinite else { return lineHeight }
        return min(max(content, lineHeight), cap)
    }

    /// True when the text is taller than the field and scrolls inside it.
    static func scrolls(content: CGFloat, lineHeight: CGFloat, maxLines: Int = MultilineInput.maxLines) -> Bool {
        content > lineHeight * CGFloat(max(1, maxLines)) + 0.5
    }
}
