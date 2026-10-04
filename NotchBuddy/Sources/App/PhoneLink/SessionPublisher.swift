#if PHONE_LINK
import AppKit
import CloudKit
import Combine

// MARK: - iPhone plan, step 4: publish agent sessions to iCloud
//
// One `Session` record per agent pill (VS Code / Claude Code, Cursor, Codex,
// Antigravity, Gemini CLI…) in the private zone `Coucou`, so the iPhone can show
// them. Driven only by AppState changes (debounced), never by a timer: nothing
// runs while no agent changes. Integrations (Stripe, Vercel…) are not sessions.
//
// In clear (needed for sorting and widgets): pillId, state, step counts, flags,
// dates. Encrypted with the user's iCloud keys: project name, steps, cwd,
// last message, the pending command and question.

@MainActor
final class SessionPublisher {
    static let shared = SessionPublisher()

    private let container = CKContainer(identifier: "iCloud.fr.louisraille.Coucou")
    private var database: CKDatabase { container.privateCloudDatabase }
    private var cancellable: AnyCancellable?

    /// What was last written to iCloud, by pill ID.
    private var published: [String: SessionSnapshot] = [:]
    private var zoneReady = false
    private var cleanedUp = false
    private var publishing = false
    private var pending: [String: SessionSnapshot]?

    /// Stops publishing and deletes this Mac's sessions from iCloud.
    func stop() {
        cancellable = nil
        pending = nil
        Task {
            do {
                let existing = try await existingSessions()
                let ids = existing.keys.map { SessionSnapshot.recordID(for: $0) }
                if !ids.isEmpty {
                    _ = try await database.modifyRecords(saving: [], deleting: ids, savePolicy: .changedKeys, atomically: false)
                }
                log("publisher off, removed \(ids.count) session(s) from iCloud")
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                log("publisher off, nothing in iCloud")
            } catch {
                log("publisher off, cleanup failed: \(error.localizedDescription)")
            }
            published = [:]
            cleanedUp = false
        }
    }

