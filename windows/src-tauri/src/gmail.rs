// Gmail over the official REST API with per-user OAuth — the path that works
// where IMAP port 993 is firewalled (raw TCP blocked, HTTPS open).
//
// Each user registers their OWN OAuth client once (Google Cloud Console → APIs
// & Services → Credentials → OAuth client ID → Desktop app, Gmail API
// enabled, own address added as test user). No shared secret ships with the
// app, so there is nothing to leak and no verification to wait for.
//
// Flow (`gmail_signin`, one call from Settings):
// 1. Save the pasted client id/secret, bind 127.0.0.1 on an ephemeral port.
// 2. Open the consent URL in the browser; wait (3 min) for the redirect hit.
// 3. Exchange the code, fetch the profile address, persist everything in the
//    Credential Manager under "gmail-oauth" (refresh + access + expiry).
// Polling reuses the access token and refreshes it silently when needed.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::mail::{MailItem, MailboxState};

const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const SCOPE: &str = "https://www.googleapis.com/auth/gmail.readonly";
const API_ME: &str = "https://gmail.googleapis.com/gmail/v1/users/me";
const REDIRECT_PATH: &str = "/auth";

#[derive(Serialize, Deserialize, Default)]
struct OAuthStore {
    refresh_token: String,
    access_token: String,
    /// Unix seconds when `access_token` stops being valid (with margin).
    expires_at: u64,
}

fn now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn load() -> Option<OAuthStore> {
    crate::secrets::get("gmail-oauth")
        .and_then(|s| serde_json::from_str::<OAuthStore>(&s).ok())
        .filter(|o| !o.refresh_token.is_empty())
}

fn save(store: &OAuthStore) -> Result<(), String> {
    let text = serde_json::to_string(store).map_err(|e| e.to_string())?;
    crate::secrets::set("gmail-oauth", &text)
}

fn creds() -> Option<(String, String)> {
    let id = crate::secrets::get("gmail-client-id").filter(|v| !v.is_empty())?;
    let secret = crate::secrets::get("gmail-client-secret").filter(|v| !v.is_empty())?;
    Some((id, secret))
}

pub fn has_oauth() -> bool {
    load().is_some()
}

fn client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())
}

/// Exchange one refresh for a fresh access token and persist it.
async fn refresh(client_id: &str, client_secret: &str, refresh_token: &str) -> Result<String, String> {
    let http = client()?;
    let response = http
        .post(TOKEN_URL)
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token),
            ("client_id", client_id),
            ("client_secret", client_secret),
        ])
        .send()
        .await
        .map_err(|e| format!("token refresh: network error: {e}"))?;
    if !response.status().is_success() {
        let detail = response.text().await.unwrap_or_default();
        let short: String = detail.chars().take(160).collect();
        return Err(format!("token refresh failed ({short}). Sign in again."));
    }
    let body: Value = response.json().await.map_err(|e| format!("token refresh: {e}"))?;
    let access = body
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "token refresh: no access token".to_string())?;
    let expires_in = body.get("expires_in").and_then(Value::as_u64).unwrap_or(3600);
    let mut store = load().unwrap_or_default();
    store.access_token = access.to_string();
    store.expires_at = now_unix().saturating_add(expires_in.saturating_sub(120));
    save(&store)?;
    Ok(access.to_string())
}

async fn access_token() -> Result<String, String> {
    let store = load().ok_or_else(|| "not signed in".to_string())?;
    if !store.access_token.is_empty() && store.expires_at > now_unix() + 60 {
        return Ok(store.access_token);
    }
    let (id, secret) =
        creds().ok_or_else(|| "OAuth client id/secret missing".to_string())?;
    refresh(&id, &secret, &store.refresh_token).await
}

async fn get_json(url: &str, token: &str) -> Result<Value, String> {
    let http = client()?;
    let response = http
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| format!("Gmail API: network error: {e}"))?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if status.as_u16() == 401 {
        return Err("unauthorized".into());
    }
    if !status.is_success() {
        let short: String = text.chars().take(160).collect();
        return Err(format!("Gmail API {status}: {short}"));
    }
    serde_json::from_str(&text).map_err(|e| format!("Gmail API: bad response: {e}"))
}

