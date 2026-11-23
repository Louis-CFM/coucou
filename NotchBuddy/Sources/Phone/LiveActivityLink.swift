import ActivityKit
import CloudKit
import UIKit

// MARK: - iPhone plan, step 8: Mochi in the Dynamic Island
//
// The Mac starts, updates and ends the Live Activity through the relay, which
// needs this iPhone's push tokens:
//  - the push-to-start token, to start an activity while the app is closed;
//  - each running activity's update token, to update and end it.
// iOS hands them to the app (it wakes it in the background when the Mac starts
// an activity); they go to the private iCloud zone, encrypted, where the Mac
// reads them. One `PhoneToken` record per iPhone.

@MainActor
final class LiveActivityLink {
    static let shared = LiveActivityLink()

    private var database: CKDatabase { CKContainer(identifier: PhoneLink.containerID).privateCloudDatabase }
    private var started = false
    private var startToken = ""
    private var updateToken = ""
    private var activityID = ""
    private var watched: Set<String> = []

    /// "development" for builds run from Xcode, "production" for TestFlight and
    /// the App Store (set per configuration in project.yml).
    private var apnsEnvironment: String {
        Bundle.main.object(forInfoDictionaryKey: "CoucouAPNsEnvironment") as? String ?? "production"
    }

    private var recordID: CKRecord.ID {
        let device = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        return CKRecord.ID(recordName: "phone-\(device)", zoneID: PhoneLink.zoneID)
    }

    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start() {
        guard !started else { return }
        started = true
        Task {
            for await data in Activity<MochiActivityAttributes>.pushToStartTokenUpdates {
                startToken = data.hexString
                await save()
            }
        }
        Task {
            for await activity in Activity<MochiActivityAttributes>.activityUpdates {
                watch(activity)
            }
        }
        // Activities already running when the app launches.
        for activity in Activity<MochiActivityAttributes>.activities { watch(activity) }
    }

    /// The activity follows the sessions from here, each time the app is awake (open, an
    /// iCloud push, or Botan's signal every 15 s), without waiting for the Mac's pushes:
    ///  - an agent at work, thinking, or waiting for your OK: Mochi shows it;
    ///  - the work is done: Mochi shows "Done" for a few seconds, then leaves;
    ///  - nothing going: it leaves right away.
    /// The Mac starts it when the app is closed (iOS starts one in the background only on a
    /// push); with the app open, the iPhone starts it itself.
    func sessionsChanged(_ sessions: [SessionItem]) {
        answered = answered.filter { Date().timeIntervalSince($0.value) < 120 }
        let lead = Self.leadState(sessions, answered: Set(answered.keys))
        guard let activity = Activity<MochiActivityAttributes>.activities.first(where: { $0.activityState == .active }) else {
            startHereIfOpen(lead)
            return
        }
        let id = activity.id
        guard let lead, lead.isActive || lead.tone == "done" else {
            endTask?.cancel(); endTask = nil
            Task { await Self.end(id: id, with: nil) }
            return
        }
        var next = lead
        next.since = activity.content.state.since ?? Int(Date().timeIntervalSince1970)
        if next.tone == "done" {
            guard endTask == nil else { return }
            // "Done" for a moment, then Mochi leaves (a little background time to get there).
            let state = next
            let background = UIApplication.shared.beginBackgroundTask(withName: "Mochi done")
            endTask = Task {
                await Self.update(id: id, to: state)
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { await Self.end(id: id, with: state) }
                endTask = nil
                UIApplication.shared.endBackgroundTask(background)
            }
            return
        }
        // Back to work before leaving: stay.
        endTask?.cancel(); endTask = nil
        guard next != activity.content.state else { return }
        let state = next
        Task { await Self.update(id: id, to: state) }
    }

    private var endTask: Task<Void, Never>?
    /// Requests answered from the Live Activity: shown as answered until the Mac's news catches up.
    private var answered: [String: Date] = [:]

