// What the two local WhatsApp gateways send and answer, turned into `Message`. Port of
// WhatsAppGateway.swift: every field name comes from each gateway's docs and source code:
//   GOWA   — github.com/aldinokemal/go-whatsapp-web-multidevice (docs/webhook-payload.md, docs/openapi.yaml)
//   OpenWA — github.com/rmyndharis/OpenWA (docs/06-api-specification.md)
// Nothing parsed here is logged or written anywhere.

use std::collections::HashMap;

use serde_json::Value;

use super::model::{self, constant_time_eq, Media, Message};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Gowa,
    Openwa,
}

impl Kind {
    pub fn from_name(name: &str) -> Kind {
        if name == "openwa" { Kind::Openwa } else { Kind::Gowa }
    }

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

/// What one webhook delivery holds for Coucou.
#[derive(Debug, PartialEq)]
pub enum WebhookEvent {
    Message(Message),
    /// A valid delivery Coucou has no use for (receipts, reactions, a test ping…).
    Ignored,
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// "sha256=<lowercase hex>" of HMAC-SHA256(secret, body): what both gateways send.
pub fn signature(body: &[u8], secret: &str) -> String {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, secret.as_bytes());
    format!("sha256={}", hex(ring::hmac::sign(&key, body).as_ref()))
}

/// True when the delivery carries the signature `secret` gives, over the raw body bytes.
pub fn verify(kind: Kind, headers: &HashMap<String, String>, body: &[u8], secret: &str) -> bool {
    if secret.is_empty() {
        return false;
    }
    let Some(sent) = headers.get(kind.signature_header()) else { return false };
    sent.starts_with("sha256=") && constant_time_eq(sent, &signature(body, secret))
}

fn text(v: Option<&Value>) -> Option<String> {
    v.and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

/// Parses one delivery. None when it isn't JSON at all. `me` is this account's JID or number.
pub fn parse_webhook(kind: Kind, body: &[u8], me: Option<&str>) -> Option<WebhookEvent> {
    let json: Value = serde_json::from_slice(body).ok()?;
    if !json.is_object() {
        return None;
    }
    Some(match kind {
        Kind::Gowa => parse_gowa(&json, me),
        Kind::Openwa => parse_openwa(&json, me),
    })
}

/// `{"event":"message","device_id":"<own JID>","payload":{id, chat_id, from, from_name,
/// sender_display_name, timestamp (RFC3339), is_from_me, body, image|video|audio|document|…}}`
fn parse_gowa(json: &Value, me: Option<&str>) -> WebhookEvent {
    if json.get("event").and_then(Value::as_str) != Some("message") {
        return WebhookEvent::Ignored;
    }
    let Some(p) = json.get("payload").filter(|p| p.is_object()) else { return WebhookEvent::Ignored };
    let (Some(id), Some(chat)) = (text(p.get("id")), text(p.get("chat_id"))) else { return WebhookEvent::Ignored };
    let from = text(p.get("from")).unwrap_or_else(|| chat.clone());
    let body = p.get("body").and_then(Value::as_str).unwrap_or("").to_string();
    let mine = me.map(str::to_string).or_else(|| text(json.get("device_id")));
    let mut m = Message::new(&id, &chat, &from, &body, rfc3339_ms(p.get("timestamp").and_then(Value::as_str)).unwrap_or_else(now_ms));
    m.sender_name = text(p.get("sender_display_name")).or_else(|| text(p.get("from_name"))).unwrap_or_default();
    m.media = gowa_media(p);
    m.from_me = p.get("is_from_me").and_then(Value::as_bool).unwrap_or(false);
    m.mentions_me = model::is_group(&chat) && model::text_mentions(&body, mine.as_deref());
    WebhookEvent::Message(m)
}

/// GOWA puts each media under its own key; only the label matters to Coucou.
pub fn gowa_media(p: &Value) -> Media {
    let has = |k: &str| p.get(k).is_some_and(|v| !v.is_null());
    if has("image") {
        Media::Image
    } else if has("video") || has("video_note") {
        Media::Video
    } else if has("audio") {
        Media::Voice { seconds: None }
    } else if has("document") {
        Media::Document { name: text(p.get("document").and_then(|d| d.get("filename"))) }
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

/// `{"event":"message.received"|"message.sent","sessionId","data":{id, from, to, chatId, author,
/// body, type, timestamp (epoch s), fromMe, isGroup, mentionedIds, contact{name, pushName}, media{filename}}}`
fn parse_openwa(json: &Value, me: Option<&str>) -> WebhookEvent {
    let event = json.get("event").and_then(Value::as_str);
    if event != Some("message.received") && event != Some("message.sent") {
        return WebhookEvent::Ignored;
    }
    let Some(d) = json.get("data").filter(|d| d.is_object()) else { return WebhookEvent::Ignored };
    let Some(id) = text(d.get("id")) else { return WebhookEvent::Ignored };
    let Some(chat) = text(d.get("chatId")).or_else(|| text(d.get("from"))) else { return WebhookEvent::Ignored };
    let kind = d.get("type").and_then(Value::as_str).unwrap_or("text");
    if kind == "revoked" {
        return WebhookEvent::Ignored;
    }
    let from_me = d.get("fromMe").and_then(Value::as_bool).unwrap_or(event == Some("message.sent"));
    let contact = d.get("contact");
    let sender = text(d.get("author")).or_else(|| text(d.get("from"))).unwrap_or_else(|| chat.clone());
    let body = d.get("body").and_then(Value::as_str).unwrap_or("");
    let mut m = Message::new(&id, &chat, &sender, body, epoch_ms(d.get("timestamp")).unwrap_or_else(now_ms));
    m.sender_name = text(contact.and_then(|c| c.get("name")))
        .or_else(|| text(contact.and_then(|c| c.get("pushName"))))
        .unwrap_or_default();
    m.media = openwa_media(kind, text(d.get("media").and_then(|x| x.get("filename"))));
    m.from_me = from_me;
    let group = d.get("isGroup").and_then(Value::as_bool).unwrap_or_else(|| model::is_group(&chat));
    if let (true, Some(mine)) = (group, me) {
        let ids = d.get("mentionedIds").and_then(Value::as_array);
        let named = ids.is_some_and(|ids| ids.iter().filter_map(Value::as_str).any(|x| model::same_user(x, mine)));
        m.mentions_me = named || model::text_mentions(body, Some(mine));
    }
    WebhookEvent::Message(m)
}

/// OpenWA's `type` (text|image|video|audio|voice|document|sticker|location|contact|poll|…).
pub fn openwa_media(kind: &str, filename: Option<String>) -> Media {
    match kind {
        "text" | "" => Media::None,
        "image" => Media::Image,
        "video" => Media::Video,
        "audio" => Media::Audio { seconds: None },
        "voice" => Media::Voice { seconds: None },
        "document" => Media::Document { name: filename },
        "sticker" => Media::Sticker,
        "location" => Media::Location,
        "contact" => Media::Contact,
        _ => Media::Other,
    }
}

// ── REST answers ──────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Link {
    /// Logged in and online.
    Connected,
    /// Waiting for the QR to be scanned.
    NeedsQr,
    /// Logged in but offline, starting, or anything in between.
    Connecting,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Status {
    pub link: Link,
    /// This account's JID or number, once logged in.
    pub me: Option<String>,
}

pub mod gowa {
    use super::*;

    /// GOWA's envelope: `{code, message, results}`.
    pub fn results(data: &[u8]) -> Option<Value> {
        serde_json::from_slice::<Value>(data).ok()?.get("results").cloned()
    }

    /// `GET /devices` → `results: [{id, phone_number, display_name, state, jid, created_at}]`.
    /// The device Coucou uses: a logged-in one first, else the first one.
    pub fn device(data: &[u8]) -> Option<(String, Status)> {
        let list = results(data)?;
        let list = list.as_array()?;
        let pick = list.iter().find(|d| d.get("state").and_then(Value::as_str) == Some("logged_in")).or(list.first())?;
        let id = text(pick.get("id"))?;
        let jid = text(pick.get("jid"));
        let link = match pick.get("state").and_then(Value::as_str) {
            Some("logged_in") => Link::Connected,
            _ if jid.is_none() => Link::NeedsQr,
            _ => Link::Connecting,
        };
        Some((id, Status { link, me: jid }))
    }

    /// `GET /devices/{id}/login` → `results: {device_id, qr_link, qr_duration}`. The PNG's path,
    /// to fetch from the gateway itself (never from another host the link may name).
    pub fn qr_path(data: &[u8]) -> Option<(String, u64)> {
        let r = results(data)?;
        let link = r.get("qr_link")?.as_str()?;
        let url = reqwest::Url::parse(link).ok()?;
        let path = url.path().to_string();
        if path.is_empty() || path == "/" {
            return None;
        }
        Some((path, r.get("qr_duration").and_then(Value::as_u64).unwrap_or(30)))
    }

    /// `whatsapp rest` for "Start GOWA automatically": on this computer only, on the URL's port,
    /// and media never downloaded (Coucou shows a label), so GOWA keeps no photo or voice note.
    pub fn launch_arguments(port: u16) -> Vec<String> {
        vec![
            "rest".into(),
            "--host=127.0.0.1".into(),
            format!("--port={port}"),
            "--auto-download-media=false".into(),
        ]
    }

    /// The error code of a refused call (`ALREADY_LOGGED_IN`, `DEVICE_ID_REQUIRED`…).
    pub fn error_code(data: &[u8]) -> Option<String> {
        text(serde_json::from_slice::<Value>(data).ok()?.get("code"))
    }

    /// `GET /chats` → `results: {data: [{jid, name, last_message_time, …}], pagination}`.
    pub fn chats(data: &[u8]) -> Vec<(String, String, i64)> {
        let Some(r) = results(data) else { return vec![] };
        let Some(list) = r.get("data").and_then(Value::as_array) else { return vec![] };
        list.iter()
            .filter_map(|c| {
                let jid = text(c.get("jid"))?;
                let name = c.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                Some((jid, name, rfc3339_ms(c.get("last_message_time").and_then(Value::as_str)).unwrap_or(0)))
            })
            .collect()
    }

    /// `GET /chat/{jid}/messages` → `results: {data: [{id, chat_jid, sender_jid, sender_display_name,
    /// content, timestamp, is_from_me, media_type, filename}], chat_info}`. Newest first there.
    pub fn messages(data: &[u8], me: Option<&str>) -> Vec<Message> {
        let Some(r) = results(data) else { return vec![] };
        let chat_name = text(r.get("chat_info").and_then(|c| c.get("name")));
        let Some(list) = r.get("data").and_then(Value::as_array) else { return vec![] };
        list.iter()
            .filter_map(|m| {
                let id = m.get("id")?.as_str()?;
                let chat = m.get("chat_jid")?.as_str()?;
                let content = m.get("content").and_then(Value::as_str).unwrap_or("");
                let sender = m.get("sender_jid").and_then(Value::as_str).unwrap_or(chat);
                let mut msg = Message::new(id, chat, sender, content, rfc3339_ms(m.get("timestamp").and_then(Value::as_str)).unwrap_or(0));
                msg.sender_name = text(m.get("sender_display_name")).unwrap_or_default();
                msg.media = stored_media(m.get("media_type").and_then(Value::as_str), text(m.get("filename")));
                msg.from_me = m.get("is_from_me").and_then(Value::as_bool).unwrap_or(false);
                let group = model::is_group(chat);
                msg.chat_name = if group { chat_name.clone() } else { None };
                msg.mentions_me = group && model::text_mentions(content, me);
                Some(msg)
            })
            .collect()
    }

    /// `media_type` of a stored message: image|video|video_note|audio|document|sticker|call or "".
    pub fn stored_media(kind: Option<&str>, filename: Option<String>) -> Media {
        match kind.unwrap_or("") {
            "" => Media::None,
            "image" => Media::Image,
            "video" | "video_note" => Media::Video,
            "audio" => Media::Voice { seconds: None },
            "document" => Media::Document { name: filename },
            "sticker" => Media::Sticker,
            _ => Media::Other,
        }
    }

    /// `GET /group/info?group_id=…` → `results: {Name, …}`.
    pub fn group_name(data: &[u8]) -> Option<String> {
        text(results(data)?.get("Name"))
    }

    /// `POST /send/message` → `results: {message_id, status}`.
    pub fn sent_id(data: &[u8]) -> Option<String> {
        text(results(data)?.get("message_id"))
    }
}

pub mod openwa {
    use super::*;

    /// A session: `{id (uuid), name, status, phone, pushName, …}`.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Session {
        pub id: String,
        pub name: String,
        pub status: String,
        pub phone: Option<String>,
    }

    pub fn session(v: &Value) -> Option<Session> {
        Some(Session {
            id: text(v.get("id"))?,
            name: v.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
            status: v.get("status").and_then(Value::as_str).unwrap_or("").to_string(),
            phone: text(v.get("phone")),
        })
    }

    /// `GET /api/sessions` → a bare array of sessions.
    pub fn sessions(data: &[u8]) -> Vec<Session> {
        match serde_json::from_slice::<Value>(data) {
            Ok(Value::Array(list)) => list.iter().filter_map(session).collect(),
            Ok(v) => session(&v).into_iter().collect(),
            Err(_) => vec![],
        }
    }

    pub fn status(s: &Session) -> Status {
        match s.status.as_str() {
            "ready" => Status { link: Link::Connected, me: s.phone.clone() },
            "qr_ready" => Status { link: Link::NeedsQr, me: None },
            _ => Status { link: Link::Connecting, me: s.phone.clone() },
        }
    }

    /// Sessions that must be started before a QR can come: never started, stopped or failed.
    pub fn needs_start(status: &str) -> bool {
        matches!(status, "created" | "disconnected" | "failed")
    }

    /// `GET /api/sessions/{id}/qr` → `{qrCode: "data:image/png;base64,…"}`: the data URL itself,
    /// checked to be a PNG in base64 and nothing else.
    pub fn qr_data_url(data: &[u8]) -> Option<String> {
        let v: Value = serde_json::from_slice(data).ok()?;
        let url = v.get("qrCode")?.as_str()?;
        let b64 = url.strip_prefix("data:image/png;base64,")?;
        (!b64.is_empty() && b64.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'='))
            .then(|| url.to_string())
    }

    /// `GET /api/sessions/{id}/messages` → `{messages: [{waMessageId, chatId, from, author, chatName,
    /// body, type, direction, timestamp (s), metadata}], total}`.
    pub fn messages(data: &[u8], me: Option<&str>) -> Vec<Message> {
        let Ok(v) = serde_json::from_slice::<Value>(data) else { return vec![] };
        let Some(list) = v.get("messages").and_then(Value::as_array) else { return vec![] };
        list.iter()
            .filter_map(|m| {
                let id = text(m.get("waMessageId")).or_else(|| text(m.get("id")))?;
                let chat = text(m.get("chatId"))?;
                let kind = m.get("type").and_then(Value::as_str).unwrap_or("text");
                if kind == "revoked" {
                    return None;
                }
                let sender = text(m.get("author")).or_else(|| text(m.get("from"))).unwrap_or_else(|| chat.clone());
                let body = m.get("body").and_then(Value::as_str).unwrap_or("");
                let mut msg = Message::new(&id, &chat, &sender, body, epoch_ms(m.get("timestamp")).unwrap_or(0));
                let filename = text(m.get("metadata").and_then(|x| x.get("media")).and_then(|x| x.get("filename")));
                msg.media = openwa_media(kind, filename);
                msg.from_me = m.get("direction").and_then(Value::as_str) == Some("outgoing");
                msg.chat_name = text(m.get("chatName"));
                if model::is_group(&chat) {
                    msg.mentions_me = model::text_mentions(body, me);
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

    /// OpenWA names people `<number>@c.us` (Coucou keeps the @s.whatsapp.net form inside).
    pub fn chat_id(jid: &str) -> String {
        match jid.strip_suffix("@s.whatsapp.net") {
            Some(user) => format!("{user}@c.us"),
            None => jid.to_string(),
        }
    }
}

// ── GOWA's own releases (Install WhatsApp) ─────────────────────────────────────

pub mod release {
    use super::*;

    pub const LATEST_URL: &str = "https://api.github.com/repos/aldinokemal/go-whatsapp-web-multidevice/releases/latest";

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Asset {
        pub name: String,
        pub url: String,
        pub size: u64,
        /// "sha256:<hex>" when GitHub gives it.
        pub digest: Option<String>,
    }

    /// `GET /releases/latest` → `{tag_name, assets: [{name, browser_download_url, size, digest?}]}`.
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
                    digest: a.get("digest").and_then(Value::as_str).map(str::to_string),
                })
            })
            .collect();
        Some((tag.strip_prefix('v').unwrap_or(tag).to_string(), assets))
    }

    /// GOWA's system names: "windows" or "linux"; "amd64" or "arm64".
    pub fn this_os() -> &'static str {
        if cfg!(windows) { "windows" } else { "linux" }
    }

