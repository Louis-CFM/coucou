import Foundation

// Mail triage: the rules, the banned words and the VIPs of the Mail section, the search of
// the Mail pill, and the AppleScript filters they become. Pure Foundation, so it is tested on
// any machine (scripts/test-mail-triage.sh); MailController runs the scripts.

// MARK: - Rules

/// What a rule looks at. `contains` everywhere, ignoring case and accents; `domain` is the end
/// of the sender's address.
enum MailRuleField: String, Codable, CaseIterable, Sendable {
    case sender, domain, subject, text, account
}

struct MailCondition: Codable, Equatable, Sendable {
    var field: MailRuleField
    var value: String
}

/// What a rule does to a message. Coucou never deletes a message.
enum MailRuleAction: Codable, Equatable, Hashable, Sendable {
    case junk
    case important
    case markRead
    case move(String)
}

/// "If every condition matches, do this."
struct MailRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var enabled = true
    var conditions: [MailCondition]
    var action: MailRuleAction
}

/// Everything the Mail section lets the user set for the triage.
struct MailTriageSettings: Codable, Equatable, Sendable {
    /// Sort the messages that arrive from now on.
    var autoSort = false
    /// When the automatic sorting was turned on: older messages are never touched.
    var autoSortSince: Date? = nil
    /// Words, phrases or addresses: a message holding one goes to Junk.
    var banned: [String] = []
    /// Addresses or domains ("@client.fr"): always important, never moved by a rule.
    var vip: [String] = []
    var rules: [MailRule] = []
}

/// What the triage knows about a message when it decides.
struct MailFacts: Sendable {
    var sender: String
    var subject: String
    var account: String
    /// The text, when it was read (banned words and text rules need it).
    var text: String? = nil

    /// The address alone, from "Name <address>".
    var address: String {
        let raw = sender.trimmingCharacters(in: .whitespaces)
        if let lt = raw.firstIndex(of: "<"), let gt = raw.lastIndex(of: ">"), lt < gt {
            return String(raw[raw.index(after: lt)..<gt])
        }
        return raw
    }
}

/// Why a message was sorted the way it was: shown in the journal.
enum MailReason: Codable, Equatable, Sendable {
    case vip(String)
    case banned(String)
    case rule(String)
    /// The user's own click in the Mail pill.
    case manual
}

struct MailDecision: Equatable, Sendable {
    let action: MailRuleAction
    let reason: MailReason
}

enum MailTriage {
    /// Lowercased, without accents: "Réunion" and "reunion" are the same word.
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `needle` in `haystack` as a whole word or phrase ("sale" is not found in "salesforce").
    /// An address or anything with "@" or "." is matched as plain text.
    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        let h = normalize(haystack), n = normalize(needle)
        guard !n.isEmpty else { return false }
        if n.contains("@") || n.contains(".") { return h.contains(n) }
        var start = h.startIndex
        while let r = h.range(of: n, range: start..<h.endIndex) {
            let before = r.lowerBound == h.startIndex ? nil : h[h.index(before: r.lowerBound)]
            let after = r.upperBound == h.endIndex ? nil : h[r.upperBound]
            let edge: (Character?) -> Bool = { c in c.map { !($0.isLetter || $0.isNumber) } ?? true }
            if edge(before) && edge(after) { return true }
            start = h.index(after: r.lowerBound)
        }
        return false
    }

    static func matches(_ c: MailCondition, _ f: MailFacts) -> Bool {
        let v = normalize(c.value)
        guard !v.isEmpty else { return false }
        switch c.field {
        case .sender: return normalize(f.sender).contains(v)
        case .domain:
            let domain = v.hasPrefix("@") ? String(v.dropFirst()) : v
            let address = normalize(f.address)
            return address.hasSuffix("@" + domain) || address.hasSuffix("." + domain)
        case .subject: return normalize(f.subject).contains(v)
        case .text: return f.text.map { normalize($0).contains(v) } ?? false
        case .account: return normalize(f.account).contains(v)
        }
    }

    /// A VIP entry: a whole address, or a domain ("@client.fr" or "client.fr").
    static func isVIP(_ f: MailFacts, _ vip: [String]) -> String? {
        let address = normalize(f.address)
        for entry in vip {
            let e = normalize(entry)
            guard !e.isEmpty else { continue }
            if e.contains("@") && !e.hasPrefix("@") {
                if address == e { return entry }
            } else {
                let domain = e.hasPrefix("@") ? String(e.dropFirst()) : e
                if address.hasSuffix("@" + domain) || address.hasSuffix("." + domain) { return entry }
            }
        }
        return nil
    }

    /// The first banned word found in the sender, the subject or the text.
    static func bannedHit(_ f: MailFacts, _ banned: [String]) -> String? {
        for word in banned where !normalize(word).isEmpty {
            if containsWord(f.sender, word) || containsWord(f.subject, word)
                || f.text.map({ containsWord($0, word) }) == true {
                return word
            }
        }
        return nil
    }

    /// Whether deciding needs the message's text (a banned word or a text rule).
    static func needsText(_ s: MailTriageSettings) -> Bool {
        !s.banned.isEmpty || s.rules.contains { $0.enabled && $0.conditions.contains { $0.field == .text } }
    }

    /// VIPs first (never moved), then banned words, then the rules in order. Nil: left alone.
    static func decide(_ f: MailFacts, _ s: MailTriageSettings) -> MailDecision? {
        if let v = isVIP(f, s.vip) { return MailDecision(action: .important, reason: .vip(v)) }
        if let w = bannedHit(f, s.banned) { return MailDecision(action: .junk, reason: .banned(w)) }
        for rule in s.rules where rule.enabled && !rule.conditions.isEmpty {
            if rule.conditions.allSatisfy({ matches($0, f) }) {
                return MailDecision(action: rule.action, reason: .rule(rule.name))
            }
        }
        return nil
    }
}

