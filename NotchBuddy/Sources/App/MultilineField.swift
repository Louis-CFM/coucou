import SwiftUI
import AppKit

/// A text field that grows with its text (1 to `MultilineInput.maxLines` lines, then scrolls inside).
/// Return sends, Shift-Return breaks the line (`MultilineInput`). An input method that is composing keeps
/// its Return: the text system hands the Return to the command handler only once the composition is over.
/// Built on NSTextView because SwiftUI cannot tell Return from Shift-Return, nor see marked text.
/// Draws nothing and runs nothing by itself: no timer, no observer; it only reacts to the user and to its bindings.
struct MultilineField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    /// Focus both ways: `true` makes the field the first responder, the field reports when it gains or loses it.
    @Binding var isFocused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> MultilineFieldView {
        let view = MultilineFieldView()
        let tv = view.textView
        tv.delegate = context.coordinator
        tv.placeholder = placeholder
        tv.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }
        tv.onMarkedTextChange = { [weak view] in view?.invalidateIntrinsicContentSize() }
        tv.onMovedToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.applyFocus()
        }
        tv.setAccessibilityPlaceholderValue(placeholder)
        context.coordinator.viewForFocus = tv
        return view
    }

    func updateNSView(_ view: MultilineFieldView, context: Context) {
        context.coordinator.parent = self
        let tv = view.textView
        if tv.placeholder != placeholder {
            tv.placeholder = placeholder
            tv.setAccessibilityPlaceholderValue(placeholder)
            tv.needsDisplay = true
        }
        context.coordinator.sync(tv)
        context.coordinator.applyFocus()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: MultilineFieldView, context: Context) -> CGSize? {
        context.coordinator.parent = self
        context.coordinator.sync(view.textView)
        return view.fittingSize(width: proposal.width ?? 200)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultilineField
        init(_ parent: MultilineField) { self.parent = parent; lastBinding = parent.text }

        /// The undo history belongs to this field, not to the window it lives in: a panel that lives for the whole
        /// run would keep ranges of texts that are gone, and share them with the next responder.
        let undo = UndoManager()
        /// The last value of the binding this coordinator saw or wrote. A write from outside exists only when the
        /// binding differs from it: the view differing is no proof (marked text never reaches the binding).
        private var lastBinding: String
        /// A write from outside arrived while an input method had marked text: the view takes it when the
        /// composition ends.
        private var externalWritePending = false

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        /// The text of the view follows the binding. While an input method has marked text nothing is replaced
        /// (that would end the composition): a re-render with an unchanged binding does nothing, a real write waits
        /// for the end of the composition. A replacement that did not come from the user forgets the undo history
        /// of the text that went.
        func sync(_ tv: MultilineTextView) {
            let text = parent.text
            if tv.hasMarkedText() {
                if text != lastBinding { externalWritePending = true; lastBinding = text }
                return
            }
            lastBinding = text
            externalWritePending = false
            guard tv.string != text else { return }
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            tv.contentRevision &+= 1
            undo.removeAllActions()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? MultilineTextView else { return }
            // A binding that is not the value last seen or written is a write that no update has brought yet
            // (the user's edit came first in the same turn): the write wins.
            if parent.text != lastBinding { externalWritePending = true; lastBinding = parent.text }
            if externalWritePending {
                // A write from outside is waiting: while composing it is not overwritten by the marked text,
                // and when the composition is over the binding wins.
                if !tv.hasMarkedText() { sync(tv) }
                return
            }
            guard tv.string != parent.text else { return }
            lastBinding = tv.string
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let name = NSStringFromSelector(selector)
            if name == "insertTab:" { textView.window?.selectNextKeyView(textView); return true }
            if name == "insertBacktab:" { textView.window?.selectPreviousKeyView(textView); return true }
            var modifiers: MultilineInput.Modifiers = []
            let flags = (textView as? MultilineTextView)?.keyModifiers ?? []
            if flags.contains(.shift) { modifiers.insert(.shift) }
            if flags.contains(.option) { modifiers.insert(.option) }
            if flags.contains(.control) { modifiers.insert(.control) }
            if flags.contains(.command) { modifiers.insert(.command) }
            switch MultilineInput.action(for: MultilineInput.command(forSelector: name),
                                         modifiers: modifiers, composing: textView.hasMarkedText()) {
            case .send:
                parent.onSubmit()
                return true
            case .insertLineBreak:
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            case .ignore:
                return true
            case .confirmComposition:
                textView.unmarkText()
                return true
            case .passthrough:
                return false
            }
        }

        /// The field gained or lost the keyboard: the binding follows (outside the update that may be running).
        func focusChanged(_ focused: Bool) {
            guard parent.isFocused != focused else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.isFocused != focused else { return }
                self.parent.isFocused = focused
            }
        }

        /// The binding asks for the keyboard (or to give it back).
        func applyFocus() {
            guard let view = viewForFocus, let window = view.window else { return }
            let wants = parent.isFocused
            let has = window.firstResponder === view
            guard wants != has else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, let window = view.window else { return }
                let wants = self.parent.isFocused
                if wants, window.firstResponder !== view { window.makeFirstResponder(view) }
                else if !wants, window.firstResponder === view { window.makeFirstResponder(nil) }
            }
        }

        weak var viewForFocus: MultilineTextView?
    }
}

/// Scroll view around the text view; reports the height the text needs.
final class MultilineFieldView: NSScrollView {
    let textView: MultilineTextView

