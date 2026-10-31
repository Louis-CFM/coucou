import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the island lives: at the notch (top centre), or in one of the screen's four corners.
/// In a corner it is a small floating pill that opens from its corner, downwards from the top
/// corners (just under the menu bar), upwards from the bottom ones (just above the Dock).
///
/// Pure geometry (tested by scripts/test-island-placement.sh). AppKit coordinates: y goes up.
enum IslandPlacement: String, CaseIterable, Sendable {
    case notch, topLeft, topRight, bottomLeft, bottomRight

    var isCorner: Bool { self != .notch }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isRight: Bool { self == .topRight || self == .bottomRight }

    /// Room the corner island keeps from the screen's edges (inside the visible frame).
    static let margin: CGFloat = 10
    /// The island panel is wider than the open island; this much empty room on each side
    /// (Mochi's hearts, the shadow). Same value as (panel width − open width) / 2.
    static let side: CGFloat = 40
    /// A drop of Mochi this close to a corner of the screen moves the island there.
    static let snapDistance: CGFloat = 180
    /// The resting island in a corner: a square tile with rounded corners, Mochi alone in it.
    static let tile: CGFloat = 60
    static let tileCorner: CGFloat = 18
    /// Hovering the tile: the other pills come out of it one after the other, as small tiles
    /// along the screen's edge (the size of each, and the room between two).
    static let bubble: CGFloat = 40
    static let bubbleGap: CGFloat = 8
    /// Open in a corner, the circle of Mochis is centred this far from the island's corner…
    static let cornerInset: CGFloat = 50
    /// …and Mochi sits nearer to them, this much further in on each side.
    static let cornerPull: CGFloat = 30
    /// …raised a little: his body is drawn a bit below the middle of his canvas, so the room
    /// above him and beside him look the same.
    static let lift: CGFloat = 4
    /// The other pills' Mochis sit on a quarter circle of this radius around him, far enough
    /// apart for their names and for two of them to cross when they swap.
    static let arcRadius: CGFloat = 150
    /// The room Mochi and his circle take in the corner of the open island (the card has the rest).
    static let cornerColumn: CGFloat = 230
    /// The home view open in a corner (the Mail card reading a message: `homeReadingSize`).
    static let homeSize = CGSize(width: 640, height: 260)
    static let homeReadingSize = CGSize(width: 640, height: 320)

    /// The placement the views read without reaching AppState (set by AppState.islandPlacement).
    nonisolated(unsafe) static var current: IslandPlacement = .notch

    /// The centre of the circle the other Mochis sit on, in an open island of `size`, in the
    /// island's own coordinates (y down): near its corner.
    func cornerArcCenter(in size: CGSize) -> CGPoint {
        let i = Self.cornerInset
        return CGPoint(x: isRight ? size.width - i : i,
                       y: (isBottom ? size.height - i : i) - Self.lift)
    }

    /// Mochi's centre in an open island (y down): in the corner, pulled towards his circle.
    func cornerBotCenter(in size: CGSize) -> CGPoint {
        let c = cornerArcCenter(in: size), d = Self.cornerPull
        return CGPoint(x: c.x + (isRight ? -d : d), y: c.y + (isBottom ? -d : d))
    }

    /// Hovering the tile: where the other pills' small tiles go (centres, in the tile's own
    /// coordinates, y down), one after the other along the screen's edge, inwards.
    func bubbleCenters(count: Int, tile: CGFloat = IslandPlacement.tile) -> [CGPoint] {
        guard isCorner else { return [] }
        let step = Self.bubble + Self.bubbleGap
        return (0..<count).map { i in
            let d = Self.bubbleGap + Self.bubble / 2 + CGFloat(i) * step
            return CGPoint(x: isRight ? -d : tile + d, y: tile / 2)
        }
    }

    /// The tile and its small tiles together (tile coordinates, y down): the pointer may go
    /// from one to the other without the island closing them.
    func bubblesRect(count: Int, tile: CGFloat = IslandPlacement.tile) -> CGRect {
        let w = CGFloat(count) * (Self.bubble + Self.bubbleGap)
        return CGRect(x: isRight ? -w : 0, y: 0, width: tile + w, height: tile)
    }

