import Foundation

/// Pure rules for the prompt slot (the `.prompt` view of the island): what it shows for the pill the user selected,
/// when it must close, and which target a message may reach. Compiled in both builds; cmux is only a string here.
///
/// Invariant: a message goes to the conversation or the session that was on screen when Send was pressed,
/// never to another one. When in doubt, the send is refused.
enum PromptSlot {
    /// What a pill is, for the slot. Built by the caller from the task id.
    enum Pill: Equatable {
        case hermes(agent: String)
        case cmux(taskId: String)
        case other
    }

    /// What the slot shows. `surfaceKey` is the session rendered, nil for a pill whose session is not resolved yet.
    enum Content: Hashable {
        case sharedChat
        case hermesChat(agent: String)
        case cmuxReply(taskId: String, surfaceKey: String?)
        case cmuxNewChat
    }

    /// The slot is opened without a target (chat tab, hot key, attach window, island reopen):
    /// it shows what belongs to the focused pill.
    ///
    /// `carriesContext`: the opener hands the chat a window or a file (attach window, Mochi dropped on a window,
    /// Ask a question after a file drop). Only a chat takes context, so a cmux pill gets the shared chat, never its reply.
    static func contentOnOpen(focus: Pill, cmuxAvailable: Bool, carriesContext: Bool = false) -> Content {
        switch focus {
        case .hermes(let agent): return .hermesChat(agent: agent)
        case .cmux(let taskId):  return cmuxAvailable && !carriesContext ? .cmuxReply(taskId: taskId, surfaceKey: nil) : .sharedChat
        case .other:             return .sharedChat
        }
    }

    /// The content belongs to the focused pill. A new cmux chat creates its own pill, so it follows any focus;
    /// the shared chat follows everything that is not a Hermes agent.
    static func belongs(_ content: Content, to focus: Pill) -> Bool {
        switch content {
        case .cmuxNewChat:
            return true
        case .sharedChat:
            if case .hermes = focus { return false }
            return true
        case .hermesChat(let agent):
            return focus == .hermes(agent: agent)
        case .cmuxReply(let taskId, _):
            return focus == .cmux(taskId: taskId)
        }
    }

    enum FocusEffect: Equatable {
        case keep
        case close
        case show(Content)
    }

    /// Focus moved while `open` is on screen (nil = the slot is closed). `byPointer`: a click on a pill.
    static func onFocusChange(open: Content?, newFocus: Pill, byPointer: Bool) -> FocusEffect {
        if let open, belongs(open, to: newFocus) { return .keep }
        if byPointer, case .hermes(let agent) = newFocus { return .show(.hermesChat(agent: agent)) }
        return open == nil ? .keep : .close
    }

    /// Send is allowed only to what was rendered. A reply whose session was not known when it was rendered
    /// never delivers.
    static func mayDeliver(rendered: Content, resolved: Content) -> Bool {
        if case .cmuxReply(_, let key) = rendered, key == nil { return false }
        return rendered == resolved
    }

    /// The text in the field was loaded for `owner`; it may be delivered only to that very content. No owner: refuse.
    static func textMayDeliver(owner: Content?, rendered: Content) -> Bool {
        guard let owner else { return false }
        return owner == rendered
    }

    /// The rendered content changed under a field that holds text. The change is silent only when the user made it
    /// (a chip click) or when there is nothing typed; otherwise the user is told, and the text stays the draft of
    /// the content it was typed for.
    static func retargetNeedsNotice(owner: Content?, rendered: Content, textIsEmpty: Bool, byUser: Bool) -> Bool {
        guard let owner, owner != rendered else { return false }
        return !textIsEmpty && !byUser
    }

    /// A shared chat answer may take the slot (set the view to the prompt) only when the shared chat is what the slot
    /// would show, no approval or question card is pending, and the slot is closed or already on the shared chat:
    /// it never takes the screen from a cmux reply, a new cmux chat, a Hermes chat or a card.
    static func answerMayTakeSlot(onScreen: Content?, chatContent: Content, cardPending: Bool) -> Bool {
        guard chatContent == .sharedChat, !cardPending else { return false }
        guard let onScreen else { return true }
        return onScreen == .sharedChat
    }

    /// A conversation with a chat provider or a Hermes agent (not a cmux session).
    static func isChat(_ content: Content) -> Bool {
        switch content {
        case .sharedChat, .hermesChat: return true
        case .cmuxReply, .cmuxNewChat: return false
        }
    }

