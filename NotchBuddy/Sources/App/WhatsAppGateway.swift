import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// What the two local WhatsApp gateways send and answer, turned into WAMessage. Pure Foundation
// so tests/WhatsAppTests.swift checks it against the payloads printed in each gateway's docs.
// Every field name here comes from those docs and their source code:
//   GOWA   — github.com/aldinokemal/go-whatsapp-web-multidevice (docs/webhook-payload.md, docs/openapi.yaml)
//   OpenWA — github.com/rmyndharis/OpenWA (docs/06-api-specification.md)
// Nothing parsed here is logged or written anywhere.

enum WAGatewayKind: String, CaseIterable, Sendable {
    case gowa, openwa

    var name: String { self == .gowa ? "GOWA" : "OpenWA" }
    var defaultURL: String { self == .gowa ? "http://127.0.0.1:3000" : "http://127.0.0.1:2785" }
    /// The header carrying the webhook's HMAC-SHA256 ("sha256=<hex>"), lowercased.
    var signatureHeader: String { self == .gowa ? "x-hub-signature-256" : "x-openwa-signature" }
}

/// What one webhook delivery holds for Coucou.
enum WAWebhookEvent: Equatable, Sendable {
    case message(WAMessage)
    /// A valid delivery Coucou has no use for (receipts, reactions, a test ping…).
    case ignored
}

enum WAWebhook {
    /// "sha256=<lowercase hex>" of HMAC-SHA256(secret, body): what both gateways send.
    static func signature(body: Data, secret: String) -> String {
        "sha256=" + waHMACSHA256(key: Data(secret.utf8), message: body).waHex
    }

    /// True when the delivery carries the signature `secret` gives, over the raw body bytes.
    static func verify(kind: WAGatewayKind, headers: [String: String], body: Data, secret: String) -> Bool {
        guard !secret.isEmpty, let sent = headers[kind.signatureHeader], sent.hasPrefix("sha256=") else { return false }
        return waConstantTimeEqual(sent, signature(body: body, secret: secret))
    }

