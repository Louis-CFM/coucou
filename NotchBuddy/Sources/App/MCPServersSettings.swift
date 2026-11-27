import SwiftUI

/// Settings → Chat → "MCP Tools & Connectors": displays discovered MCP servers
/// from other developer tools on this Mac and allows enabling or disabling them.
struct MCPServersSettings: View {
    @ObservedObject private var state = AppState.shared

    var body: some View {
        GroupBox("MCP Tools & Connectors") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Coucou discovers MCP servers you already configured in Claude Desktop, Cursor, VS Code, or OpenCode. Enabled tools become available to the chat.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if state.mcpServers.isEmpty {
                    Text(state.isScanningMCPServers
                         ? "Scanning for MCP configurations…"
                         : "No MCP servers detected yet. Configure tools in Claude Desktop, Cursor, or OpenCode, then scan again.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(state.mcpServers) { server in
                    serverRow(server)
                }

                HStack(spacing: 8) {
                    Button(state.isScanningMCPServers ? "Scanning…" : "Scan for MCP tools") {
                        state.scanMCPServers()
                    }
                    .buttonStyle(.bordered)
                    .disabled(state.isScanningMCPServers)
                    .help("Scans existing configuration files on this Mac without making any modifications.")
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            if state.mcpServers.isEmpty {
                state.scanMCPServers()
            }
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(
                get: { server.isEnabled },
                set: { _ in state.toggleMCPServer(id: server.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                        .font(.system(size: 12, weight: .semibold))

                    ForEach(server.sources, id: \.self) { source in
                        Text(source.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Text(server.summary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if server.isReadOnly {
                Image(systemName: "checkmark.shield")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                    .help("Safe mode: mutating tools require approval in the Notch.")
            }
        }
        .padding(.vertical, 2)
    }
}
