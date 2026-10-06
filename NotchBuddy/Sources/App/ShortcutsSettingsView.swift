import SwiftUI
import AppKit

// MARK: - ShortcutsSettingsView

/// "Shortcuts" section inside SettingsView.
struct ShortcutsSettingsView: View {
    // Conflicts detected by HotKeyCenter (system already owns that combo)
    @State private var systemConflicts: Set<ShortcutAction> = []
    // Internal duplicates (two Coucou shortcuts share the same combo)
    @State private var internalDups: Set<ShortcutAction> = []

    // Per-action state (enabled flag + current spec)
    @State private var enabled:  [ShortcutAction: Bool]          = [:]
    @State private var specs:    [ShortcutAction: ShortcutSpec]  = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            globalSection
            islandSection
        }
        .onAppear { reload() }
    }

    // MARK: - Global shortcuts

    private var globalSection: some View {
        GroupBox("Global shortcuts — work from any app") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(globalActions, id: \.self) { action in
                    shortcutRow(action)
                    if action != globalActions.last {
                        Divider().padding(.leading, 24)
                    }
                }
                Divider().padding(.top, 8)
                HStack {
                    Spacer()
                    Button("Reset all to defaults") { resetAll() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(.top, 6)
            }
            .padding(6)
        }
    }

    /// Shortcuts listed here. The App Store build hides the ones it can't run.
    private var globalActions: [ShortcutAction] {
        #if APPSTORE
        ShortcutAction.allCases.filter { !$0.isNonAppStore }
        #else
        ShortcutAction.allCases
        #endif
    }

    @ViewBuilder
    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let isEnabled    = enabled[action] ?? action.enabledByDefault
        let spec         = specs[action]   ?? ShortcutLogic.defaults[action]!
        let hasSysConf   = systemConflicts.contains(action)
        let hasIntConf   = internalDups.contains(action)

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { v in toggleAction(action, enabled: v) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: 18)

            Text(action.displayName)
                .font(.system(size: 12))
                .frame(minWidth: 160, alignment: .leading)

            Spacer(minLength: 4)

            ShortcutRecorderButton(flags: specFlagsBinding(action), code: specCodeBinding(action))
                .disabled(!isEnabled)
                .onChangeCompat(of: specs[action]) { _, _ in specChanged(action) }

            if hasSysConf {
                conflictTag("System conflict", color: .orange)
            } else if hasIntConf {
                conflictTag("Duplicate", color: .red)
            }
        }
        .padding(.vertical, 5)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func conflictTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
    }

    // MARK: - Island-local shortcuts (read-only)

    private var islandSection: some View {
        GroupBox("Island shortcuts — active when the island is focused") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ShortcutLogic.islandShortcuts.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 10) {
                        Text(pair.key)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        Text(pair.description)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    if pair.key != ShortcutLogic.islandShortcuts.last?.key {
                        Divider().padding(.leading, 100)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Bindings

    private func specFlagsBinding(_ action: ShortcutAction) -> Binding<UInt> {
        Binding(
            get: { (specs[action] ?? ShortcutLogic.defaults[action]!).nsFlags },
            set: { v in
                var s = specs[action] ?? ShortcutLogic.defaults[action]!
                s.nsFlags = v
                specs[action] = s
            }
        )
    }

    private func specCodeBinding(_ action: ShortcutAction) -> Binding<UInt16> {
        Binding(
            get: { (specs[action] ?? ShortcutLogic.defaults[action]!).keyCode },
            set: { v in
                var s = specs[action] ?? ShortcutLogic.defaults[action]!
                s.keyCode = v
                specs[action] = s
            }
        )
    }

    // MARK: - Actions

    private func reload() {
        for action in ShortcutAction.allCases {
            enabled[action] = ShortcutLogic.isEnabled(action)
            specs[action]   = ShortcutLogic.hotKey(for: action)
        }
        systemConflicts = HotKeyCenter.shared.conflicts
        updateInternalDups()
    }

    private func toggleAction(_ action: ShortcutAction, enabled v: Bool) {
        enabled[action] = v
        ShortcutLogic.setEnabled(v, for: action)
        HotKeyCenter.shared.reregister(action)
        systemConflicts = HotKeyCenter.shared.conflicts
    }

    private func specChanged(_ action: ShortcutAction) {
        guard let s = specs[action] else { return }
        ShortcutLogic.save(s, for: action)
        HotKeyCenter.shared.reregister(action)
        systemConflicts = HotKeyCenter.shared.conflicts
        updateInternalDups()
    }

    private func resetAll() {
        for action in ShortcutAction.allCases {
            ShortcutLogic.resetToDefault(action)
            HotKeyCenter.shared.reregister(action)
        }
        reload()
    }

    private func updateInternalDups() {
        var all: [ShortcutAction: ShortcutSpec] = [:]
        for action in ShortcutAction.allCases {
            if ShortcutLogic.isEnabled(action) {
                all[action] = ShortcutLogic.hotKey(for: action)
            }
        }
        internalDups = ShortcutLogic.duplicates(in: all)
    }
}
