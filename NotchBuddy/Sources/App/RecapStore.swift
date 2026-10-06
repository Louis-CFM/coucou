import Foundation

// MARK: - Persisted data models

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
    var decision: String     // "allow", "always", "deny", "ask"
}

private struct RecapData: Codable {
    var turns: [RecapTurn] = []
    var decisions: [RecapDecision] = []
    var schemaVersion: Int = 1
}

// MARK: - Weekly summary

struct WeeklySummary {
    var weekStart: Date
    var weekEnd: Date
    var totalMinutes: Int
    var sessionCount: Int
    var filesChanged: Int
    var linesAdded: Int
    var linesRemoved: Int
    var commandsRun: Int
    var questionsAnswered: Int
    var permissionsAllowed: Int
    var permissionsDenied: Int
    var topAgent: String?    // pill display name
    var topProject: String?
    var busiestDay: String?
    var longestSessionMinutes: Int
}

// MARK: - In-progress turn draft (keyed by sessionId)

private struct TurnDraft {
    var pillId: String
    var project: String
    var start: Date
    var lastEvent: Date
    var changedPaths: Set<String> = []
    var linesAdded: Int = 0
    var linesRemoved: Int = 0
    var commandsRun: Int = 0
    var questions: Int = 0
}

// MARK: - Store

@MainActor
final class RecapStore {
    static let shared = RecapStore()

    private var data = RecapData()
    /// Set by DemoEngine to inject a fake summary without touching disk.
    var demoSummaryOverride: WeeklySummary? = nil
    /// Keyed by sessionId so concurrent sessions from the same agent are tracked separately.
    private var drafts: [String: TurnDraft] = [:]

