// API keys live in the Windows Credential Manager or, on Linux, the Secret
// Service (GNOME Keyring, KWallet) — never on disk and never in the front end — the island can only ask whether a key is present.

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

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

/// Whether each key is stored, as last seen. Each Secret Service lookup opens a
/// D-Bus session of its own (tens of milliseconds), and the settings ask about
/// every key on every page: a page switch took seconds. Only presence is kept,
/// never a value, and only what a lookup answered for sure.
static PRESENT: LazyLock<Mutex<HashMap<String, bool>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn remember(key: &str, present: bool) {
    PRESENT.lock().unwrap().insert(key.to_string(), present);
}

pub fn get(key: &str) -> Option<String> {
    let entry = entry(key)?;
    let store_err;
    match entry.get_password() {
        Ok(value) if !value.is_empty() => {
            remember(key, true);
            return Some(value);
        }
        Ok(_) | Err(keyring::Error::NoEntry) => {
            store_err = false;
        }
        Err(_) => {
            store_err = true;
        }
    }
    if let Some(value) = fallback_get(key) {
        remember(key, true);
        return Some(value);
    }
    if !store_err {
        remember(key, false);
    }
    None
}

pub fn set(key: &str, value: &str) -> Result<(), String> {
    if !KNOWN_KEYS.contains(&key) {
        return Err(format!("unknown key {key}"));
    }
    if value.is_empty() {
        return clear(key);
    }
    match Entry::new(SERVICE, key) {
        Ok(entry) => match entry.set_password(value) {
            Ok(()) => {
                fallback_delete(key);
                remember(key, true);
                return Ok(());
            }
            Err(err) => {
                #[cfg(windows)]
                {
                    note_fallback(key, &err.to_string());
                    dpapi_fallback::set(key, value)?;
                    remember(key, true);
                    return Ok(());
                }
                #[cfg(not(windows))]
                return Err(err.to_string());
            }
        },
        Err(err) => {
            #[cfg(windows)]
            {
                note_fallback(key, &err.to_string());
                dpapi_fallback::set(key, value)?;
                remember(key, true);
                return Ok(());
            }
            #[cfg(not(windows))]
            return Err(err.to_string());
        }
    }
}

pub fn clear(key: &str) -> Result<(), String> {
    if !KNOWN_KEYS.contains(&key) {
        return Err(format!("unknown key {key}"));
    }
    let deleted_fallback = fallback_delete(key);
    let primary = match Entry::new(SERVICE, key) {
        Ok(entry) => match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(e) => Err(e.to_string()),
        },
        Err(e) => Err(e.to_string()),
    };
    if primary.is_ok() || deleted_fallback {
        remember(key, false);
        Ok(())
    } else {
        primary
    }
}

pub fn present(key: &str) -> bool {
    if let Some(&known) = PRESENT.lock().unwrap().get(key) {
        return known;
    }
    get(key).is_some()
}

/// Looks every key up once, off the main thread, so the settings open on known answers.
pub fn warm_up() {
    std::thread::spawn(|| {
        for key in KNOWN_KEYS {
            let _ = get(key);
        }
    });
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
    if !is_internal(key) {
        return None;
    }
    if let Ok(entry) = internal_entry(key) {
        if let Ok(value) = entry.get_password() {
            if !value.is_empty() {
                return Some(value);
            }
        }
    }
    fallback_get(key)
}

