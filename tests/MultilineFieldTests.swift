import SwiftUI
import AppKit

/// Drives the real `MultilineField` in a real window with real key events (no human, no network, no general
/// pasteboard). Needs a window server, like the app: it runs on a logged in Mac.
final class Model: ObservableObject {
    @Published var text = ""
    @Published var focused = true
    /// Changed to re-render the field without writing its text.
    @Published var tick = 0
    var sent: [String] = []
}

struct Root: View {
    @ObservedObject var m: Model
    var body: some View {
        let _ = m.tick
        MultilineField(placeholder: "Ask me anything…",
                       text: Binding(get: { m.text }, set: { m.text = $0 }),
                       isFocused: Binding(get: { m.focused }, set: { m.focused = $0 }),
                       onSubmit: { m.sent.append(m.text); m.text = "" })
            .frame(width: 300)
    }
}

@main
enum MultilineFieldTests {
    nonisolated(unsafe) static var cases = 0
    static func check(_ ok: Bool, _ msg: String, line: UInt = #line) {
        cases += 1
        if !ok { print("FAIL line \(line): \(msg)"); exit(1) }
    }

    @MainActor static func pump(_ n: Int = 4) { for _ in 0..<n { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) } }

    @MainActor static func key(_ w: NSWindow, _ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) { w.sendEvent(e) }
        }
    }

    @MainActor static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor static func run() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let m = Model()
        let host = NSHostingView(rootView: Root(m: m))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host
        win.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        pump(10)
        func find(_ v: NSView) -> MultilineTextView? {
            if let t = v as? MultilineTextView { return t }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        guard let tv = find(host) else { print("FAIL no text view"); exit(1) }
        func type(_ s: String) { for ch in s { key(win, String(ch), code: 0) }; pump() }
        let undoStack: () -> Bool = { tv.undoManager?.canUndo ?? false }

        check(win.firstResponder === tv, "initial focus")
        check(tv.registeredDraggedTypes.isEmpty, "no drag type registered")

        // Keys.
        type("ab"); key(win, "\r", code: 36, .shift); pump(); type("cd")
        check(m.text == "ab\ncd" && m.sent.isEmpty, "Shift+Return breaks the line")
        key(win, "\r", code: 36, .option); pump(); type("e")
        check(m.text == "ab\ncd\ne" && m.sent.isEmpty, "Option+Return breaks the line")
        key(win, "\r", code: 36); pump()
        check(m.text == "" && m.sent == ["ab\ncd\ne"], "Return sends once, inner breaks kept")

        // Keypad Enter (key code 76) follows the Return rule, Shift included, and types no control character.
        type("k"); key(win, "\u{03}", code: 76, [.shift, .numericPad]); pump(); type("l")
        check(m.text == "k\nl", "Shift+keypad Enter breaks the line, no U+0003: \(m.text.debugDescription)")
        key(win, "\u{03}", code: 76, .numericPad); pump()
        check(m.text == "" && m.sent.count == 2 && m.sent[1] == "k\nl", "keypad Enter sends")
        type("x"); key(win, "\u{03}", code: 76, [.option, .numericPad]); pump()
        check(m.text == "x\n", "Option+keypad Enter breaks the line")
        m.text = ""; pump()

        // A control character typed by a key is not inserted; a line break and plain text are.
        tv.insertText("a\u{03}b", replacementRange: tv.selectedRange()); pump()
        check(m.text == "ab", "control character dropped from typed text")
        m.text = ""; pump()

        // Composition: marked text is kept, Return confirms and never sends.
        tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)); pump()
        check(tv.hasMarkedText(), "composing")
        let before = m.sent.count
        key(win, "\r", code: 36); pump()
        check(m.sent.count == before && !tv.hasMarkedText() && m.text == "にほ", "Return confirms the composition, sends nothing")
        key(win, "\u{03}", code: 76, .numericPad); pump()
        check(m.sent.count == before + 1, "keypad Enter sends once the composition is over")

        // I2: a write from outside while composing does not end the composition; the binding wins afterwards.
        m.text = ""; pump()
        tv.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)); pump()
        m.text = "dictated"; pump(); m.focused = true; pump()
        check(tv.hasMarkedText(), "an external write does not end the composition")
        tv.unmarkText(); pump()
        check(tv.string == "dictated" && m.text == "dictated", "after the composition the binding wins: \(tv.string.debugDescription) / \(m.text.debugDescription)")
        m.text = ""; pump()


        // B2: a re-render with no write during a composition changes nothing; the commit lands in view and binding.
        let none = NSRange(location: NSNotFound, length: 0)
        func mark(_ t: String) { tv.setMarkedText(t, selectedRange: NSRange(location: (t as NSString).length, length: 0), replacementRange: none) }
        func rerender() { m.tick += 1; pump(); host.layoutSubtreeIfNeeded(); pump() }
        m.text = ""; pump()
        mark("にほ"); rerender(); rerender()
        check(tv.hasMarkedText() && tv.string == "にほ", "re-render without a write keeps the composition")
        tv.insertText("日本", replacementRange: none); pump()
        check(tv.string == "日本" && m.text == "日本" && !tv.hasMarkedText(), "commit by insertText lands: \(tv.string.debugDescription) / \(m.text.debugDescription)")
        // the same with text before it, committed by insertText and by Return
        m.text = "pre "; pump()
        mark("にほ"); rerender()
        tv.insertText("日本", replacementRange: none); pump()
        check(tv.string == "pre 日本" && m.text == "pre 日本", "text before kept, commit lands: \(m.text.debugDescription)")
        m.text = "pre "; pump()
        mark("にほ"); rerender()
        key(win, "\r", code: 36); pump()
        check(tv.string == "pre にほ" && m.text == "pre にほ", "Return confirms the marked text, nothing lost: \(m.text.debugDescription)")
        // dead keys (Portuguese): marked accent, re-render, the accented letter replaces it
        m.text = ""; pump()
        type("v"); mark("´"); rerender(); tv.insertText("ó", replacementRange: none); pump()
        mark("~"); rerender(); tv.insertText("ã", replacementRange: none); pump()
        type("o")
        check(tv.string == "vóão" && m.text == "vóão", "dead key sequence with re-renders: \(m.text.debugDescription)")
        // the real write still wins afterwards, a dead key cancelled by Space keeps the accent
        mark("´"); rerender(); tv.insertText("´", replacementRange: none); pump()
        check(m.text == "vóão´" && tv.string == m.text, "dead key committed as itself")
        // N9: a marked text that wraps makes the field grow
        m.text = ""; pump()
        let flat = tv.enclosingScrollView!.frame.height
        mark(String(repeating: "にほんご ", count: 40)); pump(); host.layoutSubtreeIfNeeded(); pump()
        let grown = tv.enclosingScrollView!.frame.height
        check(grown > flat, "the field grows while a marked text wraps (\(flat) → \(grown))")
        tv.insertText("", replacementRange: none); pump()
        check(!tv.hasMarkedText() && tv.string == "" && m.text == "", "empty insertText cancels the composition")
        host.layoutSubtreeIfNeeded(); pump()
        check(tv.enclosingScrollView!.frame.height == flat, "the field shrinks back")

        // I5: an empty insertText replaces a range by nothing, like a plain NSTextView
        m.text = "hello"; pump()
        tv.insertText("", replacementRange: NSRange(location: 0, length: 2)); pump()
        check(tv.string == "llo" && m.text == "llo", "range replaced by nothing: \(tv.string.debugDescription)")
        // N7: a tab is kept in typed text, the Tab key moves the key view and types none
        m.text = ""; pump()
        tv.insertText("a\tb", replacementRange: tv.selectedRange()); pump()
        check(m.text == "a\tb", "a tab is kept by insertText")
        m.text = "ab"; pump()
        key(win, "\t", code: 48); pump()
        check(m.text == "ab", "plain Tab types no tab")
        m.text = ""; pump()


        // N15: the caret in the middle, a draft switch / a send during a composition, undo and redo of a composed letter
        m.text = "abcd"; pump(); tv.setSelectedRange(NSRange(location: 2, length: 0))
        mark("~"); rerender(); rerender(); tv.insertText("ã", replacementRange: none); pump(); rerender()
        check(tv.string == "abãcd" && m.text == "abãcd" && tv.selectedRange().location == 3, "commit with the caret in the middle: \(m.text.debugDescription) caret \(tv.selectedRange().location)")
        type("x")
        check(m.text == "abãxcd", "typing goes on at the caret: \(m.text.debugDescription)")
        m.text = "draft A´"; pump()
        mark("´"); m.text = "draft B"; rerender()
        check(tv.hasMarkedText(), "a draft switch does not end the composition")
        tv.insertText("é", replacementRange: none); pump()
        check(tv.string == "draft B" && m.text == "draft B", "draft switch during a composition: the new draft wins, \(m.text.debugDescription)")
        key(win, "\r", code: 36); pump()
        check(m.sent.last == "draft B", "Return then sends the new draft")
        m.text = "ol"; pump(); mark("´"); m.text = ""; rerender()
        tv.insertText("", replacementRange: none); pump()
        check(tv.string == "" && m.text == "", "a send during a composition ended by insertText: field empty")
        m.text = ""; pump()
        type("ol"); mark("´"); tv.insertText("á", replacementRange: none); pump(); type(" b")
        tv.undoManager?.undo(); pump()
        let afterUndo = m.text
        tv.undoManager?.redo(); pump()
        check(m.text == "olá b" && tv.string == m.text && afterUndo != "olá b", "undo and redo of a composed letter: undo \(afterUndo.debugDescription), redo \(m.text.debugDescription)")
        m.text = ""; pump()
        // N11: a send while an accent is pending, then the field loses the keyboard: nothing of the sent text stays
        m.text = "ol"; pump(); mark("´")
        m.text = ""; pump(); m.focused = false; pump(); rerender()
        check(tv.string == "" && m.text == "", "send with a pending accent: the field is empty after it loses the keyboard (\(tv.string.debugDescription))")
        m.focused = true; pump()
        // N12: a write and an edit in the same turn: the write wins
        m.text = "draft A"; pump()
        m.text = "draft B"; tv.insertText("é", replacementRange: NSRange(location: 7, length: 0))
        pump(); rerender()
        check(tv.string == "draft B" && m.text == "draft B", "write and edit in one turn: the write wins (\(tv.string.debugDescription) / \(m.text.debugDescription))")
        // N13: Shift+keypad Enter during a composition confirms and stops
        m.text = "ol"; pump(); mark("´")
        let sentBefore = m.sent.count
        key(win, "\u{03}", code: 76, [.shift, .numericPad]); pump()
        check(m.text == "ol´" && !tv.hasMarkedText() && m.sent.count == sentBefore, "Shift+keypad Enter during a composition confirms only: \(m.text.debugDescription)")
        m.text = ""; pump()

        // B1: type, send, type, undo, undo → no exception, nothing of the sent text comes back.
        type("hello world this is long")
        check(undoStack(), "typing is undoable")
        key(win, "\r", code: 36); pump()
        check(m.text == "", "sent")
        type("hi")
        for _ in 0..<2 { tv.undoManager?.undo(); pump() }
        check(!m.text.contains("hello") && m.text == tv.string, "undo after a send leaves no text of the sent message: \(m.text.debugDescription)")
        check(tv.undoManager !== win.undoManager, "the field has its own undo manager")
        // redo brings back what undo took
        m.text = ""; pump()
        type("hi"); tv.undoManager?.undo(); pump()
        check(m.text == "", "undo takes the typing")
        tv.undoManager?.redo(); pump()
        check(m.text == "hi", "redo brings it back: \(m.text.debugDescription)")
        // A write from outside forgets the history.
        type("abc"); check(undoStack(), "undoable again")
        m.text = "from outside"; pump()
        check(tv.undoManager?.canUndo == false, "an external write clears the undo history")
        tv.undoManager?.undo(); pump()
        check(tv.string == "from outside", "undo after an external write changes nothing")
        // The window's own manager is never touched.
        win.undoManager?.registerUndo(withTarget: tv, handler: { _ in })
        m.text = "again"; pump()
        check(win.undoManager?.canUndo == true, "the window's undo manager is left alone")

        // Paste of line breaks through a private pasteboard.
        m.text = ""; pump()
        let pb = NSPasteboard(name: NSPasteboard.Name("fr.louisraille.NotchBuddy.test-multiline"))
        pb.clearContents(); pb.setString("p1\np2\np3", forType: .string)
        _ = tv.readSelection(from: pb, type: .string); pump()
        check(m.text == "p1\np2\np3", "paste keeps line breaks")
        pb.clearContents()

        // Height 1 / 3 / 5 / 8 lines, and a narrow proposal does not lay the text out.
        guard let view = tv.enclosingScrollView as? MultilineFieldView else { print("FAIL no field view"); exit(1) }
        for (n, h) in [(1, 16.0), (3, 48.0), (5, 80.0), (8, 80.0)] {
            m.text = (1...n).map { "l\($0)" }.joined(separator: "\n"); pump()
            check(view.fittingSize(width: 300).height == h, "\(n) lines → \(h)")
        }
        let long = String(repeating: "word ", count: 4000)
        m.text = long; pump()
        let t0 = DispatchTime.now().uptimeNanoseconds
        _ = view.fittingSize(width: 0)
        let narrowMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        check(narrowMs < 5, "narrow proposal answered without a layout (\(narrowMs) ms)")
        check(view.fittingSize(width: 0).height == 16, "narrow proposal is one line")

        print("OK \(cases) checks")
    }
}
