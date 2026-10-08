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
                    shortLabel: state.githubRepoLabel,
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
            case .sessionBranch(let taskId):
                SessionBranchPanel(state: state, taskId: taskId, attention: othersNeedAttention, onClose: close)
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
    /// Result of the last action, shown in place of the subtitle for a few seconds.
    var status: PanelStatus? = nil
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
                if let status {
                    Text(status.text)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(Color(hex: status.neutral ? "#9398A1" : status.ok ? "#22C55E" : "#F4505E"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(status.text)
                        .transition(.opacity)
                } else if let subtitle {
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
    @StateObject private var status = PanelStatusModel()

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

    @ViewBuilder
    private func prAction(_ pr: GitHubPR) -> some View {
        let ref = "\(pr.repo)#\(pr.number)"
        if section == .myPRs, let preview = appState.vercelPreview(repo: pr.repo, branch: pr.headRef) {
            VercelPreviewDot(deployment: preview)
        }
        if section == .myPRs && !pr.isDraft {
            PanelActionButton(title: "Merge", symbol: "arrow.triangle.merge", accent: "#A371F7",
                              help: "Squash and merge \(ref)",
                              perform: { try await ServiceAPI.perform(kind: "github.merge", target: ref) },
                              onResult: finished)
        } else if section == .toReview {
            PanelActionButton(title: "Approve", symbol: "checkmark.seal", accent: "#22C55E",
                              help: "Approve \(ref)",
                              perform: { try await ServiceAPI.perform(kind: "github.approve", target: ref) },
                              onResult: finished)
        }
    }

    private func rerunAction(_ repo: GitHubRepoCI) -> some View {
        PanelActionButton(title: "Re-run", symbol: "arrow.clockwise", accent: "#F5A524",
                          help: "Re-run the failed jobs of the latest failed run on \(repo.branch)",
                          perform: {
                              guard let run = try await ServiceAPI.latestFailedRun(repo: repo.repo, branch: repo.branch) else {
                                  throw PanelNotice(message: "No failed run to re-run")
                              }
                              return try await ServiceAPI.perform(kind: "github.rerun", target: run)
                          },
                          onResult: finished,
                          onNotice: { status.show($0, ok: true, neutral: true) })
    }

    private func finished(_ message: String, _ ok: Bool) {
        status.show(message, ok: ok)
        // Give GitHub a moment, then show where things are.
        if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { GithubPoller.shared.triggerPulseNow() } }
    }

    var body: some View {
        SidePanelChrome(title: title, accent: "#F4505E", subtitle: "\(total)", status: status.current,
                        attention: attention, onClose: onClose) {
            if total == 0 {
                SidePanelEmpty(text: "Nothing here")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(prs.enumerated()), id: \.element.id) { idx, pr in
                            HStack(spacing: 6) {
                                GitHubPRRowView(pr: pr, showCI: section == .myPRs,
                                                selected: appState.cardSelection == idx)
                                prAction(pr)
                            }
                        }
                        ForEach(Array(repos.enumerated()), id: \.element.repo) { idx, repo in
                            HStack(spacing: 6) {
                                GitHubRepoCIRowView(repo: repo,
                                                    selected: appState.cardSelection == prs.count + idx)
                                if repo.ci == .failure { rerunAction(repo) }
                            }
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
    @StateObject private var status = PanelStatusModel()
    @State private var failureReason: String? = nil

    private func finished(_ message: String, _ ok: Bool) {
        status.show(message, ok: ok)
        if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { VercelPoller.shared.pollNow() } }
    }

    private var commitLine: String {
        deployment.commitMessage?.split(separator: "\n").first.map(String.init) ?? "No commit message"
    }

    private var accentHex: String { deployment.stateColor }

    private var targetLabel: String {
        guard let t = deployment.target, !t.isEmpty else { return "Preview" }
        return t.capitalized
    }

    var body: some View {
        let accent = Color(hex: accentHex)
        SidePanelChrome(
            title: deployment.projectName, accent: accentHex, status: status.current,
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
                if deployment.state == "ERROR" {
                    // Failed: the reason takes the commit line (the commit stays in the tooltip)
                    Text(failureReason ?? "Looking for the error…")
                        .font(.system(size: 10.5, design: failureReason == nil ? .default : .monospaced))
                        .foregroundColor(Color(hex: failureReason == nil ? "#6B7079" : "#F4505E").lighter(by: 0.2))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help([failureReason, commitLine].compactMap { $0 }.joined(separator: "\n\n"))
                } else {
                    Text(commitLine)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: deployment.commitMessage == nil ? "#6B7079" : "#C5C8CD"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
                HStack(spacing: 5) {
                    PanelLinkButton(title: "Open", accent: "#7C5CFF", help: deployment.url) {
                        if let url = safeWebURL("https://\(deployment.url)") { NSWorkspace.shared.open(url) }
                    }
                    if deployment.state == "READY" || deployment.state == "ERROR" {
                        PanelActionButton(title: "Redeploy", symbol: "arrow.clockwise", accent: "#7C5CFF",
                                          help: "Build this deployment again",
                                          perform: {
                                              try await ServiceAPI.perform(
                                                  kind: "vercel.redeploy",
                                                  target: "\(deployment.id)|\(deployment.projectName)|\(deployment.target ?? "")")
                                          },
                                          onResult: finished)
                    }
                    if deployment.isBuilding {
                        PanelActionButton(title: "Cancel build", symbol: "xmark.circle", accent: "#F4505E",
                                          help: "Stop this build",
                                          perform: { try await ServiceAPI.perform(kind: "vercel.cancel", target: deployment.id) },
                                          onResult: finished)
                    }
                    if deployment.state == "READY" && deployment.target != "production" {
                        PanelActionButton(title: "Promote", symbol: "arrow.up.circle", accent: "#22C55E",
                                          help: "Start a production build from this deployment, with your production environment variables",
                                          perform: {
                                              try await ServiceAPI.perform(
                                                  kind: "vercel.promote",
                                                  target: "\(deployment.id)|\(deployment.projectName)")
                                          },
                                          onResult: finished)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 1)
            }
        }
        // Keyed on the state too: a build that fails while the panel is open gets its reason
        .task(id: "\(deployment.id)|\(deployment.state)") {
            guard deployment.state == "ERROR" else { return }
            failureReason = nil
            let reason = try? await ServiceAPI.vercelFailureReason(id: deployment.id)
            failureReason = reason ?? "No error message from Vercel"
        }
    }
}

// MARK: - Actions

struct PanelStatus: Equatable {
    let text: String
    let ok: Bool
    var neutral = false   // information, neither a success nor a failure
}

/// Thrown by an action that had nothing to do (e.g. no failed run to re-run):
/// the button goes back to idle and the message shows in grey.
struct PanelNotice: Error {
    let message: String
}

/// The last action's result, cleared after a few seconds.
@MainActor
final class PanelStatusModel: ObservableObject {
    @Published var current: PanelStatus? = nil
    private var clear: DispatchWorkItem?

    func show(_ text: String, ok: Bool, neutral: Bool = false) {
        clear?.cancel()
        withAnimation(.easeInOut(duration: 0.16)) { current = PanelStatus(text: text, ok: ok, neutral: neutral) }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeInOut(duration: 0.16)) { self?.current = nil }
        }
        clear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 4 : 8), execute: work)
    }
}

