// API keys live in the Windows Credential Manager or, on Linux, the Secret
// Service (GNOME Keyring, KWallet) — never on disk and never in the front end — the island can only ask whether a key is present.

use keyring::Entry;

const SERVICE: &str = "fr.louisraille.coucou";

/// Every key Coucou may store. Anything outside this list is refused.
pub const KNOWN_KEYS: &[&str] = &[
    "anthropic-api-key",
    "custom-api-key",
    "n8n-url",
    "n8n-api-key",
    "vercel-token",
    "github-token",
    "stripe-api-key",
    "resend-api-key",
    "notion-api-key",
    "calcom-api-key",
];

/// The Credential Manager name for an OpenAI-compatible endpoint's key: one per
/// host, so every model of the same provider (all your Groq models, say) shares it.
pub fn endpoint_key(endpoint: &str) -> String {
    let trimmed = endpoint.trim();
    let rest = trimmed.split("://").nth(1).unwrap_or(trimmed);
    let host: String = rest
        .split('/')
        .next()
        .unwrap_or("")
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || ".:-".contains(*c))
        .take(100)
        .collect();
    format!("key:{host}")
}

/// Known keys, or a provider key made by `endpoint_key`.
fn allowed(key: &str) -> bool {
    KNOWN_KEYS.contains(&key)
        || key.strip_prefix("key:").is_some_and(|host| {
            !host.is_empty()
                && host.len() <= 100
                && host.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || ".:-".contains(c))
        })
}

fn entry(key: &str) -> Option<Entry> {
    if !allowed(key) {
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

#[cfg(test)]
mod tests {
    use super::{allowed, endpoint_key};

    #[test]
    fn provider_keys_are_per_host_and_validated() {
        assert_eq!(endpoint_key("https://api.groq.com/openai/v1"), "key:api.groq.com");
        assert_eq!(endpoint_key("http://localhost:11434/v1/"), "key:localhost:11434");
        assert_eq!(endpoint_key("integrate.api.nvidia.com/v1"), "key:integrate.api.nvidia.com");
        assert!(allowed("key:api.groq.com"));
        assert!(allowed("github-token"));
        assert!(!allowed("key:"));
        assert!(!allowed("key:EVIL/../x"));
        assert!(!allowed("random"));
    }
}
