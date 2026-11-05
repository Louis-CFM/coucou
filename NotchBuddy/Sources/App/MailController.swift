#if !APPSTORE
import Foundation
import AppKit
import Combine

// MARK: - Mail message

/// One message of an inbox, as Apple Mail reports it.
struct MailMessage: Identifiable, Equatable, Sendable {
    /// Mail's own id of the message (unique within its mailbox).
    let messageId: Int
    let account: String
    let mailbox: String
    /// Raw sender, "Name <address>" or just the address.
    let sender: String
    let subject: String
    let date: Date
    var isRead: Bool
    /// Flagged in Mail: what Coucou calls important.
    var isFlagged: Bool = false

    var id: String { "\(account)/\(mailbox)/\(messageId)" }

    /// "Name" from "Name <address>", else the address before "@".
    var senderName: String {
        let raw = sender.trimmingCharacters(in: .whitespaces)
        if let lt = raw.firstIndex(of: "<") {
            let name = raw[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !name.isEmpty { return name }
            let address = raw[raw.index(after: lt)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
            return String(address.split(separator: "@").first ?? Substring(address))
        }
        return String(raw.split(separator: "@").first ?? Substring(raw))
    }

    /// The address alone, from "Name <address>".
    var senderAddress: String {
        let raw = sender.trimmingCharacters(in: .whitespaces)
        if let lt = raw.firstIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt {
            return String(raw[raw.index(after: lt)..<gt])
        }
        return raw
    }

    var timeAgo: String {
        let diff = Date().timeIntervalSince(date)
        if diff < 60    { return String(localized: "mail.now") }
        if diff < 3600  { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }
}

// MARK: - Mail Controller

/// Reads the inboxes of Apple Mail (every account added to Mail, Gmail included) through
/// Apple Events: unread count, latest messages, and a message's text on demand.
/// Read-only except for the user's own clicks (mark as read, reply window, open in Mail);
/// it never sends anything. Mail is never launched by Coucou: nothing is read while Mail
/// is closed. Polls every 60 s, only while the pill is active and Mail is open.
/// GitHub build only (Apple Events are not allowed in the App Store build).
@MainActor
final class MailController: ObservableObject {
    static let shared = MailController()
    nonisolated static let pillId = "integration_mail"
    nonisolated static let bundleId = "com.apple.mail"

    /// Latest messages of all inboxes, newest first.
    @Published private(set) var messages: [MailMessage] = []
    /// Unread messages in all inboxes (Mail's own count), nil before the first read.
    @Published private(set) var unreadCount: Int?
    @Published private(set) var loaded = false
    @Published private(set) var isMailRunning = false
    @Published private(set) var automationDenied = false
    /// Text of the messages opened in the card, by message id.
    @Published private(set) var previews: [String: String] = [:]
    /// Messages Mail didn't give the text of (in time): the card says so instead of "Loading…".
    @Published private(set) var previewFailed: Set<String> = []

    /// How many messages are kept for the card (the newest across all inboxes).
    nonisolated static let keep = 12
    /// "Load more" adds `keep` at a time, up to this.
    nonisolated static let maxShown = 60

    /// How many of the newest messages the card shows (grows with "Load more").
    @Published private(set) var shownCount = MailController.keep
    /// The pill's search ("de:dupont devis") and quick filter.
    @Published var query = ""
    @Published private(set) var filter: MailFilter = .all
    /// What the search or the filter found; nil when neither is used (the card shows `messages`).
    @Published private(set) var results: [MailMessage]? = nil
    @Published private(set) var searching = false
    /// The newest messages of each inbox, for the search and the filters (kept a minute).
    private var searchPool: [MailMessage]? = nil
    private var searchPoolDate: Date = .distantPast
    private var poolFetching = false

    /// The list the card shows.
    var displayed: [MailMessage] { results ?? messages }

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var fetching = false
    private var lastFetch: Date = .distantPast
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.mail")

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    /// The Mail section's automatic sorting reads the inboxes too, pill on or off.
    private var autoSortOn: Bool { MailTriageStore.shared.settings.autoSort }

    /// The automatic sorting was turned on or off.
    func triageSettingsChanged() { updatePolling() }

    private init() {
        isMailRunning = Self.mailRunning()

        let ws = NSWorkspace.shared.notificationCenter
        notifTokens.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                          object: nil, queue: .main) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == Self.bundleId else { return }
            Task { @MainActor [weak self] in
                self?.isMailRunning = true
                // Mail just opened: it syncs its accounts first (a minute or two of full CPU on
                // a big inbox). Coucou waits 30 s before its first read instead of adding to it.
                try? await Task.sleep(for: .seconds(30))
                guard Self.mailRunning() else { return }
                self?.updatePolling()
            }
        })
        notifTokens.append(ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                          object: nil, queue: .main) { [weak self] notif in
            let bundleId = (notif.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard bundleId == Self.bundleId else { return }
            Task { @MainActor [weak self] in
                self?.isMailRunning = false
                self?.updatePolling()
            }
        })

        // Pill turned on → first read; turned off → stop and forget everything.
        AppState.shared.$activeIntegrations
            .map { $0.contains(Self.pillId) }
            .removeDuplicates()
            .sink { [weak self] _ in
                // The sink runs before the property changes: decide on the next turn.
                DispatchQueue.main.async { self?.updatePolling() }
            }
            .store(in: &cancellables)
    }

