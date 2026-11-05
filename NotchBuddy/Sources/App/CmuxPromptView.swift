import SwiftUI

#if !APPSTORE

/// Carries a prompt mode through NotificationCenter.
final class CmuxPromptModeBox {
    let mode: CmuxPromptMode
    init(_ mode: CmuxPromptMode) { self.mode = mode }
}

/// Reply to a cmux session, or start a new chat in a new cmux workspace.
/// Shown in the `.prompt` slot while `state.cmuxPrompt` is set. Text reaches cmux only when the user
/// clicks Send or presses Return (plus the single deferred first prompt of a new chat).
struct CmuxPromptView: View {
    @ObservedObject var state: AppState
    /// The mode this view is created for: the very value used for `.id(mode)`, so no state read decides what Send does.
    let bornMode: CmuxPromptMode
    @State private var text = ""
    @State private var folder = ""
    /// Claude every time the view opens: the last choice is not remembered.
    @State private var launcherId: CmuxLauncher.Id = .claude
    @State private var launching = false
    /// Folder lookups hit the file system: done on appear and when the lists change, not per render.
    @State private var folders: [String] = []
    @FocusState private var focused: Bool
    /// Follow the newest text unless the user scrolled up.
    @State private var pinned = true
    /// The session the header, the chips, the transcript and Send show. It follows the registry on the next
    /// render; Send compares it with the registry at the press and refuses when they differ.
    @State private var renderedKey: String?
    /// The content the text in the field was loaded for. Set only where a draft is loaded; every edit is filed
    /// under it (at the moment of the edit, not in a callback) and a send needs it to equal what is rendered.
    @State private var textOwner: PromptSlot.Content?
    /// A chip click is in flight: the retarget it causes is the user's own, so it needs no notice.
    @State private var chipClicked = false
    /// The diff card of a file edit of the timeline, while one is open over the reply view.
    @State private var activeDiff: FileDiff?
    /// The field had focus when the diff card opened: only then does it get it back.
    @State private var fieldHadFocus = false

    private var mode: CmuxPromptMode { state.cmuxPrompt ?? .newChat }

    /// The field. An edit is stored under the owner of the text right when it happens, so no order of callbacks
    /// can file it under another content.
    private var fieldText: Binding<String> {
        Binding(get: { text }, set: { new in
            text = new
            if let owner = textOwner { state.promptDrafts.set(new, for: owner) }
        })
    }

    private var replyTask: AgentTask? {
        if case .reply(let id) = mode { return state.tasks.first { $0.id == id } }
        return nil
    }

    private var launcher: CmuxLauncher { CmuxLauncher.launcher(launcherId) }

    private var isReply: Bool { if case .reply = mode { return true } else { return false } }

    /// Default folder first, then recent ones; only folders that still exist.
    private func loadFolders() {
        var out: [String] = []
        for f in [state.cmuxDefaultFolder] + state.cmuxRecentFolders where !f.isEmpty && !out.contains(f) {
            if CmuxRouting.isExistingFolder(f) { out.append(f) }
        }
        folders = out
        if !out.contains(folder) { folder = out.first ?? "" }
    }

    /// The session the registry says a reply goes to now: the one picked with the chips, else the main agent.
    private var resolvedKey: String? {
        guard let t = replyTask else { return nil }
        return HookServer.shared.cmuxReplyTarget(for: t.id)
    }

    /// The session on screen. Only the very first frame, before `onAppear`, reads the registry.
    private var targetKey: String? { renderedKey ?? resolvedKey }

    /// What this view shows, for the drafts, the notice owner and the delivery check.
    private var renderedContent: PromptSlot.Content {
        if case .reply(let id) = mode { return .cmuxReply(taskId: id, surfaceKey: targetKey) }
        return .cmuxNewChat
    }

    /// Proof that the session runs an agent (it reported in with a token: a session Coucou only discovered has
    /// none until its next prompt), and no card or dialog on it.
    private var sessionCanReceive: Bool {
        guard let key = targetKey else { return false }
        return HookServer.shared.cmuxCanSend(key: key)
    }

