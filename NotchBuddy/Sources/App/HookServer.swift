import Foundation
import Darwin
import AppKit
import SwiftUI
import CryptoKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String {
        #if APPSTORE
        // Container home root keeps path ≤ 103 bytes (sun_path limit on macOS is 104 incl. NUL)
        // /Users/louis/Library/Containers/fr.louisraille.Coucou/Data/nb.sock = 66 bytes ✓
        return NSHomeDirectory() + "/nb.sock"
        #else
        return supportDir.appendingPathComponent("nb.sock").path
        #endif
    }
    // hookScriptPath is only used by the non-App Store build.
    // App Store build derives the command from the panel-selected claudeURL in buildHooksData(claudeURL:).
    static var hookScriptPath: String { supportDir.appendingPathComponent("nb-hook").path }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private static let maxPayload = 1_048_576          // 1 MB — reject oversized messages
    private static let receiveTimeoutSeconds: Int = 5   // SO_RCVTIMEO on client sockets
    private static let maxConnections = 32              // concurrent connection ceiling

    private var serverFD: Int32 = -1
    private let connectionLock = NSLock()
    private var connectionCount = 0
    /// Permission requests waiting for a click, oldest first; the head is on the card.
    /// Each one holds its nb-hook connection open until it is answered or dropped.
    private var approvals = ApprovalQueue()
    /// One read source per queued request: it notices the client hanging up, and its
    /// cancel handler is the only place the request's fd is closed.
    private var approvalSources: [UUID: any DispatchSourceRead] = [:]
    /// AskUserQuestions waiting for an answer, oldest first, one per session; the head is on
    /// the card. Each one holds its nb-hook connection open until it is answered or dropped.
    private var questions = QuestionQueue()
    /// One read source per waiting question: it notices the client hanging up, and its
    /// cancel handler is the only place the question's fd is closed.
    private var questionSources: [UUID: any DispatchSourceRead] = [:]
    private var shownQuestion: UUID? = nil            // the question the card shows

    /// True when a real nb-hook connection is holding the approval fd open.
    @MainActor var hasRealPendingApproval: Bool { pendingApprovalFD >= 0 || !approvals.isEmpty }
    /// True when a real nb-hook connection is holding the question fd open.
    @MainActor var hasRealPendingQuestion: Bool { pendingQuestionFD >= 0 || !questions.isEmpty }
    /// The cmux lane of the question slot: a cmux question holds its nb-hook connection here, like a cmux permission
    /// card does below. Every other question waits in `questions` (above); one lane owns the card at a time.
    private var pendingQuestionFD: Int32 = -1         // held open while the user answers a cmux AskUserQuestion
    private var questionFDSource: (any DispatchSourceRead)? = nil  // monitors pendingQuestionFD
    private var questionPillId: String = ""           // pill that owns the pending question
    private var questionSessionId: String = ""        // sessionId for the pending question (recap tracking)
    private var focusBeforeQuestion: String? = nil    // saved focus to restore after question
    private var activeSessionId: String? = nil        // current Claude Code session
    private var focusBeforeApproval: String? = nil    // saved focus to restore after approval
    private var focusBeforeAlert: String? = nil       // saved focus while another pill's card shows
    private var alertPill: String? = nil              // the pill that took the focus for its alert
    /// The cmux lane of the card slot: a cmux permission card holds its nb-hook connection here, with its
    /// own source and generation. Every other request waits in `approvals` (above); one lane owns the card at a time.
    private var pendingApprovalFD: Int32 = -1         // held open while the user decides on a cmux card
    private var approvalFDSource: (any DispatchSourceRead)? = nil  // monitors pendingApprovalFD
    // Bumped each time a card takes an fd, so a stale timer never dismisses a later card
    // that happens to reuse the same fd number.
    private var cardGeneration = 0
    /// Set when a card takes the place of a card that was on screen (any build): clicks are ignored for a moment.
    private var cardReplacedAt: TimeInterval? = nil
    /// When the Hermes card on screen appeared, on the monotonic clock (system uptime).
    fileprivate var hermesCardArmedAt: TimeInterval? = nil

    #if !APPSTORE
    // cmux: per-surface registry (holds the capability token, memory only) and the queue of waiting cards.
    private var cmuxRegistry = CmuxRegistry()
    private var cmuxLaunchGeneration = 0
    /// Per task: a permission / question dialog Coucou gave back to the terminal and that may still be
    /// open there. Typing Enter then would answer it. Cleared only by the event that resolves it.
    private var cmuxOpenDialogs: [String: CmuxRouting.DialogMark] = [:]
    /// Tab title of each cmux session and the last time its title / branch were refreshed. Memory only.
    private var cmuxTitles: [String: String] = [:]
    private var cmuxMetaAt: [String: TimeInterval] = [:]
    private var cmuxRefusedLogged: Set<String> = []
    private var cmuxQueue = CmuxCardQueue()
    private struct CmuxHeld {
        var fd: Int32
        var source: any DispatchSourceRead
        var taskId: String
        var surfaceKey: String
        var payload: [String: Any]
        var parsed: AskQuestion?
    }
    private var cmuxHeld: [Int: CmuxHeld] = [:]          // side data of queued cards, keyed by card id
    private var cmuxShownPayload: [String: Any]? = nil   // payload of the cmux card currently on screen
    private var cmuxShownArrival: TimeInterval = 0
    private var cmuxPromotedAt: TimeInterval? = nil      // set when the card on screen came out of the queue
    /// Discovery (the cmux tree and session file): one run at a time, throttled, with no timer of its own.
    private var cmuxDiscoveryLast: TimeInterval? = nil
    private var cmuxDiscoveryInFlight = false
    private var cmuxDiscoveryRerun = false
    private var cmuxDiscoveryDeferred = false
    /// True while the last snapshot had a tree.
    private var cmuxTreeKnown = false
    /// Surface keys of the sessions the last discovery found with a live process in the cmux session file; nil
    /// when that file could not be read. A live process keeps its entry, anything else is subject to the time rule.
    private var cmuxLiveSessionKeys: Set<String>? = nil
    /// Sessions that ended a moment ago, by surface key: a discovery that read the file before the SessionEnd (or
    /// while the process shut down) must not bring them back.
    private var cmuxEndedAt: [String: TimeInterval] = [:]
    /// The session whose Stop wrote the pill's final line, so ending another session leaves it alone.
    private var cmuxFinalLineKey: [String: String] = [:]
    /// The sessions whose last Stop told nobody: the "waiting for input" Notification that follows gives their pill a
    /// badge, once. Cleaned wherever a surface is forgotten; bounded by what the registry can hold.
    private var cmuxStopRecord = CmuxStopRecord()
    #endif
    private var sessions = PillSessionRegistry()      // live sessions behind each pill
    private var board = SessionBoard()                // what each of those sessions shows

    /// The nb-hook connection behind the permission card on screen: the cmux card's, else the head of the queue's.
    /// -1 when no request holds the card.
    @MainActor private var liveApprovalFD: Int32 { pendingApprovalFD >= 0 ? pendingApprovalFD : (approvals.head?.fd ?? -1) }

    /// The nb-hook connection behind the question card on screen: the cmux card's, else the head of the queue's.
    /// -1 when no question holds the card.
    @MainActor private var liveQuestionFD: Int32 { pendingQuestionFD >= 0 ? pendingQuestionFD : (questions.head?.fd ?? -1) }

    private init() {}

    // MARK: - Approval queue helpers

    @MainActor
    private func cancelApprovalFDSource() {
        approvalFDSource?.cancel()
        approvalFDSource = nil
    }

    /// Note shown when a request was answered outside Coucou.
    @MainActor
    private func handledNote(pill: String) -> String {
        switch PillCatalog.basePillId(pill) {
        case "agent_cursor":  return String(localized: "Handled in Cursor.")
        case "agent_codex":   return String(localized: "Handled in Codex.")
        case "agent_copilot": return String(localized: "Handled in Copilot CLI.")
        case "agent_muse":    return String(localized: "Handled in Muse Code.")
        case "agent_hermes":  return String(localized: "Handled in Hermes.")
        #if !APPSTORE
        case let id where CmuxRouting.isCmuxTaskId(id): return String(localized: "Handled in cmux.")
        #endif
        default:              return String(localized: "Handled in \(claudeHostName(pill: pill)).")
        }
    }

    /// Cancels the cmux card's connection (the cancel handler closes the fd), shows a 3-second note,
    /// clears the card, then lets the next waiting card take the screen or collapses the island.
    @MainActor
    private func dismissApprovalCard(note: String, resolved: Bool = false) {
        var cardKey: String? = nil
        #if !APPSTORE
        cardKey = cmuxShownKey
        cmuxShownPayload = nil
        // Not resolved by an event (timeout, the hook went away): the dialog may still be open in cmux.
        if !resolved, let p = AppState.shared.pendingApproval {
            markCmuxDialogOpen(cardKey, tool: p.tool, inputKey: p.inputKey)
        } else if resolved, let p = AppState.shared.pendingApproval {
            timeline(.permission(key: TimelineNames.pairingKey(tool: p.tool, inputKey: p.inputKey), label: p.command,
                                 outcome: .handled, allowedWord: String(localized: "allowed")), cardKey)
        }
        #endif
        // cancelApprovalFDSource() triggers the cancel handler which closes the fd.
        // Never close the fd here directly — Apple requires it to happen in the cancel handler.
        cancelApprovalFDSource()
        pendingApprovalFD = -1
        let state = AppState.shared
        let pillId = state.pendingApproval?.pillId ?? "integration_claude"
        state.pendingApproval = nil
        state.isPinned = false
        setTaskState(pillId, .working, cmuxKey: cardKey)
        clearPillBadgeUnlessCardHeld(id: pillId)
        // Restore focus to the pill that was focused before the approval card appeared.
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        #if !APPSTORE
        if presentNextCmuxCard() { return }
        #endif
        if HermesApprovalCenter.shared.presentNextIfFree() { return }
        state.noteMessage = note
        state.view = .note
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            // A Hermes answer announced meanwhile keeps the island open.
            if AppState.shared.hermesAnnounceHoldsIsland { return }
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }

    /// Note shown when a request waited too long and went back to the agent.
    @MainActor
    private func waitingNote(pill: String) -> String {
        switch PillCatalog.basePillId(pill) {
        case "agent_cursor":  return String(localized: "Still waiting in Cursor.")
        case "agent_codex":   return String(localized: "Still waiting in Codex.")
        case "agent_copilot": return String(localized: "Still waiting in Copilot CLI.")
        case "agent_muse":    return String(localized: "Still waiting in Muse Code.")
        case "agent_hermes":  return String(localized: "Still waiting in Hermes.")
        #if !APPSTORE
        case let id where CmuxRouting.isCmuxTaskId(id): return String(localized: "Still waiting in cmux.")
        #endif
        default:              return String(localized: "Still waiting in \(claudeHostName(pill: pill)).")
        }
    }

    /// Puts the oldest waiting request on the card. When the card already shows it, only
    /// its "n waiting" count is refreshed (no sound, no focus change).
    @MainActor
    private func showApprovalHead() {
        let state = AppState.shared
        guard let head = approvals.head else { return }
        if let shown = state.pendingApproval, shown.id == head.id {
            if shown.queueCount != approvals.count { state.pendingApproval?.queueCount = approvals.count }
            return
        }
        // Another request takes the card: a click aimed at the previous one must not answer it.
        if let at = CardInputLock.headChangeArmedAt(shownId: state.pendingApproval?.id, headId: head.id,
                                                    now: Date().timeIntervalSinceReferenceDate) {
            cardReplacedAt = at
        }
        syncPill(head.pillId)
        state.pendingApproval = ApprovalInfo(sessionId: head.sessionId, tool: head.tool,
                                              command: head.command, inputKey: head.inputKey,
                                              pillId: head.displayPill, id: head.id,
                                              queueCount: approvals.count,
                                              projectName: head.projectName)
        state.isPinned = true
        // Approval always forces the island open — the user must be able to respond.
        // Save the focus once, so it comes back when the last request is gone.
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = head.displayPill }
        expandIfNeeded(to: .approval)
    }

    /// Takes one request out of the queue. With `answer`, the decision is written to its
    /// nb-hook first; without, the connection just closes and the agent asks again itself.
    /// The cancel handler of its source closes the fd — never close it directly.
    /// The next request in line then takes the card; when none is left the card closes,
    /// with `note` for three seconds if one is given.
    @MainActor
    private func removeApproval(id: UUID, answer json: String? = nil, note: String? = nil) {
        guard let entry = approvals.remove(id: id) else { return }
        let shownApprovalId = AppState.shared.pendingApproval?.id
        let age = Int(Date().timeIntervalSince(entry.received))
        nbLog("Approval \(entry.tool) closed after \(age) s: \(json.map { _ in "answered from Coucou" } ?? note ?? "dropped")")
        let source = approvalSources.removeValue(forKey: id)
        if let json {
            let fd = entry.fd
            Task.detached { [weak self] in
                // Write while the fd is still valid, then cancel → the cancel handler closes it.
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }

        let state = AppState.shared
        // The session's pill leaves its approval state; a popped-out one folds back soon after.
        syncPill(entry.pillId)
        if !approvals.entries.contains(where: { $0.displayPill == entry.displayPill }) {
            clearPillBadge(id: entry.displayPill)
        }
        if approvals.head != nil {
            showApprovalHead()
            return
        }
        // Last request gone: close the card and give the focus back.
        state.pendingApproval = nil
        state.isPinned = false
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == entry.displayPill, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        if let nextQuestion = questions.head {
            // The question takes the place of the approval just answered: a second click must not answer it.
            if let at = CardInputLock.handoverArmedAt(shown: shownApprovalId, next: nextQuestion.id,
                                                      now: Date().timeIntervalSinceReferenceDate) {
                cardReplacedAt = at
            }
            showQuestionHead()
            return
        }
        #if !APPSTORE
        if presentNextCmuxCard() { return }
        #endif
        if HermesApprovalCenter.shared.presentNextIfFree() { return }
        if let note {
            state.noteMessage = note
            state.view = .note
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                // A Hermes answer announced meanwhile keeps the island open.
                if AppState.shared.hermesAnnounceHoldsIsland { return }
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
        } else {
            state.view = state.tasks.isEmpty ? .empty : .overview
        }
    }

    // MARK: - Sessions on the board

    /// A session's key on the board: its id, or for one that sends none its pill and folder
    /// (the same key the recap and the question queue use).
    private static func boardKey(_ session: String, pill: String, cwd: String) -> String {
        (session == "unknown" || session.isEmpty) ? "\(pill)+\(cwd)" : session
    }

    /// Records what an event says about a session of `pill` on the board.
    @MainActor
    private func record(pill: String, session key: String, raw: String, title: String,
                        _ change: (inout BoardSession) -> Void = { _ in }) {
        board.update(pill: pill, session: key, rawSession: raw, title: title, now: Date(), change)
    }

    /// The sessions of `pill` waiting for you, with what they wait for (a permission first).
    @MainActor
    private func waitingSessions(pill: String) -> [String: BotState] {
        var waiting: [String: BotState] = [:]
        for q in questions.entries where q.pillId == pill { waiting[q.sessionId] = .question }
        for a in approvals.entries where a.pillId == pill {
            waiting[Self.boardKey(a.sessionId, pill: pill, cwd: a.cwd)] = .approval
        }
        return waiting
    }

    /// A session that starts waiting while it shares `pill` with another pops out into a pill
    /// of its own. Returns that pill, nil when the session stays (it is alone in its pill).
    @MainActor
    private func popOutIfShared(pill: String, session key: String, raw: String, title: String) -> String? {
        record(pill: pill, session: key, raw: raw, title: title)
        let popped = board.popOut(pill: pill, session: key, now: Date())
        if let popped { nbLog("\(key.prefix(8)) waits: out of \(pill) into \(popped)") }
        return popped
    }

    /// Writes the board to `pill` and to the pills popped out of it: the session the pill
    /// shows (name, steps, state, last message, terminal), the list the open card shows when
    /// several share it, each popped-out session's own pill, and the folding back of those
    /// no longer waiting.
    @MainActor
    private func syncPill(_ pill: String) {
        let state = AppState.shared
        let now = Date()
        var gone = board.keep(pill: pill) { sessions.display(pill: pill, session: $0.rawSession) != nil }
        let waiting = waitingSessions(pill: pill)
        let (folded, recheck) = board.fold(pill: pill, waiting: Set(waiting.keys), now: now)
        gone += folded
        for id in gone where state.tasks.contains(where: { $0.id == id }) {
            if state.focusId == id { state.focusId = pill }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.removeTask(id: id) }
        }
        if let recheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, recheck.timeIntervalSince(now))) { [weak self] in
                self?.syncPill(pill)
            }
        }
        guard let client = state.tasks.first(where: { $0.id == pill }) else { return }
        for (session, popped) in board.poppedOut(pill: pill) {
            showPoppedOut(popped, of: client, session: session, waiting: waiting[session])
        }
        guard let index = state.tasks.firstIndex(where: { $0.id == pill }) else { return }
        guard let shown = board.shown(pill: pill, waiting: Set(waiting.keys), now: now),
              let session = board.session(pill: pill, session: shown) else {
            if !state.tasks[index].sessionLines.isEmpty { state.tasks[index].sessionLines = [] }
            return
        }
        write(session, waiting: waiting[shown], client: pill, to: index)
        let lines = board.lines(pill: pill).map { line in
            SessionLine(id: line.session, title: line.value.title,
                        state: waiting[line.session] ?? line.value.state,
                        lastStep: Self.readableStep(line.value.steps.last ?? ""),
                        isShown: line.session == shown)
        }
        if state.tasks[index].sessionLines != lines { state.tasks[index].sessionLines = lines }
    }

    /// Puts one session's state, steps, last message, title and terminal on the task at `index`.
    @MainActor
    private func write(_ session: BoardSession, waiting: BotState?, client: String, to index: Int) {
        let state = AppState.shared
        var task = state.tasks[index]
        task.state = waiting ?? session.state
        if task.steps != session.steps {
            task.steps = session.steps
            task.stepIndex = max(0, session.steps.count - 1)
        }
        task.finalLine = session.finalLine
        // A third-party agent's pill keeps the agent's name; Claude Code's and Codex's take the session's.
        if !session.title.isEmpty, task.isIntegration || task.pill == "agent_claude-desktop" || task.id != task.pill {
            task.name = session.title
        }
        if let display = sessions.display(pill: client, session: session.rawSession) {
            if !display.cwd.isEmpty { task.sessionCwd = display.cwd }
            if task.pill == "integration_claude" { task.hostApp = display.hostApp }
            if !display.bundleId.isEmpty { task.sessionBundleId = display.bundleId }
        }
        if state.tasks[index] != task { state.tasks[index] = task }
    }

    /// Creates or refreshes the pill a waiting session popped out into, right after its
    /// client's pills, in the client's color.
    @MainActor
    private func showPoppedOut(_ id: String, of client: AgentTask, session: String, waiting: BotState?) {
        guard let value = board.session(pill: client.id, session: session) else { return }
        let state = AppState.shared
        if !state.tasks.contains(where: { $0.id == id }) {
            var task = AgentTask(id: id, name: value.title, color: client.color, state: waiting ?? value.state,
                                 steps: [], source: client.source, isIntegration: client.isIntegration)
            task.hostApp = client.hostApp
            let at = (state.tasks.lastIndex(where: { $0.pill == client.pill }) ?? state.tasks.count - 1) + 1
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.tasks.insert(task, at: at) }
        }
        guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        write(value, waiting: waiting, client: client.id, to: index)
    }

    /// A step as the open card lists it: a file edit reads "name +3 −1".
    private static func readableStep(_ step: String) -> String {
        guard let diff = step.parseDiffStep() else { return step }
        return "\(diff.filename) +\(diff.added) −\(diff.removed)"
    }

    // MARK: - Question queue helpers

    /// Puts the oldest waiting question on the card. When the card already shows it, only
    /// the list the card and the iPhone read is refreshed (no sound, no focus change).
    @MainActor
    private func showQuestionHead() {
        let state = AppState.shared
        state.waitingQuestions = questions.entries
        guard let head = questions.head else { return }
        let needsDisplay = shownQuestion != head.id || state.view != .question
        guard needsDisplay else { return }
        // Another question takes the card (or this one covers an approval): a click aimed at the previous card must not answer it.
        if let at = CardInputLock.handoverArmedAt(shown: shownQuestion ?? state.pendingApproval?.id, next: head.id,
                                                  now: Date().timeIntervalSinceReferenceDate) {
            cardReplacedAt = at
        }
        shownQuestion = head.id
        state.pendingQuestion = head.question
        state.isPinned = true
        if focusBeforeQuestion == nil { focusBeforeQuestion = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = head.displayPill }
        expandIfNeeded(to: .question)
    }

    /// Takes one question out of the queue. With `answer`, the line is written to its nb-hook
    /// first; without, the connection just closes and the agent asks again itself. The cancel
    /// handler of its source closes the fd — never close it directly. The next question then
    /// takes the card; when none is left the card closes.
    @MainActor
    private func removeQuestion(id: UUID, answer json: String? = nil) {
        guard let entry = questions.remove(id: id) else { return }
        let source = questionSources.removeValue(forKey: id)
        if let json {
            let fd = entry.fd
            Task.detached { [weak self] in
                // Write while the fd is still valid, then cancel → the cancel handler closes it.
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }

        let state = AppState.shared
        // The session's pill leaves its question state; a popped-out one folds back soon after.
        syncPill(entry.pillId)
        if !questions.entries.contains(where: { $0.displayPill == entry.displayPill })
            && !approvals.entries.contains(where: { $0.displayPill == entry.displayPill }) {
            clearPillBadge(id: entry.displayPill)
        }
        if questions.head != nil {
            showQuestionHead()
            return
        }
        state.waitingQuestions = []
        closeQuestionCard(pill: entry.displayPill)
    }

    /// No question left: close the card and give the focus back, or return to
    /// an approval waiting behind it (#851).
    @MainActor
    private func closeQuestionCard(pill: String?) {
        let state = AppState.shared
        let closedQuestion = shownQuestion
        shownQuestion = nil
        state.pendingQuestion = nil
        state.isPinned = false
        if let prev = focusBeforeQuestion {
            focusBeforeQuestion = nil
            if let pill, state.focusId == pill, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        if let head = approvals.head {
            // The approval takes the place of the question just answered: a second click must not approve it.
            if let at = CardInputLock.handoverArmedAt(shown: closedQuestion, next: head.id,
                                                      now: Date().timeIntervalSinceReferenceDate) {
                cardReplacedAt = at
            }
            state.pendingApproval = ApprovalInfo(sessionId: head.sessionId, tool: head.tool,
                                                  command: head.command, inputKey: head.inputKey,
                                                  pillId: head.displayPill, id: head.id,
                                                  queueCount: approvals.count,
                                                  projectName: head.projectName)
            state.isPinned = true
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = head.displayPill }
            expandIfNeeded(to: .approval)
            return
        }
        #if !APPSTORE
        if presentNextCmuxCard() { return }
        #endif
        if HermesApprovalCenter.shared.presentNextIfFree() { return }
        state.view = state.tasks.isEmpty ? .empty : .overview
    }

    /// The question `id` (the one the card or the iPhone showed), else the card's.
    /// nil when that question no longer waits.
    @MainActor
    private func waitingQuestion(_ id: UUID?) -> QueuedQuestion? {
        guard let id else { return questions.head }
        guard let entry = questions.entry(id: id) else {
            nbLog("Answer for a question no longer waiting, ignored")
            return nil
        }
        return entry
    }

    /// Called by QuestionView and the iPhone. Sends the answers to the session that asked
    /// question `id` (the card's when nil), then the next question takes the card.
    @MainActor
    func sendQuestionAnswers(_ answers: [String: Any], for id: UUID? = nil) {
        // Only intercept a demo question — real questions always have a live fd.
        if DemoEngine.shared.isActive, questions.isEmpty, pendingQuestionFD < 0 {
            AppState.shared.pendingQuestion = nil
            if DemoGuard.mayChangeView(DemoEngine.shared.realPending) {
                AppState.shared.isPinned = false
                AppState.shared.view = AppState.shared.tasks.isEmpty ? .empty : .overview
            }
            DemoEngine.shared.handleQuestionAnswered(answers: answers)
            return
        }
        // The cmux card holds the slot with its own connection.
        if pendingQuestionFD >= 0 {
            if let id, id != AppState.shared.cmuxLaneQuestion?.id {
                nbLog("Answer for a question no longer on the card, ignored")
                return
            }
            sendLaneQuestionAnswers(answers)
            return
        }
        guard !questions.isEmpty else { closeQuestionCard(pill: nil); return }
        if cardReplacedLocked() { return }
        guard let entry = waitingQuestion(id) else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["permissionDecision": "answer", "answers": answers], options: .withoutEscapingSlashes),
              let json = String(data: data, encoding: .utf8) else {
            removeQuestion(id: entry.id)
            return
        }
        RecapStore.shared.recordQuestionAnswered(sessionId: entry.sessionId)
        removeQuestion(id: entry.id, answer: json)
    }

    /// Called by QuestionView.onDisappear — the card left the screen without an answer.
    /// Every waiting question goes back to its terminal ("ask") at once, since none of them
    /// is on screen any more; does NOT navigate (view already changed).
    @MainActor
    func releaseQuestionFD() {
        if pendingQuestionFD >= 0 {
            releaseLaneQuestion()
            return
        }
        guard !questions.isEmpty else { return }
        let state = AppState.shared
        let gone = questions.removeAll()
        for entry in gone {
            let source = questionSources.removeValue(forKey: entry.id)
            let fd = entry.fd
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { source?.cancel() }
            }
        }
        shownQuestion = nil
        focusBeforeQuestion = nil
        state.waitingQuestions = []
        state.pendingQuestion = nil
        for pill in Set(gone.map(\.pillId)) {
            syncPill(pill)
            clearPillBadge(id: pill)
        }
    }

    /// Called by QuestionView "Reply in terminal" button: question `id` (the card's when nil)
    /// goes back to its terminal.
    @MainActor
    func sendQuestionAsk(for id: UUID? = nil) {
        if pendingQuestionFD >= 0 {
            if let id, id != AppState.shared.cmuxLaneQuestion?.id {
                nbLog("Reply-in-terminal for a question no longer on the card, ignored")
                return
            }
            sendLaneQuestionAsk()
            return
        }
        guard !questions.isEmpty else { closeQuestionCard(pill: nil); return }
        if cardReplacedLocked() { return }
        guard let entry = waitingQuestion(id) else { return }
        removeQuestion(id: entry.id, answer: #"{"permissionDecision":"ask"}"#)
    }

    // MARK: - The cmux lane of the question slot

    @MainActor
    private func cancelQuestionFDSource() {
        questionFDSource?.cancel()
        questionFDSource = nil
    }

    /// The question card is gone: a Claude approval it covered goes back on the card (its fd is still live, so the cmux
    /// queue and Hermes cannot take the slot). The lock keeps a click aimed at the question from answering it.
    @MainActor
    private func reshowApprovalHeadAfterQuestion() -> Bool {
        guard approvals.head != nil else { return false }
        cardReplacedAt = CardInputLock.armedAt(cardWasVisible: true, now: Date().timeIntervalSinceReferenceDate)
        showApprovalHead()
        expandIfNeeded(to: .approval)
        return true
    }

    @MainActor
    private func dismissQuestionCard(note: String, leftOpen: Bool = false) {
        var cardKey: String? = nil
        #if !APPSTORE
        cardKey = cmuxShownKey
        cmuxShownPayload = nil
        if leftOpen {
            markCmuxDialogOpen(cardKey, tool: "AskUserQuestion", inputKey: nil)
        } else {
            timeline(.question(text: "", more: 0, outcome: .handled), cardKey)
        }
        #endif
        cancelQuestionFDSource()
        pendingQuestionFD = -1
        let state = AppState.shared
        let pillId = questionPillId
        state.pendingQuestion = nil
        state.isPinned = false
        setTaskState(pillId, .working, cmuxKey: cardKey)
        clearPillBadgeUnlessCardHeld(id: pillId)
        if let prev = focusBeforeQuestion {
            focusBeforeQuestion = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
        if reshowApprovalHeadAfterQuestion() { return }
        if questions.head != nil {
            cardReplacedAt = CardInputLock.armedAt(cardWasVisible: true, now: Date().timeIntervalSinceReferenceDate)
            showQuestionHead()
            return
        }
        #if !APPSTORE
        if presentNextCmuxCard() { return }
        #endif
        if HermesApprovalCenter.shared.presentNextIfFree() { return }
        if !note.isEmpty {
            state.noteMessage = note
            state.view = .note
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .islandCollapse, object: nil)
            }
        } else {
            state.view = state.tasks.isEmpty ? .empty : .overview
        }
    }

    /// QuestionView on a cmux question: sends the answers JSON and cleans up.
    @MainActor
    private func sendLaneQuestionAnswers(_ answers: [String: Any]) {
        if cardReplacedLocked() { return }
        #if !APPSTORE
        if cmuxInputLocked() { return }
        #endif
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        let sid = questionSessionId
        questionSessionId = ""
        if fd >= 0, let data = try? JSONSerialization.data(withJSONObject: ["permissionDecision": "answer", "answers": answers], options: .withoutEscapingSlashes),
           let json = String(data: data, encoding: .utf8) {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }
        if !sid.isEmpty { RecapStore.shared.recordQuestionAnswered(sessionId: sid) }
        #if !APPSTORE
        // The labels chosen on the card, in the order of its questions.
        if let asked = AppState.shared.pendingQuestion {
            let labels = asked.questions.compactMap { item -> String? in
                if let one = answers[item.question] as? String { return one }
                if let many = answers[item.question] as? [String] { return many.joined(separator: ", ") }
                return nil
            }
            timeline(.question(text: "", more: 0, outcome: .answered(labels.joined(separator: ", "))), cmuxShownKey)
        }
        #endif
        dismissQuestionCard(note: "")
    }

    /// QuestionView.onDisappear on a cmux question — the card left the screen without an explicit answer.
    /// Sends "ask" immediately to unblock nb-hook; does NOT navigate (view already changed).
    @MainActor
    private func releaseLaneQuestion() {
        guard pendingQuestionFD >= 0 else { return }
        #if !APPSTORE
        markCmuxDialogOpen(cmuxShownKey, tool: "AskUserQuestion", inputKey: nil)
        cmuxShownPayload = nil
        #endif
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        AppState.shared.pendingQuestion = nil
        Task.detached { [weak self] in
            self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
            DispatchQueue.main.async { source?.cancel() }
        }
        // Runs from onDisappear: the next card (queue head, cmux queue, Hermes) comes on the next turn.
        DispatchQueue.main.async {
            if self.reshowApprovalHeadAfterQuestion() { return }
            if self.questions.head != nil {
                self.cardReplacedAt = CardInputLock.armedAt(cardWasVisible: true, now: Date().timeIntervalSinceReferenceDate)
                self.showQuestionHead()
                return
            }
            #if !APPSTORE
            _ = self.presentNextCmuxCard()
            #endif
            HermesApprovalCenter.shared.presentNextIfFree()
        }
    }

    /// "Reply in terminal" on a cmux question.
    @MainActor
    private func sendLaneQuestionAsk() {
        if cardReplacedLocked() { return }
        #if !APPSTORE
        if cmuxInputLocked() { return }
        #endif
        let fd = pendingQuestionFD
        pendingQuestionFD = -1
        let source = questionFDSource
        questionFDSource = nil
        if fd >= 0 {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { source?.cancel() }
            }
        } else {
            source?.cancel()
        }
        dismissQuestionCard(note: "", leftOpen: true)
    }

    /// Returns the tool_input serialized as sorted-keys JSON, "" if absent or empty.
    /// Same computation used in processPermissionRequest and processEvent to match PostToolUse.
    private static func approvalInputKey(_ input: [String: Any]) -> String {
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    // MARK: - Start

    func start() {
        // Ensure support directory exists (mode 0700 — not world-readable)
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        #if !APPSTORE
        installHookScript()
        // cmux quit: its capability tokens are dead, drop them (tasks stay, the next event brings new ones).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == CmuxRouting.bundleId else { return }
            MainActor.assumeIsolated { self?.cmuxRegistry.clearCredentials() }
        }
        // cmux launched or activated: the workspaces may have changed. Throttled, one run at a time. Leaving cmux
        // is no trigger: nothing changed by itself.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == CmuxRouting.bundleId else { return }
                MainActor.assumeIsolated { self?.requestCmuxDiscovery() }
            }
        }
        // App start with cmux already running: one discovery once the pills are loaded.
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == CmuxRouting.bundleId }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.requestCmuxDiscovery() }
            }
        }
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        // sun_path on macOS is 104 bytes including the NUL terminator → max 103 usable bytes
        let maxSunPathBytes = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size - 1
        guard path.utf8.count <= maxSunPathBytes else {
            NSLog("HookServer: socket path too long (\(path.utf8.count) bytes, max \(maxSunPathBytes)): \(path)")
            return
        }
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        // Restrict socket to owner only
        chmod(path, 0o600)
        guard Darwin.listen(fd, 32) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else {
                // Never end the server on a failed accept (#853); pause unless it was transient.
                // A listening socket that is gone for good (closed, not a socket) ends the loop.
                let err = errno
                if err == EBADF || err == EINVAL || err == ENOTSOCK { break }
                if err != EINTR && err != ECONNABORTED { usleep(100_000) }
                continue
            }
            // Reject connections from other users (same-UID check)
            var euid: uid_t = 0
            var egid: gid_t = 0
            guard getpeereid(clientFD, &euid, &egid) == 0, euid == getuid() else {
                close(clientFD)
                continue
            }
            // Enforce concurrent connection ceiling
            connectionLock.lock()
            let count = connectionCount
            if count < Self.maxConnections { connectionCount += 1 }
            connectionLock.unlock()
            guard count < Self.maxConnections else {
                close(clientFD)
                continue
            }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        defer {
            connectionLock.lock(); connectionCount -= 1; connectionLock.unlock()
        }
        // 5-second receive timeout — unresponsive clients don't hold threads forever
        var tv = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
            if raw.count > Self.maxPayload { break }
        }

        guard !raw.isEmpty,
              let rawPayload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }
        #if !APPSTORE
        // The cmux capability is a credential: strip it before any other code sees the payload.
        var scrubbed = rawPayload
        let cmuxToken = (scrubbed.removeValue(forKey: "cmux_socket_capability") as? String) ?? ""
        let payload = scrubbed
        #else
        let payload = rawPayload
        #endif

        let coucouKind = payload["coucou_kind"] as? String ?? ""

        // statusline payloads are handled separately — no session, no reveal, no sound
        if coucouKind == "statusline" {
            Task { @MainActor in self.processStatusLine(payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        // AskUserQuestion via --ask PreToolUse hook — hold fd open like PermissionRequest
        if coucouKind == "ask_user_question" {
            let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
            if let parsed = AskQuestion.parse(toolInput: toolInput) {
                Task { @MainActor in
                    #if !APPSTORE
                    self.noteCmuxContext(payload: payload, token: cmuxToken)
                    #endif
                    self.processQuestionRequest(fd: fd, parsed: parsed, payload: payload)
                }
            } else {
                // Malformed payload — fall back: send ask so Claude Code re-asks in terminal
                sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in
                #if !APPSTORE
                self.noteCmuxContext(payload: payload, token: cmuxToken)
                #endif
                self.processPermissionRequest(fd: fd, payload: payload)
            }
        } else {
            Task { @MainActor in
                #if !APPSTORE
                self.noteCmuxContext(payload: payload, token: cmuxToken)
                #endif
                self.processEvent(name: eventName, payload: payload)
            }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // Claude Code events route to the permanent "integration_claude" task.
    // Events tagged with a valid coucou_agent route to a dynamic "integration_<agent>" task.
    // View switches only happen if VS Code (or the agent pill) is currently focused.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let projectName = sessionName(payload, cwd: cwd)

        // Determine which pill this event belongs to.
        // coucou_agent must be lowercase, digits and hyphens, ≤ 24 chars.
        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let validAgent = Self.validateAgent(rawAgent)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""

        // Cursor identified solely by its stable Electron bundle ID.
        // ToDesktop builds other apps too — do not match on "todesktop" alone.
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))
        // The pill of a cmux event is the pill of its surface's registry entry, whatever workspace the payload names.
        #if !APPSTORE
        let cmuxTaskId = cmuxRoutedTaskId(payload: payload)
        #else
        let cmuxTaskId: String? = nil
        #endif

        // Routing:
        // • "codex" → agent_codex (GitHub build only: workspace pill, approvals in the notch)
        // • other valid coucou_agent → external pill (fire-and-forget, no approval card)
        // • Cursor bundle ID → agent_cursor
        // • VS Code → integration_claude
        // • a known terminal (Warp, Terminal, iTerm…) → integration_claude, host recorded on the task
        #if !APPSTORE
        let isCodexEvent = rawAgent == "codex"
        #else
        let isCodexEvent = false
        #endif
        let agentId: String
        let isExternalAgent: Bool
        var hostApp: String? = nil
        if isCodexEvent {
            agentId = "agent_codex"
            isExternalAgent = false
        } else if let agent = validAgent {
            agentId = "agent_\(agent)"
            isExternalAgent = true
        } else if isCursorEditor {
            agentId = "agent_cursor"
            isExternalAgent = false
        } else if isVSCodeEditor {
            agentId = "integration_claude"
            isExternalAgent = false
        } else if let id = cmuxTaskId {
            agentId = id
            isExternalAgent = false
        } else if let host = Self.terminalHost(termProgram: termProgram, bundleId: bundleId) {
            agentId = "integration_claude"
            isExternalAgent = false
            hostApp = host.bundleId
        } else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        /// Surface key of the cmux session that sent the event. Only an event that really belongs to the cmux pill
        /// speaks for one of its surfaces (a Codex session inside cmux is its own pill).
        #if !APPSTORE
        let cmuxKey: String? = (cmuxTaskId != nil && cmuxTaskId == agentId) ? CmuxRouting.surfaceKey(payload: payload) : nil
        if let key = cmuxKey, cmuxRegistry.surface(key: key) == nil, name != "SessionEnd" {
            // Past the per pill cap (or not registered): such a session has no state of its own and must not
            // write the pill's.
            nbLog("Ignored \(name) of an unregistered cmux session")
            return
        }
        #else
        let cmuxKey: String? = nil
        #endif

        #if !APPSTORE
        if let routed = cmuxTaskId, routed == agentId {
            let eventInputKey = Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:])
            // Only a hook event carrying a valid token for the surface (heard) may clear a dialog mark.
            if let key = cmuxKey, cmuxRegistry.surface(key: key)?.heard == true, let mark = cmuxOpenDialogs[key],
               CmuxRouting.dialogResolved(mark: mark, event: name, tool: payload["tool_name"] as? String ?? "",
                                          inputKey: eventInputKey) {
                cmuxOpenDialogs[key] = nil
            }
            purgeCmuxQueue(event: name, sessionId: sessionId,
                           tool: payload["tool_name"] as? String ?? "",
                           inputKey: Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]))
        }
        #endif

        let focused = state.focusId == agentId
        // The user is looking at the session's terminal: a finish or an error is already in
        // front of them, so the pill only takes a badge (no sound, no reveal). Warp exposes
        // no active tab, so a sibling session in another tab of the same terminal is quiet too.
        let terminalInFront = hostApp != nil
            && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == hostApp
        #if !APPSTORE
        var cardPromoted = false
        #else
        let cardPromoted = false
        #endif
        // Several sessions can share one pill (it is chosen from the client, not from the
        // session). The registry tells a turn-ending event whether it may touch the pill,
        // and which session owns the project name shown on it.
        let display = PillSessionRegistry.Display(
            session: sessionId,
            projectName: isExternalAgent ? (validAgent ?? projectName) : projectName,
            cwd: isExternalAgent ? "" : cwd,
            hostApp: hostApp, bundleId: bundleId)
        // For sessions that carry no id, derive a unique key from pill + cwd so that
        // concurrent anonymous sessions are tracked independently in RecapStore.
        let recapSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(agentId)+\(cwd)"
            : sessionId

        #if PHONE_LINK
        // The iPhone's "last turn" (prompt, actions, diffs, answer).
        if !isExternalAgent { TurnRecorder.shared.record(event: name, payload: payload, pillId: agentId) }
        #endif

        #if !APPSTORE
        let generationBefore = cardGeneration
        #endif
        // Waiting permission requests: an event that settles one (its tool finished, or its
        // turn ended) takes it off the card, then is processed normally.
        if !approvals.isEmpty {
            let eventTool = payload["tool_name"] as? String ?? ""
            let eventKey = Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:])
            for entry in approvals.resolved(byEvent: name, sessionId: sessionId, pillId: agentId,
                                            tool: eventTool, inputKey: eventKey) {
                removeApproval(id: entry.id, note: handledNote(pill: entry.displayPill))
            }
            // A session still waiting on a decision is held back (its parallel tool calls
            // would pull the pill out of its approval state). Other sessions go through.
            if approvals.entries.contains(where: { $0.pillId == agentId && $0.sessionId == sessionId }) {
                return
            }
        }
        // A cmux card holds the slot: dismiss it when the resolving event arrives, then continue normal
        // processing. Only skip normal processing when unresolved.
        // A cmux pill holds several sessions: only an event of the session that asked is about the card.
        #if !APPSTORE
        let cmuxPillEvent = CmuxRouting.isCmuxTaskId(agentId)
        #else
        let cmuxPillEvent = false
        #endif
        if pendingApprovalFD >= 0, let pending = state.pendingApproval, agentId == pending.pillId,
           pending.sessionId != "demo_session",
           !cmuxPillEvent || sessionId == pending.sessionId {
            let dismissNote = handledNote(pill: pending.pillId)
            var resolved = false
            switch name {
            case "PostToolUse", "PostToolUseFailure":
                // Only dismiss when this exact tool call finished — same session, tool and input.
                // Other parallel tools finishing must not close the card.
                if sessionId == pending.sessionId,
                   (payload["tool_name"] as? String ?? "") == pending.tool,
                   Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]) == pending.inputKey {
                    dismissApprovalCard(note: dismissNote, resolved: true)
                    resolved = true
                }
            case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
                // Turn ended or session interrupted — the permission is moot.
                if sessionId == pending.sessionId {
                    dismissApprovalCard(note: dismissNote, resolved: true)
                    resolved = true
                }
            default: break
            }
            if !resolved { return }
            // Approval dismissed — fall through so the resolving event updates state normally.
        }
        #if !APPSTORE
        // A dismissal promoted a queued card: the resolving event must not take the view from it.
        cardPromoted = cardGeneration != generationBefore
        #endif
        // What the event says goes to its session on the board, and the pill shows the board:
        // the session it shows, its steps and state; a session waiting for you keeps that state.
        // A cmux session is not on the board: its pill folds the states of its own surfaces (the registry), and
        // `syncPill` leaves a pill with no board session alone.
        let key = recapSessionId
        let now = Date()
        func note(_ change: (inout BoardSession) -> Void = { _ in }) {
            record(pill: agentId, session: key, raw: sessionId, title: projectName, change)
        }
        func step(_ text: String) {
            if cmuxKey != nil { appendStep(id: agentId, step: stepPrefix(forKey: cmuxKey) + text) } else { note { $0.appendStep(text) } }
        }
        defer { syncPill(agentId) }

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            upsertTask(pill: agentId, display: display, working: false,
                       externalAgent: isExternalAgent ? validAgent : nil, cmuxKey: cmuxKey)
            if cmuxKey == nil {
                note { $0.finalLine = nil }
            } else if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
                state.tasks[idx].finalLine = nil
            }
            #if !APPSTORE
            if cmuxTaskId == agentId {
                refreshCmuxMeta(taskId: agentId, cwd: cwd, key: cmuxKey)
                handleCmuxSessionStart(agentId: agentId, key: cmuxKey, payload: payload, cwd: cwd)
                requestCmuxDiscovery()
                // A new conversation (startup, clear) starts a new timeline; a compaction keeps it and says so.
                switch payload["source"] as? String {
                case "startup", "clear": timeline(.reset, cmuxKey)
                case "compact": timeline(.notice(String(localized: "Conversation compacted.")), cmuxKey)
                default: break
                }
            }
            #endif
            nbLog("SessionStart \(isExternalAgent ? agentId : projectName) (\(sessionId.prefix(8)))")
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")
            if agentId == "agent_hermes", let platform = payload["platform"] as? String,
               !platform.isEmpty, platform != "cli" {
                let capitalized = platform.prefix(1).uppercased() + platform.dropFirst()
                step(String(capitalized))
            }

        case "UserPromptSubmit":
            activeSessionId = sessionId
            upsertTask(pill: agentId, display: display, working: true,
                       externalAgent: isExternalAgent ? validAgent : nil, cmuxKey: cmuxKey)
            if cmuxKey == nil {
                note {
                    $0.state = .thinking
                    $0.finalLine = nil
                    $0.endedAt = nil
                    if let prompt = payload["prompt"] as? String, !prompt.isEmpty { $0.appendStep(String(prompt.prefix(60))) }
                }
            } else {
                if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
                setTaskState(agentId, .thinking, cmuxKey: cmuxKey)
                #if !APPSTORE
                if let key = cmuxKey { cmuxStopRecord.prompt(key) }
                #endif
                if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                    step(String(prompt.prefix(60)))
                    #if !APPSTORE
                    timeline(.prompt(prompt), cmuxKey)
                    #endif
                }
            }
            #if !APPSTORE
            if cmuxTaskId == agentId {
                refreshCmuxMeta(taskId: agentId, cwd: cwd, key: cmuxKey)
                requestCmuxDiscovery()
            }
            #endif
            RecapStore.shared.userPromptSubmit(sessionId: recapSessionId, pillId: agentId, project: projectName)
            NotificationCenter.default.post(name: .checkMondayRecap, object: nil)
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            let tool = payload["tool_name"] as? String ?? "Tool"
            if cmuxKey == nil {
                note { $0.finalLine = nil }
            } else if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
                state.tasks[idx].finalLine = nil
            }
            RecapStore.shared.preToolUse(sessionId: recapSessionId, tool: tool)
            // AskUserQuestion is handled via the dedicated --ask hook.
            // Skip state/step update here to avoid flickering over the question card.
            guard tool != "AskUserQuestion" else { break }
            upsertTask(pill: agentId, display: display, working: true,
                       externalAgent: isExternalAgent ? validAgent : nil, cmuxKey: cmuxKey)
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            if cmuxKey == nil {
                let isQuestion = tool == "ask_question" || tool.hasSuffix(":ask_question")
                let label = localizedStep(tool: tool, input: input)
                note {
                    $0.state = isQuestion ? .question : .working
                    $0.endedAt = nil
                    $0.appendStep(label)
                }
                if isQuestion {
                    SoundEngine.shared.play("question")
                    if state.isPresent { expandIfNeeded(to: .overview) }
                }
            } else {
                setTaskState(agentId, .working, cmuxKey: cmuxKey)
                let parts = stepParts(tool: tool, input: input)
                step(parts.detail.map { "\(parts.verb) · \($0)" } ?? parts.verb)
                #if !APPSTORE
                timeline(.toolStarted(key: timelineKey(tool: tool, input: input), tool: parts.verb,
                                      symbol: TimelineNames.symbol(forTool: tool), label: parts.timelineDetail ?? ""), cmuxKey)
                #endif
            }
            nbLog("PreToolUse \(tool)")

        case "PostToolUse":
            if cmuxKey == nil {
                sessions.note(pill: agentId, display: display, working: true)
                note { $0.state = .working }
            } else {
                setTaskState(agentId, .working, cmuxKey: cmuxKey)
            }
            // Live diff for Edit / MultiEdit / Write
            let diffTool = payload["tool_name"] as? String ?? ""
            let diffInput = payload["tool_input"] as? [String: Any] ?? [:]
            var timelineEdit: ChatEdit? = nil
            if let diff = buildFileDiff(tool: diffTool, input: diffInput, pillId: agentId) {
                let idx = state.appendSessionDiff(diff, for: agentId)
                // A cmux step keeps its bare diff marker (no session prefix): the card parses it.
                let diffStep = String.makeDiffStep(filename: diff.name, added: diff.added, removed: diff.removed, diffId: idx)
                if cmuxKey == nil { note { $0.appendStep(diffStep) } } else { appendStep(id: agentId, step: diffStep) }
                RecapStore.shared.recordFileDiff(sessionId: recapSessionId, path: diff.name, added: diff.added, removed: diff.removed)
                #if !APPSTORE
                // The same diff and the id the store gave it: the timeline row opens that diff.
                if cmuxKey != nil { timelineEdit = Self.timelineEdit(diff: diff, diffId: idx) }
                #endif
            }
            #if !APPSTORE
            if cmuxKey != nil {
                let parts = stepParts(tool: diffTool, input: diffInput)
                timeline(.toolFinished(key: timelineKey(tool: diffTool, input: diffInput), tool: parts.verb,
                                       symbol: TimelineNames.symbol(forTool: diffTool), label: parts.timelineDetail ?? "",
                                       failedWord: nil, edit: timelineEdit, allowedWord: String(localized: "allowed")), cmuxKey)
            }
            #endif

        case "PostToolUseFailure":
            if cmuxKey == nil {
                sessions.note(pill: agentId, display: display, working: true)
                note {
                    $0.state = .working
                    $0.appendStep(String(localized: "⚠ failed"))
                }
            } else {
                setTaskState(agentId, .working, cmuxKey: cmuxKey)
                step(String(localized: "⚠ failed"))
                #if !APPSTORE
                let failedTool = payload["tool_name"] as? String ?? ""
                let failedInput = payload["tool_input"] as? [String: Any] ?? [:]
                let parts = stepParts(tool: failedTool, input: failedInput)
                timeline(.toolFinished(key: timelineKey(tool: failedTool, input: failedInput), tool: parts.verb,
                                       symbol: TimelineNames.symbol(forTool: failedTool), label: parts.timelineDetail ?? "",
                                       failedWord: String(localized: "⚠ failed"), edit: nil,
                                       allowedWord: String(localized: "allowed")), cmuxKey)
                #endif
            }

        case "Notification":
            if cmuxKey == nil { sessions.note(pill: agentId, display: display, working: false) }
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            // The kind and whether a badge was set go to the log, never the message.
            var kind = "other"
            var badgeSet = false
            if lower.contains("rate limit") || lower.contains("limite d") {
                kind = "ratelimit"
                #if !APPSTORE
                timeline(.notice(String(localized: "Rate limit reached.")), cmuxKey)
                #endif
                if cmuxKey == nil { note { $0.state = .ratelimit } } else { setTaskState(agentId, .ratelimit, cmuxKey: cmuxKey) }
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                kind = "question"
                if cmuxKey == nil {
                    note {
                        $0.state = .question
                        $0.appendStep(message)
                    }
                } else {
                    setTaskState(agentId, .question, cmuxKey: cmuxKey)
                    step(message)
                }
            } else {
                #if !APPSTORE
                // A cmux session that waits for the user (cmux shows its own "Waiting" notification) and whose Stop
                // told nobody: the badge of a finished turn, once, nothing louder.
                if let key = cmuxKey,
                   CmuxRouting.isWaitingNotification(type: payload["notification_type"] as? String, message: message) {
                    kind = "waiting"
                    if CmuxRouting.waitingNeedsBadge(
                        stopToldNobody: cmuxStopRecord.toldNobody(key), pillFocused: focused,
                        pillHasBadge: state.tasks.first { $0.id == agentId }?.pillBadge != nil,
                        pillHoldsCard: cmuxTaskHoldsCard(agentId),
                        sessionState: cmuxRegistry.surface(key: key)?.state) {
                        setPillBadge(id: agentId, badge: .finished)
                        cmuxStopRecord.gaveWaitingBadge(key)
                        badgeSet = true
                    }
                }
                #endif
            }
            nbLog("Notification \(isExternalAgent ? agentId : projectName) kind=\(kind) badge=\(badgeSet)")

        case "Stop":
            nbLog("Stop \(isExternalAgent ? agentId : projectName)")
            let rawFinal = (payload["last_assistant_message"] as? String)
                ?? (payload["message"] as? String) ?? ""
            let finalText = DiffEngine.toOneLine(rawFinal)
            if cmuxKey == nil {
                // Each session finishes on its own: its sound, its "finished", its last message,
                // even while a sibling behind the same pill is still working. For a moment the pill
                // shows the session that finished (SessionBoard.finishMoment), then the busy one again.
                _ = sessions.endTurn(pill: agentId, session: sessionId)
                note {
                    $0.state = .finished
                    $0.endedAt = now
                    if !finalText.isEmpty {
                        $0.finalLine = finalText
                        $0.appendStep(finalText)
                    }
                }
                RecapStore.shared.stop(sessionId: recapSessionId)
                let working = sessions.workingCount(pill: agentId)
                if working > 0 { nbLog("Stop \(sessionId.prefix(8)) — \(working) other session(s) still working on \(agentId)") }
                syncPill(agentId)
                let finished = board.poppedPill(pill: agentId, session: key) ?? agentId
                if !terminalInFront { SoundEngine.shared.play("finish") }
                if !terminalInFront && showsAlert(for: finished, focused: state.focusId == finished) {
                    expandIfNeeded(to: .finished)
                } else {
                    setPillBadge(id: finished, badge: .finished)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + SessionBoard.finishMoment) {
                    // The session (or a sibling) may have started a new turn meanwhile.
                    self.board.amend(pill: agentId, session: key) { if $0.state == .finished && $0.endedAt == now { $0.state = .idle } }
                    self.syncPill(agentId)
                    guard self.sessions.workingCount(pill: agentId) == 0 else { return }
                    if isExternalAgent {
                        AppState.shared.removeTask(id: agentId)
                    } else {
                        self.clearPillBadge(id: agentId)
                    }
                }
            } else {
                stopOfCmuxSession(agentId: agentId, sessionId: sessionId, key: cmuxKey, payload: payload, cwd: cwd,
                                  recapSessionId: recapSessionId, rawFinal: rawFinal, finalText: finalText,
                                  focused: focused, cardPromoted: cardPromoted)
            }

        case "StopFailure":
            nbLog("StopFailure \(isExternalAgent ? agentId : projectName)")
            RecapStore.shared.stop(sessionId: recapSessionId)
            if cmuxKey == nil {
                _ = sessions.endTurn(pill: agentId, session: sessionId)
                nbLog("StopFailure \(sessionId.prefix(8)) — \(payload.keys.sorted().joined(separator: ", ")): \(Self.stopFailureDetail(payload) ?? "no detail")")
                // The error view shows what went wrong (finalLine), not the last thing said before it.
                note {
                    $0.state = .error
                    $0.endedAt = now
                    $0.finalLine = Self.stopFailureDetail(payload)
                }
                syncPill(agentId)
                let failed = board.poppedPill(pill: agentId, session: key) ?? agentId
                if !terminalInFront { SoundEngine.shared.play("error") }
                if !terminalInFront && showsAlert(for: failed, focused: state.focusId == failed) {
                    expandIfNeeded(to: .error)
                } else {
                    setPillBadge(id: failed, badge: .error)
                }
                // After the error moment a sibling's work takes the pill again.
                DispatchQueue.main.asyncAfter(deadline: .now() + SessionBoard.errorMoment + 0.1) { self.syncPill(agentId) }
            } else {
                #if !APPSTORE
                if let key = cmuxKey { cmuxStopRecord.stopFailed(key) }
                timeline(.ended(ok: false, note: String(localized: "The turn ended with an error.")), cmuxKey)
                #endif
                guard sessions.endTurn(pill: agentId, session: sessionId) == .pill else { break }
                nbLog("StopFailure \(sessionId.prefix(8)) — \(payload.keys.sorted().joined(separator: ", ")): \(Self.stopFailureDetail(payload) ?? "no detail")")
                setTaskState(agentId, .error, cmuxKey: cmuxKey)
                // The error view shows what went wrong (finalLine), not the last thing said before it.
                if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
                    state.tasks[idx].finalLine = Self.stopFailureDetail(payload)
                    #if !APPSTORE
                    cmuxFinalLineKey[agentId] = cmuxKey
                    #endif
                }
                SoundEngine.shared.play("error")
                #if !APPSTORE
                let errorInPlace = CmuxRouting.answerStaysInReply(prompt: state.cmuxPrompt, taskId: agentId,
                                                                  viewIsPrompt: state.view == .prompt,
                                                                  surfaceKey: cmuxKey,
                                                                  targetKey: cmuxTaskId == nil ? nil : cmuxReplyTarget(for: agentId))
                #else
                let errorInPlace = false
                #endif
                if errorInPlace {
                    // the reply view stays open
                } else {
                    switch alertPlacement(pillId: agentId, cmuxKey: cmuxKey, focused: focused && !cardPromoted) {
                    case .view: expandIfNeeded(to: .error)
                    case .badge: setPillBadge(id: agentId, badge: .error)
                    case .none: break
                    }
                }
            }

        case "Interrupt":
            // Codex: user stopped the turn
            #if !APPSTORE
            timeline(.ended(ok: false, note: String(localized: "Interrupted.")), cmuxKey)
            #endif
            RecapStore.shared.stop(sessionId: recapSessionId)
            if cmuxKey == nil {
                let interruptScope = sessions.endTurn(pill: agentId, session: sessionId)
                note { $0.state = .idle }
                guard interruptScope == .pill else { break }
                activeSessionId = nil
                clearPillBadge(id: agentId)
            } else {
                guard sessions.endTurn(pill: agentId, session: sessionId) == .pill else { break }
                activeSessionId = nil
                setTaskState(agentId, .idle, cmuxKey: cmuxKey)
                clearPillBadgeIfIdle(id: agentId)
            }

        case "SessionEnd":
            // A popped-out session that ends takes its own pill down; the client's pill goes
            // only with the last session behind it.
            if let popped = board.remove(pill: agentId, session: key),
               state.tasks.contains(where: { $0.id == popped }) {
                if state.focusId == popped { state.focusId = agentId }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.removeTask(id: popped) }
            }
            // Only the last session behind the pill may take the card and its diffs down.
            guard sessions.endSession(pill: agentId, session: sessionId) == .pill else {
                RecapStore.shared.sessionEnd(sessionId: recapSessionId)
                nbLog("SessionEnd \(sessionId.prefix(8)) — \(sessions.liveCount(pill: agentId)) session(s) left on \(agentId)")
                break
            }
            activeSessionId = nil
            #if !APPSTORE
            // A cmux pill is a workspace: only the last session that ends takes the pill with it.
            if cmuxTaskId == agentId, let key = cmuxKey {
                let now = Date().timeIntervalSinceReferenceDate
                cmuxEndedAt = cmuxEndedAt.filter { now - $0.value < CmuxRouting.endedGrace * 6 }
                if cmuxEndedAt.count < 64 { cmuxEndedAt[key] = now }
                cmuxStopRecord.forget(key)
                forgetCmuxSurface(key, wasFocused: state.focusId == agentId)
                requestCmuxDiscovery()
                RecapStore.shared.sessionEnd(sessionId: recapSessionId)
                break
            }
            #endif
            if let idx = state.tasks.firstIndex(where: { $0.id == agentId }) { state.tasks[idx].finalLine = nil }
            state.clearSessionDiffs(for: agentId)
            state.removeTask(id: agentId)
            RecapStore.shared.sessionEnd(sessionId: recapSessionId)

        case "SubagentStart":
            step(String(localized: "+ subagent"))

        case "SubagentStop":
            step(String(localized: "• subagent done"))

        default:
            break
        }
    }

    /// The Stop of a session of a cmux pill (a workspace holding one session per surface). Its answer, its state and
    /// its alert follow the registry of that workspace, not the board.
    @MainActor
    private func stopOfCmuxSession(agentId: String, sessionId: String, key cmuxKey: String?, payload: [String: Any],
                                   cwd: String, recapSessionId: String, rawFinal: String, finalText: String,
                                   focused: Bool, cardPromoted: Bool) {
        let state = AppState.shared
        #if !APPSTORE
        let scope = sessions.endTurn(pill: agentId, session: sessionId)
        // A helper that stops while another session of the workspace is mid turn adds a step, nothing else:
        // no sound, no finished view, no badge. The main session is never silent, and a sibling stuck in an
        // old state (error, rate limit) silences nobody. Decided before the state is recorded.
        var silentStop = false
        if let key = cmuxKey {
            let states = Dictionary(cmuxRegistry.surfaces(ofTask: agentId).map { ($0.key, $0.state) },
                                    uniquingKeysWith: { a, _ in a })
            silentStop = CmuxRouting.stopIsSilent(stoppingKey: key, mainKey: cmuxRegistry.surface(for: agentId)?.key,
                                                  states: states)
        }
        if CmuxRouting.isCmuxTaskId(agentId) {
            timeline(.answer(rawFinal), cmuxKey)
            refreshCmuxMeta(taskId: agentId, cwd: cwd, key: cmuxKey)
            requestCmuxDiscovery()
        }
        // The step log is shared, so the conclusion is worth showing either way.
        if !finalText.isEmpty { appendStep(id: agentId, step: stepPrefix(forKey: cmuxKey) + finalText) }
        RecapStore.shared.stop(sessionId: recapSessionId)
        // Another session is still mid-turn behind this pill: the finished state, the
        // sound and the idle reset below would land on its work. Its own Stop comes later.
        guard scope == .pill else {
            nbLog("Stop \(sessionId.prefix(8)) — \(sessions.workingCount(pill: agentId)) session(s) still working on \(agentId)")
            return
        }
        setTaskState(agentId, .finished, cmuxKey: cmuxKey)
        if !finalText.isEmpty, !silentStop, let idx = state.tasks.firstIndex(where: { $0.id == agentId }) {
            state.tasks[idx].finalLine = finalText
            cmuxFinalLineKey[agentId] = cmuxKey
        }
        if !silentStop { SoundEngine.shared.play("finish") }
        // The reply view of this session shows the answer in place: no view switch, the draft stays.
        let answerInPlace = CmuxRouting.answerStaysInReply(prompt: state.cmuxPrompt, taskId: agentId,
                                                           viewIsPrompt: state.view == .prompt,
                                                           surfaceKey: cmuxKey,
                                                           targetKey: cmuxReplyTarget(for: agentId))
        var stopTold = false
        if silentStop {
            // No sound, no view, no final line. A helper of a busy workspace shows itself by the finished badge of
            // its pill at once (what cmux shows), unless the pill is the focused one or a card holds it.
            if CmuxRouting.silentStopPlacement(
                pillFocused: focused, cardOfPillOnScreen: cmuxCardOnScreen(forPill: agentId),
                pillHoldsCard: cmuxTaskHoldsCard(agentId),
                pillHasBadge: state.tasks.first { $0.id == agentId }?.pillBadge != nil) == .badge {
                setPillBadge(id: agentId, badge: .finished)
                stopTold = true
            }
        } else if answerInPlace {
            // nothing to switch
            stopTold = true
        } else {
            switch alertPlacement(pillId: agentId, cmuxKey: cmuxKey, focused: focused && !cardPromoted) {
            case .view:
                expandIfNeeded(to: .finished)
                stopTold = true
            case .badge:
                setPillBadge(id: agentId, badge: .finished)
                stopTold = true
            case .none: break
            }
        }
        if let key = cmuxKey { cmuxStopRecord.stop(key, told: stopTold) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
            if let key = cmuxKey, CmuxRouting.isCmuxTaskId(agentId) {
                self.settleFinishedCmuxSurface(taskId: agentId, key: key)
                return
            }
            // A session (this one or a sibling) may have started a new turn meanwhile.
            guard self.sessions.workingCount(pill: agentId) == 0 else { return }
            AppState.shared.updateTask(id: agentId, state: .idle)
            self.clearPillBadge(id: agentId)
        }
        #endif
    }

    // MARK: - Agent validation + dynamic pill

    /// The terminal host of a Claude Code session. Not cmux in the GitHub build (see `CmuxRouting.terminalHost`).
    private static func terminalHost(termProgram: String, bundleId: String) -> ClaudeHost? {
        #if !APPSTORE
        return CmuxRouting.terminalHost(termProgram: termProgram, bundleId: bundleId)
        #else
        return ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId)
        #endif
    }

    /// Validates a coucou_agent name: lowercase, digits and hyphens, 1–24 chars.
    /// "claude" is reserved and rejected so it cannot impersonate the Claude Code pill.
    /// Returns the name unchanged if valid, nil otherwise.
    private static func validateAgent(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 24, raw != "claude" else { return nil }
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 0x61 && v <= 0x7A)  // a-z
                  || (v >= 0x30 && v <= 0x39)   // 0-9
                  || v == 0x2D                   // -
            guard ok else { return nil }
        }
        return raw
    }

    /// Creates a dynamic pill for a third-party agent on first event, then no-ops.
    /// ID format: "agent_<name>" — never collides with "integration_*" pills.
    /// Inserted right after integration_claude so it appears in the visible prefix(4).
    @MainActor
    private func upsertExternalAgent(id: String, name: String) {
        let state = AppState.shared
        guard state.tasks.firstIndex(where: { $0.id == id }) == nil else { return }
        let color: String
        if let def = PillCatalog.definition(for: id) {
            color = def.color
        } else {
            color = IslandConst.colorForProject(name)
        }
        let task = AgentTask(id: id, name: name, color: color, state: .idle, steps: [], source: .agent)
        if let claudeIdx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) {
            state.tasks.insert(task, at: claudeIdx + 1)
        } else {
            state.tasks.append(task)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }

    // MARK: - Helpers

    /// Whether a finish or an error opens the island. The pill shown always does; another pill
    /// does too with "Show alerts from every pill" (#683): it takes the focus for its card, and
    /// the pill that was shown comes back when the island closes. Never over an approval, a
    /// question, or a card the user is busy in (chat, mail, settings…).
    @MainActor
    private func showsAlert(for pill: String, focused: Bool) -> Bool {
        if focused { return true }
        let state = AppState.shared
        guard state.alertsFromAllPills, state.pendingApproval == nil, state.pendingQuestion == nil else { return false }
        if state.mode == .expanded, ![IslandView.overview, .finished, .error, .empty].contains(state.view) { return false }
        if focusBeforeAlert == nil { focusBeforeAlert = state.focusId }
        alertPill = pill
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pill }
        return true
    }

    /// The island closed: the pill that was shown before another pill's alert comes back.
    @MainActor
    func restoreAlertFocus() {
        guard let prev = focusBeforeAlert else { return }
        let borrowed = alertPill
        focusBeforeAlert = nil
        alertPill = nil
        let state = AppState.shared
        // Only if the alert's pill is still the one shown (the user may have picked another).
        guard state.pendingApproval == nil, state.focusId == borrowed, borrowed != prev,
              state.tasks.contains(where: { $0.id == prev }) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
    }

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .question, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Approval and question always win; other alerts are blocked while a card is showing
            if view == .approval || view == .question {
                state.view = view
            } else if isAlert && state.pendingApproval == nil {
                state.view = view
            }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Status line (plan gauge)

    @MainActor
    private func processStatusLine(payload: [String: Any]) {
        guard let usage = ClaudePlanGauge.parse(payload: payload) else { return }
        // Claude Code calls the status line several times a second: publish (and save to
        // UserDefaults) only when the numbers change, or every 30 s for "updated … ago".
        if let cur = AppState.shared.claudePlanUsage,
           cur.fiveHour == usage.fiveHour, cur.sevenDay == usage.sevenDay,
           usage.updatedAt.timeIntervalSince(cur.updatedAt) < 30 { return }
        AppState.shared.claudePlanUsage = usage
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any], arrivedAt: TimeInterval? = nil) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let projectName = sessionName(payload, cwd: cwd)

        let rawAgent = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))

        // Codex, Copilot CLI and Muse Code get the same approval card as Claude Code / Cursor.
        // Other external agents (any other coucou_agent) answer immediately with "ask"
        // so the agent re-asks in its own terminal — they do not get a notch card.
        #if !APPSTORE
        let isCodexRequest   = rawAgent == "codex"
        let isCopilotRequest = rawAgent == "copilot"
        let isMuseRequest    = rawAgent == "muse"
        // isHermesRequest is true only when the plugin sent coucou_has_transport: true,
        // meaning register_approval_transport is wired and Hermes will honour our choice.
        // Without that flag the request falls through to "ask" so Hermes handles it natively.
        let isHermesRequest  = rawAgent == "hermes"
            && UserDefaults.standard.bool(forKey: "hermesApprovalsEnabled")
            && (payload["coucou_has_transport"] as? Bool == true)
        #else
        let isCodexRequest   = false
        let isCopilotRequest = false
        let isMuseRequest    = false
        let isHermesRequest  = false
        #endif
        #if !APPSTORE
        let cmuxTaskId: String? = (isCodexRequest || isCopilotRequest || isMuseRequest || isHermesRequest
                                   || isCursorEditor || isVSCodeEditor)
            ? nil : cmuxRoutedTaskId(payload: payload)
        #else
        let cmuxTaskId: String? = nil
        #endif
        if !isCodexRequest && !isCopilotRequest && !isMuseRequest && !isHermesRequest && Self.validateAgent(rawAgent) != nil {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        // Determine which workspace pill owns the request.
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCopilotRequest {
            pillId = "agent_copilot"
        } else if isMuseRequest {
            pillId = "agent_muse"
        } else if isHermesRequest {
            pillId = "agent_hermes"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else if let id = cmuxTaskId {
            pillId = id
        } else {
            pillId = "integration_claude"
        }
        // Terminal sessions: only when turned on in Settings, else the terminal asks itself. A cmux session
        // is never a terminal session here: it belongs to the cmux pill (cmuxTaskId).
        let terminalHost = isCursorEditor || isVSCodeEditor || cmuxTaskId != nil ? nil
            : Self.terminalHost(termProgram: termProgram, bundleId: bundleId)
        let isTerminal = terminalHost != nil && ClaudeHost.terminalCardsEnabled
        guard isCodexRequest || isCopilotRequest || isMuseRequest || isHermesRequest || isCursorEditor || isVSCodeEditor || cmuxTaskId != nil || isTerminal else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let inputKey = Self.approvalInputKey(toolInput)
        nbLog("PermissionRequest \(tool) [\(pillId)]")

        // AskUserQuestion is now handled via the dedicated --ask PreToolUse hook.
        // If it still arrives here as a PermissionRequest, reply "ask" so Claude Code
        // re-asks in the terminal — never show the question twice.
        if tool == "AskUserQuestion" {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        // A plan is too long for the card: show its title.
        let command = tool == "ExitPlanMode"
            ? Self.planTitle(toolInput["plan"] as? String)
            : toolInput["command"] as? String ?? tool

        #if !APPSTORE
        // The request waits, in line or on screen. A card asking again (promoted, requeued) changes nothing.
        if cmuxTaskId != nil {
            // The row of a request names the tool by its own verb and shows the whole command up to the cut, white
            // space folded: nothing is guessed from the first word.
            let parts = stepParts(tool: tool, input: toolInput)
            let wording = parts.timelineDetail.map { "\(parts.plainVerb) · \($0)" } ?? parts.plainVerb
            timeline(.permission(key: timelineKey(tool: tool, input: toolInput), label: wording,
                                 outcome: .waiting, allowedWord: String(localized: "allowed")),
                     CmuxRouting.surfaceKey(payload: payload))
        }
        #endif

        // Read before a displaced or requeued card leaves the screen.
        let cardWasVisible = CardInputLock.cardVisible(approvalFD: liveApprovalFD, questionFD: liveQuestionFD,
                                                       approvalShown: state.pendingApproval != nil,
                                                       questionShown: state.pendingQuestion != nil)
        // A Hermes card on screen waits again, at the head of its line: nothing is sent to Hermes.
        HermesApprovalCenter.shared.requeueIfShowing()
        var displacedKey: String? = nil
        var cmuxKeyOfRequest: String? = nil
        #if !APPSTORE
        cmuxKeyOfRequest = cmuxTaskId == nil ? nil : CmuxRouting.surfaceKey(payload: payload)
        if cmuxTaskId != nil {
            if liveApprovalFD >= 0 || liveQuestionFD >= 0 {
                // A card is on screen: wait in line, the fd stays open and silent.
                guard cmuxQueue.canAccept(taskId: pillId, surfaceKey: cmuxKeyOfRequest) else {
                    // Queue full: answer like a terminal Coucou does not support. The dialog is open there.
                    markCmuxDialogOpen(cmuxKeyOfRequest, tool: tool, inputKey: inputKey)
                    Task.detached { [weak self] in
                        self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                        close(fd)
                    }
                    return
                }
                enqueueCmuxCard(kind: .approval, fd: fd, payload: payload, parsed: nil, taskId: pillId,
                                surfaceKey: cmuxKeyOfRequest ?? pillId,
                                sessionId: sessionId, tool: tool, inputKey: inputKey, arrivedAt: arrivedAt)
                return
            }
        } else {
            // A legacy request must not answer "ask" to a cmux card: send it back to the queue.
            requeueCmuxCardIfShowing()
        }
        displacedKey = cmuxShownKey
        cmuxShownPayload = cmuxTaskId != nil ? payload : nil
        cmuxShownArrival = arrivedAt ?? Date().timeIntervalSinceReferenceDate
        cmuxPromotedAt = nil   // presentNextCmuxCard sets it again when this card came out of the queue
        #endif

        // Every request but a cmux one queues here: several can wait at once (several sessions or agents),
        // the card shows the oldest. Past the cap, the newest goes back to its own terminal.
        // A session that shares its pill with another pops out into a pill of its own while
        // it waits (SessionBoard), so the request shows under its own title.
        if cmuxTaskId == nil {
            var entry = QueuedApproval(id: UUID(), fd: fd, sessionId: sessionId, pillId: pillId,
                                       projectName: projectName, cwd: cwd, tool: tool,
                                       command: command, inputKey: inputKey,
                                       hostApp: terminalHost?.bundleId, bundleId: bundleId)
            if approvals.count < ApprovalQueue.maxPending {
                entry.shownPill = popOutIfShared(pill: pillId, session: Self.boardKey(sessionId, pill: pillId, cwd: cwd),
                                                 raw: sessionId, title: projectName)
            }
            guard approvals.enqueue(entry) == .accepted else {
                nbLog("PermissionRequest \(tool): \(ApprovalQueue.maxPending) already waiting, asked in the terminal")
                Task.detached { [weak self] in
                    self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                    close(fd)
                }
                return
            }
            // The card changes only when this request takes the head of the line.
            if approvals.head?.id == entry.id {
                cardReplacedAt = CardInputLock.armedAt(cardWasVisible: cardWasVisible,
                                                       now: Date().timeIntervalSinceReferenceDate)
            }
            activeSessionId = sessionId

            upsertTask(pill: pillId,
                       display: PillSessionRegistry.Display(session: sessionId, projectName: projectName,
                                                            cwd: cwd, hostApp: terminalHost?.bundleId,
                                                            bundleId: bundleId),
                       working: true, externalAgent: nil)
            syncPill(pillId)
            SoundEngine.shared.play("approval")

            // Monitor fd: if the agent closes the connection (answered in its own UI), drop the
            // request. The cancel handler closes the fd — never close it anywhere else.
            let entryId = entry.id
            let capturedPillId = entry.displayPill
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, self.approvals.contains(id: entryId) else { return }
                self.removeApproval(id: entryId, note: self.handledNote(pill: capturedPillId))
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            approvalSources[entryId] = source

            // Safety timeout — drop without a decision. nb-hook reads EOF from the cancel
            // handler's close and exits; the agent asks again itself.
            // Copilot/Muse use 110s (their relay waits 118s but their hook timeout is 120s, leaving little margin).
            let waitTimeout: Double = (isCopilotRequest || isMuseRequest) ? 110 : 115
            DispatchQueue.main.asyncAfter(deadline: .now() + waitTimeout) { [weak self] in
                guard let self, self.approvals.contains(id: entryId) else { return }
                self.removeApproval(id: entryId, note: self.waitingNote(pill: capturedPillId))
            }

            showApprovalHead()
            return
        }

        // A cmux request: it owns the card slot with its own connection, source and generation.
        cardReplacedAt = CardInputLock.armedAt(cardWasVisible: cardWasVisible, now: Date().timeIntervalSinceReferenceDate)

        if pendingApprovalFD >= 0 {
            // Displace the previous request: write "ask" then cancel its source.
            // The cancel handler closes the old fd — never close it directly.
            let old = pendingApprovalFD
            let oldSource = approvalFDSource
            approvalFDSource = nil
            #if !APPSTORE
            if let p = state.pendingApproval { markCmuxDialogOpen(displacedKey, tool: p.tool, inputKey: p.inputKey) }
            #endif
            Task.detached { [weak self] in
                // "ask" → nb-hook outputs nothing → Claude Code re-asks
                self?.sendLine(fd: old, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { oldSource?.cancel() }
            }
        }
        pendingApprovalFD = fd
        cardGeneration += 1
        let gen = cardGeneration
        activeSessionId = sessionId

        upsertWorkspaceTask(id: pillId, projectName: projectName, cwd: cwd, cmuxKey: cmuxKeyOfRequest, hostApp: terminalHost?.bundleId, bundleId: bundleId)
        setTaskState(pillId, .approval, cmuxKey: cmuxKeyOfRequest)
        state.pendingApproval = ApprovalInfo(sessionId: sessionId, tool: tool,
                                              command: command, inputKey: inputKey, pillId: pillId)
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond.
        // Save current focus so we can restore it when the card is dismissed.
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .approval)

        // Monitor fd: if the editor closes the connection (handled externally), dismiss the card.
        // The cancel handler closes the fd — never close it anywhere else.
        let capturedPillId = pillId
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingApprovalFD == fd else { return }
            var note = self.handledNote(pill: capturedPillId)
            // A cmux card that reads EOF while still young was answered in the terminal: no dialog is left.
            var answeredInTerminal = false
            #if !APPSTORE
            if CmuxRouting.isCmuxTaskId(capturedPillId) {
                // A card promoted late was closed by the hook's own timeout: nobody handled it.
                if CmuxRouting.isLateCard(arrivedAt: self.cmuxShownArrival, now: Date().timeIntervalSinceReferenceDate) {
                    note = String(localized: "Still waiting in cmux.")
                }
                answeredInTerminal = !CmuxRouting.eofLeavesDialogOpen(
                    arrivedAt: self.cmuxShownArrival, now: Date().timeIntervalSinceReferenceDate)
            }
            #endif
            self.dismissApprovalCard(note: note, resolved: answeredInTerminal)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        approvalFDSource = source

        // Safety timeout — show a note and cancel without sending a decision.
        // nb-hook reads EOF from the cancel handler's close and exits; Claude Code / Codex re-asks.
        // Copilot/Muse use 110s (their relay waits 118s but their hook timeout is 120s, leaving little margin).
        let waitTimeout: Double = (isCopilotRequest || isMuseRequest) ? 110 : 115
        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + waitTimeout) { [weak self] in
            guard let self, self.pendingApprovalFD == captured, self.cardGeneration == gen else { return }
            self.dismissApprovalCard(note: self.waitingNote(pill: capturedPillId))
        }
    }

    /// Called by ApprovalView buttons and the iPhone. Writes the decision to the waiting
    /// nb-hook of request `id` — the one that was on screen. A click that lands after the
    /// card moved on to another request is ignored, so it can never answer the wrong one.
    @MainActor
    func sendApprovalDecision(_ decision: String, for id: UUID? = nil) {
        // Only intercept a demo card — a real card has a live connection behind it.
        if DemoEngine.shared.isActive,
           AppState.shared.pendingApproval?.sessionId == "demo_session",
           liveApprovalFD < 0 {
            let s = AppState.shared
            s.pendingApproval = nil
            if DemoGuard.mayChangeView(DemoEngine.shared.realPending) {
                s.isPinned = false
                s.view = s.tasks.isEmpty ? .empty : .overview
            }
            DemoEngine.shared.handleApprovalDecision(decision)
            return
        }
        // A Hermes request has its own card and its own answers (`sendHermesDecision`): nothing here, the iPhone included.
        if HermesPills.isTaskId(AppState.shared.pendingApproval?.pillId) { return }
        if cardReplacedLocked() { return }
        #if !APPSTORE
        if cmuxInputLocked() { return }
        #endif
        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        // Plan approval (ExitPlanMode): the hook turns "mode" into a setMode permission update.
        case "plan_auto":    json = #"{"permissionDecision":"allow","mode":"auto"}"#
        case "plan_default": json = #"{"permissionDecision":"allow","mode":"default"}"#
        // Reject the plan and stop Claude, so the change can be typed in the terminal.
        case "plan_change":  json = #"{"permissionDecision":"change_plan"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }
        // The recap only counts allow / always / deny.
        let recapDecision = ["plan_auto": "allow", "plan_default": "allow", "plan_change": "deny"][decision] ?? decision

        // The cmux card holds the slot with its own connection.
        if pendingApprovalFD >= 0 {
            if let id, id != AppState.shared.pendingApproval?.id {
                nbLog("Approval decision for a request no longer on the card, ignored")
                return
            }
            var cardKey: String? = nil
            #if !APPSTORE
            cardKey = cmuxShownKey
            cmuxShownPayload = nil
            #endif
            let fd = pendingApprovalFD
            pendingApprovalFD = -1
            // Capture source before nulling — we send the decision first, then cancel the source.
            // The cancel handler closes the fd; never close it directly.
            let source = approvalFDSource
            approvalFDSource = nil

            #if !APPSTORE
            // "ask" hands the request to the terminal (marked below); the other answers settle the row.
            if decision != "ask", let p = AppState.shared.pendingApproval {
                timeline(.permission(key: TimelineNames.pairingKey(tool: p.tool, inputKey: p.inputKey), label: p.command,
                                     outcome: decision == "allow" || decision == "always" ? .allowed : .denied,
                                     allowedWord: String(localized: "allowed")), cardKey)
            }
            #endif

            Task.detached { [weak self] in
                // Write decision while fd is still valid, then cancel source → cancel handler closes fd
                self?.sendLine(fd: fd, text: json)
                DispatchQueue.main.async { source?.cancel() }
            }

            let state = AppState.shared
            let pillId = state.pendingApproval?.pillId ?? "integration_claude"
            #if !APPSTORE
            // "ask" hands the request back to the terminal: its dialog is open there.
            if decision == "ask", let p = state.pendingApproval {
                markCmuxDialogOpen(cardKey, tool: p.tool, inputKey: p.inputKey)
            }
            #endif
            state.pendingApproval = nil
            state.isPinned = false
            RecapStore.shared.recordDecision(pillId: pillId, decision: recapDecision)
            setTaskState(pillId, .working, cmuxKey: cardKey)
            clearPillBadgeUnlessCardHeld(id: pillId)
            // Restore focus to the pill that was focused before the approval card appeared.
            if let prev = focusBeforeApproval {
                focusBeforeApproval = nil
                if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
                }
            }
            #if !APPSTORE
            if presentNextCmuxCard() { return }
            #endif
            if HermesApprovalCenter.shared.presentNextIfFree() { return }
            state.view = state.tasks.isEmpty ? .empty : .overview
            return
        }

        guard let head = approvals.head else {
            // A card with nothing behind it any more: just close it.
            let s = AppState.shared
            s.pendingApproval = nil
            s.isPinned = false
            s.view = s.tasks.isEmpty ? .empty : .overview
            return
        }
        if let id, id != head.id {
            nbLog("Approval decision for a request no longer on the card, ignored")
            return
        }
        RecapStore.shared.recordDecision(pillId: head.pillId, decision: recapDecision)
        removeApproval(id: head.id, answer: json)
        if decision == "plan_change" { ClaudeHost.activate(head.hostApp) }
    }

    /// The plan's first non-empty line without its Markdown heading marks, for the card.
    static func planTitle(_ plan: String?) -> String {
        let firstLine = plan?.split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let title = firstLine.map { String($0.drop { $0 == "#" || $0 == " " }) } ?? ""
        return title.isEmpty ? "Plan" : title
    }

    // MARK: - Question request

    @MainActor
    private func processQuestionRequest(fd: Int32, parsed: AskQuestion, payload: [String: Any], arrivedAt: TimeInterval? = nil) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
                     ?? payload["conversation_id"] as? String
                     ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let projectName = sessionName(payload, cwd: cwd)

        let rawAgent    = payload["coucou_agent"] as? String ?? ""
        let termProgram = payload["term_program"]  as? String ?? ""
        let bundleId    = payload["bundle_id"]     as? String ?? ""
        let isCursorEditor = bundleId.lowercased() == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (
            termProgram.lowercased().contains("vscode") ||
            bundleId.lowercased().contains("vscode"))
        #if !APPSTORE
        let isCodexRequest = rawAgent == "codex"
        #else
        let isCodexRequest = false
        #endif
        #if !APPSTORE
        let cmuxTaskId: String? = (isCodexRequest || isCursorEditor || isVSCodeEditor || Self.validateAgent(rawAgent) != nil)
            ? nil : cmuxRoutedTaskId(payload: payload)
        #else
        let cmuxTaskId: String? = nil
        #endif
        let pillId: String
        if isCodexRequest {
            pillId = "agent_codex"
        } else if isCursorEditor {
            pillId = "agent_cursor"
        } else if let id = cmuxTaskId {
            pillId = id
        } else {
            pillId = "integration_claude"
        }
        // Terminal sessions: only when turned on in Settings, else the terminal asks itself. A cmux session
        // is never a terminal session here: it belongs to the cmux pill (cmuxTaskId).
        let terminalHost = isCursorEditor || isVSCodeEditor || cmuxTaskId != nil ? nil
            : Self.terminalHost(termProgram: termProgram, bundleId: bundleId)
        let isTerminal = terminalHost != nil && ClaudeHost.terminalCardsEnabled
        guard isCodexRequest || isCursorEditor || isVSCodeEditor || cmuxTaskId != nil || isTerminal else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        #if !APPSTORE
        // The question waits, in line or on screen: its first question and how many more the card holds.
        if cmuxTaskId != nil, let first = parsed.questions.first {
            timeline(.question(text: first.question, more: parsed.questions.count - 1, outcome: .waiting),
                     CmuxRouting.surfaceKey(payload: payload))
        }
        #endif

        // Read before a displaced or requeued card leaves the screen.
        let cardWasVisible = CardInputLock.cardVisible(approvalFD: liveApprovalFD, questionFD: liveQuestionFD,
                                                       approvalShown: state.pendingApproval != nil,
                                                       questionShown: state.pendingQuestion != nil)
        // A Hermes card on screen waits again, at the head of its line: nothing is sent to Hermes.
        HermesApprovalCenter.shared.requeueIfShowing()
        var cmuxKeyOfRequest: String? = nil
        #if !APPSTORE
        cmuxKeyOfRequest = cmuxTaskId == nil ? nil : CmuxRouting.surfaceKey(payload: payload)
        if cmuxTaskId != nil {
            if liveApprovalFD >= 0 || liveQuestionFD >= 0 {
                guard cmuxQueue.canAccept(taskId: pillId, surfaceKey: cmuxKeyOfRequest) else {
                    markCmuxDialogOpen(cmuxKeyOfRequest, tool: "AskUserQuestion", inputKey: nil)
                    Task.detached { [weak self] in
                        self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                        close(fd)
                    }
                    return
                }
                let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
                enqueueCmuxCard(kind: .question, fd: fd, payload: payload, parsed: parsed, taskId: pillId,
                                surfaceKey: cmuxKeyOfRequest ?? pillId,
                                sessionId: sessionId, tool: "AskUserQuestion",
                                inputKey: Self.approvalInputKey(toolInput), arrivedAt: arrivedAt)
                return
            }
        } else {
            // A legacy question must not answer "ask" to a cmux card: send it back to the queue.
            requeueCmuxCardIfShowing()
        }
        cmuxShownPayload = cmuxTaskId != nil ? payload : nil
        cmuxShownArrival = arrivedAt ?? Date().timeIntervalSinceReferenceDate
        cmuxPromotedAt = nil   // presentNextCmuxCard sets it again when this card came out of the queue
        #endif

        // Every question but a cmux one queues here: several sessions can wait on a question at once, the card
        // shows the oldest, and each answer goes back to the session that asked. A session asking again
        // replaces its own older question; past the cap, the newest goes back to its terminal.
        // A session that shares its pill with another pops out into a pill of its own while
        // it waits (SessionBoard), so the question shows under its own title.
        if cmuxTaskId == nil {
            let key = Self.boardKey(sessionId, pill: pillId, cwd: cwd)
            var entry = QueuedQuestion(id: UUID(), fd: fd, sessionId: key,
                                       pillId: pillId, projectName: projectName, cwd: cwd, question: parsed)
            if questions.count < QuestionQueue.maxPending
                || questions.entries.contains(where: { $0.sessionId == key && $0.pillId == pillId }) {
                entry.shownPill = popOutIfShared(pill: pillId, session: key, raw: sessionId, title: projectName)
            }
            switch questions.enqueue(entry) {
            case .rejectedFull:
                nbLog("Question: \(QuestionQueue.maxPending) already waiting, asked in the terminal")
                Task.detached { [weak self] in
                    self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                    close(fd)
                }
                return
            case .accepted(let replaced?):
                let oldSource = questionSources.removeValue(forKey: replaced.id)
                let oldFD = replaced.fd
                Task.detached { [weak self] in
                    self?.sendLine(fd: oldFD, text: #"{"permissionDecision":"ask"}"#)
                    DispatchQueue.main.async { oldSource?.cancel() }
                }
            case .accepted(nil):
                break
            }
            // The card changes only when this question takes the head of the line.
            if questions.head?.id == entry.id {
                cardReplacedAt = CardInputLock.armedAt(cardWasVisible: cardWasVisible,
                                                       now: Date().timeIntervalSinceReferenceDate)
            }
            activeSessionId = sessionId

            upsertTask(pill: pillId,
                       display: PillSessionRegistry.Display(session: sessionId, projectName: projectName,
                                                            cwd: cwd, hostApp: terminalHost?.bundleId,
                                                            bundleId: bundleId),
                       working: true, externalAgent: nil)
            syncPill(pillId)
            SoundEngine.shared.play("approval")

            // Monitor fd: if the agent closes the connection (stopped or answered in its own UI),
            // drop the question. The cancel handler closes the fd — never close it anywhere else.
            let entryId = entry.id
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, self.questions.contains(id: entryId) else { return }
                self.removeQuestion(id: entryId)
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            questionSources[entryId] = source

            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, self.questions.contains(id: entryId) else { return }
                // Send "ask" so nb-hook exits cleanly; Claude Code re-asks in terminal.
                self.removeQuestion(id: entryId, answer: #"{"permissionDecision":"ask"}"#)
            }

            showQuestionHead()
            return
        }

        // A cmux question: it owns the card slot with its own connection, source and generation.
        cardReplacedAt = CardInputLock.armedAt(cardWasVisible: cardWasVisible, now: Date().timeIntervalSinceReferenceDate)
        pendingQuestionFD = fd
        cardGeneration += 1
        let gen = cardGeneration
        activeSessionId = sessionId
        questionPillId = pillId
        questionSessionId = (sessionId == "unknown" || sessionId.isEmpty)
            ? "\(pillId)+\(cwd)"
            : sessionId

        upsertTask(pill: pillId,
                   display: PillSessionRegistry.Display(session: sessionId, projectName: projectName,
                                                        cwd: cwd, hostApp: terminalHost?.bundleId,
                                                        bundleId: bundleId),
                   working: true, externalAgent: nil, cmuxKey: cmuxKeyOfRequest)
        setTaskState(pillId, .question, cmuxKey: cmuxKeyOfRequest)
        state.pendingQuestion = parsed
        // The iPhone and the Android link read the lane's question next to the queue's (cleared with pendingQuestion).
        state.cmuxLaneQuestion = QueuedQuestion(id: UUID(), fd: -1, sessionId: questionSessionId, pillId: pillId,
                                                projectName: projectName, cwd: cwd, question: parsed)
        state.isPinned = true
        SoundEngine.shared.play("approval")

        if focusBeforeQuestion == nil { focusBeforeQuestion = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .question)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, self.pendingQuestionFD == fd else { return }
            var leftOpen = true
            #if !APPSTORE
            leftOpen = CmuxRouting.eofLeavesDialogOpen(arrivedAt: self.cmuxShownArrival,
                                                       now: Date().timeIntervalSinceReferenceDate)
            #endif
            self.dismissQuestionCard(note: "", leftOpen: leftOpen)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        questionFDSource = source

        let captured = fd
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self, self.pendingQuestionFD == captured, self.cardGeneration == gen else { return }
            // Send "ask" so nb-hook exits cleanly; Claude Code re-asks in terminal.
            let askFD = self.pendingQuestionFD
            self.pendingQuestionFD = -1
            let src = self.questionFDSource
            self.questionFDSource = nil
            Task.detached { [weak self] in
                self?.sendLine(fd: askFD, text: #"{"permissionDecision":"ask"}"#)
                DispatchQueue.main.async { src?.cancel() }
            }
            self.dismissQuestionCard(note: "", leftOpen: true)
        }
    }

    /// "VS Code", "Warp"… — where the session behind a Claude Code pill runs.
    @MainActor
    private func claudeHostName(pill: String) -> String {
        ClaudeHost.name(for: AppState.shared.tasks.first { $0.id == pill }?.hostApp)
    }

    /// Records the session an event came from, then refreshes its card.
    /// `externalAgent` is the validated `coucou_agent` name for a third-party agent pill,
    /// nil for a workspace pill.
    @MainActor
    private func upsertTask(pill: String, display: PillSessionRegistry.Display,
                            working: Bool, externalAgent: String?, cmuxKey: String? = nil) {
        // A cmux pill holds its own sessions (one per surface): the registry stays out of it.
        if cmuxKey == nil { sessions.note(pill: pill, display: display, working: working) }
        if let externalAgent {
            upsertExternalAgent(id: pill, name: externalAgent)
        } else {
            upsertWorkspaceTask(id: pill, projectName: display.projectName, cwd: display.cwd, cmuxKey: cmuxKey,
                                hostApp: display.hostApp, bundleId: display.bundleId,
                                session: display.session)
        }
    }

    /// Updates or transiently creates a workspace pill (VS Code or Cursor) task, or a session's
    /// own pill. If the task already exists (persistent), just updates name/cwd.
    /// If missing (transient), creates it and inserts after the main pill (a session's own
    /// pill: after its client's).
    /// Name, cwd and terminal belong to the session that owns the pill (the oldest one
    /// still running), so a second session under the same client cannot rename the card,
    /// or send "Open terminal" elsewhere, out from under the first.
    @MainActor
    private func upsertWorkspaceTask(id: String, projectName: String, cwd: String = "", cmuxKey: String? = nil, hostApp: String? = nil, bundleId: String = "", session: String = "") {
        #if !APPSTORE
        if CmuxRouting.isCmuxTaskId(id) { upsertCmuxTask(id: id, projectName: projectName, cwd: cwd, key: cmuxKey); return }
        #endif
        let state = AppState.shared
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            guard sessions.ownsDisplay(pill: id, session: session) else { return }
            state.tasks[idx].name = projectName
            if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
            if PillCatalog.basePillId(id) == "integration_claude" { state.tasks[idx].hostApp = hostApp }
            if !bundleId.isEmpty { state.tasks[idx].sessionBundleId = bundleId }
            return
        }
        // Transient: create and insert after the main pill
        let def = PillCatalog.definition(for: id)
        let color = def?.color ?? "#C0C4CC"
        let source = def?.source ?? .agent
        var task = AgentTask(id: id, name: projectName, color: color,
                             state: .idle, steps: [], source: source, isIntegration: true)
        if task.pill == "integration_claude" { task.hostApp = hostApp }
        if !bundleId.isEmpty { task.sessionBundleId = bundleId }
        // A session's own pill goes after its client's other pills, so they stay together.
        if let sibling = state.tasks.lastIndex(where: { $0.pill == task.pill }) {
            state.tasks.insert(task, at: sibling + 1)
        } else if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.insert(task, at: 0)
        }
        if state.focusId == nil { state.focusId = id }
        state.syncMode()
    }


    // MARK: - cmux (GitHub build only)

    #if !APPSTORE

    /// Surface data of the pill's main surface. Contains the capability: never log or persist it.
    @MainActor
    func cmuxSurface(for taskId: String) -> CmuxSurface? { cmuxRegistry.surface(for: taskId) }

    /// Surface data of one surface (by key).
    @MainActor
    func cmuxSurface(key: String) -> CmuxSurface? { cmuxRegistry.surface(key: key) }

    @MainActor
    func cmuxCredential(for taskId: String?, hasPassword: Bool) -> CmuxCredential {
        cmuxRegistry.credential(for: taskId, hasPassword: hasPassword)
    }

    /// Token for typing into a surface: its own, else the freshest on the same socket. Never the password.
    @MainActor
    func cmuxSendCredential(forKey key: String) -> CmuxCredential { cmuxRegistry.sendCredential(forKey: key) }

    /// Token for bringing a surface to the front (nothing is typed): its own, else one on the same socket.
    @MainActor
    func cmuxJumpCredential(forKey key: String) -> CmuxCredential { cmuxRegistry.jumpCredential(forKey: key) }

    /// True when Coucou has proof that the surface runs an agent session: a hook event with a valid token for that
    /// very surface (see `CmuxSurface.canType`). A surface known only through discovery or the session file is a
    /// pill with Send off until its session reports in.
    @MainActor
    func cmuxCanType(key: String) -> Bool { cmuxRegistry.surface(key: key)?.canType == true }

    /// The pill of a cmux event: the pill of its surface's registry entry when it has one (one source of truth,
    /// whatever workspace the payload names), else the workspace of the payload.
    @MainActor
    private func cmuxRoutedTaskId(payload: [String: Any]) -> String? {
        guard let id = CmuxRouting.taskId(payload: payload) else { return nil }
        if let key = CmuxRouting.surfaceKey(payload: payload), let own = cmuxRegistry.pillId(forKey: key) { return own }
        return id
    }

    /// The pill that owns the question card on screen, nil without one.
    @MainActor
    var cmuxQuestionPillId: String? {
        pendingQuestionFD >= 0 && AppState.shared.pendingQuestion != nil && !questionPillId.isEmpty ? questionPillId : nil
    }

    /// True when the approval or question card on screen belongs to this pill.
    @MainActor
    private func cmuxCardOnScreen(forPill taskId: String) -> Bool {
        if pendingApprovalFD >= 0, AppState.shared.pendingApproval?.pillId == taskId { return true }
        if pendingQuestionFD >= 0, questionPillId == taskId { return true }
        return false
    }

    /// Agent sessions across every pill (the hub says "N sessions").
    @MainActor
    var cmuxSessionCount: Int { cmuxRegistry.surfaces.count }

    /// Where a reply to the pill goes: the surface the user picked (while it lives), else the main one.
    @MainActor
    func cmuxReplyTarget(for taskId: String) -> String? {
        if let choice = AppState.shared.cmuxReplyChoice[taskId],
           let s = cmuxRegistry.surface(key: choice), s.taskId == taskId { return choice }
        return cmuxRegistry.surface(for: taskId)?.key
    }

    /// The session whose answer is the final line of the pill (the one a Reply from the card should open), while it
    /// lives and while the pill still shows that answer (a later prompt clears the line, not the remembered key).
    @MainActor
    func cmuxFinalSurface(for taskId: String) -> String? {
        let shown = AppState.shared.tasks.first { $0.id == taskId }?.finalLine?.isEmpty == false
        guard let key = PromptSlot.cardSurface(finalLineKey: cmuxFinalLineKey[taskId], finalLineShown: shown),
              cmuxRegistry.surface(key: key)?.taskId == taskId else { return nil }
        return key
    }

    /// The main session of the pill.
    @MainActor
    func cmuxMainSurface(for taskId: String) -> String? { cmuxRegistry.surface(for: taskId)?.key }

    /// The user picked a surface in the reply header. Remembered until that surface closes.
    @MainActor
    func setCmuxReplyChoice(_ key: String, for taskId: String) {
        guard let s = cmuxRegistry.surface(key: key), s.taskId == taskId else { return }
        let state = AppState.shared
        state.cmuxReplyChoice[taskId] = key
        state.cmuxNotice = nil
    }

    /// Label, key and role of the agent surfaces of a pill, the main one first.
    @MainActor
    func cmuxSurfaces(for taskId: String) -> [CmuxSurfaceInfo] {
        let list = cmuxRegistry.surfaces(ofTask: taskId)
        let labels = CmuxRouting.surfaceLabels(titles: list.map { $0.title }, fallback: String(localized: "Session"))
        let main = cmuxRegistry.surface(for: taskId)?.key
        return zip(list, labels).map { CmuxSurfaceInfo(key: $0.key, label: $1, isMain: $0.key == main) }
    }

    /// Surface of the card on screen, else the first queued one, for this pill. nil without a card.
    @MainActor
    private func cmuxCardSurfaceKey(for taskId: String) -> String? {
        if pendingApprovalFD >= 0, AppState.shared.pendingApproval?.pillId == taskId, let k = cmuxShownKey { return k }
        if pendingQuestionFD >= 0, questionPillId == taskId, let k = cmuxShownKey { return k }
        return cmuxQueue.cards.first { $0.taskId == taskId }?.surfaceKey
    }

    /// Where Jump goes: the surface of the card on screen or queued for the pill, else the surface whose
    /// state is the folded one, else the reply target.
    @MainActor
    func cmuxJumpTarget(for taskId: String) -> CmuxSurface? {
        if let key = cmuxCardSurfaceKey(for: taskId), let s = cmuxRegistry.surface(key: key), s.taskId == taskId { return s }
        if let fold = cmuxRegistry.foldedState(ofTask: taskId), fold != "idle",
           let s = cmuxRegistry.surfaces(ofTask: taskId).first(where: { $0.state == fold }) { return s }
        return cmuxReplyTarget(for: taskId).flatMap { cmuxRegistry.surface(key: $0) }
    }

    /// Name of the session the card on screen belongs to, when its workspace has several. nil otherwise.
    @MainActor
    var cmuxCardOrigin: String? {
        guard let key = cmuxShownKey, let s = cmuxRegistry.surface(key: key) else { return nil }
        let list = cmuxSurfaces(for: s.taskId)
        guard list.count > 1 else { return nil }
        return list.first { $0.key == key }?.label
    }

    /// True while a dialog Coucou gave back to the terminal (or a session Coucou never heard from) may still
    /// be open for this surface.
    @MainActor
    func cmuxDialogMayBeOpen(key: String) -> Bool { cmuxOpenDialogs[key] != nil }

    /// The "Answered" click of the reply view: the user says the request is gone. Explicit action only.
    @MainActor
    func clearCmuxDialogMark(key: String) { cmuxOpenDialogs[key] = nil }

    /// The one gate for typing into a surface: proof that it runs an agent session (it reported in with a token),
    /// no card of its own, no dialog that may be open, not in approval or question. Evaluated per target
    /// surface: a card of another session does not block it.
    @MainActor
    func cmuxCanSend(key: String) -> Bool {
        guard let s = cmuxRegistry.surface(key: key), s.canType else { return false }
        return CmuxRouting.canSend(state: s.state,
                                   holdsCard: cmuxSurfaceHoldsCard(key),
                                   dialogMayBeOpen: cmuxOpenDialogs[key] != nil)
    }

    @MainActor
    private func markCmuxDialogOpen(_ key: String?, tool: String, inputKey: String?) {
        guard let key else { return }
        cmuxOpenDialogs[key] = CmuxRouting.DialogMark(tool: tool, inputKey: inputKey)
        // Every request handed back to the terminal passes here: its row says it waits there.
        if tool == "AskUserQuestion" {
            timeline(.question(text: "", more: 0, outcome: .inTerminal), key)
        } else if let inputKey {
            timeline(.permission(key: TimelineNames.pairingKey(tool: tool, inputKey: inputKey), label: tool,
                                 outcome: .inTerminal, allowedWord: String(localized: "allowed")), key)
        }
    }

    @MainActor
    private func markCmuxDialogOpen(from held: CmuxHeld) {
        if held.parsed != nil {
            markCmuxDialogOpen(held.surfaceKey, tool: "AskUserQuestion", inputKey: nil)
        } else {
            markCmuxDialogOpen(held.surfaceKey, tool: held.payload["tool_name"] as? String ?? "Tool",
                               inputKey: Self.approvalInputKey(held.payload["tool_input"] as? [String: Any] ?? [:]))
        }
    }

    /// Surface key of the cmux card on screen.
    @MainActor
    private var cmuxShownKey: String? {
        cmuxShownPayload.flatMap { CmuxRouting.surfaceKey(payload: $0) }
    }

    /// Remembers a "New chat" until the SessionStart of its surface arrives, or 90 s pass.
    /// Memory only. An expired launch sends nothing; the draft goes back to the field.
    @MainActor
    func setCmuxPendingLaunch(_ launch: CmuxPendingLaunch) {
        cmuxPendingLaunch = launch
        cmuxLaunchGeneration += 1
        let generation = cmuxLaunchGeneration
        let state = AppState.shared
        state.cmuxNotice = String(localized: "Starting claude…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.cmuxLaunchGeneration == generation, self.cmuxPendingLaunch != nil else { return }
            AppState.shared.cmuxNotice = String(localized: "Waiting for claude. It may be asking to trust the folder.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CmuxRouting.launchTimeout) { [weak self] in
            guard let self, self.cmuxLaunchGeneration == generation, let pending = self.cmuxPendingLaunch else { return }
            self.cmuxPendingLaunch = nil
            let state = AppState.shared
            state.cmuxNotice = String(localized: "claude did not start in time.")
            state.restoreDraft(pending.prompt, for: .cmuxNewChat, endsLaunch: true, stashIfReplaced: true)
        }
    }

    @MainActor
    var cmuxPendingLaunch: CmuxPendingLaunch? = nil

    /// Refreshes the registry from every event of a cmux session (the token may rotate).
    /// The cmux fields are validated as one unit; when one fails the whole context is dropped.
    @MainActor
    private func noteCmuxContext(payload: [String: Any], token: String) {
        guard let id = cmuxRoutedTaskId(payload: payload), let key = CmuxRouting.surfaceKey(payload: payload) else { return }
        let rawAgent = payload["coucou_agent"] as? String ?? ""
        guard Self.validateAgent(rawAgent) == nil else { return }
        let bundleId = (payload["bundle_id"] as? String ?? "").lowercased()
        let termProgram = (payload["term_program"] as? String ?? "").lowercased()
        let isCursorEditor = bundleId == "com.todesktop.230313mzl4w4u92"
        let isVSCodeEditor = !isCursorEditor && (termProgram.contains("vscode") || bundleId.contains("vscode"))
        guard !isCursorEditor, !isVSCodeEditor else { return }

        let event = payload["coucou_kind"] as? String == "ask_user_question"
            ? "AskUserQuestion" : (payload["hook_event_name"] as? String ?? "")
        let taskIsLive = AppState.shared.tasks.contains { $0.id == id }
        guard CmuxRouting.mayRegister(event: event, taskIsLive: taskIsLive) else { return }
        // The surface speaks again: a discovery may see it (a SessionEnd sets this again right after).
        cmuxEndedAt[key] = nil

        let surfaceId = payload["cmux_surface_id"] as? String ?? ""
        let workspaceId = payload["cmux_workspace_id"] as? String ?? ""
        let socketPath = payload["cmux_socket_path"] as? String ?? ""
        let valid = CmuxRouting.isValidContext(surfaceId: surfaceId, workspaceId: workspaceId,
                                               socketPath: socketPath, capability: token)
        var hadToken = false
        if case .token = cmuxRegistry.credential(for: nil, hasPassword: false) { hadToken = true }
        let accepted = cmuxRegistry.note(taskId: id, key: key,
                          surfaceId: valid ? surfaceId : "",
                          workspaceId: valid ? workspaceId : "",
                          socketPath: valid ? socketPath : "",
                          capability: valid ? token : "",
                          sessionId: payload["session_id"] as? String ?? payload["conversation_id"] as? String ?? "",
                          now: Date().timeIntervalSinceReferenceDate)
        if !accepted, cmuxRefusedLogged.insert(id).inserted {
            // One line per task, no id, path or token.
            nbLog("cmux: a session reported another socket path, kept the stored one")
        }
        // The first usable token, or a session never heard before: the workspaces may be unknown to us.
        var hasToken = false
        if case .token = cmuxRegistry.credential(for: nil, hasPassword: false) { hasToken = true }
        if cmuxRegistry.lastNoteCreated { AppState.shared.cmuxRevision &+= 1 }
        if (hasToken && !hadToken) || cmuxRegistry.lastNoteCreated { requestCmuxDiscovery() }
    }

    /// cmux cards wait for the card slot.
    @MainActor
    var hasQueuedCmuxCards: Bool { !cmuxQueue.cards.isEmpty }

    /// True when the pill has a queued card or owns the card on screen.
    @MainActor
    private func cmuxTaskHoldsCard(_ taskId: String) -> Bool {
        if cmuxQueue.hasCards(for: taskId) { return true }
        if pendingApprovalFD >= 0, AppState.shared.pendingApproval?.pillId == taskId { return true }
        if pendingQuestionFD >= 0, questionPillId == taskId { return true }
        return false
    }

    /// True when the surface has a queued card or owns the card on screen.
    @MainActor
    func cmuxSurfaceHoldsCard(_ key: String) -> Bool {
        if cmuxQueue.hasCards(forSurface: key) { return true }
        if pendingApprovalFD >= 0 || pendingQuestionFD >= 0, cmuxShownKey == key { return true }
        return false
    }

    /// Records the state of a surface and writes the pill's folded state (written only when it changes).
    /// A surface without a registry entry (past the cap, or just gone) has no state of its own and never
    /// writes the pill's.
    @MainActor
    private func setCmuxSurfaceState(taskId: String, key: String, _ newState: BotState) {
        guard cmuxRegistry.surface(key: key) != nil else { return }
        cmuxRegistry.setState(key: key, newState.rawValue)
        CmuxTimelines.shared.setLive(key, newState)
        refoldCmuxTask(taskId)
    }

    /// Pill state = fold of its surfaces' states. The badge goes when the fold is idle.
    @MainActor
    private func refoldCmuxTask(_ taskId: String) {
        let state = AppState.shared
        guard let raw = cmuxRegistry.foldedState(ofTask: taskId), let fold = BotState(rawValue: raw),
              let idx = state.tasks.firstIndex(where: { $0.id == taskId }) else { return }
        if state.tasks[idx].state != fold { state.tasks[idx].state = fold }
        if fold == .idle, state.tasks[idx].pillBadge != nil { state.tasks[idx].pillBadge = nil }
    }

    /// 5 s after a Stop: a surface still `finished` goes idle, and the pill with it when nothing else shows
    /// a state. A surface that moved on meanwhile (a new prompt) keeps its state.
    @MainActor
    private func settleFinishedCmuxSurface(taskId: String, key: String) {
        guard !cmuxSurfaceHoldsCard(key), let s = cmuxRegistry.surface(key: key),
              s.state == BotState.finished.rawValue else { return }
        setCmuxSurfaceState(taskId: taskId, key: key, .idle)
    }

    /// The step prefix of a session that is not the main one of a workspace with several: `<label> · `.
    @MainActor
    private func cmuxStepPrefix(forKey key: String) -> String {
        guard let s = cmuxRegistry.surface(key: key) else { return "" }
        let list = cmuxSurfaces(for: s.taskId)
        guard list.count > 1, let me = list.first(where: { $0.key == key }), !me.isMain else { return "" }
        return me.label + " · "
    }

    /// Drops the registry entries not seen for 30 minutes, whatever their state, except the protected ones. An
    /// entry whose process the last discovery found alive in the cmux session file is never subject (an idle
    /// workspace stays); one whose process is gone is, so a session that died without a SessionEnd does not stay
    /// an agent for as long as its terminal tab exists (see `CmuxRouting.timeRuleApplies`).
    @MainActor
    private func pruneStaleCmux() {
        let state = AppState.shared
        let protected = CmuxRouting.pruneProtected(
            holdingCard: Set(cmuxRegistry.taskIds.filter { cmuxTaskHoldsCard($0) }),
            openReplyTask: openCmuxReplyTask())
        let busy = Set(state.tasks.filter {
            CmuxRouting.isCmuxTaskId($0.id) && [.working, .thinking, .searching].contains($0.state)
        }.map { $0.id })
        let treeKnown = cmuxTreeKnown
        let liveKeys = cmuxLiveSessionKeys
        for stale in cmuxRegistry.staleTaskIds(now: Date().timeIntervalSinceReferenceDate, protected: protected, busy: busy,
                                               only: { CmuxRouting.timeRuleApplies(entry: $0, treeKnown: treeKnown, liveKeys: liveKeys) }) {
            // Focus moves on to the next session when the pill that goes was the focused one.
            forgetCmuxSurface(stale, wasFocused: state.focusId == cmuxRegistry.surface(key: stale)?.taskId)
        }
    }

    /// Reads the git branch of the main session of a pill. Called on task creation and on SessionStart,
    /// UserPromptSubmit and Stop only, at most once every few seconds per task: no timer, no polling.
    /// Only the main surface speaks for the pill (a helper may work in another folder). The title is not
    /// read here: discovery gives the workspace title.
    @MainActor
    private func refreshCmuxMeta(taskId: String, cwd: String, key: String?) {
        if let key, let main = cmuxRegistry.surface(for: taskId)?.key, main != key { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard CmuxRouting.metaRefreshDue(last: cmuxMetaAt[taskId], now: now) else { return }
        cmuxMetaAt[taskId] = now
        let folder = cwd.isEmpty ? (AppState.shared.tasks.first { $0.id == taskId }?.sessionCwd ?? "") : cwd
        CmuxControl.fetchBranch(cwd: folder) { branch in
            let state = AppState.shared
            guard let idx = state.tasks.firstIndex(where: { $0.id == taskId }) else { return }
            // Written only when changed: every write republishes `tasks`.
            let subtitle = CmuxRouting.folderLine(cwd: folder, branch: branch)
            if state.tasks[idx].subtitle != subtitle { state.tasks[idx].subtitle = subtitle }
        }
    }

    /// Everything tied to one cmux session that is gone: registry entry, queued cards, transcript, dialog
    /// mark, the reply target that pointed at it. The pill goes with its last session.
    @MainActor
    private func forgetCmuxSurface(_ key: String, wasFocused: Bool) {
        guard let s = cmuxRegistry.surface(key: key) else { return }
        let state = AppState.shared
        let taskId = s.taskId
        if cmuxRegistry.surfaces(ofTask: taskId).count <= 1 {
            state.clearSessionDiffs(for: taskId)
            state.removeTask(id: taskId)
            forgetCmuxTask(taskId, wasFocused: wasFocused)
            return
        }
        cmuxRegistry.remove(key: key)
        cleanupCmuxSurface(key, taskId: taskId)
        refoldCmuxTask(taskId)
        // The final line goes only when it was this session's: another session's answer stays on the pill.
        if cmuxFinalLineKey[taskId] == key {
            cmuxFinalLineKey[taskId] = nil
            if let idx = state.tasks.firstIndex(where: { $0.id == taskId }) { state.tasks[idx].finalLine = nil }
        }
        state.cmuxRevision &+= 1
    }

    @MainActor
    private func cleanupCmuxSurface(_ key: String, taskId: String) {
        let state = AppState.shared
        for cardId in cmuxQueue.removeAll(surfaceKey: key) { dropCmuxHeld(cardId, leftOpen: false) }
        cmuxOpenDialogs[key] = nil
        cmuxStopRecord.forget(key)
        CmuxTimelines.shared.remove(key)
        // Through the path that refreshes an open field; the draft typed before the session was resolved goes too.
        let closed = PromptSlot.Content.cmuxReply(taskId: taskId, surfaceKey: key)
        let heldText = !state.promptDrafts.text(for: closed).isEmpty
        state.clearDraft(for: closed)
        state.clearDraft(for: .cmuxReply(taskId: taskId, surfaceKey: nil))
        if state.cmuxReplyChoice[taskId] == key { state.cmuxReplyChoice[taskId] = nil }
        // The user is told here, where the session is cleaned up, not by the order of two view handlers: the text
        // typed for that session is dropped, and its own reply was on screen. The reply that shows next owns the notice.
        if PromptSlot.closedSessionNeedsNotice(rendered: state.cmuxRenderedContent, dropped: closed, draftWasEmpty: !heldText) {
            state.showCmuxFailure(.sessionClosed, owner: .cmuxReply(taskId: taskId, surfaceKey: cmuxReplyTarget(for: taskId)))
        }
    }

    /// Everything tied to a cmux pill that is gone (last SessionEnd, stale prune, eviction, closed workspace):
    /// its registry entries, queued cards, transcripts, the reply view of that pill, and where focus goes next.
    @MainActor
    private func forgetCmuxTask(_ id: String, wasFocused: Bool) {
        let state = AppState.shared
        let candidates = cmuxRegistry.taskIds.filter { $0 != id }.map { (id: $0, lastSeen: cmuxRegistry.pillLastSeen($0) ?? 0) }
        let keys = cmuxRegistry.surfaces(ofTask: id).map { $0.key }
        cmuxRegistry.remove(taskId: id)
        for key in keys { cleanupCmuxSurface(key, taskId: id) }
        state.clearDraft(for: .cmuxReply(taskId: id, surfaceKey: nil))
        for cardId in cmuxQueue.removeAll(taskId: id) { dropCmuxHeld(cardId, leftOpen: false) }
        state.cmuxReplyChoice[id] = nil
        cmuxMetaAt[id] = nil
        cmuxTitles[id] = nil
        cmuxFinalLineKey[id] = nil
        cmuxRefusedLogged.remove(id)
        state.cmuxRevision &+= 1
        if state.cmuxPrompt == .reply(taskId: id) {
            state.cmuxPrompt = nil
            state.cmuxNotice = nil
            if state.view == .prompt { state.view = .overview }
        }
        if wasFocused, state.mainPillId == CmuxRouting.hubPillId {
            let live = Set(state.tasks.map { $0.id })
            let next = CmuxRouting.nextFocus(afterRemoving: id, mainPillId: state.mainPillId,
                                             candidates: candidates.filter { live.contains($0.id) })
            state.setFocus(next)
        }
    }

    /// The task whose reply view is open (protected from prune and eviction), if any.
    @MainActor
    private func openCmuxReplyTask() -> String? {
        if case .reply(let id)? = AppState.shared.cmuxPrompt { return id }
        return nil
    }

    /// A new chat started by the user: when its surface reports in, type the first prompt.
    /// The automatic send needs the workspace UUID and the socket path of the launch to match. When the
    /// workspace could not be resolved, a task in the same folder is only focused and the prompt goes
    /// to the Reply field as a draft: the user presses Send.
    /// The new workspace is a new pill; its first session is the main one and gets the prompt.
    @MainActor
    private func handleCmuxSessionStart(agentId: String, key: String?, payload: [String: Any], cwd: String) {
        guard let pending = cmuxPendingLaunch, let key else { return }
        // Only a hook event with a valid token for this very surface can claim the launch, and with it the first
        // prompt that is typed without a click. A tokenless event (or one made up) neither matches nor uses up
        // the launch: the real session still can.
        guard cmuxRegistry.surface(key: key)?.canType == true else { return }
        let workspace = payload["cmux_workspace_id"] as? String ?? ""
        let socket = payload["cmux_socket_path"] as? String ?? ""
        let now = Date().timeIntervalSinceReferenceDate
        // New = the first hook event of this surface that carried a token (discovery may have registered the
        // surface before its SessionStart).
        let isNewSession = cmuxRegistry.lastNoteFirstHeard
        let exact = pending.matches(workspaceId: workspace, socketPath: socket,
                                    isNewTask: isNewSession, now: now)
        let byFolder = !exact && pending.matchesFolder(cwd: cwd, isNewTask: isNewSession, now: now)
        guard exact || byFolder else { return }
        cmuxPendingLaunch = nil
        let state = AppState.shared
        // The same focus rule as any new session: never take the screen from an open card.
        if CmuxRouting.launchMayTakeFocus(cardOpen: state.pendingApproval != nil || state.pendingQuestion != nil,
                                          promptIsNewChat: state.cmuxPrompt == .newChat) {
            // The reply is set before the focus moves: the slot must already belong to the new pill when it does.
            state.cmuxPrompt = .reply(taskId: agentId)
            state.setFocus(agentId)
            state.cmuxReplyChoice[agentId] = key
        }
        state.cmuxNotice = nil
        let prompt = pending.prompt
        guard exact else {
            let replyContent = PromptSlot.Content.cmuxReply(taskId: agentId, surfaceKey: key)
            state.restoreDraft(prompt, for: replyContent, endsLaunch: true, stashIfReplaced: true)
            // "Check the prompt and press Send" is true only when the prompt is in the field. If other text kept
            // the field, the prompt waits in the stash and there is no notice about it.
            if PromptSlot.promptIsInField(draft: state.promptDrafts.text(for: replyContent), prompt: prompt) {
                let sessionName = state.tasks.first { $0.id == agentId }?.name ?? ""
                state.cmuxNotice = CmuxRouting.folderDraftNotice(sessionName: sessionName)
            }
            return
        }
        // Gives the claude TUI time to take input. The one and only deferred send.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            CmuxControl.send(text: prompt, to: agentId, surfaceKey: key) { failure in
                guard let failure else { return }
                AppState.shared.showCmuxFailure(failure, owner: .cmuxReply(taskId: agentId, surfaceKey: key))
                if failure != .enterNotSent {
                    AppState.shared.restoreDraft(prompt, for: .cmuxReply(taskId: agentId, surfaceKey: key), endsLaunch: true, stashIfReplaced: true)
                }
            }
        }
    }

    /// One pill per cmux workspace. Generic overview card, no dedicated view.
    /// `key` is the session that sent the event: only the main one speaks for the folder line and the
    /// working folder, and the workspace title (from discovery) is the name once known.
    @MainActor
    private func upsertCmuxTask(id: String, projectName rawProjectName: String, cwd: String, key: String?) {
        let state = AppState.shared
        // The folder name comes from the hook payload: cleaned like the titles that come from the tree.
        let projectName = CmuxRouting.cleanLabel(rawProjectName) ?? String(localized: "Session")
        if let idx = state.tasks.firstIndex(where: { $0.id == id }) {
            // The workspace title is the name; without one the name set at creation stays.
            if let title = cmuxTitles[id] {
                let name = CmuxRouting.displayName(base: title, taskId: id, existing: cmuxPillNames())
                if state.tasks[idx].name != name { state.tasks[idx].name = name }
            }
            let isMain = key == nil || cmuxRegistry.surface(for: id)?.key == key || state.tasks[idx].sessionCwd == nil
            if isMain, !cwd.isEmpty, state.tasks[idx].sessionCwd != cwd { state.tasks[idx].sessionCwd = cwd }
            return
        }
        let name = CmuxRouting.displayName(base: cmuxTitles[id] ?? projectName, taskId: id, existing: cmuxPillNames())
        var task = makeCmuxPill(id: id, name: name, cwd: cwd)
        task.sessionCwd = cwd.isEmpty ? nil : cwd
        insertCmuxPill(task)
        if CmuxRouting.isExistingFolder(cwd) {
            state.cmuxRecentFolders = CmuxRouting.recentFolders(adding: cwd, to: state.cmuxRecentFolders)
        }
        if state.focusId == nil { state.focusId = id }
        let viewAllowsSteal = state.cmuxPrompt == nil
            && (state.mode != .expanded || state.view == .overview || state.view == .empty)
        if CmuxRouting.shouldFocusNewSession(mainPillId: state.mainPillId, focusId: state.focusId,
                                             viewAllowsSteal: viewAllowsSteal) {
            state.setFocus(id)
        }
        state.syncMode()
        refreshCmuxMeta(taskId: id, cwd: cwd, key: key)

        pruneStaleCmux()
        // Registry entries whose pill is gone (late event after SessionEnd) must not count toward the cap.
        let live = Set(state.tasks.map { $0.id })
        for stale in cmuxRegistry.taskIds where !live.contains(stale) {
            for s in cmuxRegistry.surfaces(ofTask: stale) {
                cmuxStopRecord.forget(s.key)
                CmuxTimelines.shared.remove(s.key)
            }
            cmuxRegistry.remove(taskId: stale)
        }
        let idle = CmuxRouting.evictableIdle(
            Set(state.tasks.filter { CmuxRouting.isCmuxTaskId($0.id) && $0.state == .idle }.map { $0.id }),
            openReplyTask: openCmuxReplyTask())
        for evict in cmuxRegistry.evictionCandidates(idle: idle, keep: id) {
            let wasFocused = state.focusId == evict
            state.clearSessionDiffs(for: evict)
            state.removeTask(id: evict)
            forgetCmuxTask(evict, wasFocused: wasFocused)
        }
    }

    @MainActor
    private func cmuxPillNames() -> [(id: String, name: String)] {
        AppState.shared.tasks.filter { CmuxRouting.isCmuxTaskId($0.id) }.map { (id: $0.id, name: $0.name) }
    }

    /// A workspace pill: distinct, stable colour and eye from its key, colour probed against the live ones.
    @MainActor
    private func makeCmuxPill(id: String, name: String, cwd: String) -> AgentTask {
        let state = AppState.shared
        var task = AgentTask(id: id, name: name, color: IslandConst.colorForProject(name),
                             state: .idle, steps: [], source: .claudeCode)
        task.subtitle = CmuxRouting.folderLine(cwd: cwd, branch: nil)
        let taken = Set(state.tasks.filter { CmuxRouting.isCmuxTaskId($0.id) }.map { $0.color })
        let look = CmuxRouting.appearance(key: String(id.dropFirst(CmuxRouting.taskPrefix.count)), takenColors: taken)
        task.color = look.color
        if look.eye != "pill" { task.miniEye = EyeShape(rawValue: look.eye) }
        return task
    }

    /// Right after the main pill, then the Hermes pills ahead of it.
    @MainActor
    private func insertCmuxPill(_ task: AgentTask) {
        let state = AppState.shared
        if let mainIdx = state.tasks.firstIndex(where: { $0.id == state.mainPillId }) {
            state.tasks.insert(task, at: mainIdx + 1)
        } else {
            state.tasks.insert(task, at: 0)
        }
        state.placeHermesPills()   // Hermes agent pills stay right after the main pill, ahead of sessions
    }

    // MARK: cmux discovery (workspaces, titles, sessions)

    /// Asks for a discovery: the cmux tree and the cmux session file, read once. Triggers only (a session
    /// reported in, a SessionStart / SessionEnd / prompt / Stop, the island expanding, cmux launched or
    /// activated, app start): no timer, no polling. At most one run at a time and one every 5 s; a request
    /// that cannot run yet is kept as one single delayed run.
    @MainActor
    func requestCmuxDiscovery() {
        let now = Date().timeIntervalSinceReferenceDate
        if cmuxDiscoveryInFlight { cmuxDiscoveryRerun = true; return }
        guard CmuxRouting.discoveryDue(last: cmuxDiscoveryLast, now: now, inFlight: false) else {
            let wait = CmuxRouting.discoveryInterval - (now - (cmuxDiscoveryLast ?? now))
            deferCmuxDiscovery(after: max(0.2, wait))
            return
        }
        cmuxDiscoveryLast = now
        cmuxDiscoveryInFlight = true
        cmuxDiscoveryRerun = false
        // A token only: the stored password is for the New chat the user starts, never for a background read, and
        // a tree read without a peer checked socket must not decide what exists. Without a token the pills come
        // from the session file alone.
        let credential = cmuxRegistry.credential(for: nil, hasPassword: false)
        CmuxControl.fetchSnapshot(credential: credential, startedAt: now) { [weak self] snapshot in
            guard let self else { return }
            self.cmuxDiscoveryInFlight = false
            self.applyCmuxSnapshot(snapshot)
            if self.cmuxDiscoveryRerun {
                self.cmuxDiscoveryRerun = false
                self.deferCmuxDiscovery(after: CmuxRouting.discoveryInterval)
            }
        }
    }

    @MainActor
    private func deferCmuxDiscovery(after delay: TimeInterval) {
        guard !cmuxDiscoveryDeferred else { return }
        cmuxDiscoveryDeferred = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                self?.cmuxDiscoveryDeferred = false
                self?.requestCmuxDiscovery()
            }
        }
    }

    /// Applies what one discovery found: surfaces and pills appear, get their workspace title, vanish when
    /// the tree says they are gone. Never moves focus, never opens the island, never sets a token. Surfaces it
    /// registers are not typing targets: only a hook event with a token makes one (`CmuxSurface.canType`).
    /// Order: what exists is added first (a pill the plan keeps is never destroyed and created again), then
    /// the surfaces and pills the tree no longer has go.
    @MainActor
    private func applyCmuxSnapshot(_ snapshot: CmuxSnapshot) {
        let state = AppState.shared
        let now = Date().timeIntervalSinceReferenceDate
        cmuxTreeKnown = snapshot.tree != nil
        cmuxLiveSessionKeys = snapshot.sessions.map { Set($0.map { CmuxRouting.sanitize($0.surfaceId) }) }
        cmuxEndedAt = cmuxEndedAt.filter { now - $0.value < CmuxRouting.endedGrace * 6 }
        let protected = CmuxRouting.pruneProtected(
            holdingCard: Set(cmuxRegistry.taskIds.filter { cmuxTaskHoldsCard($0) }),
            openReplyTask: openCmuxReplyTask())
        let plan = CmuxRouting.reconcile(snapshot: snapshot, entries: Array(cmuxRegistry.surfaces.values),
                                         protected: protected, ended: cmuxEndedAt)
        var membershipChanged = false

        for ws in plan.workspaces {
            if snapshot.tree != nil { cmuxTitles[ws.taskId] = ws.title }   // a title removed in cmux goes too
            else if let title = ws.title { cmuxTitles[ws.taskId] = title }
            var registered = false
            for sf in ws.surfaces {
                // A surface of a pill in use (a card, the open reply view) stays where it is.
                if let known = cmuxRegistry.surface(key: sf.key), known.taskId != ws.taskId,
                   protected.contains(known.taskId) { continue }
                let before = cmuxRegistry.surface(key: sf.key)
                guard cmuxRegistry.noteDiscovered(taskId: ws.taskId, key: sf.key, surfaceId: sf.surfaceId,
                                                  workspaceId: ws.workspaceId, socketPath: snapshot.socketPath,
                                                  sessionId: sf.sessionId, title: sf.title, index: sf.index,
                                                  startedAt: sf.startedAt, now: now) else { continue }
                registered = true
                if before == nil || before?.taskId != ws.taskId { membershipChanged = true }
                // A session Coucou never heard from may sit on an open permission dialog, whatever its file says:
                // Send stays off until a turn level hook event or the "Answered" click. Discovery only sets the
                // mark, it never clears one.
                if cmuxRegistry.surface(key: sf.key)?.heard != true, CmuxRouting.needsDialogMark(heard: false),
                   cmuxOpenDialogs[sf.key] == nil {
                    cmuxOpenDialogs[sf.key] = CmuxRouting.DialogMark(tool: "", inputKey: nil)
                }
            }
            let folder = ws.cwd
            if let idx = state.tasks.firstIndex(where: { $0.id == ws.taskId }) {
                if let title = cmuxTitles[ws.taskId] {
                    let name = CmuxRouting.displayName(base: title, taskId: ws.taskId, existing: cmuxPillNames())
                    if state.tasks[idx].name != name { state.tasks[idx].name = name }
                }
                if state.tasks[idx].sessionCwd == nil, !folder.isEmpty { state.tasks[idx].sessionCwd = folder }
                if state.tasks[idx].subtitle == nil, let line = CmuxRouting.folderLine(cwd: folder, branch: nil) {
                    state.tasks[idx].subtitle = line
                }
            } else if registered {
                // A pill exists only with a surface under it.
                let fallback = aliasProjectName(CmuxRouting.folderPillName(cwd: folder, fallback: String(localized: "Session")))
                let base = cmuxTitles[ws.taskId] ?? fallback
                let name = CmuxRouting.displayName(base: base, taskId: ws.taskId, existing: cmuxPillNames())
                var task = makeCmuxPill(id: ws.taskId, name: name, cwd: folder)
                task.sessionCwd = folder.isEmpty ? nil : folder
                insertCmuxPill(task)
                if !folder.isEmpty { refreshCmuxMeta(taskId: ws.taskId, cwd: folder, key: nil) }
                membershipChanged = true
            }
        }

        for key in plan.removeKeys where cmuxRegistry.surface(key: key) != nil {
            forgetCmuxSurface(key, wasFocused: state.focusId == cmuxRegistry.surface(key: key)?.taskId)
            membershipChanged = true
        }
        // Pills the plan does not keep, once nothing is filed under them (their surfaces were removed or moved).
        for task in plan.removeTasks where cmuxRegistry.surfaces(ofTask: task).isEmpty
            && (state.tasks.contains(where: { $0.id == task }) || cmuxRegistry.taskIds.contains(task)) {
            let wasFocused = state.focusId == task
            state.clearSessionDiffs(for: task)
            state.removeTask(id: task)
            forgetCmuxTask(task, wasFocused: wasFocused)
            membershipChanged = true
        }

        // cmux pills follow the workspace order of the sidebar, ahead of the sessions that are not in the plan.
        orderCmuxPills(plan.workspaces.map { $0.taskId })

        // Entries without a live process behind them: the time rule.
        pruneStaleCmux()
        if membershipChanged { state.cmuxRevision &+= 1 }
    }

    /// The cmux pills in sidebar order (those of the plan first), kept as one block where they already are.
    @MainActor
    private func orderCmuxPills(_ planned: [String]) {
        let state = AppState.shared
        let cmux = state.tasks.filter { CmuxRouting.isCmuxTaskId($0.id) }
        guard cmux.count > 1 else { return }
        let rank = Dictionary(planned.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = cmux.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }
        guard ordered.map({ $0.id }) != cmux.map({ $0.id }) else { return }
        var result: [AgentTask] = []
        var placed = false
        for t in state.tasks {
            if CmuxRouting.isCmuxTaskId(t.id) {
                if !placed { result.append(contentsOf: ordered); placed = true }
            } else {
                result.append(t)
            }
        }
        state.tasks = result
    }

    // MARK: cmux card queue

    /// Holds the hook's fd open and silent; the card is shown when it reaches the head of the queue.
    @MainActor
    private func enqueueCmuxCard(kind: CmuxCardKind, fd: Int32, payload: [String: Any], parsed: AskQuestion?,
                                 taskId: String, surfaceKey: String, sessionId: String, tool: String, inputKey: String,
                                 atFront: Bool = false, arrivedAt: TimeInterval? = nil) {
        let state = AppState.shared
        let now = Date().timeIntervalSinceReferenceDate
        let id = cmuxQueue.enqueue(kind: kind, taskId: taskId, sessionId: sessionId, tool: tool,
                                   inputKey: inputKey, now: now, atFront: atFront, arrivedAt: arrivedAt,
                                   surfaceKey: surfaceKey)
        // The read source fires when the hook goes away; its cancel handler is the only place the fd is closed.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // EOF on a young card: it was answered in the terminal. Only an old one may still be open.
            let arrival = self.cmuxQueue.cards.first { $0.id == id }?.arrivedAt
            let leftOpen = arrival.map {
                CmuxRouting.eofLeavesDialogOpen(arrivedAt: $0, now: Date().timeIntervalSinceReferenceDate)
            } ?? true
            self.dropCmuxHeld(id, leftOpen: leftOpen)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        cmuxHeld[id] = CmuxHeld(fd: fd, source: source, taskId: taskId, surfaceKey: surfaceKey,
                                payload: payload, parsed: parsed)

        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        upsertWorkspaceTask(id: taskId, projectName: aliasProjectName(rawName.isEmpty ? String(localized: "Session") : rawName),
                            cwd: cwd, cmuxKey: surfaceKey)
        setCmuxSurfaceState(taskId: taskId, key: surfaceKey, kind == .approval ? .approval : .question)
        setPillBadge(id: taskId, badge: .approval)
        nbLog("\(kind == .approval ? "PermissionRequest" : "AskUserQuestion") \(tool) [\(taskId)] queued")

        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in self?.dropCmuxHeld(id) }
    }

    /// Closes a queued card's fd without answering (hook prints nothing, Claude Code asks in the terminal).
    @MainActor
    private func dropCmuxHeld(_ id: Int, leftOpen: Bool = true) {
        guard let held = cmuxHeld.removeValue(forKey: id) else { return }
        held.source.cancel()
        if leftOpen { markCmuxDialogOpen(from: held) } else { timelineHandled(held) }
        cmuxQueue.remove(id: id)
        releaseCmuxSurfaceIfSettled(held.taskId, key: held.surfaceKey)
    }

    /// Back to `.working` once the session has no queued card and owns no card on screen; the badge goes
    /// when the pill holds no card at all.
    @MainActor
    private func releaseCmuxSurfaceIfSettled(_ taskId: String, key: String) {
        guard !cmuxSurfaceHoldsCard(key) else { return }
        if cmuxRegistry.surface(key: key) != nil { setCmuxSurfaceState(taskId: taskId, key: key, .working) }
        clearPillBadgeUnlessCardHeld(id: taskId)
    }

    /// An event resolved queued requests elsewhere (terminal, cmux Feed): drop them silently.
    @MainActor
    private func purgeCmuxQueue(event: String, sessionId: String, tool: String, inputKey: String) {
        for id in cmuxQueue.resolve(event: event, sessionId: sessionId, tool: tool, inputKey: inputKey) {
            guard let held = cmuxHeld.removeValue(forKey: id) else { continue }
            held.source.cancel()
            timelineHandled(held)
            releaseCmuxSurfaceIfSettled(held.taskId, key: held.surfaceKey)
        }
    }

    /// Promotes the next waiting card once the screen is free. Returns true when one was shown.
    @MainActor
    private func presentNextCmuxCard() -> Bool {
        guard liveApprovalFD < 0, liveQuestionFD < 0 else { return false }
        while true {
            let popped = cmuxQueue.popNext(now: Date().timeIntervalSinceReferenceDate)
            for id in popped.expired {
                guard let held = cmuxHeld.removeValue(forKey: id) else { continue }
                held.source.cancel()
                markCmuxDialogOpen(from: held)
                releaseCmuxSurfaceIfSettled(held.taskId, key: held.surfaceKey)
            }
            guard let card = popped.card else { return false }
            guard let held = cmuxHeld.removeValue(forKey: card.id) else { continue }
            // The queue source's cancel handler closes the original fd; the standard card path
            // installs its own source on a duplicate.
            let fd2 = dup(held.fd)
            held.source.cancel()
            guard fd2 >= 0 else {
                markCmuxDialogOpen(from: held)
                releaseCmuxSurfaceIfSettled(card.taskId, key: card.surfaceKey)
                continue
            }
            clearPillBadgeUnlessCardHeld(id: card.taskId)
            switch card.kind {
            case .approval:
                processPermissionRequest(fd: fd2, payload: held.payload, arrivedAt: card.arrivedAt)
            case .question:
                guard let parsed = held.parsed else {
                    close(fd2)
                    markCmuxDialogOpen(from: held)
                    releaseCmuxSurfaceIfSettled(card.taskId, key: card.surfaceKey)
                    continue
                }
                processQuestionRequest(fd: fd2, parsed: parsed, payload: held.payload, arrivedAt: card.arrivedAt)
            }
            // The card appeared without a click: ignore answers for a moment so a double click
            // on the previous card cannot land on this one.
            cmuxPromotedAt = Date().timeIntervalSinceReferenceDate
            return true
        }
    }

    /// A legacy (VS Code / Cursor / Codex) request is about to take the screen: the cmux card on it
    /// goes back to the head of the queue instead of being answered "ask".
    @MainActor
    private func requeueCmuxCardIfShowing() {
        guard let payload = cmuxShownPayload else { return }
        let state = AppState.shared
        let arrival = cmuxShownArrival
        let key = CmuxRouting.surfaceKey(payload: payload)
        if pendingApprovalFD >= 0, let info = state.pendingApproval, CmuxRouting.isCmuxTaskId(info.pillId) {
            let fd2 = dup(pendingApprovalFD)
            let source = approvalFDSource
            approvalFDSource = nil
            pendingApprovalFD = -1
            source?.cancel()
            state.pendingApproval = nil
            if fd2 >= 0 {
                enqueueCmuxCard(kind: .approval, fd: fd2, payload: payload, parsed: nil, taskId: info.pillId,
                                surfaceKey: key ?? info.pillId, sessionId: info.sessionId, tool: info.tool,
                                inputKey: info.inputKey, atFront: true, arrivedAt: arrival)
            } else {
                markCmuxDialogOpen(key, tool: info.tool, inputKey: info.inputKey)
                if let key { releaseCmuxSurfaceIfSettled(info.pillId, key: key) }
            }
        } else if pendingQuestionFD >= 0, CmuxRouting.isCmuxTaskId(questionPillId), let parsed = state.pendingQuestion {
            let fd2 = dup(pendingQuestionFD)
            let source = questionFDSource
            questionFDSource = nil
            // Before the view changes, so QuestionView.onDisappear → releaseQuestionFD is a no-op.
            pendingQuestionFD = -1
            source?.cancel()
            state.pendingQuestion = nil
            if fd2 >= 0 {
                let sessionId = payload["session_id"] as? String ?? payload["conversation_id"] as? String ?? "unknown"
                enqueueCmuxCard(kind: .question, fd: fd2, payload: payload, parsed: parsed, taskId: questionPillId,
                                surfaceKey: key ?? questionPillId, sessionId: sessionId, tool: "AskUserQuestion",
                                inputKey: Self.approvalInputKey(payload["tool_input"] as? [String: Any] ?? [:]),
                                atFront: true, arrivedAt: arrival)
            } else {
                markCmuxDialogOpen(key, tool: "AskUserQuestion", inputKey: nil)
                if let key { releaseCmuxSurfaceIfSettled(questionPillId, key: key) }
            }
        }
        cmuxShownPayload = nil
    }

    /// True while a card that came out of the queue is too fresh to take a click.
    @MainActor
    private func cmuxInputLocked() -> Bool {
        CmuxRouting.inputLocked(promotedAt: cmuxPromotedAt, now: Date().timeIntervalSinceReferenceDate)
    }

    #endif

    /// True while a card that replaced another card is too fresh to take a click (both builds).
    @MainActor
    private func cardReplacedLocked() -> Bool {
        CardInputLock.isLocked(armedAt: cardReplacedAt, now: Date().timeIntervalSinceReferenceDate)
    }

    // MARK: - Pill state helpers (both builds)

    /// Sets the state of a pill. For a cmux pill the state belongs to one session (`cmuxKey`): it is
    /// recorded for that session and the pill shows the folded state of all of them.
    @MainActor
    private func setTaskState(_ id: String, _ newState: BotState, cmuxKey: String? = nil) {
        #if !APPSTORE
        if CmuxRouting.isCmuxTaskId(id), let key = cmuxKey {
            setCmuxSurfaceState(taskId: id, key: key, newState)
            return
        }
        #endif
        AppState.shared.updateTask(id: id, state: newState)
    }

    /// Adds a step to the task's own list. Only a cmux pill uses it: every other session writes its steps on the
    /// board (`SessionBoard`), which the pill then shows.
    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    /// `<label> · ` for the steps of a session that is not the main one of its workspace, else "".
    @MainActor
    private func stepPrefix(forKey key: String?) -> String {
        #if !APPSTORE
        if let key { return cmuxStepPrefix(forKey: key) }
        #endif
        return ""
    }

    private enum AlertSlot { case view, badge, none }

    /// Where a finished / error alert goes. A cmux session also yields to a card of its pill that is on screen
    /// (it belongs to another session) and to the approval badge of a pill that holds a queued card.
    /// `focused` already says whether the pill is focused and the event may take the view.
    @MainActor
    private func alertPlacement(pillId: String, cmuxKey: String?, focused: Bool) -> AlertSlot {
        #if !APPSTORE
        if cmuxKey != nil {
            switch CmuxRouting.alertPlacement(focused: focused, cardOfPillOnScreen: cmuxCardOnScreen(forPill: pillId),
                                              pillHoldsCard: cmuxTaskHoldsCard(pillId)) {
            case .view: return .view
            case .badge: return .badge
            case .none: return .none
            }
        }
        #endif
        return focused ? .view : .badge
    }

    /// The badge stays while another session of the same cmux pill still holds a card.
    @MainActor
    private func clearPillBadgeUnlessCardHeld(id: String) {
        #if !APPSTORE
        if CmuxRouting.isCmuxTaskId(id), cmuxTaskHoldsCard(id) { return }
        #endif
        clearPillBadge(id: id)
    }

    /// Interrupt: a cmux pill keeps its badge while another session still shows a state.
    @MainActor
    private func clearPillBadgeIfIdle(id: String) {
        #if !APPSTORE
        if CmuxRouting.isCmuxTaskId(id), AppState.shared.tasks.first(where: { $0.id == id })?.state != .idle { return }
        #endif
        clearPillBadge(id: id)
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    // MARK: - Project name alias mapping

    /// The pill's name: the session's /rename title, else the folder the session started
    /// in (the hook reads both from the transcript), else the current cwd's folder.
    private func sessionName(_ payload: [String: Any], cwd: String) -> String {
        if let title = payload["session_title"] as? String, !title.isEmpty { return title }
        let root = payload["session_root"] as? String ?? ""
        let rawName = URL(fileURLWithPath: root.isEmpty ? cwd : root).lastPathComponent
        return aliasProjectName(rawName.isEmpty ? String(localized: "Session") : rawName)
    }

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - cmux timeline

    #if !APPSTORE
    /// One event of the timeline of a cmux session. Nothing else is read or written here; the timeline is memory only.
    @MainActor
    private func timeline(_ event: TimelineEvent, _ key: String?) {
        // A session the registry does not hold (past the cap, or just gone) has no timeline: the rule of every event.
        guard let key, cmuxRegistry.surface(key: key) != nil else { return }
        CmuxTimelines.shared.apply(event, to: key)
    }

    /// A queued card the terminal answered (or that nobody answers any more): its row says so.
    @MainActor
    private func timelineHandled(_ held: CmuxHeld) {
        if held.parsed != nil {
            timeline(.question(text: "", more: 0, outcome: .handled), held.surfaceKey)
        } else {
            let tool = held.payload["tool_name"] as? String ?? "Tool"
            let input = held.payload["tool_input"] as? [String: Any] ?? [:]
            timeline(.permission(key: timelineKey(tool: tool, input: input), label: tool, outcome: .handled,
                                 allowedWord: String(localized: "allowed")), held.surfaceKey)
        }
    }

    /// The key that pairs the events of one tool call (see `TimelineNames.pairingKey`): the tool and the sorted input,
    /// the same match the app already trusts to pair a PostToolUse with the approval on screen.
    private func timelineKey(tool: String, input: [String: Any]) -> String {
        TimelineNames.pairingKey(tool: tool, inputKey: Self.approvalInputKey(input))
    }

    /// The row of a file edit: counts, the changed lines (the store keeps six), and the id of the full diff.
    private static func timelineEdit(diff: FileDiff, diffId: Int) -> ChatEdit {
        var lines: [ChatEditLine] = []
        outer: for hunk in diff.hunks {
            for line in hunk.lines where line.kind != .context {
                lines.append(ChatEditLine(kind: line.kind == .added ? .added : .removed, text: line.text))
                if lines.count >= TimelineStore.maxPreviewLines { break outer }
            }
        }
        return ChatEdit(callId: "", tool: "", symbol: nil, name: diff.name, path: diff.path, added: diff.added,
                        removed: diff.removed, isNewFile: diff.isNewFile, tooLarge: diff.tooLarge, preview: lines, diffId: diffId)
    }
    #endif

    // MARK: - Localized step labels

    private func localizedStep(tool: String, input: [String: Any]) -> String {
        let parts = stepParts(tool: tool, input: input)
        return parts.detail.map { "\(parts.verb) · \($0)" } ?? parts.verb
    }

    /// The step wording in parts: the verb (a word of ours) and the detail (the command, file or query), nil when the
    /// step has none; `localizedStep` is these two joined with " · ". The timeline reads the same wording once, with
    /// two differences that never reach the ticker: `timelineDetail` folds every run of white space before the cut (a
    /// long run of spaces cannot push the end of a command out of sight), and `plainVerb` is the verb of the tool itself,
    /// not the one guessed from the first word of the command (the row of a request must not flatter it).
    private struct StepParts {
        var verb: String
        var detail: String?
        var timelineDetail: String?
        var plainVerb: String
    }

    private func stepParts(tool: String, input: [String: Any]) -> StepParts {
        let labels: [String: String] = [
            "Bash":         String(localized: "step.runs",       defaultValue: "Runs"),
            "Read":         String(localized: "step.reads",      defaultValue: "Reads"),
            "Write":        String(localized: "step.writes",     defaultValue: "Writes"),
            "Edit":         String(localized: "step.edits",      defaultValue: "Edits"),
            "Glob":         String(localized: "step.searches",   defaultValue: "Searches"),
            "Grep":         String(localized: "step.searches",   defaultValue: "Searches"),
            "WebSearch":    String(localized: "step.web-search", defaultValue: "Searches the web"),
            "WebFetch":     String(localized: "step.fetches",    defaultValue: "Fetches"),
            "TodoWrite":    String(localized: "step.tasks",      defaultValue: "Tasks"),
            "Task":         String(localized: "step.agent",      defaultValue: "Agent"),
            "LS":           String(localized: "step.lists",      defaultValue: "Lists"),
            "MultiEdit":    String(localized: "step.edits",      defaultValue: "Edits"),
            "NotebookEdit": String(localized: "step.notebook",   defaultValue: "Notebook"),
            // Codex tools
            "apply_patch":  String(localized: "step.edits",     defaultValue: "Edits"),
            "update_plan":  String(localized: "step.tasks",     defaultValue: "Tasks"),
            "spawn_agent":  String(localized: "step.agent",     defaultValue: "Agent"),
            // Antigravity tools
            "ask_question": String(localized: "step.needs-input", defaultValue: "Needs input"),
        ]
        let labelTool = tool == "ask_question" || tool.hasSuffix(":ask_question") ? "ask_question" : tool
        var label = labels[labelTool] ?? tool

        // Codex MCP tools arrive as mcp__server__tool — show "server · tool"
        if tool.hasPrefix("mcp__") {
            let rest = String(tool.dropFirst(5))
            let parts = rest.components(separatedBy: "__")
            label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : rest
        }

        /// The text of the command or query, cut for the ticker and folded and cut for the timeline.
        func texted(_ verb: String, _ raw: String) -> StepParts {
            StepParts(verb: verb, detail: oneLine(raw), timelineDetail: oneLine(raw, collapse: true), plainVerb: label)
        }
        func plain(_ detail: String?) -> StepParts {
            StepParts(verb: label, detail: detail, timelineDetail: detail, plainVerb: label)
        }

        // Bash: infer a more precise verb from the command
        if tool == "Bash", let cmd = input["command"] as? String {
            return texted(bashVerb(cmd), cmd)
        }

        // apply_patch: extract the first file name from the patch
        if tool == "apply_patch", let patch = input["command"] as? String {
            for line in patch.split(separator: "\n") {
                for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] {
                    if line.hasPrefix(prefix) {
                        let path = String(line.dropFirst(prefix.count))
                        return plain(URL(fileURLWithPath: path).lastPathComponent)
                    }
                }
            }
            return plain(nil)
        }

        // ask_question: extract the question string
        if (tool == "ask_question" || tool.hasSuffix(":ask_question")),
           let questions = input["questions"] as? [[String: Any]],
           let firstQ = questions.first?["question"] as? String,
           !firstQ.trimmingCharacters(in: .whitespaces).isEmpty {
            return texted(label, firstQ)
        }

        if let cmd = input["command"] as? String {
            return texted(label, cmd)
        } else if let path = input["path"] as? String {
            return plain(URL(fileURLWithPath: path).lastPathComponent)
        } else if let file = input["file_path"] as? String {
            return plain(URL(fileURLWithPath: file).lastPathComponent)
        } else if let query = input["query"] as? String {
            return texted(label, query)
        }
        return plain(nil)
    }

    /// Infers a localized verb from a shell command's first word.
    private func bashVerb(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl": return String(localized: "step.reads",    defaultValue: "Reads")
        case "rg", "grep", "find", "fd", "ls", "tree", "wc":    return String(localized: "step.searches", defaultValue: "Searches")
        default: break
        }
        let testRunners = ["pytest", "vitest", "jest", "npm test", "npm run test",
                           "cargo test", "go test", "swift test", "make test",
                           "xcodebuild test", "unittest"]
        if testRunners.contains(where: { command.contains($0) }) { return String(localized: "step.tests", defaultValue: "Tests") }
        return String(localized: "step.runs", defaultValue: "Runs")
    }

    // MARK: - Live diff helpers

    @MainActor
    private func buildFileDiff(tool: String, input: [String: Any], pillId: String) -> FileDiff? {
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String,
                  let path = input["file_path"] as? String,
                  !old.isEmpty || !new.isEmpty else { return nil }
            let d = DiffEngine.fromEdit(old: old, new: new, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        case "MultiEdit":
            guard let path = input["file_path"] as? String,
                  let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else { return nil }
            var totalAdded = 0, totalRemoved = 0, allHunks: [DiffHunk] = [], anyLarge = false
            for edit in edits {
                guard let old = edit["old_string"] as? String,
                      let new = edit["new_string"] as? String else { continue }
                let d = DiffEngine.fromEdit(old: old, new: new, path: path)
                totalAdded += d.added; totalRemoved += d.removed
                allHunks.append(contentsOf: d.hunks); if d.tooLarge { anyLarge = true }
            }
            guard totalAdded > 0 || totalRemoved > 0 else { return nil }
            return FileDiff(path: path, added: totalAdded, removed: totalRemoved,
                            hunks: allHunks, tooLarge: anyLarge, isNewFile: false)

        case "Write":
            guard let path = input["file_path"] as? String,
                  let content = input["content"] as? String, !content.isEmpty else { return nil }
            let d = DiffEngine.fromNew(content: content, path: path)
            return (d.added > 0 || d.removed > 0) ? d : nil

        default:
            return nil
        }
    }

    /// Collapses whitespace so a multi-line command stays one ticker row.
    private func oneLine(_ text: String, limit: Int = 60, collapse: Bool = false) -> String {
        #if !APPSTORE
        // The timeline folds every run of white space first, so the cut is at the real text.
        let source = collapse ? TimelineStore.wording(text, max: 4000) : text
        #else
        let source = text
        #endif
        let collapsed = source.split(whereSeparator: { $0.isNewline || $0 == "\t" })
                            .joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        appendAppLog("nb.log", message)
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires NSOpenPanel to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700 as NSNumber], ofItemAtPath: dir.path)
        // nb-hook: shell wrapper (always exits 0, calls nb-hook.py via python3)
        let wrapperURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        // nb-hook.py: Python relay
        let pyURL = wrapperURL.deletingLastPathComponent().appendingPathComponent("nb-hook.py")
        try? nbHookPythonGitHub.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou hook that needs updating:
    /// either a PermissionRequest hook with timeout < 120s, or the AskUserQuestion
    /// PreToolUse matcher is missing (requires Claude Code 2.1.85+).
    static func hooksNeedUpdate() -> Bool {
        #if APPSTORE
        // Sandboxed: ~/.claude can't be read here (homeDirectoryForCurrentUser is the
        // container). The relay script written at install carries the version it was
        // written with: an older one (1.1 wrote none) misses plan approval, session titles
        // and Claude Desktop routing, so Settings offers "Update hooks".
        guard UserDefaults.standard.bool(forKey: "coucouHooksInstalled") else { return false }
        return UserDefaults.standard.integer(forKey: appStoreHookVersionKey) < appStoreHookVersion
        #else
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }
        // Track whether any Coucou hook is installed at all
        var hasCoucouHooks = false

        if let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] {
            for matcher in permReqHooks {
                if let hookList = matcher["hooks"] as? [[String: Any]] {
                    for hook in hookList {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("NotchBuddy") || cmd.contains("coucou") {
                            hasCoucouHooks = true
                            if let timeout = hook["timeout"] as? Int, timeout < 120 { return true }
                        }
                    }
                }
            }
        }

        // Check that the AskUserQuestion PreToolUse entry exists
        if hasCoucouHooks {
            let preToolHooks = hooks["PreToolUse"] as? [[String: Any]] ?? []
            let hasAskEntry = preToolHooks.contains { m in
                (m["matcher"] as? String) == "AskUserQuestion"
                && (m["hooks"] as? [[String: Any]])?.contains {
                    let cmd = $0["command"] as? String ?? ""
                    return cmd.contains("NotchBuddy") || cmd.contains("coucou")
                } ?? false
            }
            if !hasAskEntry { return true }
        }
        return false
        #endif
    }

    #if APPSTORE
    /// Bump when nbHookPythonAppStore or the hooks written by buildHooksData change in a way
    /// the installed copy must catch up with. 1.1 wrote no version (0); 2.0 is 2.
    static let appStoreHookVersion = 2
    static let appStoreHookVersionKey = "coucouAppStoreHookVersion"
    #endif

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?
    /// The bytes of settings.json the pending preview was computed from.
    private var _pendingHooksOriginal: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let (data, original) = try buildHooksData()
        _pendingHooksData = data
        _pendingHooksOriginal = original
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    /// Refused if settings.json changed since the preview, or cannot be backed up.
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try ClaudeSettingsFile.write(data, to: settingsURL, expecting: _pendingHooksOriginal)
        _pendingHooksData = nil
        _pendingHooksOriginal = nil
    }

    private func buildHooksData() throws -> (data: Data, original: Data?) {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Unreadable or invalid settings must stop here, never count as empty.
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #else
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        // "hooks" in a shape we do not know is refused, never replaced.
        var hooks = try ClaudeSettingsFile.hooks(in: settings, name: "settings.json")
        for (event, timeout) in events {
            var existing = try ClaudeSettingsFile.hookGroups(in: hooks, event: event, name: "settings.json")
            // Remove only our own nb-hook entries, not whole groups that merely
            // mention us: a user hook like ~/dev/coucou/scripts/lint.sh must survive.
            existing = removeNbHookEntries(from: existing)
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        return (data, snapshot.bytes)
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
        guard var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                // Per-entry removal, like the Gemini path: user hooks that merely
                // mention "coucou"/"NotchBuddy" are kept, only nb-hook commands go.
                matchers = removeNbHookEntries(from: matchers)
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try ClaudeSettingsFile.write(newData, to: settingsURL, expecting: snapshot.bytes)
    }

    // MARK: - Claude plan status line installer

    private var statusLinePreviousURL: URL {
        Self.supportDir.appendingPathComponent("statusline-previous.json")
    }

    /// Returns true if our statusLine command is installed in ~/.claude/settings.json.
    static func statusLineInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sl = settings["statusLine"] as? [String: Any],
              let cmd = sl["command"] as? String else { return false }
        return cmd.contains("nb-hook")
    }

    private var _pendingStatusLineData: Data?
    /// The bytes of settings.json the pending preview was computed from.
    private var _pendingStatusLineOriginal: Data?
    private var _pendingPreviousData: Data?
    private var _pendingDeletePrevious: Bool = false

    /// Returns a diff string (only the statusLine key: before → after) without writing anything.
    func previewStatusLine(install: Bool) throws -> String {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Unreadable or invalid settings must stop here, never count as empty.
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        let settings = snapshot.object
        let hookPath = Self.hookScriptPath
        let quotedPath = hookPath.replacingOccurrences(of: "\"", with: "\\\"")
        let quotedCmd = "\"\(quotedPath)\" --statusline"

        // Reset pending side-effects
        _pendingPreviousData = nil
        _pendingDeletePrevious = false

        let oldSL = settings["statusLine"] as? [String: Any]
        let newSL: [String: Any]?

        if install {
            // Check that Python 3 is available (requires Command Line Tools)
            let clCheck = Process()
            clCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            clCheck.arguments = ["-p"]
            clCheck.standardOutput = FileHandle.nullDevice
            clCheck.standardError = FileHandle.nullDevice
            try? clCheck.run()
            clCheck.waitUntilExit()
            if clCheck.terminationStatus != 0 {
                throw NSError(domain: "Coucou", code: 1,
                              userInfo: [NSLocalizedDescriptionKey:
                                  String(localized: "Command Line Tools are required but not installed. Run: xcode-select --install")])
            }

            if let existing = oldSL,
               let cmd = existing["command"] as? String, !cmd.contains("nb-hook") {
                // Keep existing object but swap command; save old for later restoration
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
                _pendingPreviousData = try? JSONSerialization.data(withJSONObject: existing,
                                                                   options: [.prettyPrinted, .sortedKeys])
            } else if let existing = oldSL,
                      let cmd = existing["command"] as? String, cmd.contains("nb-hook") {
                // Already installed — rebuild to update path if needed, keep other fields
                var updated = existing
                updated["command"] = quotedCmd
                newSL = updated
            } else {
                newSL = ["type": "command", "command": quotedCmd]
            }
        } else {
            // Uninstall: only if it's ours
            if let cur = oldSL, let cmd = cur["command"] as? String, cmd.contains("nb-hook") {
                if let prevData = try? Data(contentsOf: statusLinePreviousURL),
                   let prevObj = (try? JSONSerialization.jsonObject(with: prevData)) as? [String: Any] {
                    newSL = prevObj
                    _pendingDeletePrevious = true
                } else {
                    newSL = nil
                }
            } else {
                newSL = oldSL  // not ours — leave unchanged
            }
        }

        // Build the full settings.json with the new statusLine
        var newSettings = settings
        if let sl = newSL {
            newSettings["statusLine"] = sl
        } else {
            newSettings.removeValue(forKey: "statusLine")
        }
        let data = try JSONSerialization.data(withJSONObject: newSettings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        _pendingStatusLineData = data
        _pendingStatusLineOriginal = snapshot.bytes

        // Build a compact diff: show only the statusLine key before → after
        func slJSON(_ val: [String: Any]?) throws -> String {
            guard let v = val else { return "(none)" }
            let d = try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
            return String(data: d, encoding: .utf8) ?? "(none)"
        }
        let before = try slJSON(oldSL)
        let after  = try slJSON(newSL)
        return "statusLine\nBefore:\n\(before)\n\nAfter:\n\(after)"
    }

    /// Writes settings.json and commits side effects (call after user confirms).
    func writeStatusLine() throws {
        guard let data = _pendingStatusLineData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        try ClaudeSettingsFile.write(data, to: settingsURL, expecting: _pendingStatusLineOriginal)
        // Commit side effects only after successful write
        if let prevData = _pendingPreviousData {
            try? prevData.write(to: statusLinePreviousURL, options: .atomic)
        }
        if _pendingDeletePrevious {
            try? FileManager.default.removeItem(at: statusLinePreviousURL)
        }
        _pendingStatusLineData = nil
        _pendingStatusLineOriginal = nil
        _pendingPreviousData = nil
        _pendingDeletePrevious = false
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// Writes nb-hook script and updates settings.json in one shot.
    /// claudeURL must be a URL from NSOpenPanel (sandbox access is granted immediately — no security scope needed).
    func installAndWriteClaudeHooksAppStore(claudeURL: URL) throws {
        let (data, original) = try buildHooksData(claudeURL: claudeURL)

        // Write nb-hook (shell wrapper) + nb-hook.py (Python relay) into ~/.claude/coucou/
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let wrapperURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookShellWrapper.write(to: wrapperURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: wrapperURL.path)
        let pyURL = coucouDir.appendingPathComponent("nb-hook.py")
        try nbHookPythonAppStore.write(to: pyURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: pyURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        try ClaudeSettingsFile.write(data, to: settingsURL, expecting: original)
        UserDefaults.standard.set(true, forKey: "coucouHooksInstalled")
        UserDefaults.standard.set(Self.appStoreHookVersion, forKey: Self.appStoreHookVersionKey)
    }

    /// The settings.json Coucou would write, to show before writing (CLAUDE.md: never
    /// write ~/.claude/settings.json without showing the change first).
    func previewClaudeHooksAppStore(claudeURL: URL) throws -> String {
        let (data, _) = try buildHooksData(claudeURL: claudeURL)
        return String(data: data, encoding: .utf8) ?? ""
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                // Per-entry removal, like the Gemini path: user hooks that merely
                // mention "coucou"/"NotchBuddy" are kept, only nb-hook commands go.
                matchers = removeNbHookEntries(from: matchers)
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try ClaudeSettingsFile.write(newData, to: settingsURL, expecting: snapshot.bytes)
        UserDefaults.standard.set(false, forKey: "coucouHooksInstalled")
    }

    private func buildHooksData(claudeURL: URL) throws -> (data: Data, original: Data?) {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        // Unreadable or invalid settings must stop here, never count as empty.
        let snapshot = try ClaudeSettingsFile.read(at: settingsURL)
        var settings = snapshot.object
        // Derive hook path from the panel-selected claudeURL (real ~/.claude, not container)
        let hookPath = claudeURL.appendingPathComponent("coucou/nb-hook").path
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        // "hooks" in a shape we do not know is refused, never replaced.
        var hooks = try ClaudeSettingsFile.hooks(in: settings, name: "settings.json")
        for (event, timeout) in events {
            var existing = try ClaudeSettingsFile.hookGroups(in: hooks, event: event, name: "settings.json")
            // Remove only our own nb-hook entries, not whole groups that merely
            // mention us: a user hook like ~/dev/coucou/scripts/lint.sh must survive.
            existing = removeNbHookEntries(from: existing)
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        // Dedicated AskUserQuestion PreToolUse hook (Claude Code 2.1.85+, timeout 130s)
        var preToolUse = hooks["PreToolUse"] as? [[String: Any]] ?? []
        preToolUse.append([
            "matcher": "AskUserQuestion",
            "hooks": [["type": "command", "command": "\(quotedCmd) --ask", "timeout": 130]],
        ])
        hooks["PreToolUse"] = preToolUse
        settings["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        return (data, snapshot.bytes)
    }
    #endif

    // MARK: - Claude Code installed-state detection (both builds)

    /// True when ~/.claude/settings.json already routes Claude Code events to Coucou.
    /// Cursor sessions ride on these same hooks, so they share this state.
    static func claudeHooksInstalled() -> Bool {
        #if APPSTORE
        // Sandboxed: can't read ~/.claude directly — check the install flag set on write.
        return UserDefaults.standard.bool(forKey: "coucouHooksInstalled")
        #else
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        return coucouHooksPresent(inSettings: json)
        #endif
    }

    // MARK: - Removing Coucou's own hook entries (both builds)

    /// Removes entries containing "nb-hook" from a Gemini- or Claude-format groups array
    /// (matcher + hooks[]), handling the legacy flat format too (command at top level).
    /// Used by both paths' install/uninstall so only Coucou's own entries are removed;
    /// whole groups are dropped only when every entry in them was ours.
    private func removeNbHookEntries(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group -> [String: Any]? in
            // Legacy flat entry — command at group level
            if let cmd = group["command"] as? String, cmd.contains("nb-hook") { return nil }
            // Group format — filter inner hooks
            if var innerHooks = group["hooks"] as? [[String: Any]] {
                innerHooks.removeAll { ($0["command"] as? String)?.contains("nb-hook") == true }
                if innerHooks.isEmpty { return nil }
                var updated = group
                updated["hooks"] = innerHooks
                return updated
            }
            return group
        }
    }

    // MARK: - Gemini CLI and Antigravity hook installers  (#if !APPSTORE only)

    #if !APPSTORE
    private static var geminiSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
    }
    private static var agyHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config/hooks.json")
    }

    // MARK: Installed-state detection

    static func geminiHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: geminiSettingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent gemini") { return true }
                    }
                }
                // Legacy flat entry
                if let cmd = group["command"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent gemini") { return true }
            }
        }
        return false
    }

    static func agyHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: agyHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let coucou = root["coucou"] else { return false }
        let json = (try? JSONSerialization.data(withJSONObject: coucou))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return json.contains("nb-hook")
    }

    // MARK: Gemini CLI – preview / write

    private var _pendingGeminiData: Data?
    private var _pendingGeminiFingerprint: String?

    func previewGeminiHooks(install: Bool) throws -> String {
        let url = Self.geminiSettingsURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "No Gemini CLI hooks to remove.")
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingGeminiFingerprint = sha256Hex(current)
        let newData = install ? try buildGeminiHooksData() : try withoutGeminiHooks()
        _pendingGeminiData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeGeminiHooks() throws {
        guard let data = _pendingGeminiData, let fp = _pendingGeminiFingerprint else { return }
        let url = Self.geminiSettingsURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "~/.gemini/settings.json changed since preview. Refresh and try again.")
            ])
        }
        try writeJSONFile(data, to: url, suffix: "settings.json")
        _pendingGeminiData = nil
        _pendingGeminiFingerprint = nil
    }

    private func buildGeminiHooksData() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.geminiSettingsURL,
                                                     label: "~/.gemini/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "~/.gemini/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it.")
            ])
        }
        let base = hookBase()
        // (Gemini event key, normalized event name passed via argv, timeout in ms)
        let events: [(String, String, Int)] = [
            ("SessionStart", "SessionStart", 10000),
            ("SessionEnd",   "SessionEnd",   10000),
            ("BeforeTool",   "PreToolUse",   5000),
            ("AfterTool",    "PostToolUse",  5000),
            ("BeforeAgent",  "UserPromptSubmit", 5000),
            ("AfterAgent",   "Stop",         5000),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (geminiEvent, normalizedEvent, timeout) in events {
            if let raw = hooks[geminiEvent], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "~/.gemini/settings.json: \"hooks\"[\"\(geminiEvent)\"] has an unexpected type — Coucou has not touched it.")
                ])
            }
            var groups = hooks[geminiEvent] as? [[String: Any]] ?? []
            // Remove legacy flat entries and groups whose inner hooks contain nb-hook
            groups = removeNbHookEntries(from: groups)
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent gemini \(normalizedEvent)",
                "timeout": timeout,
            ]
            groups.append(["matcher": "*", "hooks": [hookEntry]])
            hooks[geminiEvent] = groups
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutGeminiHooks() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.geminiSettingsURL,
                                                     label: "~/.gemini/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "~/.gemini/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it.")
            ])
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Antigravity – preview / write

    private var _pendingAgyData: Data?
    private var _pendingAgyFingerprint: String?

    func previewAgyHooks(install: Bool) throws -> String {
        let url = Self.agyHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "No Antigravity hooks to remove.")
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingAgyFingerprint = sha256Hex(current)
        let newData = install ? try buildAgyHooksData() : try withoutAgyHooks()
        _pendingAgyData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeAgyHooks() throws {
        guard let data = _pendingAgyData, let fp = _pendingAgyFingerprint else { return }
        let url = Self.agyHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "~/.gemini/config/hooks.json changed since preview. Refresh and try again.")
            ])
        }
        try writeJSONFile(data, to: url, suffix: "hooks.json")
        _pendingAgyData = nil
        _pendingAgyFingerprint = nil
    }

    private func buildAgyHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.agyHooksURL,
                                                 label: "~/.gemini/config/hooks.json")
        let base = hookBase()
        // PreToolUse / PostToolUse: tool-level hooks — use matcher group
        // PreInvocation / PostInvocation / Stop: lifecycle hooks — direct handler, no matcher
        var coucou: [String: Any] = [:]
        for event in ["PreToolUse", "PostToolUse"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [["matcher": "*", "hooks": [hook]]]
        }
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let hook: [String: Any] = ["type": "command",
                                       "command": "\(base) --agent antigravity \(event)",
                                       "timeout": 10]
            coucou[event] = [hook]
        }
        root["coucou"] = coucou
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutAgyHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.agyHooksURL,
                                                 label: "~/.gemini/config/hooks.json")
        root.removeValue(forKey: "coucou")
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: Shared helpers

    /// /bin/sh "<hookScriptPath>" — quoted for paths containing spaces (Application Support).
    private func hookBase() -> String {
        let path = Self.hookScriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        return "/bin/sh \"\(path)\""
    }

    /// Reads a JSON object from url.
    /// Absent file → empty dict. Present but invalid → throws with a user-facing message.
    private static func strictReadJSONObject(at url: URL, label: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "\(label) cannot be read — Coucou has not touched it.")
            ])
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "\(label) is not valid JSON — Coucou has not touched it.")
            ])
        }
        return obj
    }

    /// Backs up the existing file (throws on failure), creates parent dirs, then atomically writes.
    private func writeJSONFile(_ data: Data, to url: URL, suffix: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(suffix).bak-\(fmt.string(from: Date()))")
            do { try fm.copyItem(at: url, to: backupURL) }
            catch {
                throw NSError(domain: "Coucou", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Could not back up \(url.lastPathComponent): \(error.localizedDescription)")
                ])
            }
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Codex hook installer  (#if !APPSTORE only)

    static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    /// True when ~/.codex/hooks.json already routes Codex events to Coucou's nb-hook.
    static func codexHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: codexHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for hook in innerHooks {
                        if let cmd = hook["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent codex") { return true }
                    }
                }
            }
        }
        return false
    }

    private var _pendingCodexData: Data?
    private var _pendingCodexFingerprint: String?

    func previewCodexHooks(install: Bool) throws -> String {
        let url = Self.codexHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "No Codex hooks to remove.")
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingCodexFingerprint = sha256Hex(current)
        let newData = install ? try buildCodexHooksData() : try withoutCodexHooks()
        _pendingCodexData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeCodexHooks() throws {
        guard let data = _pendingCodexData, let fp = _pendingCodexFingerprint else { return }
        let url = Self.codexHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "~/.codex/hooks.json changed since preview. Refresh and try again.")
            ])
        }
        try writeJSONFile(data, to: url, suffix: "hooks.json")
        _pendingCodexData = nil
        _pendingCodexFingerprint = nil
    }

    private func buildCodexHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.codexHooksURL, label: "~/.codex/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "~/.codex/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it.")
            ])
        }
        let base = hookBase()
        // Events, timeouts in seconds (Codex format).
        // PermissionRequest uses 120s + a statusMessage shown in the Codex UI while waiting.
        let events: [(String, Int, String?)] = [
            ("SessionStart",    10,  nil),
            ("UserPromptSubmit", 10, nil),
            ("PreToolUse",      10,  nil),
            ("PermissionRequest", 120, "Waiting for your answer in the notch (Coucou)"),
            ("PostToolUse",     10,  nil),
            ("Stop",            10,  nil),
            ("SubagentStart",   10,  nil),
            ("SubagentStop",    10,  nil),
            ("Interrupt",        3,  nil),
            ("SessionEnd",       3,  nil),
        ]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout, statusMsg) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "~/.codex/hooks.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it.")
                ])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            // Remove existing Coucou entries
            groups = removeNbHookEntries(from: groups)
            var hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent codex",
                "timeout": timeout,
            ]
            if let msg = statusMsg { hookEntry["statusMessage"] = msg }
            groups.append(["hooks": [hookEntry]])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutCodexHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.codexHooksURL, label: "~/.codex/hooks.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "~/.codex/hooks.json: \"hooks\" has an unexpected type — Coucou has not touched it.")
            ])
        }
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - GitHub Copilot CLI hook installer

    static var copilotHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/coucou.json")
    }

    /// True when ~/.copilot/hooks/coucou.json already routes Copilot events to Coucou's nb-hook.
    static func copilotHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: copilotHooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                if let cmd = entry["bash"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent copilot") { return true }
            }
        }
        return false
    }

    private var _pendingCopilotData: Data?
    private var _pendingCopilotFingerprint: String?

    func previewCopilotHooks(install: Bool) throws -> String {
        let url = Self.copilotHooksURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Copilot hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingCopilotFingerprint = sha256Hex(current)
        if install {
            let newData = try buildCopilotHooksData()
            _pendingCopilotData = newData
            return String(data: newData, encoding: .utf8) ?? ""
        } else {
            _pendingCopilotData = nil  // nil = delete signal
            return "(will delete \(url.path))"
        }
    }

    func writeCopilotHooks() throws {
        guard let fp = _pendingCopilotFingerprint else { return }
        let url = Self.copilotHooksURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json changed since preview. Refresh and try again."
            ])
        }
        if let data = _pendingCopilotData {
            try writeJSONFile(data, to: url, suffix: "coucou.json")
        } else {
            // Uninstall: delete the file entirely
            try FileManager.default.removeItem(at: url)
        }
        _pendingCopilotData = nil
        _pendingCopilotFingerprint = nil
    }

    private func buildCopilotHooksData() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.copilotHooksURL,
                                                  label: "~/.copilot/hooks/coucou.json")
        if let raw = root["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Copilot CLI uses camelCase event names; each entry uses "bash" + "timeoutSec".
        // The event name is passed as a positional arg so the relay can fall back to it.
        // Copilot is fail-closed on permissionRequest — must always output valid JSON.
        let events: [(String, Int)] = [
            ("sessionStart",        10),
            ("userPromptSubmitted", 10),
            ("preToolUse",          10),
            ("permissionRequest",  120),
            ("postToolUse",         10),
            ("agentStop",           10),
            ("sessionEnd",           3),
            ("notification",        10),
        ]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.copilot/hooks/coucou.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { ($0["bash"] as? String)?.contains("nb-hook") == true }
            entries.append(["type": "command", "bash": "\(base) --agent copilot \(event)", "timeoutSec": timeout])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        root["version"] = 1
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutCopilotHooks() throws -> Data {
        var root = try Self.strictReadJSONObject(at: Self.copilotHooksURL,
                                                  label: "~/.copilot/hooks/coucou.json")
        if var hooks = root["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if var entries = hooks[key] as? [[String: Any]] {
                    entries.removeAll { ($0["command"] as? String)?.contains("nb-hook") == true }
                    if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
                }
            }
            if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: root,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - Muse Code hook installer

    static var museSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/muse/settings.json")
    }

    /// True when ~/.config/muse/settings.json already routes Muse events to Coucou's nb-hook.
    static func museHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: museSettingsURL),
              let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        for value in hooks.values {
            guard let groups = value as? [[String: Any]] else { continue }
            for group in groups {
                if let innerHooks = group["hooks"] as? [[String: Any]] {
                    for h in innerHooks {
                        if let cmd = h["command"] as? String,
                           cmd.contains("nb-hook"), cmd.contains("--agent muse") { return true }
                    }
                }
                if let cmd = group["command"] as? String,
                   cmd.contains("nb-hook"), cmd.contains("--agent muse") { return true }
            }
        }
        return false
    }

    private var _pendingMuseData: Data?
    private var _pendingMuseFingerprint: String?

    func previewMuseHooks(install: Bool) throws -> String {
        let url = Self.museSettingsURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install && !exists {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "No Muse Code hooks to remove."
            ])
        }
        let current = exists ? try Data(contentsOf: url) : Data()
        _pendingMuseFingerprint = sha256Hex(current)
        let newData = install ? try buildMuseHooksData() : try withoutMuseHooks()
        _pendingMuseData = newData
        return String(data: newData, encoding: .utf8) ?? ""
    }

    func writeMuseHooks() throws {
        guard let data = _pendingMuseData, let fp = _pendingMuseFingerprint else { return }
        let url = Self.museSettingsURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json changed since preview. Refresh and try again."
            ])
        }
        try writeJSONFile(data, to: url, suffix: "settings.json")
        _pendingMuseData = nil
        _pendingMuseFingerprint = nil
    }

    private func buildMuseHooksData() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.museSettingsURL,
                                                      label: "~/.config/muse/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        let base = hookBase()
        // Muse uses PascalCase events. Timeouts in milliseconds (seconds × 1000).
        let events: [(String, Int)] = [
            ("SessionStart",      10),
            ("UserPromptSubmit",   5),
            ("PreToolUse",         5),
            ("PermissionRequest", 120),
            ("PostToolUse",        5),
            ("Stop",               5),
            ("SessionEnd",         3),
        ]
        let isNew = !FileManager.default.fileExists(atPath: Self.museSettingsURL.path)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeoutSec) in events {
            if let raw = hooks[event], !(raw is [[String: Any]]) {
                throw NSError(domain: "Coucou", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\"[\"\(event)\"] has an unexpected type — Coucou has not touched it."
                ])
            }
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = removeNbHookEntries(from: groups)
            let hookEntry: [String: Any] = [
                "type": "command",
                "command": "\(base) --agent muse \(event)",
                "timeout": timeoutSec * 1000,
            ]
            groups.append(["matcher": "*", "hooks": [hookEntry]])
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        if isNew { settings["schema_version"] = 1 }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private func withoutMuseHooks() throws -> Data {
        var settings = try Self.strictReadJSONObject(at: Self.museSettingsURL,
                                                      label: "~/.config/muse/settings.json")
        if let raw = settings["hooks"], !(raw is [String: Any]) {
            throw NSError(domain: "Coucou", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/muse/settings.json: \"hooks\" has an unexpected type — Coucou has not touched it."
            ])
        }
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in hooks.keys {
                if let groups = hooks[key] as? [[String: Any]] {
                    let cleaned = removeNbHookEntries(from: groups)
                    if cleaned.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = cleaned }
                }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        return try JSONSerialization.data(withJSONObject: settings,
                                         options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    // MARK: - OpenCode plugin installer

    private var _pendingOpenCodeContent: String?
    private var _pendingOpenCodeFingerprint: String?

    static var openCodePluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/opencode/plugins/coucou.js")
    }

    static func openCodePluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: openCodePluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("opencode")
    }

    private func buildOpenCodePluginContent() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
