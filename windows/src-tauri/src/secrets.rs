// API keys live in the Windows Credential Manager, never on disk and never in
// the front end — the island can only ask whether a key is present.

use keyring::Entry;

const SERVICE: &str = "fr.louisraille.coucou";

/// Every key Coucou may store. Anything outside this list is refused.
pub const KNOWN_KEYS: &[&str] = &[
    "anthropic-api-key",
    "gemini-api-key",
    "gmail-email",
    "gmail-app-password",
    "gmail-client-id",
    "gmail-client-secret",
    "gmail-oauth",
    "outlook-email",
    "outlook-app-password",
    "outlook-client-id",
    "outlook-oauth",
    "outlook-oauth-2",
    "outlook-oauth-3",
    "outlook-oauth-4",
    "outlook-oauth-5",
    "outlook-oauth-6",
    "outlook-oauth-7",
    "outlook-oauth-8",
    "outlook-refresh-token",
    "outlook-refresh-token-2",
    "outlook-refresh-token-3",
    "outlook-refresh-token-4",
    "outlook-refresh-token-5",
    "outlook-refresh-token-6",
    "outlook-refresh-token-7",
    "outlook-refresh-token-8",
    "outlook-device-code",
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
    entry(key)?.get_password().ok().filter(|v| !v.is_empty())
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
