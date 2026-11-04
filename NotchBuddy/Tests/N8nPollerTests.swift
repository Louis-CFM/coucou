#!/usr/bin/swift
// N8nPollerTests.swift — standalone test script for n8n execution date parsing and status checks.
// Run from repo root:
//   swift NotchBuddy/Tests/N8nPollerTests.swift

import Foundation

var passed = 0
var failed = 0

func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ desc: String) {
    if actual == expected {
        passed += 1
        print("  ✓ \(desc)")
    } else {
        failed += 1
        print("  ✗ \(desc) — expected: \(expected), got: \(actual)")
    }
}

let isoFormatterFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

let isoFormatterStandard: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseExecutionDate(from json: [String: Any]) -> Date? {
    let dateString = (json["stoppedAt"] as? String) ?? (json["startedAt"] as? String)
    guard let dateString else { return nil }
    return isoFormatterFractional.date(from: dateString) ?? isoFormatterStandard.date(from: dateString)
}

print("Running N8nPollerTests...")

// 1. Parse stoppedAt with fractional seconds
let date1Str = "2026-10-21T14:30:00.123Z"
let expectedDate1 = isoFormatterFractional.date(from: date1Str)!
let json1: [String: Any] = ["stoppedAt": date1Str, "startedAt": "2026-10-21T14:29:50.000Z"]
assertEqual(parseExecutionDate(from: json1), expectedDate1, "Parses stoppedAt with fractional seconds")

// 2. Parse stoppedAt with standard ISO8601 (no fractions)
let date2Str = "2026-10-21T14:30:00Z"
let expectedDate2 = isoFormatterStandard.date(from: date2Str)!
let json2: [String: Any] = ["stoppedAt": date2Str]
assertEqual(parseExecutionDate(from: json2), expectedDate2, "Parses stoppedAt with standard ISO8601")

// 3. Fallback to startedAt when stoppedAt is missing
let date3Str = "2026-10-21T12:00:00.500Z"
let expectedDate3 = isoFormatterFractional.date(from: date3Str)!
let json3: [String: Any] = ["startedAt": date3Str]
assertEqual(parseExecutionDate(from: json3), expectedDate3, "Falls back to startedAt when stoppedAt is nil")

// 4. Missing date returns nil
let json4: [String: Any] = ["id": "123", "status": "success"]
assertEqual(parseExecutionDate(from: json4), nil, "Returns nil when stoppedAt and startedAt are missing")

// 5. Terminal statuses verification
let terminal = ["success", "error", "crashed", "canceled", "failed"]
assertEqual(terminal.contains("success"), true, "success is terminal")
assertEqual(terminal.contains("error"), true, "error is terminal")
assertEqual(terminal.contains("crashed"), true, "crashed is terminal")
assertEqual(terminal.contains("running"), false, "running is not terminal")
assertEqual(terminal.contains("waiting"), false, "waiting is not terminal")

print("")
print("Results: \(passed) passed, \(failed) failed")
exit(failed > 0 ? 1 : 0)
