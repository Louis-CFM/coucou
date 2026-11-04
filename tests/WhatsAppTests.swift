import Foundation

@main
enum WhatsAppTests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func msg(_ id: String, chat: String, from: String? = nil, text: String = "hi", at: Double = 0,
                    fromMe: Bool = false, mention: Bool = false) -> WAMessage {
        WAMessage(id: id, chat: chat, sender: from ?? chat, senderName: "Marie", text: text,
                  date: Date(timeIntervalSince1970: 1_800_000_000 + at), fromMe: fromMe, mentionsMe: mention)
    }

    static func main() {
        print("\nInbox: one conversation per chat")
        do {
            var inbox = WAInbox()
            let f = WAFilters()
            check("a new message notifies", inbox.add(msg("1", chat: "33600000001@s.whatsapp.net"), filters: f) == .notify)
            inbox.add(msg("2", chat: "33600000001@s.whatsapp.net", at: 5), filters: f)
            inbox.add(msg("3", chat: "33600000002@s.whatsapp.net", at: 3), filters: f)
            check("grouped by chat", inbox.conversations.count == 2)
            check("unread counted", inbox.conversations["33600000001@s.whatsapp.net"]?.unread == 2)
            check("newest first", inbox.sorted.first?.id == "33600000001@s.whatsapp.net")
            check("a duplicate is ignored", inbox.add(msg("2", chat: "33600000001@s.whatsapp.net"), filters: f) == .duplicate)
            check("the same person under another form", inbox.add(msg("4", chat: "33600000001:7@c.us", at: 9), filters: f) == .notify
                  && inbox.conversations.count == 2)
            inbox.markRead("33600000001@s.whatsapp.net")
            check("marked read", inbox.conversations["33600000001@s.whatsapp.net"]?.unread == 0)
            check("total", inbox.totalUnread == 1)
            check("my own message is quiet and reads the chat",
                  inbox.add(msg("5", chat: "33600000002@s.whatsapp.net", at: 10, fromMe: true), filters: f) == .quiet
                  && inbox.conversations["33600000002@s.whatsapp.net"]?.unread == 0)
        }

        print("\nFilters")
        do {
            var inbox = WAInbox()
            var f = WAFilters()
            let group = "120363000000000001@g.us"
            check("a group stays quiet", inbox.add(msg("g1", chat: group, from: "336@s.whatsapp.net"), filters: f) == .quiet)
            check("hidden from the pill", inbox.visible(filters: f).isEmpty)
            check("unless it mentions me", inbox.add(msg("g2", chat: group, from: "336@s.whatsapp.net", mention: true), filters: f) == .notify)
            check("then it shows", inbox.visible(filters: f).count == 1)
            f.ignored = ["33600000009@s.whatsapp.net"]
            check("an ignored chat never comes in", inbox.add(msg("i1", chat: "33600000009@s.whatsapp.net"), filters: f) == .ignored)
            f.muteGroups = false
            check("groups heard when not muted", inbox.add(msg("g3", chat: group, from: "336@s.whatsapp.net"), filters: f) == .notify)
        }

        print("\nStatus updates and channels are not conversations (#901)")
        do {
            var inbox = WAInbox()
            let f = WAFilters()
            check("a contact's Status is left out", inbox.add(msg("s1", chat: "status@broadcast", from: "33600000001@s.whatsapp.net", text: "https://vm.tiktok.com/x"), filters: f) == .ignored)
            check("a channel post is left out", inbox.add(msg("n1", chat: "120363000000000001@newsletter"), filters: f) == .ignored)
            check("nothing shows", inbox.visible(filters: f).isEmpty)
            check("people and groups still are", WAJID.isConversation("33600000001@s.whatsapp.net") && WAJID.isConversation("120363@g.us") && WAJID.isConversation("251556368777322@lid"))
        }

        print("\nOnly the last messages are kept")
        do {
            var inbox = WAInbox()
            for i in 0..<30 { inbox.add(msg("m\(i)", chat: "1@s.whatsapp.net", at: Double(i)), filters: WAFilters()) }
            check("20 kept, newest last", inbox.conversations["1@s.whatsapp.net"]?.messages.count == 20
                  && inbox.conversations["1@s.whatsapp.net"]?.messages.last?.id == "m29")
            var big = WAInbox()
            for i in 0..<2_500 { big.add(msg("b\(i)", chat: "2@s.whatsapp.net", at: Double(i)), filters: WAFilters()) }
            check("the newest ids are still known after 2,000", big.add(msg("b2499", chat: "2@s.whatsapp.net"), filters: WAFilters()) == .duplicate)
            var groups = WAInbox()
            groups.add(msg("q1", chat: "120363000000000009@g.us", from: "33@s.whatsapp.net"), filters: WAFilters())
            check("a muted group's quiet messages don't count as unread to read", groups.visibleUnread(filters: WAFilters()) == 0)
            groups.remove("120363000000000009@g.us")
            check("removed", groups.conversations.isEmpty)
            inbox.clear()
            check("cleared", inbox.conversations.isEmpty)
        }

        print("\nLabels")
        do {
            check("initials", WAJID.initials("Marie Dupont") == "MD" && WAJID.initials("+33 6") == "#")
            check("number", WAJID.displayNumber("33612345678@s.whatsapp.net") == "+33612345678")
            check("group", WAJID.isGroup("1203@g.us") && !WAJID.isGroup("33@s.whatsapp.net"))
            check("voice duration", WAMessage(id: "v", chat: "c", sender: "c", senderName: "", text: "", media: .voice(seconds: 12),
                                              date: Date()).previewKey == ("whatsapp.media.voice", "0:12"))
        }

        print("\nRate limit")
        do {
            var limit = WARateLimit(limit: 3, window: 60)
            let now = Date()
            check("three in a minute", limit.allow(now: now) && limit.allow(now: now) && limit.allow(now: now))
            check("not four", !limit.allow(now: now))
            check("again a minute later", limit.allow(now: now.addingTimeInterval(61)))
        }

        print("\nReplies")
        do {
            var inbox = WAInbox()
            inbox.add(msg("r1", chat: "33600000001@s.whatsapp.net"), filters: WAFilters())
            check("a reply in an open conversation", WAReply.check("ok !", to: "33600000001@s.whatsapp.net", in: inbox) == nil)
            check("…under its other form too", WAReply.check("ok", to: "33600000001@c.us", in: inbox) == nil)
            check("never to a new chat", WAReply.check("hi", to: "33699999999@s.whatsapp.net", in: inbox) == .notAConversation)
            check("nothing empty", WAReply.check("  \n ", to: "33600000001@s.whatsapp.net", in: inbox) == .empty)
            check("not too long", WAReply.check(String(repeating: "a", count: 4097), to: "33600000001@s.whatsapp.net", in: inbox) == .tooLong)
        }

        print("\nThe webhook's HTTP request")
        do {
            let body = #"{"event":"message"}"#
            let raw = "POST /whatsapp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nX-Hub-Signature-256: sha256=ab\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            if case .done(let r) = WAHTTPRequest.parse(Data(raw.utf8)) {
                check("method and path", r.method == "POST" && r.path == "/whatsapp")
                check("headers lowercased", r.headers["x-hub-signature-256"] == "sha256=ab")
                check("body", String(data: r.body, encoding: .utf8) == body)
            } else { check("parsed", false) }
            check("incomplete body waits", WAHTTPRequest.parse(Data(String(raw.dropLast(3)).utf8)) == .incomplete)
            check("headers not done yet", WAHTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
            check("garbage refused", WAHTTPRequest.parse(Data("\r\n\r\n".utf8)) == .invalid)
            check("constant-time compare", waConstantTimeEqual("abc", "abc") && !waConstantTimeEqual("abc", "abd"))
        }

        runGatewayTests()

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nAll WhatsApp tests passed")
    }
}
