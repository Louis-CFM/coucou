#if PHONE_LINK && !APPSTORE
import AppKit
import CloudKit

// MARK: - Instructions from the iPhone
//
// The iPhone writes an `Instruction` record (text encrypted) for a session.
// When the user turned it on (Settings → General → iPhone, off by default),
// this Mac checks every 15 s, takes each instruction once (the record is
// deleted on read), and continues that same Claude Code conversation in the
// background: `claude -p <text> --resume <session id>`, in the session's own
// folder. The folder and the session come from what this Mac saw in the
// hooks, never from the iPhone. Hooks keep working, so the notch, the iPhone
// and the permission requests (approved by hand, with Face ID on the phone)
// follow the run like any other turn.
// GitHub build only: the App Store build is sandboxed and can't start `claude`.

@MainActor
final class InstructionRunner {
    static let shared = InstructionRunner()

    nonisolated static let enabledKey = "iPhoneInstructionsEnabled"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var database: CKDatabase { CKContainer(identifier: CloudProbe.containerID).privateCloudDatabase }
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?

    /// Instructions older than this are dropped instead of run.
    private let maxAge: TimeInterval = 10 * 60

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on && CloudProbe.isEnabled { start() } else { stop() }
    }

    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func start() {
        guard pollTask == nil else { return }
        log("on: checking for instructions every 15 s")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        log("off")
    }

    // MARK: Reading

    private func check() async {
        var found: [CKRecord] = []
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: SessionSnapshot.zoneID, since: changeToken)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result, mod.record.recordType == "Instruction" { found.append(mod.record) }
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return
        } catch {
            return
        }
        guard !found.isEmpty else { return }
        // Single use: gone from iCloud before anything runs.
        _ = try? await database.modifyRecords(saving: [], deleting: found.map(\.recordID))
        for record in found.sorted(by: { ($0["createdAt"] as? Date ?? .distantPast) < ($1["createdAt"] as? Date ?? .distantPast) }) {
            handle(record)
        }
    }

    private func handle(_ record: CKRecord) {
        let pillId = record["pillId"] as? String ?? ""
        let createdAt = record["createdAt"] as? Date ?? .distantPast
        let text = (record.encryptedValues["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isEnabled else { log("ignored: instructions are off"); return }
        guard Date().timeIntervalSince(createdAt) < maxAge else { log("ignored: older than 10 min"); return }
        guard !text.isEmpty, text.count <= 8000 else { log("ignored: empty or too long"); return }
        guard pillId == "integration_claude" || pillId == "agent_cursor" else { log("ignored: \(pillId) can't take instructions"); return }
        guard let session = AppState.shared.claudeSessions[pillId] else {
            log("ignored: no Claude Code session seen for \(pillId) yet")
            return
        }
        if case .failure(let failure) = SessionResumer.shared.resume(session, pillId: pillId, text: text,
                                                                      log: { [weak self] in self?.log($0) }) {
            log("ignored: \(failure)")
        }
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[instruction] \(message)")
    }
}
#endif
