import Foundation
import CoreGraphics

/// A short glance, then a return to center, then a pause.
struct IdleMicroAnimation {
    static let pauseRange: ClosedRange<Double> = 20...40
    static let duration: Double = 1.4
    static let blinkDelay: Double = 0.5

    let startTime: TimeInterval
    let direction: CGPoint
    let blinks: Bool

    static func random(startTime: TimeInterval) -> Self {
        let directions = [CGPoint(x: -0.75, y: 0), CGPoint(x: 0.75, y: 0),
                          CGPoint(x: 0, y: 0.5), CGPoint(x: -0.6, y: 0.4),
                          CGPoint(x: 0.6, y: 0.4)]
        return Self(startTime: startTime, direction: directions.randomElement()!,
                    blinks: Bool.random())
    }

    static func isEligible(enabled: Bool, visible: Bool, resting: Bool,
                           idle: Bool, reduceMotion: Bool) -> Bool {
        enabled && visible && resting && idle && !reduceMotion
    }

    func look(at time: TimeInterval) -> CGPoint {
        let elapsed = time - startTime
        let weight: Double
        if elapsed < 0.25 {
            weight = smoothStep(elapsed / 0.25)
        } else if elapsed < 0.75 {
            weight = 1
        } else {
            weight = 1 - smoothStep((elapsed - 0.75) / 0.4)
        }
        return CGPoint(x: direction.x * weight, y: direction.y * weight)
    }

    private func smoothStep(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
