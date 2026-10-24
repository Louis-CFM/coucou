import Foundation

// WhatsApp in the notch (GitHub build only): what Coucou keeps of the conversations, in memory
// only, and the rules that decide what reaches the pill. Pure Foundation, so the parsing and
// the rules are tested without the app (tests/WhatsAppTests.swift). Nothing here is ever
// written to disk or to a log.

/// What a message holds besides text: only a label is shown, the media itself is never fetched.
enum WAMedia: Equatable, Sendable {
    case none
    case image
    case video
    case audio(seconds: Int?)
    case voice(seconds: Int?)
    case document(name: String?)
    case sticker
    case location
    case contact
    case other
}

struct WAMessage: Identifiable, Equatable, Sendable {
    var id: String
    /// The conversation: a person (…@s.whatsapp.net, …@lid, …@c.us) or a group (…@g.us).
    var chat: String
    /// Who wrote it (in a group, the member; in a private chat, the chat itself).
    var sender: String
    var senderName: String
    var text: String
    var media: WAMedia = .none
    var date: Date
    var fromMe: Bool = false
    /// The message mentions this account (only meaningful in groups).
    var mentionsMe: Bool = false
    /// Set by the gateway when the chat name came with the message.
    var chatName: String? = nil
}

extension WAMessage {
    /// One line for the pill: the text, else the media's label (English keys, localized by the view).
    var previewKey: (key: String, value: String) {
        switch media {
        case .none: return ("", text)
        case .image: return ("whatsapp.media.photo", text)
        case .video: return ("whatsapp.media.video", text)
        case .audio(let s), .voice(let s): return ("whatsapp.media.voice", s.map(WAJID.duration) ?? "")
        case .document(let name): return ("whatsapp.media.document", name ?? text)
        case .sticker: return ("whatsapp.media.sticker", "")
        case .location: return ("whatsapp.media.location", "")
        case .contact: return ("whatsapp.media.contact", "")
        case .other: return ("whatsapp.media.other", text)
        }
    }
}

struct WAConversation: Identifiable, Equatable, Sendable {
    var id: String   // the chat JID
    var name: String
    var isGroup: Bool
    /// Newest last, the last `WAInbox.keep` only.
    var messages: [WAMessage] = []
    var unread: Int = 0
    var lastActivity: Date
}

/// What the user chose in Settings → WhatsApp.
struct WAFilters: Equatable, Sendable {
    /// Groups stay quiet unless the message mentions you.
    var muteGroups = true
    /// Chats never shown (JIDs).
    var ignored: Set<String> = []
}

enum WAJID {
    static func isGroup(_ jid: String) -> Bool { jid.hasSuffix("@g.us") }

    /// Status updates (status@broadcast), broadcast lists and channels (…@newsletter) come in as
    /// messages too, but they are not conversations: a contact's Status would become a chat named after them (#901).
    static func isConversation(_ jid: String) -> Bool { !jid.hasSuffix("@broadcast") && !jid.hasSuffix("@newsletter") }

    /// "33612345678@s.whatsapp.net" → "+33 6 12 34 56 78"-ish: the digits with a plus.
    static func displayNumber(_ jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        let digits = user.split(separator: ":").first.map(String.init) ?? user
        return digits.allSatisfy(\.isNumber) && !digits.isEmpty ? "+" + digits : digits
    }

    /// Two letters for the avatar: "Marie Dupont" → "MD", "+33 6…" → "#".
    static func initials(_ name: String) -> String {
        let words = name.split { $0 == " " || $0 == "-" }.filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "#" : letters.joined()
    }

    /// 12 → "0:12", 75 → "1:15".
    static func duration(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }

    /// The same person under its several forms: "33612345678:12@s.whatsapp.net" and
    /// "33612345678@c.us" are one chat.
    static func normalized(_ jid: String) -> String {
        let parts = jid.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return jid }
        let user = parts[0].split(separator: ":").first.map(String.init) ?? parts[0]
        let server = parts[1] == "c.us" ? "s.whatsapp.net" : parts[1]
        return "\(user)@\(server)"
    }
}

/// The conversations, grouped by chat: one entry per conversation, never one per message.
struct WAInbox: Equatable, Sendable {
    static let keep = 20

    private(set) var conversations: [String: WAConversation] = [:]
    private var seenIds: Set<String> = []
    /// The same ids in arrival order, so the oldest are the ones forgotten.
    private var seenOrder: [String] = []

