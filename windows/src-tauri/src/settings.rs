// Preferences, stored as plain JSON in settings.json under platform::config_dir().
// No secret ever lands here — API keys live in the OS keychain (see secrets.rs).

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub sound_enabled: bool,
    pub sound_volume: f64,
    pub auto_close_interval: f64,
    pub absence_interval: f64,
    pub active_integrations: Vec<String>,
    /// "primary" = the main display, "cursor" = whichever display the mouse is on.
    pub screen: String,
    pub autostart: bool,
    pub hooks_installed: bool,
    /// Active chat provider id — a `providers::PROVIDERS` entry, or `custom`.
    /// Defaulted explicitly so a settings.json written before providers existed
    /// still loads; that is also the migration path for `model` below.
    #[serde(default = "default_provider")]
    pub chat_provider: String,
    /// Per-provider model override. A provider absent from the map uses its
    /// catalog default, so a new provider works without touching settings.
    #[serde(default)]
    pub provider_models: std::collections::HashMap<String, String>,
    /// The custom gateway: any OpenAI- or Anthropic-compatible endpoint.
    #[serde(default)]
    pub custom_base_url: String,
    #[serde(default = "default_custom_model")]
    pub custom_model: String,
    #[serde(default)]
    pub custom_dialect: crate::providers::Dialect,
    /// Legacy single-model field, kept so an older settings.json deserializes. Read
    /// once as the Anthropic model override; superseded by `provider_models`.
    #[serde(default = "default_model")]
    pub model: String,
}

fn default_provider() -> String {
    "anthropic".to_string()
}

fn default_custom_model() -> String {
    "gpt-4o-mini".to_string()
}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            sound_enabled: true,
            sound_volume: 0.12,
            auto_close_interval: 15.0,
            absence_interval: 180.0,
            active_integrations: vec![
                "integration_resend".into(),
                "integration_n8n".into(),
                "integration_vercel".into(),
                "integration_github".into(),
            ],
            screen: "primary".into(),
            autostart: false,
            hooks_installed: false,
            chat_provider: default_provider(),
            provider_models: std::collections::HashMap::new(),
            custom_base_url: String::new(),
            custom_model: default_custom_model(),
            custom_dialect: crate::providers::Dialect::OpenAI,
            model: default_model(),
        }
    }
}

pub use crate::platform::{config_dir, local_dir};

pub fn hook_exe_path() -> PathBuf {
    local_dir().join("bin").join(crate::platform::HOOK_EXE)
}

fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn load() -> Settings {
    match std::fs::read(settings_path()) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => Settings::default(),
    }
}

pub fn save(settings: &Settings) -> std::io::Result<()> {
    let dir = config_dir();
    crate::platform::ensure_private_dir(&dir)?;
    let json = serde_json::to_vec_pretty(settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(settings_path(), json)
}
