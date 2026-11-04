import Foundation

@main
enum QuestionQueueTests {
    static func question(_ text: String) -> AskQuestion {
        AskQuestion(questions: [AskQuestionItem(question: text, header: "", options: [
            AskQuestionOption(label: "Yes", description: ""), AskQuestionOption(label: "No", description: ""),
        ], multiSelect: false)])
    }

    static func entry(_ n: Int, session: String, pill: String = "integration_claude") -> QueuedQuestion {
        QueuedQuestion(id: UUID(), fd: Int32(n), sessionId: session, pillId: pill,
                       projectName: "p\(n)", cwd: "/", question: question("q\(n)"))
    }

    static func accepted(_ result: QuestionQueue.EnqueueResult) -> QueuedQuestion?? {
        if case .accepted(let replaced) = result { return .some(replaced) }
        return nil
    }

    static func main() {
        // Two sessions on one pill both wait: neither pushes the other away, FIFO
        var q = QuestionQueue()
        let a = entry(1, session: "s1"), b = entry(2, session: "s2")
        precondition(accepted(q.enqueue(a)) == .some(nil))
        precondition(accepted(q.enqueue(b)) == .some(nil))
        precondition(q.count == 2 && q.head?.id == a.id)
        precondition(q.hasEntries(forPill: "integration_claude") && !q.hasEntries(forPill: "agent_codex"))

        // Slots: the pill's own iPhone record first, then one record per extra question
        precondition(q.entries.map(\.slot) == [1, 2])
        precondition(q.entries.map(\.phoneRecordId) == ["integration_claude", "integration_claude#q2"])

        // Another pill counts its own slots
        let c = entry(3, session: "s3", pill: "agent_codex")
        _ = q.enqueue(c)
        precondition(q.entry(id: c.id)?.phoneRecordId == "agent_codex")

        // Answering the head leaves the others where they are: same order, same slot
        precondition(q.remove(id: a.id)?.id == a.id)
        precondition(q.head?.id == b.id && q.entry(id: b.id)?.slot == 2)
        precondition(q.remove(id: a.id) == nil)   // already gone: no-op

        // A freed slot is reused by the next question on that pill
        let d = entry(4, session: "s4")
        _ = q.enqueue(d)
        precondition(q.entry(id: d.id)?.slot == 1 && q.entries.last?.id == d.id)

        // A newer question from the same session takes its older one's place and slot
        let order = q.entries.map(\.sessionId)
        let b2 = entry(5, session: "s2")
        guard case .accepted(let replaced)? = Optional(q.enqueue(b2)) else { preconditionFailure() }
        precondition(replaced?.id == b.id && !q.contains(id: b.id) && q.contains(id: b2.id))
        precondition(q.entry(id: b2.id)?.slot == 2 && q.count == 3)
        precondition(q.entries.map(\.sessionId) == order && q.head?.id == b2.id)
        // Same session id on another pill is another session
        let codexS1 = entry(6, session: "s4", pill: "agent_codex")
        precondition(accepted(q.enqueue(codexS1)) == .some(nil) && q.entry(id: codexS1.id)?.slot == 2)

        // Cap: the newest goes back to its terminal, the queue is unchanged
        var full = QuestionQueue()
        let all = (1...QuestionQueue.maxPending).map { entry($0, session: "f\($0)") }
        for e in all { precondition(accepted(full.enqueue(e)) == .some(nil)) }
        precondition(full.enqueue(entry(99, session: "f99")) == .rejectedFull)
        precondition(full.entries.map(\.id) == all.map(\.id))
        precondition(full.entries.map(\.slot) == Array(1...QuestionQueue.maxPending))
        // …but a session asking again is not a new question: it takes its own place back
        let again = entry(98, session: "f3")
        guard case .accepted(let old)? = Optional(full.enqueue(again)) else { preconditionFailure() }
        precondition(old?.id == all[2].id && full.count == QuestionQueue.maxPending)
        precondition(full.entry(id: again.id)?.slot == 3)

        // removeAll hands every question back, oldest first
        let gone = full.removeAll()
        precondition(gone.count == QuestionQueue.maxPending && gone.first?.id == all[0].id && full.isEmpty)

        // An iPhone answer goes to the question on the record it names, even when two
        // sessions asked the very same question
        var same = QuestionQueue()
        let s1 = QueuedQuestion(id: UUID(), fd: 1, sessionId: "a", pillId: "integration_claude",
                                projectName: "a", cwd: "/a", question: question("Same?"))
        let s2 = QueuedQuestion(id: UUID(), fd: 2, sessionId: "b", pillId: "integration_claude",
                                projectName: "b", cwd: "/b", question: question("Same?"))
        let other = QueuedQuestion(id: UUID(), fd: 3, sessionId: "c", pillId: "agent_codex",
                                   projectName: "c", cwd: "/c", question: question("Other?"))
        for e in [s1, s2, other] { _ = same.enqueue(e) }
        let fp: (AskQuestion) -> String = { $0.questions.map(\.question).joined() }
        func answered(_ fingerprint: String, _ record: String) -> UUID? {
            QuestionQueue.question(answering: fingerprint, onRecord: record, in: same.entries, fingerprintOf: fp)?.id
        }
        precondition(answered("Same?", "integration_claude") == s1.id)
        precondition(answered("Same?", "integration_claude#q2") == s2.id)
        precondition(answered("Other?", "agent_codex") == other.id)
        precondition(answered("Same?", "") == s1.id)               // no record named: the oldest
        precondition(answered("Same?", "agent_codex") == nil)      // not the question on that record
        precondition(answered("Gone?", "integration_claude") == nil)
        _ = same.remove(id: s1.id)
        precondition(answered("Same?", "integration_claude") == nil)   // answered already
        precondition(answered("Same?", "integration_claude#q2") == s2.id)

        // A question whose session popped out of its pill shows on (and is answered from) that
        // pill's record; the slots count the other questions only
        var out = QuestionQueue()
        var popped = entry(10, session: "p1")
        popped.shownPill = "integration_claude#2"
        _ = out.enqueue(popped)
        let inside = entry(11, session: "p2")
        _ = out.enqueue(inside)
        precondition(out.entry(id: popped.id)?.phoneRecordId == "integration_claude#2")
        precondition(out.entry(id: popped.id)?.displayPill == "integration_claude#2")
        precondition(out.entry(id: inside.id)?.phoneRecordId == "integration_claude")
        precondition(out.entry(id: inside.id)?.displayPill == "integration_claude")
        precondition(QuestionQueue.question(answering: "q10", onRecord: "integration_claude#2", in: out.entries,
                                            fingerprintOf: { $0.questions.map(\.question).joined() })?.id == popped.id)

        print("QuestionQueue tests: all passed")
    }
}
