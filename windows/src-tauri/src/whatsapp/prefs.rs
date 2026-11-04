// WhatsApp's harmless choices (Settings → Integrations → WhatsApp), in whatsapp.json next to
// settings.json. Owned by Rust: the webview changes them through `whatsapp_set_prefs` only.
// The gateway's address, its credential and the webhook's secret are in the credential store,
// never here; no message, name or number is ever written here either (an ignored chat's id
// is the one exception, as on the Mac: it is what "Ignore" has to remember).

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

pub const DEFAULT_PORT: u16 = 47823;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    pub enabled: bool,
    /// "gowa" or "openwa".
    pub gateway: String,
    /// The webhook's port on 127.0.0.1.
    pub port: u16,
    /// Read receipts when a conversation is opened (on), or only when replying (off).
    pub mark_read_on_open: bool,
    pub mute_groups: bool,
    /// Normalized chat ids.
    pub ignored: Vec<String>,
    /// Coucou starts the GOWA binary at `gowa_path` itself.
    pub auto_start: bool,
    pub gowa_path: String,
    /// GOWA's version once installed by Coucou.
    pub gowa_version: Option<String>,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs {
            enabled: false,
            gateway: "gowa".into(),
            port: DEFAULT_PORT,
            mark_read_on_open: true,
            mute_groups: true,
            ignored: vec![],
            auto_start: false,
            gowa_path: String::new(),
            gowa_version: None,
        }
    }
}

impl Prefs {
    /// What a file (or the webview) may hold, brought back inside the rules.
    pub fn cleaned(mut self) -> Prefs {
        if self.gateway != "openwa" {
            self.gateway = "gowa".into();
        }
        if self.port < 1024 {
            self.port = DEFAULT_PORT;
        }
        self.ignored.retain(|id| !id.is_empty() && id.len() <= 128);
        self.ignored.sort();
        self.ignored.dedup();
        self.ignored.truncate(500);
        self.gowa_path = self.gowa_path.trim().to_string();
        self
    }
}

fn path() -> PathBuf {
    crate::platform::config_dir().join("whatsapp.json")
}

pub fn load() -> Prefs {
    std::fs::read(path()).ok().and_then(|b| serde_json::from_slice::<Prefs>(&b).ok()).unwrap_or_default().cleaned()
}

pub fn save(prefs: &Prefs) {
    let path = path();
    let Some(dir) = path.parent() else { return };
    let temp = path.with_extension(format!("json.coucou-{}", std::process::id()));
    let written = crate::platform::ensure_private_dir(dir)
        .and_then(|()| serde_json::to_vec_pretty(prefs).map_err(std::io::Error::other))
        .and_then(|json| std::fs::write(&temp, json))
        .and_then(|()| std::fs::rename(&temp, &path));
    if let Err(err) = written {
        let _ = std::fs::remove_file(&temp);
        crate::log::line(format!("whatsapp: could not save whatsapp.json: {err}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_and_cleaning() {
        let p: Prefs = serde_json::from_str("{}").unwrap();
        assert_eq!(p, Prefs::default());
        assert!(!p.enabled && p.mute_groups && p.mark_read_on_open && p.port == DEFAULT_PORT && p.gateway == "gowa");
        let odd: Prefs = serde_json::from_str(r#"{"gateway":"evil","port":80,"ignored":["b","a","b",""],"gowaPath":"  /x/gowa "}"#).unwrap();
        let odd = odd.cleaned();
        assert_eq!((odd.gateway.as_str(), odd.port), ("gowa", DEFAULT_PORT));
        assert_eq!(odd.ignored, ["a", "b"]);
        assert_eq!(odd.gowa_path, "/x/gowa");
        let json = serde_json::to_string(&Prefs::default()).unwrap();
        assert!(json.contains("\"markReadOnOpen\":true") && json.contains("\"muteGroups\":true"));
    }
}
