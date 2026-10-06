// Preferences, stored as plain JSON in %APPDATA%\Coucou\settings.json.
// No secret ever lands here — API keys live in the Windows Credential Manager.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::hindsight::HindsightSettings;
use crate::hotkeys::Hotkeys;

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
    /// "anthropic" (default) or "router" — the user's OpenAI-compatible 9router.
    #[serde(default = "default_chat_provider")]
    pub chat_provider: String,
    /// 9router base URL, e.g. https://host/9router/v1. Empty until configured.
    #[serde(default)]
    pub router_base_url: String,
    /// "+ New task": the folder used last time.
    #[serde(default)]
    pub last_task_folder: String,
    /// "+ New task": "cli" or "desktop", last used per agent id.
    #[serde(default)]
    pub last_task_targets: BTreeMap<String, String>,
    /// "+ New task": what was last used per agent and target, keyed
    /// "agent/target" (e.g. "claude/cli"). Never holds a prompt.
    #[serde(default)]
    pub task_profiles: BTreeMap<String, TaskProfile>,
    /// Global shortcuts. An empty field means "off".
    #[serde(default)]
    pub hotkeys: Hotkeys,
    /// Speech-to-text model asked of 9router's /audio/transcriptions.
    #[serde(default = "default_stt_model")]
    pub stt_model: String,
    /// Locked: the island cannot be dragged. Unlocked: drag it anywhere.
    #[serde(default = "default_true")]
    pub island_locked: bool,
    /// Where the user dragged the island (top-centre, physical px). None =
    /// top-centre of the display chosen by `screen`.
    #[serde(default)]
    pub island_position: Option<crate::placement::Anchor>,
    /// The first-launch "Coucou found: … Set them up?" offer was already made.
    #[serde(default)]
    pub setup_offered: bool,
    /// Robot agents in fallback order: "hermes:<profile>", "hermes", "codex".
    #[serde(default = "default_robot_agents")]
    pub robot_agents: Vec<String>,
    /// Robot actions that need no Allow/Deny card, matched strictly. Empty
    /// until the user adds one: nothing reaches other people unasked.
    #[serde(default)]
    pub robot_preapproved: Vec<String>,
    /// Started (hidden) when the robot's browser is not answering on :9222.
    /// Empty until the user sets it.
    #[serde(default)]
    pub robot_browser_start: String,
    #[serde(default)]
    pub hindsight: HindsightSettings,
}

fn default_true() -> bool {
    true
}

fn default_robot_agents() -> Vec<String> {
    crate::robot::DEFAULT_AGENTS.iter().map(|s| s.to_string()).collect()
}

const MAX_ROBOT_ENTRY: usize = 500;
const MAX_ROBOT_ENTRIES: usize = 50;

fn clean_list(list: &mut Vec<String>) {
    let mut out: Vec<String> = Vec::new();
    for item in list.iter() {
        let flat: String = item.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
        let t: String = flat.trim().chars().take(MAX_ROBOT_ENTRY).collect();
        if !t.is_empty() && !out.contains(&t) && out.len() < MAX_ROBOT_ENTRIES {
            out.push(t);
        }
    }
    *list = out;
}

pub const DEFAULT_STT_MODEL: &str = crate::voice::DEFAULT_MODEL;

fn default_stt_model() -> String {
    DEFAULT_STT_MODEL.to_string()
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskProfile {
    #[serde(default)]
    pub folder: String,
}

/// "claude/cli", "kimi-code/desktop"… — the key of `task_profiles`.
pub fn task_profile_key(agent: &str, target: &str) -> String {
    format!("{agent}/{target}")
}

fn valid_profile_key(key: &str) -> bool {
    key.split_once('/').is_some_and(|(agent, target)| {
        crate::launch::Agent::parse(agent).is_some() && crate::launch::Target::parse(target).is_some()
    })
}

fn default_model() -> String {
    crate::claude::DEFAULT_MODEL.to_string()
}

fn default_chat_provider() -> String {
    "anthropic".to_string()
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
            chat_provider: default_chat_provider(),
            router_base_url: String::new(),
            last_task_folder: String::new(),
            last_task_targets: BTreeMap::new(),
            task_profiles: BTreeMap::new(),
            hotkeys: Hotkeys::default(),
            stt_model: default_stt_model(),
            island_locked: true,
            island_position: None,
            setup_offered: false,
            robot_agents: default_robot_agents(),
            robot_preapproved: Vec::new(),
            robot_browser_start: String::new(),
            hindsight: HindsightSettings::default(),
        }
    }
}