// Coucou hook plugin for OpenCode — generated by Coucou.app
// Forwards every event to the Coucou notch (fire-and-forget, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';
const EVENT_MAP = {
  'session.created': 'SessionStart',
  'session.idle': 'Stop',
  'session.error': 'StopFailure',
  'session.deleted': 'SessionEnd',
  'permission.asked': 'PermissionRequest',
};

function forward(hook_event_name, payload) {
  const p = spawn('/bin/sh', [HOOK, '--agent', 'opencode'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  p.stdin.on('error', () => {});
  p.stdin.write(JSON.stringify({ hook_event_name, ...payload }) + '\\n');
  p.stdin.end();
  p.unref();
}

export const CoucouPlugin = async (_ctx) => ({
  event: async ({ event }) => {
    const hook_event_name = EVENT_MAP[event.type];
    if (!hook_event_name) return;
    const props = event.properties || {};
    const payload = {
      session_id: event.sessionID || event.session_id || props.sessionID || props.session_id || '',
      cwd: event.cwd || event.directory || props.cwd || props.directory || '',
    };
    if (typeof props.tool === 'string') payload.tool_name = props.tool;
    if (props.input != null) payload.tool_input = props.input;
    forward(hook_event_name, payload);
  },
  'tool.execute.before': async (input) => {
    forward('PreToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
      tool_input: input.input ?? null,
    });
  },
  'tool.execute.after': async (input, _output) => {
    forward('PostToolUse', {
      session_id: input.sessionID || input.session_id || '',
      cwd: input.cwd || '',
      tool_name: typeof input.tool === 'string' ? input.tool : '',
    });
  },
});
"""
    }

    func previewOpenCodePlugin(install: Bool) throws -> String {
        let url = Self.openCodePluginURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install {
            guard exists else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No OpenCode plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: url)) ?? Data()
            _pendingOpenCodeFingerprint = sha256Hex(current)
            _pendingOpenCodeContent = nil
            return "(will delete \(url.path))"
        }
        let current = exists ? (try? Data(contentsOf: url)) ?? Data() : Data()
        _pendingOpenCodeFingerprint = sha256Hex(current)
        let content = buildOpenCodePluginContent()
        _pendingOpenCodeContent = content
        return content
    }

    func writeOpenCodePlugin() throws {
        guard let fp = _pendingOpenCodeFingerprint else { return }
        let url = Self.openCodePluginURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/opencode/plugins/coucou.js changed since preview. Refresh and try again."
            ])
        }
        guard let content = _pendingOpenCodeContent else {
            // Uninstall path: checked by removeOpenCodePlugin
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("coucou.js.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: backupURL)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingOpenCodeContent = nil
        _pendingOpenCodeFingerprint = nil
    }

    func removeOpenCodePlugin() throws {
        let url = Self.openCodePluginURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/opencode/plugins/coucou.js was not generated by Coucou — not deleting it."
            ])
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Amp plugin installer

    private var _pendingAmpContent: String?
    private var _pendingAmpFingerprint: String?

    static var ampPluginURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/amp/plugins/coucou.ts")
    }

    static func ampPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: ampPluginURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("'amp'")
    }

    private func buildAmpPluginContent() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
// Coucou hook plugin for Amp — generated by Coucou.app
// Forwards every event to the Coucou notch (display only, never blocks).
import { spawn } from 'node:child_process';

const HOOK = '\(path)';

function forward(event_name: string, fields: Record<string, unknown>): void {
  const payload = JSON.stringify({ hook_event_name: event_name, ...fields });
  const p = spawn('/bin/sh', [HOOK, '--agent', 'amp'],
                  { stdio: ['pipe', 'ignore', 'ignore'], detached: true });
  p.on('error', () => {});
  (p.stdin as import('node:stream').Writable).on('error', () => {});
  (p.stdin as import('node:stream').Writable).write(payload + '\\n');
  (p.stdin as import('node:stream').Writable).end();
  p.unref();
}

export default function (amp: any): void {
  amp.on('session.start', (e: any) => { forward('SessionStart',     { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.start',   (e: any) => { forward('UserPromptSubmit', { session_id: e.thread?.id ?? '' }); });
  amp.on('tool.call',     (e: any) => { try { forward('PreToolUse', { session_id: e.thread?.id ?? '', tool_name: typeof e.tool === 'string' ? e.tool : '' }); } finally { return { action: 'allow' }; } });
  amp.on('tool.result',   (e: any) => { forward('PostToolUse',      { session_id: e.thread?.id ?? '' }); });
  amp.on('agent.end',     (e: any) => { forward('Stop',             { session_id: e.thread?.id ?? '' }); });
}
"""
    }

    func previewAmpPlugin(install: Bool) throws -> String {
        let url = Self.ampPluginURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !install {
            guard exists else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No Amp plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: url)) ?? Data()
            _pendingAmpFingerprint = sha256Hex(current)
            _pendingAmpContent = nil
            return "(will delete \(url.path))"
        }
        let current = exists ? (try? Data(contentsOf: url)) ?? Data() : Data()
        _pendingAmpFingerprint = sha256Hex(current)
        let content = buildAmpPluginContent()
        _pendingAmpContent = content
        return content
    }

    func writeAmpPlugin() throws {
        guard let fp = _pendingAmpFingerprint else { return }
        let url = Self.ampPluginURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/amp/plugins/coucou.ts changed since preview. Refresh and try again."
            ])
        }
        guard let content = _pendingAmpContent else {
            // Uninstall path: checked by removeAmpPlugin
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("coucou.ts.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: backupURL)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingAmpContent = nil
        _pendingAmpFingerprint = nil
    }

    func removeAmpPlugin() throws {
        let url = Self.ampPluginURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.config/amp/plugins/coucou.ts was not generated by Coucou — not deleting it."
            ])
        }
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Hermes plugin installer

    private var _pendingHermesPluginContent: String?
    private var _pendingHermesPluginFingerprint: String?
    private var _pendingHermesConfigContent: String?
    private var _pendingHermesConfigFingerprint: String?

    static var hermesPluginDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/plugins/coucou")
    }
    static var hermesInitPyURL: URL { hermesPluginDir.appendingPathComponent("__init__.py") }
    static var hermesPluginYamlURL: URL { hermesPluginDir.appendingPathComponent("plugin.yaml") }
    static var hermesConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml")
    }

    static func hermesPluginInstalled() -> Bool {
        guard let content = try? String(contentsOf: hermesInitPyURL, encoding: .utf8) else { return false }
        return content.contains("nb-hook") && content.contains("hermes")
    }

    /// Why the approvals toggle can or cannot be used.
    typealias HermesApprovalSupport = HermesDetect.Support

    #if !APPSTORE
    /// Finds the `hermes` executable in PATH and common install locations.
    private static func hermesExecutablePath() -> String? {
        // Try PATH via `which` first
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["hermes"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError  = Pipe()
        if (try? which.run()) != nil {
            which.waitUntilExit()
            if which.terminationStatus == 0 {
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !out.isEmpty && FileManager.default.isExecutableFile(atPath: out) { return out }
            }
        }
        // Explicit common locations
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for candidate in [
            "\(home)/.local/bin/hermes",
            "\(home)/.hermes/bin/hermes",
            "/usr/local/bin/hermes",
            "/opt/homebrew/bin/hermes",
        ] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Reads the first 4 KB of a file as text (nil when unreadable or not UTF-8, e.g. a Mach-O binary).
    private static func headOfFile(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        // Lenient decode: a cut inside a multi-byte character must not lose the whole launcher text.
        let data = fh.readData(ofLength: 4096)
        if data.contains(0) { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs `executable args...` with a 3-second limit. Returns (exit status, stdout), nil when it can't start or times out.
    private static func runWithTimeout(_ executable: String, _ args: [String]) -> (status: Int32, output: String)? {
        let task = Process(); let out = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardOutput = out; task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global(qos: .background).async { task.waitUntilExit(); group.leave() }
        if group.wait(timeout: .now() + 3) == .timedOut { task.terminate(); return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, text)
    }

    /// Whether the installed Hermes exposes the approval transport. The decision lives in `HermesDetect.decide`
    /// (unit-tested); this only wires it to the disk and to `Process`: the interpreter of the Hermes launcher runs
    /// `-I -c "import ..." <install dir>`, 3 s per attempt, never the system python3. Fails closed.
    static func hermesApprovalSupport() -> HermesApprovalSupport {
        let hermesPath = hermesExecutablePath()
        return HermesDetect.decide(
            hermesPath: hermesPath,
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            readFile: { headOfFile($0) },
            exists: { FileManager.default.isExecutableFile(atPath: $0) },
            runImport: { python, dir in
                runWithTimeout(python, HermesDetect.importArguments(installDir: dir))?.status == 0
            },
            versionOutput: { hermesPath.flatMap { runWithTimeout($0, ["--version"])?.output } })
    }

    static func hermesSupportsApprovalTransport() -> Bool { hermesApprovalSupport() == .supported }
    #endif

    private func buildHermesInitPy() -> String {
        let path = Self.hookScriptPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return """
# Coucou hook plugin for Hermes Agent — generated by Coucou.app
# Session/tool events → Coucou notch (fire-and-forget, never blocks).
# Approval transport: uses register_approval_transport when available (future Hermes),
# falls back to pre_approval_request observer-only hook (hermes 0.15.x).
import json, subprocess, threading
from pathlib import Path

HOOK = Path('\(path)')
_lock = threading.Lock()
# Maps session_id → metadata dict. Keeps correct session when multiple
# sessions run concurrently (gateway mode). _current_session_id is kept as
# a last-seen fallback for hooks that don't supply a session_id.
_sessions: dict = {}
_current_session_id = ''


def _fire(fields: dict) -> None:
    \"\"\"Non-blocking: spawn nb-hook and return immediately. Reaps child to avoid zombies.\"\"\"
    def _run() -> None:
        try:
            p = subprocess.Popen(
                [str(HOOK), '--agent', 'hermes'],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,   # detach from process group
            )
            p.stdin.write(json.dumps(fields).encode() + b'\\n')
            p.stdin.close()
            p.wait(timeout=5)             # reap; 5s >> the 0.3s socket timeout
        except Exception:
            pass
    threading.Thread(target=_run, daemon=True).start()


def register(ctx) -> None:
    def on_session_start(**kwargs) -> None:
        global _current_session_id
        sid = kwargs.get('session_id', '')
        meta = {
            'model': kwargs.get('model', ''),
            'platform': kwargs.get('platform', 'cli') or 'cli',
        }
        with _lock:
            _sessions[sid] = meta
            _current_session_id = sid
        _fire({'hook_event_name': 'SessionStart', 'session_id': sid, 'platform': meta['platform']})

    def on_session_end(**kwargs) -> None:
        sid = kwargs.get('session_id', '')
        with _lock:
            _sessions.pop(sid, None)
        # Stop is sent by post_llm_call (which has the last assistant message).
        # Only send StopFailure here when the session was interrupted abnormally.
        if kwargs.get('interrupted'):
            _fire({'hook_event_name': 'StopFailure', 'session_id': sid})

    def post_llm_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        response = kwargs.get('assistant_response', '')
        _fire({
            'hook_event_name': 'Stop',
            'session_id': sid,
            'last_assistant_message': response,
        })

    def pre_tool_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        _fire({
            'hook_event_name': 'PreToolUse',
            'session_id': sid,
            'tool_name': kwargs.get('tool_name', ''),
            'tool_input': kwargs.get('args') or {},
        })

    def post_tool_call(**kwargs) -> None:
        sid = kwargs.get('session_id', '') or _current_session_id
        _fire({
            'hook_event_name': 'PostToolUse',
            'session_id': sid,
            'tool_name': kwargs.get('tool_name', ''),
        })

    ctx.register_hook('on_session_start', on_session_start)
    ctx.register_hook('on_session_end',   on_session_end)
    ctx.register_hook('post_llm_call',    post_llm_call)
    ctx.register_hook('pre_tool_call',    pre_tool_call)
    ctx.register_hook('post_tool_call',   post_tool_call)

    if hasattr(ctx, 'register_approval_transport'):
        # Hermes version supports transport API — Coucou shows a real Allow/Deny card
        # and returns the user's choice to Hermes.
        def _present(request) -> object:
            sid = (getattr(request, 'session_id', None)
                   or getattr(request, 'session_key', None)
                   or _current_session_id)
            cmd     = getattr(request, 'command', '')
            desc    = getattr(request, 'description', '')
            timeout = getattr(request, 'timeout_seconds',
                              getattr(request, 'timeout', 30.0))
            allowed = list(getattr(request, 'allowed_choices', ('once', 'deny')))

            payload = json.dumps({
                'hook_event_name': 'PermissionRequest',
                'session_id': sid,
                'coucou_agent': 'hermes',
                'coucou_has_transport': True,
                'tool_name': cmd,
                'tool_input': {'command': cmd, 'description': desc},
            }).encode()
            try:
                result = subprocess.run(
                    [str(HOOK), '--agent', 'hermes'],
                    input=payload,
                    capture_output=True,
                    timeout=max(1.0, float(timeout) - 2.0),
                )
                data   = json.loads(result.stdout)
                choice = data['choice']
                if choice not in allowed:
                    raise ValueError(f'invalid choice: {choice!r}')
                return request.respond(choice)
            except Exception:
                # Fall back to Hermes' native prompt on any error.
                return request.respond('deny')

        ctx.register_approval_transport('coucou', _present)
    else:
        # Observer-only hook (hermes 0.15.x): Hermes still controls the decision.
        # Fire a PreToolUse-style step so the notch shows "⏳ Approval pending in Hermes"
        # in the step list without displaying a fake Allow/Deny card.
        def pre_approval_request(**kwargs) -> None:
            sid = kwargs.get('session_key', '') or _current_session_id
            _fire({
                'hook_event_name': 'PreToolUse',
                'session_id': sid,
                'tool_name': '⏳ Approval pending in Hermes',
                'tool_input': {
                    'command': kwargs.get('command', ''),
                    'description': kwargs.get('description', ''),
                },
            })

        ctx.register_hook('pre_approval_request', pre_approval_request)
"""
    }

    private static let hermesPluginYaml = """
name: coucou
version: "1.0"
description: Coucou notch integration — generated by Coucou.app
"""

    /// Merges Coucou keys into a Hermes config.yaml string without touching other settings.
    ///
    /// Returns the merged YAML string, or nil if the file uses an unsupported structure
    /// (flow maps `{…}`, YAML anchors `&`, multi-document `---`) that the line-level
    /// merger cannot safely handle. Callers should surface an error with the lines
    /// the user needs to add manually.
    ///
    /// Plugin enablement (plugins.enabled) is handled by the `hermes plugins enable/disable`
    /// CLI after the plugin files are written; this function only manages security.approval.
    static func mergedHermesConfig(_ base: String, enableApprovals: Bool) -> String? {
        // Reject structures the simple merger cannot handle safely.
        // Flow maps, anchors, and multi-document markers require a full YAML parser.
        let unsafePatterns = ["{", " &", "\n---"]
        for p in unsafePatterns where base.contains(p) {
            return nil
        }

        var lines = base.components(separatedBy: "\n")

        // Detect file indentation: look for the first indented line and count spaces.
        let indent: Int = {
            for line in lines {
                let leading = line.prefix(while: { $0 == " " }).count
                if leading > 0 && leading <= 8 { return leading }
            }
            return 2  // default
        }()
        let ind  = String(repeating: " ", count: indent)         // e.g. "  " (2) or "    " (4)
        let ind2 = String(repeating: " ", count: indent * 2)     // one extra level

        // Returns the index of the first top-level section header line matching `key`.
        // Top-level = no leading spaces, ends with `:` (optionally with trailing space/comment).
        func topLevelIndex(key: String) -> Int? {
            lines.firstIndex { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix(" ") && !line.hasPrefix("\t") else { return false }
                return t == "\(key):" || t.hasPrefix("\(key):")
            }
        }

        // Returns the range of lines that belong to a top-level section (from its header to
        // just before the next top-level section, or the end of the array).
        func sectionRange(from sectionIdx: Int) -> Range<Int> {
            var end = sectionIdx + 1
            while end < lines.count {
                let l = lines[end]
                // A new top-level key: not blank, not a comment, no leading whitespace
                if !l.isEmpty && !l.hasPrefix("#") && !l.hasPrefix(" ") && !l.hasPrefix("\t") {
                    break
                }
                end += 1
            }
            return sectionIdx ..< end
        }

        // --- security.approval ---
        let transportLine = "\(ind2)transport: coucou"
        let fallbackLine  = "\(ind2)transport_fallback: builtin"

        func ensureApprovalTransport() {
            if let secIdx = topLevelIndex(key: "security") {
                let secRange = sectionRange(from: secIdx)
                // Look for approval: within the security section (must be indented)
                if let approvalIdx = (secRange.lowerBound + 1 ..< secRange.upperBound)
                    .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("approval:") }) {
                    // approval: block exists — update or add transport keys within it
                    let approvalRange = sectionRange(from: approvalIdx)
                    var hasTransport = false
                    var hasFallback  = false
                    for i in (approvalRange.lowerBound + 1 ..< approvalRange.upperBound) {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("transport:") && !t.hasPrefix("transport_fallback") {
                            lines[i] = transportLine; hasTransport = true
                        } else if t.hasPrefix("transport_fallback:") {
                            lines[i] = fallbackLine; hasFallback = true
                        }
                    }
                    let insertAt = approvalRange.lowerBound + 1
                    if !hasFallback  { lines.insert(fallbackLine,  at: insertAt) }
                    if !hasTransport { lines.insert(transportLine, at: insertAt) }
                } else {
                    // No approval: key — insert right after security:
                    let insertAt = secIdx + 1
                    lines.insert("\(ind)approval:", at: insertAt)
                    lines.insert(transportLine,     at: insertAt + 1)
                    lines.insert(fallbackLine,      at: insertAt + 2)
                }
            } else {
                // No security: section — append
                if lines.last != "" { lines.append("") }
                lines.append("security:")
                lines.append("\(ind)approval:")
                lines.append(transportLine)
                lines.append(fallbackLine)
            }
        }

        func removeApprovalTransport() {
            // Only remove exact Coucou-written transport keys; don't touch unrelated keys.
            lines.removeAll { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t == "transport: coucou" || t == "transport_fallback: builtin"
            }
        }

        // --- plugins.enabled ---
        // Note: actual plugin enable/disable is done via `hermes plugins enable/disable coucou`
        // CLI after writing/removing the plugin files. This block ensures the preview
        // shows the complete intended state of config.yaml.
        func ensureCoucouPlugin() {
            // "Already present" = coucou in the plugins.enabled list specifically.
            // Check by finding plugins: section first, then enabled: sub-key within it.
            if let pluginsIdx = topLevelIndex(key: "plugins") {
                let pluginsRange = sectionRange(from: pluginsIdx)
                // Find enabled: within the plugins section
                if let enabledIdx = (pluginsRange.lowerBound + 1 ..< pluginsRange.upperBound)
                    .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("enabled:") }) {
                    let enabledLine = lines[enabledIdx]
                    let trimmed = enabledLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains("[") && trimmed.contains("]") {
                        // Inline list: enabled: [x, y]  or  enabled: []
                        if trimmed.contains("coucou") { return }   // already present
                        if trimmed == "enabled: []" || trimmed == "enabled:[]" {
                            // Empty inline list → expand to block entry
                            let prefix = enabledLine.prefix(while: { $0 == " " })
                            lines[enabledIdx] = "\(prefix)enabled:"
                            lines.insert("\(prefix)\(ind)- coucou", at: enabledIdx + 1)
                        } else {
                            lines[enabledIdx] = enabledLine.replacingOccurrences(of: "]", with: ", coucou]")
                        }
                    } else {
                        // Block list — check if coucou is already a child of this enabled:
                        let enabledRange = sectionRange(from: enabledIdx)
                        let alreadyPresent = (enabledRange.lowerBound + 1 ..< enabledRange.upperBound)
                            .contains { lines[$0].trimmingCharacters(in: .whitespaces) == "- coucou" }
                        if alreadyPresent { return }
                        // Insert after enabled:
                        let prefix = enabledLine.prefix(while: { $0 == " " })
                        lines.insert("\(prefix)\(ind)- coucou", at: enabledIdx + 1)
                    }
                } else {
                    // No enabled: key under plugins: — insert after plugins:
                    lines.insert("\(ind)enabled:", at: pluginsIdx + 1)
                    lines.insert("\(ind)\(ind)- coucou", at: pluginsIdx + 2)
                }
            } else {
                // No plugins: section — append
                if lines.last != "" { lines.append("") }
                lines.append("plugins:")
                lines.append("\(ind)enabled:")
                lines.append("\(ind)\(ind)- coucou")
            }
        }

        func removeCoucouPlugin() {
            // Remove the `- coucou` entry from plugins.enabled only.
            // If that leaves enabled: with no entries, leave the key in place (don't remove it).
            guard let pluginsIdx = topLevelIndex(key: "plugins") else { return }
            let pluginsRange = sectionRange(from: pluginsIdx)
            guard let enabledIdx = (pluginsRange.lowerBound + 1 ..< pluginsRange.upperBound)
                .first(where: { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("enabled:") })
            else { return }
            let enabledLine = lines[enabledIdx]
            let trimmed = enabledLine.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("[") && trimmed.contains("]") {
                // Inline list: remove coucou from it
                let cleaned = trimmed
                    .replacingOccurrences(of: ", coucou", with: "")
                    .replacingOccurrences(of: "coucou, ", with: "")
                    .replacingOccurrences(of: "coucou",   with: "")
                let prefix = enabledLine.prefix(while: { $0 == " " })
                lines[enabledIdx] = "\(prefix)\(cleaned)"
            } else {
                // Block list: remove the `- coucou` entry
                let enabledRange = sectionRange(from: enabledIdx)
                // Collect indices to remove first, then remove in reverse to preserve indices.
                let toRemove = (enabledRange.lowerBound + 1 ..< enabledRange.upperBound)
                    .filter { lines[$0].trimmingCharacters(in: .whitespaces) == "- coucou" }
                for i in toRemove.reversed() { lines.remove(at: i) }
            }
        }

        ensureCoucouPlugin()
        if enableApprovals { ensureApprovalTransport() } else { removeApprovalTransport() }
        return lines.joined(separator: "\n")
    }

    func previewHermesPlugin(install: Bool) throws -> String {
        if !install {
            guard FileManager.default.fileExists(atPath: Self.hermesInitPyURL.path) else {
                throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                    NSLocalizedDescriptionKey: "No Hermes plugin to remove."
                ])
            }
            let current = (try? Data(contentsOf: Self.hermesInitPyURL)) ?? Data()
            _pendingHermesPluginFingerprint = sha256Hex(current)
            _pendingHermesPluginContent = nil
            return "(will delete \(Self.hermesInitPyURL.path))"
        }
        let current = (try? Data(contentsOf: Self.hermesInitPyURL)) ?? Data()
        _pendingHermesPluginFingerprint = sha256Hex(current)
        let content = buildHermesInitPy()
        _pendingHermesPluginContent = content
        return content
    }

    func writeHermesPlugin() throws {
        guard let fp = _pendingHermesPluginFingerprint else { return }
        let url = Self.hermesInitPyURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/plugins/coucou/__init__.py changed since preview. Refresh and try again."
            ])
        }
        let fm = FileManager.default
        if let content = _pendingHermesPluginContent {
            try fm.createDirectory(at: Self.hermesPluginDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "yyyyMMdd-HHmmss"
                let bak = url.deletingLastPathComponent()
                    .appendingPathComponent("__init__.py.bak-\(fmt.string(from: Date()))")
                try fm.copyItem(at: url, to: bak)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            try Self.hermesPluginYaml.write(to: Self.hermesPluginYamlURL, atomically: true, encoding: .utf8)
            // Register the plugin with the Hermes CLI so it appears in plugins.enabled.
            // Best-effort — silently ignored if hermes is not on PATH.
            try? Self.runHermesCLI(["plugins", "enable", "coucou"])
        }
        _pendingHermesPluginContent = nil
        _pendingHermesPluginFingerprint = nil
    }

    func removeHermesPlugin() throws {
        let url = Self.hermesInitPyURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard content.contains("generated by Coucou") else {
            throw NSError(domain: "Coucou", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/plugins/coucou/__init__.py was not generated by Coucou — not deleting it."
            ])
        }
        // Remove from hermes plugins.enabled first, then delete the files.
        // Best-effort — silently ignored if hermes is not on PATH.
        try? Self.runHermesCLI(["plugins", "disable", "coucou"])
        try FileManager.default.removeItem(at: Self.hermesPluginDir)
    }

    /// Invoke the Hermes CLI with the given arguments.
    /// Searches standard PATH locations for the `hermes` binary.
    @discardableResult
    private static func runHermesCLI(_ args: [String]) throws -> String {
        let hermesPaths = [
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
            "/usr/bin/hermes",
            (ProcessInfo.processInfo.environment["HOME"] ?? "") + "/.local/bin/hermes",
        ]
        guard let hermesBin = hermesPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "CoucouNoop", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "hermes CLI not found."
            ])
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hermesBin)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError  = Pipe()   // discard stderr
        try proc.run()
        proc.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    func previewHermesConfig(enableApprovals: Bool, supportsTransport: Bool) throws -> String {
        let base = (try? String(contentsOf: Self.hermesConfigURL, encoding: .utf8)) ?? ""
        let current = (try? Data(contentsOf: Self.hermesConfigURL)) ?? Data()
        _pendingHermesConfigFingerprint = sha256Hex(current)
        let effectiveApprovals = enableApprovals && supportsTransport
        guard let merged = Self.mergedHermesConfig(base, enableApprovals: effectiveApprovals) else {
            _pendingHermesConfigContent = nil
            throw NSError(domain: "Coucou", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/config.yaml uses an unsupported structure (flow maps, YAML anchors, or multi-document). Edit it manually and add:\n  security:\n    approval:\n      transport: coucou\n      transport_fallback: builtin"
            ])
        }
        _pendingHermesConfigContent = merged
        return merged
    }

    func writeHermesConfig() throws {
        guard let fp = _pendingHermesConfigFingerprint,
              let content = _pendingHermesConfigContent else { return }
        let url = Self.hermesConfigURL
        let current = (try? Data(contentsOf: url)) ?? Data()
        guard sha256Hex(current) == fp else {
            throw NSError(domain: "Coucou", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "~/.hermes/config.yaml changed since preview. Refresh and try again."
            ])
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let bak = url.deletingLastPathComponent()
                .appendingPathComponent("config.yaml.bak-\(fmt.string(from: Date()))")
            try fm.copyItem(at: url, to: bak)
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        _pendingHermesConfigContent = nil
        _pendingHermesConfigFingerprint = nil
    }

    // MARK: SHA-256 fingerprint

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
    /// A finished Hermes answer opens the collapsed island: like `hookExpand`, then the island closes by itself.
    static let hermesAnnounceExpand = Notification.Name("notchBuddy.hermesAnnounceExpand")
}