/// A small capsule button that acts on GitHub or Vercel. Nothing runs on the first click:
/// it turns into "Confirm?" for 3 seconds, and only a second click runs the action.
struct PanelActionButton: View {
    let title: String
    let symbol: String
    let accent: String
    var help: String? = nil
    let perform: @MainActor () async throws -> String
    let onResult: (String, Bool) -> Void
    /// Shows a PanelNotice (nothing was done). Defaults to nothing.
    var onNotice: (String) -> Void = { _ in }

    private enum Phase { case idle, confirming, running, done, failed }
    @State private var phase: Phase = .idle
    @State private var isHovered = false
    @State private var reset: DispatchWorkItem?

    private var color: String {
        switch phase {
        case .idle, .running: return accent
        case .confirming:     return "#F5A524"
        case .done:           return "#22C55E"
        case .failed:         return "#F4505E"
        }
    }

    private func resetLater(_ seconds: Double) {
        reset?.cancel()
        let work = DispatchWorkItem { phase = .idle }
        reset = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func tap() {
        switch phase {
        case .idle:
            phase = .confirming
            SoundEngine.shared.play("blip")
            resetLater(3)
        case .confirming:
            reset?.cancel()
            phase = .running
            Task { @MainActor in
                do {
                    let message = try await perform()
                    phase = .done
                    SoundEngine.shared.play("finish")
                    onResult(message, true)
                } catch let notice as PanelNotice {
                    phase = .idle
                    SoundEngine.shared.play("blip")
                    onNotice(notice.message)
                    return
                } catch {
                    phase = .failed
                    SoundEngine.shared.play("error")
                    onResult(ServiceAPI.describe(error), false)
                }
                resetLater(2.5)
            }
        case .running, .done, .failed:
            break
        }
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 3) {
                switch phase {
                case .idle:
                    Image(systemName: symbol).font(.system(size: 7.5, weight: .bold))
                    Text(title)
                case .confirming:
                    Text("Confirm?")
                case .running:
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 8, height: 8)
                    Text(title)
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 7.5, weight: .bold))
                    Text("Done")
                case .failed:
                    Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold))
                    Text("Failed")
                }
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(Color(hex: color).lighter(by: 0.25))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(Color(hex: color).opacity(isHovered || phase == .confirming ? 0.24 : 0.13)))
            .overlay(Capsule().stroke(Color(hex: color).opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .layoutPriority(2)
        .onHover { isHovered = $0 }
        .help(phase == .confirming ? "Click again to confirm" : (help ?? title))
        .animation(.easeInOut(duration: 0.14), value: phase)
    }
}

