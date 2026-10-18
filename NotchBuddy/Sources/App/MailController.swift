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

    /// How many messages are kept for the card (the newest across all inboxes).
    nonisolated static let keep = 12

    private var notifTokens: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var timer: Timer?
    private var fetching = false
    private var lastFetch: Date = .distantPast
    private let queue = DispatchQueue(label: "fr.louisraille.coucou.mail")

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

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
        if isPillActive && isMailRunning {
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
        guard isPillActive, Self.mailRunning(), !fetching else { return }
        isMailRunning = true
        fetching = true
        lastFetch = Date()
        Task {
            let result = await runAppleScript(Self.listScript(perInbox: Self.keep))
            fetching = false
            guard case .success(let values) = result, let text = values.first else { return }
            let parsed = Self.parseList(text)
            unreadCount = parsed.unread
            let newest = Array(parsed.messages.sorted { $0.date > $1.date }.prefix(Self.keep))
            if newest != messages { messages = newest }
            loaded = true
        }
    }

    // MARK: - Actions (each one follows a click)

    /// The message's text (first 1,200 characters), read once and cached.
    func loadPreview(_ message: MailMessage) {
        guard previews[message.id] == nil, Self.mailRunning() else { return }
        Task {
            let script = Self.messageScript(message, body: """
                set c to ""
                try
                    set c to content of m
                end try
                if (length of c) > 1200 then set c to text 1 thru 1200 of c
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
                previews[message.id] = ""
            }
        }
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
    nonisolated static func listScript(perInbox: Int) -> String {
        """
        set RS to character id 30
        set US to character id 31
        tell application id "com.apple.mail"
            set uc to 0
            try
                set uc to unread count of inbox
            end try
            set out to (uc as string)
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
                    set n to 0
                    try
                        set n to count of messages of mb
                    end try
                    if n > 0 then
                        set k to \(perInbox)
                        if n < k then set k to n
                        -- Newest first when message 1 is the most recent, else read from the end.
                        set a to 1
                        set b to k
                        try
                            if (date received of message 1 of mb) < (date received of message n of mb) then
                                set a to n - k + 1
                                set b to n
                            end if
                        end try
                        -- One request per field for the whole range (not one per message).
                        try
                            set ids to id of messages a thru b of mb
                            set subs to subject of messages a thru b of mb
                            set snds to sender of messages a thru b of mb
                            set dts to date received of messages a thru b of mb
                            set rds to read status of messages a thru b of mb
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
                                    set out to out & RS & ((item i of ids) as string) & US & (name of acc) & US & (name of mb) & US & f & US & s & US & d & US & ((item i of rds) as string)
                                end try
                            end repeat
                        end try
                    end if
                end if
            end repeat
            return out
        end tell
        """
    }

    /// A script that finds `message` in its mailbox as `m`, then runs `body`.
    nonisolated static func messageScript(_ message: MailMessage, body: String) -> String {
        """
        tell application id "com.apple.mail"
            set mb to mailbox "\(escape(message.mailbox))" of account "\(escape(message.account))"
            set m to first message of mb whose id is \(message.messageId)
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
                                  isRead: f[6] == "true")
            guard seen.insert(msg.id).inserted else { continue }
            out.append(msg)
        }
        return (unread, out)
    }

    // MARK: - AppleScript runner

    enum ScriptResult { case success([String]), denied, error }

    @discardableResult
    private func runAppleScript(_ source: String) async -> ScriptResult {
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
