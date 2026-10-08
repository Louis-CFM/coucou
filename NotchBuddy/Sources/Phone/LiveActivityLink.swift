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

    private func watch(_ activity: Activity<MochiActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
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
        record.encryptedValues["startToken"] = startToken
        record.encryptedValues["updateToken"] = updateToken
        // Several tokens can arrive at once; the last write wins, with all fields.
        _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