impl Settings {
    /// Unknown providers fall back to Anthropic; a valid 9router URL is stored
    /// in its normalised form (an invalid one is kept so the error stays visible).
    pub fn sanitize(&mut self) {
        if self.chat_provider != "router" {
            self.chat_provider = default_chat_provider();
        }
        let trimmed = self.router_base_url.trim();
        self.router_base_url = if trimmed.is_empty() {
            String::new()
        } else {
            crate::router::normalize_base_url(trimmed).unwrap_or_else(|_| trimmed.to_string())
        };
        self.last_task_targets
            .retain(|agent, target| crate::launch::Agent::parse(agent).is_some() && crate::launch::Target::parse(target).is_some());
        self.task_profiles.retain(|key, _| valid_profile_key(key));
        self.hotkeys.sanitize();
        self.stt_model = crate::router::validate_model(&self.stt_model).unwrap_or_else(|_| default_stt_model());
        clean_list(&mut self.robot_agents);
        self.robot_agents.retain(|a| crate::robot::AgentSpec::parse(a).is_some());
        if self.robot_agents.is_empty() {
            self.robot_agents = default_robot_agents();
        }
        clean_list(&mut self.robot_preapproved);
        self.robot_browser_start = self.robot_browser_start.trim().to_string();
        self.hindsight.sanitize();
    }

    /// The folder to offer for this agent and target: its own saved one, else
    /// the last folder used by any launch, else empty.
    pub fn task_folder(&self, agent: &str, target: &str) -> String {
        self.task_profiles
            .get(&task_profile_key(agent, target))
            .map(|p| p.folder.trim())
            .filter(|f| !f.is_empty())
            .unwrap_or(self.last_task_folder.trim())
            .to_string()
    }

    /// After a launch went through: remember its folder for this agent and
    /// target, as the global last folder, and the target for the agent.
    pub fn remember_task(&mut self, agent: &str, target: &str, folder: &str) {
        self.last_task_folder = folder.to_string();
        self.last_task_targets.insert(agent.to_string(), target.to_string());
        self.task_profiles
            .entry(task_profile_key(agent, target))
            .or_default()
            .folder = folder.to_string();
    }
}

pub use crate::platform::{config_dir, local_dir};

pub fn hook_exe_path() -> PathBuf {
    local_dir().join("bin").join("coucou-hook.exe")
}

fn settings_path() -> PathBuf {
    config_dir().join("settings.json")
}

