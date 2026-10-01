import SwiftUI
import ServiceManagement

struct SettingsGeneralTab: View {
    @ObservedObject private var state = AppState.shared
    @State private var language: AppLanguage = AppLanguage.current
    @State private var languageChanged = false
    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var hotkeyFlags: UInt = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16 = AppState.shared.hotkeyCode
    @State private var status: SettingsStatus?

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    var body: some View {
        SettingsPage(status: status) {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(verbatim: lang.displayName).tag(lang)
                    }
                }
                .onChange(of: language) { _, lang in
                    lang.apply()
                    languageChanged = true
                }
                Toggle("Launch at Mac startup", isOn: $launchAtStartup)
                    .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }
            } footer: {
                if languageChanged {
                    HStack {
                        Text("Restart Coucou to apply the new language.")
                        Spacer()
                        Button("Restart now") { AppLanguage.relaunch() }
                            .controlSize(.small)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                }
            }

            Section {
                Toggle("Show island with shortcut", isOn: $state.hotkeyEnabled)
                if state.hotkeyEnabled {
                    LabeledContent("Shortcut") {
                        ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                            .onChange(of: hotkeyFlags) { _, v in state.hotkeyFlags = v }
                            .onChange(of: hotkeyCode)  { _, v in state.hotkeyCode  = v }
                    }
                }
            } header: {
                Text("Hotkey")
            } footer: {
                if state.hotkeyEnabled {
                    Text("Click, then press the keys")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Section("Sound") {
                Toggle("Enable sounds", isOn: $state.soundEnabled)
                LabeledContent("Volume") {
                    HStack(spacing: 8) {
                        Slider(value: $state.soundVolume, in: 0...0.2)
                            .frame(width: 180)
                        Text(verbatim: "\(Int(state.soundVolume / 0.2 * 100)) %")
                            .frame(width: 40, alignment: .trailing)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(!state.soundEnabled)
            }

            Section("Behavior") {
                LabeledContent("Close after inactivity") {
                    NumberField(value: $state.autoCloseInterval, unit: "s")
                }
                LabeledContent("Hide after no movement") {
                    NumberField(value: absenceMinutes, unit: "min")
                }
            }
        }
        .toggleStyle(.switch)
    }

    private func toggleStartup(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
            status = nil
        } catch {
            status = .failure(String(localized: "Startup: \(error.localizedDescription)"))
            launchAtStartup = !on
        }
    }
}
