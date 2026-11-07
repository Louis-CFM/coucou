// What the two local WhatsApp gateways send and answer, turned into Messages.
// Port of WhatsAppGateway.swift; pure Rust, checked below against the payloads
// printed in each gateway's docs (the Mac's tests/WhatsAppGatewayTests.swift):
//   GOWA   — github.com/aldinokemal/go-whatsapp-web-multidevice
//   OpenWA — github.com/rmyndharis/OpenWA
// Nothing parsed here is logged or written anywhere.

use serde_json::Value;

use super::models::{hex, is_group, same_user, text_mentions, Media, Message};

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    #[default]
    Gowa,
    Openwa,
}

impl Kind {
    pub fn default_url(self) -> &'static str {
        match self {
            Kind::Gowa => "http://127.0.0.1:3000",
            Kind::Openwa => "http://127.0.0.1:2785",
        }
    }

    /// The header carrying the webhook's HMAC-SHA256 ("sha256=<hex>"), lowercased.
    pub fn signature_header(self) -> &'static str {
        match self {
            Kind::Gowa => "x-hub-signature-256",
            Kind::Openwa => "x-openwa-signature",
        }
    }
}

fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

// ── Dates ─────────────────────────────────────────────────────────────────────

/// Days from 1970-01-01 to a civil date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// "2023-10-15T10:30:00Z", with fractions and an offset → Unix seconds.
pub fn rfc3339(s: &str) -> Option<f64> {
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || !(b[10] == b'T' || b[10] == b't' || b[10] == b' ') {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (h, mi, se) = (num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    let mut i = 19;
    let mut frac = 0.0;
    if b.get(i) == Some(&b'.') {
        let start = i + 1;
        i = start;
        while b.get(i).is_some_and(u8::is_ascii_digit) {
            i += 1;
        }
        frac = format!("0.{}", s.get(start..i)?).parse().ok()?;
    }
    let offset = match b.get(i)? {
        b'Z' | b'z' => 0,
        b'+' | b'-' => {
            let sign = if b[i] == b'-' { -1 } else { 1 };
            sign * (num(i + 1..i + 3)? * 3600 + num(i + 4..i + 6)? * 60)
        }
        _ => return None,
    };
    let secs = days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + se - offset;
    Some(secs as f64 + frac)
}

/// Epoch seconds, as a number or a numeric string.
pub fn epoch(v: Option<&Value>) -> Option<f64> {
    let n = match v? {
        Value::Number(n) => n.as_f64()?,
        Value::String(s) => s.parse().ok()?,
        _ => return None,
    };
    (n > 0.0).then_some(n)
}

// ── Webhook ───────────────────────────────────────────────────────────────────

/// What one webhook delivery holds for Coucou.
#[derive(Debug, PartialEq)]
pub enum Event {
    Message(Box<Message>),
    /// A valid delivery Coucou has no use for (receipts, reactions, a test ping…).
    Ignored,
}

/// "sha256=<lowercase hex>" of HMAC-SHA256(secret, body): what both gateways send.
pub fn signature(body: &[u8], secret: &str) -> String {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, secret.as_bytes());
    format!("sha256={}", hex(ring::hmac::sign(&key, body).as_ref()))
}

/// True when the delivery carries the signature `secret` gives, over the raw body bytes.
pub fn verify(kind: Kind, headers: &std::collections::HashMap<String, String>, body: &[u8], secret: &str) -> bool {
    let Some(sent) = headers.get(kind.signature_header()) else { return false };
    !secret.is_empty() && sent.starts_with("sha256=") && super::models::constant_time_eq(sent, &signature(body, secret))
}

/// Parses one delivery. None when it isn't JSON at all. `me` is this account's
/// JID or number, to tell a mention of you.
pub fn parse_webhook(kind: Kind, body: &[u8], me: Option<&str>) -> Option<Event> {
    let json: Value = serde_json::from_slice(body).ok()?;
    if !json.is_object() {
        return None;
    }
    Some(match kind {
        Kind::Gowa => parse_gowa(&json, me),
        Kind::Openwa => parse_openwa(&json, me),
    })
}

/// `{"event":"message","device_id":…,"payload":{id, chat_id, from, from_name,
/// sender_display_name, timestamp (RFC3339), is_from_me, body, image|video|…}}`
fn parse_gowa(json: &Value, me: Option<&str>) -> Event {
    if json.get("event").and_then(Value::as_str) != Some("message") {
        return Event::Ignored;
    }
    let Some(p) = json.get("payload") else { return Event::Ignored };
    let (Some(id), Some(chat)) = (str_of(p, "id"), str_of(p, "chat_id")) else { return Event::Ignored };
    let from = str_of(p, "from").unwrap_or(chat);
    let text = p.get("body").and_then(Value::as_str).unwrap_or("");
    let mine = me.or_else(|| str_of(json, "device_id"));
    let name = str_of(p, "sender_display_name").or_else(|| str_of(p, "from_name")).unwrap_or("");
    let date = str_of(p, "timestamp").and_then(rfc3339).unwrap_or_else(now);
    let mut m = Message::new(id, chat, from, name, text, date);
    m.media = gowa_media(p);
    m.from_me = p.get("is_from_me").and_then(Value::as_bool).unwrap_or(false);
    m.mentions_me = is_group(chat) && text_mentions(text, mine);
    Event::Message(Box::new(m))
}

/// GOWA puts each media under its own key; only the label matters to Coucou.
fn gowa_media(p: &Value) -> Media {
    let has = |k: &str| p.get(k).is_some_and(|v| !v.is_null());
    if has("image") {
        Media::Image
    } else if has("video") || has("video_note") {
        Media::Video
    } else if has("audio") {
        Media::Voice { seconds: None }
    } else if has("document") {
        Media::Document { name: p.get("document").and_then(|d| str_of(d, "filename")).map(String::from) }
    } else if has("sticker") {
        Media::Sticker
    } else if has("location") || has("live_location") {
        Media::Location
    } else if has("contact") || has("contacts_array") {
        Media::Contact
    } else if has("poll") {
        Media::Other
    } else {
        Media::None
    }
}

/// `{"event":"message.received"|"message.sent","data":{id, from, chatId, author,
/// body, type, timestamp (epoch s), fromMe, isGroup, mentionedIds, contact, media}}`
fn parse_openwa(json: &Value, me: Option<&str>) -> Event {
    let event = json.get("event").and_then(Value::as_str);
    if !matches!(event, Some("message.received") | Some("message.sent")) {
        return Event::Ignored;
    }
    let Some(d) = json.get("data") else { return Event::Ignored };
    let Some(id) = str_of(d, "id") else { return Event::Ignored };
    let Some(chat) = str_of(d, "chatId").or_else(|| str_of(d, "from")) else { return Event::Ignored };
    let kind = d.get("type").and_then(Value::as_str).unwrap_or("text");
    if kind == "revoked" {
        return Event::Ignored;
    }
    let contact = d.get("contact");
    let name = contact.and_then(|c| str_of(c, "name").or_else(|| str_of(c, "pushName"))).unwrap_or("");
    let sender = str_of(d, "author").or_else(|| str_of(d, "from")).unwrap_or(chat);
    let text = d.get("body").and_then(Value::as_str).unwrap_or("");
    let date = epoch(d.get("timestamp")).unwrap_or_else(now);
    let mut m = Message::new(id, chat, sender, name, text, date);
    m.media = openwa_media(kind, d.get("media").and_then(|x| str_of(x, "filename")));
    m.from_me = d.get("fromMe").and_then(Value::as_bool).unwrap_or(event == Some("message.sent"));
    let group = d.get("isGroup").and_then(Value::as_bool).unwrap_or_else(|| is_group(chat));
    if group {
        if let Some(mine) = me {
            let mentioned = d
                .get("mentionedIds")
                .and_then(Value::as_array)
                .is_some_and(|ids| ids.iter().filter_map(Value::as_str).any(|i| same_user(i, mine)));
            m.mentions_me = mentioned || text_mentions(text, Some(mine));
        }
    }
    Event::Message(Box::new(m))
}

/// OpenWA's `type` (text|image|video|audio|voice|document|sticker|location|contact|poll|…).
fn openwa_media(kind: &str, filename: Option<&str>) -> Media {
    match kind {
        "text" | "" => Media::None,
        "image" => Media::Image,
        "video" => Media::Video,
        "audio" => Media::Audio { seconds: None },
        "voice" => Media::Voice { seconds: None },
        "document" => Media::Document { name: filename.map(String::from) },
        "sticker" => Media::Sticker,
        "location" => Media::Location,
        "contact" => Media::Contact,
        _ => Media::Other,
    }
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

// ── REST answers ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Link {
    Connected,
    NeedsQr,
    Connecting,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Status {
    pub link: Link,
    /// This account's JID or number, once logged in.
    pub me: Option<String>,
}

pub mod gowa {
    use super::*;

    /// GOWA's envelope: `{code, message, results}`.
    pub fn results(data: &[u8]) -> Option<Value> {
        let mut v: Value = serde_json::from_slice(data).ok()?;
        v.get_mut("results").map(Value::take)
    }

    /// `GET /devices` → the device Coucou uses: a logged-in one first, else the first one.
    pub fn device(data: &[u8]) -> Option<(String, Status)> {
        let list = results(data)?;
        let list = list.as_array().filter(|l| !l.is_empty())?;
        let pick = list.iter().find(|d| d.get("state").and_then(Value::as_str) == Some("logged_in")).unwrap_or(&list[0]);
        let id = str_of(pick, "id")?.to_string();
        let jid = str_of(pick, "jid").map(String::from);
        let link = match pick.get("state").and_then(Value::as_str) {
            Some("logged_in") => Link::Connected,
            _ if jid.is_none() => Link::NeedsQr,
            _ => Link::Connecting,
        };
        Some((id, Status { link, me: jid }))
    }

    /// `GET /devices/{id}/login` → the QR PNG's path on the gateway, and its life.
    pub fn qr_path(data: &[u8]) -> Option<(String, u64)> {
        let r = results(data)?;
        let link = str_of(&r, "qr_link")?;
        let url = reqwest::Url::parse(link).ok()?;
        if url.path().is_empty() || url.path() == "/" {
            return None;
        }
        Some((url.path().to_string(), r.get("qr_duration").and_then(Value::as_u64).unwrap_or(30)))
    }

    /// `rest` on this computer only, on the URL's port, media never downloaded.
    pub fn launch_arguments(port: u16) -> Vec<String> {
        vec!["rest".into(), "--host=127.0.0.1".into(), format!("--port={port}"), "--auto-download-media=false".into()]
    }

    /// The error code of a refused call (`ALREADY_LOGGED_IN`…).
    pub fn error_code(data: &[u8]) -> Option<String> {
        let v: Value = serde_json::from_slice(data).ok()?;
        v.get("code").and_then(Value::as_str).map(String::from)
    }

    /// `GET /chats` → (jid, name, last activity).
    pub fn chats(data: &[u8]) -> Vec<(String, String, f64)> {
        let Some(r) = results(data) else { return Vec::new() };
        r.get("data")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|c| {
                        let jid = str_of(c, "jid")?.to_string();
                        let name = c.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                        let last = str_of(c, "last_message_time").and_then(rfc3339).unwrap_or(0.0);
                        Some((jid, name, last))
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// `GET /chat/{jid}/messages` → the stored messages.
    pub fn messages(data: &[u8], me: Option<&str>) -> Vec<Message> {
        let Some(r) = results(data) else { return Vec::new() };
        let chat_name = r.get("chat_info").and_then(|c| str_of(c, "name")).map(String::from);
        let Some(list) = r.get("data").and_then(Value::as_array) else { return Vec::new() };
        list.iter()
            .filter_map(|m| {
                let id = m.get("id").and_then(Value::as_str)?;
                let chat = m.get("chat_jid").and_then(Value::as_str)?;
                let text = m.get("content").and_then(Value::as_str).unwrap_or("");
                let sender = m.get("sender_jid").and_then(Value::as_str).unwrap_or(chat);
                let name = str_of(m, "sender_display_name").unwrap_or("");
                let date = str_of(m, "timestamp").and_then(rfc3339).unwrap_or(0.0);
                let mut msg = Message::new(id, chat, sender, name, text, date);
                msg.media = stored_media(m.get("media_type").and_then(Value::as_str), str_of(m, "filename"));
                msg.from_me = m.get("is_from_me").and_then(Value::as_bool).unwrap_or(false);
                msg.chat_name = if is_group(chat) { chat_name.clone() } else { None };
                msg.mentions_me = is_group(chat) && text_mentions(text, me);
                Some(msg)
            })
            .collect()
    }

    fn stored_media(kind: Option<&str>, filename: Option<&str>) -> Media {
        match kind.unwrap_or("") {
            "" => Media::None,
            "image" => Media::Image,
            "video" | "video_note" => Media::Video,
            "audio" => Media::Voice { seconds: None },
            "document" => Media::Document { name: filename.map(String::from) },
            "sticker" => Media::Sticker,
            _ => Media::Other,
        }
    }
}

pub mod openwa {
    use super::*;

    /// A session: (id, status, phone).
    pub fn session(v: &Value) -> Option<(String, String, Option<String>)> {
        let id = str_of(v, "id")?.to_string();
        let status = v.get("status").and_then(Value::as_str).unwrap_or("").to_string();
        Some((id, status, str_of(v, "phone").map(String::from)))
    }

    /// `GET /api/sessions` → a bare array of sessions; the first one.
    pub fn first_session(data: &[u8]) -> Option<(String, String, Option<String>)> {
        let v: Value = serde_json::from_slice(data).ok()?;
        match &v {
            Value::Array(list) => list.iter().find_map(session),
            other => session(other),
        }
    }

    pub fn status(status: &str, phone: Option<String>) -> Status {
        match status {
            "ready" => Status { link: Link::Connected, me: phone },
            "qr_ready" => Status { link: Link::NeedsQr, me: None },
            _ => Status { link: Link::Connecting, me: phone },
        }
    }

    /// Sessions that must be started before a QR can come.
    pub fn needs_start(status: &str) -> bool {
        matches!(status, "created" | "disconnected" | "failed")
    }

    /// `GET /api/sessions/{id}/qr` → `{qrCode: "data:image/png;base64,…"}`: the PNG bytes.
    pub fn qr_png(data: &[u8]) -> Option<Vec<u8>> {
        let v: Value = serde_json::from_slice(data).ok()?;
        let url = v.get("qrCode")?.as_str()?;
        let rest = url.strip_prefix("data:image/png;base64")?;
        let (_, b64) = rest.split_once(',')?;
        crate::recap::decode_base64(b64)
    }

    /// `GET /api/sessions/{id}/messages` → `{messages: [{waMessageId, chatId, …}]}`.
    pub fn messages(data: &[u8], me: Option<&str>) -> Vec<Message> {
        let Ok(v) = serde_json::from_slice::<Value>(data) else { return Vec::new() };
        let Some(list) = v.get("messages").and_then(Value::as_array) else { return Vec::new() };
        list.iter()
            .filter_map(|m| {
                let id = str_of(m, "waMessageId").or_else(|| str_of(m, "id"))?;
                let chat = str_of(m, "chatId")?;
                let kind = m.get("type").and_then(Value::as_str).unwrap_or("text");
                if kind == "revoked" {
                    return None;
                }
                let filename = m.get("metadata").and_then(|x| x.get("media")).and_then(|x| str_of(x, "filename"));
                let sender = str_of(m, "author").or_else(|| str_of(m, "from")).unwrap_or(chat);
                let text = m.get("body").and_then(Value::as_str).unwrap_or("");
                let mut msg = Message::new(id, chat, sender, "", text, epoch(m.get("timestamp")).unwrap_or(0.0));
                msg.media = openwa_media(kind, filename);
                msg.from_me = m.get("direction").and_then(Value::as_str) == Some("outgoing");
                msg.chat_name = str_of(m, "chatName").map(String::from);
                if is_group(chat) {
                    msg.mentions_me = text_mentions(text, me);
                }
                Some(msg)
            })
            .collect()
    }

    /// NestJS error: `{statusCode, message (string or [string]), error}`.
    pub fn error_message(data: &[u8]) -> Option<String> {
        let v: Value = serde_json::from_slice(data).ok()?;
        match v.get("message")? {
            Value::String(s) => Some(s.clone()),
            Value::Array(list) => Some(list.iter().filter_map(Value::as_str).collect::<Vec<_>>().join(", ")),
            _ => None,
        }
    }

    /// OpenWA names people `<number>@c.us`.
    pub fn id(jid: &str) -> String {
        jid.strip_suffix("@s.whatsapp.net").map(|u| format!("{u}@c.us")).unwrap_or_else(|| jid.to_string())
    }
}

// ── GOWA's GitHub release (Install WhatsApp) ──────────────────────────────────

pub mod release {
    use super::*;

    pub const LATEST: &str = "https://api.github.com/repos/aldinokemal/go-whatsapp-web-multidevice/releases/latest";

    #[derive(Debug, Clone, PartialEq)]
    pub struct Asset {
        pub name: String,
        pub url: String,
        pub size: u64,
        /// "sha256:<hex>" when GitHub gives it.
        pub digest: Option<String>,
    }

    /// `{tag_name, assets: [{name, browser_download_url, size, digest?}]}`.
    pub fn parse(data: &[u8]) -> Option<(String, Vec<Asset>)> {
        let v: Value = serde_json::from_slice(data).ok()?;
        let tag = v.get("tag_name")?.as_str()?;
        let assets = v
            .get("assets")?
            .as_array()?
            .iter()
            .filter_map(|a| {
                Some(Asset {
                    name: a.get("name")?.as_str()?.to_string(),
                    url: a.get("browser_download_url")?.as_str()?.to_string(),
                    size: a.get("size").and_then(Value::as_u64).unwrap_or(0),
                    digest: a.get("digest").and_then(Value::as_str).map(String::from),
                })
            })
            .collect();
        Some((tag.strip_prefix('v').unwrap_or(tag).to_string(), assets))
    }

    /// The Windows zip for this processor ("amd64", "386") and the checksums file.
    pub fn pick(assets: &[Asset], arch: &str) -> Option<(Asset, Option<Asset>)> {
        let zip = assets
            .iter()
            .find(|a| a.name.starts_with("whatsapp_") && a.name.ends_with(&format!("_windows_{arch}.zip")))?
            .clone();
        let sums = assets.iter().find(|a| a.name == "checksums.txt").cloned();
        Some((zip, sums))
    }

    /// The SHA-256 (lowercase hex) of `asset` in a checksums file ("<hex>  <name>"
    /// per line), else GitHub's own "sha256:<hex>" digest.
    pub fn expected_sha256(asset: &Asset, checksums: Option<&str>) -> Option<String> {
        for line in checksums.unwrap_or("").lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() == 2 && parts[1] == asset.name && parts[0].len() == 64 {
                return Some(parts[0].to_lowercase());
            }
        }
        let d = asset.digest.as_deref()?;
        (d.starts_with("sha256:") && d.len() == 71).then(|| d[7..].to_lowercase())
    }

    /// Only GitHub serves the download (its assets redirect to githubusercontent.com).
    pub fn allowed_host(host: Option<&str>) -> bool {
        let Some(h) = host.map(str::to_lowercase) else { return false };
        h == "github.com" || h == "api.github.com" || h.ends_with(".githubusercontent.com")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::whatsapp::models::{Filters, Inbox, Outcome};

    const GOWA_TEXT: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"3EB0C127D7BACC83D6A1","chat_id":"628987654321@s.whatsapp.net","from":"628123456789@s.whatsapp.net","from_lid":"251556368777322@lid","sender_display_name":"Saved Contact","from_name":"John Doe","timestamp":"2023-10-15T10:30:00Z","is_from_me":false,"body":"Hello, how are you?"}}"#;
    const GOWA_IMAGE: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"3EB0C127D7BACC83D6A3","chat_id":"628987654321@s.whatsapp.net","from":"628123456789@s.whatsapp.net","from_name":"John Doe","timestamp":"2025-07-13T11:05:51Z","body":"Check this out!","image":{"path":"statics/media/x.jpeg","caption":"Check this out!"}}}"#;
    const GOWA_AUDIO: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"3EB0C127D7BACC83D6A5","chat_id":"628987654321@s.whatsapp.net","from":"628123456789@s.whatsapp.net","from_name":"John Doe","timestamp":"2023-10-15T10:55:00Z","audio":"statics/media/x.ogg"}}"#;
    const GOWA_ACK: &str = r#"{"event":"message.ack","device_id":"628123456789@s.whatsapp.net","timestamp":"2025-07-18T22:44:20Z","payload":{"ids":["3EB00106E8BE0F407E88EC"],"chat_id":"120363402106XXXXX@g.us","receipt_type":"delivered"}}"#;
    const GOWA_GROUP_MENTION: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"G1","chat_id":"120363402106000001@g.us","from":"628123456789@s.whatsapp.net","from_name":"John Doe","timestamp":"2025-07-13T11:05:51Z","is_from_me":false,"body":"@628987654321 tu viens ?"}}"#;
    const OPENWA_TEXT: &str = r#"{"event":"message.received","timestamp":"2026-02-02T10:30:00Z","sessionId":"3f2a","data":{"id":"ABC123_DEF456","from":"628123456789@c.us","to":"628987654321@c.us","chatId":"628123456789@c.us","body":"Hello!","type":"text","timestamp":1706868600,"fromMe": false,"isGroup":false}}"#;
    const OPENWA_MINIMAL: &str = r#"{"event":"message.received","sessionId":"default","data":{"id":"3EB0F5A2B4C...","chatId":"628123456789@c.us","from":"628123456789@c.us","body":"Hello!","type":"text","timestamp":1705312200}}"#;
    const OPENWA_GROUP_VOICE: &str = r#"{"event":"message.received","sessionId":"s1","data":{"id":"3EB0VOICE","from":"120363000000000000@g.us","chatId":"120363000000000000@g.us","author":"6281111111111@c.us","body":"","type":"voice","timestamp":1706868600,"fromMe":false,"isGroup":true,"mentionedIds":["6280000000000@c.us"],"contact":{"pushName":"Budi"},"media":{"mimetype":"audio/ogg","omitted":true}}}"#;

    fn message(e: Option<Event>) -> Message {
        match e {
            Some(Event::Message(m)) => *m,
            other => panic!("not a message: {other:?}"),
        }
    }

    #[test]
    fn gowa_webhook() {
        let m = message(parse_webhook(Kind::Gowa, GOWA_TEXT.as_bytes(), None));
        assert_eq!((m.id.as_str(), m.chat.as_str()), ("3EB0C127D7BACC83D6A1", "628987654321@s.whatsapp.net"));
        assert_eq!(m.sender_name, "Saved Contact", "the saved contact's name first");
        assert_eq!((m.text.as_str(), &m.media), ("Hello, how are you?", &Media::None));
        assert_eq!(m.date, 1_697_365_800.0, "RFC3339 date");
        assert!(!m.from_me);
        let img = message(parse_webhook(Kind::Gowa, GOWA_IMAGE.as_bytes(), None));
        assert_eq!((&img.media, img.text.as_str(), img.from_me), (&Media::Image, "Check this out!", false));
        let audio = message(parse_webhook(Kind::Gowa, GOWA_AUDIO.as_bytes(), None));
        assert_eq!(audio.media, Media::Voice { seconds: None });
        assert_eq!(audio.preview_key(), ("Voice message", String::new()));
        assert_eq!(parse_webhook(Kind::Gowa, GOWA_ACK.as_bytes(), None), Some(Event::Ignored), "a receipt is ignored");
        assert_eq!(parse_webhook(Kind::Gowa, b"nope", None), None);
        let g = message(parse_webhook(Kind::Gowa, GOWA_GROUP_MENTION.as_bytes(), None));
        assert!(g.mentions_me && g.sender == "628123456789@s.whatsapp.net");
        let mut inbox = Inbox::default();
        assert_eq!(inbox.add(g, &Filters::default(), None, false), Outcome::Notify, "despite muted groups");
    }

    #[test]
    fn openwa_webhook() {
        let m = message(parse_webhook(Kind::Openwa, OPENWA_TEXT.as_bytes(), None));
        assert_eq!((m.id.as_str(), m.chat.as_str()), ("ABC123_DEF456", "628123456789@c.us"));
        assert_eq!(m.date, 1_706_868_600.0);
        assert!(!m.from_me && m.text == "Hello!");
        let mut inbox = Inbox::default();
        inbox.add(m, &Filters::default(), None, false);
        assert!(inbox.conversations.contains_key("628123456789@s.whatsapp.net"), "@c.us folded into GOWA's form");
        let min = message(parse_webhook(Kind::Openwa, OPENWA_MINIMAL.as_bytes(), None));
        assert!(min.id == "3EB0F5A2B4C..." && !min.from_me, "missing fields tolerated");
        let v = message(parse_webhook(Kind::Openwa, OPENWA_GROUP_VOICE.as_bytes(), Some("6280000000000")));
        assert_eq!((v.sender.as_str(), v.sender_name.as_str()), ("6281111111111@c.us", "Budi"));
        assert_eq!(v.media, Media::Voice { seconds: None });
        assert!(v.mentions_me);
        let ping = r#"{"event":"test","data":{"message":"This is a test webhook from OpenWA"}}"#;
        assert_eq!(parse_webhook(Kind::Openwa, ping.as_bytes(), None), Some(Event::Ignored));
        let sent = OPENWA_TEXT.replace("message.received", "message.sent").replace(r#""fromMe": false"#, r#""fromMe": true"#);
        assert!(message(parse_webhook(Kind::Openwa, sent.as_bytes(), None)).from_me);
    }

    #[test]
    fn signatures() {
        use std::collections::HashMap;
        // OpenWA's own fixture (sdk/javascript/test/webhook.test.ts).
        let secret = "test-secret-0123456789";
        let body = r#"{"event":"message.received","timestamp":"2026-02-02T10:00:00.000Z","sessionId":"s1","idempotencyKey":"k","deliveryId":"dlv_1","data":{"text":"héllo 👋"}}"#.as_bytes();
        let header = "sha256=d74a41bb687f31ed4c932f76f524116100ca4120d2cabb7a469ee5d928122f70";
        assert_eq!(signature(body, secret), header);
        let h = |v: &str| HashMap::from([("x-openwa-signature".to_string(), v.to_string())]);
        assert!(verify(Kind::Openwa, &h(header), body, secret));
        let mut flipped = body.to_vec();
        flipped[3] ^= 1;
        assert!(!verify(Kind::Openwa, &h(header), &flipped, secret), "a flipped byte fails");
        assert!(!verify(Kind::Openwa, &h(header), body, &format!("{secret}x")), "the wrong secret fails");
        assert!(!verify(Kind::Openwa, &h(&header[7..]), body, secret), "no prefix fails");
        assert!(!verify(Kind::Openwa, &h(&format!("SHA256={}", &header[7..])), body, secret));
        assert!(!verify(Kind::Openwa, &h(&header[..header.len() - 1]), body, secret), "truncated fails");
        assert!(!verify(Kind::Openwa, &HashMap::new(), body, secret), "missing header fails");
        assert!(!verify(Kind::Openwa, &h(header), body, ""), "empty secret fails");
        assert!(!verify(Kind::Gowa, &h(header), body, secret), "GOWA's header is its own");
        // RFC 4231 test case 2.
        assert_eq!(
            signature(b"what do ya want for nothing?", "Jefe"),
            "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        );
        let long = "k".repeat(100);
        let sig = signature(b"x", &long);
        let gh = HashMap::from([("x-hub-signature-256".to_string(), sig.clone())]);
        assert!(sig.len() == 71 && verify(Kind::Gowa, &gh, b"x", &long), "a key longer than a block");
    }

    #[test]
    fn rest_answers() {
        let devices = r#"{"code":"SUCCESS","message":"List devices","results":[{"id":"coucou","state":"disconnected"},{"id":"my-device-id","phone_number":"628123456789","state":"logged_in","jid":"628123456789@s.whatsapp.net"}]}"#;
        assert_eq!(
            gowa::device(devices.as_bytes()),
            Some(("my-device-id".into(), Status { link: Link::Connected, me: Some("628123456789@s.whatsapp.net".into()) }))
        );
        let fresh = r#"{"code":"SUCCESS","results":[{"id":"coucou","state":"disconnected"}]}"#;
        assert_eq!(gowa::device(fresh.as_bytes()).unwrap().1.link, Link::NeedsQr);
        assert_eq!(gowa::device(br#"{"code":"SUCCESS","results":[]}"#), None);
        let login = r#"{"code":"SUCCESS","results":{"device_id":"coucou","qr_duration":30,"qr_link":"http://localhost:3000/statics/qrcode/scan-qr-b0b7.png"}}"#;
        assert_eq!(gowa::qr_path(login.as_bytes()), Some(("/statics/qrcode/scan-qr-b0b7.png".into(), 30)));
        assert_eq!(gowa::launch_arguments(3001), ["rest", "--host=127.0.0.1", "--port=3001", "--auto-download-media=false"]);
        assert_eq!(gowa::error_code(br#"{"code":"ALREADY_LOGGED_IN","message":"x"}"#).as_deref(), Some("ALREADY_LOGGED_IN"));
        let msgs = r#"{"code":"SUCCESS","results":{"data":[{"id":"M2","chat_jid":"120363402106000001@g.us","sender_jid":"628123456789@s.whatsapp.net","sender_display_name":"John","content":"","timestamp":"2025-07-13T11:06:00Z","is_from_me":false,"media_type":"document","filename":"devis.pdf"},{"id":"M1","chat_jid":"120363402106000001@g.us","sender_jid":"628987654321@s.whatsapp.net","content":"salut","timestamp":"2025-07-13T11:05:00Z","is_from_me":true,"media_type":""}],"chat_info":{"jid":"120363402106000001@g.us","name":"Famille"}}}"#;
        let list = gowa::messages(msgs.as_bytes(), None);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].media, Media::Document { name: Some("devis.pdf".into()) });
        assert!(list[1].from_me);
        assert_eq!(list[0].chat_name.as_deref(), Some("Famille"));
        let chats = r#"{"code":"SUCCESS","results":{"data":[{"jid":"628123456789@s.whatsapp.net","name":"John","last_message_time":"2025-07-13T11:06:00Z"}]}}"#;
        assert_eq!(gowa::chats(chats.as_bytes())[0].1, "John");

        let session = r#"[{"id":"0b5d6c3e","name":"coucou","status":"ready","phone":"628123456789"}]"#;
        let (id, status, phone) = openwa::first_session(session.as_bytes()).unwrap();
        assert_eq!(id, "0b5d6c3e");
        assert_eq!(openwa::status(&status, phone), Status { link: Link::Connected, me: Some("628123456789".into()) });
        assert_eq!(openwa::status("qr_ready", None).link, Link::NeedsQr);
        assert!(openwa::needs_start("created") && !openwa::needs_start("qr_ready"));
        let qr = r#"{"qrCode":"data:image/png;base64,iVBORw==","status":"qr_ready"}"#;
        assert_eq!(openwa::qr_png(qr.as_bytes()), Some(vec![0x89, 0x50, 0x4E, 0x47]));
        let stored = r#"{"messages":[{"id":"9f0c","waMessageId":"3EB0AB","chatId":"628123456789@c.us","from":"628123456789@c.us","chatName":"Alice","author":null,"body":"See you","type":"text","direction":"incoming","timestamp":1719306115,"metadata":null}],"total":1}"#;
        let om = openwa::messages(stored.as_bytes(), None);
        assert_eq!((om[0].id.as_str(), om[0].chat_name.as_deref(), om[0].from_me), ("3EB0AB", Some("Alice"), false));
        assert_eq!(openwa::error_message(br#"{"statusCode":400,"message":["a","b"]}"#).as_deref(), Some("a, b"));
        assert_eq!(openwa::id("336@s.whatsapp.net"), "336@c.us");
    }

    #[test]
    fn gowas_github_release() {
        let json = r#"{"tag_name":"v9.6.0","assets":[{"name":"checksums.txt","size":582,"browser_download_url":"https://github.com/a/b/releases/download/v9.6.0/checksums.txt"},{"name":"whatsapp_9.6.0_darwin_arm64.zip","size":1,"browser_download_url":"https://github.com/x"},{"name":"whatsapp_9.6.0_windows_386.zip","size":12254948,"browser_download_url":"https://github.com/a/b/releases/download/v9.6.0/whatsapp_9.6.0_windows_386.zip"},{"name":"whatsapp_9.6.0_windows_amd64.zip","size":12517486,"digest":"sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","browser_download_url":"https://github.com/a/b/releases/download/v9.6.0/whatsapp_9.6.0_windows_amd64.zip"}]}"#;
        let (version, assets) = release::parse(json.as_bytes()).unwrap();
        assert_eq!(version, "9.6.0");
        let (zip, sums) = release::pick(&assets, "amd64").unwrap();
        assert_eq!((zip.name.as_str(), sums.map(|s| s.name)), ("whatsapp_9.6.0_windows_amd64.zip", Some("checksums.txt".into())));
        assert_eq!(release::pick(&assets, "386").unwrap().0.name, "whatsapp_9.6.0_windows_386.zip");
        assert!(release::pick(&assets[..2], "amd64").is_none(), "never a Mac one");
        let file = "1111111111111111111111111111111111111111111111111111111111111111  whatsapp_9.6.0_windows_386.zip\n2222222222222222222222222222222222222222222222222222222222222222  whatsapp_9.6.0_windows_amd64.zip\n";
        assert_eq!(release::expected_sha256(&zip, Some(file)), Some("2".repeat(64)));
        assert_eq!(release::expected_sha256(&zip, None), Some("a".repeat(64)), "else GitHub's digest");
        let bare = release::Asset { name: "x.zip".into(), url: String::new(), size: 1, digest: None };
        assert_eq!(release::expected_sha256(&bare, Some(file)), None);
        assert!(release::allowed_host(Some("objects.githubusercontent.com")) && release::allowed_host(Some("github.com")));
        assert!(!release::allowed_host(Some("github.com.evil.io")) && !release::allowed_host(None));
    }

    #[test]
    fn dates() {
        assert_eq!(rfc3339("2023-10-15T10:30:00Z"), Some(1_697_365_800.0));
        assert_eq!(rfc3339("2023-10-15T12:30:00+02:00"), Some(1_697_365_800.0));
        assert_eq!(rfc3339("2026-02-02T10:00:00.250Z"), Some(1_770_026_400.25));
        assert_eq!(rfc3339("1970-01-01T00:00:00Z"), Some(0.0));
        assert_eq!(rfc3339("yesterday"), None);
        assert_eq!(epoch(Some(&Value::from("1706868600"))), Some(1_706_868_600.0));
    }
}