    /// Parses one delivery. nil when it isn't JSON at all. `me` is this account's JID or number,
    /// to tell a mention of you (GOWA also gives it in the delivery itself).
    static func parse(kind: WAGatewayKind, body: Data, me: String? = nil) -> WAWebhookEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        switch kind {
        case .gowa:   return parseGOWA(json, me: me)
        case .openwa: return parseOpenWA(json, me: me)
        }
    }

    // MARK: GOWA

    /// `{"event":"message","device_id":"<own JID>","payload":{id, chat_id, from, from_name,
    /// sender_display_name, timestamp (RFC3339), is_from_me, body, image|video|audio|document|…}}`
    private static func parseGOWA(_ json: [String: Any], me: String?) -> WAWebhookEvent {
        guard json["event"] as? String == "message",
              let p = json["payload"] as? [String: Any],
              let id = p["id"] as? String, !id.isEmpty,
              let chat = p["chat_id"] as? String, !chat.isEmpty else { return .ignored }
        let from = (p["from"] as? String) ?? chat
        let text = (p["body"] as? String) ?? ""
        let mine = me ?? (json["device_id"] as? String)
        var message = WAMessage(
            id: id, chat: chat, sender: from,
            senderName: nonEmpty(p["sender_display_name"]) ?? nonEmpty(p["from_name"]) ?? "",
            text: text, media: gowaMedia(p),
            date: WADate.rfc3339(p["timestamp"] as? String) ?? Date(),
            fromMe: p["is_from_me"] as? Bool ?? false)
        message.mentionsMe = WAJID.isGroup(chat) && WAMention.textMentions(text, me: mine)
        return .message(message)
    }

    /// GOWA puts each media under its own key; only the label matters to Coucou.
    static func gowaMedia(_ p: [String: Any]) -> WAMedia {
        if p["image"] != nil { return .image }
        if p["video"] != nil || p["video_note"] != nil { return .video }
        if p["audio"] != nil { return .voice(seconds: nil) }
        if let doc = p["document"] {
            return .document(name: (doc as? [String: Any]).flatMap { nonEmpty($0["filename"]) })
        }
        if p["sticker"] != nil { return .sticker }
        if p["location"] != nil || p["live_location"] != nil { return .location }
        if p["contact"] != nil || p["contacts_array"] != nil { return .contact }
        if p["poll"] != nil { return .other }
        return .none
    }

    // MARK: OpenWA

    /// `{"event":"message.received"|"message.sent","sessionId","data":{id, from, to, chatId, author,
    /// body, type, timestamp (epoch s), fromMe, isGroup, mentionedIds, contact{name, pushName}, media{filename}}}`
    private static func parseOpenWA(_ json: [String: Any], me: String?) -> WAWebhookEvent {
        let event = json["event"] as? String
        guard event == "message.received" || event == "message.sent",
              let d = json["data"] as? [String: Any],
              let id = d["id"] as? String, !id.isEmpty,
              let chat = (d["chatId"] as? String) ?? (d["from"] as? String), !chat.isEmpty else { return .ignored }
        let type = (d["type"] as? String) ?? "text"
        guard type != "revoked" else { return .ignored }
        let fromMe = (d["fromMe"] as? Bool) ?? (event == "message.sent")
        let contact = d["contact"] as? [String: Any]
        let media = d["media"] as? [String: Any]
        var message = WAMessage(
            id: id, chat: chat,
            sender: nonEmpty(d["author"]) ?? (d["from"] as? String) ?? chat,
            senderName: nonEmpty(contact?["name"]) ?? nonEmpty(contact?["pushName"]) ?? "",
            text: (d["body"] as? String) ?? "",
            media: openwaMedia(type, filename: nonEmpty(media?["filename"])),
            date: WADate.epoch(d["timestamp"]) ?? Date(),
            fromMe: fromMe)
        let isGroup = (d["isGroup"] as? Bool) ?? WAJID.isGroup(chat)
        if isGroup, let mine = me {
            let ids = (d["mentionedIds"] as? [String]) ?? []
            message.mentionsMe = ids.contains { WAJID.sameUser($0, mine) } || WAMention.textMentions(message.text, me: mine)
        }
        return .message(message)
    }

    /// OpenWA's `type` (text|image|video|audio|voice|document|sticker|location|contact|poll|…).
    static func openwaMedia(_ type: String, filename: String? = nil) -> WAMedia {
        switch type {
        case "text", "":  return .none
        case "image":     return .image
        case "video":     return .video
        case "audio":     return .audio(seconds: nil)
        case "voice":     return .voice(seconds: nil)
        case "document":  return .document(name: filename)
        case "sticker":   return .sticker
        case "location":  return .location
        case "contact":   return .contact
        default:          return .other
        }
    }
}

// MARK: - REST answers (status, QR, polling)

/// What a gateway says of the WhatsApp link.
struct WAStatus: Equatable, Sendable {
    enum Link: Equatable, Sendable {
        /// Logged in and online.
        case connected
        /// Waiting for the QR to be scanned.
        case needsQR
        /// Logged in but offline, starting, or anything in between.
        case connecting
    }
    var link: Link
    /// This account's JID or number, once logged in.
    var me: String?
}

