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
    @AppStorage("flowMuteMac") private var muteMac = true   // SystemMute.enabledKey
    @State private var editingShortcut = false

    var body: some View {
        HubPageScaffold(title: String(localized: "hub.page.settings")) {
            HubLabel(String(localized: "hub.settings.keys"))
                .settingsHeading("flow.keys")
            HubCard {
                HubRow(title: String(localized: "flow.enable")) {
                    Toggle("", isOn: $flow.isEnabled).toggleStyle(.switch).labelsHidden()
                }
                HubDivider()
                VStack(alignment: .leading, spacing: 0) {
                    HubRow(title: String(localized: "hub.settings.hold"),
                           detail: flow.key == .fn ? String(localized: "flow.fn-help") : nil) {
                        FlowKeyPicker(editing: $editingShortcut)
                    }
                    // Unfolds under "Hold to dictate" to record a shortcut, folds back once saved.
                    FlowCollapsible(isOpen: editingShortcut) {
                        VStack(alignment: .leading, spacing: 12) {
                            HubDivider()
                            FlowShortcutEditor(active: editingShortcut) { _ in
                                withAnimation(FlowMotion.fold) { editingShortcut = false }
                            }
                        }
                        .padding(.top, 12)
                    }
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
                HubRow(title: String(localized: "flow.mute-mac"), detail: String(localized: "flow.mute-mac-detail")) {
                    Toggle("", isOn: $muteMac).toggleStyle(.switch).labelsHidden()
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
                .settingsAnchor("flow.keys", cornerRadius: 14)

            HubLabel(String(localized: "flow.ai.title"))
                .settingsHeading("flow.ai")
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
                .settingsAnchor("flow.ai", cornerRadius: 14)

            HubLabel(String(localized: "hub.settings.permission"))
                .settingsHeading("flow.permission")
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
                .settingsAnchor("flow.permission", cornerRadius: 14)

            HubLabel(String(localized: "hub.settings.recognition"))
                .settingsHeading("flow.recognition")
            HubCard {
                HubRecognitionSettings(language: $language)
            }
                .settingsAnchor("flow.recognition", cornerRadius: 14)

            HubLabel(String(localized: "hub.page.notes"))
                .settingsHeading("flow.summary")
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
                .settingsAnchor("flow.summary", cornerRadius: 14)

            HubLabel(String(localized: "hub.settings.app"))
                .settingsHeading("flow.app")
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
                .settingsAnchor("flow.app", cornerRadius: 14)

            HubLabel(String(localized: "hub.settings.privacy"))
                .settingsHeading("flow.privacy")
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
                .settingsAnchor("flow.privacy", cornerRadius: 14)
        }
        .onAppear { flow.recheckTrust() }
        .alert(String(localized: "hub.settings.clear-all-confirm"), isPresented: $confirmClear) {
            Button(String(localized: "hub.settings.clear-all"), role: .destructive) { store.clearEverything() }
            Button(String(localized: "hub.cancel"), role: .cancel) {}
        }
    }
}

/// A key drawn like a keycap.
/// The motion of the sections that unfold: smooth, no bounce.
enum FlowMotion {
    static var fold: Animation { .smooth(duration: 0.34) }
}

/// Unfolds and folds its content smoothly: its real height is measured, then the height is what
/// moves (the rows below follow), with a fade. Its content stays laid out while folded.
struct FlowCollapsible<Content: View>: View {
    let isOpen: Bool
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                // Open, a change inside (a message appears) moves the height smoothly too.
                if isOpen, height > 0 { withAnimation(.smooth(duration: 0.22)) { height = new } } else { height = new }
            }
            .frame(height: isOpen ? height : 0, alignment: .top)
            .clipped()
            .opacity(isOpen ? 1 : 0)
            .allowsHitTesting(isOpen)
            .accessibilityHidden(!isOpen)
    }
}

/// "Hold to dictate": the four keys, your shortcut once saved (in place of "Custom shortcut"),
/// and an entry to record a new one, which unfolds the editor below.
struct FlowKeyPicker: View {
    @ObservedObject private var flow = FlowDictation.shared
    @Binding var editing: Bool