// MARK: - nb-hook shell wrapper (same for both GitHub and App Store)
// Invoked by Claude Code via /bin/sh or directly via shebang.
// Always exits 0 — never blocks Claude Code.
// On macOS, checks xcode-select before running python3 to avoid triggering the
// "install developer tools" dialog on machines without Xcode CLI tools.
// Elsewhere (the hook copied to a Linux machine reached over SSH, docs/REMOTE.md)
// it runs the python3 found in PATH.

private let nbHookShellWrapper = """
#!/bin/sh
# Coucou hook relay — always exits 0, never blocks Claude Code
HOOK_DIR="$(dirname "$0")"
PY=""
if [ "$(uname -s)" = "Darwin" ]; then
    xcode-select -p >/dev/null 2>&1 && PY=/usr/bin/python3
else
    PY=$(command -v python3 2>/dev/null)
fi
out=""
if [ -n "$PY" ]; then
    out=$("$PY" "$HOOK_DIR/nb-hook.py" "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        out=""
    fi
fi
if [ -n "$out" ]; then
    printf '%s\\n' "$out"
else
    # Copilot is fail-closed — must always output valid JSON even when python3 is absent or crashes.
    _cop=0; _perm=0
    for _a in "$@"; do
        case "$_a" in
            copilot) _cop=1 ;;
            permissionRequest|PermissionRequest) _perm=1 ;;
        esac
    done
    if [ "$_cop" -eq 1 ]; then
        if [ "$_perm" -eq 1 ]; then
            printf '{"permissionDecision":"ask"}\\n'
        else
            printf '{}\\n'
        fi
    fi
fi
exit 0
"""

