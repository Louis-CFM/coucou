// The two local WhatsApp gateways Coucou can talk to — port of
// WhatsAppProvider.swift. Each call goes to the URL set in Settings
// (127.0.0.1 by default) and nowhere else: no redirect is followed, no proxy
// is used, nothing is cached, and no media is ever fetched.

use std::sync::Mutex;
use std::time::Duration;

use reqwest::{Method, Url};
use serde_json::{json, Value};

use super::gateway::{gowa, openwa, Kind, Link, Status};
use super::models::Message;

#[derive(Debug, Clone, PartialEq)]
pub enum Error {
    /// Nothing answers at that URL.
    Unreachable,
    /// Wrong user:pass (GOWA) or API key (OpenWA).
    Unauthorized,
    /// The gateway answered with an error (its own message, never a message's content).
    Refused(String),
    /// WhatsApp isn't linked yet.
    NotLoggedIn,
}

pub struct Provider {
    pub kind: Kind,
    base: Url,
    auth: Option<(String, String)>,
    client: reqwest::Client,
    /// GOWA's device, or OpenWA's session.
    scope: Mutex<Option<String>>,
}

/// Percent-encodes one path segment (a JID: "@" and "." stay as they are).
fn segment(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'@' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

impl Provider {
    /// `credential`: "user:pass" for GOWA's basic auth, the API key for OpenWA.
    pub fn new(kind: Kind, url: &str, credential: Option<&str>) -> Option<Provider> {
        let base = Url::parse(url.trim()).ok().filter(|u| u.scheme() == "http" || u.scheme() == "https")?;
        let auth = credential.filter(|c| !c.is_empty()).and_then(|c| match kind {
            Kind::Gowa => c.contains(':').then(|| ("Authorization".into(), format!("Basic {}", crate::claude::base64_for(c.as_bytes())))),
            Kind::Openwa => Some(("X-API-Key".into(), c.to_string())),
        });
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .no_proxy()
            .build()
            .ok()?;
        Some(Provider { kind, base, auth, client, scope: Mutex::new(None) })
    }

    async fn call(&self, method: Method, path: &str, query: &[(&str, String)], body: Option<Value>, timeout: u64) -> Result<(Vec<u8>, u16), Error> {
        let mut url = self.base.clone();
        let prefix = url.path().trim_end_matches('/').to_string();
        url.set_path(&format!("{prefix}{path}"));
        if !query.is_empty() {
            let mut q = url.query_pairs_mut();
            for (k, v) in query {
                q.append_pair(k, v);
            }
        }
        let mut req = self.client.request(method, url.clone()).timeout(Duration::from_secs(timeout)).header("Accept", "application/json");
        if let Some((name, value)) = &self.auth {
            req = req.header(name.as_str(), value.as_str());
        }
        if let Some(body) = body {
            req = req.json(&body);
        }
        let response = req.send().await.map_err(|_| Error::Unreachable)?;
        // Second lock: an answer from anywhere but the gateway is not one.
        if response.url().host() != url.host() || response.url().port_or_known_default() != url.port_or_known_default() {
            return Err(Error::Unreachable);
        }
        let code = response.status().as_u16();
        let bytes = response.bytes().await.map_err(|_| Error::Unreachable)?;
        Ok((bytes.to_vec(), code))
    }

    fn check(&self, data: &[u8], code: u16) -> Result<(), Error> {
        match self.kind {
            Kind::Gowa => {
                if code == 401 {
                    return Err(if gowa::error_code(data).as_deref() == Some("AUTHENTICATION_ERROR") {
                        Error::NotLoggedIn
                    } else {
                        Error::Unauthorized
                    });
                }
                if !(200..300).contains(&code) {
                    return Err(Error::Refused(gowa::error_code(data).unwrap_or_else(|| format!("HTTP {code}"))));
                }
            }
            Kind::Openwa => {
                if code == 401 || code == 403 {
                    return Err(Error::Unauthorized);
                }
                if !(200..300).contains(&code) {
                    return Err(Error::Refused(openwa::error_message(data).unwrap_or_else(|| format!("HTTP {code}"))));
                }
            }
        }
        Ok(())
    }

    fn scope(&self) -> Option<String> {
        self.scope.lock().unwrap().clone()
    }

    // ── GOWA: one device (the one logged in, else "coucou") ──────────────────

    async fn gowa_device(&self) -> Result<(String, Status), Error> {
        let (data, code) = self.call(Method::GET, "/devices", &[], None, 10).await?;
        self.check(&data, code)?;
        if let Some(found) = gowa::device(&data) {
            *self.scope.lock().unwrap() = Some(found.0.clone());
            return Ok(found);
        }
        let (made, code) = self.call(Method::POST, "/devices", &[], Some(json!({ "device_id": "coucou" })), 10).await?;
        self.check(&made, code)?;
        *self.scope.lock().unwrap() = Some("coucou".into());
        Ok(("coucou".into(), Status { link: Link::NeedsQr, me: None }))
    }

    async fn gowa_id(&self) -> Result<String, Error> {
        match self.scope() {
            Some(id) => Ok(id),
            None => Ok(self.gowa_device().await?.0),
        }
    }

    async fn gowa_scoped(&self, method: Method, path: &str, mut query: Vec<(&str, String)>, body: Option<Value>) -> Result<Vec<u8>, Error> {
        query.push(("device_id", self.gowa_id().await?));
        let (data, code) = self.call(method, path, &query, body, 10).await?;
        self.check(&data, code)?;
        Ok(data)
    }

    // ── OpenWA: one session (the one ready, else "coucou", started) ──────────

    async fn openwa_session(&self) -> Result<(String, String, Option<String>), Error> {
        let (data, code) = self.call(Method::GET, "/api/sessions", &[], None, 10).await?;
        self.check(&data, code)?;
        let list: Vec<Value> = serde_json::from_slice::<Value>(&data).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
        let all: Vec<_> = list.iter().filter_map(openwa::session).collect();
        let known = self.scope();
        let named = list.iter().find(|s| s.get("name").and_then(Value::as_str) == Some("coucou")).and_then(openwa::session);
        let pick = all
            .iter()
            .find(|s| s.1 == "ready")
            .cloned()
            .or_else(|| all.iter().find(|s| Some(&s.0) == known.as_ref()).cloned())
            .or(named)
            .or_else(|| all.first().cloned());
        let mut session = match pick {
            Some(s) => s,
            None => {
                let (made, code) = self.call(Method::POST, "/api/sessions", &[], Some(json!({ "name": "coucou" })), 10).await?;
                self.check(&made, code)?;
                let v: Value = serde_json::from_slice(&made).map_err(|_| Error::Refused("session".into()))?;
                let mut s = openwa::session(&v).ok_or_else(|| Error::Refused("session".into()))?;
                s.1 = "created".into();
                s
            }
        };
        *self.scope.lock().unwrap() = Some(session.0.clone());
        if openwa::needs_start(&session.1) {
            let (started, code) = self.call(Method::POST, &format!("/api/sessions/{}/start", session.0), &[], None, 10).await?;
            self.check(&started, code)?;
            if let Some(s) = serde_json::from_slice::<Value>(&started).ok().as_ref().and_then(openwa::session) {
                session = s;
            }
        }
        Ok(session)
    }

    async fn openwa_id(&self) -> Result<String, Error> {
        match self.scope() {
            Some(id) => Ok(id),
            None => Ok(self.openwa_session().await?.0),
        }
    }

    async fn openwa_scoped(&self, method: Method, path: &str, query: Vec<(&str, String)>, body: Option<Value>) -> Result<Vec<u8>, Error> {
        let id = self.openwa_id().await?;
        let (data, code) = self.call(method, &format!("/api/sessions/{id}{path}"), &query, body, 10).await?;
        self.check(&data, code)?;
        Ok(data)
    }

    // ── What the controller asks ─────────────────────────────────────────────

    /// The link to WhatsApp (sets up the device or session the first time).
    pub async fn status(&self) -> Result<Status, Error> {
        match self.kind {
            Kind::Gowa => Ok(self.gowa_device().await?.1),
            Kind::Openwa => {
                let (_, status, phone) = self.openwa_session().await?;
                Ok(openwa::status(&status, phone))
            }
        }
    }

    /// The QR to scan (PNG bytes) and how long it stays valid; None when there is
    /// none to show (already linked, not ready yet).
    pub async fn qr_code(&self) -> Result<Option<(Vec<u8>, u64)>, Error> {
        match self.kind {
            Kind::Gowa => {
                let id = self.gowa_id().await?;
                // GOWA answers once WhatsApp has handed it the first code: a few seconds.
                let (data, code) = self.call(Method::GET, &format!("/devices/{}/login", segment(&id)), &[], None, 45).await?;
                if gowa::error_code(&data).as_deref() == Some("ALREADY_LOGGED_IN") {
                    return Ok(None);
                }
                self.check(&data, code)?;
                let Some((path, seconds)) = gowa::qr_path(&data) else { return Ok(None) };
                // Served by the gateway itself: fetched from the configured URL, whatever host the link names.
                let (png, code) = self.call(Method::GET, &path, &[], None, 10).await?;
                if code != 200 || !png.starts_with(&[0x89, b'P', b'N', b'G']) {
                    return Ok(None);
                }
                // qr_duration is half the code's life: asking again sooner restarts the pairing.
                Ok(Some((png, (seconds * 2).saturating_sub(5).max(20))))
            }
            Kind::Openwa => {
                let id = self.openwa_id().await?;
                let (data, code) = self.call(Method::GET, &format!("/api/sessions/{id}/qr"), &[], None, 10).await?;
                if code == 400 {
                    return Ok(None);
                }
                self.check(&data, code)?;
                Ok(openwa::qr_png(&data).map(|png| (png, 15)))
            }
        }
    }

    /// Tells the gateway to post new messages to Coucou's local webhook, signed with `secret`.
    pub async fn register_webhook(&self, url: &str, secret: &str) -> Result<(), Error> {
        match self.kind {
            Kind::Gowa => {
                let id = self.gowa_id().await?;
                let body = json!({ "webhook_url": url, "webhook_secret": secret, "webhook_events": "message" });
                let (data, code) = self.call(Method::PATCH, &format!("/devices/{}/webhook", segment(&id)), &[], Some(body), 10).await?;
                self.check(&data, code)
            }
            Kind::Openwa => {
                let id = self.openwa_id().await?;
                let body = json!({ "url": url, "events": ["message.received", "message.sent"], "secret": secret });
                let (list, code) = self.call(Method::GET, &format!("/api/sessions/{id}/webhooks"), &[], None, 10).await?;
                self.check(&list, code)?;
                let hooks: Vec<Value> = serde_json::from_slice::<Value>(&list).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default();
                let mine = hooks.iter().find(|h| h.get("url").and_then(Value::as_str) == Some(url)).and_then(|h| h.get("id")?.as_str().map(String::from));
                let (data, code) = match mine {
                    Some(hook) => self.call(Method::PUT, &format!("/api/sessions/{id}/webhooks/{hook}"), &[], Some(body), 10).await?,
                    None => self.call(Method::POST, &format!("/api/sessions/{id}/webhooks"), &[], Some(body), 10).await?,
                };
                self.check(&data, code)
            }
        }
    }

    /// Messages of every chat since `since` (Unix seconds; the polling fallback), oldest first.
    pub async fn recent_messages(&self, since: f64, me: Option<&str>) -> Result<Vec<Message>, Error> {
        let mut out = match self.kind {
            Kind::Gowa => {
                let chats = gowa::chats(&self.gowa_scoped(Method::GET, "/chats", vec![("limit", "20".into())], None).await?);
                let mut out = Vec::new();
                // Only the chats that moved since `since` (newest first from the gateway).
                for (jid, name, last) in chats.into_iter().take(8).filter(|c| c.2 > since) {
                    let _ = last;
                    let data = self
                        .gowa_scoped(
                            Method::GET,
                            &format!("/chat/{}/messages", segment(&jid)),
                            vec![("limit", "10".into()), ("start_time", iso(since))],
                            None,
                        )
                        .await?;
                    for mut m in gowa::messages(&data, me) {
                        if m.chat_name.is_none() && !name.is_empty() && super::models::is_group(&jid) {
                            m.chat_name = Some(name.clone());
                        }
                        out.push(m);
                    }
                }
                out
            }
            Kind::Openwa => {
                let query = vec![
                    ("since", ((since * 1000.0) as i64).to_string()),
                    ("limit", "50".into()),
                    ("inlineMedia", "false".into()),
                ];
                openwa::messages(&self.openwa_scoped(Method::GET, "/messages", query, None).await?, me)
            }
        };
        out.sort_by(|a, b| a.date.partial_cmp(&b.date).unwrap_or(std::cmp::Ordering::Equal));
        Ok(out)
    }

    /// The latest `limit` messages of one chat, oldest first.
    pub async fn messages(&self, chat: &str, limit: u32, me: Option<&str>) -> Result<Vec<Message>, Error> {
        let mut out = match self.kind {
            Kind::Gowa => gowa::messages(
                &self.gowa_scoped(Method::GET, &format!("/chat/{}/messages", segment(chat)), vec![("limit", limit.to_string())], None).await?,
                me,
            ),
            Kind::Openwa => openwa::messages(
                &self
                    .openwa_scoped(
                        Method::GET,
                        "/messages",
                        vec![("chatId", openwa::id(chat)), ("limit", limit.to_string()), ("inlineMedia", "false".into())],
                        None,
                    )
                    .await?,
                me,
            ),
        };
        out.sort_by(|a, b| a.date.partial_cmp(&b.date).unwrap_or(std::cmp::Ordering::Equal));
        Ok(out)
    }

    /// Sends a text to an existing chat; the new message's id when the gateway gives it.
    pub async fn send(&self, text: &str, chat: &str) -> Result<Option<String>, Error> {
        match self.kind {
            Kind::Gowa => {
                let data = self.gowa_scoped(Method::POST, "/send/message", Vec::new(), Some(json!({ "phone": chat, "message": text }))).await?;
                Ok(gowa::results(&data).and_then(|r| r.get("message_id")?.as_str().map(String::from)))
            }
            Kind::Openwa => {
                let body = json!({ "chatId": openwa::id(chat), "text": text });
                let data = self.openwa_scoped(Method::POST, "/messages/send-text", Vec::new(), Some(body)).await?;
                Ok(serde_json::from_slice::<Value>(&data).ok().and_then(|v| v.get("messageId")?.as_str().map(String::from)))
            }
        }
    }

    /// Marks the chat read up to `last_incoming` (the newest message received in it).
    pub async fn mark_read(&self, chat: &str, last_incoming: Option<&str>) -> Result<(), Error> {
        match self.kind {
            Kind::Gowa => {
                let Some(id) = last_incoming else { return Ok(()) };
                self.gowa_scoped(Method::POST, &format!("/message/{}/read", segment(id)), Vec::new(), Some(json!({ "phone": chat }))).await?;
                Ok(())
            }
            Kind::Openwa => {
                self.openwa_scoped(Method::POST, "/chats/read", Vec::new(), Some(json!({ "chatId": openwa::id(chat) }))).await?;
                Ok(())
            }
        }
    }

    /// A group's name, when the messages don't carry it.
    pub async fn group_name(&self, chat: &str) -> Option<String> {
        if !super::models::is_group(chat) {
            return None;
        }
        match self.kind {
            Kind::Gowa => {
                let data = self.gowa_scoped(Method::GET, "/group/info", vec![("group_id", chat.into())], None).await.ok()?;
                gowa::results(&data)?.get("Name")?.as_str().filter(|n| !n.is_empty()).map(String::from)
            }
            Kind::Openwa => {
                let data = self.openwa_scoped(Method::GET, &format!("/groups/{}", segment(chat)), Vec::new(), None).await.ok()?;
                serde_json::from_slice::<Value>(&data).ok()?.get("name")?.as_str().filter(|n| !n.is_empty()).map(String::from)
            }
        }
    }
}

/// Unix seconds → "2026-10-19T12:00:00Z".
pub fn iso(seconds: f64) -> String {
    let s = seconds.max(0.0) as i64;
    let (days, rem) = (s.div_euclid(86_400), s.rem_euclid(86_400));
    // Civil date from days (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn times_and_paths() {
        assert_eq!(iso(1_697_365_800.0), "2023-10-15T10:30:00Z");
        assert_eq!(super::super::gateway::rfc3339(&iso(1_800_000_000.0)), Some(1_800_000_000.0));
        assert_eq!(segment("120363@g.us"), "120363@g.us");
        assert_eq!(segment("a b/c"), "a%20b%2Fc");
    }

    #[test]
    fn only_http_gateways_and_their_credentials() {
        assert!(Provider::new(Kind::Gowa, "file:///etc", None).is_none());
        let p = Provider::new(Kind::Gowa, "http://127.0.0.1:3000", Some("user:pass")).unwrap();
        assert_eq!(p.auth.as_ref().map(|a| a.1.as_str()), Some("Basic dXNlcjpwYXNz"));
        assert!(Provider::new(Kind::Gowa, "http://127.0.0.1:3000", Some("nocolon")).unwrap().auth.is_none());
        let o = Provider::new(Kind::Openwa, "http://127.0.0.1:2785", Some("key")).unwrap();
        assert_eq!(o.auth, Some(("X-API-Key".into(), "key".into())));
    }
}
