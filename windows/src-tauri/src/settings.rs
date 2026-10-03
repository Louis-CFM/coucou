// Preferences, stored as plain JSON in settings.json under platform::config_dir().
// No secret ever lands here — API keys live in the OS keychain (see secrets.rs).

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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
    /// OpenAI-compatible base URL (OpenRouter, NVIDIA NIM, …). Empty = Claude API.
    #[serde(default)]
    pub chat_endpoint: String,
    /// Model id sent to `chat_endpoint`.
    #[serde(default)]
    pub custom_model: String,
    /// Roam screenshot without the scan cutscene: a quick sweep, then capture.
    #[serde(default)]
    pub quick_scan: bool,
    /// The island never fades to the invisible wake strip: at rest it stays
    /// compact at the top of the screen.
    #[serde(default)]
    pub keep_visible: bool,
    /// The main Mochi's name: the chat's persona. Empty = "Mochi".
    #[serde(default)]
    pub mochi_name: String,
    /// Hands-free chat: after a spoken question, the mic listens again once
    /// the reply is in. Off = the mic turns off after each prompt.
    #[serde(default)]
    pub keep_mic_on: bool,
    /// Names of the coloured integration Mochis, by integration id. Missing or
    /// empty = the service's own name.
    #[serde(default)]
    pub mochi_names: HashMap<String, String>,
    /// The chat's saved models (selector next to Send).
    #[serde(default)]
    pub models: Vec<ModelEntry>,
    /// Id of the model the chat uses.
    #[serde(default)]
    pub active_model: String,
    /// Each Mochi's shape and hat ids, by task id; "integration_claude" is the
    /// main Mochi.
    #[serde(default)]
    pub wardrobe: HashMap<String, Outfit>,
}

/// One Mochi's look. Empty strings mean the default shape / no hat.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Outfit {
    pub shape: String,
    pub head: String,
}

/// A model the chat can use.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ModelEntry {
    pub id: String,
    pub label: String,
    /// "claude", or "openai" for any OpenAI-compatible endpoint.
    pub kind: String,
    pub model: String,
    pub endpoint: String,
    /// Whether it reads images, learnt the first time it is sent one.
    /// None = not known yet.
    pub vision: Option<bool>,
    /// What it makes: "image", "video" or "audio" (see media.rs). Anything
    /// else, including the empty string of a settings.json written before
    /// this existed, is a text chat model.
    pub output: String,
    /// Text-to-speech voice, for "audio" models. Empty = the model's default.
    pub voice: String,
    /// Output detail for "3d" models that offer it (TRELLIS 2: "low",
    /// "medium" or "high"). Empty = the model's default.
    pub detail: String,
}

/// Settings written before the model list existed: turn the Claude model and
/// the single custom provider into list entries, keeping the one in use active.
fn migrate(s: &mut Settings) {
    if !s.models.is_empty() {
        if !s.models.iter().any(|m| m.id == s.active_model) {
            s.active_model = s.models[0].id.clone();
        }
        return;
    }
    s.models.push(ModelEntry {
        id: "claude".into(),
        label: s.model.replace("claude-", "Claude ").replace('-', " "),
        kind: "claude".into(),
        model: s.model.clone(),
        endpoint: String::new(),
        vision: Some(true),
        ..Default::default()
    });
    s.active_model = "claude".into();
    if !s.chat_endpoint.trim().is_empty() && !s.custom_model.trim().is_empty() {
        s.models.push(ModelEntry {
            id: "custom".into(),
            label: s.custom_model.trim().to_string(),
            kind: "openai".into(),
            model: s.custom_model.trim().to_string(),
            endpoint: s.chat_endpoint.trim().to_string(),
            vision: None,
            ..Default::default()
        });
        s.active_model = "custom".into();
    }
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
            chat_endpoint: String::new(),
            custom_model: String::new(),
            quick_scan: false,
            keep_visible: false,
            mochi_name: String::new(),
            keep_mic_on: false,
            mochi_names: HashMap::new(),
            models: Vec::new(),
            active_model: String::new(),
            wardrobe: HashMap::new(),
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
    let mut s: Settings = match std::fs::read(settings_path()) {
        Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
        Err(_) => Settings::default(),
    };
    migrate(&mut s);
    s
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
    use super::{migrate, Settings};

    #[test]
    fn old_settings_become_a_model_list() {
        // A custom provider in use: both models listed, the custom one active.
        let mut s: Settings = serde_json::from_str(
            r#"{"soundEnabled":true,"soundVolume":0.1,"autoCloseInterval":15,"absenceInterval":180,
               "activeIntegrations":[],"screen":"primary","autostart":false,"hooksInstalled":false,
               "model":"claude-opus-5","chatEndpoint":"https://api.groq.com/openai/v1","customModel":"llama-3.3"}"#,
        )
        .unwrap();
        migrate(&mut s);
        assert_eq!(s.models.len(), 2);
        assert_eq!(s.models[0].kind, "claude");
        assert_eq!(s.models[1].endpoint, "https://api.groq.com/openai/v1");
        assert_eq!(s.active_model, "custom");
        // Saved before models had an output kind: still text models.
        assert!(s.models.iter().all(|m| m.output.is_empty() && m.voice.is_empty()));

        // Fresh install: just Claude. A dangling active id is repaired.
        let mut fresh = Settings::default();
        migrate(&mut fresh);
        assert_eq!(fresh.models.len(), 1);
        fresh.active_model = "gone".into();
        migrate(&mut fresh);
        assert_eq!(fresh.active_model, "claude");
    }

    #[test]
    fn model_entries_without_an_output_load_as_text() {
        let m: super::ModelEntry =
            serde_json::from_str(r#"{"id":"m","label":"x","kind":"openai","model":"llama","endpoint":"e","vision":null}"#)
                .unwrap();
        assert_eq!(m.output, "");
        let m: super::ModelEntry = serde_json::from_str(r#"{"id":"m","model":"o","output":"audio","voice":"troy"}"#).unwrap();
        assert_eq!((m.output.as_str(), m.voice.as_str()), ("audio", "troy"));
    }
}
