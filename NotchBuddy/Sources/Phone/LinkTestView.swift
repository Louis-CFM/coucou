import SwiftUI

struct LinkTestView: View {
    let link: PhoneLink
    @State private var sending = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusRow
                    if link.notificationsAllowed == false {
                        Label("Notifications are off: the \"Ping from your Mac\" banner won't show.",
                              systemImage: "bell.slash")
                            .foregroundStyle(.secondary)
                    }
                    if let error = link.pushError {
                        Label("Push registration failed: \(error)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
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
