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
];

/// What the keychain answered, by key: pollers and the phone loop ask every
/// few seconds, and only `set` and `clear` (both below) change a key. An answer
/// the keychain could not give (locked, unreachable) is not kept.
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

fn entry(key: &'static str) -> Option<Entry> {
    Entry::new(SERVICE, key).ok()
}

pub fn get(key: &str) -> Option<String> {
    let key = known(key)?;
    CACHE.get_or(key, || match entry(key).ok_or(())?.get_password() {
        Ok(v) => Ok(Some(v).filter(|v| !v.is_empty())),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err(()),
    })
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    let key = known(key).ok_or_else(|| format!("unknown key {key}"))?;
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    if value.is_empty() {
        let _ = entry.delete_credential();
        CACHE.put(key, None);
        return Ok(());
    }
    entry.set_password(value).map_err(|e| e.to_string())?;
    CACHE.put(key, Some(value.to_string()));
    Ok(())
}

pub fn clear(key: &str) -> Result<(), String> {
    let key = known(key).ok_or_else(|| format!("unknown key {key}"))?;
    let entry = entry(key).ok_or_else(|| format!("unknown key {key}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => {
            CACHE.put(key, None);
            Ok(())
        }
        Err(e) => Err(e.to_string()),
    }
}

pub fn present(key: &str) -> bool {
    get(key).is_some()
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
}