fn header(payload: &Value, name: &str) -> String {
    payload
        .get("payload")
        .and_then(|p| p.get("headers"))
        .and_then(Value::as_array)
        .and_then(|hs| {
            hs.iter().find(|h| {
                h.get("name")
                    .and_then(Value::as_str)
                    .map(|n| n.eq_ignore_ascii_case(name))
                    .unwrap_or(false)
            })
        })
        .and_then(|h| h.get("value"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

/// Unread count + newest subjects over REST. Counts only mail actually
/// fetched (`in:inbox`, recent first) — never the server's estimate, which
/// happily reports years of archived unread. 401 refreshes once and retries.
pub async fn unread() -> Result<MailboxState, String> {
    let token = access_token().await?;
    let list_url = format!(
        "{API_ME}/messages?q=is%3Aunread+in%3Ainbox+newer_than%3A30d&maxResults=20"
    );
    let list = match get_json(&list_url, &token).await {
        Err(e) if e == "unauthorized" => {
            let store = load().ok_or_else(|| "not signed in".to_string())?;
            let (id, secret) =
                creds().ok_or_else(|| "OAuth client id/secret missing".to_string())?;
            let fresh = refresh(&id, &secret, &store.refresh_token).await?;
            get_json(&list_url, &fresh).await?
        }
        other => other?,
    };
    let ids: Vec<String> = list
        .get("messages")
        .and_then(Value::as_array)
        .map(|ms| {
            ms.iter()
                .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_string))
                .take(20)
                .collect()
        })
        .unwrap_or_default();
    let unread = ids.len() as u32;

    let token2 = access_token().await?;
    let mut latest = Vec::new();
    for id in ids.into_iter().take(3) {
        let url = format!(
            "{API_ME}/messages/{id}?format=metadata&metadataHeaders=Subject&metadataHeaders=From"
        );
        if let Ok(msg) = get_json(&url, &token2).await {
            let subject = header(&msg, "Subject");
            let from = header(&msg, "From");
            latest.push(MailItem {
                from: if from.is_empty() { "?".into() } else { from },
                subject: if subject.is_empty() { "(no subject)".into() } else { subject },
            });
        }
    }
    Ok(MailboxState { unread, latest })
}

/// Full interactive sign-in: opens the browser, waits for the redirect,
/// exchanges the code and stores the tokens. Returns the account address.
pub async fn signin(client_id: String, client_secret: String) -> Result<String, String> {
    let client_id = client_id.trim().to_string();
    let client_secret = client_secret.trim().to_string();
    if client_id.is_empty() || client_secret.is_empty() {
        return Err("paste the OAuth client ID and secret first".into());
    }
    crate::secrets::set("gmail-client-id", &client_id)?;
    crate::secrets::set("gmail-client-secret", &client_secret)?;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("cannot listen locally: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let redirect = format!("http://127.0.0.1:{port}{REDIRECT_PATH}");

    let auth = format!(
        "{AUTH_URL}?client_id={id}&redirect_uri={redir}&response_type=code\
         &scope={scope}&access_type=offline&prompt=consent",
        id = urlencode(&client_id),
        redir = urlencode(&redirect),
        scope = urlencode(SCOPE),
    );
    open_browser(&auth);

    // One redirect hit, then done. The browser tab shows a plain confirmation.
    let accept = tokio::time::timeout(std::time::Duration::from_secs(180), listener.accept())
        .await
        .map_err(|_| "timed out waiting for the browser — click Sign in again".to_string())?;
    let (mut socket, _) =
        accept.map_err(|e| format!("local redirect failed: {e}"))?;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut buf = [0u8; 8192];
    let n = socket.read(&mut buf).await.unwrap_or(0);
    let request = String::from_utf8_lossy(&buf[..n]).into_owned();
    let done_page = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\
        <html><body style=\"font-family:sans-serif;padding:40px\">\
        <h2>Signed in — back to Coucou ✅</h2><p>You can close this tab.</p></body></html>";
    let _ = socket.write_all(done_page.as_bytes()).await;

    let code = parse_query(&request, "code")
        .ok_or_else(|| {
            parse_query(&request, "error")
                .map(|e| format!("Google refused: {e}"))
                .unwrap_or_else(|| "no code in the redirect".to_string())
        })?;

    let http = client()?;
    let response = http
        .post(TOKEN_URL)
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code.as_str()),
            ("client_id", client_id.as_str()),
            ("client_secret", client_secret.as_str()),
            ("redirect_uri", redirect.as_str()),
        ])
        .send()
        .await
        .map_err(|e| format!("code exchange: network error: {e}"))?;
    if !response.status().is_success() {
        let detail = response.text().await.unwrap_or_default();
        let short: String = detail.chars().take(200).collect();
        return Err(format!("code exchange failed: {short}"));
    }
    let body: Value = response.json().await.map_err(|e| format!("code exchange: {e}"))?;
    let access = body
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "code exchange: no access token".to_string())?
        .to_string();
    let refresh_token = body
        .get("refresh_token")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            "Google did not return a refresh token — remove Coucou's access at \
             myaccount.google.com/permissions and sign in again"
                .to_string()
        })?
        .to_string();
    let expires_in = body.get("expires_in").and_then(Value::as_u64).unwrap_or(3600);
    save(&OAuthStore {
        refresh_token,
        access_token: access.clone(),
        expires_at: now_unix().saturating_add(expires_in.saturating_sub(120)),
    })?;

    let profile: Value = get_json(&format!("{API_ME}/profile"), &access).await?;
    let email = profile
        .get("emailAddress")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Ok(email)
}

pub fn signout() -> Result<(), String> {
    crate::secrets::clear("gmail-oauth")
}

fn parse_query(request: &str, key: &str) -> Option<String> {
    let line = request.lines().next()?;
    let path = line.split_whitespace().nth(1)?;
    let query = path.split_once('?')?.1;
    for pair in query.split('&') {
        let (k, v) = pair.split_once('=')?;
        if k == key {
            return Some(urldecode(v));
        }
    }
    None
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn urldecode(s: &str) -> String {
    let mut bytes = Vec::with_capacity(s.len());
    let mut it = s.bytes();
    while let Some(b) = it.next() {
        match b {
            b'%' => {
                let hi = it.next().unwrap_or(b'0');
                let lo = it.next().unwrap_or(b'0');
                let hex = |c: u8| (c as char).to_digit(16).unwrap_or(0) as u8;
                bytes.push(hex(hi) * 16 + hex(lo));
            }
            b'+' => bytes.push(b' '),
            _ => bytes.push(b),
        }
    }
    String::from_utf8_lossy(&bytes).into_owned()
}

fn open_browser(url: &str) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let _ = std::process::Command::new("rundll32.exe")
        .args(["url.dll,FileProtocolHandler", url])
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
}
