import SwiftUI

struct LinkTestView: View {
    let link: PhoneLink
    @State private var sending = false

    var body: some View {
            List {
                Section {
                    statusRow
                    if link.notificationsAllowed == false {
                        Label("Notifications are off: the \"Ping from your Mac\" banner won't show.",
                              systemImage: "bell.slash")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Approval notifications", value: link.approvalsStatus)
                    if let error = link.pushError {
                        Label("Push registration failed: \(error)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section("Sessions on your Mac") {
                    if link.sessions.isEmpty {
                        Text("No session yet. Open Coucou on your Mac (NotchBuddyCloud).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(link.sessions) { session in
                        HStack(alignment: .top, spacing: 12) {
                            MochiStill(state: session.state)
                                .padding(4)
                                .frame(width: 40, height: 40)
                                .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name.isEmpty ? session.pillName : session.name)
                                Text("\(session.pillName) · \(session.state.rawValue)" +
                                     (session.steps.isEmpty ? "" : " · \(session.stepIndex + 1)/\(session.steps.count)"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if session.needsApproval {
                                    Text(session.approvalCommand.isEmpty ? "Waiting for your approval" : session.approvalCommand)
                                        .font(.caption.monospaced()).foregroundStyle(.orange).lineLimit(2)
                                } else if !session.question.isEmpty {
                                    Text(session.question).font(.caption).foregroundStyle(.cyan).lineLimit(2)
                                } else if let step = session.currentStep {
                                    Text(step).font(.caption).lineLimit(1)
                                }
                                Text(session.updatedAt, style: .relative)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        sending = true
                        Task {
                            await link.sendPong()
                            sending = false
                        }
                    } label: {
                        HStack {
                            Text("Send pong")
                            if sending { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(link.pings.isEmpty || sending || link.status != .ready)
                    if let pong = link.lastPong {
                        Text(pong).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Pings from your Mac") {
                    if link.pings.isEmpty {
                        Text("No ping yet.").foregroundStyle(.secondary)
                    }
                    ForEach(link.pings) { ping in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ping.message.isEmpty ? "Ping" : ping.message)
                            HStack {
                                Text("\(ping.macName) · \(ping.app)")
                                Spacer()
                                Text(ping.sentAt, style: .time)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(delayText(ping))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(ping.delay == nil ? Color.secondary : Color.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("Coucou link test")
            .refreshable { await link.refresh() }
            .toolbar {
                NavigationLink("Kit") { KitPreviewView() }
            }
    }

    @ViewBuilder private var statusRow: some View {
        switch link.status {
        case .starting:
            Label("Connecting to iCloud…", systemImage: "icloud")
        case .noAccount(let reason):
            Label("iCloud not connected. \(reason) Sign in in Settings, using the same account as your Mac.",
                  systemImage: "icloud.slash")
                .foregroundStyle(.orange)
        case .zoneMissing:
            Label("The Coucou zone doesn't exist yet. Launch Coucou on your Mac (NotchBuddyCloud scheme), then pull to refresh.",
                  systemImage: "tray")
                .foregroundStyle(.orange)
        case .ready:
            Label("Linked to iCloud", systemImage: "checkmark.icloud")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.red)
        }
    }

    private func delayText(_ ping: PingItem) -> String {
        guard let delay = ping.delay else { return "already there at launch" }
        return String(format: "received %.1f s after sending", delay)
    }
}