    /// Allow or Deny tapped on the Live Activity: it says so at once ("Allowed", Mochi back to
    /// work) instead of waiting for the Mac to answer through iCloud.
    func showAnswered(fingerprint: String, allowed: Bool) async {
        answered[fingerprint] = Date()
        guard let activity = Activity<MochiActivityAttributes>.activities.first(where: { $0.activityState == .active }) else { return }
        var state = activity.content.state
        state.approval = nil
        state.tone = "working"
        state.state = BotState.working.rawValue
        state.statusText = allowed ? "Allowed" : "Denied"
        let id = activity.id, next = state
        await Self.update(id: id, to: next)
    }

    /// With the app open and an agent going, Mochi is in the Dynamic Island as soon as you leave it.
    private func startHereIfOpen(_ lead: MochiActivityState?) {
        guard var lead, lead.isActive, activitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        lead.since = Int(Date().timeIntervalSince1970)
        _ = try? Activity<MochiActivityAttributes>.request(attributes: MochiActivityAttributes(),
                                                           content: ActivityContent(state: lead, staleDate: nil),
                                                           pushType: .token)
    }

    // Only Sendable values cross into these: the activity is looked up again by its ID.
    private nonisolated static func update(id: String, to state: MochiActivityState) async {
        guard let activity = Activity<MochiActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    private nonisolated static func end(id: String, with state: MochiActivityState?) async {
        guard let activity = Activity<MochiActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        await activity.end(state.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: .immediate)
    }

    /// The most urgent session, as the Mac builds it (LiveActivityRelay.leadState).
    static func leadState(_ sessions: [SessionItem], answered: Set<String> = []) -> MochiActivityState? {
        let ranked = sessions
            .filter { PillCatalog.isSession($0.id) }
            .map { s -> (session: SessionItem, urgency: Int, state: BotState) in
                let isAnswered = answered.contains(s.approvalFingerprint)
                let waiting = s.needsApproval && !s.approvalFingerprint.isEmpty && !isAnswered
                // Answered here, the Mac not told yet: back to work.
                let state = isAnswered && (s.state == .approval || s.needsApproval) ? BotState.working : s.state
                return (s, MochiActivityState.urgency(state: state, waitingForOK: waiting, hasQuestion: state == .question), state)
            }
        guard let lead = ranked.min(by: { $0.urgency < $1.urgency }) else { return nil }
        let (session, urgency, state) = lead
        let others = ranked.filter { $0.session.id != session.id && $0.urgency <= 3 }.count
        return MochiActivityState(
            pillId: session.id,
            agent: session.pillName,
            color: session.color,
            state: (urgency == 0 ? BotState.approval : state).rawValue,
            statusText: MochiActivityState.statusText(state: state, urgency: urgency,
                                                      stepIndex: session.stepIndex, stepCount: session.steps.count),
            tone: MochiActivityState.tone(urgency: urgency),
            stepIndex: max(0, session.stepIndex),
            stepCount: session.steps.count,
            others: others,
            approval: urgency == 0 && !session.approvalFingerprint.isEmpty ? session.approvalFingerprint : nil)
    }

    private func watch(_ activity: Activity<MochiActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        // One Mochi at a time: the newest one stays.
        let newest = activity.id
        for older in Activity<MochiActivityAttributes>.activities where older.id != newest && older.activityState == .active {
            let id = older.id
            Task { await Self.end(id: id, with: nil) }
        }
        Task {
            for await data in activity.pushTokenUpdates {
                activityID = activity.id
                updateToken = data.hexString
                await save()
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                watched.remove(activity.id)
                if activityID == activity.id {
                    activityID = ""
                    updateToken = ""
                    await save()
                }
            }
        }
    }

    private func save() async {
        let record = CKRecord(recordType: "PhoneToken", recordID: recordID)
        record["env"] = apnsEnvironment
        record["activityId"] = activityID
        record["updatedAt"] = Date()
        record["deviceName"] = UIDevice.current.name
        // Which app the tokens belong to (Botan or Coucou): the relay pushes to that app.
        record["app"] = Bundle.main.bundleIdentifier ?? ""
        record.encryptedValues["startToken"] = startToken
        record.encryptedValues["updateToken"] = updateToken
        // Several tokens can arrive at once; the last write wins, with all fields.
        _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