enum WAGOWA {
    /// GOWA's envelope: `{code, message, results}` (no "status": the HTTP code says it).
    static func results(_ data: Data) -> Any? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["results"]
    }

    /// `GET /devices` → `results: [{id, phone_number, display_name, state, jid, created_at}]`.
    /// The device Coucou uses: a logged-in one first, else the first one.
    static func device(_ data: Data) -> (id: String, status: WAStatus)? {
        guard let list = results(data) as? [[String: Any]], !list.isEmpty else { return nil }
        let pick = list.first { $0["state"] as? String == "logged_in" } ?? list[0]
        guard let id = pick["id"] as? String, !id.isEmpty else { return nil }
        let jid = nonEmpty(pick["jid"])
        let link: WAStatus.Link
        switch pick["state"] as? String {
        case "logged_in": link = .connected
        case "connecting", "connected": link = jid == nil ? .needsQR : .connecting
        default: link = jid == nil ? .needsQR : .connecting
        }
        return (id, WAStatus(link: link, me: jid))
    }

    /// `GET /devices/{id}/login` → `results: {device_id, qr_link, qr_duration}`. The PNG's path,
    /// to fetch from the gateway itself (never from another host the link may name).
    static func qrPath(_ data: Data) -> (path: String, seconds: Int)? {
        guard let r = results(data) as? [String: Any], let link = r["qr_link"] as? String,
              let url = URL(string: link), !url.path.isEmpty else { return nil }
        return (url.path, (r["qr_duration"] as? Int) ?? 30)
    }

    /// `./whatsapp rest` for Coucou's "Start GOWA automatically": on this Mac only, on the
    /// URL's port, and media never downloaded (Coucou shows a label), so GOWA keeps no photo
    /// or voice note on disk.
    static func launchArguments(for url: URL) -> [String] {
        ["rest", "--host=127.0.0.1", "--port=\(url.port ?? 3000)", "--auto-download-media=false"]
    }

    /// The error code of a refused call (`ALREADY_LOGGED_IN`, `DEVICE_ID_REQUIRED`…).
    static func errorCode(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["code"] as? String
    }

    /// `GET /chats` → `results: {data: [{jid, name, last_message_time, …}], pagination}`.
    static func chats(_ data: Data) -> [(jid: String, name: String, last: Date)] {
        guard let r = results(data) as? [String: Any], let list = r["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let jid = c["jid"] as? String, !jid.isEmpty else { return nil }
            return (jid, (c["name"] as? String) ?? "", WADate.rfc3339(c["last_message_time"] as? String) ?? .distantPast)
        }
    }

    /// `GET /chat/{jid}/messages` → `results: {data: [{id, chat_jid, sender_jid, sender_display_name,
    /// content, timestamp, is_from_me, media_type, filename}], chat_info}`. Newest first there.
    static func messages(_ data: Data, me: String?) -> [WAMessage] {
        guard let r = results(data) as? [String: Any], let list = r["data"] as? [[String: Any]] else { return [] }
        let chatName = nonEmpty((r["chat_info"] as? [String: Any])?["name"])
        return list.compactMap { m in
            guard let id = m["id"] as? String, let chat = m["chat_jid"] as? String else { return nil }
            let text = (m["content"] as? String) ?? ""
            var msg = WAMessage(
                id: id, chat: chat, sender: (m["sender_jid"] as? String) ?? chat,
                senderName: nonEmpty(m["sender_display_name"]) ?? "",
                text: text, media: gowaStoredMedia(m["media_type"] as? String, filename: nonEmpty(m["filename"])),
                date: WADate.rfc3339(m["timestamp"] as? String) ?? .distantPast,
                fromMe: m["is_from_me"] as? Bool ?? false)
            msg.chatName = WAJID.isGroup(chat) ? chatName : nil
            msg.mentionsMe = WAJID.isGroup(chat) && WAMention.textMentions(text, me: me)
            return msg
        }
    }

    /// `media_type` of a stored message: image|video|video_note|audio|document|sticker|call or "".
    static func gowaStoredMedia(_ type: String?, filename: String?) -> WAMedia {
        switch type ?? "" {
        case "":                    return .none
        case "image":               return .image
        case "video", "video_note": return .video
        case "audio":               return .voice(seconds: nil)
        case "document":            return .document(name: filename)
        case "sticker":             return .sticker
        default:                    return .other
        }
    }
}

/// GOWA's own releases on GitHub, for "Install WhatsApp" (one click, no Terminal): which zip
/// fits this Mac and the SHA-256 GOWA publishes for it. The release workflow (GoReleaser,
/// .github/workflows/release.yml in GOWA's repo) names them `whatsapp_<version>_darwin_<arch>.zip`
/// (the binary inside is `darwin-<arch>`) next to `checksums-macos.txt`.
enum WAGOWARelease {
    static let latestURL = URL(string: "https://api.github.com/repos/aldinokemal/go-whatsapp-web-multidevice/releases/latest")!

    struct Asset: Equatable, Sendable {
        let name: String
        let url: URL
        let size: Int
        /// "sha256:<hex>" when GitHub gives it.
        let digest: String?
    }