pub fn set_internal(key: &str, value: &str) -> Result<(), String> {
    if !is_internal(key) {
        return Err(format!("unknown key {key}"));
    }
    if value.is_empty() {
        // An empty value means "forget it" (the relay's access key); some keystores refuse an empty password.
        let deleted_fallback = fallback_delete(key);
        let primary = match internal_entry(key) {
            Ok(entry) => match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(e) => Err(e.to_string()),
            },
            Err(e) => Err(e),
        };
        return if primary.is_ok() || deleted_fallback { Ok(()) } else { primary };
    }
    match internal_entry(key) {
        Ok(entry) => match entry.set_password(value) {
            Ok(()) => {
                fallback_delete(key);
                Ok(())
            }
            Err(err) => {
                #[cfg(windows)]
                {
                    note_fallback(key, &err.to_string());
                    return dpapi_fallback::set(key, value);
                }
                #[cfg(not(windows))]
                Err(err.to_string())
            }
        },
        Err(err) => {
            #[cfg(windows)]
            {
                note_fallback(key, &err);
                return dpapi_fallback::set(key, value);
            }
            #[cfg(not(windows))]
            Err(err)
        }
    }
}

#[cfg(windows)]
fn note_fallback(_key: &str, _err: &str) {
    #[cfg(not(test))]
    crate::log::line(format!(
        "secrets: Credential Manager refused {_key} ({_err}); using DPAPI vault fallback"
    ));
}

fn fallback_get(key: &str) -> Option<String> {
    #[cfg(windows)]
    {
        dpapi_fallback::get(key)
    }
    #[cfg(not(windows))]
    {
        let _ = key;
        None
    }
}

fn fallback_delete(key: &str) -> bool {
    #[cfg(windows)]
    {
        dpapi_fallback::delete(key)
    }
    #[cfg(not(windows))]
    {
        let _ = key;
        false
    }
}

/// Encrypted per-user fallback store on Windows for machines where Credential Manager
/// rejects writes with `Windows error code 8` (ERROR_NOT_ENOUGH_MEMORY / profile quota).
/// Blobs are protected with `CryptProtectData` (bound to the current Windows user logon)
/// inside `%LOCALAPPDATA%\Coucou\vault` restricted by `platform::ensure_private_dir`.
#[cfg(windows)]
mod dpapi_fallback {
    use std::ffi::c_void;
    use std::io::Write;
    use std::path::{Path, PathBuf};

    use windows::Win32::Foundation::{HLOCAL, LocalFree};
    use windows::Win32::Security::Cryptography::{
        CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB, CryptProtectData, CryptUnprotectData,
    };

    const ENTROPY: &[u8] = b"fr.louisraille.coucou.vault.v1";

    pub fn vault_dir() -> PathBuf {
        let base = std::env::var_os("LOCALAPPDATA")
            .or_else(|| std::env::var_os("APPDATA"))
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        base.join("Coucou").join("vault")
    }

    fn key_path(dir: &Path, key: &str) -> Result<PathBuf, String> {
        if key.is_empty()
            || !key
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        {
            return Err(format!("invalid vault key {key}"));
        }
        Ok(dir.join(format!("{key}.dpapi")))
    }

