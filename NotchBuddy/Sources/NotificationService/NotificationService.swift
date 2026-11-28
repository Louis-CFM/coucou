import CloudKit
import Foundation
import UserNotifications

/// Fills in Botan's iCloud alert for an approval, so one banner says it all ("VS Code · portfo ·
/// Waiting for your OK: npm run build") instead of a plain alert followed by a second, detailed one.
/// The alert itself carries the agent (pill ID) and the fingerprint; the command and the project
/// come from the app, which the same push wakes (PendingApprovals). Waits a few seconds for them,
/// then shows what it has.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let note = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification
        guard let fingerprint = note?.recordFields?["fingerprint"] as? String, !fingerprint.isEmpty else {
            contentHandler(content)
            return
        }
        let pillId = note?.recordFields?["pillId"] as? String ?? ""
        content.title = PillCatalog.definition(for: pillId)?.name ?? "An agent"
        content.body = "Waiting for your OK"
        content.userInfo["fingerprint"] = fingerprint
        content.userInfo["pillId"] = pillId
        // This runs on its own thread, with about 30 s to spare: waiting here is fine.
        for _ in 0..<16 {
            if let item = PendingApprovals.load()[fingerprint] {
                content.title = item.project.isEmpty ? item.agent : "\(item.agent) · \(item.project)"
                if !item.command.isEmpty { content.body = "Waiting for your OK: \(item.command.prefix(140))" }
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        contentHandler(content)
    }
}
