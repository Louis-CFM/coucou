import SwiftUI

// MARK: - Side panel (right card)
//
// Opened from the GitHub and Vercel cards: it takes the place of the agent pills
// until it is closed (✕, Esc, tapping its opener again) or anything else needs the
// island — an approval, a question, a focus change, the island collapsing.

struct SidePanelView: View {
    @ObservedObject var state: AppState
    let panel: SidePanel

    private func close() {
        withAnimation(.easeInOut(duration: 0.16)) { state.sidePanel = nil }
    }

    /// Another pill has an alert badge while its pill is hidden behind the panel.
    private var othersNeedAttention: Bool {
        state.tasks.contains { $0.id != state.focusId && $0.pillBadge != nil }
    }

    var body: some View {
        Group {
            switch panel {
            case .githubRepos:
                FocusPickerPanel(
                    title: "Repositories", accent: "#F4505E", allLabel: "All repos",
                    options: state.githubFocusOptions,
                    selection: state.effectiveGithubFocus,
                    shortLabel: { $0.split(separator: "/").last.map(String.init) ?? $0 },
                    attention: othersNeedAttention, onClose: close,
                    onPick: { repo in
                        state.githubFocusRepo = repo
                        GithubPoller.shared.refreshIfStale()
                        close()
                    })
            case .vercelProjects:
                FocusPickerPanel(
                    title: "Projects", accent: "#7C5CFF", allLabel: "All projects",
                    options: state.vercelFocusOptions,
                    selection: state.effectiveVercelFocus,
                    attention: othersNeedAttention, onClose: close,
                    onPick: { project in
                        state.vercelFocusProject = project
                        close()
                    })
            case .github(let section):
                GitHubSectionPanel(section: section, pulse: state.githubVisiblePulse,
                                   attention: othersNeedAttention, onClose: close)
            case .vercelDeployment(let id):
                if let dep = state.vercelDeployments.first(where: { $0.id == id }) {
                    VercelDeploymentPanel(deployment: dep, attention: othersNeedAttention, onClose: close)
                } else {
                    SidePanelChrome(title: "Deployment", accent: "#7C5CFF", attention: othersNeedAttention,
                                    onClose: close) {
                        SidePanelEmpty(text: "This deployment is no longer in the list")
                    }
                }
            }
        }
        .onExitCommand { close() }
    }
}

// MARK: - Chrome (header + content)

struct SidePanelChrome<Content: View>: View {
    let title: String
    let accent: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    let attention: Bool
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: accent))
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let trailing { trailing }
                SidePanelCloseButton(attention: attention, action: onClose)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 9)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Same look as the ↗ button of the left card. The amber dot says another pill,
/// hidden behind the panel, has something to show.
private struct SidePanelCloseButton: View {
    let attention: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(Color(hex: isHovered ? "#C5C8CD" : "#5F646D"))
                .frame(width: 16, height: 16)
                .background(Color.white.opacity(isHovered ? 0.12 : 0.07))
                .clipShape(Circle())
                .overlay(alignment: .topTrailing) {
                    if attention {
                        Circle()
                            .fill(Color(hex: "#F5A524"))
                            .frame(width: 5, height: 5)
                            .offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(attention ? "Close — other agents have updates" : "Close")
    }
}

private struct SidePanelEmpty: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(Color(hex: "#6B7079"))
            .padding(.top, 2)
    }
}

/// Fades the last rows of a list that scrolls.
private struct ScrollFade: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content.mask(
            Group {
                if active {
                    LinearGradient(stops: [.init(color: .black, location: 0),
                                           .init(color: .black, location: 0.78),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color.black
                }
            }
        )
    }
}

// MARK: - Focus picker (repo / project chips)

struct FocusPickerPanel: View {
    let title: String
    let accent: String
    let allLabel: String
    let options: [String]
    let selection: String?
    var shortLabel: (String) -> String = { $0 }
    let attention: Bool
    let onClose: () -> Void
    let onPick: (String?) -> Void

    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        SidePanelChrome(title: title, accent: accent, subtitle: "\(options.count)",
                        attention: attention, onClose: onClose) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: columns, spacing: 4) {
                    FocusChip(label: allLabel, accent: accent, selected: selection == nil) { onPick(nil) }
                    ForEach(options, id: \.self) { option in
                        FocusChip(label: shortLabel(option), accent: accent, selected: option == selection) {
                            onPick(option)
                        }
                        .help(option)
                    }
                }
                .padding(.vertical, 1)
            }
            .modifier(ScrollFade(active: options.count + 1 > 4))
        }
    }
}

