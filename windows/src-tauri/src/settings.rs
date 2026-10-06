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
    /// "anthropic" (default, unchanged behavior) or "openai-compatible".
    #[serde(default = "default_provider")]
    pub chat_provider: String,
    /// Base URL for the OpenAI-compatible provider; plain (non-secret) setting.
    #[serde(default = "default_base_url")]
    pub openai_base_url: String,
    /// Full endpoint URL for the Anthropic-compatible provider; default is the
    /// official API (behavior unchanged when untouched).
    #[serde(default = "default_anthropic_base_url")]
    pub anthropic_base_url: String,
    /// Opt-in web search for the OpenAI-compatible provider (spends credits).
    #[serde(default)]
    pub web_search: bool,
}

fn default_provider() -> String {
    "anthropic".into()
}

fn default_base_url() -> String {
    crate::openai::DEFAULT_BASE_URL.into()
}

fn default_anthropic_base_url() -> String {
    "https://api.anthropic.com/v1/messages".into()
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
            chat_provider: default_provider(),
            openai_base_url: default_base_url(),
            anthropic_base_url: default_anthropic_base_url(),
            web_search: false,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_settings_json_loads_with_anthropic_defaults() {
        // A real file written by an older build: every old field, none of the new ones.
        let s: Settings = serde_json::from_str(
            r#"{"soundEnabled":true,"soundVolume":0.12,"autoCloseInterval":15.0,"absenceInterval":180.0,"activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false,"model":"claude-opus-5"}"#,
        )
        .unwrap();
        assert_eq!(s.model, "claude-opus-5");
        assert_eq!(s.chat_provider, "anthropic");
        assert_eq!(s.openai_base_url, crate::openai::DEFAULT_BASE_URL);
        assert!(!s.web_search);
    }

    #[test]
    fn old_settings_json_defaults_anthropic_compat_endpoint() {
        let s: Settings = serde_json::from_str(
            r#"{"soundEnabled":true,"soundVolume":0.12,"autoCloseInterval":15.0,"absenceInterval":180.0,"activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false,"model":"claude-opus-5"}"#,
        )
        .unwrap();
        assert_eq!(s.anthropic_base_url, "https://api.anthropic.com/v1/messages");
    }
}