    /// Called once at launch so the controller starts observing.
    func start() { updatePolling() }

    // MARK: - Polling

    private static func mailRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    private func updatePolling() {
        if (isPillActive || autoSortOn) && isMailRunning {
            if timer == nil {
                let t = Timer(timeInterval: 60, repeats: true) { _ in
                    MainActor.assumeIsolated { MailController.shared.refresh() }
                }
                t.tolerance = 10
                RunLoop.main.add(t, forMode: .common)
                timer = t
            }
            refresh()
        } else {
            timer?.invalidate()
            timer = nil
            if !isPillActive {
                messages = []
                unreadCount = nil
                previews = [:]
                loaded = false
                results = nil
                searchPool = nil
                query = ""
                filter = .all
                shownCount = Self.keep
            }
        }
    }

    /// Reads the inboxes again unless that was done in the last `minAge` seconds.
    func refreshIfStale(minAge: TimeInterval = 15) {
        guard Date().timeIntervalSince(lastFetch) > minAge else { return }
        refresh()
    }

    /// Reads the unread count and the latest messages of every inbox.
    func refresh() {
        guard isPillActive || autoSortOn, Self.mailRunning(), !fetching else { return }
        isMailRunning = true
        fetching = true
        lastFetch = Date()
        // The sorting looks a little further than the card, so a burst of mail is not missed.
        let perInbox = max(shownCount, autoSortOn ? 30 : 0)
        Task {
            let result = await runAppleScript(Self.listScript(perInbox: perInbox))
            fetching = false
            guard case .success(let values) = result, let text = values.first else { return }
            let parsed = Self.parseList(text)
            if isPillActive {
                unreadCount = parsed.unread
                let newest = Array(parsed.messages.sorted { $0.date > $1.date }.prefix(shownCount))
                if newest != messages { messages = newest }
                loaded = true
            }
            await triage(parsed.messages)
        }
    }

    /// The card shows `keep` more messages.
    func loadMore() {
        guard results == nil, shownCount < Self.maxShown else { return }
        shownCount = min(Self.maxShown, shownCount + Self.keep)
        refresh()
    }

    // MARK: - Search and filters

    func setFilter(_ f: MailFilter) {
        filter = f
        runSearch()
    }

    /// How deep the search and the filters look: the newest messages of each inbox, read in
    /// short steps like the card's own list (a `whose` search in Mail scans the whole mailbox
    /// and freezes it; one big read takes Mail too long on a busy inbox).
    nonisolated static let searchDepth = 300
    nonisolated static let searchStep = 50

