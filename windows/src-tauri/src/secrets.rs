// API keys live in the Windows Credential Manager or, on Linux, the Secret
// Service (GNOME Keyring, KWallet) — never on disk and never in the front end — the island can only ask whether a key is present.

use std::collections::BTreeMap;
use std::sync::Mutex;

use keyring::Entry;

const SERVICE: &str = "fr.louisraille.coucou";

/// Every key Coucou may store. Anything outside this list is refused.
pub const KNOWN_KEYS: &[&str] = &[
    "anthropic-api-key",
    "openai-api-key",
    "google-api-key",
    "openrouter-api-key",
    "openai-compatible-key",
    "cursor-api-key",
    "n8n-url",
    "n8n-api-key",
    "vercel-token",
    "github-token",
    "stripe-api-key",
    "resend-api-key",
    "resend-from",
    "notion-api-key",
    "calcom-api-key",
    // The shared secret the Android companion proves on every relay call.
    "phone-secret",
    // « OK Coucou »'s answers in an ElevenLabs voice.
    "elevenlabs-api-key",
    // ... or in a Fish Audio voice.
    "fish-audio-api-key",
];

/// The credential name for an OpenAI-compatible endpoint's key (the media and
/// voice models): one per host, so every model of the same provider (all your
/// Groq models, say) shares it, and a key only ever goes to its own host.
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

/// What the keychain answered, by key: pollers and the phone loop ask every
/// few seconds, and only `set` and `clear` (both below) change a key. An answer
/// the keychain could not give (locked, unreachable) is not kept. Dynamic
/// `key:{host}` endpoint keys skip it: a name made at runtime is no `&'static`.
struct Cache(Mutex<BTreeMap<&'static str, Option<String>>>);

impl Cache {
    const fn new() -> Self {
        Self(Mutex::new(BTreeMap::new()))
    }

    fn get_or(&self, key: &'static str, load: impl FnOnce() -> Result<Option<String>, ()>) -> Option<String> {
        if let Some(v) = self.0.lock().unwrap_or_else(|e| e.into_inner()).get(key) {
            return v.clone();
        }
        let v = load().ok()?;
        self.0.lock().unwrap_or_else(|e| e.into_inner()).insert(key, v.clone());
        v
    }

    fn put(&self, key: &'static str, value: Option<String>) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).insert(key, value);
    }
}

static CACHE: Cache = Cache::new();

fn known(key: &str) -> Option<&'static str> {
    KNOWN_KEYS.iter().copied().find(|k| *k == key)
}

pub fn get(key: &str) -> Option<String> {
    match known(key) {
        Some(key) => CACHE.get_or(key, || match entry(key).ok_or(())?.get_password() {
            Ok(v) => Ok(Some(v).filter(|v| !v.is_empty())),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => Err(()),
        }),
        None => entry(key)?.get_password().ok().filter(|v| !v.is_empty()),
    }
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    if value.is_empty() {
        let _ = entry.delete_credential();
        if let Some(key) = known(key) {
            CACHE.put(key, None);
        }
        return Ok(());
    }
    entry.set_password(value).map_err(|e| e.to_string())?;
    if let Some(key) = known(key) {
        CACHE.put(key, Some(value.to_string()));
    }
    Ok(())
}

pub fn clear(key: &str) -> Result<(), String> {
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => {
            if let Some(key) = known(key) {
                CACHE.put(key, None);
            }
            Ok(())
        }
        Err(e) => Err(e.to_string()),
    }
}


pub fn present(key: &str) -> bool {
    get(key).is_some()
}

// ── Entries only Rust reads and writes ───────────────────────────────────────
//
// The phone link's certificate, key and pairing token, and the relay's room, end-to-end key and access key.
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
    fn a_key_is_asked_of_the_keychain_once() {
        let cache = Cache::new();
        let mut asked = 0;
        for _ in 0..3 {
            let v = cache.get_or("github-token", || {
                asked += 1;
                Ok(Some("ghp_x".into()))
            });
            assert_eq!(v.as_deref(), Some("ghp_x"));
        }
        assert_eq!(asked, 1);
    }

    #[test]
    fn a_keychain_that_could_not_answer_is_asked_again() {
        // A locked Secret Service at login must not hide the key until restart.
        let cache = Cache::new();
        assert_eq!(cache.get_or("vercel-token", || Err(())), None);
        assert_eq!(cache.get_or("vercel-token", || Ok(Some("v".into()))).as_deref(), Some("v"));
    }

    #[test]
    fn set_and_clear_replace_what_was_cached() {
        let cache = Cache::new();
        let _ = cache.get_or("n8n-url", || Ok(None));
        cache.put("n8n-url", Some("https://n8n.example".into()));
        assert_eq!(cache.get_or("n8n-url", || panic!("cached")).as_deref(), Some("https://n8n.example"));
        cache.put("n8n-url", None);
        assert_eq!(cache.get_or("n8n-url", || panic!("cached")), None);
    }

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

    #[test]
    fn the_phone_links_secrets_cannot_be_reached_from_the_island() {
        // The island's commands go through `get`/`set`/`clear`/`present`, which
        // only know KNOWN_KEYS.
        for key in INTERNAL_KEYS {
            assert!(!KNOWN_KEYS.contains(key), "{key}");
            assert!(known(key).is_none(), "{key}");
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