// MARK: - nb-hook Python relay (GitHub / non-sandboxed version)

private let nbHookPythonGitHub = """
#!/usr/bin/env python3
# nb-hook.py — Coucou hook relay for Claude Code and third-party agents (GitHub version)
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def add_cmux_context(payload, env):
    sid = env.get('CMUX_SURFACE_ID', '')
    if not sid:
        return
    payload.setdefault('cmux_surface_id', sid)
    payload.setdefault('cmux_workspace_id', env.get('CMUX_WORKSPACE_ID', ''))
    payload.setdefault('cmux_socket_path', env.get('CMUX_SOCKET_PATH', ''))
    payload.setdefault('cmux_socket_capability', env.get('CMUX_SOCKET_CAPABILITY', ''))

def add_session_name(payload):
    # Name the pill after the session's title, else the folder the session started in,
    # not the current cwd (the agent may cd into subfolders). Both come from the
    # transcript: its first lines, and its last custom-title entry (/rename), else its
    # last ai-title one (the title Claude Code gives a session; VS Code sessions only
    # have that). Entries are told by their type: a message that merely quotes one is not
    # a title. Claude Code writes the title again every 40-80 KB, hence a 256 KB tail.
    path = payload.get('transcript_path') or ''
    if not path:
        return
    try:
        with open(path, 'rb') as f:
            for line in f.read(16384).splitlines():
                try:
                    root = json.loads(line).get('cwd')
                except Exception:
                    continue
                if root:
                    payload['session_root'] = root
                    break
            f.seek(0, os.SEEK_END)
            start = max(0, f.tell() - 262144)
            f.seek(start)
            lines = f.read().splitlines()
            ai_title = ''
            for line in reversed(lines[1:] if start else lines):
                if b'"type":"custom-title"' not in line and b'"type":"ai-title"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get('type') == 'custom-title' and entry.get('customTitle'):
                    payload['session_title'] = entry['customTitle']
                    return
                if entry.get('type') == 'ai-title' and not ai_title:
                    ai_title = entry.get('aiTitle') or ''
            if ai_title:
                payload['session_title'] = ai_title
    except Exception:
        pass

def term_program(env):
    # VS Code's Claude Code extension on a remote machine (Remote - SSH) has neither
    # TERM_PROGRAM nor the app's bundle ID; its entrypoint still says where it runs.
    term = env.get('TERM_PROGRAM', '')
    if not term and not env.get('__CFBundleIdentifier') and env.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-vscode':
        return 'vscode'
    return term

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    # COUCOU_SOCKET points the relay at another socket, for instance the one an
    # `ssh -R` tunnel forwards from the Mac to a remote machine (docs/REMOTE.md).
    socket_path = os.path.expanduser(
        os.environ.get('COUCOU_SOCKET') or '~/Library/Application Support/NotchBuddy/nb.sock'
    )

    # --statusline mode: relay rate_limits to Coucou, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'coucou_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(socket_path)
            s.sendall((json.dumps(relay) + '\\n').encode())
            s.close()
        except Exception:
            pass
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        if os.path.exists(prev_file):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['coucou_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', term_program(env))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        add_cmux_context(payload, env)
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        add_session_name(payload)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'answer':
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code asks in terminal
        except Exception:
            pass
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with coucou_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('coucou_agent', agent)
    # Claude Code sessions from the Claude desktop app (Code tab) report this entrypoint;
    # route them to the Claude Desktop pill instead of dropping them (no VS Code terminal).
    if not payload.get('coucou_agent') and os.environ.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-desktop':
        payload['coucou_agent'] = 'claude-desktop'

    # Enrich with terminal context
    env = os.environ
    payload.setdefault('term_program', term_program(env))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    add_cmux_context(payload, env)
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()
    add_session_name(payload)

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    # socket_path is already defined above

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if agent == 'hermes':
                    hermes_choice = 'once' if decision == 'allow' else decision
                    if hermes_choice in ('once', 'always', 'deny'):
                        sys.stdout.write(json.dumps({'choice': hermes_choice}) + '\\n')
                        sys.stdout.flush()
                    sys.exit(0)
                if decision in ('allow', 'always'):
                    # Copilot/Muse use {"permissionDecision":"allow"} directly
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'allow'}
                    elif decision == 'always' and agent != 'codex':
                        # Let Claude Code persist the rule via updatedPermissions
                        suggestions = payload.get('permission_suggestions', [])
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    else:
                        # Claude Code / Codex plain allow
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    # Claude Code ignores an allow for ExitPlanMode without updatedInput (Allow and Always).
                    if payload.get('tool_name') == 'ExitPlanMode' and 'hookSpecificOutput' in out:
                        out['hookSpecificOutput']['decision']['updatedInput'] = payload.get('tool_input', {})
                        # Mode picked on the plan card: same choice as the terminal's plan dialog.
                        mode = resp_obj.get('mode')
                        if mode in ('auto', 'default'):
                            out['hookSpecificOutput']['decision']['updatedPermissions'] = [{'type': 'setMode', 'mode': mode, 'destination': 'session'}]
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'deny'}
                    else:
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'answer':
                    # AskUserQuestion answered from the notch
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'change_plan':
                    # Plan card "Change plan": like the terminal's "Tell Claude what to change",
                    # reject the plan and stop Claude so the prompt is free for the change.
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'interrupt': True, 'message': 'The user wants to change the plan and will type the changes in the terminal.'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        # Hermes: no output → json.loads raises in plugin → transport_fallback: builtin activates
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\\n')
            sys.stdout.flush()
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Antigravity needs a decision on PreToolUse ({} reads as a denial). "ask" keeps its own
    # permission prompt (and the user's Always Allow); Coucou never allows a tool by itself.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)
"""

