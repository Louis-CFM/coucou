import SwiftUI

/// Settings → Agents: the switch and the rules, each one removable.
struct AutoApproveSettingsSection: View {
    @State private var on = AutoApprove.enabled
    @State private var rules = AutoApprove.rules

    var body: some View {
        GroupBox(String(localized: "Auto-approve")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "Auto-approve"), isOn: $on)
                    .onChange(of: on) { _, v in AutoApprove.enabled = v }
                Text("Allow the commands you picked with Always here without asking again. Only for Codex, Copilot CLI and Muse Code, only in the same folder, and never for a command that chains, redirects or deletes.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if rules.isEmpty {
                    Text("No rules yet.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                ForEach(rules, id: \.self) { rule in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(PillCatalog.definition(for: rule.pillId)?.name ?? rule.pillId) · \(rule.prefix)…")
                                .font(.system(size: 11, design: .monospaced))
                            Text(verbatim: rule.cwd)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Button(String(localized: "Remove")) {
                            AutoApprove.remove(rule)
                            rules = AutoApprove.rules
                        }
                    }
                }
            }
            .padding(6)
        }
        .onAppear { on = AutoApprove.enabled; rules = AutoApprove.rules }
    }
}
