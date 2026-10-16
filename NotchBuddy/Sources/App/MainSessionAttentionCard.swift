import SwiftUI

struct MainSessionAttentionCard: View {
    let request: MainSessionAttention
    let count: Int
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Color.clear.frame(width: 98)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(request.appName) · " + (request.kind == "permission"
                        ? String(localized: "attention.waiting-approval", defaultValue: "Waiting for approval")
                        : String(localized: "attention.waiting-answer", defaultValue: "Waiting for an answer")))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                    Spacer()
                    if count > 1 {
                        Text(String(localized: "attention.pending-count", defaultValue: "\(count) pending"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(request.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(request.reason).font(.system(size: 12)).lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 56, alignment: .topLeading)
                    .help(request.reason)
                HStack {
                    Button(request.source == "codex"
                           ? String(localized: "attention.back-to-chat", defaultValue: "Back to chat")
                           : String(localized: "attention.open-app", defaultValue: "Open OpenCode"),
                           action: onOpen)
                        .buttonStyle(.borderedProminent).tint(.orange)
                    Button(String(localized: "attention.later", defaultValue: "Later"), action: onDismiss)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                }.font(.system(size: 12))
            }
            .padding(.vertical, 8)
            .padding(.trailing, 16)
        }
        .foregroundStyle(.white)
    }
}