// MARK: - nb-hook Python relay (App Store — socket in sandboxed container)

private let nbHookPythonAppStore = """
#!/usr/bin/env python3
# nb-hook.py — Coucou (App Store) hook relay for Claude Code and third-party agents
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket

def normalize_event(name):
    mapping = {
        'BeforeTool': 'PreToolUse', 'BeforeToolSelection': 'PreToolUse',
        'AfterTool': 'PostToolUse', 'AfterModel': 'PostToolUse',
        'BeforeAgent': 'UserPromptSubmit', 'AfterAgent': 'Stop',
        'startup': 'SessionStart', 'exit': 'SessionEnd',
        'PreInvocation': 'UserPromptSubmit', 'PostInvocation': 'PostToolUse',
        'pre_tool_use': 'PreToolUse', 'post_tool_use': 'PostToolUse',
        'user_prompt_submit': 'UserPromptSubmit', 'session_start': 'SessionStart',
        'session_end': 'SessionEnd', 'stop': 'Stop',
        'sessionStart': 'SessionStart', 'userPromptSubmitted': 'UserPromptSubmit',
        'agentStop': 'Stop', 'notification': 'Notification',
        'preToolUse': 'PreToolUse', 'postToolUse': 'PostToolUse',
        'permissionRequest': 'PermissionRequest', 'sessionEnd': 'SessionEnd',
    }
    return mapping.get(name, name)

def normalize_tool_fields(payload):
    if 'tool_name' not in payload:
        # Copilot sends toolName directly; other agents nest in toolCall
        if payload.get('toolName'):
            payload['tool_name'] = payload['toolName']
        else:
            tool = payload.get('toolCall')
            if not isinstance(tool, dict):
                tool = {}
            name = tool.get('name') or payload.get('tool', '')
            if name:
                payload['tool_name'] = name
    if 'tool_input' not in payload:
        # Copilot sends toolArgs directly
        tool_args = payload.get('toolArgs')
        if isinstance(tool_args, dict):
            payload['tool_input'] = tool_args
        else:
            tool = payload.get('toolCall') or {}
            if isinstance(tool.get('args'), dict):
                flat = dict(tool['args'])
                for src, dst in [('CommandLine', 'command'), ('FilePath', 'file_path'),
                                 ('Path', 'path'), ('Url', 'url'), ('Query', 'query'), ('Pattern', 'pattern')]:
                    if src in flat:
                        flat[dst] = flat[src]
                payload['tool_input'] = flat
    if 'session_id' not in payload:
        for k in ['conversationId', 'conversation_id', 'sessionId', 'GEMINI_SESSION_ID']:
            if payload.get(k):
                payload['session_id'] = payload[k]
                break
        if 'session_id' not in payload:
            sid = os.environ.get('GEMINI_SESSION_ID', '')
            if sid:
                payload['session_id'] = sid
    # Copilot sends workdir for the current working directory
    if not payload.get('cwd') and payload.get('workdir'):
        payload['cwd'] = payload['workdir']

def add_session_name(payload):
    # Name the pill after the session's title, else the folder the session started in,
    # not the current cwd (the agent may cd into subfolders). Both come from the
    # transcript: its first lines, and its last custom-title entry (/rename), else its
    # last ai-title one (the title Claude Code gives a session; VS Code sessions only
    # have that). Entries are told by their type: a message that merely quotes one is not
    # a title. Claude Code writes the title again every 40-80 KB, hence a 256 KB tail.
    path = payload.get('transcript_path') or ''
    if not path:
        return
    try:
        with open(path, 'rb') as f:
            for line in f.read(16384).splitlines():
                try:
                    root = json.loads(line).get('cwd')
                except Exception:
                    continue
                if root:
                    payload['session_root'] = root
                    break
            f.seek(0, os.SEEK_END)
            start = max(0, f.tell() - 262144)
            f.seek(start)
            lines = f.read().splitlines()
            ai_title = ''
            for line in reversed(lines[1:] if start else lines):
                if b'"type":"custom-title"' not in line and b'"type":"ai-title"' not in line:
                    continue
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get('type') == 'custom-title' and entry.get('customTitle'):
                    payload['session_title'] = entry['customTitle']
                    return
                if entry.get('type') == 'ai-title' and not ai_title:
                    ai_title = entry.get('aiTitle') or ''
            if ai_title:
                payload['session_title'] = ai_title
    except Exception:
        pass

def term_program(env):
    # VS Code's Claude Code extension on a remote machine (Remote - SSH) has neither
    # TERM_PROGRAM nor the app's bundle ID; its entrypoint still says where it runs.
    term = env.get('TERM_PROGRAM', '')
    if not term and not env.get('__CFBundleIdentifier') and env.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-vscode':
        return 'vscode'
    return term

def main():
    raw = b''
    payload = {}
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            if '--statusline' not in sys.argv[1:]:
                return
        else:
            payload = json.loads(raw)
    except Exception:
        if '--statusline' not in sys.argv[1:]:
            return

    # COUCOU_SOCKET points the relay at another socket, for instance the one an
    # `ssh -R` tunnel forwards from the Mac to a remote machine (docs/REMOTE.md).
    socket_path = os.path.expanduser(
        os.environ.get('COUCOU_SOCKET') or '~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock'
    )

    # --statusline mode: relay rate_limits to Coucou, then delegate to saved previous
    if '--statusline' in sys.argv[1:]:
        relay = {
            'coucou_kind': 'statusline',
            'session_id': payload.get('session_id', ''),
            'rate_limits': payload.get('rate_limits', {}),
        }
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(socket_path)
            s.sendall((json.dumps(relay) + '\\n').encode())
            s.close()
        except Exception:
            pass
        prev_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'statusline-previous.json')
        if os.path.exists(prev_file):
            try:
                import subprocess
                with open(prev_file) as f:
                    prev = json.load(f)
                cmd = prev.get('command', '')
                if cmd:
                    result = subprocess.run(['/bin/sh', '-c', cmd], input=raw,
                                             capture_output=True, timeout=10)
                    if result.stdout:
                        sys.stdout.buffer.write(result.stdout)
                        sys.stdout.buffer.flush()
            except Exception:
                pass
        return

    # --ask mode: dedicated hook for AskUserQuestion via PreToolUse (Claude Code 2.1.85+)
    if '--ask' in sys.argv[1:]:
        tool = payload.get('tool_name', '')
        if tool != 'AskUserQuestion':
            return  # Not an AskUserQuestion invocation — exit cleanly (no output)
        payload['coucou_kind'] = 'ask_user_question'
        env = os.environ
        payload.setdefault('term_program', term_program(env))
        payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
        payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
        payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
        if 'cwd' not in payload or not payload['cwd']:
            paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
            if isinstance(paths, list) and paths:
                payload['cwd'] = paths[0]
            else:
                payload['cwd'] = os.getcwd()
        add_session_name(payload)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(125)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'answer':
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PreToolUse', 'permissionDecision': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code asks in terminal
        except Exception:
            pass
        return

    # Parse --agent <name> and optional positional event from argv.
    # --agent tags the payload with coucou_agent so the app routes to the right pill.
    # The positional arg is a fallback event name for agents that do not set hook_event_name.
    args = sys.argv[1:]
    agent = ''
    arg_event = ''
    i = 0
    while i < len(args):
        if args[i] == '--agent' and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            if not arg_event:
                arg_event = args[i]
            i += 1
    if agent:
        payload.setdefault('coucou_agent', agent)
    # Claude Code sessions from the Claude desktop app (Code tab) report this entrypoint;
    # route them to the Claude Desktop pill instead of dropping them (no VS Code terminal).
    if not payload.get('coucou_agent') and os.environ.get('CLAUDE_CODE_ENTRYPOINT') == 'claude-desktop':
        payload['coucou_agent'] = 'claude-desktop'

    env = os.environ
    payload.setdefault('term_program', term_program(env))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        paths = payload.get('workspacePaths') or payload.get('workspace_roots', [])
        if isinstance(paths, list) and paths:
            payload['cwd'] = paths[0]
        else:
            payload['cwd'] = os.getcwd()
    add_session_name(payload)

    # Normalize event name and tool fields (Gemini CLI / Antigravity → canonical names)
    try:
        raw_event = payload.get('hook_event_name', '') or arg_event
        if raw_event:
            payload['hook_event_name'] = normalize_event(raw_event)
        normalize_tool_fields(payload)
    except Exception:
        pass

    event = payload.get('hook_event_name', '')
    # socket_path is already defined above

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if agent == 'hermes':
                    hermes_choice = 'once' if decision == 'allow' else decision
                    if hermes_choice in ('once', 'always', 'deny'):
                        sys.stdout.write(json.dumps({'choice': hermes_choice}) + '\\n')
                        sys.stdout.flush()
                    sys.exit(0)
                if decision in ('allow', 'always'):
                    # Copilot/Muse use {"permissionDecision":"allow"} directly
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'allow'}
                    elif decision == 'always' and agent != 'codex':
                        # Let Claude Code persist the rule via updatedPermissions
                        suggestions = payload.get('permission_suggestions', [])
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    else:
                        # Claude Code / Codex plain allow
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    # Claude Code ignores an allow for ExitPlanMode without updatedInput (Allow and Always).
                    if payload.get('tool_name') == 'ExitPlanMode' and 'hookSpecificOutput' in out:
                        out['hookSpecificOutput']['decision']['updatedInput'] = payload.get('tool_input', {})
                        # Mode picked on the plan card: same choice as the terminal's plan dialog.
                        mode = resp_obj.get('mode')
                        if mode in ('auto', 'default'):
                            out['hookSpecificOutput']['decision']['updatedPermissions'] = [{'type': 'setMode', 'mode': mode, 'destination': 'session'}]
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    if agent in ('copilot', 'muse'):
                        out = {'permissionDecision': 'deny'}
                    else:
                        out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'answer':
                    # AskUserQuestion answered from the notch
                    answers = resp_obj.get('answers', {})
                    questions = payload.get('tool_input', {}).get('questions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedInput': {'questions': questions, 'answers': answers}}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'change_plan':
                    # Plan card "Change plan": like the terminal's "Tell Claude what to change",
                    # reject the plan and stop Claude so the prompt is free for the change.
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'interrupt': True, 'message': 'The user wants to change the plan and will type the changes in the terminal.'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → agent re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        # Copilot is fail-closed: must always output valid JSON so it re-asks rather than deny
        # Hermes: no output → json.loads raises in plugin → transport_fallback: builtin activates
        if agent == 'copilot':
            sys.stdout.write('{"permissionDecision":"ask"}\\n')
            sys.stdout.flush()
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block the agent

    # Antigravity needs a decision on PreToolUse ({} reads as a denial). "ask" keeps its own
    # permission prompt (and the user's Always Allow); Coucou never allows a tool by itself.
    if agent == 'antigravity' and event == 'PreToolUse':
        sys.stdout.write('{"decision":"ask"}\\n')
        sys.stdout.flush()
    elif agent in ('gemini', 'antigravity', 'muse', 'copilot'):
        sys.stdout.write('{}\\n')
        sys.stdout.flush()

try:
    main()
except Exception:
    pass
sys.exit(0)
"""