/// Same shape as PanelActionButton for a plain link (no confirmation).
struct PanelLinkButton: View {
    let title: String
    let accent: String
    var help: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.up.right").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(Color(hex: isHovered ? "#C5C8CD" : "#8E939C"))
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 17)
            .background(Capsule().fill(Color.white.opacity(isHovered ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help ?? title)
    }
}

// MARK: - Claude Code session → branch

/// The chips after a session's name: its branch and PR.
struct SessionChips: View {
    @ObservedObject var state: AppState
    let taskId: String

    var body: some View {
        if let git = state.sessionGit[taskId] {
            SessionBranchChip(git: git, info: state.sessionBranchInfo(for: taskId),
                              isOpen: state.sidePanel == .sessionBranch(taskId)) {
                state.toggleSidePanel(.sessionBranch(taskId))
            }
        }
    }
}

/// Next to the session name: "#12" with the PR's CI dot, or the branch when it has no open PR.
struct SessionBranchChip: View {
    let git: GitRepoInfo
    let info: SessionBranchInfo?
    let isOpen: Bool
    let action: () -> Void
    @State private var isHovered = false

    private var ci: CIState { info?.pr?.ci ?? info?.branchCI ?? .unknown }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if ci != .unknown {
                    Circle()
                        .fill(ghCIDot(ci))
                        .frame(width: 5, height: 5)
                }
                if let pr = info?.pr {
                    Text("#\(pr.number)")
                } else {
                    Image(systemName: "arrow.branch").font(.system(size: 7, weight: .semibold))
                    Text(git.branch)
                        .truncationMode(.middle)
                        .frame(minWidth: 30, maxWidth: 60, alignment: .leading)
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color(hex: isHovered || isOpen ? "#C5C8CD" : "#8E939C"))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(Color.white.opacity(isHovered || isOpen ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)   // the branch gives way to the session name
        .onHover { isHovered = $0 }
        .help(info?.pr.map { "\($0.title) · \(git.repo)" } ?? "\(git.repo) · \(git.branch)")
    }
}

struct SessionBranchPanel: View {
    @ObservedObject var state: AppState
    let taskId: String
    let attention: Bool
    let onClose: () -> Void
    @StateObject private var status = PanelStatusModel()

    private var git: GitRepoInfo? { state.sessionGit[taskId] }
    private var info: SessionBranchInfo? { state.sessionBranchInfo(for: taskId) }

