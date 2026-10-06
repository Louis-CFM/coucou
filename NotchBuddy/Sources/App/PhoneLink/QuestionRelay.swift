#if PHONE_LINK
import AppKit
import CloudKit
import Combine

// MARK: - Answer Claude's questions from the iPhone
//
// While Claude Code waits on an AskUserQuestion, the session record carries
// the question and its choices (SessionPublisher). The iPhone answers with an
// `Answer` record: the question's fingerprint and the labels picked. This Mac
// looks for answers every 2 s, only while a question waits, and applies one
// only if it matches the question still waiting and every label is one of its
// choices. Answers are single use: deleted as soon as they are read.

@MainActor
final class QuestionRelay {
    static let shared = QuestionRelay()

    private let container = CKContainer(identifier: "iCloud.fr.louisraille.Coucou")
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { SessionSnapshot.zoneID }

    private var cancellable: AnyCancellable?
    private var current: (fingerprint: String, since: Date)?
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?

    func start() {
        guard cancellable == nil else { return }
        // @Published sends the new value before the property changes: use the value passed along.
        cancellable = AppState.shared.$pendingQuestion
            .map { $0.map(QuestionPayload.init(ask:)) }
            .removeDuplicates()
            .sink { [weak self] payload in
                MainActor.assumeIsolated { self?.pendingChanged(to: payload) }
            }
    }

    func stop() {
        cancellable = nil
        pendingChanged(to: nil)
    }

    private func pendingChanged(to payload: QuestionPayload?) {
        let fingerprint = payload?.fingerprint
        guard current?.fingerprint != fingerprint else { return }
        pollTask?.cancel()
        pollTask = nil
        current = nil
        guard let fingerprint else { return }
        current = (fingerprint, Date())
        pollTask = Task { [weak self] in
            // The Mac gives the question back to the terminal after 120 s.
            for _ in 0..<62 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                if await self.checkAnswers(for: fingerprint) { return }
            }
        }
    }

    /// Returns true once a matching answer was applied.
    private func checkAnswers(for fingerprint: String) async -> Bool {
        guard current?.fingerprint == fingerprint, let since = current?.since else { return true }
        var found: [(id: CKRecord.ID, fingerprint: String, selections: String)] = []
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: changeToken)
                for (id, result) in changes.modificationResultsByID {
                    guard case .success(let mod) = result, mod.record.recordType == "Answer" else { continue }
                    let record = mod.record
                    let answeredAt = record["answeredAt"] as? Date ?? .distantPast
                    guard answeredAt >= since.addingTimeInterval(-5) else { continue }
                    found.append((id, record["fingerprint"] as? String ?? "",
                                  record.encryptedValues["selections"] as? String ?? ""))
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return false
        } catch {
            log("answer check failed: \(error.localizedDescription)")
            return false
        }
        guard !found.isEmpty else { return false }
        let ids = found.map { $0.id }
        Task { _ = try? await database.modifyRecords(saving: [], deleting: ids) }
        guard let match = found.first(where: { $0.fingerprint == fingerprint }) else {
            log("ignored \(found.count) answer(s) for another question")
            return false
        }
        apply(match.selections, fingerprint: fingerprint)
        return true
    }

    private func apply(_ json: String, fingerprint: String) {
        // Check again right before answering the hook.
        guard let pending = AppState.shared.pendingQuestion else {
            log("answer arrived after the question was resolved, ignored")
            return
        }
        let payload = QuestionPayload(ask: pending)
        guard payload.fingerprint == fingerprint else {
            log("answer for an older question, ignored")
            return
        }
        guard let selections = QuestionPayload.decodeSelections(json), payload.accepts(selections) else {
            log("answer with unknown choices, ignored")
            return
        }
        log("answered from the iPhone")
        HookServer.shared.sendQuestionAnswers(AskQuestion.buildAnswers(questions: pending.questions, selections: selections))
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[question] \(message)")
    }
}

extension QuestionPayload {
    init(ask: AskQuestion) {
        self.init(items: ask.questions.map { item in
            Item(question: item.question, header: item.header,
                 options: item.options.map { Option(label: $0.label, description: $0.description) },
                 multiSelect: item.multiSelect)
        })
    }
}
#endif
