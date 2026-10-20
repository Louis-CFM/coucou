#if !APPSTORE
import AppKit
import SwiftUI

/// Coucou Flow → Settings: the key, the permission, the recognition and the history.
struct HubSettingsPage: View {
    @ObservedObject private var flow = FlowDictation.shared
    @ObservedObject private var store = FlowStore.shared
    @AppStorage("dictationLanguage") private var language = MacDictation.automatic
    @State private var confirmClear = false
    @State private var showInDock = FlowHubController.showInDock
    @State private var openAtLaunch = FlowHubController.openAtLaunch

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.settings")) {
            HubLabel(String(localized: "hub.settings.keys"))
            HubCard {
                HubRow(title: String(localized: "flow.enable")) {
                    Toggle("", isOn: $flow.isEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.hold"),
                       detail: flow.key == .fn ? String(localized: "flow.fn-help") : nil) {
                    Picker("", selection: $flow.key) {
                        ForEach(FlowKey.allCases) { Text(verbatim: $0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HubDivider()
                HubRow(title: String(localized: "flow.edge")) {
                    Picker("", selection: $flow.pillEdge) {
                        ForEach(FlowPillEdge.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.handsfree"),
                       detail: String(localized: "hub.settings.handsfree-detail")) {
                    HubKeyCap(text: "\(flow.key.symbol) \(flow.key.symbol)")
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.paste-again"),
                       detail: String(localized: "hub.settings.paste-again-detail")) {
                    HubKeyCap(text: "⌃⌘V")
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.cancel")) {
                    HubKeyCap(text: String(localized: "hub.key-esc"))
                }
            }

            HubLabel(String(localized: "flow.ai.title"))
            HubCard {
                HubRow(title: String(localized: "flow.prompt-mode"), detail: String(localized: "flow.prompt-mode-detail")) {
                    Toggle("", isOn: $store.promptMode)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!FlowCleanup.hasKey && !store.promptMode)
                }
                HubDivider()
                HubRow(title: String(localized: "flow.translate"),
                       detail: FlowLanguages.language(store.translateTo).map {
                           String(format: String(localized: "flow.translate-on %@"), $0.name)
                       } ?? String(localized: "flow.translate-detail")) {
                    Picker("", selection: $store.translateTo) {
                        Text("flow.translate-off").tag("")
                        Divider()
                        ForEach(FlowLanguages.sorted) { Text(verbatim: $0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!FlowCleanup.hasKey && store.translateTo.isEmpty)
                }
                if !FlowCleanup.hasKey {
                    HStack(spacing: 10) {
                        Image(systemName: "key")
                            .foregroundColor(HubTheme.accent)
                        Text("hub.cleanup-key")
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "#C7CAD0"))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(String(localized: "hub.open-settings")) {
                            NotificationCenter.default.post(name: .openFullSettings, object: "chat")
                        }
                        .buttonStyle(HubButtonStyle())
                    }
                }
                Text("flow.ai-privacy")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HubLabel(String(localized: "hub.settings.permission"))
            HubCard {
                if flow.trusted {
                    Label(String(localized: "flow.access-ok"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(HubTheme.green)
                } else {
                    Text("flow.accessibility")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#C7CAD0"))
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "flow.accessibility-open")) { flow.openAccessibilitySettings() }
                        .buttonStyle(HubButtonStyle(primary: true))
                }
            }

            HubLabel(String(localized: "hub.settings.recognition"))
            HubCard {
                HubRecognitionSettings(language: $language)
            }

            HubLabel(String(localized: "hub.page.notes"))
            HubCard {
                HubSummaryEnginePicker()
                Text("notes.engine-detail")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HubDivider()
                Text("notes.legal")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HubLabel(String(localized: "hub.settings.app"))
            HubCard {
                HubRow(title: String(localized: "hub.settings.dock"), detail: String(localized: "hub.settings.dock-detail")) {
                    Toggle("", isOn: Binding(get: { showInDock }, set: { showInDock = $0; FlowHubController.showInDock = $0 }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                HubDivider()
                HubRow(title: String(localized: "hub.settings.open-at-launch")) {
                    Toggle("", isOn: Binding(get: { openAtLaunch }, set: { openAtLaunch = $0; FlowHubController.openAtLaunch = $0 }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            HubLabel(String(localized: "hub.settings.privacy"))
            HubCard {
                HubRow(title: String(localized: "hub.settings.keep")) {
                    Picker("", selection: $store.keepDays) {
                        Text("hub.keep.none").tag(0)
                        Text("hub.keep.week").tag(7)
                        Text("hub.keep.month").tag(30)
                        Text("hub.keep.year").tag(365)
                        Text("hub.keep.forever").tag(-1)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HubDivider()
                HStack(spacing: 8) {
                    Button(String(localized: "hub.settings.clear-history")) { store.clearHistory() }
                        .buttonStyle(HubButtonStyle())
                    Button(String(localized: "hub.settings.clear-all")) { confirmClear = true }
                        .buttonStyle(HubButtonStyle())
                }
                Text("hub.settings.privacy-text")
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { flow.recheckTrust() }
        .alert(String(localized: "hub.settings.clear-all-confirm"), isPresented: $confirmClear) {
            Button(String(localized: "hub.settings.clear-all"), role: .destructive) { store.clearEverything() }
            Button(String(localized: "hub.cancel"), role: .cancel) {}
        }
    }
}

/// A key drawn like a keycap.
struct HubKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
    }
}

/// How the voice becomes text: Parakeet on the Mac (once downloaded) or the Mac's recognizer.
struct HubRecognitionSettings: View {
    @Binding var language: String
    @ObservedObject private var store = FlowStore.shared
    @ObservedObject private var parakeet = Parakeet.shared

    var body: some View {
        HubEngineRow(selected: store.engine == .parakeet,
                     title: String(localized: "hub.engine.parakeet"),
                     detail: String(localized: "hub.engine.parakeet-detail")) {
            store.engine = .parakeet
        } trailing: {
            parakeetStatus
        }
        HubDivider()
        HubEngineRow(selected: store.engine == .apple,
                     title: String(localized: "hub.settings.engine-apple"),
                     detail: String(localized: "hub.settings.engine-apple-detail")) {
            store.engine = .apple
        } trailing: {
            EmptyView()
        }
        if store.engine == .apple {
            HubDivider()
            HubRow(title: String(localized: "Dictation language")) {
                Picker("", selection: $language) {
                    Text("Automatic").tag(MacDictation.automatic)
                    ForEach(MacDictation.allLanguages, id: \.self) { id in
                        Text(MacDictation.name(of: id)).tag(id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        } else if !parakeet.isReady {
            Text("hub.engine.fallback")
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var parakeetStatus: some View {
        switch parakeet.state {
        case .unsupported:
            Text("hub.engine.unsupported")
                .font(.system(size: 12))
                .foregroundColor(HubTheme.secondary)
        case .missing:
            Button(String(localized: "hub.engine.download")) { parakeet.download() }
                .buttonStyle(HubButtonStyle(primary: true))
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 110)
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 12))
                    .foregroundColor(HubTheme.secondary)
                    .monospacedDigit()
            }
        case .ready:
            Menu {
                Button(String(localized: "hub.engine.remove"), role: .destructive) { parakeet.remove() }
            } label: {
                Label(String(localized: "hub.engine.installed"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(HubTheme.green)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        case .failed:
            Button(String(localized: "hub.engine.retry")) { parakeet.download() }
                .buttonStyle(HubButtonStyle())
        }
    }
}

/// A recognizer to choose: a round mark, its name and what it does, and its status on the right.
private struct HubEngineRow<Trailing: View>: View {
    let selected: Bool
    let title: String
    let detail: String
    let choose: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Button(action: choose) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().strokeBorder(selected ? HubTheme.accent : Color(hex: "#5A5F68"),
                                              lineWidth: selected ? 5 : 1.5)
                    }
                    .frame(width: 17, height: 17)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 13.5, weight: .semibold))
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundColor(HubTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            trailing()
        }
    }
}
#endif