    private enum Choice: Hashable { case key(FlowKey), record }

    var body: some View {
        Picker("", selection: Binding<Choice>(
            get: { .key(flow.key) },
            set: { choice in
                withAnimation(FlowMotion.fold) {
                    switch choice {
                    case .key(let key):
                        editing = false
                        flow.key = key
                    case .record:
                        editing = true
                    }
                }
            })) {
            ForEach(FlowKey.presets) { Text(verbatim: $0.label).tag(Choice.key($0)) }
            if flow.key == .custom || !flow.shortcutOrder.isEmpty {
                Text(verbatim: flow.shortcutOrder.isEmpty ? String(localized: "flow.key-custom")
                                                          : FlowShortcut.compact(flow.shortcutOrder))
                    .tag(Choice.key(.custom))
            }
            Divider()
            Text(verbatim: flow.shortcutOrder.isEmpty ? String(localized: "flow.key-custom-new")
                                                      : String(localized: "flow.key-custom-change"))
                .tag(Choice.record)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Records a custom shortcut: hold the keys together, let go, ↩ saves (Esc cancels). The keys show
/// as key caps in the order they were pressed. Listening starts when the section unfolds.
struct FlowShortcutEditor: View {
    let active: Bool
    let onFinish: (Bool) -> Void
    @StateObject private var recording = FlowShortcutRecording()
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("flow.shortcut.title").font(.system(size: 13.5, weight: .medium))
                    Text("flow.shortcut.detail")
                        .font(.system(size: 12))
                        .foregroundColor(HubTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                // A click always (re)starts the recording, it never stops it.
                Button { recording.start() } label: { field }
                    .buttonStyle(.plain)
            }
            hint
        }
        .onAppear {
            recording.onFinish = onFinish
            if active { recording.start() }
        }
        .onChange(of: active) { _, on in
            recording.onFinish = onFinish
            if on { recording.start() } else { recording.stop() }
        }
        .onDisappear { recording.stop() }
        .onChange(of: recording.isRecording) { _, on in
            pulse = false
            if on { withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { pulse = true } }
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            if recording.keys.isEmpty {
                Text(recording.isRecording ? String(localized: "flow.shortcut.listening")
                                           : String(localized: "flow.shortcut.empty"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(recording.isRecording ? HubTheme.accent : HubTheme.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            } else {
                ForEach(recording.keys, id: \.self) { code in
                    HubKeyCap(text: FlowShortcut.capName(code))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            // Listening: a dot that breathes. Once the keys are in, only they show (↩ is said below).
            if !recording.canSave {
                Image(systemName: recording.isRecording ? "record.circle" : "keyboard")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(recording.isRecording ? HubTheme.accent : HubTheme.secondary)
                    .opacity(recording.isRecording && pulse ? 0.3 : 1)
                    .padding(.leading, 2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 190, minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(recording.isRecording ? HubTheme.accent.opacity(pulse && !recording.canSave ? 0.5 : 1) : HubTheme.line,
                          lineWidth: recording.isRecording ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.smooth(duration: 0.22), value: recording.keys)
        .animation(.smooth(duration: 0.2), value: recording.canSave)
        .fixedSize()
    }

    /// One line under the field: how to record, how to save, or what is wrong.
    private var hint: some View {
        Group {
            if let problem = recording.problem {
                Label(message(problem), systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(HubTheme.red)
            } else if recording.canSave {
                Text("flow.shortcut.confirm")
                    .foregroundColor(HubTheme.accent)
            } else {
                Text("flow.shortcut.recording")
                    .foregroundColor(HubTheme.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.smooth(duration: 0.2), value: recording.problem)
        .animation(.smooth(duration: 0.2), value: recording.canSave)
    }

    private func message(_ problem: FlowShortcutRules.Problem) -> String {
        switch problem {
        case .needsModifier: return String(localized: "flow.shortcut.needs-modifier")
        case .tooCommon:     return String(localized: "flow.shortcut.too-common")
        case .forbiddenKey:  return String(localized: "flow.shortcut.forbidden")
        case .tooMany:       return String(localized: "flow.shortcut.too-many")
        }
    }
}

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