    private func finished(_ message: String, _ ok: Bool) {
        status.show(message, ok: ok)
        guard ok, let git else { return }
        SessionGitHubLinker.shared.invalidate(repo: git.repo, branch: git.branch)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            SessionGitHubLinker.shared.refresh(for: state.tasks.first { $0.id == taskId })
            GithubPoller.shared.triggerPulseNow()
        }
    }

    private func ciWord(_ ci: CIState) -> String {
        switch ci {
        case .failure: return "failing"
        case .pending: return "running"
        case .success: return "passing"
        case .unknown: return "no checks"
        }
    }

    var body: some View {
        let repoName = git.map { $0.repo.split(separator: "/").last.map(String.init) ?? $0.repo } ?? "Session"
        SidePanelChrome(title: repoName, accent: "#F4505E", subtitle: git?.branch, status: status.current,
                        attention: attention, onClose: onClose) {
            if let git {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) {
                        // Pull request
                        if let pr = info?.pr {
                            HStack(spacing: 6) {
                                GitHubPRRowView(pr: pr, showCI: true)
                                if !pr.isDraft {
                                    PanelActionButton(title: "Merge", symbol: "arrow.triangle.merge", accent: "#A371F7",
                                                      help: "Squash and merge \(pr.id)",
                                                      perform: { try await ServiceAPI.perform(kind: "github.merge", target: pr.id) },
                                                      onResult: finished)
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(info == nil ? "Looking for a pull request…" : "No open pull request")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(hex: "#6B7079"))
                                Spacer(minLength: 4)
                                if info != nil {
                                    PanelLinkButton(title: "Open PR", accent: "#F4505E",
                                                    help: "Compare \(git.branch) on GitHub") {
                                        let branch = git.branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? git.branch
                                        if let url = safeWebURL("https://github.com/\(git.repo)/compare/\(branch)?expand=1") {
                                            NSWorkspace.shared.open(url)
                                        }
                                    }
                                }
                            }
                            .frame(height: 20)
                        }

                        // Branch checks (shown when there is no PR, or to re-run a failure)
                        if let info, info.pr == nil || info.branchCI == .failure {
                            HStack(spacing: 5) {
                                Circle().fill(ghCIDot(info.branchCI)).frame(width: 5, height: 5)
                                    .opacity(info.branchCI == .unknown ? 0.35 : 1)
                                Text("Checks")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(hex: "#9398A1"))
                                Text(ciWord(info.branchCI))
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: info.branchCI == .unknown ? "#6B7079" : "#C5C8CD"))
                                Spacer(minLength: 4)
                                if info.branchCI == .failure {
                                    PanelActionButton(title: "Re-run", symbol: "arrow.clockwise", accent: "#F5A524",
                                                      help: "Re-run the failed jobs of the latest failed run on \(git.branch)",
                                                      perform: {
                                                          guard let run = try await ServiceAPI.latestFailedRun(repo: git.repo, branch: git.branch) else {
                                                              throw PanelNotice(message: "No failed run to re-run")
                                                          }
                                                          return try await ServiceAPI.perform(kind: "github.rerun", target: run)
                                                      },
                                                      onResult: finished,
                                                      onNotice: { status.show($0, ok: true, neutral: true) })
                                }
                            }
                            .frame(height: 20)
                        }

                        // Vercel preview of this branch
                        if let dep = state.vercelPreview(repo: git.repo, branch: git.branch) {
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: dep.stateColor)).frame(width: 5, height: 5)
                                Text(dep.target == "production" ? "Production" : "Vercel")
                                    .font(.system(size: 10.5))
                                    .foregroundColor(Color(hex: "#9398A1"))
                                Text("\(dep.statusLabel) · \(dep.isBuilding ? "now" : dep.timeAgo)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#C5C8CD"))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                PanelLinkButton(title: dep.target == "production" ? "Open" : "Preview",
                                                accent: "#7C5CFF", help: dep.url) {
                                    if let url = safeWebURL("https://\(dep.url)") { NSWorkspace.shared.open(url) }
                                }
                            }
                            .frame(height: 20)
                        }
                    }
                }
            } else {
                Text("This session isn't in a GitHub checkout")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#6B7079"))
            }
        }
        .onAppear { SessionGitHubLinker.shared.refresh(for: state.tasks.first { $0.id == taskId }) }
    }
}

/// A small Vercel mark in the deployment's state color; opens the preview.
struct VercelPreviewDot: View {
    let deployment: VercelDeployment
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if let url = safeWebURL("https://\(deployment.url)") { NSWorkspace.shared.open(url) }
        }) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 6.5, weight: .bold))
                .foregroundColor(Color(hex: deployment.stateColor))
                .frame(width: 17, height: 17)
                .background(Circle().fill(Color.white.opacity(isHovered ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Vercel \(deployment.target == "production" ? "production" : "preview") · \(deployment.statusLabel) · \(deployment.url)")
    }
}
