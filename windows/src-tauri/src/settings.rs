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
    #[serde(default = "default_true")]
    pub always_show_compact: bool,
    #[serde(default = "default_local")]
    pub chat_provider: String,
    #[serde(default = "default_ollama")]
    pub local_provider: String,
    #[serde(default = "default_ollama_url")]
    pub local_server_url: String,
    #[serde(default)]
    pub local_model: String,
    #[serde(default = "default_true")]
    pub voice_enabled: bool,
    #[serde(default = "default_wake_word")]
    pub voice_wake_word: String,
    #[serde(default = "default_voice_lang")]
    pub voice_language: String,
    #[serde(default = "default_voice_name")]
    pub voice_tts_voice: String,
    #[serde(default = "default_stt_provider")]
    pub voice_stt_provider: String,
    #[serde(default = "default_whisper_url")]
    pub voice_whisper_url: String,
    #[serde(default = "default_silence_timeout")]
    pub voice_silence_timeout: f64,
    #[serde(default = "default_voice_speed")]
    pub voice_speed: f64,
    #[serde(default = "default_voice_volume")]
    pub voice_volume: f64,
    #[serde(default = "default_voice_pitch")]
    pub voice_pitch: String,
    #[serde(default = "default_voice_response_mode")]
    pub voice_response_mode: String,
    #[serde(default)]
    pub voice_input_device: String,
    #[serde(default = "default_voice_mic_gain")]
    pub voice_mic_gain: f64,
    /// Claude model used by the chat. Changeable in the settings window.
    /// Defaulted explicitly so a settings.json written by an older build still loads.
    #[serde(default = "default_model")]
    pub model: String,
    #[serde(default = "default_true")]
    pub web_access_enabled: bool,
}

fn default_true() -> bool {
    true
}

fn default_local() -> String {
    "local".to_string()
}

fn default_ollama() -> String {
    "ollama".to_string()
}

fn default_ollama_url() -> String {
    "http://localhost:11434".to_string()
}

fn default_wake_word() -> String {
    "Hey Coucou".to_string()
}

fn default_voice_lang() -> String {
    "id-ID".to_string()
}

fn default_voice_name() -> String {
    "id-ID-GadisNeural".to_string()
}

fn default_stt_provider() -> String {
    "native".to_string()
}

fn default_whisper_url() -> String {
    "http://localhost:11434".to_string()
}

fn default_silence_timeout() -> f64 {
    1.5
}

fn default_voice_speed() -> f64 {
    1.0
}

fn default_voice_volume() -> f64 {
    1.0
}

fn default_voice_pitch() -> String {
    "+0Hz".to_string()
}

fn default_voice_response_mode() -> String {
    "concise".to_string()
}

fn default_voice_mic_gain() -> f64 {
    2.0
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
            always_show_compact: true,
            chat_provider: default_local(),
            local_provider: default_ollama(),
            local_server_url: default_ollama_url(),
            local_model: String::new(),
            voice_enabled: true,
            voice_wake_word: default_wake_word(),
            voice_language: default_voice_lang(),
            voice_tts_voice: default_voice_name(),
            voice_stt_provider: default_stt_provider(),
            voice_whisper_url: default_whisper_url(),
            voice_silence_timeout: default_silence_timeout(),
            voice_speed: default_voice_speed(),
            voice_volume: default_voice_volume(),
            voice_pitch: default_voice_pitch(),
            voice_response_mode: default_voice_response_mode(),
            voice_input_device: String::new(),
            voice_mic_gain: default_voice_mic_gain(),
            model: default_model(),
            web_access_enabled: true,
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
