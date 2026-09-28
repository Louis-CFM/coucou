use crate::paths;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::Mutex;

pub const SERVICE_NAME: &str = "fr.louisraille.NotchBuddy";

const ALLOWED_KEYS: &[&str] = &[
    "anthropic-api-key",
    "resend-api-key",
    "resend-from",
    "n8n-url",
    "n8n-api-key",
    "vercel-token",
    "github-token",
    "stripe-api-key",
    "calcom-api-key",
    "notion-api-key",
];

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SecretsStatus {
    pub secure_storage_available: bool,
    pub secure_storage_backend: String,
}

pub struct SecretsState {
    backend: Mutex<BackendKind>,
    file_cache: Mutex<HashMap<String, String>>,
}

#[derive(Clone, Copy)]
enum BackendKind {
    SecretService,
    FileFallback,
    Unavailable,
}

impl SecretsState {
    pub fn new() -> Self {
        let backend = init_backend();
        Self {
            backend: Mutex::new(backend),
            file_cache: Mutex::new(load_file_secrets()),
        }
    }

    fn status_locked(&self, backend: BackendKind) -> SecretsStatus {
        match backend {
            BackendKind::SecretService => SecretsStatus {
                secure_storage_available: true,
                secure_storage_backend: "secret-service".into(),
            },
            BackendKind::FileFallback => SecretsStatus {
                secure_storage_available: false,
                secure_storage_backend: "file-fallback".into(),
            },
            BackendKind::Unavailable => SecretsStatus {
                secure_storage_available: false,
                secure_storage_backend: "unavailable".into(),
            },
        }
    }
}

fn init_backend() -> BackendKind {
    if try_secret_service_ping() {
        return BackendKind::SecretService;
    }
    if paths::ensure().is_ok() {
        BackendKind::FileFallback
    } else {
        BackendKind::Unavailable
    }
}

fn try_secret_service_ping() -> bool {
    #[cfg(feature = "secret-service")]
    {
        use secret_service::{EncryptionType, blocking::SecretService};
        SecretService::connect(EncryptionType::Dh).is_ok()
    }
    #[cfg(not(feature = "secret-service"))]
    {
        false
    }
}

fn validate_key(key: &str) -> Result<(), String> {
    if ALLOWED_KEYS.contains(&key) {
        Ok(())
    } else {
        Err(format!("unknown secret key: {key}"))
    }
}

fn load_file_secrets() -> HashMap<String, String> {
    let path = paths::secrets_fallback_path();
    let Ok(data) = std::fs::read(&path) else {
        return HashMap::new();
    };
    serde_json::from_slice(&data).unwrap_or_default()
}

fn save_file_secrets(map: &HashMap<String, String>) -> Result<(), String> {
    let _ = paths::ensure();
    let path = paths::secrets_fallback_path();
    let data = serde_json::to_vec_pretty(map).map_err(|e| e.to_string())?;
    std::fs::write(&path, &data).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

fn attrs_for_key(key: &str) -> HashMap<&str, &str> {
    HashMap::from([
        ("service", SERVICE_NAME),
        ("account", key),
    ])
}

#[cfg(feature = "secret-service")]
fn with_collection<F, T>(f: F) -> Result<T, String>
where
    F: FnOnce(
        secret_service::blocking::Collection<'_>,
    ) -> Result<T, secret_service::Error>,
{
    use secret_service::{EncryptionType, blocking::SecretService};
    let ss = SecretService::connect(EncryptionType::Dh).map_err(|e| e.to_string())?;
    let collection = ss
        .get_any_collection()
        .map_err(|e| e.to_string())?;
    let _ = collection.unlock();
    f(collection).map_err(|e| e.to_string())
}

#[cfg(feature = "secret-service")]
fn secret_service_get(key: &str) -> Result<Option<String>, String> {
    with_collection(|collection| {
        let items = collection.search_items(attrs_for_key(key))?;
        if items.is_empty() {
            return Ok(None);
        }
        let secret = items[0].get_secret()?;
        Ok(String::from_utf8(secret).ok())
    })
}

#[cfg(not(feature = "secret-service"))]
fn secret_service_get(_key: &str) -> Result<Option<String>, String> {
    Err("secret-service feature disabled".into())
}

#[cfg(feature = "secret-service")]
fn secret_service_set(key: &str, value: &str) -> Result<(), String> {
    with_collection(|collection| {
        let attrs = attrs_for_key(key);
        let items = collection.search_items(attrs.clone())?;
        if let Some(item) = items.into_iter().next() {
            item.set_secret(value.as_bytes(), "text/plain")?;
        } else {
            collection.create_item(
                &format!("Coucou {key}"),
                attrs,
                value.as_bytes(),
                true,
                "text/plain",
            )?;
        }
        Ok(())
    })
}

#[cfg(not(feature = "secret-service"))]
fn secret_service_set(_key: &str, _value: &str) -> Result<(), String> {
    Err("secret-service feature disabled".into())
}

#[cfg(feature = "secret-service")]
fn secret_service_delete(key: &str) -> Result<(), String> {
    with_collection(|collection| {
        let items = collection.search_items(attrs_for_key(key))?;
        for item in items {
            item.delete()?;
        }
        Ok(())
    })
}

#[cfg(not(feature = "secret-service"))]
fn secret_service_delete(_key: &str) -> Result<(), String> {
    Err("secret-service feature disabled".into())
}

#[tauri::command]
pub fn secrets_get(state: tauri::State<'_, SecretsState>, key: String) -> Result<Option<String>, String> {
    validate_key(&key)?;
    let backend = *state.backend.lock().unwrap();
    match backend {
        BackendKind::SecretService => secret_service_get(&key),
        BackendKind::FileFallback | BackendKind::Unavailable => {
            Ok(state.file_cache.lock().unwrap().get(&key).cloned())
        }
    }
}

#[tauri::command]
pub fn secrets_set(state: tauri::State<'_, SecretsState>, key: String, value: String) -> Result<(), String> {
    validate_key(&key)?;
    let backend = *state.backend.lock().unwrap();
    match backend {
        BackendKind::SecretService => secret_service_set(&key, &value),
        BackendKind::FileFallback | BackendKind::Unavailable => {
            {
                let mut cache = state.file_cache.lock().unwrap();
                cache.insert(key, value);
                save_file_secrets(&cache)?;
            }
            Ok(())
        }
    }
}

#[tauri::command]
pub fn secrets_delete(state: tauri::State<'_, SecretsState>, key: String) -> Result<(), String> {
    validate_key(&key)?;
    let backend = *state.backend.lock().unwrap();
    match backend {
        BackendKind::SecretService => secret_service_delete(&key),
        BackendKind::FileFallback | BackendKind::Unavailable => {
            {
                let mut cache = state.file_cache.lock().unwrap();
                cache.remove(&key);
                save_file_secrets(&cache)?;
            }
            Ok(())
        }
    }
}

#[tauri::command]
pub fn secrets_status(state: tauri::State<'_, SecretsState>) -> SecretsStatus {
    let backend = *state.backend.lock().unwrap();
    state.status_locked(backend)
}
