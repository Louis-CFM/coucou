// Outlook over Microsoft Graph with per-user OAuth — the path for accounts
// where basic auth (and therefore IMAP app passwords) is disabled by
// Microsoft. Same shape as the Gmail module, but the sign-in uses the
// *device code* flow instead of a localhost redirect:
//
// 1. POST .../devicecode {client_id, scope} → user code + verification URL.
// 2. The user approves in any browser (even the phone).
// 3. This call polls .../token until the grant lands (up to ~3 min), then
//    stores refresh + access + expiry in the Credential Manager.
//
// Device flow needs no redirect URI registered and no client secret: the app
// registration is a public client ("Mobile and desktop applications") with
// the delegated Mail.Read scope. Everything rides on HTTPS/443.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::mail::{MailItem, MailboxState};

const TENANT: &str = "consumers";
const SCOPE: &str = "offline_access Mail.Read";

fn device_url() -> String {
    format!("https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/devicecode")
}

fn token_url() -> String {
    format!("https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token")
}

const GRAPH_LIST: &str = "https://graph.microsoft.com/v1.0/me/messages\
    ?$filter=isRead%20eq%20false&$orderby=receivedDateTime%20desc&$top=10\
    &$select=id,subject,from,receivedDateTime";

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
    crate::secrets::get("outlook-oauth")
        .and_then(|s| serde_json::from_str::<OAuthStore>(&s).ok())
        .filter(|o| !o.refresh_token.is_empty())
}

fn save(store: &OAuthStore) -> Result<(), String> {
    let text = serde_json::to_string(store).map_err(|e| e.to_string())?;
    crate::secrets::set("outlook-oauth", &text)
}

fn client_id() -> Option<String> {
    crate::secrets::get("outlook-client-id").filter(|v| !v.is_empty())
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

async fn refresh(client_id: &str, refresh_token: &str) -> Result<String, String> {
    let http = client()?;
    let response = http
        .post(token_url())
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", client_id),
            ("refresh_token", refresh_token),
            ("scope", SCOPE),
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
    apply_tokens(&body)
}

fn apply_tokens(body: &Value) -> Result<String, String> {
    let access = body
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "token response: no access token".to_string())?
        .to_string();
    let expires_in = body.get("expires_in").and_then(Value::as_u64).unwrap_or(3600);
    let mut store = load().unwrap_or_default();
    if let Some(refresh) = body.get("refresh_token").and_then(Value::as_str) {
        if !refresh.is_empty() {
            store.refresh_token = refresh.to_string();
        }
    }
    store.access_token = access.clone();
    store.expires_at = now_unix().saturating_add(expires_in.saturating_sub(120));
    save(&store)?;
    Ok(access)
}

async fn access_token() -> Result<String, String> {
    let store = load().ok_or_else(|| "not signed in".to_string())?;
    if !store.access_token.is_empty() && store.expires_at > now_unix() + 60 {
        return Ok(store.access_token);
    }
    let id = client_id().ok_or_else(|| "OAuth client ID missing".to_string())?;
    refresh(&id, &store.refresh_token).await
}

async fn get_json(url: &str, token: &str) -> Result<Value, String> {
    let http = client()?;
    let response = http
        .get(url)
        .bearer_auth(token)
        .header("Accept", "application/json")
        .send()
        .await
        .map_err(|e| format!("Outlook API: network error: {e}"))?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if status.as_u16() == 401 {
        return Err("unauthorized".into());
    }
    if !status.is_success() {
        let short: String = text.chars().take(160).collect();
        return Err(format!("Outlook API {status}: {short}"));
    }
    serde_json::from_str(&text).map_err(|e| format!("Outlook API: bad response: {e}"))
}

fn sender(msg: &Value) -> String {
    msg.get("from")
        .and_then(|f| f.get("emailAddress"))
        .and_then(|e| {
            e.get("name")
                .and_then(Value::as_str)
                .filter(|n| !n.is_empty())
                .map(str::to_string)
                .or_else(|| {
                    e.get("address").and_then(Value::as_str).map(str::to_string)
                })
        })
        .unwrap_or_else(|| "?".into())
}

