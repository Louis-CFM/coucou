// Preferences, stored as plain JSON in %APPDATA%\Coucou\settings.json.
// No secret ever lands here — API keys live in the Windows Credential Manager.

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
    /// Cursor agent hooks in `%USERPROFILE%\.cursor\hooks.json`.
    /// Defaulted so a settings.json written before the Cursor pill still loads.
    #[serde(default)]
    pub cursor_hooks_installed: bool,
    /// Last project the Cursor chat may edit. Survives a closed Cursor window.
    #[serde(default)]
    pub cursor_project: Option<String>,
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    /// Pill focused when Coucou starts. An older settings.json has no such field.
    #[serde(default = "default_pill")]
    pub default_pill: String,
    /// How the compact island disappears completely.
    /// "timer" = after the mouse has left it. "manual" = only the close button.
    #[serde(default = "default_hide_mode")]
    pub hide_mode: String,
    /// How the expanded island shrinks back to compact.
    /// "timer" = after the mouse has left it. "outside" = on a click outside Coucou.
    #[serde(default = "default_shrink_mode")]
    pub shrink_mode: String,
}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

fn default_pill() -> String {
    "integration_claude".to_string()
}

fn default_hide_mode() -> String {
    "timer".to_string()
}

fn default_shrink_mode() -> String {
    "timer".to_string()
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
            cursor_hooks_installed: false,
            cursor_project: None,
            model: default_model(),
            default_pill: default_pill(),
            hide_mode: default_hide_mode(),
            shrink_mode: default_shrink_mode(),
        }
    }
}

/// %APPDATA%\Coucou
pub fn config_dir() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

/// %LOCALAPPDATA%\Coucou — where coucou-hook.exe and the log live.
pub fn local_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("Coucou")
}

pub fn hook_exe_path() -> PathBuf {
    local_dir().join("bin").join("coucou-hook.exe")
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
    std::fs::create_dir_all(&dir)?;
    let json = serde_json::to_vec_pretty(settings)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(settings_path(), json)
}
