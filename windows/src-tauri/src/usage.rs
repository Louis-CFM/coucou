// Claude plan usage — the "current session" (5 h) and weekly windows that
// Claude Code shows in /usage, polled for the overview card.
//
// The only request is to api.anthropic.com, with the OAuth token Claude Code
// already keeps in %USERPROFILE%\.claude\.credentials.json. The token is read on
// every poll, never copied, logged or sent anywhere else. No credentials file
// (API-key users, Claude Code not signed in) means no request at all.

use std::sync::atomic::Ordering;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, Emitter};

use crate::integrations::PAUSED;
use crate::island::WINDOW_LABEL;
use crate::log;

const URL: &str = "https://api.anthropic.com/api/oauth/usage";
const FIRST_DELAY: Duration = Duration::from_secs(4);
const EVERY: Duration = Duration::from_secs(300);
/// After a 429 the endpoint wants us gone for a while.
const BACKOFF: Duration = Duration::from_secs(900);

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    /// 0–1.
    pub used: f64,
    /// ISO 8601, as the API returns it.
    pub resets_at: Option<String>,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct UsagePayload {
    pub session: Option<UsageWindow>,
    pub weekly: Option<UsageWindow>,
    pub error: Option<String>,
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(FIRST_DELAY).await;
        loop {
            let wait = if PAUSED.load(Ordering::Relaxed) { EVERY } else { poll(&app).await };
            tokio::time::sleep(wait).await;
        }
    });
}

fn access_token() -> Option<String> {
    let home = std::env::var_os("USERPROFILE")?;
    let path = std::path::Path::new(&home).join(".claude").join(".credentials.json");
    let text = std::fs::read_to_string(path).ok()?;
    let json: Value = serde_json::from_str(&text).ok()?;
    json.pointer("/claudeAiOauth/accessToken")?.as_str().map(str::to_owned)
}

fn window(json: &Value, key: &str) -> Option<UsageWindow> {
    let w = json.get(key)?;
    let pct = w.get("utilization")?.as_f64()?;
    Some(UsageWindow {
        used: (pct / 100.0).clamp(0.0, 1.0),
        resets_at: w.get("resets_at").and_then(Value::as_str).map(str::to_owned),
    })
}

fn emit_error(app: &AppHandle, msg: &str) {
    let _ = app.emit_to(
        WINDOW_LABEL,
        "claude-usage",
        UsagePayload { session: None, weekly: None, error: Some(msg.to_owned()) },
    );
}

/// One poll; returns how long to wait before the next one.
async fn poll(app: &AppHandle) -> Duration {
    let Some(token) = access_token() else {
        emit_error(app, "Sign in to Claude Code to see usage");
        return EVERY;
    };
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap_or_default();
    let res = client
        .get(URL)
        .bearer_auth(token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .send()
        .await;
    let res = match res {
        Ok(r) => r,
        Err(err) => {
            log::line(format!("claude usage: request failed ({})", err.without_url()));
            emit_error(app, "Usage unavailable — offline?");
            return EVERY;
        }
    };
    let status = res.status().as_u16();
    if status == 429 {
        return BACKOFF;
    }
    if status == 401 || status == 403 {
        emit_error(app, "Claude Code session expired — run claude to sign in again");
        return EVERY;
    }
    if !(200..300).contains(&status) {
        log::line(format!("claude usage: HTTP {status}"));
        emit_error(app, "Usage unavailable");
        return EVERY;
    }
    let Ok(json) = res.json::<Value>().await else {
        emit_error(app, "Usage unavailable");
        return EVERY;
    };
    let _ = app.emit_to(
        WINDOW_LABEL,
        "claude-usage",
        UsagePayload {
            session: window(&json, "five_hour"),
            weekly: window(&json, "seven_day"),
            error: None,
        },
    );
    EVERY
}
