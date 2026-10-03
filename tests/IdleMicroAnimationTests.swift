import Foundation
import CoreGraphics

@main
enum IdleMicroAnimationTests {
    static func main() {
        precondition(!IdleMicroAnimation.isEligible(enabled: false, visible: true,
                        resting: true, idle: true, reduceMotion: false))
        precondition(!IdleMicroAnimation.isEligible(enabled: true, visible: false,
                        resting: true, idle: true, reduceMotion: false))
        precondition(!IdleMicroAnimation.isEligible(enabled: true, visible: true,
                        resting: false, idle: true, reduceMotion: false))
        precondition(!IdleMicroAnimation.isEligible(enabled: true, visible: true,
                        resting: true, idle: false, reduceMotion: false))
        precondition(!IdleMicroAnimation.isEligible(enabled: true, visible: true,
                        resting: true, idle: true, reduceMotion: true))
        precondition(IdleMicroAnimation.isEligible(enabled: true, visible: true,
                        resting: true, idle: true, reduceMotion: false))

        let burst = IdleMicroAnimation(startTime: 100, direction: CGPoint(x: -0.75, y: 0.4), blinks: true)
        // No movement before the burst, or after returning to center.
        for time in [99.0, 100, 101.15, 100 + IdleMicroAnimation.duration, 1000] {
            let look = burst.look(at: time)
            precondition(abs(look.x) < 0.000001 && abs(look.y) < 0.000001)
        }
        // The glance reaches the selected direction, then smoothly returns.
        precondition(burst.look(at: 100.5) == burst.direction)
        let outgoing = burst.look(at: 100.125)
        let returning = burst.look(at: 100.95)
        precondition(abs(outgoing.x - returning.x) < 0.000001)
        precondition(outgoing.x < 0 && outgoing.y > 0)
        for step in 0...140 {
            let look = burst.look(at: 100 + Double(step) / 100)
            precondition(look.x >= -0.75 && look.x <= 0)
            precondition(look.y >= 0 && look.y <= 0.4)
        }
        // A blink has time to finish before the timeline pauses again.
        precondition(IdleMicroAnimation.duration - IdleMicroAnimation.blinkDelay > 0.2)
        for _ in 0..<100 {
            let random = IdleMicroAnimation.random(startTime: 0)
            precondition(random.direction != .zero)
            precondition(abs(random.direction.x) <= 1 && abs(random.direction.y) <= 1)
        }
        print("Idle animation eligibility, motion envelope and blink settling passed")
    }
}
