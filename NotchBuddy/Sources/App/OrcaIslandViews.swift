import SwiftUI

// Orca data in the island: the counters of the closed island and the open workspace list.
// Placeholder styling, consistent with the existing cards; read-only (no row action).

private enum OrcaColors {
    static let running = Color(hex: "#3B9EFF")
    static let finished = Color(hex: "#34D399")
    static let alert = Color(hex: "#F5A524")
    static let failed = Color(hex: "#F4505E")
    static let review = Color(hex: "#A78BFA")
    static let idle = Color(hex: "#6B7079")
    static let text = Color(hex: "#F5F6F8")
    static let secondary = Color(hex: "#8E939C")
}

// MARK: - Icons (the Orca sidebar's: spinner, check-circle, bell)

/// Rotating arc; the animation only exists while the view is on screen and active.
struct OrcaSpinner: View {
    var size: CGFloat = 10
    var color: Color = OrcaColors.running
    @Environment(\.islandViewActive) private var active
    @State private var turn = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 0.82)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.2, size / 8), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(turn ? 360 : 0))
            .onAppear { restart() }
            .onChange(of: active) { _, _ in restart() }
            .onDisappear { turn = false }
    }

    private func restart() {
        turn = false
        guard active else { return }
        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turn = true }
    }
}

struct OrcaStatusIcon: View {
    let status: OrcaAgentStatus
    var size: CGFloat = 10

    var body: some View {
        switch status {
        case .running:  OrcaSpinner(size: size)
        case .finished: Image(systemName: "checkmark.circle").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.finished)
        case .alert:    Image(systemName: "bell.fill").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.alert)
        case .idle:     Image(systemName: "circle.dotted").font(.system(size: size)).foregroundColor(OrcaColors.idle)
        }
    }
}

struct OrcaWorkspaceStateIcon: View {
    let state: OrcaWorkspaceState
    var size: CGFloat = 13

    var body: some View {
        Group {
            switch state {
            case .running:   OrcaSpinner(size: size)
            case .done:      OrcaStatusIcon(status: .finished, size: size)
            case .attention: OrcaStatusIcon(status: .alert, size: size)
            case .failed:    Image(systemName: "xmark.circle.fill").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.failed)
            case .review:    Image(systemName: "eye.circle").font(.system(size: size, weight: .semibold)).foregroundColor(OrcaColors.review)
            case .idle:      OrcaStatusIcon(status: .idle, size: size)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }
}

// MARK: - Closed island: three agent counters

struct OrcaCounterStrip: View {
    let counts: OrcaAgentCounts

    var body: some View {
        HStack(spacing: 6) {
            if counts.running > 0 { counter(.running, counts.running) }
            if counts.finished > 0 { counter(.finished, counts.finished) }
            if counts.alert > 0 { counter(.alert, counts.alert) }
        }
        .fixedSize()
        .animation(.easeInOut(duration: 0.2), value: counts)
    }

    private func counter(_ status: OrcaAgentStatus, _ n: Int) -> some View {
        HStack(spacing: 2) {
            OrcaStatusIcon(status: status, size: 10)
            Text("\(n)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(OrcaColors.text)
        }
    }
}

// MARK: - Open island: flat workspace list + usage footer

struct OrcaWorkspaceListView: View {
    @ObservedObject var state: AppState

    /// Workspaces worth a row: anything with an agent or a non-idle state. Already ordered by the
    /// derivation (failed, needs you, running, review, done; then most recent).
    private var rows: [OrcaWorkspace] {
        state.orca.workspaces.filter { $0.state != .idle || !$0.agents.isEmpty }
    }

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            VStack(spacing: 0) {
                if rows.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { OrcaWorkspaceRow(workspace: $0) }
                        }
                    }
                }
                OrcaUsageFooter(usage: state.orca.usage)
            }
            .padding(.leading, 108)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Spacer()
            Text(state.orca.orca.ok ? "Nothing running in Orca." : "Orca is not reachable.")
                .font(.system(size: 13, weight: .semibold))
            Text(state.orca.orca.ok ? "Agents and workspaces show up here." : "Open Orca and this list fills in.")
                .font(.system(size: 11))
                .foregroundColor(OrcaColors.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct OrcaWorkspaceRow: View {
    let workspace: OrcaWorkspace

    var body: some View {
        HStack(spacing: 8) {
            OrcaWorkspaceStateIcon(state: workspace.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(OrcaColors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(OrcaColors.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let pr = workspace.pr, let number = pr.number {
                Text("PR #\(number)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(pr.isOpen ? OrcaColors.finished : OrcaColors.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))
                    .fixedSize()
            }
            HStack(spacing: 3) {
                ForEach(Array(workspace.agents.enumerated()), id: \.offset) { _, agent in
                    OrcaStatusIcon(status: agent.status, size: 10)
                }
            }
            .fixedSize()
            Text(ago)
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(OrcaColors.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())   // read-only: hovering and clicking do nothing
    }

    private var subtitle: String {
        [workspace.repo, workspace.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var ago: String {
        workspace.lastActivityAt.map { OrcaFormatting.ago(since: $0) } ?? ""
    }
}

struct OrcaUsageFooter: View {
    let usage: [OrcaProviderUsage]

    var body: some View {
        if !usage.isEmpty {
            VStack(spacing: 4) {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(usage) { provider in
                            HStack(spacing: 5) {
                                Text(provider.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(OrcaColors.text)
                                window("session", provider.session)
                                window("week", provider.weekly)
                            }
                            .fixedSize()
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func window(_ name: String, _ w: OrcaUsageWindow?) -> some View {
        if let w {
            let tint: Color = w.pct >= 90 ? OrcaColors.failed : w.pct >= 70 ? OrcaColors.alert : OrcaColors.secondary
            Text("\(name) \(Int(w.pct.rounded()))%\(w.resetText.map { " · resets \($0)" } ?? "")")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(tint)
        }
    }
}