    pub fn this_arch() -> &'static str {
        if cfg!(target_arch = "aarch64") { "arm64" } else { "amd64" }
    }

    /// The zip for this system (`whatsapp_<version>_<os>_<arch>.zip`, as GOWA's release workflow names
    /// them) and its checksums file (`checksums-<os>.txt`, else a plain `checksums.txt`).
    pub fn pick<'a>(assets: &'a [Asset], os: &str, arch: &str) -> Option<(&'a Asset, Option<&'a Asset>)> {
        let suffix = format!("_{os}_{arch}.zip");
        let zip = assets.iter().find(|a| a.name.starts_with("whatsapp_") && a.name.ends_with(&suffix))?;
        let os_sums = match os {
            "windows" => "checksums-windows.txt",
            "linux" => "checksums-linux.txt",
            _ => "checksums-macos.txt",
        };
        let sums = assets
            .iter()
            .find(|a| a.name == os_sums)
            .or_else(|| assets.iter().find(|a| a.name == "checksums.txt"));
        Some((zip, sums))
    }

    /// The binary inside the zip: `<os>-<arch>` (`.exe` on Windows) as GOWA builds it, else a
    /// `whatsapp` / `whatsapp.exe` at any depth. Never a folder, never anything else.
    pub fn binary_entry<'a>(names: &'a [String], os: &str, arch: &str) -> Option<&'a String> {
        let base = |n: &str| n.rsplit('/').next().unwrap_or(n).to_string();
        let exe = if os == "windows" { ".exe" } else { "" };
        let wanted = [format!("{os}-{arch}{exe}"), format!("{os}-{arch}"), format!("whatsapp{exe}")];
        wanted.iter().find_map(|w| names.iter().find(|n| !n.ends_with('/') && base(n) == *w))
    }

    /// The SHA-256 (lowercase hex) of `asset` in a GoReleaser checksums file ("<hex>  <name>" per
    /// line), else GitHub's own "sha256:<hex>" digest.
    pub fn expected_sha256(asset: &Asset, checksums: Option<&str>) -> Option<String> {
        for line in checksums.unwrap_or("").lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() == 2 && parts[1] == asset.name && parts[0].len() == 64 && parts[0].bytes().all(|b| b.is_ascii_hexdigit()) {
                return Some(parts[0].to_ascii_lowercase());
            }
        }
        asset.digest.as_deref().and_then(crate::update::parse_digest)
    }
}