// MARK: - Hermes approvals (the card slot; the queue and the rules are in HermesApprovalCenter)

extension HookServer {
    /// No approval and no question holds the slot. A demo card does not: a real request covers it, as a hook request does.
    @MainActor var hermesSlotFree: Bool {
        let s = AppState.shared
        let demoCard = s.pendingApproval?.sessionId == "demo_session" && liveApprovalFD < 0
        return (s.pendingApproval == nil || demoCard) && s.pendingQuestion == nil && liveApprovalFD < 0 && pendingQuestionFD < 0
    }

    /// Puts a Hermes request in the card slot: the pill, the sound, the island. No file descriptor, no 115 s timer
    /// (Hermes waits on its own clock). Every Hermes card arms the input lock, whatever was on screen before it: a click
    /// aimed at the previous view cannot land on the card.
    @MainActor
    func presentHermesCard(request: HermesApprovalRequest, pillId: String, playSound: Bool) {
        let state = AppState.shared
        hermesCardArmedAt = CardInputLock.uptime
        #if !APPSTORE
        cmuxShownPayload = nil
        cmuxPromotedAt = nil
        #endif
        let id = HermesApproval.cardIdentity(request: request, pillId: pillId)
        setTaskState(pillId, .approval)
        // The command itself stays in the center: the shared slot holds ids only.
        state.pendingApproval = ApprovalInfo(sessionId: id.sessionId, tool: id.tool, command: "", inputKey: id.inputKey, pillId: pillId)
        state.isPinned = true
        clearPillBadge(id: pillId)
        if playSound { SoundEngine.shared.play("approval") }
        if focusBeforeApproval == nil { focusBeforeApproval = state.focusId }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = pillId }
        expandIfNeeded(to: .approval)
    }

    /// The Hermes card leaves the slot (answered or withdrawn): the pill goes back to what its turn says.
    @MainActor
    func clearHermesCard(pillId: String, agent: String) {
        let state = AppState.shared
        guard state.pendingApproval?.pillId == pillId else { return }
        state.pendingApproval = nil
        state.isPinned = false
        state.approvalReadingHeight = nil
        state.updateTask(id: pillId, state: (state.hermesTurnsRunning[agent] ?? 0) > 0 ? .thinking : .idle)
        clearPillBadgeUnlessCardHeld(id: pillId)
        if let prev = focusBeforeApproval {
            focusBeforeApproval = nil
            if state.focusId == pillId, state.tasks.contains(where: { $0.id == prev }) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { state.focusId = prev }
            }
        }
    }

    /// The slot is free again: the cmux queue first (as before), then the next Hermes request. True when a card appeared.
    @MainActor
    func presentNextAfterHermesCard() -> Bool {
        #if !APPSTORE
        let cmuxWaiting = hasQueuedCmuxCards
        #else
        let cmuxWaiting = false
        #endif
        let next = HermesApproval.nextForFreeSlot(cmuxWaiting: cmuxWaiting, hermesWaiting: HermesApprovalCenter.shared.queue.hasWaiting)
        #if !APPSTORE
        if next == .cmux, presentNextCmuxCard() { return true }
        #endif
        return next != .none && HermesApprovalCenter.shared.presentNextIfFree()
    }

    /// A click on a button of the Hermes card of `requestID`. Ignored for a moment after a card replaced another.
    /// This is the only way in: nothing else (key, timer, iPhone, demo) reaches `HermesApprovalCenter.click`.
    @MainActor
    func sendHermesDecision(requestID: String, button: String) {
        // The Hermes cards have their own lock on the monotonic clock (the center checks it as well); the hook cards keep theirs.
        if CardInputLock.isLockedKeepingWindow(armedAt: &hermesCardArmedAt, now: CardInputLock.uptime) { return }
        #if !APPSTORE
        if cmuxInputLocked() { return }
        #endif
        HermesApprovalCenter.shared.click(requestID: requestID, button: button)
    }
}

