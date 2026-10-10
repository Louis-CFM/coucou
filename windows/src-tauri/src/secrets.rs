// API keys live in the Windows Credential Manager or, on Linux, the Secret
// Service (GNOME Keyring, KWallet) — never on disk and never in the front end — the island can only ask whether a key is present.

use keyring::Entry;

const SERVICE: &str = "fr.louisraille.coucou";

/// Every key Coucou may store. Anything outside this list is refused.
pub const KNOWN_KEYS: &[&str] = &[
    "anthropic-api-key",
    "openai-api-key",
    "google-api-key",
    "openrouter-api-key",
    "openai-compatible-key",
    "n8n-url",
    "n8n-api-key",
    "vercel-token",
    "github-token",
    "stripe-api-key",
    "resend-api-key",
    "notion-api-key",
    "calcom-api-key",
];

fn entry(key: &str) -> Option<Entry> {
    if !KNOWN_KEYS.contains(&key) {
        return None;
    }
    Entry::new(SERVICE, key).ok()
}

pub fn get(key: &str) -> Option<String> {
    let stored = entry(key).and_then(|e| e.get_password().ok()).filter(|v| !v.is_empty());
    if stored.is_none() && key == "github-token" {
        return gh_cli_token();
    }
    stored
}

// ── GitHub CLI login ──────────────────────────────────────────────────────────
//
// With no GitHub token stored, the pill uses the login of the user's own `gh`
// (`gh auth token`), asked each time it is needed, kept in memory for a few
// minutes and never written anywhere: it is only ever sent to api.github.com,
// like the stored one. A token stored in Settings always wins.
// COUCOU_GH_CLI=0 turns this off.

#[cfg(unix)]
fn gh_cli_token() -> Option<String> {
    use std::process::{Command, Stdio};
    use std::sync::Mutex;
    use std::time::{Duration, Instant};

    static CACHE: Mutex<Option<(Instant, Option<String>)>> = Mutex::new(None);
    const FOUND_FOR: Duration = Duration::from_secs(600);
    const MISSING_FOR: Duration = Duration::from_secs(60);

    if std::env::var("COUCOU_GH_CLI").is_ok_and(|v| v == "0") {
        return None;
    }
    let mut cache = CACHE.lock().ok()?;
    if let Some((at, token)) = cache.as_ref() {
        let ttl = if token.is_some() { FOUND_FOR } else { MISSING_FOR };
        if at.elapsed() < ttl {
            return token.clone();
        }
    }
    let token = Command::new("gh")
        .args(["auth", "token", "--hostname", "github.com"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty() && t.len() < 512 && t.bytes().all(|b| b.is_ascii_graphic()));
    *cache = Some((Instant::now(), token.clone()));
    token
}

#[cfg(not(unix))]
fn gh_cli_token() -> Option<String> {
    None
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    if value.is_empty() {
        let _ = entry.delete_credential();
        return Ok(());
    }
    entry.set_password(value).map_err(|e| e.to_string())
}

pub fn clear(key: &str) -> Result<(), String> {
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

pub fn present(key: &str) -> bool {
    get(key).is_some()
}