    /// The chat view sends only text it owns, typed for the chat on screen, and never while a cmux prompt is open.
    /// Text owned by a cmux content is refused even when that content is the one on screen.
    static func chatTextMayDeliver(owner: Content?, onScreen: Content, cmuxPromptOpen: Bool) -> Bool {
        guard !cmuxPromptOpen, isChat(onScreen), let owner, isChat(owner) else { return false }
        return owner == onScreen
    }

    /// The chat view loads (and takes ownership of) a draft only for a chat content, with no cmux prompt open.
    static func chatMayLoadDraft(onScreen: Content?, cmuxPromptOpen: Bool) -> Bool {
        guard !cmuxPromptOpen, let onScreen else { return false }
        return isChat(onScreen)
    }

    /// An opener that should give the shared chat while the selected provider is Hermes.
    enum SharedOpen: Equatable {
        case keep                       // not on Hermes: nothing to do
        case backToShared               // the last shared provider is known: select it
        case hermesChat(agent: String?) // unknown: the chat of the active agent, and the focus moves to its pill
    }

    static func sharedOpen(providerIsHermes: Bool, lastSharedKnown: Bool, activeAgent: String?) -> SharedOpen {
        guard providerIsHermes else { return .keep }
        return lastSharedKnown ? .backToShared : .hermesChat(agent: activeAgent)
    }

    /// After a failed send the prompt goes back to the draft only when the draft is empty; a draft of spaces and
    /// newlines only is empty to the eye and counts as empty. Text typed meanwhile stays exactly as typed, without
    /// the prompt in front of it (the one line field could hide it, and the next Return would send both).
    static func draftAfterFailure(draft: String, prompt: String) -> String {
        isBlank(draft) ? prompt : draft
    }

    /// The failed prompt is left out of the field: other text stays there. The caller then stashes the prompt
    /// (`PromptStash`) when it cannot be lost (a first prompt of a new chat).
    static func failureLosesPrompt(draft: String, prompt: String) -> Bool {
        !isBlank(prompt) && !isBlank(draft) && draft.trimmingCharacters(in: .whitespacesAndNewlines) != prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a field shows when it is loaded: the stored draft, or the stashed prompt when the stored one is blank.
    struct LoadedDraft: Equatable { let text: String; let restoredStash: Bool }

    static func draftForLoad(stored: String, stashed: String?) -> LoadedDraft {
        guard isBlank(stored), let stashed else { return LoadedDraft(text: stored, restoredStash: false) }
        return LoadedDraft(text: stashed, restoredStash: true)
    }

    /// Loads a field: the stash is taken only when the stored draft is blank (and the reload is not a writer's), so a
    /// load over other text leaves the stashed prompt for the next load of the empty field.
    static func loadDraft(stored: String, stash: inout PromptStash, for content: Content, takesStash: Bool = true) -> LoadedDraft {
        draftForLoad(stored: stored, stashed: takesStash && isBlank(stored) ? stash.take(for: content) : nil)
    }

    /// The existing notice for a restored prompt ("claude started in X. Check the prompt and press Send.") fits a reply
    /// field that shows no other notice. Nothing else has such a notice.
    static func restoredNoticeFits(content: Content, noticeInUse: Bool) -> Bool {
        if case .cmuxReply = content { return !noticeInUse }
        return false
    }

    /// The prompt is what the field holds: the only case where "check the prompt and press Send" is true.
    static func promptIsInField(draft: String, prompt: String) -> Bool { !isBlank(prompt) && draft == prompt }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A session was cleaned up and its draft dropped: the user is told when that session's own reply was on
    /// screen and held text. Decided where the session is cleaned up, not by the order of two view handlers.
    static func closedSessionNeedsNotice(rendered: Content?, dropped: Content, draftWasEmpty: Bool) -> Bool {
        !draftWasEmpty && rendered == dropped
    }

    /// What stays in the draft after a send that went through: the sent text is gone; what was typed after the press
    /// stays only when it is exactly the draft minus the sent prefix (text appended). Any other edit empties it.
    static func draftAfterSend(draft: String, sent: String) -> String {
        guard !sent.isEmpty, draft.hasPrefix(sent) else { return "" }
        return String(draft.dropFirst(sent.count))
    }

    /// The session whose answer the card shows: the remembered one only while the pill still shows that answer.
    static func cardSurface(finalLineKey: String?, finalLineShown: Bool) -> String? {
        finalLineShown ? finalLineKey : nil
    }

    /// The island may reopen on the Hermes chat only when that agent's pill is the focused one.
    static func reopensOnHermesChat(focus: Pill, activeAgent: String?, unseenAnswer: Bool,
                                    turnRunning: Bool, alertPending: Bool) -> Bool {
        guard let activeAgent, focus == .hermes(agent: activeAgent), !alertPending else { return false }
        return unseenAnswer || turnRunning
    }

    /// Which session a Reply opens on: the session of the card, else the chip, else the main one.
    /// Only a live session is ever returned.
    static func replySurface(cardSurface: String?, choice: String?, main: String?, live: Set<String>) -> String? {
        for candidate in [cardSurface, choice, main] {
            if let candidate, live.contains(candidate) { return candidate }
        }
        return nil
    }
}

/// Drafts by content, so text typed for one conversation never reaches another. Memory only, capped.
struct PromptDrafts: Equatable {
    static let maxEntries = 16
    static let maxLength = 8000