    /// Filters the newest messages (read once, kept a minute) with the query and the filter;
    /// nothing to search: back to the list. What is found shows as the steps come in.
    func runSearch() {
        let q = MailQuery.parse(query)
        guard !q.isEmpty || filter != .all else {
            results = nil
            searching = false
            return
        }
        if let pool = searchPool, Date().timeIntervalSince(searchPoolDate) < 60 {
            results = Self.filtered(pool, q, filter)
            searching = false
            return
        }
        // At once: what the card already has.
        results = Self.filtered(searchPool ?? messages, q, filter)
        searching = true
        // One read at a time: a chip clicked during it is applied as the steps land.
        guard !poolFetching, Self.mailRunning() else { return }
        poolFetching = true
        Task {
            var pool: [String: MailMessage] = [:]
            var skip = 0
            while skip < Self.searchDepth {
                let result = await runAppleScript(Self.listScript(perInbox: Self.searchStep, skip: skip))
                guard case .success(let values) = result, let text = values.first else { break }
                let got = Self.parseList(text).messages
                for m in got { pool[m.id] = m }
                skip += Self.searchStep
                let q = MailQuery.parse(query)
                guard searching, !q.isEmpty || filter != .all else { break }
                results = Self.filtered(Array(pool.values), q, filter)
                if got.isEmpty { break }
            }
            poolFetching = false
            if !pool.isEmpty {
                searchPool = Array(pool.values)
                searchPoolDate = Date()
            }
            let q = MailQuery.parse(query)
            guard searching, !q.isEmpty || filter != .all else { return }
            searching = false
            results = Self.filtered(searchPool ?? messages, q, filter)
        }
    }

    nonisolated static func filtered(_ pool: [MailMessage], _ q: MailQuery, _ f: MailFilter) -> [MailMessage] {
        Array(pool.filter {
            MailSearch.matches(sender: $0.sender, subject: $0.subject, date: $0.date,
                               isRead: $0.isRead, isFlagged: $0.isFlagged, query: q, filter: f)
        }.sorted { $0.date > $1.date }.prefix(maxShown))
    }

    func clearSearch() {
        query = ""
        filter = .all
        results = nil
        searching = false
    }

    // MARK: - Sorting

    /// The automatic sorting: each message that arrived since it was turned on is looked at
    /// once (VIPs, banned words, rules), and what it does is written in the journal.
    private func triage(_ list: [MailMessage]) async {
        let store = MailTriageStore.shared
        let settings = store.settings
        guard settings.autoSort, let since = settings.autoSortSince else { return }
        let fresh = list.filter { $0.date >= since && !store.isSeen($0.id) }.sorted { $0.date < $1.date }
        guard !fresh.isEmpty else { return }
        store.markSeen(fresh.map(\.id))
        store.countChecked(fresh.count)
        let needsText = MailTriage.needsText(settings)
        for message in fresh {
            var facts = MailFacts(sender: message.sender, subject: message.subject, account: message.account)
            if needsText { facts.text = await readText(message, limit: 4000) }
            guard let decision = MailTriage.decide(facts, settings) else { continue }
            await perform(decision.action, on: message, reason: decision.reason)
        }
    }

    /// Applies `action` to the message in Mail, writes it in the journal and updates the card.
    @discardableResult
    func perform(_ action: MailRuleAction, on message: MailMessage, reason: MailReason) async -> Bool {
        let script = MailScript.applyScript(account: message.account, mailbox: message.mailbox,
                                            messageId: message.messageId, action: action)
        guard case .success(let values) = await runAppleScript(script) else { return false }
        MailTriageStore.shared.record(MailJournalEntry(
            date: Date(), account: message.account, fromMailbox: message.mailbox,
            sender: message.sender, subject: message.subject, rfcId: values.first ?? "",
            action: action, reason: reason))
        updateLocal(message.id) { m in
            switch action {
            case .junk, .move: return nil
            case .important: m.isFlagged = true; return m
            case .markRead: m.isRead = true; return m
            }
        }
        if action == .junk || action == .markRead, !message.isRead, let u = unreadCount { unreadCount = max(0, u - 1) }
        return true
    }

    /// Changes (or, returning nil, removes) a message in the card's lists.
    private func updateLocal(_ id: String, _ change: (inout MailMessage) -> MailMessage?) {
        func apply(_ list: [MailMessage]) -> [MailMessage] {
            list.compactMap { m in
                guard m.id == id else { return m }
                var copy = m
                return change(&copy)
            }
        }
        messages = apply(messages)
        if let r = results { results = apply(r) }
        if let p = searchPool { searchPool = apply(p) }
    }

    /// Puts back a message the journal shows as sorted.
    func undo(_ entry: MailJournalEntry) {
        guard Self.mailRunning(), !entry.undone, !entry.rfcId.isEmpty else { return }
        Task {
            let script = MailScript.undoScript(account: entry.account, fromMailbox: entry.fromMailbox,
                                               rfcId: entry.rfcId, action: entry.action)
            if case .success = await runAppleScript(script) {
                MailTriageStore.shared.markUndone(entry.id)
                refreshIfStale(minAge: 0)
            }
        }
    }

