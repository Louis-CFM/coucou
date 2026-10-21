import SwiftUI

struct AgentsOnlyModeControl: View {
    @Binding var enabled: Bool
    var message: String?

    var body: some View {
        GroupBox(String(localized: "focus.mode-title")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(String(localized: "focus.agents-only"), isOn: $enabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("agents-only-mode")
                Text(String(localized: enabled ? "focus.enabled-description" : "focus.full-description"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            .padding(6)
        }
    }
}
