import Foundation

// The prompt slot logic of AppState (what the chat view shows for the selected pill, see PromptSlot).
// Fork owned file: AppState.swift only keeps the stored properties and the observers that must live there.

extension AppState {
    /// `byPointer`: the user clicked the pill (only the overview has pills to click). The prompt slot then follows
    /// `PromptSlot.onFocusChange`; a Hermes pill always selects its agent, whatever the way it was reached.
    func setFocus(_ id: String, byPointer: Bool = false) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        let pill = pill(forTaskId: id)
        let effect = PromptSlot.onFocusChange(open: promptContent, newFocus: pill, byPointer: byPointer)
        applyingFocusEffect = true
        focusId = id
        applyingFocusEffect = false
        tasks[idx].pillBadge = nil  // clear badge when user brings task to focus
        switch effect {
        case .keep: break
        case .close: closePromptSlot()
        case .show: break   // the agent is selected below, then its chat opens
        }
        if case .hermes(let agent) = pill {
            if hermesChatAgent != agent { hermesChatAgent = agent }
            if case .show = effect { switchChatProvider(.hermes) }
        }
    }

    // MARK: drafts

    /// A writer outside the views (a launch that ended, a failed send, a closed session): the open view reloads.
    /// `endsLaunch`: the writer is a launch outcome, the only thing that lets Send work again while a launch waits.
    /// The stash is not touched here: a stashed prompt is never put back in the turn that ends a send.
    func writeDraft(_ text: String, for content: PromptSlot.Content, endsLaunch: Bool = false) {
        promptDrafts.set(text, for: content)
        draftRevision &+= 1
        if endsLaunch { launchEndedRevision &+= 1 }
    }

    /// A send failed: the prompt goes back to the draft of its content when the draft is empty or blank. Other text
    /// stays as typed. `stashIfReplaced`: a first prompt of a new chat must not be lost, so it waits in the stash
    /// until that field is empty again.
    func restoreDraft(_ prompt: String, for content: PromptSlot.Content, endsLaunch: Bool = false, stashIfReplaced: Bool = false) {
        let draft = promptDrafts.text(for: content)
        if stashIfReplaced, PromptSlot.failureLosesPrompt(draft: draft, prompt: prompt) { promptStash.keep(prompt, for: content) }
        writeDraft(PromptSlot.draftAfterFailure(draft: draft, prompt: prompt), for: content, endsLaunch: endsLaunch)
    }

    /// The draft a field shows when it is loaded (it appears, or its content changes): the stored one, or the fresh
    /// stashed prompt when the stored one is blank. A reload caused by a writer (`takesStash: false`) never takes it.
    func draftForField(_ content: PromptSlot.Content, takesStash: Bool = true) -> PromptSlot.LoadedDraft {
        let stored = promptDrafts.text(for: content)
        let loaded = PromptSlot.loadDraft(stored: stored, stash: &promptStash, for: content, takesStash: takesStash)
        if loaded.restoredStash { promptDrafts.set(loaded.text, for: content) }
        return loaded
    }

    /// Removes a draft through the path that also refreshes an open field. A session that is gone keeps no stashed prompt.
    func clearDraft(for content: PromptSlot.Content) {
        if case .cmuxReply(let taskId, _) = content { promptStash.forgetReplies(ofTask: taskId) }
        guard !promptDrafts.text(for: content).isEmpty else { return }
        writeDraft("", for: content)
    }

    // MARK: what the slot is

    /// What the task id stands for, for the slot rules.
    func pill(forTaskId id: String) -> PromptSlot.Pill {
        if HermesPills.isTaskId(id), let name = HermesPills.agentName(forTaskId: id, in: hermesAgents.map { $0.name }) {
            return .hermes(agent: name)
        }
        #if !APPSTORE
        if CmuxRouting.isCmuxTaskId(id) { return .cmux(taskId: id) }
        #endif
        return .other
    }

    /// The pill the user selected.
    var focusPill: PromptSlot.Pill { focusId.map { pill(forTaskId: $0) } ?? .other }

    /// The chat the prompt slot shows when no cmux prompt is open.
    var chatContent: PromptSlot.Content {
        chatProvider == .hermes ? .hermesChat(agent: activeHermesAgent?.name ?? "") : .sharedChat
    }

    /// What the prompt slot shows now; nil while another view is on screen.
    var promptContent: PromptSlot.Content? {
        guard view == .prompt else { return nil }
        #if !APPSTORE
        switch cmuxPrompt {
        case .reply(let id)?: return .cmuxReply(taskId: id, surfaceKey: HookServer.shared.cmuxReplyTarget(for: id))
        case .newChat?:       return .cmuxNewChat
        case nil:             break
        }
        #endif
        return chatContent
    }

    /// Back to the overview of the focused pill. Drafts are kept.
    func closePromptSlot() {
        #if !APPSTORE
        clearCmuxPrompt()
        #endif
        if view == .prompt { view = .overview }
    }

    // MARK: openers

    private var cmuxAvailableForSlot: Bool {
        #if !APPSTORE
        return true
        #else
        return false
        #endif
    }

    /// What an opener with no target would show, without changing anything.
    func contentOnOpenPreview(carriesContext: Bool = false) -> PromptSlot.Content {
        PromptSlot.contentOnOpen(focus: focusPill, cmuxAvailable: cmuxAvailableForSlot, carriesContext: carriesContext)
    }

    /// The chat tab would open a cmux reply (it then takes no window context: a reply has no context chip).
    var chatTabOpensCmuxReply: Bool {
        if case .cmuxReply = contentOnOpenPreview() { return true }
        return false
    }

    /// The slot is opened with no target: selects the provider and agent of the focused pill and returns what the
    /// slot must show. A cmux reply is not opened here (`openCmuxPrompt` does it, it needs the window).
    /// `carriesContext`: the opener attaches a window or a file, so it opens a chat, never a cmux reply.
    func promptContentOnOpen(carriesContext: Bool = false) -> PromptSlot.Content {
        let content = contentOnOpenPreview(carriesContext: carriesContext)
        switch content {
        case .hermesChat(let agent):
            if hermesChatAgent != agent { hermesChatAgent = agent }
            if chatProvider != .hermes { chatProvider = .hermes }
        case .sharedChat:
            switch PromptSlot.sharedOpen(providerIsHermes: chatProvider == .hermes, lastSharedKnown: lastSharedProvider != nil,
                                         activeAgent: activeHermesAgent?.name) {
            case .keep:
                break
            case .backToShared:
                if let shared = lastSharedProvider { chatProvider = shared }
            case .hermesChat:
                // Unknown shared provider: no provider is switched silently. The slot shows the chat of the active
                // Hermes agent, as the app always did, and the focus moves to that agent's pill so both agree.
                focusActiveHermesPill()
                return chatContent
            }
        case .cmuxReply, .cmuxNewChat:
            break
        }
        return content
    }

    /// The chat tab, and the entries that hand a chat a file ("Ask a question", "Ask Claude"): opens the slot on
    /// `promptContentOnOpen`, synchronously.
    func showPromptSlot(carriesContext: Bool = false) {
        let content = promptContentOnOpen(carriesContext: carriesContext)
        #if !APPSTORE
        if case .cmuxReply(let taskId, _) = content {
            applyNoticeRuleForOpening(.reply(taskId: taskId))
            cmuxOpeningPrompt = true
            view = .prompt
            cmuxPrompt = .reply(taskId: taskId)
            cmuxOpeningPrompt = false
            return
        }
        #endif
        view = .prompt
    }

    #if !APPSTORE
    /// A failure notice stays with the prompt it is about and is dropped for any other. One rule for both openers.
    func applyNoticeRuleForOpening(_ mode: CmuxPromptMode) {
        let keepsNotice: Bool
        switch (cmuxNoticeOwner, mode) {
        case (.cmuxReply(let owned, _)?, .reply(let id)): keepsNotice = owned == id
        case (.cmuxNewChat?, .newChat):                   keepsNotice = true
        default:                                          keepsNotice = false
        }
        if !keepsNotice { cmuxNotice = nil }
    }
    #endif

    /// An answer of the shared chat takes the slot only when the slot would show the shared chat, no card is pending
    /// and no other content is in it. Otherwise the view stays as it is (the answer waits in the shared conversation).
    func showSharedChatAnswer() {
        if !PromptSlot.answerMayTakeSlot(onScreen: promptContent, chatContent: chatContent, cardPending: alertCardPending) { return }
        view = .prompt
    }

    /// The focus goes to the pill of the Hermes agent whose chat is shown (no effect on the slot: it is already on it).
    func focusActiveHermesPill() {
        guard case .hermesChat(let agent) = chatContent,
              let id = HermesPills.taskIds(for: hermesAgents.map { $0.name })[agent],
              tasks.contains(where: { $0.id == id }) else { return }
        applyingFocusEffect = true
        focusId = id
        applyingFocusEffect = false
    }

    /// The model picker chose a conversation: the focused pill follows it (the click on the picker is the last
    /// click), so the slot keeps showing what belongs to the focused pill.
    func syncFocusToChat() {
        guard view == .prompt else { return }
        #if !APPSTORE
        if cmuxPrompt != nil { return }
        #endif
        if case .hermesChat = chatContent {
            focusActiveHermesPill()
        } else if case .hermes = focusPill, tasks.contains(where: { $0.id == mainPillId }) {
            applyingFocusEffect = true
            focusId = mainPillId
            applyingFocusEffect = false
        }
    }
}
