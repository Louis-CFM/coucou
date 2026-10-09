import SwiftUI

/// Settings → Chat → "Connected on this Mac": what the automatic scan found, ready to use in the chat.
struct ConnectedOnThisMacSection: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        GroupBox("Connected on this Mac") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Coucou looks for AI tools you are already signed in to and AI servers running here. They show up in the chat with no key to paste.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.connectedItems.isEmpty {
                    Text(state.isScanningConnections
                         ? "Looking…"
                         : "Nothing found yet. Sign in to Claude Code, or start Ollama or LM Studio, then scan again.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(state.connectedItems) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Color(hex: item.status == .connected ? "#22C55E" : "#F59E0B"))
                            .frame(width: 8, height: 8)
                        Text(item.name).font(.system(size: 12, weight: .semibold))
                        Text(item.detail)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if item.isUntested {
                            Text("Not tested yet")
                                .font(.system(size: 10))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.18))
                                .clipShape(Capsule())
                                .help("Coucou's authors could not run this tool's chat command. It may not work; tell us if it does not.")
                        }
                    }
                }

                Button(state.isScanningConnections ? "Scanning…" : "Scan again") {
                    Task { await AutoConnect.scan(force: true) }
                }
                .buttonStyle(.bordered)
                .disabled(state.isScanningConnections)
                .help("Looks again, and reconnects anything you removed. Only this Mac is asked.")
            }
            .padding(.vertical, 4)
        }
        .onAppear { Task { await AutoConnect.scan(force: false) } }
    }
}
