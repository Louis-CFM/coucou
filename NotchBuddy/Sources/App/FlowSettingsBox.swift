#if !APPSTORE
import SwiftUI

/// Settings → Voice: Flow dictation (hold a key, speak, the words are pasted where you type).
struct FlowSettingsBox: View {
    @ObservedObject private var flow = FlowDictation.shared

    var body: some View {
        GroupBox(String(localized: "flow.title")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle(String(localized: "flow.enable"), isOn: $flow.isEnabled)
                    Spacer()
                    Button(String(localized: "hub.open")) { FlowHubController.shared.show() }
                }

                Text(String(format: String(localized: "flow.how %@"), flow.key.label))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(String(localized: "flow.key"))
                    Picker(String(localized: "flow.key"), selection: $flow.key) {
                        ForEach(FlowKey.allCases) { key in
                            Text(verbatim: key.label).tag(key)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                .disabled(!flow.isEnabled)

                if flow.key == .fn {
                    Text(String(localized: "flow.fn-help"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if flow.isEnabled {
                    if flow.trusted {
                        Label(String(localized: "flow.access-ok"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(String(localized: "flow.accessibility"))
                                    .font(.system(size: 11))
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(String(localized: "flow.accessibility-open")) {
                                    flow.openAccessibilitySettings()
                                }
                            }
                        }
                    }
                }

                Text(String(localized: "flow.privacy"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
        .onAppear { flow.recheckTrust() }
    }
}
#endif
