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
    /// How much of the app is drawn: text, spacing, and the island itself.
    /// 1.0 is the size everything was designed at. The window multiplies by
    /// the same factor, so scaling up never crops what it grew.
    #[serde(default = "default_ui_scale")]
    pub ui_scale: f64,
}

/// The UI scale the settings window offers, as a slider. Bounded so a stray
/// value in `settings.json` cannot make the island wider than the screen or
/// so small it stops being usable.
pub const UI_SCALE_MIN: f64 = 1.0;
pub const UI_SCALE_MAX: f64 = 2.0;

fn default_ui_scale() -> f64 {
    1.0
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
            ui_scale: default_ui_scale(),
        }
    }
}

impl Settings {
    /// Brings `ui_scale` back inside the range the slider offers. A file
    /// written by hand can hold anything, and every consumer of the setting —
    /// the window size, the pushed island shape, the zoom — has to agree on it,
    /// so it is made sane once, here, rather than defended at each use.
    pub fn clamp_ui_scale(&mut self) {
        if !self.ui_scale.is_finite() {
            self.ui_scale = default_ui_scale();
        }
        self.ui_scale = self.ui_scale.clamp(UI_SCALE_MIN, UI_SCALE_MAX);
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
        Ok(bytes) => {
            let mut settings = serde_json::from_slice::<Settings>(&bytes).unwrap_or_default();
            settings.clamp_ui_scale();
            settings
        }
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
    fn a_settings_file_written_before_the_scale_existed_loads_at_one() {
        // The whole point of `default`: an older settings.json has no
        // `uiScale`, and 1.0 is the size that file was written for.
        let json = serde_json::to_string(&Settings::default()).unwrap();
        let mut without = serde_json::from_str::<serde_json::Value>(&json).unwrap();
        without.as_object_mut().unwrap().remove("uiScale");
        let settings: Settings = serde_json::from_value(without).unwrap();

        assert_eq!(settings.ui_scale, 1.0);
    }

    #[test]
    fn a_scale_outside_the_offered_range_comes_back_inside_it() {
        let mut settings = Settings::default();
        settings.ui_scale = 9.0;
        settings.clamp_ui_scale();
        assert_eq!(settings.ui_scale, UI_SCALE_MAX);

        settings.ui_scale = 0.0;
        settings.clamp_ui_scale();
        assert_eq!(settings.ui_scale, UI_SCALE_MIN);

        // Not a number at all — an empty string, say.
        settings.ui_scale = f64::NAN;
        settings.clamp_ui_scale();
        assert_eq!(settings.ui_scale, 1.0);
    }

    #[test]
    fn the_default_scale_is_the_undisturbed_one() {
        assert_eq!(Settings::default().ui_scale, 1.0);
    }
}
