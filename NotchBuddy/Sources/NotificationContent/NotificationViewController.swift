import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI
import CloudKit

// The expanded approval notification (long press): Mochi alive, waiting for
// your OK, with the agent and the command. The Review and Deny buttons stay
// the system's, under this view.

final class NotificationViewController: UIViewController, @preconcurrency UNNotificationContentExtension {
    private let host = UIHostingController(rootView: ApprovalNotificationView(pillId: "integration_claude", title: "", message: ""))

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.08, alpha: 1)
        host.view.backgroundColor = .clear
        // Pinned with constraints: the extension's view has no size yet here.
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        preferredContentSize = CGSize(width: view.bounds.width, height: 200)
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let note = CKNotification(fromRemoteNotificationDictionary: content.userInfo) as? CKQueryNotification
        let pillId = content.userInfo["pillId"] as? String
            ?? note?.recordFields?["pillId"] as? String ?? "integration_claude"
        host.rootView = ApprovalNotificationView(pillId: pillId, title: content.title, message: content.body)
        preferredContentSize = CGSize(width: view.bounds.width, height: 200)
    }
}

/// Mochi in his agent's color, waiting; who asks and the exact command.
struct ApprovalNotificationView: View {
    let pillId: String
    let title: String
    let message: String

    private var pill: PillDefinition? { PillCatalog.definition(for: pillId) }
    private var color: String { pill?.color ?? "#FFFFFF" }

    /// The command alone, without the "Waiting for your OK: " the local notification adds.
    private var command: String {
        let prefix = "Waiting for your OK: "
        if message.hasPrefix(prefix) { return String(message.dropFirst(prefix.count)) }
        return message == "An agent is waiting for your OK" ? "" : message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                MochiLive(state: .approval, bodyHex: color)
                    .padding(7)
                    .frame(width: 60, height: 60)
                    .background(Color.mochiTile(hex: color), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.isEmpty || title == "Coucou" ? (pill?.name ?? "Coucou") : title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("Waiting for your OK")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            if !command.isEmpty {
                Text(command)
                    .font(.callout.monospaced())
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.08))
        .environment(\.colorScheme, .dark)
    }
}
