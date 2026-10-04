import SwiftUI

/// The command an agent waits on, with Allow (Face ID) and Deny.
/// Used in the session screen and in the sheet opened from a notification.
struct ApprovalCard: View {
    let link: PhoneLink
    let session: SessionItem

    @State private var sending: Decision?
    @State private var sent: Decision?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for your OK").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(session.approvalCommand.isEmpty ? "The agent asks for a permission." : session.approvalCommand)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                .textSelection(.enabled)
            if let sent {
                Label(sent == .allow ? "Allowed, sent to your Mac" : "Denied, sent to your Mac",
                      systemImage: sent == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(sent == .allow ? .green : .red)
            } else if session.approvalFingerprint.isEmpty {
                Text("Answer on your Mac. This request can't be answered from the iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Button(role: .destructive) { Task { await send(.deny) } } label: {
                        Label("Deny", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Button { Task { await send(.allow) } } label: {
                        Label("Allow", systemImage: "faceid")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .controlSize(.large)
                .disabled(sending != nil)
                Text("Allow asks for Face ID. The request expires after 2 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.orange.opacity(0.7), lineWidth: 1.5))
        .onChange(of: session.approvalFingerprint) { sent = nil; error = nil }
    }

    private func send(_ decision: Decision) async {
        sending = decision
        defer { sending = nil }
        error = nil
        if decision == .allow {
            guard await OwnerCheck.confirm(reason: "Allow this command on your Mac") else {
                error = "Face ID didn't confirm. Nothing was sent."
                return
            }
        }
        let summary = session.approvalCommand.isEmpty ? "Permission" : session.approvalCommand
        if await link.decide(decision, fingerprint: session.approvalFingerprint, pillId: session.id,
                             summary: String(summary.prefix(200))) {
            sent = decision
        } else {
            error = link.lastPong ?? "Couldn't reach iCloud."
        }
    }
}

/// Opened from the "Review" action of an approval notification.
struct ReviewSheet: View {
    let link: PhoneLink
    let fingerprint: String
    @Environment(\.dismiss) private var dismiss

    private var session: SessionItem? { link.sessions.first { $0.approvalFingerprint == fingerprint } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session {
                        HStack(spacing: 12) {
                            MochiStill(state: session.state)
                                .padding(6)
                                .frame(width: 52, height: 52)
                                .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(session.pillName) · \(session.title)").font(.headline)
                                if !session.macName.isEmpty {
                                    Text(session.macName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ApprovalCard(link: link, session: session)
                    } else {
                        Text("This request was already answered or has expired.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    }
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await link.refresh() }
        }
    }
}

/// Decisions taken on this iPhone.
struct HistoryView: View {
    let link: PhoneLink

    var body: some View {
        List {
            if link.history.isEmpty {
                Text("No decision yet.").foregroundStyle(.secondary)
            }
            ForEach(link.history) { log in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: log.decision == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(log.decision == .allow ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.summary)
                            .font(.callout.monospaced())
                            .lineLimit(3)
                        HStack(spacing: 4) {
                            Text(PillCatalog.definition(for: log.pillId)?.name ?? log.pillId)
                            Text("·")
                            Text(log.date, format: .dateTime.day().month().hour().minute())
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}
