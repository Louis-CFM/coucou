import SwiftUI

#if !APPSTORE

// MARK: - Settings → Botan
//
// One box, styled like the Android one. Off by default: turning the switch on opens Bluetooth and
// looks for Botan, turning it off closes everything.

struct BotanLinkSettingsBox: View {
    @ObservedObject private var link = BotanLinkService.shared
    @AppStorage(BotanLinkService.enabledKey) private var enabled = false

    var body: some View {
        GroupBox("Botan") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(String(localized: "botan.link.toggle"), isOn: $enabled)
                    .onChange(of: enabled) { _, on in link.setEnabled(on) }
                note(String(localized: "botan.link.description"))
                if enabled { note(statusText) }
            }
            .padding(6)
        }
    }

    private var statusText: String {
        switch link.status {
        case .off: return String(localized: "botan.link.status.searching")
        case .searching, .connecting: return String(localized: "botan.link.status.searching")
        case .bluetoothOff: return String(localized: "botan.link.status.bluetooth")
        case .unauthorized: return String(localized: "botan.link.status.unauthorized")
        case .linked(let name): return String(format: String(localized: "botan.link.status.linked %@"), name)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#endif
