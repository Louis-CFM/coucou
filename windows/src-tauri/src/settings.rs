// Preferences, stored as plain JSON in %APPDATA%\Coucou\settings.json.
// No secret ever lands here — API keys live in the Windows Credential Manager.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    #[serde(default = "default_sound_enabled")]
    pub sound_enabled: bool,
    #[serde(default = "default_sound_volume")]
    pub sound_volume: f64,
    #[serde(default = "default_auto_close_interval")]
    pub auto_close_interval: f64,
    /// Seconds from compact to fully reduced. 0 = never fully reduce.
    #[serde(default = "default_absence_interval")]
    pub absence_interval: f64,
    /// Seconds from fully reduced to off-screen. 0 = never leave the screen.
    /// The last of the three resting steps; `auto_close_interval` compacts the
    /// island to the bar and `absence_interval` takes it to a single Mochi.
    #[serde(default)]
    pub auto_close_delay: f64,
    /// Pinned by the user from the island header: the island then ignores
    /// outside clicks, Escape and the auto-close timer until unpinned.
    #[serde(default)]
    pub pin_island: bool,
    /// Wake the reduced island on hover. When false it waits to be clicked.
    #[serde(default = "default_wake_on_hover")]
    pub wake_on_hover: bool,
    /// Opt-in integrations. Defaults to empty: a fresh install shows only the
    /// coding-agent pills rather than every integration that has no key.
    #[serde(default)]
    pub active_integrations: Vec<String>,
    /// "primary" = the main display, "cursor" = whichever display the mouse is on,
    /// "secondary" = the first non-primary display.
    #[serde(default = "default_screen")]
    pub screen: String,
    #[serde(default)]
    pub autostart: bool,
    #[serde(default)]
    pub hooks_installed: bool,
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    /// Chat backend: "claude" (Anthropic API) or "opencode" (local CLI).
    #[serde(default = "default_chat_provider")]
    pub chat_provider: String,
    /// Optional explicit path to opencode.exe; empty = auto-detect.
    #[serde(default)]
    pub opencode_bin: String,
    /// Optional `provider/model` override for opencode chat; empty = its default.
    #[serde(default)]
    pub opencode_model: String,
    /// Keep one opencode server running for as long as the app is, and send chat
    /// turns to it over HTTP. Off means the default: a fresh `opencode run` per
    /// message, each booting a throwaway server of its own.
    #[serde(default)]
    pub chat_via_server: bool,
    /// Whether hovering the top edge brings back an island that auto-close took
    /// off-screen. Governs off-screen only; wake_on_hover is for the parked bar.
    #[serde(default = "default_true")]
    pub hover_restore: bool,
    /// Horizontal resting place of the compact island, normalised 0..=1 across
    /// the target display: 0 = flush left, 0.5 = centred, 1 = flush right.
    /// Stored as a fraction so a drag can land anywhere while the presets still
    /// snap to exact edges.
    #[serde(default = "default_notch_position")]
    pub notch_position: f64,
}

fn default_notch_position() -> f64 {
    0.5
}


fn default_true() -> bool {
    true
}

fn default_chat_provider() -> String {
    "claude".into()
}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

fn default_sound_enabled() -> bool {
    true
}

fn default_sound_volume() -> f64 {
    0.12
}

fn default_auto_close_interval() -> f64 {
    15.0
}

fn default_absence_interval() -> f64 {
    180.0
}

/// Waking on hover is the default: the island is a bar at the top of the screen
/// and should appear as the pointer reaches it. Turning it off means it waits to
/// be clicked.
fn default_wake_on_hover() -> bool {
    true
}

fn default_screen() -> String {
    "primary".into()
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            sound_enabled: default_sound_enabled(),
            sound_volume: default_sound_volume(),
            auto_close_interval: default_auto_close_interval(),
            absence_interval: default_absence_interval(),
            auto_close_delay: 0.0,
            pin_island: false,
            wake_on_hover: default_wake_on_hover(),
            // Opt-in only: the coding-agent pills are always loaded, so starting
            // with an empty list means a fresh install shows nothing unconfigured.
            active_integrations: Vec::new(),
            screen: default_screen(),
            autostart: false,
            hooks_installed: false,
            model: default_model(),
            chat_provider: default_chat_provider(),
            opencode_bin: String::new(),
            opencode_model: String::new(),
            chat_via_server: false,
            hover_restore: true,
            notch_position: default_notch_position(),
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