pub fn load() -> Settings {
    match std::fs::read(settings_path()) {
        Ok(bytes) => serde_json::from_slice::<Settings>(&bytes)
            .map(|mut s| {
                s.sanitize();
                s
            })
            .unwrap_or_default(),
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

#[cfg(test)]
mod tests {
    use super::Settings;

    const LEGACY_NO_MODEL: &str = r#"{
        "soundEnabled": true, "soundVolume": 0.1, "autoCloseInterval": 15.0,
        "absenceInterval": 180.0, "activeIntegrations": ["integration_github"],
        "screen": "cursor", "autostart": false, "hooksInstalled": true
    }"#;

    #[test]
    fn settings_from_an_older_build_still_load() {
        let s: Settings = serde_json::from_str(LEGACY_NO_MODEL).unwrap();
        assert_eq!(s.screen, "cursor");
        assert!(s.hooks_installed);
        assert_eq!(s.model, crate::claude::DEFAULT_MODEL);
        assert_eq!(s.chat_provider, "anthropic");
        assert_eq!(s.router_base_url, "");
        assert_eq!(s.last_task_folder, "");
        assert!(s.last_task_targets.is_empty());
    }

    #[test]
    fn hindsight_settings_default_for_older_files() {
        let s: Settings = serde_json::from_str(LEGACY_NO_MODEL).unwrap();
        assert_eq!(
            s.hindsight,
            super::HindsightSettings {
                enabled: false,
                base_url: "https://hindsight.example.com/hindsight".into(),
                tenant: "default".into(),
                bank: "hieu".into(),
                automatic_recall: true,
                inferred_retention: true,
                allow_development_http: false,
            }
        );
    }

    #[test]
    fn partial_hindsight_settings_use_per_field_defaults() {
        let json = LEGACY_NO_MODEL.replace(
            "\"hooksInstalled\": true",
            "\"hooksInstalled\": true, \"hindsight\": {\"enabled\": true, \"tenant\": \"team\"}",
        );
        let s: Settings = serde_json::from_str(&json).unwrap();
        assert!(s.hindsight.enabled);
        assert_eq!(s.hindsight.base_url, "https://hindsight.example.com/hindsight");
        assert_eq!(s.hindsight.tenant, "team");
        assert_eq!(s.hindsight.bank, "hieu");
        assert!(s.hindsight.automatic_recall);
        assert!(s.hindsight.inferred_retention);
        assert!(!s.hindsight.allow_development_http);
    }

    #[test]
    fn hindsight_settings_sanitize_empty_segments_without_enabling_memory() {
        let mut s = Settings::default();
        s.hindsight.enabled = false;
        s.hindsight.tenant = " \t".into();
        s.hindsight.bank = "\n".into();
        s.sanitize();
        assert_eq!(s.hindsight.tenant, "default");
        assert_eq!(s.hindsight.bank, "hieu");
        assert!(!s.hindsight.enabled);
    }

    #[test]
    fn task_launcher_memory_round_trips_and_drops_junk() {
        let mut s = Settings { last_task_folder: r"C:\work".into(), ..Settings::default() };
        s.last_task_targets.insert("codex".into(), "desktop".into());
        s.last_task_targets.insert("gpt".into(), "cli".into());
        s.last_task_targets.insert("hermes".into(), "web".into());
        s.sanitize();
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["lastTaskFolder"], r"C:\work");
        assert_eq!(json["lastTaskTargets"], serde_json::json!({ "codex": "desktop" }));
    }

    #[test]
    fn older_task_memory_still_loads_and_feeds_every_profile() {
        let json = LEGACY_NO_MODEL.replace(
            "\"hooksInstalled\": true",
            r#""hooksInstalled": true, "lastTaskFolder": "C:\\old", "lastTaskTargets": {"codex": "desktop"}"#,
        );
        let s: Settings = serde_json::from_str(&json).unwrap();
        assert!(s.task_profiles.is_empty());
        assert_eq!(s.last_task_targets.get("codex").map(String::as_str), Some("desktop"));
        for agent in ["claude", "codex", "kimi-code", "hermes"] {
            for target in ["cli", "desktop"] {
                assert_eq!(s.task_folder(agent, target), r"C:\old");
            }
        }
        assert_eq!(Settings::default().task_folder("claude", "cli"), "");
    }

    #[test]
    fn task_profiles_are_kept_per_agent_and_target() {
        let mut s = Settings::default();
        s.remember_task("claude", "cli", r"C:\a");
        s.remember_task("kimi-code", "desktop", r"C:\b");
        assert_eq!(s.task_folder("claude", "cli"), r"C:\a");
        assert_eq!(s.task_folder("kimi-code", "desktop"), r"C:\b");
        // No profile of its own: the last folder used anywhere.
        assert_eq!(s.task_folder("claude", "desktop"), r"C:\b");
        assert_eq!(s.task_folder("hermes", "cli"), r"C:\b");
        assert_eq!(s.last_task_targets.get("kimi-code").map(String::as_str), Some("desktop"));

        s.task_profiles.insert("gpt/cli".into(), super::TaskProfile { folder: "x".into() });
        s.task_profiles.insert("claude/web".into(), super::TaskProfile { folder: "x".into() });
        s.task_profiles.insert("claude".into(), super::TaskProfile { folder: "x".into() });
        s.sanitize();
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(
            json["taskProfiles"],
            serde_json::json!({ "claude/cli": { "folder": r"C:\a" }, "kimi-code/desktop": { "folder": r"C:\b" } })
        );
        let back: Settings = serde_json::from_value(json).unwrap();
        assert_eq!(back.task_folder("claude", "cli"), r"C:\a");
        assert_eq!(super::task_profile_key("hermes", "desktop"), "hermes/desktop");
    }

    #[test]
    fn hotkeys_and_stt_model_default_for_older_files() {
        let s: Settings = serde_json::from_str(LEGACY_NO_MODEL).unwrap();
        assert_eq!(s.hotkeys, crate::hotkeys::Hotkeys::default());
        assert_eq!(s.hotkeys.chat, "Ctrl+Alt+C");
        assert_eq!(s.hotkeys.task, "Ctrl+Alt+N");
        assert_eq!(s.hotkeys.voice, "Ctrl+Alt+V");
        assert_eq!(s.stt_model, "groq/whisper-large-v3");

        let partial = LEGACY_NO_MODEL.replace(
            "\"hooksInstalled\": true",
            r#""hooksInstalled": true, "hotkeys": {"chat": "Ctrl+Shift+K"}"#,
        );
        let s: Settings = serde_json::from_str(&partial).unwrap();
        assert_eq!(s.hotkeys.chat, "Ctrl+Shift+K");
        assert_eq!(s.hotkeys.task, "Ctrl+Alt+N");
    }

    #[test]
    fn sanitize_normalises_hotkeys_and_keeps_bad_ones_visible() {
        let mut s = Settings::default();
        s.hotkeys.chat = " ctrl + alt + space ".into();
        s.hotkeys.task = "Ctrl+Banana".into();
        s.hotkeys.voice = "".into();
        s.stt_model = "a
b".into();
        s.sanitize();
        assert_eq!(s.hotkeys.chat, "Ctrl+Alt+Space");
        assert_eq!(s.hotkeys.task, "Ctrl+Banana");
        assert_eq!(s.hotkeys.voice, "");
        assert_eq!(s.stt_model, "groq/whisper-large-v3");
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["hotkeys"]["chat"], "Ctrl+Alt+Space");
        assert_eq!(json["sttModel"], "groq/whisper-large-v3");
    }

    #[test]
    fn island_placement_defaults_to_locked_top_centre_and_round_trips() {
        let s: Settings = serde_json::from_str(LEGACY_NO_MODEL).unwrap();
        assert!(s.island_locked);
        assert_eq!(s.island_position, None);

        let moved = LEGACY_NO_MODEL.replace(
            "\"hooksInstalled\": true",
            r#""hooksInstalled": true, "islandLocked": false, "islandPosition": {"x": -900, "y": 120}"#,
        );
        let s: Settings = serde_json::from_str(&moved).unwrap();
        assert!(!s.island_locked);
        assert_eq!(s.island_position, Some(crate::placement::Anchor { x: -900, y: 120 }));
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["islandLocked"], false);
        assert_eq!(json["islandPosition"], serde_json::json!({ "x": -900, "y": 120 }));
        let reset = Settings { island_position: None, ..s };
        assert!(serde_json::to_value(&reset).unwrap()["islandPosition"].is_null());
    }

    #[test]
    fn robot_settings_default_for_older_files_and_are_cleaned() {
        let s: Settings = serde_json::from_str(LEGACY_NO_MODEL).unwrap();
        assert_eq!(s.robot_agents, vec!["hermes:amanda", "codex"]);
        assert!(s.robot_preapproved.is_empty(), "nothing is pre-approved unless the user adds it");
        assert!(s.robot_browser_start.is_empty(), "no machine-specific path by default");
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["robotAgents"], serde_json::json!(["hermes:amanda", "codex"]));
        assert!(json["robotPreapproved"].is_array());
        assert!(json["robotBrowserStart"].is_string());

        let mut s = Settings {
            robot_agents: vec!["codex".into(), "gpt".into(), " codex ".into()],
            robot_preapproved: vec!["  a\nb ".into(), "".into(), "a b".into()],
            robot_browser_start: "  C:\\x.cmd ".into(),
            ..Settings::default()
        };
        s.sanitize();
        assert_eq!(s.robot_agents, vec!["codex"]);
        assert_eq!(s.robot_preapproved, vec!["a b"]);
        assert_eq!(s.robot_browser_start, "C:\\x.cmd");
        s.robot_agents = vec!["nope".into()];
        s.sanitize();
        assert_eq!(s.robot_agents, vec!["hermes:amanda", "codex"]);
    }

    #[test]
    fn a_saved_model_survives_the_new_fields() {
        let json = LEGACY_NO_MODEL.replace("\"hooksInstalled\": true", "\"hooksInstalled\": true, \"model\": \"claude-sonnet-5\"");
        let s: Settings = serde_json::from_str(&json).unwrap();
        assert_eq!(s.model, "claude-sonnet-5");
        assert_eq!(s.chat_provider, "anthropic");
    }

    #[test]
    fn router_fields_round_trip_in_camel_case() {
        let s = Settings {
            chat_provider: "router".into(),
            router_base_url: "https://router.example.com/9router/v1".into(),
            model: "cc-claude-opus-5-5".into(),
            ..Settings::default()
        };
        let json = serde_json::to_value(&s).unwrap();
        assert_eq!(json["chatProvider"], "router");
        assert_eq!(json["routerBaseUrl"], "https://router.example.com/9router/v1");
        let back: Settings = serde_json::from_value(json).unwrap();
        assert_eq!(back.chat_provider, "router");
        assert_eq!(back.model, "cc-claude-opus-5-5");
    }

    #[test]
    fn sanitize_normalises_the_url_and_unknown_providers() {
        let mut s = Settings {
            chat_provider: "something-else".into(),
            router_base_url: " https://router.example.com/9router/v1/ ".into(),
            ..Settings::default()
        };
        s.sanitize();
        assert_eq!(s.chat_provider, "anthropic");
        assert_eq!(s.router_base_url, "https://router.example.com/9router/v1");

        s.chat_provider = "router".into();
        s.router_base_url = "http://example.com/v1".into();
        s.sanitize();
        assert_eq!(s.chat_provider, "router");
        assert_eq!(s.router_base_url, "http://example.com/v1");
    }
}
