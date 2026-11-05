import Foundation

@main
enum ChatHeightTests {
    static var cases = 0
    static func check(_ ok: Bool, _ msg: String, line: UInt = #line) {
        cases += 1
        if !ok { print("FAIL line \(line): \(msg)"); exit(1) }
    }

    static func main() {
        // Default height: exactly what the chat has always had.
        check(ChatHeight.defaultHeight(messageCount: 0) == 240, "0 messages")
        check(ChatHeight.defaultHeight(messageCount: 1) == 280, "1 message")
        check(ChatHeight.defaultHeight(messageCount: 2) == 300, "2 messages")
        check(ChatHeight.defaultHeight(messageCount: 50) == 300, "many messages")
        check(ChatHeight.defaultHeight(messageCount: -3) == 240, "negative count")

        // Maximum from screen metrics: room below the top of the screen minus the margin, never below 300.
        check(ChatHeight.maximumHeight(availableHeight: 900) == 876, "900 pt screen")
        check(ChatHeight.maximumHeight(availableHeight: 1117.5) == 1093, "fractional height rounds down")
        check(ChatHeight.maximumHeight(availableHeight: 320) == 300, "tiny screen keeps today's cap")
        check(ChatHeight.maximumHeight(availableHeight: 0) == 300, "zero")
        check(ChatHeight.maximumHeight(availableHeight: .nan) == 300, "nan")
        check(ChatHeight.maximumHeight(availableHeight: .infinity) == 300, "infinity")

        let max: CGFloat = 800

        // Never stretched: identical to today for 0, 1 and many messages.
        for n in [0, 1, 2, 7] {
            check(ChatHeight.resolve(messageCount: n, stored: nil, maximum: max)
                  == ChatHeight.defaultHeight(messageCount: n), "unstretched \(n)")
        }
        // Stretched: used for every message count, clamped between default and maximum.
        for n in [0, 1, 2, 7] {
            check(ChatHeight.resolve(messageCount: n, stored: 500, maximum: max) == 500, "stored 500, \(n)")
            check(ChatHeight.resolve(messageCount: n, stored: 5000, maximum: max) == max, "stored above max, \(n)")
            check(ChatHeight.resolve(messageCount: n, stored: 100, maximum: max)
                  == ChatHeight.defaultHeight(messageCount: n), "stored below default, \(n)")
        }
        // A smaller screen clamps without losing the stored value (it is only read, never rewritten).
        check(ChatHeight.resolve(messageCount: 2, stored: 700, maximum: 500) == 500, "screen shrinks")
        check(ChatHeight.resolve(messageCount: 2, stored: 700, maximum: 900) == 700, "screen grows back")
        check(ChatHeight.resolve(messageCount: 2, stored: 700, maximum: 250) == 300, "max below default")
        check(ChatHeight.resolve(messageCount: 0, stored: .nan, maximum: max) == 240, "nan stored")

        // Dragging.
        check(ChatHeight.dragged(start: 300, translation: 120, messageCount: 2, maximum: max) == 420, "drag down")
        check(ChatHeight.dragged(start: 300, translation: 9000, messageCount: 2, maximum: max) == max, "drag past max")
        check(ChatHeight.dragged(start: 420, translation: -9000, messageCount: 2, maximum: max) == 300, "drag past min")
        check(ChatHeight.dragged(start: 240, translation: -50, messageCount: 0, maximum: max) == 240, "min with 0 messages")

        // Committing a drag: back at the default height forgets the stretch.
        check(ChatHeight.committed(height: 300, messageCount: 2) == nil, "commit at default")
        check(ChatHeight.committed(height: 300.5, messageCount: 2) == nil, "commit within epsilon")
        check(ChatHeight.committed(height: 450, messageCount: 2) == 450, "commit stretched")
        check(ChatHeight.committed(height: 260, messageCount: 0) == 260, "commit small stretch with 0 messages")

        // canStretch / isStretched.
        check(ChatHeight.canStretch(messageCount: 2, maximum: 300) == false, "no room")
        check(ChatHeight.canStretch(messageCount: 2, maximum: 302) == true, "room")
        check(ChatHeight.isStretched(messageCount: 2, stored: nil, maximum: max) == false, "not stretched")
        check(ChatHeight.isStretched(messageCount: 2, stored: 450, maximum: max) == true, "stretched")
        check(ChatHeight.isStretched(messageCount: 2, stored: 250, maximum: max) == false, "stored below default")

        // Toggle: default → maximum → default; in between → default.
        check(ChatHeight.toggled(messageCount: 2, stored: nil, maximum: max) == max, "default → max")
        check(ChatHeight.toggled(messageCount: 2, stored: max, maximum: max) == nil, "max → default")
        check(ChatHeight.toggled(messageCount: 2, stored: 450, maximum: max) == nil, "in between → default")
        check(ChatHeight.toggled(messageCount: 2, stored: nil, maximum: 300) == nil, "no room: stays default")

        // Panel height: 560 until stretched, then tall enough for the maximum, never below 560.
        check(ChatHeight.panelHeight(everStretched: false, maximum: 900) == 560, "panel never stretched")
        check(ChatHeight.panelHeight(everStretched: true, maximum: 900) == 900, "panel stretched")
        check(ChatHeight.panelHeight(everStretched: true, maximum: 300) == 560, "panel small screen")
        // The island always fits in the panel.
        for n in [0, 1, 2, 9] {
            for stored: CGFloat? in [nil, 260, 500, 5000] {
                let h = ChatHeight.resolve(messageCount: n, stored: stored, maximum: 900)
                check(h <= ChatHeight.panelHeight(everStretched: stored != nil, maximum: 900), "island fits panel")
            }
        }

        // UserDefaults decoding.
        check(ChatHeight.storedValue(from: 0) == nil, "unset")
        check(ChatHeight.storedValue(from: -5) == nil, "negative")
        check(ChatHeight.storedValue(from: .nan) == nil, "nan raw")
        check(ChatHeight.storedValue(from: 512) == 512, "valid")

        // Scroll policy.
        check(ChatScrollPolicy.isAtBottom(contentOffsetY: 0, contentHeight: 100, viewportHeight: 200), "short content")
        check(ChatScrollPolicy.isAtBottom(contentOffsetY: 800, contentHeight: 1000, viewportHeight: 200), "exact bottom")
        check(ChatScrollPolicy.isAtBottom(contentOffsetY: 780, contentHeight: 1000, viewportHeight: 200), "within tolerance")
        check(!ChatScrollPolicy.isAtBottom(contentOffsetY: 400, contentHeight: 1000, viewportHeight: 200), "scrolled up")

        // Edge cases: negative room, infinite stored value, tolerance boundary, stored above the maximum.
        check(ChatHeight.maximumHeight(availableHeight: -500) == 300, "negative room")
        check(ChatHeight.storedValue(from: .infinity) == nil, "infinite raw")
        check(ChatScrollPolicy.isAtBottom(contentOffsetY: 776, contentHeight: 1000, viewportHeight: 200), "exactly at tolerance")
        check(!ChatScrollPolicy.isAtBottom(contentOffsetY: 775.9, contentHeight: 1000, viewportHeight: 200), "just past tolerance")
        check(ChatHeight.toggled(messageCount: 2, stored: 5000, maximum: max) == nil, "stored above max is stretched → default")
        check(ChatHeight.isStretched(messageCount: 2, stored: 5000, maximum: max), "stored above max counts as stretched")
        check(ChatHeight.defaultsKey == "chatStretchedHeight", "defaults key is a stable contract")

        // A drag shorter than the dead zone (double click with jitter) keeps what was stored before.
        check(ChatHeight.committedAfterDrag(height: 302, start: 300, startStored: nil, messageCount: 2) == nil, "jitter keeps nil")
        check(ChatHeight.committedAfterDrag(height: 453, start: 450, startStored: 450, messageCount: 2) == 450, "jitter keeps stored")
        check(ChatHeight.committedAfterDrag(height: 303, start: 300, startStored: nil, messageCount: 2) == nil, "3 pt jitter at default")
        check(ChatHeight.committedAfterDrag(height: 304, start: 300, startStored: nil, messageCount: 2) == 304, "4 pt is the first real stretch")
        check(ChatHeight.committedAfterDrag(height: 320, start: 300, startStored: nil, messageCount: 2) == 320, "real stretch")
        check(ChatHeight.committedAfterDrag(height: 300, start: 450, startStored: 450, messageCount: 2) == nil, "dragged back to default")

        // Panel target: grows with the stretch, shrinks only when the screen changes.
        check(ChatHeight.panelTarget(current: 560, everStretched: false, maximum: 900, allowShrink: false) == 560, "never stretched")
        check(ChatHeight.panelTarget(current: 560, everStretched: false, maximum: 900, allowShrink: true) == 560, "never stretched, screen change")
        check(ChatHeight.panelTarget(current: 560, everStretched: true, maximum: 900, allowShrink: false) == 900, "grows")
        check(ChatHeight.panelTarget(current: 1400, everStretched: true, maximum: 900, allowShrink: false) == 1400, "never shrinks")
        check(ChatHeight.panelTarget(current: 1400, everStretched: true, maximum: 900, allowShrink: true) == 900, "shrinks on a new screen")
        check(ChatHeight.panelTarget(current: 1400, everStretched: true, maximum: 300, allowShrink: true) == 560, "small screen keeps 560")

        // Island moved to a smaller screen (relocate): the stored stretch is clamped and the panel shrinks with it.
        check(ChatHeight.resolve(messageCount: 2, stored: 1200, maximum: 700) == 700, "stretch clamped on the smaller screen")
        check(ChatHeight.panelTarget(current: 1300, everStretched: true, maximum: 700, allowShrink: true) == 700, "panel shrinks to the new maximum")
        check(ChatHeight.panelTarget(current: 1300, everStretched: true, maximum: 700, allowShrink: false) == 1300, "no shrink without a screen change")

        // The resizing flag only lives while the drag is real.
        check(ChatHeight.resizeIsLive(resizing: true, primaryButtonDown: true, isChatView: true, isExpanded: true), "live drag")
        check(!ChatHeight.resizeIsLive(resizing: true, primaryButtonDown: false, isChatView: true, isExpanded: true), "button released")
        check(!ChatHeight.resizeIsLive(resizing: true, primaryButtonDown: true, isChatView: false, isExpanded: true), "view changed")
        check(!ChatHeight.resizeIsLive(resizing: true, primaryButtonDown: true, isChatView: true, isExpanded: false), "island folded")
        check(!ChatHeight.resizeIsLive(resizing: false, primaryButtonDown: true, isChatView: true, isExpanded: true), "not resizing")

        // Pin decided from geometry alone.
        typealias M = ChatScrollPolicy.Metrics
        let atBottom = M(offsetY: 800, contentHeight: 1000, viewportHeight: 200)
        let scrolledUp = M(offsetY: 500, contentHeight: 1000, viewportHeight: 200)
        check(ChatScrollPolicy.pinned(after: true, from: atBottom, to: scrolledUp) == false, "user scrolls up unpins")
        check(ChatScrollPolicy.pinned(after: false, from: scrolledUp, to: atBottom) == true, "back at the bottom pins")
        check(ChatScrollPolicy.pinned(after: true, from: atBottom, to: M(offsetY: 800, contentHeight: 1100, viewportHeight: 200)) == true, "streaming growth keeps pinned")
        check(ChatScrollPolicy.pinned(after: false, from: scrolledUp, to: M(offsetY: 500, contentHeight: 1100, viewportHeight: 200)) == false, "growth keeps unpinned")
        check(ChatScrollPolicy.pinned(after: true, from: atBottom, to: M(offsetY: 600, contentHeight: 1000, viewportHeight: 400)) == true, "stretching the viewport clamps the offset without unpinning")
        check(ChatScrollPolicy.pinned(after: true, from: atBottom, to: M(offsetY: 800, contentHeight: 1000, viewportHeight: 100)) == true, "shrinking the viewport keeps pinned")
        check(ChatScrollPolicy.pinned(after: true, from: atBottom, to: M(offsetY: 799.5, contentHeight: 1000, viewportHeight: 200)) == true, "sub-point move stays pinned")
        check(ChatScrollPolicy.pinned(after: false, from: scrolledUp, to: M(offsetY: 300, contentHeight: 1000, viewportHeight: 200)) == false, "stays unpinned scrolling further up")
        check(ChatScrollPolicy.pinned(after: true, from: M(offsetY: 0, contentHeight: 100, viewportHeight: 200), to: M(offsetY: 0, contentHeight: 100, viewportHeight: 200)) == true, "short content")

        // A panel that grows keeps the edge the island is anchored to: the top at the notch and the top corners, the bottom
        // in the bottom corners (the island sits at the panel's base there, so growing downwards would push it off screen).
        let bottomCorner = ChatHeight.panelOriginY(currentMinY: 100, currentHeight: 560, newHeight: 900, anchoredToBottom: true)
        check(bottomCorner == 100, "bottom corner + everStretched: the panel grows upwards, minY stays")
        check(bottomCorner + 900 == 1000, "bottom corner: the top edge moves up by the growth")
        let topEdge = ChatHeight.panelOriginY(currentMinY: 400, currentHeight: 560, newHeight: 900, anchoredToBottom: false)
        check(topEdge == 60, "notch and top corners: the panel grows downwards, maxY stays")
        check(topEdge + 900 == 400 + 560, "top anchor: maxY unchanged")
        check(ChatHeight.panelOriginY(currentMinY: 100, currentHeight: 900, newHeight: 700, anchoredToBottom: true) == 100, "bottom anchor shrinking keeps minY")
        check(ChatHeight.panelOriginY(currentMinY: 60, currentHeight: 900, newHeight: 700, anchoredToBottom: false) == 260, "top anchor shrinking keeps maxY")

        print("Chat height and scroll policy: \(cases) cases passed")
    }
}
