import Foundation
import CoreGraphics

@main
enum IslandGazeGeometryTests {
    static func main() {
        // Actual desktop arrangement: central 2560×1080, portrait display on the
        // left (-1080,-427), landscape display on the right (2560,0).
        let central = CGRect(x: 920, y: 760, width: 720, height: 320)
        let bot = CGPoint(x: 40, y: 16)
        let cases: [(CGRect, CGPoint, Int, Int)] = [
            (central, CGPoint(x: 1148, y: 1064), 0, 0), // Cursor at Mochi's center
            (central, CGPoint(x: -1, y: -426), -1, -1), // Left monitor, bottom-right
            (central, CGPoint(x: 2561, y: 1000), 1, -1), // Right monitor, left edge
            (central, CGPoint(x: 1500, y: 1600), 1, 1), // Monitor above the island
            (central, CGPoint(x: 1000, y: -300), -1, -1), // Monitor below the island
            // Mochi itself hosted on an offset secondary display.
            (CGRect(x: -900, y: 1173, width: 720, height: 320),
             CGPoint(x: -200, y: 1000), 1, -1),
            (CGRect(x: -900, y: 1173, width: 720, height: 320),
             CGPoint(x: -1000, y: 1600), -1, 1),
            (CGRect(x: 3160, y: 760, width: 720, height: 320),
             CGPoint(x: 4400, y: 1000), 1, -1),
            (CGRect(x: 3160, y: 760, width: 720, height: 320),
             CGPoint(x: 2000, y: 1100), -1, 1),
        ]
        for (panel, mouse, xSign, ySign) in cases {
            let look = IslandGazeGeometry.direction(mouse: mouse, panelFrame: panel,
                                                   islandWidth: 344, botCenter: bot)
            precondition(sign(look.x) == xSign && sign(look.y) == ySign)
            precondition(abs(look.x) <= 1 && abs(look.y) <= 1)
        }

        // Moving the whole desktop cannot change the direction toward a cursor.
        let mouse = CGPoint(x: -1, y: -426)
        let reference = IslandGazeGeometry.direction(mouse: mouse, panelFrame: central,
                                                     islandWidth: 344, botCenter: bot)
        for shift in [CGPoint(x: -2560, y: 500), CGPoint(x: 2560, y: -427),
                      CGPoint(x: 0, y: 1920)] {
            let moved = IslandGazeGeometry.direction(
                mouse: CGPoint(x: mouse.x + shift.x, y: mouse.y + shift.y),
                panelFrame: central.offsetBy(dx: shift.x, dy: shift.y),
                islandWidth: 344, botCenter: bot
            )
            precondition(abs(moved.x - reference.x) < 0.000001)
            precondition(abs(moved.y - reference.y) < 0.000001)
        }
        print("Island gaze geometry: 12 cases passed")
    }

    private static func sign(_ value: CGFloat) -> Int {
        value == 0 ? 0 : (value < 0 ? -1 : 1)
    }
}