    private static let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("NotchBuddy/recap.json")
    }()

    private init() { load() }

    // MARK: - Event recording

    func userPromptSubmit(sessionId: String, pillId: String, project: String) {
        guard isEnabled else { return }
        pruneStale()
        if drafts[sessionId] == nil {
            drafts[sessionId] = TurnDraft(pillId: pillId, project: project, start: .now, lastEvent: .now)
        } else {
            drafts[sessionId]?.lastEvent = .now
        }
    }

    func preToolUse(sessionId: String, tool: String) {
        guard isEnabled, var draft = drafts[sessionId] else { return }
        draft.lastEvent = .now
        switch tool {
        case "Bash", "Execute", "mcp__ide__executeCode":
            draft.commandsRun += 1
        default:
            break
        }
        drafts[sessionId] = draft
    }

    /// Called after a file diff is computed in PostToolUse.
    func recordFileDiff(sessionId: String, path: String, added: Int, removed: Int) {
        guard isEnabled, var draft = drafts[sessionId] else { return }
        draft.lastEvent = .now
        draft.changedPaths.insert(path)
        draft.linesAdded += added
        draft.linesRemoved += removed
        drafts[sessionId] = draft
    }

    /// Called when the user sends answers from the notch (not when the question is asked).
    func recordQuestionAnswered(sessionId: String) {
        guard isEnabled, var draft = drafts[sessionId] else { return }
        draft.lastEvent = .now
        draft.questions += 1
        drafts[sessionId] = draft
    }

    func stop(sessionId: String) {
        guard isEnabled, let draft = drafts.removeValue(forKey: sessionId) else { return }
        let turn = RecapTurn(
            pillId: draft.pillId,
            project: draft.project,
            start: draft.start,
            end: .now,
            filesChanged: draft.changedPaths.count,
            linesAdded: draft.linesAdded,
            linesRemoved: draft.linesRemoved,
            commandsRun: draft.commandsRun,
            questions: draft.questions
        )
        data.turns.append(turn)
        prune()
        save()
    }

    func sessionEnd(sessionId: String) {
        drafts.removeValue(forKey: sessionId)
    }

    func recordDecision(pillId: String, decision: String) {
        guard isEnabled else { return }
        data.decisions.append(RecapDecision(pillId: pillId, date: .now, decision: decision))
        prune()
        save()
    }

    // MARK: - Query

    /// Returns a summary for the last completed week (Mon–Sun, ISO 8601).
    /// Pass a custom `weekStart` (Monday 00:00 local) to query a different week.
    func weeklySummary(for weekStart: Date? = nil) -> WeeklySummary? {
        if let demo = demoSummaryOverride { return demo }
        // ISO 8601 calendar: weeks start on Monday regardless of locale.
        let cal = Calendar(identifier: .iso8601)
        let start: Date
        if let ws = weekStart {
            start = ws
        } else {
            // Previous Monday 00:00 local
            var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
            comps.weekday = 2   // Monday (weekday 2 in Gregorian/ISO, Sunday=1)
            let thisMonday = cal.date(from: comps)!
            start = cal.date(byAdding: .weekOfYear, value: -1, to: thisMonday)!
        }
        let end = cal.date(byAdding: .day, value: 7, to: start)!

        let turns = data.turns.filter { $0.start >= start && $0.start < end }
        let decisions = data.decisions.filter { $0.date >= start && $0.date < end }
        guard !turns.isEmpty else { return nil }

        // Merge overlapping intervals to avoid double-counting parallel sessions.
        let totalSecs = mergedTotalSeconds(turns)
        let allowed = decisions.filter { $0.decision == "allow" || $0.decision == "always" }.count
        let denied  = decisions.filter { $0.decision == "deny" }.count

        // Top agent by session count
        var countByAgent: [String: Int] = [:]
        for t in turns { countByAgent[t.pillId, default: 0] += 1 }
        let topAgentId = countByAgent.max { $0.value < $1.value }?.key
        let topAgent = topAgentId.flatMap { PillCatalog.definition(for: $0)?.name } ?? topAgentId

        // Top project by session count
        var countByProject: [String: Int] = [:]
        for t in turns where !t.project.isEmpty { countByProject[t.project, default: 0] += 1 }
        let topProject = countByProject.max { $0.value < $1.value }?.key

        // Busiest day
        var countByWeekday: [Int: Int] = [:]
        for t in turns { countByWeekday[cal.component(.weekday, from: t.start), default: 0] += 1 }
        let dayNames = [1: "Sunday", 2: "Monday", 3: "Tuesday", 4: "Wednesday",
                        5: "Thursday", 6: "Friday", 7: "Saturday"]
        let busiestDay = countByWeekday.max { $0.value < $1.value }.flatMap { dayNames[$0.key] }

        let longestSecs = turns.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0

        return WeeklySummary(
            weekStart: start,
            weekEnd: cal.date(byAdding: .second, value: -1, to: end)!,
            totalMinutes:          Int(totalSecs / 60),
            sessionCount:          turns.count,
            filesChanged:          turns.reduce(0) { $0 + $1.filesChanged },
            linesAdded:            turns.reduce(0) { $0 + $1.linesAdded },
            linesRemoved:          turns.reduce(0) { $0 + $1.linesRemoved },
            commandsRun:           turns.reduce(0) { $0 + $1.commandsRun },
            questionsAnswered:     turns.reduce(0) { $0 + $1.questions },
            permissionsAllowed:    allowed,
            permissionsDenied:     denied,
            topAgent:              topAgent,
            topProject:            topProject,
            busiestDay:            busiestDay,
            longestSessionMinutes: Int(longestSecs / 60)
        )
    }

    // MARK: - Persistence

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "recapEnabled") as? Bool ?? true
    }

    func clearHistory() {
        data = RecapData()
        drafts = [:]
        try? FileManager.default.removeItem(at: Self.storageURL)
    }

    private func load() {
        guard let raw = try? Data(contentsOf: Self.storageURL) else { return }
        do {
            data = try JSONDecoder().decode(RecapData.self, from: raw)
            prune()
        } catch {
            // Rename corrupt file so it's not silently lost, then start fresh.
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let corrupt = Self.storageURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(fmt.string(from: Date()))")
            try? FileManager.default.moveItem(at: Self.storageURL, to: corrupt)
        }
    }

    private func save() {
        pruneStale()
        persist()
    }

    private func persist() {
        let dir = Self.storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let encoded = try? JSONEncoder().encode(data) {
            try? encoded.write(to: Self.storageURL, options: .atomic)
        }
    }

    private func prune() {
        guard let cutoff = Calendar.current.date(byAdding: .weekOfYear, value: -12, to: .now) else { return }
        data.turns     = data.turns.filter     { $0.start >= cutoff }
        data.decisions = data.decisions.filter { $0.date  >= cutoff }
    }

    /// Finalises drafts with no events for 2+ hours (agent crashed or forgot to Stop).
    /// Instead of discarding them, persists them as completed turns so they count in the recap.
    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-2 * 3600)
        var staleKeys: [String] = []
        for (key, draft) in drafts where draft.lastEvent < cutoff {
            let turn = RecapTurn(
                pillId: draft.pillId,
                project: draft.project,
                start: draft.start,
                end: draft.lastEvent,
                filesChanged: draft.changedPaths.count,
                linesAdded: draft.linesAdded,
                linesRemoved: draft.linesRemoved,
                commandsRun: draft.commandsRun,
                questions: draft.questions
            )
            data.turns.append(turn)
            staleKeys.append(key)
        }
        for key in staleKeys { drafts.removeValue(forKey: key) }
        if !staleKeys.isEmpty {
            prune()
            persist()
        }
    }

    // MARK: - Interval merging (prevents double-counting parallel sessions)

    private func mergedTotalSeconds(_ turns: [RecapTurn]) -> Double {
        let sorted = turns.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var total: Double = 0
        var segStart: Date? = nil
        var segEnd: Date? = nil
        for t in sorted {
            if let end = segEnd {
                if t.start <= end {
                    segEnd = max(end, t.end)
                } else {
                    total += segEnd!.timeIntervalSince(segStart!)
                    segStart = t.start
                    segEnd = t.end
                }
            } else {
                segStart = t.start
                segEnd = t.end
            }
        }
        if let e = segEnd, let s = segStart { total += e.timeIntervalSince(s) }
        return total
    }
}
