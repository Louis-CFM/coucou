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
    /// Which agent this build drives by default: "pi", "copilot",
    /// "antigravity" or "claudeCode". Defaulted explicitly so a settings.json
    /// written by an older build still loads.
    #[serde(default = "default_agent")]
    pub active_agent: String,
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    /// Which backend the island chat talks to: "claude" or "pi".
    ///
    /// This is deliberately not a model. Pi is a whole agent with its own tools,
    /// permissions and sessions, not a model name, and presenting it in the model
    /// list would misrepresent it. Defaulted explicitly so a settings.json written
    /// by an older build still loads and keeps working on Claude.
    #[serde(default = "default_chat_provider")]
    pub chat_provider: String,
    /// Agents Coucow has been told to stay away from.
    ///
    /// A disabled agent is off in the strongest sense available: its hooks are
    /// removed so the agent stops calling Coucou at all, and its pill is hidden so
    /// it stops taking up room in the island. Stored as a list rather than a set
    /// of flags because "which agents are off" is a short, readable list in
    /// settings.json, and a new agent added by a later Coucou is enabled by
    /// default rather than silently switched off.
    #[serde(default)]
    pub disabled_agents: Vec<String>,
    /// Whether Mochi is also living on the desktop as a free-floating window.
    #[serde(default)]
    pub desktop_mochi: bool,
    /// Desktop Mochi panel edge length in logical pixels.
    #[serde(default = "default_desktop_mochi_size")]
    pub desktop_mochi_size: f64,
    /// Last position, in the virtual screen's coordinates, y increasing
    /// downward. `None` until it has been dragged somewhere.
    #[serde(default)]
    pub desktop_mochi_pos: Option<(f64, f64)>,
}

fn default_agent() -> String {
    "pi".to_string()
}

fn default_chat_provider() -> String {
    "claude".to_string()
}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

fn default_desktop_mochi_size() -> f64 {
    120.0
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
            active_agent: default_agent(),
            model: default_model(),
            chat_provider: default_chat_provider(),
            disabled_agents: Vec::new(),
            desktop_mochi: false,
            desktop_mochi_size: default_desktop_mochi_size(),
            desktop_mochi_pos: None,
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

    /// A settings.json written by a build that predates these fields must still
    /// load, or the upgrade silently resets a user's configuration. `load()`
    /// falls back to `Settings::default()` on any parse error, so a missing key
    /// that was not defaulted would quietly become "no agents disabled" and
    /// "chat on Claude" rather than raising — which is exactly the kind of
    /// invisible reset that is hard to notice and annoying to diagnose.
    #[test]
    fn an_older_settings_file_still_loads() {
        let old = br#"{
            "soundEnabled": true,
            "soundVolume": 0.12,
            "autoCloseInterval": 15,
            "absenceInterval": 180,
            "activeIntegrations": [],
            "screen": "primary",
            "autostart": false,
            "hooksInstalled": true,
            "activeAgent": "copilot",
            "model": "claude-opus-5"
        }"#;
        let s: Settings = serde_json::from_slice(old).expect("an older file must still parse");
        assert_eq!(s.active_agent, "copilot", "existing values must survive");
        assert_eq!(s.chat_provider, "claude", "the chat provider defaults");
        assert_eq!(s.desktop_mochi_size, 120.0, "Mochi keeps its default size");
        assert!(
            s.disabled_agents.is_empty(),
            "an agent added by a later build starts enabled, not disabled"
        );
    }

    #[test]
    fn disabled_agents_round_trips_and_unknown_names_are_kept() {
        let base = Settings::default();
        let s = Settings {
            disabled_agents: vec!["pi".to_string(), "some-agent-from-the-future".to_string()],
            ..base
        };
        let json = serde_json::to_string(&s).unwrap();
        assert!(
            json.contains("\"disabledAgents\""),
            "the field must be written in camelCase, got: {json}"
        );
        let back: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.disabled_agents, s.disabled_agents);
    }
}
