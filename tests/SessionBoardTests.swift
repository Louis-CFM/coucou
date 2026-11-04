import Foundation

// The real BotState lives in Sources/CoucouKit/IslandTypes.swift.
enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping, dizzy
}

@main
enum SessionBoardTests {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    static func main() {
        sessions()
        shownSession()
        popOuts()
        places()
        print("SessionBoard tests: all passed")
    }

    static func sessions() {
        var b = SessionBoard()
        b.update(pill: "vs", session: "a", rawSession: "a", title: "Report", now: at(0)) { $0.state = .thinking }
        b.update(pill: "vs", session: "a", rawSession: "a", title: "", now: at(1)) { $0.appendStep("ls") }
        let a = b.session(pill: "vs", session: "a")!
        precondition(a.title == "Report" && a.state == .thinking && a.steps == ["ls"] && a.lastActive == at(1))
        // Steps are capped, oldest go first
        for i in 0..<30 { b.update(pill: "vs", session: "a", rawSession: "a", title: "", now: at(2)) { $0.appendStep("s\(i)") } }
        precondition(b.session(pill: "vs", session: "a")!.steps.count == SessionBoard.maxSteps)
        precondition(b.session(pill: "vs", session: "a")!.steps.last == "s29")
        // A timer's change is not activity
        b.amend(pill: "vs", session: "a") { $0.state = .idle }
        precondition(b.session(pill: "vs", session: "a")!.lastActive == at(2))
        b.amend(pill: "vs", session: "nobody") { $0.state = .error }
        precondition(b.session(pill: "vs", session: "nobody") == nil)
        // Removal
        precondition(b.sessionCount(pill: "vs") == 1 && b.remove(pill: "vs", session: "a") == nil && b.sessionCount(pill: "vs") == 0)
        // Sessions the registry let go leave the board, with the pill they popped out into
        b.update(pill: "vs", session: "x", rawSession: "x", title: "X", now: at(0))
        b.update(pill: "vs", session: "y", rawSession: "y", title: "Y", now: at(0))
        b.update(pill: "vs", session: "z", rawSession: "z", title: "Z", now: at(0))
        _ = b.popOut(pill: "vs", session: "y", now: at(0))
        precondition(b.keep(pill: "vs") { $0.rawSession == "x" } == ["vs#2"] && b.sessionCount(pill: "vs") == 1)
    }

    static func shownSession() {
        var b = SessionBoard()
        func set(_ s: String, _ state: BotState, _ t: TimeInterval, ended: TimeInterval? = nil) {
            b.update(pill: "vs", session: s, rawSession: s, title: s.uppercased(), now: at(t)) {
                $0.state = state
                if let ended { $0.endedAt = at(ended) }
            }
        }
        set("a", .working, 0)
        precondition(b.shown(pill: "vs", waiting: [], now: at(0)) == "a")
        precondition(b.lines(pill: "vs").isEmpty)             // one session: no list

        // B works too and is more recent, but A keeps the pill for minHold
        set("b", .working, 1)
        precondition(b.shown(pill: "vs", waiting: [], now: at(1)) == "a")
        precondition(b.shown(pill: "vs", waiting: [], now: at(SessionBoard.minHold - 0.1)) == "a")
        // …then the one active last takes it
        precondition(b.shown(pill: "vs", waiting: [], now: at(SessionBoard.minHold + 0.1)) == "b")
        precondition(b.lines(pill: "vs").map(\.session) == ["a", "b"])  // in the order they came

        // A finishing outranks B working, at once and only for the finish moment
        set("a", .finished, 8, ended: 8)
        precondition(b.shown(pill: "vs", waiting: [], now: at(8)) == "a")
        set("b", .working, 9)
        precondition(b.shown(pill: "vs", waiting: [], now: at(9)) == "a")
        precondition(b.shown(pill: "vs", waiting: [], now: at(8 + SessionBoard.finishMoment + 0.1)) == "b")

        // A failure stays in front for the error moment
        set("a", .error, 20, ended: 20)
        precondition(b.shown(pill: "vs", waiting: [], now: at(21)) == "a")
        precondition(b.shown(pill: "vs", waiting: [], now: at(20 + SessionBoard.errorMoment + 0.1)) == "b")

        // A session waiting for you comes first (while it stays in the pill)
        set("c", .idle, 60)
        precondition(b.shown(pill: "vs", waiting: ["c"], now: at(61)) == "c")
        precondition(SessionBoard.rank(b.session(pill: "vs", session: "c")!, waiting: true, now: at(61)) == 0)

        // Ranks
        let s = BoardSession(title: "", rawSession: "", state: .idle, lastActive: at(0))
        var w = s; w.state = .thinking
        precondition(SessionBoard.rank(w, waiting: false, now: at(0)) == 3)
        precondition(SessionBoard.rank(s, waiting: false, now: at(0)) == 5)
        var f = s; f.state = .finished; f.endedAt = at(0)
        precondition(SessionBoard.rank(f, waiting: false, now: at(1)) == 2)
        precondition(SessionBoard.rank(f, waiting: false, now: at(100)) == 4)
    }