// MARK: - Search

/// The search of the Mail pill: free words, plus "de:" / "from:" and "objet:" / "subject:".
struct MailQuery: Equatable, Sendable {
    var from: [String] = []
    var subject: [String] = []
    var words: [String] = []

    var isEmpty: Bool { from.isEmpty && subject.isEmpty && words.isEmpty }

    static let fromKeys = ["de:", "from:", "von:", "da:"]
    static let subjectKeys = ["objet:", "subject:", "asunto:", "betreff:", "assunto:", "oggetto:"]

    /// `de:dupont objet:"devis mai" facture` → from dupont, subject "devis mai", word facture.
    static func parse(_ text: String) -> MailQuery {
        var q = MailQuery()
        var tokens: [String] = []
        var current = "", quoted = false
        for c in text {
            if c == "\"" { quoted.toggle(); continue }
            if c.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        var pending: WritableKeyPath<MailQuery, [String]>? = nil
        for token in tokens {
            let lower = token.lowercased()
            if let key = (fromKeys + subjectKeys).first(where: { lower.hasPrefix($0) }) {
                let path: WritableKeyPath<MailQuery, [String]> = fromKeys.contains(key) ? \.from : \.subject
                let rest = String(token.dropFirst(key.count))
                if rest.isEmpty { pending = path } else { q[keyPath: path].append(rest) }
                continue
            }
            if let path = pending { q[keyPath: path].append(token); pending = nil; continue }
            q.words.append(token)
        }
        return q
    }
}

/// The quick filters of the Mail pill.
enum MailFilter: String, CaseIterable, Sendable {
    case all, unread, flagged, today
}

// MARK: - AppleScript pieces

/// The notch's search and quick filters, run here on the newest messages Mail gave in one
/// read (MailController.searchDepth per inbox). Asking Mail to search (`whose`) scans whole
/// mailboxes and freezes it on a big inbox.
enum MailSearch {
    static func matches(sender: String, subject: String, date: Date, isRead: Bool, isFlagged: Bool,
                        query: MailQuery, filter: MailFilter,
                        now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch filter {
        case .all: break
        case .unread: if isRead { return false }
        case .flagged: if !isFlagged { return false }
        case .today: if !calendar.isDate(date, inSameDayAs: now) { return false }
        }
        let s = MailTriage.normalize(sender), sub = MailTriage.normalize(subject)
        for w in query.words.map(MailTriage.normalize) where !s.contains(w) && !sub.contains(w) { return false }
        for f in query.from.map(MailTriage.normalize) where !s.contains(f) { return false }
        for x in query.subject.map(MailTriage.normalize) where !sub.contains(x) { return false }
        return true
    }
}

enum MailScript {
    /// AppleScript that sets `m` to message `id` of `mailbox` (a reference such as
    /// `mailbox "INBOX" of acc`): straight by its id, without reading the mailbox. Written
    /// «class mssg» because "message id" is also a property of Mail's messages (their
    /// Message-ID). If Mail refuses it, the mailbox is searched as before.
    static func findMessage(_ id: Int, in mailbox: String) -> String {
        """
        set m to missing value
        try
            set m to «class mssg» id \(id) of \(mailbox)
            get id of m
        on error
            set m to first message of \(mailbox) whose id is \(id)
        end try
        """
    }

