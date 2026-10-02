// API keys live in the Windows Credential Manager or, on Linux, the Secret
// Service (GNOME Keyring, KWallet) — never on disk and never in the front end — the island can only ask whether a key is present.

use keyring::Entry;

const SERVICE: &str = "fr.louisraille.coucou";

/// Every key Coucou may store. Anything outside this list is refused.
pub const KNOWN_KEYS: &[&str] = &[
    "anthropic-api-key",
    "n8n-url",
    "n8n-api-key",
    "vercel-token",
    "github-token",
    "stripe-api-key",
    "resend-api-key",
    "notion-api-key",
    "calcom-api-key",
];

/// Provider credentials live under `provider-<id>`. Accepting the prefix is the one
/// widening of the allowlist, and it stays bounded: the suffix must name a provider
/// Coucou can actually route to, so the UI still cannot invent a key name. Anything
/// else — an integration key, a bare string, a non-routable provider — is refused.
const PROVIDER_PREFIX: &str = "provider-";

fn provider_entry(id: &str) -> Option<Entry> {
    let key = id.strip_prefix(PROVIDER_PREFIX)?;
    if !crate::providers::is_routable(key) {
        return None;
    }
    Entry::new(SERVICE, id).ok()
}

fn entry(key: &str) -> Option<Entry> {
    if KNOWN_KEYS.contains(&key) {
        return Entry::new(SERVICE, key).ok();
    }
    provider_entry(key)
}

/// The Anthropic key used to live at `anthropic-api-key` before providers existed.
/// Coucou is young and nobody depends on the old name, but silently orphaning a key
/// the user already typed is the kind of thing that reads as data loss — so the old
/// name is read as a fallback for Anthropic only.
fn legacy_for(key: &str) -> Option<&'static str> {
    match key {
        "provider-anthropic" => Some("anthropic-api-key"),
        _ => None,
    }
}

pub fn get(key: &str) -> Option<String> {
    let stored = entry(key)?.get_password().ok().filter(|v| !v.is_empty());
    if stored.is_some() {
        return stored;
    }
    let legacy = legacy_for(key).and_then(|old| {
        Entry::new(SERVICE, old)
            .ok()?
            .get_password()
            .ok()
            .filter(|v| !v.is_empty())
    });
    legacy
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