    static func popOuts() {
        var b = SessionBoard()
        b.update(pill: "vs", session: "a", rawSession: "a", title: "A", now: at(0)) { $0.state = .working }
        // Alone in its pill: a waiting session stays there
        precondition(b.popOut(pill: "vs", session: "a", now: at(1)) == nil)
        b.update(pill: "vs", session: "b", rawSession: "b", title: "B", now: at(1)) { $0.state = .working }
        b.update(pill: "vs", session: "c", rawSession: "c", title: "C", now: at(1)) { $0.state = .working }
        // Sharing it: out into "<pill>#2", then "#3"; asking again keeps the same pill
        precondition(b.popOut(pill: "vs", session: "b", now: at(2)) == "vs#2")
        precondition(b.popOut(pill: "vs", session: "b", now: at(3)) == "vs#2")
        precondition(b.popOut(pill: "vs", session: "c", now: at(3)) == "vs#3")
        precondition(b.poppedPill(pill: "vs", session: "c") == "vs#3")
        precondition(b.poppedOut(pill: "vs").map(\.pill) == ["vs#2", "vs#3"])
        // The last session left inside never pops out: the client pill always shows one
        precondition(b.popOut(pill: "vs", session: "a", now: at(4)) == nil)
        // Nor does one whose sibling has been silent for long (killed without SessionEnd)
        var quiet = SessionBoard()
        quiet.update(pill: "vs", session: "old", rawSession: "old", title: "Old", now: at(0))
        quiet.update(pill: "vs", session: "new", rawSession: "new", title: "New", now: at(SessionBoard.siblingQuiet + 1))
        precondition(quiet.popOut(pill: "vs", session: "new", now: at(SessionBoard.siblingQuiet + 1)) == nil)
        // Popped-out sessions are not the pill's, nor in its list
        precondition(b.shown(pill: "vs", waiting: ["b", "c"], now: at(4)) == "a")
        precondition(b.lines(pill: "vs").isEmpty)

        // Still waiting: stays out. Answered: stays minPopOut, then folds
        var r = b.fold(pill: "vs", waiting: ["b", "c"], now: at(10))
        precondition(r.folded.isEmpty && r.recheck == nil)
        r = b.fold(pill: "vs", waiting: ["c"], now: at(10))     // b out since 2: due at 5
        precondition(r.folded == ["vs#2"] && r.recheck == nil)
        precondition(b.popOut(pill: "vs", session: "b", now: at(11)) == "vs#2")   // number 2 free again
        r = b.fold(pill: "vs", waiting: ["c"], now: at(12))     // b just out again: due at 14
        precondition(r.folded.isEmpty && r.recheck == at(11 + SessionBoard.minPopOut))
        r = b.fold(pill: "vs", waiting: ["c"], now: at(14))
        precondition(r.folded == ["vs#2"])
        precondition(b.lines(pill: "vs").map(\.session) == ["a", "b"])

        // A popped-out session that ends takes its pill down with it
        precondition(b.remove(pill: "vs", session: "c") == "vs#3")
        // When nobody is left inside, every popped-out session folds back at once
        _ = b.popOut(pill: "vs", session: "b", now: at(20))
        b.remove(pill: "vs", session: "a")
        r = b.fold(pill: "vs", waiting: ["b"], now: at(20))
        precondition(r.folded == ["vs#2"] && b.poppedOut(pill: "vs").isEmpty)
    }