extension HookServer {
    /// What stopped a Claude Code turn, from its StopFailure hook: Claude Code's own message when
    /// it sends one, else a sentence for the kind of error. nil when nothing says.
    static func stopFailureDetail(_ payload: [String: Any]) -> String? {
        for key in ["error_message", "error_details", "message"] {
            if let text = payload[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return DiffEngine.toOneLine(text)
            }
        }
        if let error = payload["error"] as? [String: Any], let text = error["message"] as? String, !text.isEmpty {
            return DiffEngine.toOneLine(text)
        }
        let kind = (payload["error_type"] as? String) ?? (payload["error"] as? String) ?? ""
        switch kind {
        case "rate_limit":            return String(localized: "Claude's rate limit is reached. Try again in a moment.")
        case "overloaded":            return String(localized: "Claude is overloaded. Try again in a moment.")
        case "authentication_failed", "oauth_org_not_allowed":
                                      return String(localized: "Claude Code is not signed in, or its key is no longer valid.")
        case "billing_error":         return String(localized: "Billing problem on the Claude account.")
        case "server_error":          return String(localized: "Claude's servers had a problem. Try again.")
        case "max_output_tokens":     return String(localized: "The answer was too long and was cut.")
        case "model_not_found":       return String(localized: "This model is not available.")
        default:
            // Claude Code often sends only `error: "unknown"`: its last message then usually
            // carries the API's own words ("API Error: 529 Overloaded…").
            if let last = payload["last_assistant_message"] as? String,
               last.range(of: "error", options: .caseInsensitive) != nil {
                return DiffEngine.toOneLine(last)
            }
            // A readable error is shown as it is; "unknown" or a bare status code says nothing.
            return kind.count > 3 && Int(kind) == nil && kind != "unknown" ? kind : nil
        }
    }
}