    private var canSubmit: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !state.cmuxBusy else { return false }
        if isReply { return sessionCanReceive }
        return !launching && folders.contains(folder)
    }

    /// A notice about a send belongs to the reply it was sent from: another reply does not show it.
    private var storedNoticeIsMine: Bool {
        state.cmuxNotice != nil && (state.cmuxNoticeOwner == nil || state.cmuxNoticeOwner == renderedContent)
    }

    private var notice: String? {
        if storedNoticeIsMine, let n = state.cmuxNotice { return n }
        return impliedFailure?.message
    }

    /// The failure the notice stands for: the one stored with it, or the one the session state implies.
    private var noticeFailure: CmuxControl.Failure? {
        storedNoticeIsMine ? state.cmuxNoticeFailure : impliedFailure
    }

    private var impliedFailure: CmuxControl.Failure? {
        if isReply, let key = targetKey, !sessionCanReceive {
            let server = HookServer.shared
            if !server.cmuxCanType(key: key) { return CmuxControl.Failure.notReachableYet }
            if server.cmuxDialogMayBeOpen(key: key) { return CmuxControl.Failure.dialogMayBeOpen }
            return CmuxControl.Failure.blockedByDialog
        }
        return nil
    }

    /// The session that answers: its label (the string the header and chips show) in the colour of its pill.
    private var replySpeaker: ChatSpeaker {
        let label = replyTask.flatMap { t in HookServer.shared.cmuxSurfaces(for: t.id).first { $0.key == targetKey }?.label }
        return ChatSpeaker(name: label ?? replyTask?.name ?? "cmux", colorHex: replyTask?.color ?? "#8E939C")
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    AgentWho(task: replyTask, label: isReply ? "cmux · reply" : "New chat in cmux")
                    // Same second line as the overview card: folder and branch of the session.
                    if isReply, let line = replyTask?.subtitle {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 15)
                    }
                    // Where the reply goes: the one agent, or chips to pick among several.
                    if isReply, let t = replyTask { targetLine(for: t) }
                }
                .padding(.top, 4)

                if isReply, let t = replyTask { targetChips(for: t) }

                if isReply { replyBody } else { newChatBody }

                if let notice {
                    HStack(spacing: 10) {
                        Text(notice)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(2)
                        if isReply, let key = targetKey, noticeFailure == .dialogMayBeOpen {
                            // Explicit click: the user says the request is gone (answered, then declined, in cmux).
                            Button("Answered") {
                                HookServer.shared.clearCmuxDialogMark(key: key)
                                state.cmuxNotice = nil
                                state.objectWillChange.send()
                            }
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#7DD3FC").opacity(0.85))
                            .buttonStyle(.plain)
                        }
                        if noticeFailure == .noCredential {
                            Button("Settings…") {
                                NotificationCenter.default.post(name: .openFullSettings, object: "agents")
                            }
                            .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
                        }
                        if noticeFailure == .noCredential || noticeFailure == .notRunning || state.cmuxNoticeOffersCmux {
                            Button("Open cmux") { CmuxHub.openCmux() }
                                .font(.system(size: 11)).foregroundColor(Color(hex: "#7DD3FC").opacity(0.85))
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }

                HStack(spacing: 8) {
                    TextField(isReply ? String(localized: "Reply…") : String(localized: "First prompt…"), text: fieldText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { send() }

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(!canSubmit)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .simultaneousGesture(TapGesture().onEnded { focused = true })
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)

            // The diff of a file edit, drawn as the overview draws it: its own background and gutter.
            if let diff = activeDiff {
                CardBackground(wash: nil)
                DiffCardView(diff: diff, onDismiss: { closeDiff() })
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) { ChatResizeGrip(state: state) }
        .padding(.bottom, 10)
        .onAppear {
            focused = true
            launcherId = .claude
            launching = HookServer.shared.cmuxPendingLaunch != nil
            loadFolders()
            renderedKey = resolvedKey
            state.cmuxRenderedContent = renderedContent
            loadDraft()
            CmuxTimelines.shared.show(isReply ? renderedKey : nil)
        }
        .onDisappear {
            if state.cmuxRenderedContent == renderedContent { state.cmuxRenderedContent = nil }
            CmuxTimelines.shared.show(nil)
        }
        .onChange(of: state.cmuxPrompt) { _, _ in launcherId = .claude }
        .onChange(of: state.cmuxDefaultFolder) { _, _ in loadFolders() }
        .onChange(of: state.cmuxRecentFolders) { _, _ in loadFolders() }
        // The registry moved the session of this pill (discovery, a closed session, a chip): show the new one.
        .onChange(of: resolvedKey) { _, new in renderedKey = new }
        .onChange(of: renderedKey) { _, new in CmuxTimelines.shared.show(isReply ? new : nil) }
        // The field shows the draft of what is rendered; what is typed is kept for it.
        .onChange(of: renderedContent) { _, new in
            state.cmuxRenderedContent = new
            activeDiff = nil
            loadDraft()
        }
        // A draft written from outside (a launch that timed out, a prompt that could not be typed, a send that ended).
        // Keyed on the write counter, not on the text: the typing of the user also stores its draft.
        .onChange(of: state.draftRevision) { _, _ in loadDraft(takesStash: false) }
        // Only a launch outcome (timeout, folder match, failed first prompt) lets Send work again while a launch waits.
        .onChange(of: state.launchEndedRevision) { _, _ in launching = false }
        .onReceive(NotificationCenter.default.publisher(for: .islandSendMessage)) { _ in
            guard state.view == .prompt, state.cmuxPrompt != nil else { return }
            send()
        }
    }

    // MARK: reply target

    /// `To: <agent>` when the workspace has one agent session (the chips cover several).
    @ViewBuilder private func targetLine(for task: AgentTask) -> some View {
        let surfaces = HookServer.shared.cmuxSurfaces(for: task.id)
        if surfaces.count == 1, let only = surfaces.first {
            Text("To: \(only.label)")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 15)
        }
    }

    /// More chips than this scroll in a bounded area instead of pushing the transcript and the field away (a
    /// workspace holds up to 24 sessions). Up to this many, the chips wrap exactly as before.
    private static let chipsBeforeScroll = 8
    /// Two rows of chips and half of the third (a chip is about 22 pt high, rows 6 pt apart): the cut row says the
    /// list scrolls.
    private static let chipsScrollHeight: CGFloat = 67

    /// One chip per agent session of the workspace, the main one first; the selected chip is the target.
    @ViewBuilder private func targetChips(for task: AgentTask) -> some View {
        let surfaces = HookServer.shared.cmuxSurfaces(for: task.id)
        if surfaces.count > Self.chipsBeforeScroll {
            // At most two rows, then the same wrapping chips scroll; the selected chip is kept in view.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // Full width, leading: a scroll view centres content narrower than itself, and the chips must sit
                    // on the same left edge as in the wrapping case.
                    chipFlow(surfaces, task: task)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.chipsScrollHeight)
                .onAppear { if let t = targetKey { proxy.scrollTo(t) } }
                .onChange(of: targetKey) { _, t in if let t { proxy.scrollTo(t) } }
            }
        } else if surfaces.count > 1 {
            chipFlow(surfaces, task: task)
        }
    }

    private func chipFlow(_ surfaces: [CmuxSurfaceInfo], task: AgentTask) -> some View {
        let target = targetKey
        return ChipFlowLayout(spacing: 6) {
            ForEach(surfaces, id: \.key) { s in
                Button {
                    if s.key != target { chipClicked = true }
                    HookServer.shared.setCmuxReplyChoice(s.key, for: task.id)
                } label: {
                    chipLabel(s.label, selected: s.key == target)
                }
                .buttonStyle(.plain)
                .id(s.key)
            }
        }
        .padding(.horizontal, 10)
    }

    // MARK: bodies

    @ViewBuilder private var replyBody: some View {
        CmuxTimelineBody(screen: CmuxTimelines.shared.screen, speaker: replySpeaker, pinned: $pinned)
            .environment(\.chatOpenEdit) { edit in openDiff(of: edit) }
    }

    /// The full diff while the store still has it, else the card rebuilt from the row. The field gives up focus.
    private func openDiff(of edit: ChatEdit) {
        // A stored diff is shown only when it is the file of the row (its path cleaned as the row's was).
        let stored = replyTask.flatMap { t in
            edit.diffId.flatMap { id in state.sessionDiffs[t.id]?.first { $0.id == id && TimelineStore.wording($0.path, max: TimelineStore.maxPathChars) == edit.path } }
        }
        fieldHadFocus = focused
        focused = false
        withAnimation { activeDiff = stored ?? FileDiff.rebuilt(from: edit) }
    }

    private func closeDiff() {
        withAnimation { activeDiff = nil }
        if fieldHadFocus { focused = true }
    }

    @ViewBuilder private var newChatBody: some View {
        if folders.isEmpty {
            HStack(spacing: 10) {
                Text("Set a default folder in Settings.")
                    .font(.system(size: 11.5)).foregroundColor(Color(hex: "#8E939C"))
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openFullSettings, object: "agents")
                }
                .font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C")).buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            Spacer()
        } else {
            let labels = CmuxRouting.chipLabels(for: folders)
            ChipFlowLayout(spacing: 6) {
                ForEach(Array(folders.enumerated()), id: \.element) { i, f in
                    let selected = f == folder
                    Button { folder = f } label: { chipLabel(labels[i], selected: selected) }
                        .buttonStyle(.plain)
                        .help(f)
                }
            }
            .padding(.horizontal, 10)
            ChipFlowLayout(spacing: 6) {
                ForEach(CmuxLauncher.all) { l in
                    Button { launcherId = l.id } label: { chipLabel(l.name, selected: l.id == launcherId) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            Text("Runs: \(state.cmuxCommand(for: launcher))")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "#8E939C"))
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
            Spacer()
        }
    }

    /// One chip, for the folders and for the launchers.
    private func chipLabel(_ title: String, selected: Bool) -> some View {
        Text(verbatim: title)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(selected ? Color(hex: "#0B0C0E") : Color(hex: "#C5C8CD"))
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(selected ? Color(hex: "#F5F6F8") : Color.white.opacity(0.08))
            .clipShape(Capsule())
    }

    // MARK: actions

    /// The field takes the draft stored for what is rendered (empty when that content has none: the text typed
    /// belongs to the other content, where it stays as a draft). The owner of the text is set here, and only here.
    /// `takesStash`: the field is being loaded (it appears, or its content changed). A reload caused by a writer, such as
    /// the end of a send, never puts a stashed prompt back.
    private func loadDraft(takesStash: Bool = true) {
        let content = renderedContent
        // The session moved under typed text without the user doing it: say so. The text stays the draft of the
        // session it was typed for (every edit was filed under its owner); the field takes the new one.
        if PromptSlot.retargetNeedsNotice(owner: textOwner, rendered: content, textIsEmpty: text.isEmpty, byUser: chipClicked) {
            state.showCmuxFailure(.sessionClosed, owner: content)
        }
        if textOwner != content { chipClicked = false }
        textOwner = content
        let loaded = state.draftForField(content, takesStash: takesStash)
        if loaded.text != text { text = loaded.text }
        // The prompt that waited in the stash is in the field now: say it is there, with the notice that exists for it.
        if loaded.restoredStash, PromptSlot.restoredNoticeFits(content: content, noticeInUse: state.cmuxNotice != nil),
           case .cmuxReply(let taskId, _) = content {
            state.cmuxNotice = CmuxRouting.folderDraftNotice(sessionName: state.tasks.first { $0.id == taskId }?.name ?? "")
        }
    }

    /// A send ended: the text goes (sent, or typed in cmux) or comes back (failed), in the draft of the content it
    /// was sent from. The open view follows its draft; a view that is gone leaves the draft for when it returns.
    private func settleDraft(_ content: PromptSlot.Content, sent prompt: String, keep: Bool) {
        if keep {
            state.restoreDraft(prompt, for: content)
        } else {
            // The sent text goes; text appended after the press stays, any other edit empties the field.
            let draft = state.promptDrafts.text(for: content)
            let remaining = PromptSlot.draftAfterSend(draft: draft, sent: prompt)
            if remaining != draft { state.writeDraft(remaining, for: content) }
        }
    }

    /// Explicit user action only: Send click, Return, or the island send shortcut.
    private func send() {
        guard canSubmit else { return }
        // Only the mode this view was created for, and only while the prompt is still open: a prompt that was just
        // closed (a card arriving, a focus change) must not turn a Return into a new chat.
        guard state.view == .prompt, let current = state.cmuxPrompt, current == bornMode else { return }
        // The text must have been loaded for what is rendered; otherwise it belongs to another session or chat.
        guard PromptSlot.textMayDeliver(owner: textOwner, rendered: renderedContent) else {
            if isReply { renderedKey = resolvedKey }
            state.showCmuxFailure(.sessionClosed, owner: renderedContent)
            return
        }
        let prompt = text
        pinned = true
        state.cmuxNotice = nil
        switch current {
        case .reply(let id):
            // Only to the session that is on screen. If the registry moved on since the last render, nothing is
            // typed: the view shows the new session and says so; the text stays with the session it was typed for.
            let rendered = PromptSlot.Content.cmuxReply(taskId: id, surfaceKey: renderedKey)
            let resolved = PromptSlot.Content.cmuxReply(taskId: id, surfaceKey: resolvedKey)
            guard PromptSlot.mayDeliver(rendered: rendered, resolved: resolved), let key = renderedKey else {
                renderedKey = resolvedKey
                state.showCmuxFailure(.sessionClosed, owner: .cmuxReply(taskId: id, surfaceKey: resolvedKey))
                return
            }
            CmuxControl.send(text: prompt, to: id, surfaceKey: key) { failure in
                if let failure {
                    state.showCmuxFailure(failure, owner: rendered)
                    settleDraft(rendered, sent: prompt, keep: failure != .enterNotSent)
                } else {
                    settleDraft(rendered, sent: prompt, keep: false)
                }
            }
        case .newChat:
            let chosen = folder
            let chosenLauncher = launcher
            CmuxControl.newChat(folder: chosen, prompt: prompt, launcher: chosenLauncher) { failure in
                if let failure {
                    state.showCmuxFailure(failure, owner: .cmuxNewChat)
                    settleDraft(.cmuxNewChat, sent: prompt, keep: true)
                } else {
                    settleDraft(.cmuxNewChat, sent: prompt, keep: false)
                    // Only Claude reports its start; the others have no pending launch to wait for.
                    if state.cmuxRenderedContent == .cmuxNewChat { launching = chosenLauncher.reportsSessionStart }
                }
            }
        }
    }
}

