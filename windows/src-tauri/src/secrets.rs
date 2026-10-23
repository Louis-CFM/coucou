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
    "gitlab-url",
    "gitlab-token",
    "gitea-url",
    "gitea-token",
    "stripe-api-key",
    "resend-api-key",
    "notion-api-key",
    "calcom-api-key",
    // « OK Coucou »'s answers in an ElevenLabs voice.
    "elevenlabs-api-key",
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

// ── Entries only Rust reads and writes ───────────────────────────────────────
//
// The phone link's certificate, key and pairing token, the relay's room, end-to-end key and access key,
// and WhatsApp's gateway address, credential and webhook secret.
// They are not in KNOWN_KEYS
// on purpose: the island has `secret_present` / `secret_set` / `secret_clear`
// for those, and none of the three may be reachable from a webview.

/// Every entry of that kind. Anything outside this list is refused.
pub const INTERNAL_KEYS: &[&str] = &[
    "phone-link-cert",
    "phone-link-key",
    "phone-link-token",
    "phone-relay-room",
    "phone-relay-key",
    "phone-relay-access",
    // WhatsApp's gateway address, its credential (GOWA's user:password or OpenWA's API key) and
    // the webhook's signing secret: set from Settings through whatsapp_save_gateway, read by Rust only.
    "whatsapp-url",
    "whatsapp-api-key",
    "whatsapp-webhook-secret",
];

/// Whether the keystore would accept this key through `get_internal` / `set_internal`.
pub fn is_internal(key: &str) -> bool {
    INTERNAL_KEYS.contains(&key)
}

fn internal_entry(key: &str) -> Result<Entry, String> {
    if !is_internal(key) {
        return Err(format!("unknown key {key}"));
    }
    Entry::new(SERVICE, key).map_err(|e| e.to_string())
}

pub fn get_internal(key: &str) -> Option<String> {
    internal_entry(key).ok()?.get_password().ok().filter(|v| !v.is_empty())
}

pub fn set_internal(key: &str, value: &str) -> Result<(), String> {
    let entry = internal_entry(key)?;
    if value.is_empty() {
        // An empty value means "forget it" (the relay's access key); some keystores refuse an empty password.
        return match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        };
    }
    entry.set_password(value).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_phone_links_secrets_cannot_be_reached_from_the_island() {
        // The island's commands go through `get`/`set`/`clear`/`present`, which
        // only know KNOWN_KEYS.
        for key in INTERNAL_KEYS {
            assert!(!KNOWN_KEYS.contains(key), "{key}");
            assert!(entry(key).is_none(), "{key}");
            assert!(set(key, "x").is_err(), "{key}");
            assert!(clear(key).is_err(), "{key}");
            assert!(!present(key), "{key}");
        }
        // And the other way round: a key of the island is not an internal one.
        assert!(set_internal("github-token", "x").is_err());
    }

    /// Windows Credential Manager caps a secret's size. The phone link stores its certificate (about
    /// 600 hex characters) and key there, so prove that a secret of that size round-trips through the
    /// real store. A separate service name: this can never touch a user's real entries.
    #[cfg(windows)]
    #[test]
    fn a_certificate_sized_secret_round_trips_through_credential_manager() {
        let entry = keyring::Entry::new("fr.louisraille.coucou.test", "phone-link-size-check").unwrap();
        let big: String = (0..1_200).map(|i| char::from(b"0123456789abcdef"[i % 16])).collect();
        entry.set_password(&big).expect("Credential Manager refused a certificate-sized secret");
        let back = entry.get_password().expect("could not read it back");
        let _ = entry.delete_credential();
        assert_eq!(back, big);
    }
}
