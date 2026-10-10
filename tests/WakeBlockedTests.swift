import Foundation

@main
enum WakeBlockedTests {
    static func main() {
        testNeverBlockWhenCollapsed()
        testApprovalViewExpandedBlocks()
        testQuestionViewExpandedBlocks()
        testPromptViewExpandedBlocks()
        testVoiceResultNeverBlocks()
        testPendingApprovalAlwaysBlocks()
        testOverviewExpandedAllowed()
        testListeningExpandedAllowed()
        testNonRegression_wakeAfterResult()
        print("WakeBlockedTests: all cases passed")
    }

    // MARK: - Collapsed island never blocks (the key fix)

    static func testNeverBlockWhenCollapsed() {
        for view in IslandView.allCases {
            let r = VoiceWakeFilter.wakeBlocked(view: view, mode: .compact, pendingApproval: false)
            precondition(r == nil,
                "compact mode must never block, got '\(r ?? "nil")' for view \(view)")
        }
        for view in IslandView.allCases {
            let r = VoiceWakeFilter.wakeBlocked(view: view, mode: .hidden, pendingApproval: false)
            precondition(r == nil,
                "hidden mode must never block, got '\(r ?? "nil")' for view \(view)")
        }
    }

    // MARK: - Expanded + blocking views

    static func testApprovalViewExpandedBlocks() {
        let r = VoiceWakeFilter.wakeBlocked(view: .approval, mode: .expanded, pendingApproval: false)
        precondition(r != nil, "expanded+approval must block")
        precondition(r == "approval shown", "reason must be 'approval shown', got '\(r!)'")
    }

    static func testQuestionViewExpandedBlocks() {
        let r = VoiceWakeFilter.wakeBlocked(view: .question, mode: .expanded, pendingApproval: false)
        precondition(r != nil, "expanded+question must block")
        precondition(r == "question shown", "reason must be 'question shown', got '\(r!)'")
    }

    static func testPromptViewExpandedBlocks() {
        let r = VoiceWakeFilter.wakeBlocked(view: .prompt, mode: .expanded, pendingApproval: false)
        precondition(r != nil, "expanded+prompt must block")
        precondition(r == "chat shown", "reason must be 'chat shown', got '\(r!)'")
    }

    // MARK: - voiceResult never blocks (the root-cause fix)

    static func testVoiceResultNeverBlocks() {
        // Expanded + voiceResult → still accept (a new wake replaces the result card)
        let expanded = VoiceWakeFilter.wakeBlocked(view: .voiceResult, mode: .expanded, pendingApproval: false)
        precondition(expanded == nil,
            "voiceResult + expanded must not block, got '\(expanded ?? "nil")'")
        // Compact + voiceResult → also accept
        let compact = VoiceWakeFilter.wakeBlocked(view: .voiceResult, mode: .compact, pendingApproval: false)
        precondition(compact == nil,
            "voiceResult + compact must not block, got '\(compact ?? "nil")'")
    }

    // MARK: - pendingApproval always blocks regardless of mode/view

    static func testPendingApprovalAlwaysBlocks() {
        for mode in IslandMode.allCases {
            for view in IslandView.allCases {
                let r = VoiceWakeFilter.wakeBlocked(view: view, mode: mode, pendingApproval: true)
                precondition(r != nil,
                    "pendingApproval=true must always block (mode=\(mode), view=\(view))")
            }
        }
    }

    // MARK: - Non-blocking expanded views

    static func testOverviewExpandedAllowed() {
        let r = VoiceWakeFilter.wakeBlocked(view: .overview, mode: .expanded, pendingApproval: false)
        precondition(r == nil, "expanded+overview must not block")
    }

    static func testListeningExpandedAllowed() {
        // Shouldn't reach wakeDetected while already listening, but the filter itself is permissive.
        let r = VoiceWakeFilter.wakeBlocked(view: .listening, mode: .expanded, pendingApproval: false)
        precondition(r == nil, "expanded+listening must not block at filter level")
    }

    // MARK: - Non-regression: wake accepted after voiceResult+compact (the original bug)

    static func testNonRegression_wakeAfterResult() {
        // Simulate: command ran → island showed .voiceResult → island collapsed
        // (state.view was left as .voiceResult while mode became .compact)
        // All 5 subsequent wakes must be accepted.
        for i in 1...5 {
            let r = VoiceWakeFilter.wakeBlocked(view: .voiceResult, mode: .compact, pendingApproval: false)
            precondition(r == nil,
                "wake \(i) after voiceResult+compact must be accepted, got '\(r ?? "nil")'")
        }
    }
}