/// Small helpers shared by the hub card and the prompt view.
@MainActor
enum CmuxHub {
    /// Brings cmux to the front, or launches it. Never types anything.
    static func openCmux() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == CmuxRouting.bundleId }) {
            app.activate(options: .activateIgnoringOtherApps)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxRouting.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    // LaunchServices and the process list are not cheap: the answers are cached for a few seconds, so a
    // view body that asks on every render does not repeat the lookup.
    private static var cache: (at: Date, installed: Bool, running: Bool)?
    private static let cacheTTL: TimeInterval = 3

    private static func lookup() -> (installed: Bool, running: Bool) {
        if let c = cache, Date().timeIntervalSince(c.at) < cacheTTL { return (c.installed, c.running) }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CmuxRouting.bundleId) != nil
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == CmuxRouting.bundleId }
        cache = (Date(), installed, running)
        return (installed, running)
    }

    static func isInstalled() -> Bool { lookup().installed }

    static func isRunning() -> Bool { lookup().running }

    static func open(_ mode: CmuxPromptMode) {
        NotificationCenter.default.post(name: .openCmuxPrompt, object: CmuxPromptModeBox(mode))
    }

    /// Reply from a card or the overview: the session whose answer is on the card comes first, else the chip the
    /// user picked, else the main one. Only a live session is chosen; nothing is typed.
    static func openReply(taskId: String) {
        let server = HookServer.shared
        let state = AppState.shared
        let live = Set(server.cmuxSurfaces(for: taskId).map { $0.key })
        let surface = PromptSlot.replySurface(cardSurface: server.cmuxFinalSurface(for: taskId),
                                              choice: state.cmuxReplyChoice[taskId],
                                              main: server.cmuxMainSurface(for: taskId), live: live)
        // The main session needs no pin: it is what the reply resolves to by itself (and follows its changes).
        if let surface, surface != server.cmuxReplyTarget(for: taskId) {
            server.setCmuxReplyChoice(surface, for: taskId)
        }
        open(.reply(taskId: taskId))
    }
}

#endif
