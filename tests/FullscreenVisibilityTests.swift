import AppKit
@main enum FullscreenVisibilityTests {
    static func main() {
        let central = CGRect(x: 0, y: 0, width: 2560, height: 1080)
        let right = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        let left = CGRect(x: -1080, y: -413, width: 1080, height: 1920)
        precondition(FullscreenVisibility.shouldHide(screen: central, windows: [central]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [CGRect(x: 0, y: 0, width: 2560, height: 1020)]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [right]))
        precondition(FullscreenVisibility.shouldHide(screen: right, windows: [right]))
        precondition(FullscreenVisibility.shouldHide(screen: left, windows: [left]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [CGRect(x: 0, y: 24, width: 2560, height: 1056)]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: []))
        precondition(!FullscreenVisibility.shouldHide(screen: .zero, windows: [.zero]))
        precondition(FullscreenVisibility.shouldHide(screen: central, windows: [central.offsetBy(dx: 1, dy: 1)]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [CGRect(x: 100, y: 100, width: 500, height: 300)]))
        let ordinary = CGRect(x: central.midX - 250, y: central.midY - 150, width: 500, height: 300)
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [ordinary, central]))
        precondition(FullscreenVisibility.shouldHide(screen: central, windows: [right, central]))
        precondition(FullscreenVisibility.shouldHide(screen: central, windows: [central, ordinary]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [central.offsetBy(dx: 3, dy: 0)]))
        // Real Zen regression: separate layer-0 toolbar in front of fullscreen content.
        for y in [0.0, 15.0, 30.0] {
            let toolbar = CGRect(x: 0, y: y, width: 2560, height: 68)
            precondition(FullscreenVisibility.shouldHide(screen: central, windows: [toolbar, central]))
        }
        let toolbar = CGRect(x: 2560, y: 0, width: 1920, height: 68)
        precondition(FullscreenVisibility.shouldHide(screen: right, windows: [toolbar, right]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [toolbar, right]))
        precondition(!FullscreenVisibility.shouldHide(screen: central, windows: [CGRect(x: 0, y: 0, width: 2560, height: 68), CGRect(x: 0, y: 30, width: 2560, height: 1050)]))
        // Actual swipe frames observed between DBeaver and Zen: preserve visibility.
        for x in [-297.0, 24.0, 57.0, 568.0] {
            let sliding = central.offsetBy(dx: x, dy: 0)
            precondition(FullscreenVisibility.decision(screen: central, windows: [sliding]) == nil)
        }
        precondition(FullscreenVisibility.decision(screen: central, windows: [central]) == true)
        precondition(FullscreenVisibility.decision(screen: central, windows: []) == false)
        precondition(FullscreenVisibility.decision(screen: central, windows: [central.offsetBy(dx: -1300, dy: 0), central.offsetBy(dx: 1324, dy: 0)]) == nil)
        precondition(FullscreenVisibility.decision(screen: central, windows: [right]) == false)
        let restingPanel = CGRect(x: 920, y: 0, width: 720, height: 320)
        precondition(FullscreenVisibility.isPanelSettled(expected: restingPanel, actual: restingPanel))
        precondition(!FullscreenVisibility.isPanelSettled(expected: restingPanel, actual: nil))
        precondition(!FullscreenVisibility.isPanelSettled(expected: restingPanel, actual: restingPanel.offsetBy(dx: 2314, dy: 0)))
        precondition(!FullscreenVisibility.isPanelSettled(expected: restingPanel, actual: restingPanel.offsetBy(dx: -1702, dy: 0)))
        precondition(!FullscreenVisibility.isPanelSettled(expected: restingPanel, actual: CGRect(x: 920, y: 0, width: 706, height: 314)))
        precondition(FullscreenVisibility.isPanelSettled(expected: restingPanel.offsetBy(dx: -1080, dy: -413), actual: restingPanel.offsetBy(dx: -1080, dy: -413)))
        print("Fullscreen visibility: 34 coverage, toolbar, swipe-gap, multi-display and arrival-frame cases passed")
    }
}
