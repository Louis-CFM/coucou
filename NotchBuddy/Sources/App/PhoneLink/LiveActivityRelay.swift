#if PHONE_LINK
import AppKit
import CloudKit
import Combine

// MARK: - iPhone plan, step 8: Mochi leaves for the iPhone
//
// When the Mac locks while an agent is working, Mochi moves to the iPhone's
// Dynamic Island and Lock Screen (a Live Activity), and comes back when the
// Mac unlocks. Live Activity pushes need the APNs key, which can't ship in the
// app, so they go through the user's relay (relay/ in this repo, a stateless
// Cloudflare Worker). The iPhone's push tokens come from iCloud (`PhoneToken`
// records, written by LiveActivityLink on the iPhone).
//
// Sent to the relay: the iPhone's token and MochiActivityState (agent, state,
// counts). Never a project name, a step, a command or a path.
// Runs only while the Mac is locked with an agent going: lock notifications
// and AppState changes, no timer at rest.

@MainActor
final class LiveActivityRelay {
    static let shared = LiveActivityRelay()

    static let enabledKey = "iPhoneLiveActivityEnabled"
    /// Overrides the relay address (defaults write fr.louisraille.NotchBuddy phoneRelayURL <url>).
    static let relayURLKey = "phoneRelayURL"
    /// The deployed relay (relay/README.md).
    static let defaultRelayURL = "https://coucou-relay.raillelouis.workers.dev"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private struct Phone {
        var env: String
        var startToken: String
        var updateToken: String
        var updatedAt: Date
    }

    private var database: CKDatabase { CKContainer(identifier: CloudProbe.containerID).privateCloudDatabase }
    private var observers: [NSObjectProtocol] = []
    private var cancellable: AnyCancellable?
    private var phones: [String: Phone] = [:]
    private var changeToken: CKServerChangeToken?

    private var locked = false
    private var latest: MochiActivityState?
    /// Set while a Live Activity runs on the iPhone(s).
    private var startedAt: Date?
    /// The startedAt whose start push actually went out.
    private var startSent: Date?
    private var sent: MochiActivityState?
    private var sending = false
    private var retryTask: Task<Void, Never>?
    private var retries = 0
    /// Ends the activity 10 minutes after the agents are done, if nothing restarts.
    private var doneTask: Task<Void, Never>?

    private var relayURL: URL? {
        let value = UserDefaults.standard.string(forKey: Self.relayURLKey) ?? Self.defaultRelayURL
        return value.isEmpty ? nil : URL(string: value)?.appendingPathComponent("v1/live-activity")
    }