/// Unread count + newest subjects over Graph. 401 refreshes once and retries.
pub async fn unread() -> Result<MailboxState, String> {
    let token = access_token().await?;
    let list = match get_json(GRAPH_LIST, &token).await {
        Err(e) if e == "unauthorized" => {
            let store = load().ok_or_else(|| "not signed in".to_string())?;
            let id = client_id().ok_or_else(|| "OAuth client ID missing".to_string())?;
            let fresh = refresh(&id, &store.refresh_token).await?;
            get_json(GRAPH_LIST, &fresh).await?
        }
        other => other?,
    };
    let items = list.get("value").and_then(Value::as_array).cloned().unwrap_or_default();
    let unread = items.len() as u32;
    let latest = items
        .into_iter()
        .take(3)
        .map(|m| MailItem {
            from: sender(&m),
            subject: m
                .get("subject")
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| "(no subject)".into()),
        })
        .collect();
    Ok(MailboxState { unread, latest })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceChallenge {
    pub user_code: String,
    pub verification_url: String,
}

/// Begins device-flow sign-in: persists the client id, asks Microsoft for a
/// user code, stashes the device code and returns what the user must approve.
/// Call `poll_device` afterwards to wait for the grant.
pub async fn begin_device(client_id: String) -> Result<DeviceChallenge, String> {
    let client_id = client_id.trim().to_string();
    if client_id.is_empty() {
        return Err("paste the OAuth client (application) ID first".into());
    }
    crate::secrets::set("outlook-client-id", &client_id)?;
    let http = client()?;
    let response = http
        .post(device_url())
        .form(&[("client_id", client_id.as_str()), ("scope", SCOPE)])
        .send()
        .await
        .map_err(|e| format!("device flow: network error: {e}"))?;
    if !response.status().is_success() {
        let detail = response.text().await.unwrap_or_default();
        let short: String = detail.chars().take(200).collect();
        return Err(format!("device flow refused: {short} (check the client ID)"));
    }
    let body: Value = response.json().await.map_err(|e| format!("device flow: {e}"))?;
    let user_code = body
        .get("user_code")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    // verification_uri_complete embeds the code — one click, no typing.
    let url = body
        .get("verification_uri_complete")
        .and_then(Value::as_str)
        .or_else(|| body.get("verification_uri").and_then(Value::as_str))
        .unwrap_or("https://aka.ms/devicelogin")
        .to_string();
    if user_code.is_empty() {
        return Err("device flow: no user code".into());
    }
    let device_code = body
        .get("device_code")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    crate::secrets::set("outlook-device-code", &device_code)?;
    Ok(DeviceChallenge { user_code, verification_url: url })
}

/// Polls for the grant after the user approves (up to ~3 min). Stores tokens
/// and returns silently; the pill picks them up on the next poll.
pub async fn poll_device() -> Result<(), String> {
    let id: String = client_id().ok_or_else(|| "paste the OAuth client (application) ID first".to_string())?;
    // The device_code must survive between begin and poll: keep it in the
    // Credential Manager under a transient key.
    let device_code = crate::secrets::get("outlook-device-code")
        .filter(|v| !v.is_empty())
        .ok_or_else(|| "start the sign-in first".to_string())?;
    let http = client()?;
    let deadline = now_unix().saturating_add(180);
    loop {
        let response = http
            .post(token_url())
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ("client_id", id.as_str()),
                ("device_code", device_code.as_str()),
            ])
            .send()
            .await
            .map_err(|e| format!("device poll: network error: {e}"))?;
        if response.status().is_success() {
            let body: Value = response.json().await.map_err(|e| format!("device poll: {e}"))?;
            apply_tokens(&body)?;
            let _ = crate::secrets::clear("outlook-device-code");
            return Ok(());
        }
        let detail = response.text().await.unwrap_or_default();
        if !(detail.contains("authorization_pending") || detail.contains("slow_down")) {
            let short: String = detail.chars().take(200).collect();
            return Err(format!("sign-in failed: {short}"));
        }
        if now_unix() >= deadline {
            return Err("timed out waiting for approval — the code stays valid ~15 min, click again".into());
        }
        let wait = if detail.contains("slow_down") { 10 } else { 5 };
        tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
    }
}

pub fn signout() -> Result<(), String> {
    crate::secrets::clear("outlook-oauth")?;
    let _ = crate::secrets::clear("outlook-device-code");
    Ok(())
}
