import XCTest
@testable import OrcaKit

final class OrcaFormattingTests: XCTestCase {
    let cal = TestClock.utc
    let now = TestClock.now

    func testAgo() {
        let t = Int(now.timeIntervalSince1970)
        XCTAssertEqual(OrcaFormatting.ago(since: t - 5, now: now), "now")
        XCTAssertEqual(OrcaFormatting.ago(since: t - 5, now: now, lang: .pt), "agora")
        XCTAssertEqual(OrcaFormatting.ago(since: t - 300, now: now), "5 min")
        XCTAssertEqual(OrcaFormatting.ago(since: t - 3 * 3600, now: now), "3 h")
        XCTAssertEqual(OrcaFormatting.ago(since: t - 2 * 86400, now: now), "2 d")
        XCTAssertEqual(OrcaFormatting.ago(since: t + 100, now: now), "now")
    }

    func testResetText() {
        let t = Int(now.timeIntervalSince1970)
        XCTAssertEqual(OrcaFormatting.resetText(resetsAt: t + 3600, now: now, calendar: cal), "20:25")
        // 2026-10-25 is a Sunday, 4 days out
        XCTAssertEqual(OrcaFormatting.resetText(resetsAt: t + 4 * 86400, now: now, calendar: cal), "sun")
        XCTAssertEqual(OrcaFormatting.resetText(resetsAt: t + 4 * 86400, now: now, calendar: cal, lang: .pt), "dom")
        XCTAssertEqual(OrcaFormatting.resetText(resetsAt: t + 10 * 86400, now: now, calendar: cal), "10/31")
        XCTAssertEqual(OrcaFormatting.resetText(resetsAt: t + 10 * 86400, now: now, calendar: cal, lang: .pt), "31/10")
    }

    func testClampedFraction() {
        XCTAssertEqual(OrcaFormatting.clampedFraction(150), 1)
        XCTAssertEqual(OrcaFormatting.clampedFraction(-3), 0)
        XCTAssertEqual(OrcaFormatting.clampedFraction(nil), 0)
        XCTAssertEqual(OrcaFormatting.clampedFraction(50), 0.5)
    }

    func testOneLine() {
        XCTAssertEqual(OrcaFormatting.oneLine("a\n  b\tc", limit: 10), "a b c")
        XCTAssertNil(OrcaFormatting.oneLine("  \n ", limit: 10))
        XCTAssertEqual(OrcaFormatting.oneLine("abcdef", limit: 4), "abc…")
    }

    func testPRText() {
        XCTAssertEqual(OrcaFormatting.prText(OrcaPullRequest(number: 9, state: "open")), "PR #9 · open")
        XCTAssertNil(OrcaFormatting.prText(nil))
    }
}