    /// `GET /releases/latest` → `{tag_name, assets: [{name, browser_download_url, size, digest?}]}`.
    static func parse(_ data: Data) -> (version: String, assets: [Asset])? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String, let list = obj["assets"] as? [[String: Any]] else { return nil }
        let assets: [Asset] = list.compactMap { a in
            guard let name = a["name"] as? String, let s = a["browser_download_url"] as? String,
                  let url = URL(string: s) else { return nil }
            return Asset(name: name, url: url, size: (a["size"] as? Int) ?? 0, digest: a["digest"] as? String)
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return (version, assets)
    }

    /// The zip for this Mac ("arm64" or "amd64") and the macOS checksums file.
    static func pick(_ assets: [Asset], arch: String) -> (zip: Asset, checksums: Asset?)? {
        guard let zip = assets.first(where: { $0.name.hasPrefix("whatsapp_") && $0.name.hasSuffix("_darwin_\(arch).zip") }) else { return nil }
        return (zip, assets.first { $0.name == "checksums-macos.txt" })
    }

    /// The binary's name inside the zip.
    static func binaryName(arch: String) -> String { "darwin-\(arch)" }

    /// The SHA-256 (lowercase hex) of `name` in a GoReleaser checksums file ("<hex>  <name>" per line),
    /// else from GitHub's own "sha256:<hex>" digest.
    static func expectedSHA256(for asset: Asset, checksums: String?) -> String? {
        for line in (checksums ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == Substring(asset.name), parts[0].count == 64 { return parts[0].lowercased() }
        }
        if let d = asset.digest, d.hasPrefix("sha256:"), d.count == 71 { return String(d.dropFirst(7)).lowercased() }
        return nil
    }

    /// Only GitHub serves the download (its assets redirect to githubusercontent.com).
    static func allowedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com" || h.hasSuffix(".githubusercontent.com")
    }
}

enum WAOpenWA {
    /// A session: `{id (uuid), name, status, phone, pushName, …}`.
    /// status: created|initializing|qr_ready|authenticating|ready|disconnected|action_required|failed.
    static func session(_ obj: Any?) -> (id: String, status: String, phone: String?)? {
        guard let s = obj as? [String: Any], let id = s["id"] as? String, !id.isEmpty else { return nil }
        return (id, (s["status"] as? String) ?? "", nonEmpty(s["phone"]))
    }

    /// `GET /api/sessions?name=…` → a bare array of sessions.
    static func firstSession(_ data: Data) -> (id: String, status: String, phone: String?)? {
        let json = try? JSONSerialization.jsonObject(with: data)
        if let list = json as? [Any] { return list.lazy.compactMap(session).first }
        return session(json)
    }

    static func status(_ s: (id: String, status: String, phone: String?)) -> WAStatus {
        switch s.status {
        case "ready":                 return WAStatus(link: .connected, me: s.phone)
        case "qr_ready":              return WAStatus(link: .needsQR, me: nil)
        default:                      return WAStatus(link: .connecting, me: s.phone)
        }
    }

    /// Sessions that must be started before a QR can come: never started, stopped or failed.
    static func needsStart(_ status: String) -> Bool {
        ["created", "disconnected", "failed"].contains(status)
    }

