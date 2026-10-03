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
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    /// "auto" follows the system language; otherwise "en", "de" or "fr". Drives the
    /// chat's answer language and the island's step labels.
    #[serde(default = "default_language")]
    pub language: String,
    /// Who the chat talks to: "anthropic" (Claude), or a local model server,
    /// "ollama", "lmstudio" or "custom" (any OpenAI-compatible server, see local_chat.rs).
    #[serde(default = "default_provider")]
    pub chat_provider: String,
    /// Addresses of the local model servers once connected; empty means not connected.
    #[serde(default)]
    pub ollama_url: String,
    #[serde(default)]
    pub lmstudio_url: String,
    /// The model chosen on each local server.
    #[serde(default)]
    pub ollama_model: String,
    #[serde(default)]
    pub lmstudio_model: String,
    /// An OpenAI-compatible server of the user's own; its key, if any, is in the keychain.
    #[serde(default)]
    pub custom_url: String,
    #[serde(default)]
    pub custom_model: String,
    /// Show the plan usage pill (5 h and weekly limits) in the island's header.
    /// Off until the user turns it on, so the header stays as it shipped.
    #[serde(default)]
    pub show_plan_in_notch: bool,
    /// Coucou's status line relay is the one in settings.json. Like
    /// `hooks_installed`, the real state wins at launch over what was stored.
    #[serde(default)]
    pub plan_relay_installed: bool,
}

fn default_language() -> String {
    "auto".to_string()
}

fn default_provider() -> String {
    "anthropic".to_string()
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
            model: default_model(),
            language: default_language(),
            chat_provider: default_provider(),
            ollama_url: String::new(),
            lmstudio_url: String::new(),
            ollama_model: String::new(),
            lmstudio_model: String::new(),
            custom_url: String::new(),
            custom_model: String::new(),
            show_plan_in_notch: false,
            plan_relay_installed: false,
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
