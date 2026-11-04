#if PHONE_LINK
import AppKit
import CloudKit
import Combine

// MARK: - Answer Claude's questions from the iPhone
//
// While Claude Code waits on an AskUserQuestion, a session record carries
// the question and its choices (SessionPublisher): the pill's own record for
// the first question behind it, a record of its own for each other session's.
// The iPhone answers with an `Answer` record: the question's fingerprint, the
// record it was shown on and the labels picked. This Mac looks for answers
// every 2 s, only while a question waits, and applies one only if it matches a
// question still waiting on that record and every label is one of its
// choices. Answers are single use: deleted as soon as they are read.

@MainActor
final class QuestionRelay {
    static let shared = QuestionRelay()

    private let container = CKContainer(identifier: "iCloud.fr.louisraille.Coucou")
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { SessionSnapshot.zoneID }

    private var cancellable: AnyCancellable?
    /// The questions waiting, oldest first (AppState.waitingQuestions).
    private var waiting: [QueuedQuestion] = []
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?

    func start() {
        guard cancellable == nil else { return }
        // @Published sends the new value before the property changes: use the value passed along.
        cancellable = AppState.shared.$waitingQuestions
            .removeDuplicates()
            .sink { [weak self] questions in
                MainActor.assumeIsolated { self?.waitingChanged(to: questions) }
            }
    }

    func stop() {
        cancellable = nil
        waitingChanged(to: [])
    }

    private func waitingChanged(to questions: [QueuedQuestion]) {
        waiting = questions
        guard !questions.isEmpty else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        // Each question goes back to its terminal after 120 s at the latest, so the polling
        // stops with the last one (the empty list cancels it).
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, !self.waiting.isEmpty else { return }
                await self.checkAnswers()
            }
        }
    }

    private struct Answer {
        let id: CKRecord.ID
        let fingerprint: String
        let recordId: String
        let answeredAt: Date
        let selections: String
    }

    private func checkAnswers() async {
        guard let oldest = waiting.map(\.received).min() else { return }
        var found: [Answer] = []
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: changeToken)
                for (id, result) in changes.modificationResultsByID {
                    guard case .success(let mod) = result, mod.record.recordType == "Answer" else { continue }
                    let record = mod.record
                    let answeredAt = record["answeredAt"] as? Date ?? .distantPast
                    guard answeredAt >= oldest.addingTimeInterval(-5) else { continue }
                    found.append(Answer(id: id, fingerprint: record["fingerprint"] as? String ?? "",
                                        recordId: record["pillId"] as? String ?? "", answeredAt: answeredAt,
                                        selections: record.encryptedValues["selections"] as? String ?? ""))
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return
        } catch {
            log("answer check failed: \(error.localizedDescription)")
            return
        }
        guard !found.isEmpty else { return }
        let ids = found.map(\.id)
        Task { _ = try? await database.modifyRecords(saving: [], deleting: ids) }
        for answer in found.sorted(by: { $0.answeredAt < $1.answeredAt }) { apply(answer) }
    }

    private func apply(_ answer: Answer) {
        // Check again right before answering the hook: read what waits now.
        guard let entry = QuestionQueue.question(answering: answer.fingerprint, onRecord: answer.recordId,
                                                 in: AppState.shared.waitingQuestions,
                                                 fingerprintOf: { QuestionPayload(ask: $0).fingerprint }) else {
            log("answer for a question no longer waiting, ignored")
            return
        }
        guard answer.answeredAt >= entry.received.addingTimeInterval(-5) else {
            log("answer for an older question, ignored")
            return
        }
        guard let selections = QuestionPayload.decodeSelections(answer.selections),
              QuestionPayload(ask: entry.question).accepts(selections) else {
            log("answer with unknown choices, ignored")
            return
        }
        log("answered from the iPhone (\(entry.phoneRecordId))")
        HookServer.shared.sendQuestionAnswers(
            AskQuestion.buildAnswers(questions: entry.question.questions, selections: selections), for: entry.id)
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