    /// `GET /api/sessions/{id}/qr` → `{qrCode: "data:image/png;base64,…", status}`: the PNG bytes.
    static func qrPNG(_ data: Data) -> Data? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = obj["qrCode"] as? String,
              let comma = url.firstIndex(of: ","), url.hasPrefix("data:image/png;base64") else { return nil }
        return Data(base64Encoded: String(url[url.index(after: comma)...]))
    }

    /// `GET /api/sessions/{id}/chats` → bare `[{id, name, isGroup, unreadCount, timestamp, …}]`.
    static func chats(_ data: Data) -> [(jid: String, name: String, unread: Int, last: Date)] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { c in
            guard let id = c["id"] as? String, !id.isEmpty else { return nil }
            return (id, (c["name"] as? String) ?? "", (c["unreadCount"] as? Int) ?? 0, WADate.epoch(c["timestamp"]) ?? .distantPast)
        }
    }

    /// `GET /api/sessions/{id}/messages` → `{messages: [{waMessageId, chatId, from, author, chatName,
    /// body, type, direction, timestamp (s), metadata}], total}`.
    static func messages(_ data: Data, me: String?) -> [WAMessage] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["messages"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = nonEmpty(m["waMessageId"]) ?? nonEmpty(m["id"]),
                  let chat = m["chatId"] as? String, !chat.isEmpty else { return nil }
            let type = (m["type"] as? String) ?? "text"
            guard type != "revoked" else { return nil }
            let media = (m["metadata"] as? [String: Any])?["media"] as? [String: Any]
            var msg = WAMessage(
                id: id, chat: chat, sender: nonEmpty(m["author"]) ?? (m["from"] as? String) ?? chat,
                senderName: "", text: (m["body"] as? String) ?? "",
                media: WAWebhook.openwaMedia(type, filename: nonEmpty(media?["filename"])),
                date: WADate.epoch(m["timestamp"]) ?? .distantPast,
                fromMe: m["direction"] as? String == "outgoing")
            msg.chatName = nonEmpty(m["chatName"])
            if WAJID.isGroup(chat), let me { msg.mentionsMe = WAMention.textMentions(msg.text, me: me) }
            return msg
        }
    }

    /// NestJS error: `{statusCode, message (string or [string]), error}`.
    static func errorMessage(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let s = obj["message"] as? String { return s }
        return (obj["message"] as? [String])?.joined(separator: ", ")
    }
}

// MARK: - Helpers

enum WAMention {
    /// "@33612345678" in the text, for this account's number (how GOWA shows a mention of you).
    static func textMentions(_ text: String, me: String?) -> Bool {
        guard let me, case let digits = WAJID.digits(me), digits.count >= 6 else { return false }
        return text.contains("@" + digits)
    }
}

extension WAJID {
    /// The user part's digits: "33612345678:3@s.whatsapp.net" → "33612345678".
    static func digits(_ jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        let base = user.split(separator: ":").first.map(String.init) ?? user
        return base.filter(\.isNumber)
    }

    /// Two ids of the same person, whatever their server part (@c.us, @s.whatsapp.net, a bare number).
    static func sameUser(_ a: String, _ b: String) -> Bool {
        let x = digits(a), y = digits(b)
        return !x.isEmpty && x == y
    }
}

enum WADate {
    static func rfc3339(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// Epoch seconds, as a number or a numeric string.
    static func epoch(_ v: Any?) -> Date? {
        if let n = v as? Double, n > 0 { return Date(timeIntervalSince1970: n) }
        if let n = v as? Int, n > 0 { return Date(timeIntervalSince1970: TimeInterval(n)) }
        if let s = v as? String, let n = Double(s), n > 0 { return Date(timeIntervalSince1970: n) }
        return nil
    }
}

private func nonEmpty(_ v: Any?) -> String? {
    guard let s = v as? String, !s.isEmpty else { return nil }
    return s
}

// MARK: - HMAC-SHA256

/// HMAC-SHA256 (RFC 2104). CryptoKit on Apple platforms; a plain SHA-256 elsewhere, so the
/// tests run the same checks on Linux.
func waHMACSHA256(key: Data, message: Data) -> Data {
    #if canImport(CryptoKit)
    return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    #else
    var k = key.count > 64 ? waSHA256(key) : key
    k.append(contentsOf: [UInt8](repeating: 0, count: 64 - k.count))
    let inner = Data(k.map { $0 ^ 0x36 }) + message
    return waSHA256(Data(k.map { $0 ^ 0x5c }) + waSHA256(inner))
    #endif
}

#if !canImport(CryptoKit)
/// SHA-256 (FIPS 180-4), only where CryptoKit is missing.
func waSHA256(_ data: Data) -> Data {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var bytes = [UInt8](data)
    let bitLength = UInt64(bytes.count) * 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    for i in (0..<8).reversed() { bytes.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    var w = [UInt32](repeating: 0, count: 64)
    for chunk in stride(from: 0, to: bytes.count, by: 64) {
        for i in 0..<16 {
            let j = chunk + i * 4
            w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
        for i in 0..<64 {
            let t1 = hh &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ k[i] &+ w[i]
            let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
            (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
    var out = Data()
    for v in h { out.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
    return out
}
#endif
