import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI
import CloudKit

// The expanded approval notification (long press): Mochi alive, waiting for
// your OK, with the agent and the command. The Review and Deny buttons stay
// the system's, under this view.

final class NotificationViewController: UIViewController, @preconcurrency UNNotificationContentExtension {
    private var host: UIHostingController<ApprovalNotificationView>?

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let note = CKNotification(fromRemoteNotificationDictionary: content.userInfo) as? CKQueryNotification
        let pillId = content.userInfo["pillId"] as? String
            ?? note?.recordFields?["pillId"] as? String ?? "integration_claude"
        let view = ApprovalNotificationView(pillId: pillId, title: content.title, message: content.body)
        if let host {
            host.rootView = view
        } else {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            addChild(host)
            host.view.frame = self.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            self.view.addSubview(host.view)
            host.didMove(toParent: self)
            self.host = host
        }
        preferredContentSize = CGSize(width: view.bounds.width, height: 190)
    }
}

struct ApprovalNotificationView: View {
    let pillId: String
    let title: String
    let message: String

    private var pill: PillDefinition? { PillCatalog.definition(for: pillId) }

    /// The command alone, without the "Waiting for your OK: " the local notification adds.
    private var command: String {
        let prefix = "Waiting for your OK: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MochiLive(state: .approval, bodyHex: pill?.color ?? "#FFFFFF")
                .padding(6)
                .frame(width: 76, height: 76)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 6) {
                Text(title == "Coucou" ? (pill?.name ?? "Coucou") : title)
                    .font(.headline)
                Text("Waiting for your OK")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(command)
                    .font(.footnote.monospaced())
                    .lineLimit(4)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.08))
        .preferredColorScheme(.dark)
    }
}
