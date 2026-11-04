import Foundation

// The chat's mail actions: the plan the AI writes (a ```coucou-mail JSON block in its answer),
// what Coucou tells the AI, the matching of PDF pages to recipients and the scripts that send.
// Pure Foundation, tested on any machine (scripts/test-mail-triage.sh). Nothing in a plan
// happens until the user clicks Run on its card (MailAgent.swift).

struct MailOutgoing: Equatable, Sendable {
    var to: [String]
    var cc: [String] = []
    var subject: String
    var body: String
    /// Forward the attachments of this message (its number in the list sent to the AI).
    var attachmentsFrom: Int? = nil
    /// Files on the Mac.
    var files: [String] = []
}

struct MailMergeRecipient: Equatable, Sendable {
    var email: String
    var name: String
    /// What the recipient's page holds ("Bordeaux"), and the {key} of the templates.
    var key: String
}

/// One message per recipient, each with its own page of a PDF.
struct MailMerge: Equatable, Sendable {
    var fromMessage: Int?
    /// The PDF among that message's attachments (nil: the first PDF).
    var attachment: String?
    var splitPages: Bool
    /// Pages go to the recipient whose key they contain; false: in order.
    var matchByKey: Bool
    var recipients: [MailMergeRecipient]
    var subject: String
    var body: String
    /// Files on the Mac, instead of a message's PDF.
    var file: String? = nil
}

enum MailPlanAction: Equatable, Sendable {
    case sort(MailRuleAction, messages: [Int])
    case reply(message: Int, body: String)
    case send(MailOutgoing)
    case merge(MailMerge)
    case saveAttachments(message: Int, folder: String)
}

struct MailPlan: Equatable, Sendable {
    var summary: String
    var actions: [MailPlanAction]

    /// How many mails the plan sends.
    var sendCount: Int {
        actions.reduce(0) { n, a in
            switch a {
            case .send: return n + 1
            case .merge(let m): return n + m.recipients.count
            default: return n
            }
        }
    }
}

enum MailPlanParser {
    static let fence = "```coucou-mail"

    /// The answer without its plan block, the plan, and why the block could not be read.
    static func extract(_ text: String) -> (prose: String, plan: MailPlan?, error: String?) {
        guard let start = text.range(of: fence) else { return (text, nil, nil) }
        let afterFence = text[start.upperBound...]
        let end = afterFence.range(of: "```")
        let json = String(end.map { afterFence[..<$0.lowerBound] } ?? afterFence)
        var prose = String(text[..<start.lowerBound])
        if let end { prose += afterFence[end.upperBound...] }
        prose = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        // Still streaming: no closing fence yet.
        guard end != nil else { return (prose, nil, nil) }
        do {
            return (prose, try decode(json), nil)
        } catch {
            return (prose, nil, "\(error)")
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func decode(_ json: String) throws -> MailPlan {
        guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "not a JSON object")
        }
        let list = root["actions"] as? [[String: Any]] ?? []
        var actions: [MailPlanAction] = []
        for (i, a) in list.enumerated() {
            guard let type = a["type"] as? String else { throw Failure(description: "action \(i + 1) has no type") }
            actions.append(try action(type.lowercased(), a, index: i + 1))
        }
        guard !actions.isEmpty else { throw Failure(description: "no actions") }
        return MailPlan(summary: root["summary"] as? String ?? "", actions: actions)
    }

    private static func ints(_ v: Any?) -> [Int] {
        if let n = int(v) { return [n] }
        return (v as? [Any] ?? []).compactMap(int)
    }