    func start() {
        guard cancellable == nil else { return }
        let state = AppState.shared
        cancellable = state.$tasks
            .combineLatest(state.$pendingApproval, state.$pendingQuestion)
            .map { tasks, approval, question in
                SessionSnapshot.all(tasks: tasks, approval: approval, question: question)
            }
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] snapshots in
                MainActor.assumeIsolated { self?.publish(snapshots) }
            }
        log("session publisher on")
    }

    // MARK: Publishing

    private func publish(_ snapshots: [String: SessionSnapshot]) {
        guard !publishing else { pending = snapshots; return }
        publishing = true
        Task {
            await write(snapshots)
            publishing = false
            if let next = pending {
                pending = nil
                publish(next)
            }
        }
    }

    private func write(_ snapshots: [String: SessionSnapshot]) async {
        do {
            if !zoneReady {
                _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: SessionSnapshot.zoneID)], deleting: [])
                zoneReady = true
            }
            if !cleanedUp {
                // Sessions left by a previous run (the Mac quit or crashed).
                published = try await existingSessions()
                cleanedUp = true
            }

            let changed = snapshots.values.filter { published[$0.pillId] != $0 }
            let removed = published.keys.filter { snapshots[$0] == nil }
            guard !changed.isEmpty || !removed.isEmpty else { return }

            let records = changed.map { $0.record() }
            let deletions = removed.map { SessionSnapshot.recordID(for: $0) }
            let result = try await database.modifyRecords(saving: records, deleting: deletions,
                                                          savePolicy: .changedKeys, atomically: false)
            for (id, outcome) in result.saveResults {
                guard let pillId = SessionSnapshot.pillId(from: id) else { continue }
                switch outcome {
                case .success: published[pillId] = snapshots[pillId]
                case .failure(let error): log("save \(pillId) failed: \(error.localizedDescription)")
                }
            }
            for (id, outcome) in result.deleteResults {
                guard let pillId = SessionSnapshot.pillId(from: id) else { continue }
                switch outcome {
                case .success: published[pillId] = nil
                case .failure(let error): log("delete \(pillId) failed: \(error.localizedDescription)")
                }
            }
            let summary = changed.map { "\($0.pillId)=\($0.state)" }.sorted().joined(separator: ", ")
            log("published \(changed.count) session(s)\(summary.isEmpty ? "" : " [\(summary)]"), removed \(removed.count)")
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            zoneReady = false
            log("zone missing, will recreate on the next change")
        } catch {
            log("publish failed: \(error.localizedDescription)")
        }
    }

    /// Session records already in the zone, so the first write can delete stale ones.
    private func existingSessions() async throws -> [String: SessionSnapshot] {
        var found: [String: SessionSnapshot] = [:]
        var token: CKServerChangeToken?
        var more = true
        while more {
            let changes = try await database.recordZoneChanges(inZoneWith: CloudProbe.zoneID, since: token)
            for (id, result) in changes.modificationResultsByID {
                guard case .success(let mod) = result, mod.record.recordType == SessionSnapshot.recordType,
                      let pillId = SessionSnapshot.pillId(from: id) else { continue }
                // Unknown content: a placeholder that never equals a real snapshot,
                // so it is rewritten if the session still exists, deleted otherwise.
                found[pillId] = SessionSnapshot.placeholder(pillId: pillId)
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return found
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[sessions] \(message)")
    }
}

// MARK: - Snapshot

/// The part of an AgentTask the iPhone needs. Equatable so unchanged sessions
/// are not rewritten.
struct SessionSnapshot: Equatable {
    static let recordType = "Session"

    let pillId: String
    let name: String
    let color: String
    let state: String
    let stepIndex: Int
    let steps: [String]
    let cwd: String
    let finalLine: String
    let approvalTool: String
    let approvalCommand: String
    let question: String

    static func all(tasks: [AgentTask], approval: ApprovalInfo?,
                    question: AskQuestion?) -> [String: SessionSnapshot] {
        var result: [String: SessionSnapshot] = [:]
        for task in tasks where task.source != .n8n {
            let hasApproval = approval?.pillId == task.id
            let questionText = task.state == .question
                ? (question?.questions.map(\.question).joined(separator: "\n") ?? "")
                : ""
            result[task.id] = SessionSnapshot(
                pillId: task.id,
                name: task.name,
                color: task.color,
                state: task.state.rawValue,
                stepIndex: task.stepIndex,
                steps: task.steps,
                cwd: task.sessionCwd ?? "",
                finalLine: task.finalLine ?? "",
                approvalTool: hasApproval ? (approval?.tool ?? "") : "",
                approvalCommand: hasApproval ? (approval?.command ?? "") : "",
                question: questionText)
        }
        return result
    }

    static func placeholder(pillId: String) -> SessionSnapshot {
        SessionSnapshot(pillId: pillId, name: "", color: "", state: "", stepIndex: -1, steps: [],
                        cwd: "", finalLine: "", approvalTool: "", approvalCommand: "", question: "")
    }

    /// Same zone as CloudProbe.zoneID, rebuilt here because that one is main-actor isolated.
    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Coucou", ownerName: CKCurrentUserDefaultName)
    }

    static func recordID(for pillId: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "session-\(pillId)", zoneID: zoneID)
    }

    static func pillId(from id: CKRecord.ID) -> String? {
        let name = id.recordName
        guard name.hasPrefix("session-") else { return nil }
        return String(name.dropFirst("session-".count))
    }

    func record() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: Self.recordID(for: pillId))
        record["pillId"] = pillId
        record["color"] = color
        record["state"] = state
        record["stepIndex"] = stepIndex
        record["stepCount"] = steps.count
        record["needsApproval"] = !approvalCommand.isEmpty || !approvalTool.isEmpty
        record["needsAnswer"] = !question.isEmpty
        record["updatedAt"] = Date()
        record["macName"] = Host.current().localizedName ?? ""
        record.encryptedValues["name"] = name
        record.encryptedValues["steps"] = steps
        record.encryptedValues["cwd"] = cwd
        record.encryptedValues["finalLine"] = finalLine
        record.encryptedValues["approvalTool"] = approvalTool
        record.encryptedValues["approvalCommand"] = approvalCommand
        record.encryptedValues["question"] = question
        return record
    }
}
#endif