    private var texts: [PromptSlot.Content: String] = [:]
    /// Oldest written first.
    private var order: [PromptSlot.Content] = []

    var count: Int { texts.count }

    /// An empty text removes the draft. A longer one is cut.
    mutating func set(_ text: String, for content: PromptSlot.Content) {
        guard !text.isEmpty else { clear(content); return }
        order.removeAll { $0 == content }
        order.append(content)
        texts[content] = text.count > Self.maxLength ? String(text.prefix(Self.maxLength)) : text
        while order.count > Self.maxEntries {
            texts[order.removeFirst()] = nil
        }
    }

    func text(for content: PromptSlot.Content) -> String { texts[content] ?? "" }

    mutating func clear(_ content: PromptSlot.Content) {
        texts[content] = nil
        order.removeAll { $0 == content }
    }

    /// Drops the drafts of contents that no longer exist.
    mutating func prune(keeping live: (PromptSlot.Content) -> Bool) {
        order.removeAll { content in
            let keep = live(content)
            if !keep { texts[content] = nil }
            return !keep
        }
    }
}

/// Prompts that could not go back to their field because other text was there: first prompts of a new chat whose
/// launch timed out or whose deferred send failed. One per content, put back the next time that field is loaded (never
/// in the turn that ends a send), never merged with other text, and only while fresh (one hour). Memory only, capped,
/// forgotten with the session or the conversation and at quit.
struct PromptStash: Equatable {
    static let maxEntries = 8
    static let maxLength = PromptDrafts.maxLength
    /// A stashed prompt older than this is typed text nobody remembers: it is dropped, not put back.
    static let maxAge: TimeInterval = 3600

    /// The age rule, with the clock as a parameter. A stamp from the future (the clock moved back) is not fresh.
    static func isFresh(storedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(storedAt)
        return age >= 0 && age <= maxAge
    }

    private var texts: [PromptSlot.Content: (text: String, storedAt: Date)] = [:]
    /// Oldest kept first.
    private var order: [PromptSlot.Content] = []

    var count: Int { texts.count }

    static func == (lhs: PromptStash, rhs: PromptStash) -> Bool {
        lhs.order == rhs.order && lhs.order.allSatisfy { lhs.texts[$0]?.text == rhs.texts[$0]?.text && lhs.texts[$0]?.storedAt == rhs.texts[$0]?.storedAt }
    }

    /// A blank prompt is not kept. A newer prompt of the same content replaces the older one and restarts the age.
    mutating func keep(_ prompt: String, for content: PromptSlot.Content, at now: Date = Date()) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        order.removeAll { $0 == content }
        order.append(content)
        texts[content] = (prompt.count > Self.maxLength ? String(prompt.prefix(Self.maxLength)) : prompt, now)
        while order.count > Self.maxEntries { texts[order.removeFirst()] = nil }
    }

    /// The stashed prompt of a content, removed from the stash. A stale one is removed and not returned.
    mutating func take(for content: PromptSlot.Content, at now: Date = Date()) -> String? {
        guard let entry = texts.removeValue(forKey: content) else { return nil }
        order.removeAll { $0 == content }
        return Self.isFresh(storedAt: entry.storedAt, now: now) ? entry.text : nil
    }

    /// A cmux session is gone: its replies keep nothing, whatever surface they named.
    mutating func forgetReplies(ofTask taskId: String) {
        let gone = order.filter { if case .cmuxReply(let id, _) = $0 { return id == taskId } else { return false } }
        for content in gone { texts[content] = nil }
        order.removeAll { gone.contains($0) }
    }

    mutating func removeAll() { texts = [:]; order = [] }
}
