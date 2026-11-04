import Foundation

// The gateways' payloads, copied verbatim from their own docs (see each fixture's source),
// through Coucou's parsers.

extension WhatsAppTests {
    // GOWA docs/webhook-payload.md — text message
    static let gowaText = #"""
    {
      "event": "message",
      "device_id": "628987654321@s.whatsapp.net",
      "payload": {
        "id": "3EB0C127D7BACC83D6A1",
        "chat_id": "628987654321@s.whatsapp.net",
        "from": "628123456789@s.whatsapp.net",
        "from_lid": "251556368777322@lid",
        "sender_display_name": "Saved Contact",
        "from_name": "John Doe",
        "timestamp": "2023-10-15T10:30:00Z",
        "is_from_me": false,
        "body": "Hello, how are you?"
      }
    }
    """#

    // GOWA docs/webhook-payload.md — image, auto-download, with caption
    static let gowaImage = #"""
    {
      "event": "message",
      "device_id": "628987654321@s.whatsapp.net",
      "payload": {
        "id": "3EB0C127D7BACC83D6A3",
        "chat_id": "628987654321@s.whatsapp.net",
        "from": "628123456789@s.whatsapp.net",
        "from_name": "John Doe",
        "timestamp": "2025-07-13T11:05:51Z",
        "body": "Check this out!",
        "image": {
          "path": "statics/media/1752404751-ad9e37ac-c658-4fe5-8d25-ba4a3f4d58fd.jpeg",
          "caption": "Check this out!"
        }
      }
    }
    """#

    // GOWA docs/webhook-payload.md — audio
    static let gowaAudio = #"""
    {
      "event": "message",
      "device_id": "628987654321@s.whatsapp.net",
      "payload": {
        "id": "3EB0C127D7BACC83D6A5",
        "chat_id": "628987654321@s.whatsapp.net",
        "from": "628123456789@s.whatsapp.net",
        "from_name": "John Doe",
        "timestamp": "2023-10-15T10:55:00Z",
        "audio": "statics/media/1752404905-b9393cd1-8546-4df9-8a60-ee3276036aba.ogg"
      }
    }
    """#

    // GOWA docs/webhook-payload.md — delivery receipt
    static let gowaAck = #"""
    {
      "event": "message.ack",
      "device_id": "628123456789@s.whatsapp.net",
      "timestamp": "2025-07-18T22:44:20Z",
      "payload": {
        "ids": [
          "3EB00106E8BE0F407E88EC"
        ],
        "chat_id": "120363402106XXXXX@g.us",
        "from": "6289685XXXXXX@s.whatsapp.net",
        "from_lid": "251556368777322@lid",
        "sender_display_name": "Saved Contact",
        "receipt_type": "delivered",
        "receipt_type_description": "means the message was delivered to the device (but the user might not have noticed)."
      }
    }
    """#

    // GOWA: a group message mentioning the account. The docs print none; built from the
    // fields event_message.go always sets (chat_id @g.us, from = the member, "@<number>" in body).
    static let gowaGroupMention = #"""
    {"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"G1","chat_id":"120363402106000001@g.us","from":"628123456789@s.whatsapp.net","from_name":"John Doe","timestamp":"2025-07-13T11:05:51Z","is_from_me":false,"body":"@628987654321 tu viens ?"}}
    """#

    // OpenWA docs/12-troubleshooting-faq.md — 1:1 text message.received
    static let openwaText = #"""
    {
      "event": "message.received",
      "timestamp": "2026-02-02T10:30:00Z",
      "sessionId": "3f2a9c1e-7b4d-4e8a-9c2f-1d5e6a7b8c9d",
      "idempotencyKey": "msg_3f2a9c1e-7b4d-4e8a-9c2f-1d5e6a7b8c9d_ABC123_DEF456_f1e2d3c4-b5a6-7890-1234-567890abcdef",
      "deliveryId": "dlv_550e8400-e29b-41d4-a716-446655440000",
      "data": {
        "id": "ABC123_DEF456",
        "from": "628123456789@c.us",
        "to": "628987654321@c.us",
        "chatId": "628123456789@c.us",
        "body": "Hello!",
        "type": "text",
        "timestamp": 1706868600,
        "fromMe": false,
        "isGroup": false,
        "kind": "individual"
      }
    }
    """#

    // OpenWA docs/22-n8n-integration.md — minimal message.received (fields left out on purpose)
    static let openwaMinimal = #"""
    {
      "event": "message.received",
      "timestamp": "2024-01-15T10:30:00Z",
      "sessionId": "default",
      "idempotencyKey": "msg_default_3EB0F5A2B4C..._f1e2d3c4-b5a6-7890-1234-567890abcdef",
      "deliveryId": "dlv_0f8c1a2b-3c4d-5e6f-7a8b-9c0d1e2f3a4b",
      "data": {
        "id": "3EB0F5A2B4C...",
        "chatId": "628123456789@c.us",
        "from": "628123456789@c.us",
        "body": "Hello!",
        "type": "text",
        "timestamp": 1705312200
      }
    }
    """#

    // OpenWA: a group voice note with a mention. No full example in the docs; built from
    // whatsapp-engine.interface.ts (author, mentionedIds, type "voice", contact.pushName).
    static let openwaGroupVoice = #"""
    {"event":"message.received","timestamp":"2026-02-02T10:30:00Z","sessionId":"s1","idempotencyKey":"k","deliveryId":"dlv_2","data":{"id":"3EB0VOICE","from":"120363000000000000@g.us","to":"6280000000000@c.us","chatId":"120363000000000000@g.us","author":"6281111111111@c.us","body":"","type":"voice","timestamp":1706868600,"fromMe":false,"isGroup":true,"kind":"group","mentionedIds":["6280000000000@c.us"],"contact":{"pushName":"Budi"},"media":{"mimetype":"audio/ogg; codecs=opus","omitted":true,"sizeBytes":9000}}}
    """#

    static func runGatewayTests() {
        print("\nGOWA webhook (docs/webhook-payload.md)")
        do {
            if case .message(let m) = WAWebhook.parse(kind: .gowa, body: Data(gowaText.utf8)) {
                check("id and chat", m.id == "3EB0C127D7BACC83D6A1" && m.chat == "628987654321@s.whatsapp.net")
                check("the saved contact's name first", m.senderName == "Saved Contact")
                check("text", m.text == "Hello, how are you?" && m.media == .none)
                check("RFC3339 date", m.date == Date(timeIntervalSince1970: 1_697_365_800))
                check("not mine", !m.fromMe)
            } else { check("text parsed", false) }

            if case .message(let m) = WAWebhook.parse(kind: .gowa, body: Data(gowaImage.utf8)) {
                check("image label, caption kept", m.media == .image && m.text == "Check this out!")
                check("is_from_me missing → not mine", !m.fromMe)
            } else { check("image parsed", false) }

            if case .message(let m) = WAWebhook.parse(kind: .gowa, body: Data(gowaAudio.utf8)) {
                check("audio is a voice label, no duration", m.media == .voice(seconds: nil) && m.previewKey == ("whatsapp.media.voice", ""))
            } else { check("audio parsed", false) }

            check("a receipt is ignored", WAWebhook.parse(kind: .gowa, body: Data(gowaAck.utf8)) == .ignored)
            check("not JSON → nil", WAWebhook.parse(kind: .gowa, body: Data("nope".utf8)) == nil)

            if case .message(let m) = WAWebhook.parse(kind: .gowa, body: Data(gowaGroupMention.utf8)) {
                check("a group mention of the account", m.mentionsMe && m.sender == "628123456789@s.whatsapp.net")
                var inbox = WAInbox()
                check("…reaches the pill despite muted groups", inbox.add(m, filters: WAFilters()) == .notify)
            } else { check("group parsed", false) }
        }

        print("\nOpenWA webhook (docs/06, docs/12, docs/22)")
        do {
            if case .message(let m) = WAWebhook.parse(kind: .openwa, body: Data(openwaText.utf8)) {
                check("id and chat", m.id == "ABC123_DEF456" && m.chat == "628123456789@c.us")
                check("epoch seconds", m.date == Date(timeIntervalSince1970: 1_706_868_600))
                check("text", m.text == "Hello!" && !m.fromMe)
                var inbox = WAInbox()
                inbox.add(m, filters: WAFilters())
                check("@c.us folded into the same chat as GOWA's form",
                      inbox.conversations["628123456789@s.whatsapp.net"] != nil)
            } else { check("text parsed", false) }

            check("missing fields tolerated", {
                if case .message(let m) = WAWebhook.parse(kind: .openwa, body: Data(openwaMinimal.utf8)) {
                    return m.id == "3EB0F5A2B4C..." && !m.fromMe
                }
                return false
            }())

            if case .message(let m) = WAWebhook.parse(kind: .openwa, body: Data(openwaGroupVoice.utf8), me: "6280000000000") {
                check("group sender is the author", m.sender == "6281111111111@c.us" && m.senderName == "Budi")
                check("voice label", m.media == .voice(seconds: nil))
                check("mentionedIds name the account", m.mentionsMe)
            } else { check("group parsed", false) }

            let test = #"{"event":"test","data":{"message":"This is a test webhook from OpenWA","webhookId":"w","url":"u"}}"#
            check("the test ping is ignored", WAWebhook.parse(kind: .openwa, body: Data(test.utf8)) == .ignored)
            let sent = openwaText.replacingOccurrences(of: "message.received", with: "message.sent")
                .replacingOccurrences(of: #""fromMe": false"#, with: #""fromMe": true"#)
            if case .message(let m) = WAWebhook.parse(kind: .openwa, body: Data(sent.utf8)) {
                check("message.sent is mine", m.fromMe)
            } else { check("sent parsed", false) }
        }

        print("\nSignatures")
        do {
            // OpenWA sdk/javascript/test/webhook.test.ts: "the gateway's generateSignature produces
            // this header for this body".
            let secret = "test-secret-0123456789"
            let body = Data(#"{"event":"message.received","timestamp":"2026-02-02T10:00:00.000Z","sessionId":"s1","idempotencyKey":"k","deliveryId":"dlv_1","data":{"text":"héllo 👋"}}"#.utf8)
            let header = "sha256=d74a41bb687f31ed4c932f76f524116100ca4120d2cabb7a469ee5d928122f70"
            check("OpenWA's own fixture", WAWebhook.signature(body: body, secret: secret) == header)
            check("verified", WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": header], body: body, secret: secret))
            var flipped = body
            flipped[flipped.startIndex + 3] ^= 1
            check("a flipped byte fails", !WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": header], body: flipped, secret: secret))
            check("the wrong secret fails", !WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": header], body: body, secret: secret + "x"))
            check("no prefix fails", !WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": String(header.dropFirst(7))], body: body, secret: secret))
            check("SHA256= fails", !WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": "SHA256=" + header.dropFirst(7)], body: body, secret: secret))
            check("truncated fails", !WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": String(header.dropLast())], body: body, secret: secret))
            check("missing header fails", !WAWebhook.verify(kind: .openwa, headers: [:], body: body, secret: secret))
            check("empty secret fails", !WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": header], body: body, secret: ""))
            check("GOWA's header is its own", !WAWebhook.verify(kind: .gowa, headers: ["x-openwa-signature": header], body: body, secret: secret))
            // RFC 4231 test case 2 (GOWA prints no fixture; same HMAC-SHA256, hex lowercase).
            check("RFC 4231", WAWebhook.signature(body: Data("what do ya want for nothing?".utf8), secret: "Jefe")
                  == "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
            let long = String(repeating: "k", count: 100)
            let sig = WAWebhook.signature(body: Data("x".utf8), secret: long)
            check("a key longer than a block", sig.count == 71 && WAWebhook.verify(kind: .gowa, headers: ["x-hub-signature-256": sig], body: Data("x".utf8), secret: long))
        }

        print("\nREST answers")
        do {
            let devices = #"{"code":"SUCCESS","message":"List devices","results":[{"id":"coucou","state":"disconnected","created_at":"2024-01-01T00:00:00Z"},{"id":"my-device-id","phone_number":"628123456789","display_name":"John Doe","state":"logged_in","jid":"628123456789@s.whatsapp.net","created_at":"2024-01-01T00:00:00Z"}]}"#
            let d = WAGOWA.device(Data(devices.utf8))
            check("GOWA: the logged-in device", d?.id == "my-device-id" && d?.status == WAStatus(link: .connected, me: "628123456789@s.whatsapp.net"))
            let fresh = #"{"code":"SUCCESS","message":"List devices","results":[{"id":"coucou","state":"disconnected","created_at":"2024-01-01T00:00:00Z"}]}"#
            check("GOWA: never logged in → QR", WAGOWA.device(Data(fresh.utf8))?.status.link == .needsQR)
            check("GOWA: no device", WAGOWA.device(Data(#"{"code":"SUCCESS","message":"x","results":[]}"#.utf8)) == nil)
            let login = #"{"code":"SUCCESS","message":"Success","results":{"device_id":"coucou","qr_duration":30,"qr_link":"http://localhost:3000/statics/qrcode/scan-qr-b0b7bb43-9a22-455a-814f-5a225c743310.png"}}"#
            let qr = WAGOWA.qrPath(Data(login.utf8))
            check("GOWA: QR path only, fetched from the gateway", qr?.path == "/statics/qrcode/scan-qr-b0b7bb43-9a22-455a-814f-5a225c743310.png" && qr?.seconds == 30)
            check("GOWA launched on this Mac only, no media download",
                  WAGOWA.launchArguments(for: URL(string: "http://127.0.0.1:3001")!)
                  == ["rest", "--host=127.0.0.1", "--port=3001", "--auto-download-media=false"])
            check("GOWA: error code", WAGOWA.errorCode(Data(#"{"code":"ALREADY_LOGGED_IN","message":"you are already logged in."}"#.utf8)) == "ALREADY_LOGGED_IN")

            let msgs = #"{"code":"SUCCESS","message":"ok","results":{"data":[{"id":"M2","chat_jid":"120363402106000001@g.us","sender_jid":"628123456789@s.whatsapp.net","sender_display_name":"John","content":"","timestamp":"2025-07-13T11:06:00Z","is_from_me":false,"media_type":"document","filename":"devis.pdf"},{"id":"M1","chat_jid":"120363402106000001@g.us","sender_jid":"628987654321@s.whatsapp.net","content":"salut","timestamp":"2025-07-13T11:05:00Z","is_from_me":true,"media_type":""}],"pagination":{"limit":10,"offset":0,"total":2},"chat_info":{"jid":"120363402106000001@g.us","name":"Famille","last_message_time":"2025-07-13T11:06:00Z"}}}"#
            let list = WAGOWA.messages(Data(msgs.utf8), me: nil)
            check("GOWA stored messages", list.count == 2 && list[0].media == .document(name: "devis.pdf") && list[1].fromMe)
            check("GOWA group name from chat_info", list[0].chatName == "Famille")
            let chats = #"{"code":"SUCCESS","message":"ok","results":{"data":[{"jid":"628123456789@s.whatsapp.net","name":"John","last_message_time":"2025-07-13T11:06:00Z","archived":false}],"pagination":{"limit":25,"offset":0,"total":1}}}"#
            check("GOWA chats", WAGOWA.chats(Data(chats.utf8)).first?.name == "John")

            let session = #"[{"id":"0b5d6c3e-1111-4a2b-9c3d-123456789abc","name":"coucou","status":"ready","phone":"628123456789","pushName":"Me"}]"#
            let s = WAOpenWA.firstSession(Data(session.utf8))
            check("OpenWA session", s?.id == "0b5d6c3e-1111-4a2b-9c3d-123456789abc" && s.map(WAOpenWA.status) == WAStatus(link: .connected, me: "628123456789"))
            check("OpenWA QR state", WAOpenWA.status((id: "x", status: "qr_ready", phone: nil)).link == .needsQR)
            check("OpenWA start when stopped", WAOpenWA.needsStart("created") && !WAOpenWA.needsStart("qr_ready"))
            let png = Data([0x89, 0x50, 0x4E, 0x47])
            let qrBody = #"{"qrCode":"data:image/png;base64,\#(png.base64EncodedString())","status":"qr_ready"}"#
            check("OpenWA QR data URL", WAOpenWA.qrPNG(Data(qrBody.utf8)) == png)
            let stored = #"{"messages":[{"id":"9f0c","sessionId":"s","waMessageId":"3EB0AB","chatId":"628123456789@c.us","from":"628123456789@c.us","to":"6280@c.us","chatName":"Alice","author":null,"body":"See you","type":"text","direction":"incoming","timestamp":1719306115,"metadata":null,"status":"delivered","createdAt":"2024-06-25T09:01:55Z"}],"total":1}"#
            let om = WAOpenWA.messages(Data(stored.utf8), me: nil)
            check("OpenWA stored messages", om.first?.id == "3EB0AB" && om.first?.chatName == "Alice" && om.first?.fromMe == false)
            let oc = #"[{"id":"6281234567890@c.us","name":"Alice","isGroup":false,"kind":"individual","unreadCount":2,"timestamp":1719306115,"lastMessage":"See you tomorrow","lastMessageType":"text","archived":false,"pinned":false,"muted":false}]"#
            check("OpenWA chats", WAOpenWA.chats(Data(oc.utf8)).first?.unread == 2)
            check("OpenWA error, string or list", WAOpenWA.errorMessage(Data(#"{"statusCode":400,"message":["a","b"],"error":"Bad Request"}"#.utf8)) == "a, b")
        }

        print("\nGOWA's GitHub release (Install WhatsApp)")
        do {
            // Shape of GET /repos/aldinokemal/go-whatsapp-web-multidevice/releases/latest, asset names
            // as GOWA's GoReleaser workflow writes them.
            let json = #"{"tag_name":"v9.6.0","assets":[{"name":"checksums-macos.txt","size":228,"browser_download_url":"https://github.com/aldinokemal/go-whatsapp-web-multidevice/releases/download/v9.6.0/checksums-macos.txt"},{"name":"whatsapp_9.6.0_darwin_amd64.zip","size":13900000,"browser_download_url":"https://github.com/aldinokemal/go-whatsapp-web-multidevice/releases/download/v9.6.0/whatsapp_9.6.0_darwin_amd64.zip"},{"name":"whatsapp_9.6.0_darwin_arm64.zip","size":13100000,"digest":"sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","browser_download_url":"https://github.com/aldinokemal/go-whatsapp-web-multidevice/releases/download/v9.6.0/whatsapp_9.6.0_darwin_arm64.zip"},{"name":"whatsapp_9.6.0_linux_arm64.zip","size":1,"browser_download_url":"https://github.com/x"}]}"#
            let r = WAGOWARelease.parse(Data(json.utf8))
            check("version without the v", r?.version == "9.6.0")
            let arm = r.flatMap { WAGOWARelease.pick($0.assets, arch: "arm64") }
            check("the Apple silicon zip", arm?.zip.name == "whatsapp_9.6.0_darwin_arm64.zip" && arm?.checksums?.name == "checksums-macos.txt")
            check("the Intel zip", r.flatMap { WAGOWARelease.pick($0.assets, arch: "amd64") }?.zip.name == "whatsapp_9.6.0_darwin_amd64.zip")
            check("never a Linux one", r.flatMap { WAGOWARelease.pick($0.assets.filter { !$0.name.contains("darwin") }, arch: "arm64") } == nil)
            let sums = "1111111111111111111111111111111111111111111111111111111111111111  whatsapp_9.6.0_darwin_amd64.zip\n2222222222222222222222222222222222222222222222222222222222222222  whatsapp_9.6.0_darwin_arm64.zip\n"
            check("checksum from GOWA's file", arm.flatMap { WAGOWARelease.expectedSHA256(for: $0.zip, checksums: sums) } == String(repeating: "2", count: 64))
            check("else GitHub's digest", arm.flatMap { WAGOWARelease.expectedSHA256(for: $0.zip, checksums: nil) } == String(repeating: "a", count: 64))
            check("no checksum at all → nil", WAGOWARelease.expectedSHA256(for: .init(name: "x.zip", url: URL(string: "https://github.com")!, size: 1, digest: nil), checksums: sums) == nil)
            check("binary name", WAGOWARelease.binaryName(arch: "arm64") == "darwin-arm64")
            check("GitHub hosts only", WAGOWARelease.allowedHost("objects.githubusercontent.com") && WAGOWARelease.allowedHost("github.com")
                  && !WAGOWARelease.allowedHost("github.com.evil.io") && !WAGOWARelease.allowedHost(nil))
        }

        print("\nMentions and ids")
        do {
            check("same user across forms", WAJID.sameUser("628@c.us", "628:4@s.whatsapp.net") && !WAJID.sameUser("1@c.us", "2@c.us"))
            check("a mention needs the whole number", WAMention.textMentions("hey @33612345678!", me: "33612345678@s.whatsapp.net")
                  && !WAMention.textMentions("hey @336", me: "33612345678@s.whatsapp.net"))
            var inbox = WAInbox()
            inbox.add(WAMessage(id: "o1", chat: "33600000003@s.whatsapp.net", sender: "me", senderName: "Louis", text: "yo",
                                date: Date(), fromMe: true), filters: WAFilters())
            check("my own first message doesn't name the chat after me",
                  inbox.conversations["33600000003@s.whatsapp.net"]?.name == "+33600000003")
            inbox.add(WAMessage(id: "o2", chat: "33600000003@s.whatsapp.net", sender: "x", senderName: "Marie", text: "yo",
                                date: Date()), filters: WAFilters())
            check("…their reply does", inbox.conversations["33600000003@s.whatsapp.net"]?.name == "Marie")
            let before = inbox.conversations["33600000003@s.whatsapp.net"]?.unread
            check("history loaded on opening is quiet and unread untouched",
                  inbox.add(WAMessage(id: "h1", chat: "33600000003@s.whatsapp.net", sender: "x", senderName: "Marie", text: "old",
                                      date: Date(timeIntervalSinceNow: -3600)), filters: WAFilters(), history: true) == .quiet
                  && inbox.conversations["33600000003@s.whatsapp.net"]?.unread == before
                  && inbox.conversations["33600000003@s.whatsapp.net"]?.messages.first?.id == "h1")
        }
    }
}