/// A pill-shaped choice, styled like the agent pills.
private struct FocusChip: View {
    let label: String
    let accent: String
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            SoundEngine.shared.play("blip")
            action()
        }) {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                }
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(selected || isHovered
                             ? Color(hex: accent).lighter(by: 0.3)
                             : Color(hex: "#6B7079"))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(
                Capsule().fill(selected ? Color(hex: accent).opacity(0.18)
                               : isHovered ? Color(hex: accent).opacity(0.10)
                               : Color(hex: "#0E0F11"))
            )
            .overlay(
                Capsule().stroke(Color(hex: accent).opacity(selected ? 0.55 : isHovered ? 0.4 : 0.14),
                                 lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = h }
        }
    }
}

// MARK: - GitHub section (PRs, reviews, default-branch CI)

struct GitHubSectionPanel: View {
    let section: GitHubDetailSection
    let pulse: GitHubPulse?
    let attention: Bool
    let onClose: () -> Void
    @ObservedObject private var appState = AppState.shared

    private var title: String {
        switch section {
        case .myPRs:    return "My PRs"
        case .toReview: return "To review"
        case .mainCI:   return "Default branch CI"
        case .activity: return "Activity"
        }
    }

    private var prs: [GitHubPR] {
        guard let pulse else { return [] }
        switch section {
        case .myPRs:    return pulse.myPRs
        case .toReview: return pulse.toReview
        case .mainCI, .activity: return []
        }
    }

    private var repos: [GitHubRepoCI] {
        section == .mainCI ? (pulse?.mainCI ?? []) : []
    }

    private var total: Int { prs.count + repos.count }

    var body: some View {
        SidePanelChrome(title: title, accent: "#F4505E", subtitle: "\(total)",
                        attention: attention, onClose: onClose) {
            if total == 0 {
                SidePanelEmpty(text: "Nothing here")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(prs.enumerated()), id: \.element.id) { idx, pr in
                            GitHubPRRowView(pr: pr, showCI: section == .myPRs,
                                            selected: appState.cardSelection == idx)
                        }
                        ForEach(Array(repos.enumerated()), id: \.element.repo) { idx, repo in
                            GitHubRepoCIRowView(repo: repo,
                                                selected: appState.cardSelection == prs.count + idx)
                        }
                    }
                }
                .modifier(ScrollFade(active: total > 3))
            }
        }
        .onAppear {
            GithubPoller.shared.refreshIfStale()
            appState.cardItemCount = total
        }
        .onChange(of: total) { _, n in appState.cardItemCount = n }
        .onDisappear { appState.cardItemCount = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .islandActivateCardSelection)) { _ in
            guard let sel = appState.cardSelection else { return }
            let link: String
            if sel < prs.count {
                link = prs[sel].url
            } else {
                let i = sel - prs.count
                guard i < repos.count else { return }
                link = repos[i].url.hasSuffix("/") ? repos[i].url + "actions" : repos[i].url + "/actions"
            }
            if let url = safeWebURL(link), url.host == "github.com" { NSWorkspace.shared.open(url) }
        }
    }
}

// MARK: - Vercel deployment

struct VercelDeploymentPanel: View {
    let deployment: VercelDeployment
    let attention: Bool
    let onClose: () -> Void

    private var accentHex: String {
        switch deployment.state {
        case "READY":    return "#22C55E"
        case "CANCELED": return "#6B7079"
        default:         return "#F4505E"
        }
    }

    private var targetLabel: String {
        guard let t = deployment.target, !t.isEmpty else { return "Preview" }
        return t.capitalized
    }

    var body: some View {
        let accent = Color(hex: accentHex)
        SidePanelChrome(
            title: deployment.projectName, accent: accentHex,
            trailing: AnyView(
                Text(deployment.statusLabel)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(accent.opacity(0.14))
                    .clipShape(Capsule())
            ),
            attention: attention, onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: 5) {
                Text(deployment.commitMessage?.split(separator: "\n").first.map(String.init) ?? "No commit message")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: deployment.commitMessage == nil ? "#6B7079" : "#C5C8CD"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    if let branch = deployment.branch {
                        Label(branch, systemImage: "arrow.branch")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(targetLabel)
                    Text(deployment.timeAgo == "just now" ? "just now" : deployment.timeAgo + " ago")
                }
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#6B7079"))
                Button(action: {
                    if let url = safeWebURL("https://\(deployment.url)") { NSWorkspace.shared.open(url) }
                }) {
                    HStack(spacing: 4) {
                        Text(deployment.url)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 7, weight: .semibold))
                    }
                    .foregroundColor(Color(hex: "#7C5CFF").opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