// ── Dates ─────────────────────────────────────────────────────────────────────

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

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

/// "2023-10-15T10:30:00Z", "…T10:30:00.123+02:00" → milliseconds since 1970.
pub fn rfc3339_ms(s: Option<&str>) -> Option<i64> {
    let s = s?.trim();
    let b = s.as_bytes();
    if b.len() < 20 || b[4] != b'-' || b[7] != b'-' || !(b[10] == b'T' || b[10] == b't' || b[10] == b' ') || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let num = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?, num(17..19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || se > 60 {
        return None;
    }
    let mut rest = &s[19..];
    let mut millis = 0i64;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits: String = frac.chars().take_while(char::is_ascii_digit).collect();
        if digits.is_empty() {
            return None;
        }
        let ms: String = digits.chars().chain("000".chars()).take(3).collect();
        millis = ms.parse().ok()?;
        rest = &frac[digits.len()..];
    }
    let offset_min = match rest {
        "Z" | "z" => 0,
        o if o.len() == 6 && (o.starts_with('+') || o.starts_with('-')) && &o[3..4] == ":" => {
            let sign = if o.starts_with('-') { -1 } else { 1 };
            sign * (o[1..3].parse::<i64>().ok()? * 60 + o[4..6].parse::<i64>().ok()?)
        }
        _ => return None,
    };
    let days = days_from_civil(y, mo, d);
    Some(((days * 86_400 + h * 3600 + mi * 60 + se - offset_min * 60) * 1000) + millis)
}

