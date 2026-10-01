import SwiftUI

struct SettingsIslandTab: View {
    @ObservedObject private var state = AppState.shared

    private var usedSlots: Int { state.activeIntegrations.count }
    private var isFull: Bool { usedSlots >= AgentTask.maxToggleablePills }

    var body: some View {
        SettingsPage(status: nil) {
            Section {
                LabeledContent {
                    Text("Always active")
                        .foregroundColor(.secondary)
                } label: {
                    PillLabel(name: "VS Code", color: "#F5F6F8")
                }
            } footer: {
                Text("Claude Code sessions always have their pill.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section {
                ForEach(AgentTask.toggleableIntegrationIds, id: \.self) { id in
                    if let task = AgentTask.integrationAgents.first(where: { $0.id == id }) {
                        pillRow(id: id, task: task)
                    }
                }
            } header: {
                HStack {
                    Text("Active pills")
                    Spacer()
                    Text("\(usedSlots)/\(AgentTask.maxToggleablePills) slots used")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(isFull ? .orange : .secondary)
                }
            } footer: {
                if isFull {
                    Text("Turn a pill off to make room for another one.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }

    private func pillRow(id: String, task: AgentTask) -> some View {
        let isOn = state.activeIntegrations.contains(id)
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { _ in state.toggleIntegration(id) }
        )) {
            PillLabel(name: task.name, color: task.color)
        }
        .disabled(isFull && !isOn)
    }
}

private struct PillLabel: View {
    let name: String
    let color: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: color)).frame(width: 10, height: 10)
            Text(verbatim: name)
        }
    }
}
