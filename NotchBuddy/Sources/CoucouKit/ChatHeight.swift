import Foundation
import CoreGraphics

/// Height of the chat card in the island (the `.prompt` view), and the user's stretch of it.
/// Pure logic, no UI: the island, the panel and the tests all read it from here.
enum ChatHeight {
    /// The chat as it always was: 240 pt, plus 40 pt per message, up to 300 pt.
    static let base: CGFloat = 240
    static let perMessage: CGFloat = 40
    static let defaultCap: CGFloat = 300
    /// Height of the island panel when the chat has never been stretched.
    static let basePanelHeight: CGFloat = 560
    /// Free space kept between the bottom of the stretched chat and the screen (or Dock).
    static let bottomMargin: CGFloat = 24
    /// Two heights closer than this are the same height.
    static let epsilon: CGFloat = 1
    /// A drag that moved the grip less than this is a click with some jitter (a double click), not a stretch.
    static let dragDeadZone: CGFloat = 4
    /// UserDefaults key of the stretch the user chose.
    static let defaultsKey = "chatStretchedHeight"

    /// Height of the chat when the user never stretched it.
    static func defaultHeight(messageCount: Int) -> CGFloat {
        min(defaultCap, base + CGFloat(max(0, messageCount)) * perMessage)
    }

    /// Tallest the chat may be. The island is glued to the top of the screen, so what fits is the
    /// distance from the top of the screen to the bottom of the usable area (above the Dock), minus a margin.
    /// Never below the default cap: a tiny screen keeps today's chat.
    static func maximumHeight(availableHeight: CGFloat) -> CGFloat {
        guard availableHeight.isFinite else { return defaultCap }
        return max(defaultCap, (availableHeight - bottomMargin).rounded(.down))
    }

    /// Height to show. `stored` is what the user chose (nil = never stretched, or reset); it is kept
    /// raw so that a bigger screen restores it, and clamped here between today's height and `maximum`.
    static func resolve(messageCount: Int, stored: CGFloat?, maximum: CGFloat) -> CGFloat {
        let minimum = defaultHeight(messageCount: messageCount)
        guard let stored, stored.isFinite else { return minimum }
        return min(max(stored, minimum), max(minimum, maximum))
    }

    /// Height while dragging the grip: `start` plus the drag, between today's height and `maximum`.
    static func dragged(start: CGFloat, translation: CGFloat, messageCount: Int, maximum: CGFloat) -> CGFloat {
        resolve(messageCount: messageCount, stored: start + translation, maximum: maximum)
    }

    /// What to remember when a drag ends: nil when the chat is back at its default height.
    static func committed(height: CGFloat, messageCount: Int) -> CGFloat? {
        height <= defaultHeight(messageCount: messageCount) + epsilon ? nil : height
    }

    /// What to remember when the drag of the grip ends. A drag shorter than the dead zone is a double click
    /// with jitter: the stretch from before the drag (`startStored`) stays as it was.
    static func committedAfterDrag(height: CGFloat, start: CGFloat, startStored: CGFloat?,
                                   messageCount: Int) -> CGFloat? {
        abs(height - start) < dragDeadZone
            ? startStored
            : committed(height: height, messageCount: messageCount)
    }

    /// True when the chat is taller than its default height.
    static func isStretched(messageCount: Int, stored: CGFloat?, maximum: CGFloat) -> Bool {
        resolve(messageCount: messageCount, stored: stored, maximum: maximum)
            > defaultHeight(messageCount: messageCount) + epsilon
    }

    /// Whether the screen leaves any room to stretch.
    static func canStretch(messageCount: Int, maximum: CGFloat) -> Bool {
        maximum > defaultHeight(messageCount: messageCount) + epsilon
    }

    /// Double click on the grip, or the header button: stretched → back to the default height (nil);
    /// at the default height → the maximum.
    static func toggled(messageCount: Int, stored: CGFloat?, maximum: CGFloat) -> CGFloat? {
        guard canStretch(messageCount: messageCount, maximum: maximum) else { return nil }
        return isStretched(messageCount: messageCount, stored: stored, maximum: maximum) ? nil : maximum
    }

    /// Height of the island panel. 560 pt until the chat has been stretched; then tall enough
    /// for the maximum (the panel stays transparent and click-through outside the island).
    static func panelHeight(everStretched: Bool, maximum: CGFloat) -> CGFloat {
        everStretched ? max(basePanelHeight, maximum) : basePanelHeight
    }

    /// Height the panel should have. `allowShrink` is for a change of screen; otherwise the panel never
    /// shrinks, so the island can animate down inside it.
    static func panelTarget(current: CGFloat, everStretched: Bool, maximum: CGFloat, allowShrink: Bool) -> CGFloat {
        let target = panelHeight(everStretched: everStretched, maximum: maximum)
        return everStretched && !allowShrink ? max(target, current) : target
    }

    /// Where the panel's bottom edge goes when its height changes. The island is anchored to the panel's base in the bottom corners
    /// (keep `minY`) and to its top elsewhere (keep `maxY`), so a stretched chat never pushes the island off the screen.
    static func panelOriginY(currentMinY: CGFloat, currentHeight: CGFloat, newHeight: CGFloat, anchoredToBottom: Bool) -> CGFloat {
        anchoredToBottom ? currentMinY : currentMinY + currentHeight - newHeight
    }

    /// Whether a drag of the grip is still real. The flag `chatResizing` is a promise that the primary
    /// button is down on the chat; if the gesture was cancelled or the view went away, it must not outlive that.
    static func resizeIsLive(resizing: Bool, primaryButtonDown: Bool, isChatView: Bool, isExpanded: Bool) -> Bool {
        resizing && primaryButtonDown && isChatView && isExpanded
    }

    /// Rebuilds a stored value from UserDefaults: only a positive, finite number counts.
    static func storedValue(from raw: Double) -> CGFloat? {
        raw.isFinite && raw > 0 ? CGFloat(raw) : nil
    }
}

/// Auto-scroll of a message list: follow the newest text unless the user scrolled up.
enum ChatScrollPolicy {
    /// Distance from the bottom that still counts as "at the bottom".
    static let tolerance: CGFloat = 24

    static func isAtBottom(contentOffsetY: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        // Content shorter than the viewport is always at the bottom.
        contentOffsetY + viewportHeight >= contentHeight - tolerance
    }

    struct Metrics: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var viewportHeight: CGFloat
        var atBottom: Bool {
            ChatScrollPolicy.isAtBottom(contentOffsetY: offsetY, contentHeight: contentHeight,
                                        viewportHeight: viewportHeight)
        }
    }

    /// Whether to keep following the newest text after the scroll geometry changed. Decided from geometry
    /// alone (a wheel, a trackpad and a scroller all look the same): back at the bottom pins; the offset
    /// moving up while neither the content nor the viewport changed size is the user scrolling away, and
    /// unpins. Growth of the content (streaming) or of the viewport (stretching the chat) never unpins.
    static func pinned(after previous: Bool, from old: Metrics, to new: Metrics) -> Bool {
        if new.atBottom { return true }
        let userMovedUp = new.offsetY < old.offsetY - 1
            && new.contentHeight == old.contentHeight
            && new.viewportHeight == old.viewportHeight
        return userMovedUp ? false : previous
    }
}
