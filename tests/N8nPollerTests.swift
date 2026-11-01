import Foundation

// n8n execution dates and terminal statuses. Tests n8nExecutionDate and
// n8nTerminalStatuses from NotchBuddy/Sources/App/N8nExecution.swift.

@main
enum N8nPollerTests {
    static var passed = 0
    static var failed = 0

    static func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ desc: String) {
        if actual == expected {
            passed += 1
            print("  ✓ \(desc)")
        } else {
            failed += 1
            print("  ✗ \(desc) — expected: \(expected), got: \(actual)")
        }
    }

    static func main() {
        let isoFormatterFractional = ISO8601DateFormatter()
        isoFormatterFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterStandard = ISO8601DateFormatter()
        isoFormatterStandard.formatOptions = [.withInternetDateTime]

        print("Running N8nPollerTests...")

        // 1. Parse stoppedAt with fractional seconds
        let date1Str = "2026-10-21T14:30:00.123Z"
        let expectedDate1 = isoFormatterFractional.date(from: date1Str)!
        let json1: [String: Any] = ["stoppedAt": date1Str, "startedAt": "2026-10-21T14:29:50.000Z"]
        assertEqual(n8nExecutionDate(from: json1), expectedDate1, "Parses stoppedAt with fractional seconds")

        // 2. Parse stoppedAt with standard ISO8601 (no fractions)
        let date2Str = "2026-10-21T14:30:00Z"
        let expectedDate2 = isoFormatterStandard.date(from: date2Str)!
        let json2: [String: Any] = ["stoppedAt": date2Str]
        assertEqual(n8nExecutionDate(from: json2), expectedDate2, "Parses stoppedAt with standard ISO8601")

        // 3. Fallback to startedAt when stoppedAt is missing
        let date3Str = "2026-10-21T12:00:00.500Z"
        let expectedDate3 = isoFormatterFractional.date(from: date3Str)!
        let json3: [String: Any] = ["startedAt": date3Str]
        assertEqual(n8nExecutionDate(from: json3), expectedDate3, "Falls back to startedAt when stoppedAt is nil")

        // 4. No date, or one that does not parse: now
        let json4: [String: Any] = ["id": "123", "status": "success"]
        assertEqual(abs(n8nExecutionDate(from: json4).timeIntervalSinceNow) < 5, true,
                    "Falls back to now when stoppedAt and startedAt are missing")
        let json4b: [String: Any] = ["stoppedAt": "yesterday"]
        assertEqual(abs(n8nExecutionDate(from: json4b).timeIntervalSinceNow) < 5, true,
                    "Falls back to now when the date does not parse")

        // 5. Terminal statuses verification
        assertEqual(n8nTerminalStatuses.contains("success"), true, "success is terminal")
        assertEqual(n8nTerminalStatuses.contains("error"), true, "error is terminal")
        assertEqual(n8nTerminalStatuses.contains("crashed"), true, "crashed is terminal")
        assertEqual(n8nTerminalStatuses.contains("running"), false, "running is not terminal")
        assertEqual(n8nTerminalStatuses.contains("waiting"), false, "waiting is not terminal")

        print("")
        print("Results: \(passed) passed, \(failed) failed")
        exit(failed > 0 ? 1 : 0)
    }
}
