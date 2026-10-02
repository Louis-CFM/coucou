import Foundation
import CoreGraphics

enum IslandGazeGeometry {
    /// Cursor and panel use global AppKit coordinates. Bot center is measured
    /// from the island's top-left corner, with the island centered in the panel.
    static func direction(mouse: CGPoint, panelFrame: CGRect,
                          islandWidth: CGFloat, botCenter: CGPoint) -> CGPoint {
        let bot = CGPoint(x: panelFrame.midX - islandWidth / 2 + botCenter.x,
                          y: panelFrame.maxY - botCenter.y)
        return CGPoint(x: tanh((mouse.x - bot.x) / 260),
                       y: tanh((mouse.y - bot.y) / 200))
    }
}