    // MARK: Lifecycle

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on && CloudProbe.isEnabled { start() } else { stop() }
    }

    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func start() {
        guard cancellable == nil else { return }
        let center = DistributedNotificationCenter.default()
        observers = [
            center.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockChanged(true) }
            },
            center.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockChanged(false) }
            },
        ]
        let state = AppState.shared
        cancellable = state.$tasks
            .combineLatest(state.$pendingApproval)
            .map { tasks, approval in Self.leadState(tasks: tasks, approval: approval) }
            .removeDuplicates()
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] lead in
                MainActor.assumeIsolated { self?.stateChanged(lead) }
            }
        log(relayURL == nil ? "on, but no relay address yet (relay/README.md)" : "on")
    }

    func stop() {
        guard cancellable != nil else { return }
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        cancellable = nil
        if startedAt != nil { finish(dismissAfter: 0) }
        log("off")
    }

    // MARK: Events

    private func lockChanged(_ isLocked: Bool) {
        locked = isLocked
        if isLocked {
            log("Mac locked")
            if let latest, latest.isActive { begin(latest) }
        } else {
            log("Mac unlocked")
            // Mochi comes back to the notch.
            if startedAt != nil { finish(dismissAfter: 0) }
        }
    }

    private func stateChanged(_ lead: MochiActivityState?) {
        latest = lead
        guard locked else { return }
        if startedAt == nil {
            if let lead, lead.isActive { begin(lead) }
            return
        }
        if let lead, lead.isActive {
            // Back to work: the same activity carries on.
            doneTask?.cancel(); doneTask = nil
            flush()
        } else if doneTask == nil {
            // Nothing going any more: show "done" for 10 minutes, then leave,
            // unless an agent starts again meanwhile.
            if lead != nil { flush() }
            doneTask = Task {
                try? await Task.sleep(for: .seconds(10 * 60))
                guard !Task.isCancelled else { return }
                doneTask = nil
                finish(dismissAfter: 0)
            }
        }
    }

    // MARK: Sending

    private func begin(_ state: MochiActivityState) {
        let start = Date()
        startedAt = start
        sent = state
        retries = 0
        Task {
            await refreshPhones()
            // The Mac unlocked meanwhile: don't leave.
            guard startedAt == start, locked else { return }
            startSent = start
            let targets = phones.filter { !$0.value.startToken.isEmpty }
            if targets.isEmpty {
                log("no iPhone token yet: open Coucou on the iPhone once, with Live Activities allowed")
                return
            }
            for (id, phone) in targets {
                await post(event: "start", token: phone.startToken, env: phone.env, state: state, phoneID: id)
            }
            log("Mochi left for the iPhone (\(state.agent), \(state.statusText))")
        }
    }

    /// Sends the latest state if it changed, one request at a time.
    private func flush() {
        guard !sending, let startedAt, let state = latest, state != sent else { return }
        sending = true
        Task {
            let targets = await updateTargets(since: startedAt)
            guard !targets.isEmpty else {
                sending = false
                scheduleRetry()
                return
            }
            for (id, phone) in targets {
                await post(event: "update", token: phone.updateToken, env: phone.env, state: state,
                           urgent: state.tone == "waiting" || state.tone == "question", phoneID: id)
            }
            sent = state
            sending = false
            // Something changed while this one was on its way.
            if latest != sent { flush() }
        }
    }

    private func finish(dismissAfter: Int) {
        guard let startedAt else { return }
        self.startedAt = nil
        retryTask?.cancel(); retryTask = nil
        doneTask?.cancel(); doneTask = nil
        let last = latest ?? sent ?? .placeholder
        sent = nil
        guard startSent == startedAt else {
            // The start never went out: nothing to end on the iPhone.
            log("Mochi is back on the Mac")
            return
        }
        Task {
            // A start sent a moment ago: its update token is still on its way.
            var targets = await updateTargets(since: startedAt)
            for _ in 0..<6 where targets.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                targets = await updateTargets(since: startedAt)
            }
            if targets.isEmpty { log("can't end the Live Activity: no update token from the iPhone") }
            for (id, phone) in targets {
                await post(event: "end", token: phone.updateToken, env: phone.env, state: last,
                           dismissAfter: dismissAfter, phoneID: id)
            }
            log(dismissAfter == 0 ? "Mochi is back on the Mac" : "agents done, the iPhone shows it for \(dismissAfter / 60) min")
        }
    }

    /// The update token arrives a moment after the start (the iPhone gets it
    /// from iOS, then writes it to iCloud): retry a few times.
    private func scheduleRetry() {
        guard retryTask == nil, retries < 10 else { return }
        retries += 1
        retryTask = Task {
            try? await Task.sleep(for: .seconds(3))
            retryTask = nil
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func updateTargets(since date: Date) async -> [String: Phone] {
        func fresh() -> [String: Phone] {
            phones.filter { !$0.value.updateToken.isEmpty && $0.value.updatedAt >= date.addingTimeInterval(-2) }
        }
        if fresh().isEmpty { await refreshPhones() }
        return fresh()
    }

    private func post(event: String, token: String, env: String, state: MochiActivityState,
                      urgent: Bool = false, dismissAfter: Int? = nil, phoneID: String) async {
        guard let url = relayURL else { return }
        var body: [String: Any] = ["token": token, "env": env, "event": event, "urgent": urgent]
        if let dismissAfter { body["dismissAfter"] = dismissAfter }
        guard let stateData = try? JSONEncoder().encode(state),
              let stateObject = try? JSONSerialization.jsonObject(with: stateData) else { return }
        body["state"] = stateObject
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return }
            if status == 410 {
                // That token is gone (activity ended on the iPhone, app deleted…).
                if event == "start" { phones[phoneID]?.startToken = "" } else { phones[phoneID]?.updateToken = "" }
            }
            log("relay \(event) → \(status) \(String(data: data, encoding: .utf8)?.prefix(120) ?? "")")
        } catch {
            log("relay \(event) failed: \(error.localizedDescription)")
        }
    }

    // MARK: Tokens

    private func refreshPhones() async {
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: CloudProbe.zoneID, since: changeToken)
                for (id, result) in changes.modificationResultsByID {
                    guard case .success(let mod) = result, mod.record.recordType == "PhoneToken" else { continue }
                    let record = mod.record
                    phones[id.recordName] = Phone(
                        env: record["env"] as? String ?? "production",
                        startToken: record.encryptedValues["startToken"] as? String ?? "",
                        updateToken: record.encryptedValues["updateToken"] as? String ?? "",
                        updatedAt: record["updatedAt"] as? Date ?? .distantPast)
                }
                for deletion in changes.deletions where deletion.recordType == "PhoneToken" {
                    phones[deletion.recordID.recordName] = nil
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
        } catch {
            log("token fetch failed: \(error.localizedDescription)")
        }
    }

    // MARK: State

    /// The most urgent session, as the iPhone's Live Activity shows it.
    nonisolated static func leadState(tasks: [AgentTask], approval: ApprovalInfo?) -> MochiActivityState? {
        let ranked = tasks
            .filter { $0.source != .n8n }   // same sessions as SessionPublisher
            .map { task -> (AgentTask, Int) in
                let urgency = MochiActivityState.urgency(state: task.state,
                                                         waitingForOK: approval?.pillId == task.id,
                                                         hasQuestion: task.state == .question)
                return (task, urgency)
            }
        guard let lead = ranked.min(by: { $0.1 < $1.1 }) else { return nil }
        let (task, urgency) = lead
        let others = ranked.filter { $0.0.id != task.id && $0.1 <= 3 }.count
        return MochiActivityState(
            pillId: task.id,
            agent: PillCatalog.definition(for: task.id)?.name ?? "Agent",
            color: task.color,
            state: (urgency == 0 ? BotState.approval : task.state).rawValue,
            statusText: MochiActivityState.statusText(state: task.state, urgency: urgency,
                                                      stepIndex: task.stepIndex, stepCount: task.steps.count),
            tone: MochiActivityState.tone(urgency: urgency),
            stepIndex: max(0, task.stepIndex),
            stepCount: task.steps.count,
            others: others)
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[live] \(message)")
    }
}
#endif