    init() {
        // TextKit 1 stack, built by hand: `layoutManager` and `usedRect` stay available and cheap.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        textView = MultilineTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 16), textContainer: container)
        super.init(frame: .zero)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .none
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Narrower than this the field is not laid out: SwiftUI probes the minimum width (0), and wrapping a long
    /// text one glyph per line costs more than typing.
    static let minUsableWidth: CGFloat = 24

    private var cached: (revision: Int, width: CGFloat, height: CGFloat, scrolls: Bool)?

    /// Width given, height of the text clamped to 1...5 lines. One layout per change of text or width.
    func fittingSize(width: CGFloat) -> CGSize {
        let w = max(1, width.isFinite ? width : 200)
        let inset = textView.textContainerInset
        let lineHeight = ceil(textView.layoutManager!.defaultLineHeight(for: textView.font ?? MultilineTextView.defaultFont))
        let oneLine = lineHeight + 2 * inset.height
        if w < Self.minUsableWidth { return CGSize(width: w, height: oneLine) }
        if let c = cached, c.revision == textView.contentRevision, c.width == w {
            verticalScrollElasticity = c.scrolls ? .allowed : .none
            return CGSize(width: w, height: c.height)
        }
        let container = textView.textContainer!
        let layout = textView.layoutManager!
        container.containerSize = NSSize(width: w - 2 * inset.width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let content = ceil(layout.usedRect(for: container).height) + 2 * inset.height
        let height = MultilineInput.height(content: content, lineHeight: oneLine)
        let scrolls = MultilineInput.scrolls(content: content, lineHeight: oneLine)
        verticalScrollElasticity = scrolls ? .allowed : .none
        cached = (textView.contentRevision, w, height, scrolls)
        return CGSize(width: w, height: height)
    }
}

final class MultilineTextView: NSTextView {
    static let defaultFont = NSFont.systemFont(ofSize: 13)
    /// The colours of a plain SwiftUI TextField (measured on its render, in light and dark), so a one line
    /// field looks as it always did. Both follow the appearance of the window.
    static let fieldTextColor = NSColor.textColor
    static let fieldPlaceholderColor = NSColor.textColor.withAlphaComponent(0.8)

    var placeholder = ""
    var onFocusChange: ((Bool) -> Void)?
    var onMovedToWindow: (() -> Void)?
    /// The marked text changed (no `textDidChange` for it): the size is asked again.
    var onMarkedTextChange: (() -> Void)?

    override func unmarkText() {
        super.unmarkText()
        contentRevision &+= 1
        onMarkedTextChange?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        contentRevision &+= 1
        onMarkedTextChange?()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        font = Self.defaultFont
        textColor = Self.fieldTextColor
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        // Text replacement and spelling correction follow the system settings, as the old field's did.
        isAutomaticTextReplacementEnabled = NSSpellChecker.isAutomaticTextReplacementEnabled
        isAutomaticSpellingCorrectionEnabled = NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        isAutomaticLinkDetectionEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        typingAttributes = [.font: Self.defaultFont, .foregroundColor: Self.fieldTextColor]
        // Like the old field: no drag type. Whatever is dragged on the island is the island's (upload).
        unregisterDraggedTypes()
    }

    /// NSTextView registers its drag types again when its settings change: it keeps none.
    override func updateDragTypeRegistration() { unregisterDraggedTypes() }

    /// Bumped on every change of the text (typing, undo, a write from the binding): the height is cached on it.
    var contentRevision = 0

    override func didChangeText() {
        contentRevision &+= 1
        super.didChangeText()
    }

    /// Text typed by a key never carries a raw control character (a Shift+keypad Enter gave U+0003).
    /// The line break the field inserts itself is a plain `\n` and passes; so does a tab (Option+Tab).
    /// An empty string is the text system's way to cancel a composition or delete a range: it goes through as is.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let raw = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Marked text can end here without `unmarkText` or a change notification: ask for the size again.
        defer { contentRevision &+= 1; onMarkedTextChange?() }
        if raw.isEmpty { super.insertText(string, replacementRange: replacementRange); return }
        // The keypad Enter with Shift is declined by the key bindings and arrives as the raw U+0003: it is the
        // Enter, and follows the Return rule where the command would have arrived.
        // During a composition the key only confirms the marked text (a Return does the same).
        if inReturnKey, raw == "\u{03}" {
            // The input context may already have confirmed the marked text when the key reaches here: the state
            // at the press is what counts.
            if composingAtKeyDown || hasMarkedText() { unmarkText(); return }
            doCommand(by: #selector(NSResponder.insertNewline(_:)))
            return
        }
        let clean = MultilineInput.withoutControlCharacters(raw)
        guard !clean.isEmpty else { return }
        super.insertText(clean, replacementRange: replacementRange)
    }

    private var inReturnKey = false
    private var composingAtKeyDown = false

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    /// Modifiers of the key being handled, for the command handler (set only while `keyDown` runs).
    private(set) var keyModifiers: NSEvent.ModifierFlags = []

    /// Every key goes through the input context like in any text view (an accent popup or an autocorrect bubble
    /// may take a Return); only what it declines reaches the field's own rules.
    override func keyDown(with event: NSEvent) {
        keyModifiers = event.modifierFlags
        inReturnKey = MultilineInput.isReturnKey(keyCode: event.keyCode)
        composingAtKeyDown = hasMarkedText()
        defer { keyModifiers = []; inReturnKey = false; composingAtKeyDown = false }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        // Losing the keyboard ends a composition (the accent is kept as typed), so a write that waits for its end
        // lands now instead of showing the text of a message that is gone.
        if hasMarkedText() { unmarkText() }
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMovedToWindow?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let pad = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: NSPoint(x: origin.x + pad, y: origin.y),
                                       withAttributes: [.font: font ?? Self.defaultFont,
                                                        .foregroundColor: Self.fieldPlaceholderColor])
    }
}
