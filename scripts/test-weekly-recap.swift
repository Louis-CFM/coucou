#!/usr/bin/env swift
// test-weekly-recap.swift
// Fills recap.json with one fake week of activity so the weekly recap card has something to show.
// Usage:  swift scripts/test-weekly-recap.swift
// After running, open Coucou and choose "Weekly recap" from the menu bar, or wait for Monday ≥ 8 am.
//
// NOTE: To render the real RecapShareImageView to a PNG, use the Debug menu in the app (DEBUG builds
// only): Debug → "Render recap image". This saves ~/Desktop/coucou-recap-debug.png and opens it.
// The standalone script cannot import the app module, so image rendering is done via the app.

import Foundation

// MARK: - Mirror the Codable models from RecapStore.swift

struct RecapTurn: Codable {
    var pillId: String
    var project: String
    var start: Date
    var end: Date
    var filesChanged: Int
    var linesAdded: Int
    var linesRemoved: Int
    var commandsRun: Int
    var questions: Int
}

struct RecapDecision: Codable {
    var pillId: String
    var date: Date
    var decision: String
}

struct RecapData: Codable {
    var turns: [RecapTurn]
    var decisions: [RecapDecision]
    var schemaVersion: Int
}

// MARK: - Target path

let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
let recapURL = support.appendingPathComponent("NotchBuddy/recap.json")

// Load existing data (if any) so we don't clobber other weeks.
var data: RecapData
if let raw = try? Data(contentsOf: recapURL),
   let decoded = try? JSONDecoder().decode(RecapData.self, from: raw) {
    data = decoded
    print("Loaded \(data.turns.count) existing turns.")
} else {
    data = RecapData(turns: [], decisions: [], schemaVersion: 1)
    print("Starting fresh.")
}

// MARK: - Fake data: one week ago Mon–Sun

let cal = Calendar.current
var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
comps.weekday = 2
let thisMonday = cal.date(from: comps)!
let lastMonday = cal.date(byAdding: .weekOfYear, value: -1, to: thisMonday)!

func makeDate(dayOffset: Int, hour: Int, minute: Int = 0) -> Date {
    cal.date(byAdding: .second, value: dayOffset * 86400 + hour * 3600 + minute * 60, to: lastMonday)!
}

let fakeTurns: [RecapTurn] = [
    // Monday: long Claude Code session
    RecapTurn(pillId: "integration_claude", project: "coucou",
              start: makeDate(dayOffset: 0, hour: 9),
              end:   makeDate(dayOffset: 0, hour: 11, minute: 30),
              filesChanged: 8, linesAdded: 312, linesRemoved: 87,
              commandsRun: 14, questions: 2),
    // Monday: afternoon session
    RecapTurn(pillId: "integration_claude", project: "coucou",
              start: makeDate(dayOffset: 0, hour: 14),
              end:   makeDate(dayOffset: 0, hour: 15, minute: 45),
              filesChanged: 3, linesAdded: 95, linesRemoved: 20,
              commandsRun: 5, questions: 0),
    // Tuesday: Gemini CLI
    RecapTurn(pillId: "agent_gemini", project: "side-project",
              start: makeDate(dayOffset: 1, hour: 10),
              end:   makeDate(dayOffset: 1, hour: 11),
              filesChanged: 2, linesAdded: 50, linesRemoved: 10,
              commandsRun: 3, questions: 1),
    // Wednesday: Claude Code
    RecapTurn(pillId: "integration_claude", project: "coucou",
              start: makeDate(dayOffset: 2, hour: 9, minute: 30),
              end:   makeDate(dayOffset: 2, hour: 12),
              filesChanged: 5, linesAdded: 180, linesRemoved: 60,
              commandsRun: 8, questions: 3),
    // Thursday: short burst
    RecapTurn(pillId: "integration_claude", project: "coucou",
              start: makeDate(dayOffset: 3, hour: 16),
              end:   makeDate(dayOffset: 3, hour: 17),
              filesChanged: 1, linesAdded: 40, linesRemoved: 5,
              commandsRun: 2, questions: 0),
    // Friday: longest session
    RecapTurn(pillId: "integration_claude", project: "coucou",
              start: makeDate(dayOffset: 4, hour: 8),
              end:   makeDate(dayOffset: 4, hour: 13),
              filesChanged: 12, linesAdded: 540, linesRemoved: 130,
              commandsRun: 22, questions: 5),
]

let fakeDecisions: [RecapDecision] = [
    RecapDecision(pillId: "integration_claude", date: makeDate(dayOffset: 0, hour: 9, minute: 30), decision: "allow"),
    RecapDecision(pillId: "integration_claude", date: makeDate(dayOffset: 0, hour: 10), decision: "allow"),
    RecapDecision(pillId: "integration_claude", date: makeDate(dayOffset: 2, hour: 10), decision: "deny"),
    RecapDecision(pillId: "integration_claude", date: makeDate(dayOffset: 4, hour: 9), decision: "always"),
    RecapDecision(pillId: "integration_claude", date: makeDate(dayOffset: 4, hour: 10), decision: "allow"),
]

// Remove any existing turns for the same week to avoid duplicates
let weekEnd = cal.date(byAdding: .day, value: 7, to: lastMonday)!
data.turns = data.turns.filter { $0.start < lastMonday || $0.start >= weekEnd }
data.decisions = data.decisions.filter { $0.date < lastMonday || $0.date >= weekEnd }

data.turns += fakeTurns
data.decisions += fakeDecisions

// MARK: - Write

let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted

try FileManager.default.createDirectory(at: recapURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
let encoded = try encoder.encode(data)
try encoded.write(to: recapURL, options: .atomic)

print("Wrote \(fakeTurns.count) test turns to \(recapURL.path)")
print("Total activity: ~\(fakeTurns.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start) / 60) }) minutes")
print("")
print("Open Coucou → menu bar → 'Weekly recap' to see the card.")
print("Or run `open \(recapURL.deletingLastPathComponent().path)` to inspect the file.")
print("")
print("To render the share card PNG, use the Debug menu in a DEBUG build of the app:")
print("  Debug → 'Render recap image' → saves ~/Desktop/coucou-recap-debug.png")