    static func places() {
        typealias C = SessionBoard.Cell
        func ids(_ slots: [SessionBoard.Slot]) -> [String] {
            slots.map { slot -> String in
                switch slot {
                case .pill(let id): return id
                case .waiting(let ids): return "+\(ids.count):" + ids.joined(separator: ",")
                }
            }
        }
        // As today when nothing waits: the first 4 others, in order
        let plain = (1...6).map { C(id: "p\($0)", state: .working, poppedOut: false) }
        precondition(ids(SessionBoard.slots(plain)) == ["p1", "p2", "p3", "p4"])

        // 3 clients + 2 questions. The first question is on the card (the focused pill), the
        // second popped-out pill takes the free place.
        let threeClients = [C(id: "vscode", state: .working, poppedOut: false),
                            C(id: "desktop", state: .working, poppedOut: false),
                            C(id: "codex", state: .working, poppedOut: false),
                            C(id: "desktop#2", state: .question, poppedOut: true)]
        precondition(ids(SessionBoard.slots(threeClients)) == ["vscode", "desktop", "codex", "desktop#2"])

        // 5 waiting sessions (the first on the card, 4 more): free place, then the idle pill's,
        // then the finished one's; the newest two share the "+2" stack, the ones waiting
        // longest stay in sight. Working pills stay.
        let five = [C(id: "vscode", state: .working, poppedOut: false),
                    C(id: "codex", state: .idle, poppedOut: false),
                    C(id: "desktop", state: .finished, poppedOut: false),
                    C(id: "vscode#3", state: .approval, poppedOut: true),
                    C(id: "vscode#4", state: .question, poppedOut: true),
                    C(id: "vscode#5", state: .question, poppedOut: true),
                    C(id: "vscode#6", state: .approval, poppedOut: true)]
        precondition(ids(SessionBoard.slots(five)) == ["vscode", "vscode#4", "vscode#3", "+2:vscode#5,vscode#6"],
                     "\(ids(SessionBoard.slots(five)))")

        // A client with three sessions, one asking: it is on the card; the client pill (the
        // other two) and the rest keep their places.
        let oneAsks = [C(id: "vscode", state: .working, poppedOut: false),
                       C(id: "github", state: .idle, poppedOut: false)]
        precondition(ids(SessionBoard.slots(oneAsks)) == ["vscode", "github"])

        // A pill that waits itself (a lone session) beyond the first 4 comes in like a popped one
        let late = (1...4).map { C(id: "w\($0)", state: .working, poppedOut: false) }
            + [C(id: "i5", state: .idle, poppedOut: false), C(id: "q6", state: .question, poppedOut: false)]
        precondition(ids(SessionBoard.slots(late)) == ["w1", "w2", "w3", "+1:q6"])
        let lateIdle = [C(id: "w1", state: .working, poppedOut: false), C(id: "i2", state: .idle, poppedOut: false),
                        C(id: "w3", state: .working, poppedOut: false), C(id: "w4", state: .working, poppedOut: false),
                        C(id: "q5", state: .question, poppedOut: false)]
        precondition(ids(SessionBoard.slots(lateIdle)) == ["w1", "q5", "w3", "w4"])
        precondition(SessionBoard.slots([]).isEmpty)
    }
}