    /// A string inside AppleScript double quotes.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The names a Junk mailbox has, depending on the provider and the language.
    static let junkNames = ["Junk", "Junk E-mail", "Junk Email", "Spam", "[Gmail]/Spam",
                            "Courrier indésirable", "Indésirables", "Spam-Verdacht", "Correo no deseado"]

    /// AppleScript that applies `action` to message `m` of account `acc`. Moving to Junk also
    /// marks it as junk for Mail's own filter.
    static func apply(_ action: MailRuleAction) -> String {
        switch action {
        case .junk:
            return """
            set junk mail status of m to true
            set moved to false
            repeat with nm in \(list(junkNames))
                if not moved then
                    try
                        move m to mailbox (nm as string) of acc
                        set moved to true
                    end try
                end if
            end repeat
            if not moved then
                try
                    move m to junk mailbox
                end try
            end if
            """
        case .important: return "set flagged status of m to true"
        case .markRead: return "set read status of m to true"
        case .move(let name):
            return """
            try
                move m to mailbox \(quote(name)) of acc
            on error
                move m to mailbox \(quote(name))
            end try
            """
        }
    }

    /// AppleScript that puts message `m` back as it was (the journal's Undo).
    static func undo(_ action: MailRuleAction, fromMailbox: String) -> String {
        switch action {
        case .junk:
            return """
            set junk mail status of m to false
            move m to mailbox \(quote(fromMailbox)) of acc
            """
        case .important: return "set flagged status of m to false"
        case .markRead: return "set read status of m to false"
        case .move: return "move m to mailbox \(quote(fromMailbox)) of acc"
        }
    }

    /// The mailboxes where the message may be after `action`, to find it again for Undo.
    static func placesAfter(_ action: MailRuleAction, fromMailbox: String) -> [String] {
        switch action {
        case .junk: return junkNames.map { "mailbox \(quote($0)) of acc" } + ["junk mailbox"]
        case .move(let name): return ["mailbox \(quote(name)) of acc", "mailbox \(quote(name))"]
        case .important, .markRead: return ["mailbox \(quote(fromMailbox)) of acc"]
        }
    }

    static func list(_ items: [String]) -> String { "{" + items.map(quote).joined(separator: ", ") + "}" }

    /// Sorts one message: finds it by Mail's id in its mailbox, notes its Message-ID (to find it
    /// again for Undo, as Mail's id can change when it moves), applies the action, returns the
    /// Message-ID.
    static func applyScript(account: String, mailbox: String, messageId: Int, action: MailRuleAction) -> String {
        """
        tell application id "com.apple.mail"
            set acc to account \(quote(account))
            \(findMessage(messageId, in: "mailbox \(quote(mailbox)) of acc"))
            set rid to ""
            try
                set rid to message id of m
            end try
        \(indent(apply(action)))
            return rid
        end tell
        """
    }

    /// Undoes a sort: finds the message by its Message-ID where the action put it, then puts
    /// it back.
    static func undoScript(account: String, fromMailbox: String, rfcId: String, action: MailRuleAction) -> String {
        """
        tell application id "com.apple.mail"
            set acc to account \(quote(account))
            set m to missing value
            repeat with mb in {\(placesAfter(action, fromMailbox: fromMailbox).joined(separator: ", "))}
                if m is missing value then
                    try
                        set found to (messages of (contents of mb) whose message id is \(quote(rfcId)))
                        if (count of found) > 0 then set m to item 1 of found
                    end try
                end if
            end repeat
            if m is missing value then error "not found"
        \(indent(undo(action, fromMailbox: fromMailbox)))
            return "ok"
        end tell
        """
    }

    private static func indent(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }
}
