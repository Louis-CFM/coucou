#if !APPSTORE
import SwiftUI

// MARK: - Notch card: "Coucou 0.6.0 is out", one click to install it

struct UpdateCardView: View {
    @ObservedObject private var updater = MacUpdater.shared

    var body: some View {
        ZStack {
            CardBackground(wash: .green)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .asking:
            title(String(localized: "update.ask.title"))
            line(String(localized: "update.ask.body"))
            HStack(spacing: 8) {
                PrimaryButton(verbatim: String(localized: "update.ask.yes")) { updater.answer(true) }
                SecondaryButton(verbatim: String(localized: "update.ask.no")) { updater.answer(false) }
            }

        case .available(let r):
            header(r)
            HStack(spacing: 8) {
                PrimaryButton(verbatim: String(localized: "update.now")) { updater.install() }
                SecondaryButton(verbatim: String(localized: "update.whats-new")) { updater.openReleasePage() }
                SecondaryButton(verbatim: String(localized: "update.later")) { updater.later() }
            }

        case .downloading(let r, let fraction):
            header(r)
            ProgressView(value: max(0, min(1, fraction)))
                .progressViewStyle(.linear)
                .tint(Color(hex: "#34D399"))
                .frame(maxWidth: 260)
            line(String(localized: "update.downloading") + "  \(Int((fraction * 100).rounded())) %")

        case .verifying(let r):
            header(r)
            working(String(localized: "update.verifying"))

        case .installing(let r):
            header(r)
            working(String(localized: "update.installing"))

        case .relaunching(let r):
            header(r)
            working(String(localized: "update.relaunching"))

        case .manual(let r):
            header(r)
            line(String(localized: "update.manual"))
            HStack(spacing: 8) {
                PrimaryButton(verbatim: String(localized: "update.open-github")) { updater.openReleasePage() }
                SecondaryButton("OK") { updater.dismiss() }
            }

        case .failed(_, let message):
            title(String(localized: "update.failed"))
            line(message)
            HStack(spacing: 8) {
                PrimaryButton(verbatim: String(localized: "update.open-github")) { updater.openReleasePage() }
                SecondaryButton("OK") { updater.dismiss() }
            }

        case .idle:
            title(String(localized: "update.up-to-date"))
            SecondaryButton("OK") { updater.dismiss() }
        }
    }

    private func header(_ r: MacUpdate.Release) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            title(String(format: String(localized: "update.title %@"), r.version))
            line(r.headline.map { "\($0)  ·  " + String(format: String(localized: "update.you-have %@"), MacUpdater.currentVersion) }
                 ?? String(format: String(localized: "update.you-have %@"), MacUpdater.currentVersion))
        }
    }

    private func title(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .lineLimit(1)
    }

    private func line(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundColor(Color(hex: "#8E939C"))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func working(_ s: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small)
            line(s)
        }
    }
}

// MARK: - Settings → General → Updates

struct UpdateSettingsSection: View {
    @ObservedObject private var updater = MacUpdater.shared
    @State private var enabled = MacUpdater.consent == true

    var body: some View {
        GroupBox(String(localized: "update.settings.title")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(String(localized: "update.settings.toggle"), isOn: $enabled)
                    .onChange(of: enabled) { _, on in updater.setEnabled(on) }
                Text(String(localized: "update.settings.footer"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if let r = updater.latest {
                        Button(String(format: String(localized: "update.settings.install %@"), r.version)) { updater.show(r) }
                    }
                    Button(String(localized: "update.settings.check")) {
                        Task { await updater.check(manual: true) }
                    }
                    .disabled(updater.lastCheck == .checking || updater.busy)
                    status
                }
                Text(String(format: String(localized: "update.you-have %@"), MacUpdater.currentVersion))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.lastCheck {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text(String(localized: "update.up-to-date")).font(.system(size: 11)).foregroundColor(.secondary)
        case .unreachable: Text(String(localized: "update.settings.unreachable")).font(.system(size: 11)).foregroundColor(.secondary)
        case .none: EmptyView()
        }
    }
}
#endif