    private static func int(_ v: Any?) -> Int? {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) }
        return nil
    }

    private static func strings(_ v: Any?) -> [String] {
        if let s = v as? String { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return (v as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    private static func action(_ type: String, _ a: [String: Any], index: Int) throws -> MailPlanAction {
        func need(_ key: String) throws -> String {
            guard let s = a[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Failure(description: "action \(index) (\(type)) needs \"\(key)\"")
            }
            return s
        }
        func message() throws -> Int {
            guard let n = int(a["message"]) else { throw Failure(description: "action \(index) (\(type)) needs \"message\"") }
            return n
        }
        switch type {
        case "flag", "important", "junk", "read", "mark_read", "move":
            let messages = ints(a["messages"] ?? a["message"])
            guard !messages.isEmpty else { throw Failure(description: "action \(index) (\(type)) needs \"messages\"") }
            let act: MailRuleAction
            switch type {
            case "junk": act = .junk
            case "read", "mark_read": act = .markRead
            case "move": act = .move(try need("mailbox"))
            default: act = .important
            }
            return .sort(act, messages: messages)
        case "reply":
            return .reply(message: try message(), body: try need("body"))
        case "send":
            let to = strings(a["to"])
            guard !to.isEmpty else { throw Failure(description: "action \(index) (send) needs \"to\"") }
            return .send(MailOutgoing(to: to, cc: strings(a["cc"]), subject: a["subject"] as? String ?? "",
                                      body: a["body"] as? String ?? "", attachmentsFrom: int(a["attachments_from"]),
                                      files: strings(a["files"])))
        case "merge", "mail_merge":
            let recipients = (a["recipients"] as? [[String: Any]] ?? []).compactMap { r -> MailMergeRecipient? in
                guard let email = r["email"] as? String, !email.isEmpty else { return nil }
                return MailMergeRecipient(email: email, name: r["name"] as? String ?? "",
                                          key: (r["key"] as? String) ?? (r["city"] as? String) ?? "")
            }
            guard !recipients.isEmpty else { throw Failure(description: "action \(index) (merge) needs \"recipients\"") }
            let match = (a["match"] as? String ?? "key").lowercased()
            return .merge(MailMerge(fromMessage: int(a["from_message"] ?? a["message"]),
                                    attachment: a["attachment"] as? String,
                                    splitPages: a["split_pages"] as? Bool ?? true,
                                    matchByKey: match != "order",
                                    recipients: recipients,
                                    subject: a["subject"] as? String ?? "",
                                    body: a["body"] as? String ?? "",
                                    file: a["file"] as? String))
        case "save_attachments", "save":
            return .saveAttachments(message: try message(), folder: try need("folder"))
        default:
            throw Failure(description: "action \(index) has an unknown type \"\(type)\"")
        }
    }
}

// MARK: - Mail merge

enum MailMergeMatching {
    struct Assignment: Equatable, Sendable {
        let recipient: MailMergeRecipient
        /// The page (0-based) for this recipient, nil when none was found.
        let page: Int?
        /// More than one page held the key: the first free one was taken.
        let ambiguous: Bool
    }

    /// Gives each recipient a page: the one whose text holds its key as a whole word, or the
    /// page in the same order. A page goes to one recipient only.
    static func assign(pages: [String], recipients: [MailMergeRecipient], byKey: Bool) -> [Assignment] {
        guard byKey else {
            return recipients.enumerated().map { i, r in
                Assignment(recipient: r, page: i < pages.count ? i : nil, ambiguous: false)
            }
        }
        var taken = Set<Int>()
        return recipients.map { r in
            let key = r.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return Assignment(recipient: r, page: nil, ambiguous: false) }
            let hits = pages.indices.filter { MailTriage.containsWord(pages[$0], key) }
            let free = hits.filter { !taken.contains($0) }
            guard let page = free.first else { return Assignment(recipient: r, page: nil, ambiguous: false) }
            taken.insert(page)
            return Assignment(recipient: r, page: page, ambiguous: hits.count > 1)
        }
    }

    /// {name}, {key} (and {city}, {email}) filled in.
    static func fill(_ template: String, _ r: MailMergeRecipient) -> String {
        template
            .replacingOccurrences(of: "{name}", with: r.name)
            .replacingOccurrences(of: "{key}", with: r.key)
            .replacingOccurrences(of: "{city}", with: r.key)
            .replacingOccurrences(of: "{email}", with: r.email)
    }

    /// A file name for a recipient's page: "Plans - Bordeaux.pdf".
    static func pageFileName(base: String, key: String, page: Int) -> String {
        let stem = (base as NSString).deletingPathExtension
        let label = key.isEmpty ? "p\(page + 1)" : key
        let safe = (stem + " - " + label).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return safe + ".pdf"
    }
}

enum MailAddress {
    /// A plain address check: something@something.something, no spaces.
    static func isValid(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.contains(" "), let at = t.firstIndex(of: "@"), at != t.startIndex else { return false }
        let domain = t[t.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !domain.contains("@")
    }
}

// MARK: - What the AI is told

enum MailAgentPrompt {
    /// Added to the chat's system prompt while the chat's Mail switch is on.
    static let instructions = """


    The user turned on Mail: you can act on their Apple Mail through Coucou. Their latest messages are listed under their request, each with a number [n]; some come with their text and attachments.
    When they ask you to DO something with their mail, answer in one or two short sentences, then give ONE plan in a fenced code block tagged coucou-mail, holding JSON:
    {"summary": "what the plan does, in the user's language", "actions": [ ... ]}
    Actions:
    - {"type": "flag" | "junk" | "read" | "move", "messages": [n, ...], "mailbox": "only for move"}
    - {"type": "reply", "message": n, "body": "..."} : a reply draft opened in Mail, not sent
    - {"type": "send", "to": ["address"], "cc": [], "subject": "...", "body": "...", "attachments_from": n (optional: that message's attachments), "files": ["/path"] (optional)}
    - {"type": "merge", "from_message": n, "attachment": "name of a PDF in that message", "split_pages": true, "match": "key" or "order", "recipients": [{"email": "...", "name": "...", "key": "what is written on their page, like a city"}], "subject": "... {key} ...", "body": "Hello {name}, ..."} : one mail per recipient, each with the PDF page that contains their key (or the page in the same order)
    - {"type": "save_attachments", "message": n, "folder": "~/Documents/..."}
    Rules: nothing happens until the user clicks Run under your plan, so never say it is done. Never invent an address: use only addresses the user gave, found in their messages, or in a file they shared. If something is missing (the recipients' addresses, which message), ask instead of writing a plan. A question about their mail gets an answer, without a plan. Plain text bodies, in the user's language.
    """

    struct Line: Sendable {
        let number: Int
        let sender: String
        let subject: String
        let date: Date
        let isRead: Bool
        let account: String
        var attachments: [String] = []
        var text: String? = nil
    }

    /// The list sent under the user's request.
    static func snapshot(_ lines: [Line], accounts: [(name: String, address: String)], now: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "\n\n<mail>\n"
        if !accounts.isEmpty {
            out += "Accounts: " + accounts.map { "\($0.name) <\($0.address)>" }.joined(separator: ", ") + "\n"
        }
        for l in lines {
            out += "[\(l.number)] \(df.string(from: l.date)) · \(l.isRead ? "read" : "unread") · \(l.account) · from \(l.sender) · \"\(l.subject)\""
            if !l.attachments.isEmpty { out += " · attachments: " + l.attachments.joined(separator: ", ") }
            out += "\n"
            if let t = l.text, !t.isEmpty {
                out += "    text: " + t.replacingOccurrences(of: "\n", with: " ").prefix(3000) + "\n"
            }
        }
        out += "</mail>"
        return out
    }

    /// The messages a request names (a sender or a subject word of four letters or more),
    /// best first: their text goes to the AI.
    static func mentioned(in query: String, senders: [String], subjects: [String], limit: Int = 3) -> [Int] {
        let words = query.split { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." }
            .map { MailTriage.normalize(String($0)) }
            .filter { $0.count >= 4 }
        guard !words.isEmpty else { return [] }
        var scored: [(Int, Int)] = []
        for i in senders.indices {
            let s = MailTriage.normalize(senders[i]), sub = MailTriage.normalize(subjects[i])
            let score = words.reduce(0) { $0 + (s.contains($1) ? 2 : 0) + (sub.contains($1) ? 1 : 0) }
            if score > 0 { scored.append((i, score)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(limit).map(\.0)
    }
}

// MARK: - Scripts

extension MailScript {
    /// Sends one message from Mail. `from` picks the sending address; attachments are POSIX paths.
    static func sendScript(from: String?, to: [String], cc: [String], subject: String, body: String,
                           attachments: [String]) -> String {
        var s = """
        tell application id "com.apple.mail"
            set m to make new outgoing message with properties {subject:\(quote(subject)), content:\(quote(body)), visible:false}

        """
        if let from, !from.isEmpty { s += "    set sender of m to \(quote(from))\n" }
        s += "    tell m\n"
        for a in to { s += "        make new to recipient at end of to recipients with properties {address:\(quote(a))}\n" }
        for a in cc { s += "        make new cc recipient at end of cc recipients with properties {address:\(quote(a))}\n" }
        for p in attachments {
            s += "        make new attachment with properties {file name:(POSIX file \(quote(p)))} at after the last paragraph of content\n"
        }
        s += "    end tell\n"
        if !attachments.isEmpty { s += "    delay 1\n" }
        s += """
            send m
            return "ok"
        end tell
        """
        return s
    }

    /// Saves a message's attachments (only `onlyName` when given) into `folder`, returns the
    /// saved file names, one per line.
    static func saveAttachmentsScript(account: String, mailbox: String, messageId: Int, folder: String,
                                      onlyName: String? = nil) -> String {
        let test = onlyName.map { "(name of a) is \(quote($0))" } ?? "true"
        return """
        tell application id "com.apple.mail"
            \(MailScript.findMessage(messageId, in: "mailbox \(quote(mailbox)) of account \(quote(account))"))
            set out to ""
            repeat with a in mail attachments of m
                if \(test) then
                    set p to \(quote(folder.hasSuffix("/") ? folder : folder + "/")) & (name of a)
                    save a in (POSIX file p)
                    set out to out & (name of a) & linefeed
                end if
            end repeat
            return out
        end tell
        """
    }

    /// Opens Mail's reply window for a message with `body` above the quoted text. Not sent.
    static func replyDraftScript(account: String, mailbox: String, messageId: Int, body: String) -> String {
        """
        tell application id "com.apple.mail"
            \(MailScript.findMessage(messageId, in: "mailbox \(quote(mailbox)) of account \(quote(account))"))
            set r to reply m with opening window
            try
                set content of r to \(quote(body)) & return & return & (content of r)
            end try
            activate
            return "ok"
        end tell
        """
    }

    /// The names of a message's attachments and the start of its text: names one per line,
    /// then a record separator, then the text.
    static func detailsScript(account: String, mailbox: String, messageId: Int, textLimit: Int) -> String {
        """
        tell application id "com.apple.mail"
            \(MailScript.findMessage(messageId, in: "mailbox \(quote(mailbox)) of account \(quote(account))"))
            set out to ""
            try
                repeat with a in mail attachments of m
                    set out to out & (name of a) & linefeed
                end repeat
            end try
            set c to ""
            try
                set c to content of m
            end try
            if (length of c) > \(textLimit) then set c to text 1 thru \(textLimit) of c
            return out & (character id 30) & c
        end tell
        """
    }

    /// Every enabled account: name, a unit separator, its first address; one per line.
    static let accountsScript = """
    tell application id "com.apple.mail"
        set out to ""
        repeat with acc in (every account whose enabled is true)
            set addr to ""
            try
                set addr to item 1 of (email addresses of acc)
            end try
            set out to out & (name of acc) & (character id 31) & addr & linefeed
        end repeat
        return out
    end tell
    """
}
