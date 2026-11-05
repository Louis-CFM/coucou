import Foundation

@main
enum MultilineInputTests {
    static var cases = 0
    static func check(_ ok: Bool, _ msg: String, line: UInt = #line) {
        cases += 1
        if !ok { print("FAIL line \(line): \(msg)"); exit(1) }
    }

    static func main() {
        typealias M = MultilineInput
        let none: M.Modifiers = []

        // Return alone sends, exactly as before.
        check(M.action(for: .newline, modifiers: none, composing: false) == .send, "return sends")
        // Shift, Option and Control with Return break the line.
        for m: M.Modifiers in [.shift, .option, .control, [.shift, .option]] {
            check(M.action(for: .newline, modifiers: m, composing: false) == .insertLineBreak, "modified return breaks the line")
        }
        // Command-Return belongs to the island shortcut: the field neither sends nor types.
        check(M.action(for: .newline, modifiers: .command, composing: false) == .ignore, "command return")
        check(M.action(for: .newline, modifiers: [.command, .shift], composing: false) == .ignore, "command shift return")
        // The standard line break commands always break.
        check(M.action(for: .lineBreak, modifiers: none, composing: false) == .insertLineBreak, "line break command")
        // An input method that composes keeps its Return: it confirms the text, never sends, never breaks the line.
        for c: M.Command in [.newline, .lineBreak] {
            for m: M.Modifiers in [none, .shift, .option, .command] {
                check(M.action(for: c, modifiers: m, composing: true) == .confirmComposition, "composition confirmed by return")
            }
        }
        for m: M.Modifiers in [none, .shift] {
            check(M.action(for: .other, modifiers: m, composing: true) == .passthrough, "other keys stay with the composition")
        }
        // Any other command is the text system's.
        check(M.action(for: .other, modifiers: none, composing: false) == .passthrough, "other passes")
        check(M.action(for: .other, modifiers: .shift, composing: false) == .passthrough, "other with shift passes")

        // Selector names.
        check(M.command(forSelector: "insertNewline:") == .newline, "insertNewline")
        check(M.command(forSelector: "insertLineBreak:") == .lineBreak, "insertLineBreak")
        check(M.command(forSelector: "insertNewlineIgnoringFieldEditor:") == .lineBreak, "ignoring field editor")
        check(M.command(forSelector: "deleteBackward:") == .other, "delete")
        check(M.command(forSelector: "") == .other, "empty")

        // Return and keypad Enter are one key; nothing else is.
        check(M.isReturnKey(keyCode: 36), "return key")
        check(M.isReturnKey(keyCode: 76), "keypad enter")
        check(!M.isReturnKey(keyCode: 0) && !M.isReturnKey(keyCode: 48) && !M.isReturnKey(keyCode: 75), "other keys")

        // No raw control character from a key.
        check(M.withoutControlCharacters("a\u{03}b") == "ab", "ETX dropped")
        check(M.withoutControlCharacters("\n") == "\n", "line break kept")
        check(M.withoutControlCharacters("a\u{0}\u{1B}\u{7F}\u{85}\u{9F}b\t") == "ab\t", "NUL ESC DEL C1 dropped, tab kept")
        check(M.withoutControlCharacters("a\tb") == "a\tb", "tab kept")
        check(M.withoutControlCharacters("héllo にほ 😀") == "héllo にほ 😀", "text kept")
        check(M.withoutControlCharacters("\u{03}") == "", "only a control character")
        check(M.withoutControlCharacters("") == "", "empty")

        // Height: one line at least, five at most.
        let lh: CGFloat = 16
        check(M.height(content: 0, lineHeight: lh) == 16, "empty is one line")
        check(M.height(content: 16, lineHeight: lh) == 16, "one line")
        check(M.height(content: 48, lineHeight: lh) == 48, "three lines")
        check(M.height(content: 80, lineHeight: lh) == 80, "five lines")
        check(M.height(content: 81, lineHeight: lh) == 80, "six lines capped")
        check(M.height(content: 800, lineHeight: lh) == 80, "many lines capped")
        check(M.height(content: .nan, lineHeight: lh) == 16, "nan content")
        check(M.height(content: .infinity, lineHeight: lh) == 16, "infinite content")
        check(M.height(content: 40, lineHeight: 0) == 0, "no line height")
        check(M.height(content: 40, lineHeight: .nan) == 0, "nan line height")
        check(M.height(content: 100, lineHeight: lh, maxLines: 0) == 16, "max lines floor of one")
        check(M.height(content: 100, lineHeight: lh, maxLines: 2) == 32, "custom cap")
        check(M.maxLines == 5, "five lines")

        // Scrolling starts after the fifth line.
        check(!M.scrolls(content: 80, lineHeight: lh), "five lines do not scroll")
        check(M.scrolls(content: 96, lineHeight: lh), "six lines scroll")
        check(!M.scrolls(content: 16, lineHeight: lh), "one line does not scroll")

        print("OK \(cases) checks")
    }
}
