import SwiftUI
import AppKit

struct IslandScreenPicker: View {
    @ObservedObject var state: AppState
    @State private var screens = IslandScreenSelection.availableScreens()

    var body: some View {
        GroupBox("Display") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Default screen", selection: $state.preferredScreenID) {
                    Text("Automatic (notch or primary screen)").tag("")
                    ForEach(screens) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                    if !state.preferredScreenID.isEmpty && !screens.contains(where: { $0.id == state.preferredScreenID }) {
                        Text("Disconnected screen").tag(state.preferredScreenID)
                    }
                }
                Text("Used next time Coucou starts. If unavailable, Coucou uses the notch or primary screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = IslandScreenSelection.availableScreens()
            }
        }

    }
}