    pub fn protect(plaintext: &[u8]) -> Result<Vec<u8>, String> {
        let mut in_buf = plaintext.to_vec();
        let data_in = CRYPT_INTEGER_BLOB {
            cbData: in_buf.len() as u32,
            pbData: if in_buf.is_empty() {
                std::ptr::null_mut()
            } else {
                in_buf.as_mut_ptr()
            },
        };
        let mut entropy_buf = ENTROPY.to_vec();
        let entropy = CRYPT_INTEGER_BLOB {
            cbData: entropy_buf.len() as u32,
            pbData: entropy_buf.as_mut_ptr(),
        };
        let mut data_out = CRYPT_INTEGER_BLOB::default();
        unsafe {
            CryptProtectData(
                &data_in,
                None,
                Some(&entropy),
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut data_out,
            )
            .map_err(|e| format!("DPAPI protect failed: {e}"))?;
            let slice = std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize);
            let encrypted = slice.to_vec();
            let _ = LocalFree(Some(HLOCAL(data_out.pbData as *mut c_void)));
            Ok(encrypted)
        }
    }

    pub fn unprotect(ciphertext: &[u8]) -> Result<Vec<u8>, String> {
        if ciphertext.is_empty() {
            return Err("empty ciphertext".into());
        }
        let mut in_buf = ciphertext.to_vec();
        let data_in = CRYPT_INTEGER_BLOB {
            cbData: in_buf.len() as u32,
            pbData: in_buf.as_mut_ptr(),
        };
        let mut entropy_buf = ENTROPY.to_vec();
        let entropy = CRYPT_INTEGER_BLOB {
            cbData: entropy_buf.len() as u32,
            pbData: entropy_buf.as_mut_ptr(),
        };
        let mut data_out = CRYPT_INTEGER_BLOB::default();
        unsafe {
            CryptUnprotectData(
                &data_in,
                None,
                Some(&entropy),
                None,
                None,
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut data_out,
            )
            .map_err(|e| format!("DPAPI unprotect failed: {e}"))?;
            let slice = std::slice::from_raw_parts(data_out.pbData, data_out.cbData as usize);
            let decrypted = slice.to_vec();
            let _ = LocalFree(Some(HLOCAL(data_out.pbData as *mut c_void)));
            Ok(decrypted)
        }
    }

    pub fn get(key: &str) -> Option<String> {
        get_from(&vault_dir(), key)
    }

    pub fn set(key: &str, value: &str) -> Result<(), String> {
        set_in(&vault_dir(), key, value)
    }

    pub fn delete(key: &str) -> bool {
        delete_from(&vault_dir(), key)
    }

    pub fn get_from(dir: &Path, key: &str) -> Option<String> {
        let path = key_path(dir, key).ok()?;
        let bytes = std::fs::read(&path).ok()?;
        let plain = unprotect(&bytes).ok()?;
        String::from_utf8(plain).ok().filter(|v| !v.is_empty())
    }

    pub fn set_in(dir: &Path, key: &str, value: &str) -> Result<(), String> {
        crate::platform::ensure_private_dir(dir).map_err(|e| e.to_string())?;
        let target = key_path(dir, key)?;
        let blob = protect(value.as_bytes())?;
        let tmp = dir.join(format!("{key}.dpapi.tmp.{}", std::process::id()));
        let written = std::fs::File::create(&tmp).and_then(|mut f| {
            f.write_all(&blob)?;
            f.sync_all()
        });
        if let Err(e) = written {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        if let Err(e) = std::fs::rename(&tmp, &target) {
            let _ = std::fs::remove_file(&tmp);
            return Err(e.to_string());
        }
        Ok(())
    }

    pub fn delete_from(dir: &Path, key: &str) -> bool {
        let Ok(path) = key_path(dir, key) else {
            return false;
        };
        if !path.exists() {
            return false;
        }
        std::fs::remove_file(&path).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presence_is_answered_from_memory_once_known() {
        remember("calcom-api-key", true);
        assert!(present("calcom-api-key"));
        remember("calcom-api-key", false);
        assert!(!present("calcom-api-key"));
    }

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

    #[cfg(windows)]
    #[test]
    fn dpapi_vault_round_trips_large_secret_and_deletes_cleanly() {
        let dir = std::env::temp_dir().join(format!("coucou-dpapi-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let secret: String = (0..4096).map(|i| char::from(b"0123456789abcdef"[i % 16])).collect();

        assert_eq!(dpapi_fallback::get_from(&dir, "phone-link-cert"), None);
        dpapi_fallback::set_in(&dir, "phone-link-cert", &secret).expect("DPAPI set_in failed");

        // Stored file must not contain plaintext secret bytes.
        let disk = std::fs::read(dir.join("phone-link-cert.dpapi")).unwrap();
        assert!(!disk.windows(16).any(|w| w == &secret.as_bytes()[..16]));

        assert_eq!(
            dpapi_fallback::get_from(&dir, "phone-link-cert").as_deref(),
            Some(secret.as_str())
        );
        assert!(dpapi_fallback::get_from(&dir, "../evil").is_none());
        assert!(dpapi_fallback::delete_from(&dir, "phone-link-cert"));
        assert_eq!(dpapi_fallback::get_from(&dir, "phone-link-cert"), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