    /// The other pills' Mochis around him (y down): `count` points on the quarter circle that
    /// faces the inside of the screen, from the side along the edge to the side going inwards.
    func arcPoints(count: Int, in size: CGSize) -> [CGPoint] {
        guard count > 0, isCorner else { return [] }
        let c = cornerArcCenter(in: size), r = Self.arcRadius
        // Angles (degrees, y down): the quarter facing away from the corner.
        let (from, to): (Double, Double) = switch self {
        case .topRight: (180, 90)
        case .topLeft: (0, 90)
        case .bottomRight: (180, 270)
        case .bottomLeft: (0, -90)
        case .notch: (0, 0)
        }
        let pad = 4.0
        let a0 = from + (to > from ? pad : -pad), a1 = to - (to > from ? pad : -pad)
        return (0..<count).map { i in
            let t = count == 1 ? 0.5 : Double(i) / Double(count - 1)
            let a = (a0 + (a1 - a0) * t) * .pi / 180
            return CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
        }
    }

    /// The tile a drop at this placement shows (screen coordinates, y up): the corner's resting
    /// island, or a notch-sized bar at the top centre.
    func dropTarget(screen: CGRect, visible: CGRect, panelSize: CGSize) -> CGRect {
        guard isCorner else {
            return CGRect(x: screen.midX - 100, y: screen.maxY - 34, width: 200, height: 34)
        }
        let o = panelOrigin(screen: screen, visible: visible, panelSize: panelSize)
        return islandRect(panelSize: panelSize, size: CGSize(width: Self.tile, height: Self.tile))
            .offsetBy(dx: o.x, dy: o.y)
    }

    /// The panel's origin on the screen. `screen` is the screen's frame, `visible` its visible
    /// frame (without the menu bar and the Dock).
    func panelOrigin(screen: CGRect, visible: CGRect, panelSize: CGSize) -> CGPoint {
        let m = Self.margin, s = Self.side
        switch self {
        case .notch:       return CGPoint(x: screen.midX - panelSize.width / 2, y: screen.maxY - panelSize.height)
        case .topLeft:     return CGPoint(x: visible.minX + m - s, y: visible.maxY - m - panelSize.height)
        case .topRight:    return CGPoint(x: visible.maxX - m + s - panelSize.width, y: visible.maxY - m - panelSize.height)
        case .bottomLeft:  return CGPoint(x: visible.minX + m - s, y: visible.minY + m)
        case .bottomRight: return CGPoint(x: visible.maxX - m + s - panelSize.width, y: visible.minY + m)
        }
    }

    /// The island's rect inside the panel (panel coordinates, y up) for an island of `size`:
    /// centred at the top for the notch, held by its corner otherwise.
    func islandRect(panelSize: CGSize, size: CGSize) -> CGRect {
        let x: CGFloat
        if isLeft { x = Self.side }
        else if isRight { x = panelSize.width - Self.side - size.width }
        else { x = (panelSize.width - size.width) / 2 }
        let y = isBottom ? 0 : panelSize.height - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where Mochi dropped at `point` sends the island: a corner when the drop is near one,
    /// the notch when it is near the top centre, else nil (the drop does what it did before).
    static func snap(_ point: CGPoint, screen: CGRect) -> IslandPlacement? {
        let d = snapDistance
        let nearLeft = point.x - screen.minX < d, nearRight = screen.maxX - point.x < d
        let nearTop = screen.maxY - point.y < d, nearBottom = point.y - screen.minY < d
        if nearTop && nearLeft { return .topLeft }
        if nearTop && nearRight { return .topRight }
        if nearBottom && nearLeft { return .bottomLeft }
        if nearBottom && nearRight { return .bottomRight }
        if screen.maxY - point.y < 90 && abs(point.x - screen.midX) < 220 { return .notch }
        return nil
    }
}