    /// Newest activity first.
    var sorted: [WAConversation] {
        conversations.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    var totalUnread: Int { conversations.values.reduce(0) { $0 + $1.unread } }

    enum Outcome: Equatable { case duplicate, ignored, quiet, notify }

    /// Adds a message to its conversation. `.notify` when it should reach you (Mochi reacts),
    /// `.quiet` when it is kept but stays silent (a muted group, your own message).
    @discardableResult
    /// `history`: an older message loaded on demand (a conversation opened): kept, never counted
    /// as unread, never announced.
    mutating func add(_ message: WAMessage, filters: WAFilters, name: String? = nil, history: Bool = false) -> Outcome {
        guard !seenIds.contains(message.id) else { return .duplicate }
        let chat = WAJID.normalized(message.chat)
        guard WAJID.isConversation(chat), !filters.ignored.contains(chat) else { return .ignored }
        seenIds.insert(message.id)
        seenOrder.append(message.id)
        if seenOrder.count > 2_000 {
            let dropped = seenOrder.prefix(1_000)
            seenOrder.removeFirst(1_000)
            for id in dropped { seenIds.remove(id) }
        }

        let isGroup = WAJID.isGroup(chat)
        let number = WAJID.displayNumber(chat)
        // In a private chat the other person names it: never your own name on your own message.
        let personName = isGroup || message.fromMe ? nil : nonEmpty(message.senderName)
        var conversation = conversations[chat] ?? WAConversation(
            id: chat, name: name ?? message.chatName ?? personName ?? number,
            isGroup: isGroup, lastActivity: message.date)
        if let name = name ?? message.chatName, !name.isEmpty { conversation.name = name }
        else if conversation.name == number, let personName { conversation.name = personName }
        var msg = message
        msg.chat = chat
        conversation.messages.append(msg)
        conversation.messages.sort { $0.date < $1.date }
        if conversation.messages.count > Self.keep { conversation.messages.removeFirst(conversation.messages.count - Self.keep) }
        conversation.lastActivity = max(conversation.lastActivity, message.date)

        let outcome: Outcome
        if history {
            outcome = .quiet
        } else if message.fromMe {
            // You answered from the phone: it is read there.
            conversation.unread = 0
            outcome = .quiet
        } else {
            conversation.unread += 1
            outcome = isGroup && filters.muteGroups && !message.mentionsMe ? .quiet : .notify
        }
        conversations[chat] = conversation
        return outcome
    }

    /// The conversations the pill lists: muted groups without unread mentions stay out of it.
    func visible(filters: WAFilters) -> [WAConversation] {
        sorted.filter { !filters.ignored.contains($0.id) && (!$0.isGroup || !filters.muteGroups || $0.messages.contains { $0.mentionsMe && !$0.fromMe }) }
    }

    /// Unread messages in the conversations the pill shows (a muted group's quiet messages
    /// and an ignored chat can't be opened, so they don't count).
    func visibleUnread(filters: WAFilters) -> Int {
        visible(filters: filters).reduce(0) { $0 + $1.unread }
    }

    /// A chat dropped from the inbox (the user ignores it).
    mutating func remove(_ chat: String) {
        conversations[WAJID.normalized(chat)] = nil
    }

    mutating func markRead(_ chat: String) {
        conversations[WAJID.normalized(chat)]?.unread = 0
    }

    /// History loaded at connection: whether it was read is unknown, so nothing counts as new.
    mutating func markAllRead() {
        for key in conversations.keys { conversations[key]?.unread = 0 }
    }

    mutating func rename(_ chat: String, to name: String) {
        guard !name.isEmpty else { return }
        conversations[WAJID.normalized(chat)]?.name = name
    }

    /// Everything goes (Coucou quits, WhatsApp turned off).
    mutating func clear() {
        conversations = [:]
        seenIds = []
        seenOrder = []
    }

    private func nonEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}

/// What may be sent from the notch: a reply, in a conversation already there, one at a time.
enum WAReply {
    enum Refusal: Equatable, Sendable { case empty, tooLong, notAConversation }
    /// The gateways' own cap (OpenWA's send-text takes 4,096 characters at most).
    static let maxLength = 4096

    static func check(_ text: String, to chat: String, in inbox: WAInbox) -> Refusal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maxLength { return .tooLong }
        // Never a new chat, never a list of recipients: only a conversation that wrote to you.
        guard inbox.conversations[WAJID.normalized(chat)] != nil else { return .notAConversation }
        return nil
    }
}

/// A few sends a minute at most, whatever is clicked: Coucou is no bulk sender.
struct WARateLimit: Sendable {
    var limit = 6
    var window: TimeInterval = 60
    private(set) var sent: [Date] = []

    init(limit: Int = 6, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    mutating func allow(now: Date = Date()) -> Bool {
        sent.removeAll { now.timeIntervalSince($0) > window }
        guard sent.count < limit else { return false }
        sent.append(now)
        return true
    }
}

// MARK: - The webhook's HTTP request

/// One HTTP request read from the local socket: enough of HTTP/1.1 for a gateway's webhook.
struct WAHTTPRequest: Equatable, Sendable {
    var method: String
    var path: String
    /// Lowercased names.
    var headers: [String: String]
    var body: Data

    enum Parse: Equatable { case incomplete, invalid, done(WAHTTPRequest) }

    /// Parses what arrived so far; `.incomplete` until the whole body is there.
    static func parse(_ data: Data, maxBody: Int = 1_000_000) -> Parse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16_384 ? .invalid : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBody else { return .invalid }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .done(WAHTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body)))
    }

    static func response(_ status: Int, _ reason: String) -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}

// MARK: - Hex

extension Data {
    var waHex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Compares two strings in constant time (signatures).
func waConstantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    guard x.count == y.count else { return false }
    var diff: UInt8 = 0
    for i in x.indices { diff |= x[i] ^ y[i] }
    return diff == 0
}