/// Epoch seconds, as a number or a numeric string → milliseconds.
pub fn epoch_ms(v: Option<&Value>) -> Option<i64> {
    let secs = match v? {
        Value::Number(n) => n.as_f64()?,
        Value::String(s) => s.trim().parse::<f64>().ok()?,
        _ => return None,
    };
    (secs > 0.0).then(|| (secs * 1000.0) as i64)
}

/// The ISO 8601 form GOWA's `start_time` takes (UTC, seconds).
pub fn iso_utc(ms: i64) -> String {
    let secs = ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let tod = secs.rem_euclid(86_400);
    // civil_from_days (Howard Hinnant).
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", tod / 3600, tod % 3600 / 60, tod % 60)
}

/// Standard base64 with padding (RFC 4648).
pub fn base64(bytes: &[u8]) -> String {
    const ABC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (u32::from(chunk[0]) << 16) | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8) | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(ABC[(n >> 18) as usize & 63] as char);
        out.push(ABC[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { ABC[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { ABC[n as usize & 63] as char } else { '=' });
    }
    out
}

/// PNG bytes → a `data:` URL the webview can show (no file, no other host).
pub fn png_data_url(png: &[u8]) -> String {
    format!("data:image/png;base64,{}", base64(png))
}

#[cfg(test)]
mod tests {
    use super::*;

    // GOWA docs/webhook-payload.md — text message
    const GOWA_TEXT: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"3EB0C127D7BACC83D6A1","chat_id":"628987654321@s.whatsapp.net","from":"628123456789@s.whatsapp.net","from_lid":"251556368777322@lid","sender_display_name":"Saved Contact","from_name":"John Doe","timestamp":"2023-10-15T10:30:00Z","is_from_me":false,"body":"Hello, how are you?"}}"#;
    const GOWA_IMAGE: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"3EB0C127D7BACC83D6A3","chat_id":"628987654321@s.whatsapp.net","from":"628123456789@s.whatsapp.net","from_name":"John Doe","timestamp":"2025-07-13T11:05:51Z","body":"Check this out!","image":{"path":"statics/media/1.jpeg","caption":"Check this out!"}}}"#;
    const GOWA_AUDIO: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"3EB0C127D7BACC83D6A5","chat_id":"628987654321@s.whatsapp.net","from":"628123456789@s.whatsapp.net","from_name":"John Doe","timestamp":"2023-10-15T10:55:00Z","audio":"statics/media/1.ogg"}}"#;
    const GOWA_ACK: &str = r#"{"event":"message.ack","device_id":"628123456789@s.whatsapp.net","timestamp":"2025-07-18T22:44:20Z","payload":{"ids":["3EB00106E8BE0F407E88EC"],"chat_id":"120363402106XXXXX@g.us","receipt_type":"delivered"}}"#;
    const GOWA_GROUP_MENTION: &str = r#"{"event":"message","device_id":"628987654321@s.whatsapp.net","payload":{"id":"G1","chat_id":"120363402106000001@g.us","from":"628123456789@s.whatsapp.net","from_name":"John Doe","timestamp":"2025-07-13T11:05:51Z","is_from_me":false,"body":"@628987654321 tu viens ?"}}"#;
    // OpenWA docs/12-troubleshooting-faq.md — 1:1 text message.received
    const OPENWA_TEXT: &str = r#"{"event":"message.received","timestamp":"2026-02-02T10:30:00Z","sessionId":"3f2a","data":{"id":"ABC123_DEF456","from":"628123456789@c.us","to":"628987654321@c.us","chatId":"628123456789@c.us","body":"Hello!","type":"text","timestamp":1706868600,"fromMe":false,"isGroup":false}}"#;
    const OPENWA_MINIMAL: &str = r#"{"event":"message.received","sessionId":"default","data":{"id":"3EB0F5A2B4C...","chatId":"628123456789@c.us","from":"628123456789@c.us","body":"Hello!","type":"text","timestamp":1705312200}}"#;
    const OPENWA_GROUP_VOICE: &str = r#"{"event":"message.received","sessionId":"s1","data":{"id":"3EB0VOICE","from":"120363000000000000@g.us","to":"6280000000000@c.us","chatId":"120363000000000000@g.us","author":"6281111111111@c.us","body":"","type":"voice","timestamp":1706868600,"fromMe":false,"isGroup":true,"mentionedIds":["6280000000000@c.us"],"contact":{"pushName":"Budi"}}}"#;

    fn message(kind: Kind, body: &str, me: Option<&str>) -> Message {
        match parse_webhook(kind, body.as_bytes(), me) {
            Some(WebhookEvent::Message(m)) => m,
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn gowa_webhooks_from_its_docs() {
        let m = message(Kind::Gowa, GOWA_TEXT, None);
        assert_eq!((m.id.as_str(), m.chat.as_str()), ("3EB0C127D7BACC83D6A1", "628987654321@s.whatsapp.net"));
        assert_eq!(m.sender_name, "Saved Contact");
        assert_eq!((m.text.as_str(), &m.media), ("Hello, how are you?", &Media::None));
        assert_eq!(m.date, 1_697_365_800_000);
        assert!(!m.from_me);
        let m = message(Kind::Gowa, GOWA_IMAGE, None);
        assert_eq!((&m.media, m.text.as_str(), m.from_me), (&Media::Image, "Check this out!", false));
        assert_eq!(message(Kind::Gowa, GOWA_AUDIO, None).media, Media::Voice { seconds: None });
        assert_eq!(parse_webhook(Kind::Gowa, GOWA_ACK.as_bytes(), None), Some(WebhookEvent::Ignored));
        assert_eq!(parse_webhook(Kind::Gowa, b"nope", None), None);
        let m = message(Kind::Gowa, GOWA_GROUP_MENTION, None);
        assert!(m.mentions_me);
        assert_eq!(m.sender, "628123456789@s.whatsapp.net");
        let mut inbox = model::Inbox::default();
        assert_eq!(inbox.add(m, &model::Filters::default(), None, false), model::Outcome::Notify);
    }

    #[test]
    fn openwa_webhooks_from_its_docs() {
        let m = message(Kind::Openwa, OPENWA_TEXT, None);
        assert_eq!((m.id.as_str(), m.chat.as_str()), ("ABC123_DEF456", "628123456789@c.us"));
        assert_eq!(m.date, 1_706_868_600_000);
        assert!(!m.from_me);
        let mut inbox = model::Inbox::default();
        inbox.add(m, &model::Filters::default(), None, false);
        assert!(inbox.conversations.contains_key("628123456789@s.whatsapp.net"), "@c.us folded into GOWA's form");
        let m = message(Kind::Openwa, OPENWA_MINIMAL, None);
        assert_eq!(m.id, "3EB0F5A2B4C...");
        let m = message(Kind::Openwa, OPENWA_GROUP_VOICE, Some("6280000000000"));
        assert_eq!((m.sender.as_str(), m.sender_name.as_str()), ("6281111111111@c.us", "Budi"));
        assert_eq!(m.media, Media::Voice { seconds: None });
        assert!(m.mentions_me);
        let ping = r#"{"event":"test","data":{"message":"This is a test webhook from OpenWA"}}"#;
        assert_eq!(parse_webhook(Kind::Openwa, ping.as_bytes(), None), Some(WebhookEvent::Ignored));
        let sent = OPENWA_TEXT.replace("message.received", "message.sent").replace(r#""fromMe":false"#, r#""fromMe":true"#);
        assert!(message(Kind::Openwa, &sent, None).from_me);
    }

    #[test]
    fn signatures() {
        // OpenWA sdk/javascript/test/webhook.test.ts.
        let secret = "test-secret-0123456789";
        let body = r#"{"event":"message.received","timestamp":"2026-02-02T10:00:00.000Z","sessionId":"s1","idempotencyKey":"k","deliveryId":"dlv_1","data":{"text":"héllo 👋"}}"#.as_bytes();
        let header = "sha256=d74a41bb687f31ed4c932f76f524116100ca4120d2cabb7a469ee5d928122f70";
        assert_eq!(signature(body, secret), header);
        let h = |v: &str| HashMap::from([("x-openwa-signature".to_string(), v.to_string())]);
        assert!(verify(Kind::Openwa, &h(header), body, secret));
        let mut flipped = body.to_vec();
        flipped[3] ^= 1;
        assert!(!verify(Kind::Openwa, &h(header), &flipped, secret));
        assert!(!verify(Kind::Openwa, &h(header), body, &format!("{secret}x")));
        assert!(!verify(Kind::Openwa, &h(&header[7..]), body, secret));
        assert!(!verify(Kind::Openwa, &h(&format!("SHA256={}", &header[7..])), body, secret));
        assert!(!verify(Kind::Openwa, &h(&header[..header.len() - 1]), body, secret));
        assert!(!verify(Kind::Openwa, &HashMap::new(), body, secret));
        assert!(!verify(Kind::Openwa, &h(header), body, ""));
        assert!(!verify(Kind::Gowa, &h(header), body, secret), "GOWA's header is its own");
        // RFC 4231 test case 2.
        assert_eq!(signature(b"what do ya want for nothing?", "Jefe"),
            "sha256=5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }

    #[test]
    fn rest_answers() {
        let devices = r#"{"code":"SUCCESS","results":[{"id":"coucou","state":"disconnected"},{"id":"my-device-id","state":"logged_in","jid":"628123456789@s.whatsapp.net"}]}"#;
        assert_eq!(gowa::device(devices.as_bytes()),
            Some(("my-device-id".into(), Status { link: Link::Connected, me: Some("628123456789@s.whatsapp.net".into()) })));
        let fresh = r#"{"code":"SUCCESS","results":[{"id":"coucou","state":"disconnected"}]}"#;
        assert_eq!(gowa::device(fresh.as_bytes()).unwrap().1.link, Link::NeedsQr);
        assert_eq!(gowa::device(br#"{"code":"SUCCESS","results":[]}"#), None);
        let login = r#"{"code":"SUCCESS","results":{"device_id":"coucou","qr_duration":30,"qr_link":"http://localhost:3000/statics/qrcode/scan-qr-b0b7.png"}}"#;
        assert_eq!(gowa::qr_path(login.as_bytes()), Some(("/statics/qrcode/scan-qr-b0b7.png".into(), 30)));
        assert_eq!(gowa::launch_arguments(3001), ["rest", "--host=127.0.0.1", "--port=3001", "--auto-download-media=false"]);
        assert_eq!(gowa::error_code(br#"{"code":"ALREADY_LOGGED_IN","message":"x"}"#).as_deref(), Some("ALREADY_LOGGED_IN"));
        let msgs = r#"{"code":"SUCCESS","results":{"data":[{"id":"M2","chat_jid":"120363402106000001@g.us","sender_jid":"628123456789@s.whatsapp.net","sender_display_name":"John","content":"","timestamp":"2025-07-13T11:06:00Z","is_from_me":false,"media_type":"document","filename":"devis.pdf"},{"id":"M1","chat_jid":"120363402106000001@g.us","sender_jid":"628987654321@s.whatsapp.net","content":"salut","timestamp":"2025-07-13T11:05:00Z","is_from_me":true,"media_type":""}],"chat_info":{"name":"Famille"}}}"#;
        let list = gowa::messages(msgs.as_bytes(), None);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].media, Media::Document { name: Some("devis.pdf".into()) });
        assert!(list[1].from_me);
        assert_eq!(list[0].chat_name.as_deref(), Some("Famille"));
        let chats = r#"{"code":"SUCCESS","results":{"data":[{"jid":"628123456789@s.whatsapp.net","name":"John","last_message_time":"2025-07-13T11:06:00Z"}]}}"#;
        assert_eq!(gowa::chats(chats.as_bytes())[0].1, "John");

        let session = r#"[{"id":"0b5d","name":"coucou","status":"ready","phone":"628123456789"}]"#;
        let s = &openwa::sessions(session.as_bytes())[0];
        assert_eq!(openwa::status(s), Status { link: Link::Connected, me: Some("628123456789".into()) });
        assert!(openwa::needs_start("created") && !openwa::needs_start("qr_ready"));
        assert_eq!(openwa::qr_data_url(br#"{"qrCode":"data:image/png;base64,iVBORw==","status":"qr_ready"}"#).as_deref(),
            Some("data:image/png;base64,iVBORw=="));
        assert_eq!(openwa::qr_data_url(br#"{"qrCode":"data:text/html;base64,PHA+"}"#), None);
        assert_eq!(openwa::qr_data_url(br#"{"qrCode":"data:image/png;base64,\"><script>"}"#), None);
        let stored = r#"{"messages":[{"waMessageId":"3EB0AB","chatId":"628123456789@c.us","from":"628123456789@c.us","chatName":"Alice","author":null,"body":"See you","type":"text","direction":"incoming","timestamp":1719306115}],"total":1}"#;
        let om = openwa::messages(stored.as_bytes(), None);
        assert_eq!((om[0].id.as_str(), om[0].chat_name.as_deref(), om[0].from_me), ("3EB0AB", Some("Alice"), false));
        assert_eq!(openwa::error_message(br#"{"statusCode":400,"message":["a","b"]}"#).as_deref(), Some("a, b"));
        assert_eq!(openwa::chat_id("336@s.whatsapp.net"), "336@c.us");
    }

    #[test]
    fn gowa_release_for_this_system() {
        let json = r#"{"tag_name":"v9.6.0","assets":[
            {"name":"checksums-macos.txt","size":228,"browser_download_url":"https://github.com/a/b/releases/download/v9.6.0/checksums-macos.txt"},
            {"name":"checksums-linux.txt","size":228,"browser_download_url":"https://github.com/a/b/releases/download/v9.6.0/checksums-linux.txt"},
            {"name":"whatsapp_9.6.0_darwin_arm64.zip","size":13100000,"browser_download_url":"https://github.com/x"},
            {"name":"whatsapp_9.6.0_linux_amd64.zip","size":13900000,"browser_download_url":"https://github.com/y"},
            {"name":"whatsapp_9.6.0_linux_arm64.zip","size":1,"browser_download_url":"https://github.com/z"},
            {"name":"whatsapp_9.6.0_windows_amd64.zip","size":14000000,"digest":"sha256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","browser_download_url":"https://github.com/w"}]}"#;
        let (version, assets) = release::parse(json.as_bytes()).unwrap();
        assert_eq!(version, "9.6.0");
        let (zip, sums) = release::pick(&assets, "linux", "amd64").unwrap();
        assert_eq!((zip.name.as_str(), sums.map(|s| s.name.as_str())), ("whatsapp_9.6.0_linux_amd64.zip", Some("checksums-linux.txt")));
        let (zip, sums) = release::pick(&assets, "windows", "amd64").unwrap();
        assert_eq!(zip.name, "whatsapp_9.6.0_windows_amd64.zip");
        assert!(sums.is_none(), "no checksums-windows.txt nor checksums.txt here");
        assert!(release::pick(&assets, "windows", "arm64").is_none());
        let text = format!("{}  whatsapp_9.6.0_linux_amd64.zip\n{}  whatsapp_9.6.0_linux_arm64.zip\n", "1".repeat(64), "2".repeat(64));
        let (zip, _) = release::pick(&assets, "linux", "arm64").unwrap();
        assert_eq!(release::expected_sha256(zip, Some(&text)), Some("2".repeat(64)));
        let (win, _) = release::pick(&assets, "windows", "amd64").unwrap();
        assert_eq!(release::expected_sha256(win, None), Some("a".repeat(64)), "GitHub's digest");
        let (lin, _) = release::pick(&assets, "linux", "amd64").unwrap();
        assert_eq!(release::expected_sha256(lin, Some("nothing here")), None);
        let names: Vec<String> = ["README.md", "bin/", "bin/linux-amd64", "windows-amd64.exe"].map(String::from).to_vec();
        assert_eq!(release::binary_entry(&names, "linux", "amd64").map(String::as_str), Some("bin/linux-amd64"));
        assert_eq!(release::binary_entry(&names, "windows", "amd64").map(String::as_str), Some("windows-amd64.exe"));
        let plain: Vec<String> = ["whatsapp.exe".to_string()].to_vec();
        assert_eq!(release::binary_entry(&plain, "windows", "amd64").map(String::as_str), Some("whatsapp.exe"));
        assert_eq!(release::binary_entry(&plain, "linux", "amd64"), None);
    }

    #[test]
    fn dates_and_data_urls() {
        assert_eq!(rfc3339_ms(Some("1970-01-01T00:00:00Z")), Some(0));
        assert_eq!(rfc3339_ms(Some("2023-10-15T10:30:00Z")), Some(1_697_365_800_000));
        assert_eq!(rfc3339_ms(Some("2023-10-15T12:30:00.5+02:00")), Some(1_697_365_800_500));
        assert_eq!(rfc3339_ms(Some("2023-10-15T10:30:00.123456Z")), Some(1_697_365_800_123));
        assert_eq!(rfc3339_ms(Some("yesterday")), None);
        assert_eq!(rfc3339_ms(Some("2023-13-15T10:30:00Z")), None);
        assert_eq!(rfc3339_ms(None), None);
        assert_eq!(epoch_ms(Some(&serde_json::json!(1706868600))), Some(1_706_868_600_000));
        assert_eq!(epoch_ms(Some(&serde_json::json!("1706868600"))), Some(1_706_868_600_000));
        assert_eq!(epoch_ms(Some(&serde_json::json!(0))), None);
        assert_eq!(iso_utc(1_697_365_800_000), "2023-10-15T10:30:00Z");
        assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(png_data_url(&[0x89, 0x50, 0x4E, 0x47]), "data:image/png;base64,iVBORw==");
        assert_eq!(png_data_url(b"Man"), "data:image/png;base64,TWFu");
        assert_eq!(png_data_url(b"Ma"), "data:image/png;base64,TWE=");
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn gowas_real_release_names_on_linux_and_windows() {
        // GOWA's release.yml (GoReleaser): whatsapp_<version>_<os>_<arch>.zip, one checksums.txt for
        // Linux and Windows (checksums-macos.txt is the Mac's), and the binary named <os>-<arch>[.exe].
        let json = r#"{"tag_name":"v9.0.1","assets":[
            {"name":"checksums-macos.txt","size":228,"browser_download_url":"https://github.com/a/b/releases/download/v9.0.1/checksums-macos.txt"},
            {"name":"checksums.txt","size":700,"browser_download_url":"https://github.com/a/b/releases/download/v9.0.1/checksums.txt"},
            {"name":"whatsapp_9.0.1_linux_amd64.zip","size":13900000,"browser_download_url":"https://github.com/y"},
            {"name":"whatsapp_9.0.1_linux_armv7.zip","size":13000000,"browser_download_url":"https://github.com/v"},
            {"name":"whatsapp_9.0.1_windows_amd64.zip","size":14000000,"browser_download_url":"https://github.com/w"}]}"#;
        let (_, assets) = release::parse(json.as_bytes()).unwrap();
        for os in ["linux", "windows"] {
            let (zip, sums) = release::pick(&assets, os, "amd64").unwrap();
            assert_eq!(zip.name, format!("whatsapp_9.0.1_{os}_amd64.zip"));
            assert_eq!(sums.map(|s| s.name.as_str()), Some("checksums.txt"));
        }
        let names = vec!["windows-amd64.exe".to_string()];
        assert_eq!(release::binary_entry(&names, "windows", "amd64").map(String::as_str), Some("windows-amd64.exe"));
        let names = vec!["linux-amd64".to_string()];
        assert_eq!(release::binary_entry(&names, "linux", "amd64").map(String::as_str), Some("linux-amd64"));
    }
}