    /// The message's text, `limit` characters at most ("" when Mail can't give it).
    private func readText(_ message: MailMessage, limit: Int) async -> String {
        let script = Self.messageScript(message, body: """
            set c to ""
            try
                set c to content of m
            end try
            if (length of c) > \(limit) then set c to text 1 thru \(limit) of c
            return c
            """)
        if case .success(let values) = await runAppleScript(script) { return values.first ?? "" }
        return ""
    }

    // MARK: - Actions (each one follows a click)

    /// The message's text (first 4,000 characters), read once and cached. Mail may have to
    /// download it: 20 seconds at most, then the card says it couldn't.
    func loadPreview(_ message: MailMessage) {
        guard previews[message.id] == nil, Self.mailRunning() else { return }
        previewFailed.remove(message.id)
        Task {
            let script = Self.messageScript(message, body: """
                set c to ""
                with timeout of 20 seconds
                    set c to content of m
                end timeout
                if c is missing value then set c to ""
                if (length of c) > 4000 then set c to text 1 thru 4000 of c
                return c
                """)
            let result = await runAppleScript(script)
            if case .success(let values) = result {
                let text = (values.first ?? "")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .replacingOccurrences(of: "\u{FFFC}", with: "")   // attachment placeholders
                    .replacingOccurrences(of: "\n\n\n", with: "\n\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                previews[message.id] = text
            } else {
                previewFailed.insert(message.id)
            }
        }
    }

    /// Flag or unflag the message (Coucou's "important").
    func toggleFlag(_ message: MailMessage) {
        guard Self.mailRunning() else { return }
        let on = !message.isFlagged
        updateLocal(message.id) { m in m.isFlagged = on; return m }
        Task {
            await runAppleScript(Self.messageScript(message, body: "set flagged status of m to \(on)"))
        }
    }

    /// Junk, from the card: written in the journal, so it can be put back.
    func moveToJunk(_ message: MailMessage) {
        guard Self.mailRunning() else { return }
        Task { await perform(.junk, on: message, reason: .manual) }
    }

    /// "Always ignore this sender": the address becomes a banned word, and this message goes to Junk.
    func ignoreSender(_ message: MailMessage) {
        MailTriageStore.shared.addBanned(message.senderAddress)
        moveToJunk(message)
    }

    /// "Always important": the address becomes a VIP, and this message is flagged.
    func makeVIP(_ message: MailMessage) {
        MailTriageStore.shared.addVIP(message.senderAddress)
        if !message.isFlagged { toggleFlag(message) }
    }

    func markAsRead(_ message: MailMessage) {
        guard Self.mailRunning() else { return }
        if let i = messages.firstIndex(where: { $0.id == message.id }) {
            if !messages[i].isRead, let u = unreadCount { unreadCount = max(0, u - 1) }
            messages[i].isRead = true
        }
        Task {
            await runAppleScript(Self.messageScript(message, body: "set read status of m to true"))
        }
    }

    /// Opens Mail's own reply window for the message. Nothing is sent: the user writes
    /// and sends from Mail.
    func reply(_ message: MailMessage) {
        guard Self.mailRunning() else { return }
        Task {
            await runAppleScript(Self.messageScript(message, body: """
                reply m with opening window
                activate
                """))
        }
    }

    func openInMail(_ message: MailMessage) {
        guard Self.mailRunning() else { openMail(); return }
        Task {
            await runAppleScript(Self.messageScript(message, body: """
                open m
                activate
                """))
        }
    }

    func openMail() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Scripts

    /// Field and record separators: characters that never appear in a subject or a name.
    nonisolated static let fieldSep: Character = "\u{1F}"
    nonisolated static let recordSep: Character = "\u{1E}"

    /// Unread count, then for each account's inbox its newest `perInbox` messages:
    /// id, account, mailbox, sender, subject, date (ISO), read status.
    /// `skip` passes over the newest ones first: the search reads the inboxes in short steps.
    nonisolated static func listScript(perInbox: Int, skip: Int = 0) -> String {
        """
        set RS to character id 30
        set US to character id 31
        tell application id "com.apple.mail"
            -- Mail busy for 30 s: give up rather than queue more (it is never the user's wait).
            with timeout of 30 seconds
            set uc to 0
            try
                set uc to unread count of inbox
            end try
            set L to {(uc as string)}
            set accs to {}
            try
                set accs to (every account whose enabled is true)
            on error
                try
                    set accs to every account
                end try
            end try
            repeat with acc in accs
                set mb to missing value
                try
                    set mb to mailbox "INBOX" of acc
                on error
                    try
                        set mb to mailbox "Inbox" of acc
                    end try
                end try
                if mb is not missing value then
                    set accName to name of acc
                    set mbName to name of mb
                    set n to 0
                    try
                        set n to count of messages of mb
                    end try
                    if n > \(skip) then
                        set s to \(skip)
                        set e to s + \(perInbox)
                        if e > n then set e to n
                        -- Newest first when message 1 is the most recent, else read from the end.
                        set a to s + 1
                        set b to e
                        try
                            if (date received of message 1 of mb) < (date received of message n of mb) then
                                set a to n - e + 1
                                set b to n - s
                            end if
                        end try
                        -- One request per field for the whole range (not one per message).
                        try
                            set ids to id of messages a thru b of mb
                            set subs to subject of messages a thru b of mb
                            set snds to sender of messages a thru b of mb
                            set dts to date received of messages a thru b of mb
                            set rds to read status of messages a thru b of mb
                            set fls to {}
                            try
                                set fls to flagged status of messages a thru b of mb
                            end try
                            repeat with i from 1 to count of ids
                                try
                                    set s to item i of subs
                                    if s is missing value then set s to ""
                                    set f to item i of snds
                                    if f is missing value then set f to ""
                                    set d to ""
                                    try
                                        set d to ((item i of dts) as «class isot» as string)
                                    end try
                                    set fl to "false"
                                    try
                                        set fl to ((item i of fls) as string)
                                    end try
                                    set end of L to ((item i of ids) as string) & US & accName & US & mbName & US & f & US & s & US & d & US & ((item i of rds) as string) & US & fl
                                end try
                            end repeat
                        end try
                    end if
                end if
            end repeat
            end timeout
        end tell
        -- One join at the end (adding to a growing text each time is slow on long lists).
        set AppleScript's text item delimiters to RS
        set out to L as text
        set AppleScript's text item delimiters to ""
        return out
        """
    }

    /// A script that finds `message` in its mailbox as `m`, then runs `body`.
    nonisolated static func messageScript(_ message: MailMessage, body: String) -> String {
        """
        tell application id "com.apple.mail"
            set mb to mailbox "\(escape(message.mailbox))" of account "\(escape(message.account))"
            \(MailScript.findMessage(message.messageId, in: "mb"))
            \(body)
        end tell
        """
    }

    nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Parses the list script's output (see listScript). Malformed records are skipped.
    nonisolated static func parseList(_ text: String) -> (unread: Int?, messages: [MailMessage]) {
        let records = text.split(separator: recordSep, omittingEmptySubsequences: false)
        guard let head = records.first else { return (nil, []) }
        let unread = Int(head.trimmingCharacters(in: .whitespaces))
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var seen = Set<String>()
        var out: [MailMessage] = []
        for record in records.dropFirst() {
            let f = record.split(separator: fieldSep, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, let id = Int(f[0]) else { continue }
            let msg = MailMessage(messageId: id, account: f[1], mailbox: f[2], sender: f[3],
                                  subject: f[4], date: iso.date(from: f[5]) ?? .distantPast,
                                  isRead: f[6] == "true", isFlagged: f.count >= 8 && f[7] == "true")
            guard seen.insert(msg.id).inserted else { continue }
            out.append(msg)
        }
        return (unread, out)
    }

    // MARK: - AppleScript runner

    enum ScriptResult { case success([String]), denied, error }

    @discardableResult
    func runAppleScript(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { cont in
            queue.async {
                guard let script = NSAppleScript(source: source) else {
                    cont.resume(returning: .error)
                    return
                }
                var errDict: NSDictionary?
                let desc = script.executeAndReturnError(&errDict)
                if let errDict {
                    let code = (errDict[NSAppleScript.errorNumber] as? Int) ?? 0
                    if code == -1743 {
                        Task { @MainActor in MailController.shared.automationDenied = true }
                        cont.resume(returning: .denied)
                    } else {
                        cont.resume(returning: .error)
                    }
                    return
                }
                Task { @MainActor in MailController.shared.automationDenied = false }
                // Extract the values on this queue before resuming (NSAppleEventDescriptor is not Sendable).
                cont.resume(returning: .success([desc.stringValue ?? ""]))
            }
        }
    }
}
#endif
