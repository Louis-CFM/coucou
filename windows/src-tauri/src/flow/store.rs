// Everything the Coucou window shows and edits about dictation: the history,
// the numbers, the dictionary, the snippets, the styles and the preferences.
// Small JSON files in the app's folder (%LOCALAPPDATA%\Coucou\Flow or
// ~/.local/share/coucou/Flow), on this computer only. Port of FlowStore.swift.

use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

use super::logic::FlowKey;
use super::text::{self, new_id, Day, Replacement, Snippet};

/// One dictation, kept for the history.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub id: String,
    /// Milliseconds since 1970.
    pub date: u64,
    pub text: String,
    /// The app it was pasted in ("Slack"), when known.
    #[serde(default)]
    pub app: Option<String>,
    pub words: u64,
    /// How long you spoke.
    pub seconds: f64,
}

/// The numbers of one day. Kept even when the history is emptied.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DayStats {
    pub words: u64,
    pub seconds: f64,
    pub dictations: u64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Stats {
    /// "2026-10-14" → that day's numbers.
    pub days: BTreeMap<String, DayStats>,
    /// App name → words dictated in it.
    pub apps: BTreeMap<String, u64>,
}

/// How the words are written in an app, when the clean-up is on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Style {
    /// Only the dictionary, replacements and snippets: code, terminals, AI chats.
    Verbatim,
    /// Without the "um" and the repeats, punctuation fixed, the tone kept.
    #[default]
    Natural,
    /// Full sentences, for mails.
    Polished,
}

/// An app with its own style. `id` is the program's name in lower case
/// ("outlook", "slack", "windowsterminal"), what the foreground window tells.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AppStyle {
    pub id: String,
    pub name: String,
    pub style: Style,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Edge {
    #[default]
    Bottom,
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SummaryEngine {
    #[default]
    Claude,
    Off,
}

/// The preferences of dictation and of the window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    /// Hold a key to dictate anywhere. Off until the user turns it on.
    pub enabled: bool,
    pub key: FlowKey,
    pub edge: Edge,
    /// The microphone by name; empty is the system's default.
    pub mic: String,
    /// Days the history is kept: 0 = not kept, -1 = forever.
    pub keep_days: i64,
    /// Clean the words with Claude before pasting them (needs the Claude key).
    pub cleanup: bool,
    /// The style of the apps that have none of their own.
    pub default_style: Style,
    pub summary_engine: SummaryEngine,
    /// Open the Coucou window when Coucou is opened (not when it starts with the computer).
    pub open_at_launch: bool,
    /// « OK Coucou »: listen for it and answer with Claude (needs the Claude key).
    pub voice: bool,
    /// How Coucou answers out loud: "system", "elevenlabs" or "off".
    pub voice_output: String,
    /// The ElevenLabs voice: "female" or "male".
    pub voice_gender: String,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            enabled: false,
            key: FlowKey::default(),
            edge: Edge::Bottom,
            mic: String::new(),
            keep_days: 30,
            cleanup: false,
            default_style: Style::Natural,
            summary_engine: SummaryEngine::Claude,
            open_at_launch: true,
            voice: false,
            voice_output: "system".into(),
            voice_gender: "female".into(),
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Words {
    pub words: Vec<String>,
    pub replacements: Vec<Replacement>,
}

/// Apps that get a style from the start: mails polished, chats natural, code
/// and AI chats as said.
pub fn default_app_styles() -> Vec<AppStyle> {
    let s = |id: &str, name: &str, style| AppStyle { id: id.into(), name: name.into(), style };
    vec![
        s("outlook", "Outlook", Style::Polished),
        s("olk", "Outlook (new)", Style::Polished),
        s("thunderbird", "Thunderbird", Style::Polished),
        s("slack", "Slack", Style::Natural),
        s("discord", "Discord", Style::Natural),
        s("whatsapp", "WhatsApp", Style::Natural),
        s("telegram", "Telegram", Style::Natural),
        s("teams", "Microsoft Teams", Style::Natural),
        s("claude", "Claude", Style::Verbatim),
        s("windowsterminal", "Windows Terminal", Style::Verbatim),
        s("code", "Visual Studio Code", Style::Verbatim),
        s("cursor", "Cursor", Style::Verbatim),
        s("gnome-terminal-server", "Terminal", Style::Verbatim),
        s("konsole", "Konsole", Style::Verbatim),
        s("kitty", "kitty", Style::Verbatim),
    ]
}

pub struct Store {
    pub history: Vec<Entry>,
    pub stats: Stats,
    pub words: Words,
    pub snippets: Vec<Snippet>,
    pub app_styles: Vec<AppStyle>,
    pub prefs: Prefs,
    /// When the history is not kept, the last dictation still waits here
    /// (memory only) for "paste again".
    last_unkept: Option<String>,
    folder: PathBuf,
}

fn load<T: DeserializeOwned>(folder: &std::path::Path, name: &str) -> Option<T> {
    let text = std::fs::read_to_string(folder.join(name)).ok()?;
    serde_json::from_str(&text).ok()
}

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn today() -> Day {
    let t = crate::platform::local_time();
    Day { year: t.year as i32, month: t.month, day: t.day }
}

impl Store {
    pub fn folder() -> PathBuf {
        crate::settings::local_dir().join("Flow")
    }

    pub fn load() -> Store {
        Self::load_from(Self::folder())
    }

    pub fn load_from(folder: PathBuf) -> Store {
        let mut store = Store {
            history: load(&folder, "history.json").unwrap_or_default(),
            stats: load(&folder, "stats.json").unwrap_or_default(),
            words: load(&folder, "words.json").unwrap_or_default(),
            snippets: load(&folder, "snippets.json").unwrap_or_default(),
            app_styles: load(&folder, "styles.json").unwrap_or_else(default_app_styles),
            prefs: load(&folder, "prefs.json").unwrap_or_default(),
            last_unkept: None,
            folder,
        };
        store.prune(now_ms());
        store
    }

    fn write<T: Serialize>(&self, value: &T, name: &str) -> std::io::Result<()> {
        crate::platform::ensure_private_dir(&self.folder)?;
        let text = serde_json::to_string_pretty(value).map_err(std::io::Error::other)?;
        let tmp = self.folder.join(format!("{name}.tmp"));
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, self.folder.join(name))
    }

    fn save<T: Serialize>(&self, value: &T, name: &str) {
        if let Err(err) = self.write(value, name) {
            crate::log::line(format!("flow: could not save {name}: {err}"));
        }
    }

    pub fn save_prefs(&self) {
        self.save(&self.prefs, "prefs.json");
    }
    pub fn set_words(&mut self, words: Words) -> Result<(), String> {
        self.write(&words, "words.json").map_err(|e| format!("Could not save dictionary: {e}"))?;
        self.words = words;
        Ok(())
    }
    pub fn set_snippets(&mut self, snippets: Vec<Snippet>) -> Result<(), String> {
        self.write(&snippets, "snippets.json").map_err(|e| format!("Could not save snippets: {e}"))?;
        self.snippets = snippets;
        Ok(())
    }
    pub fn set_styles(&mut self, styles: Vec<AppStyle>) -> Result<(), String> {
        self.write(&styles, "styles.json").map_err(|e| format!("Could not save app styles: {e}"))?;
        self.app_styles = styles;
        Ok(())
    }
    fn save_history(&self) {
        self.save(&self.history, "history.json");
    }
    fn save_stats(&self) {
        self.save(&self.stats, "stats.json");
    }

    /// The words with the replacements and the dictionary's spelling, snippets set aside.
    pub fn prepare(&self, raw: &str) -> text::Prepared {
        text::prepare(raw, &self.words.words, &self.words.replacements, &self.snippets)
    }

    pub fn style_for(&self, app: Option<&str>) -> Style {
        app.and_then(|id| self.app_styles.iter().find(|s| s.id == id))
            .map(|s| s.style)
            .unwrap_or(self.prefs.default_style)
    }

    /// The last thing dictated, for "paste again".
    pub fn last_text(&self) -> Option<String> {
        self.history.first().map(|e| e.text.clone()).or_else(|| self.last_unkept.clone())
    }

    pub fn record(&mut self, text: &str, app: Option<&str>, seconds: f64, day: Day, now: u64) -> Option<Entry> {
        let count = text::word_count(text) as u64;
        if count == 0 {
            return None;
        }
        let d = self.stats.days.entry(day.key()).or_default();
        d.words += count;
        d.seconds += seconds;
        d.dictations += 1;
        if let Some(app) = app.filter(|a| !a.is_empty()) {
            *self.stats.apps.entry(app.to_string()).or_default() += count;
        }
        self.save_stats();
        if self.prefs.keep_days == 0 {
            self.last_unkept = Some(text.to_string());
            return None;
        }
        let entry = Entry { id: new_id(), date: now, text: text.to_string(), app: app.map(String::from), words: count, seconds };
        self.history.insert(0, entry.clone());
        self.prune(now);
        self.save_history();
        Some(entry)
    }

    fn set_history(&mut self, history: Vec<Entry>) -> Result<(), String> {
        self.write(&history, "history.json").map_err(|e| format!("Could not update dictation history: {e}"))?;
        self.history = history;
        Ok(())
    }

    pub fn delete(&mut self, id: &str) -> Result<(), String> {
        self.set_history(self.history.iter().filter(|e| e.id != id).cloned().collect())
    }

    /// Empties the history; the numbers stay.
    pub fn clear_history(&mut self) -> Result<(), String> {
        self.set_history(Vec::new())?;
        self.last_unkept = None;
        Ok(())
    }

    /// Empties the history and the numbers.
    pub fn clear_everything(&mut self) -> Result<(), String> {
        self.clear_history()?;
        let stats = Stats::default();
        self.write(&stats, "stats.json").map_err(|e| format!("History erased; could not erase statistics: {e}"))?;
        self.stats = stats;
        Ok(())
    }

    pub fn prune(&mut self, now: u64) {
        let before = self.history.len();
        if self.prefs.keep_days == 0 {
            self.history.clear();
        } else if self.prefs.keep_days > 0 {
            let limit = now.saturating_sub(self.prefs.keep_days as u64 * 86_400_000);
            self.history.retain(|e| e.date >= limit);
        }
        if self.history.len() != before {
            self.save_history();
        }
    }

    pub fn streak(&self, today: Day) -> u32 {
        let days: HashSet<String> = self.stats.days.iter().filter(|(_, d)| d.words > 0).map(|(k, _)| k.clone()).collect();
        text::streak(&days, today)
    }

    /// Words, seconds and dictations since `from` (None: everything).
    pub fn totals(&self, from: Option<Day>) -> (u64, f64, u64) {
        let from = from.map(Day::key);
        let mut out = (0, 0.0, 0);
        for (key, d) in &self.stats.days {
            if from.as_ref().is_none_or(|f| key >= f) {
                out.0 += d.words;
                out.1 += d.seconds;
                out.2 += d.dictations;
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_store() -> (Store, PathBuf) {
        let dir = std::env::temp_dir().join(format!("coucou-flow-{}-{}", std::process::id(), new_id()));
        (Store::load_from(dir.clone()), dir)
    }

    #[test]
    fn dictionary_edits_are_durable_and_failed_writes_keep_the_live_and_saved_words() {
        let (mut store, path) = temp_store();
        let words = Words { words: vec!["Coucou".into()], replacements: vec![
            Replacement { id: "one".into(), from: "cloud code".into(), to: "Claude Code".into() },
        ] };
        store.set_words(words.clone()).unwrap();
        assert_eq!(Store::load_from(path.clone()).words, words);
        let before = std::fs::read(path.join("words.json")).unwrap();
        std::fs::create_dir(path.join("words.json.tmp")).unwrap();
        assert!(store.set_words(Words::default()).is_err());
        assert_eq!(store.words, words);
        assert_eq!(std::fs::read(path.join("words.json")).unwrap(), before);
        assert_eq!(store.prepare("coucou cloud code").text, "Coucou Claude Code");
        std::fs::remove_dir(path.join("words.json.tmp")).unwrap();
        store.set_words(Words::default()).unwrap();
        assert_eq!(Store::load_from(path.clone()).words, Words::default());
        std::fs::remove_file(path.join("words.json")).unwrap();
        std::fs::remove_dir(path).unwrap();
    }

    #[test]
    fn snippet_edits_are_durable_and_failed_writes_keep_the_live_and_saved_snippets() {
        let (mut store, path) = temp_store();
        let snippets = vec![Snippet { id: "one".into(), trigger: "signature".into(), text: "Hello world".into() }];
        store.set_snippets(snippets.clone()).unwrap();
        assert_eq!(Store::load_from(path.clone()).snippets, snippets);
        let before = std::fs::read(path.join("snippets.json")).unwrap();
        std::fs::create_dir(path.join("snippets.json.tmp")).unwrap();
        assert!(store.set_snippets(vec![]).is_err());
        assert_eq!(store.snippets, snippets);
        assert_eq!(std::fs::read(path.join("snippets.json")).unwrap(), before);
        assert_eq!(store.prepare("signature").snippets.values().next().unwrap(), "Hello world");
        std::fs::remove_dir(path.join("snippets.json.tmp")).unwrap();
        store.set_snippets(vec![]).unwrap();
        assert!(Store::load_from(path.clone()).snippets.is_empty());
        std::fs::remove_file(path.join("snippets.json")).unwrap();
        std::fs::remove_dir(path).unwrap();
    }

    #[test]
    fn style_edits_are_durable_and_failed_writes_keep_the_live_and_saved_styles() {
        let (mut store, path) = temp_store();
        let styles = vec![AppStyle { id: "mail".into(), name: "Mail".into(), style: Style::Polished }];
        store.set_styles(styles.clone()).unwrap();
        assert_eq!(Store::load_from(path.clone()).app_styles, styles);
        let before = std::fs::read(path.join("styles.json")).unwrap();
        std::fs::create_dir(path.join("styles.json.tmp")).unwrap();
        assert!(store.set_styles(vec![]).is_err());
        assert_eq!(store.app_styles, styles);
        assert_eq!(std::fs::read(path.join("styles.json")).unwrap(), before);
        assert_eq!(store.style_for(Some("mail")), Style::Polished);
        std::fs::remove_dir(path.join("styles.json.tmp")).unwrap();
        store.set_styles(vec![]).unwrap();
        assert!(Store::load_from(path.clone()).app_styles.is_empty());
        std::fs::remove_file(path.join("styles.json")).unwrap();
        std::fs::remove_dir(path).unwrap();
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn locked_editor_files_reject_replacement_without_changing_live_values() {
        use std::os::windows::fs::OpenOptionsExt;
        let (mut store, path) = temp_store();
        store.set_words(Words::default()).unwrap();
        store.set_snippets(vec![]).unwrap();
        store.set_styles(vec![]).unwrap();
        let locks: Vec<_> = ["words", "snippets", "styles"].iter().map(|name|
            std::fs::OpenOptions::new().read(true).share_mode(0).open(path.join(format!("{name}.json"))).unwrap()
        ).collect();
        assert!(store.set_words(Words { words: vec!["unsaved".into()], replacements: vec![] }).is_err());
        assert!(store.set_snippets(vec![Snippet { id: "one".into(), trigger: "unsaved".into(), text: "unsaved".into() }]).is_err());
        assert!(store.set_styles(default_app_styles()).is_err());
        assert!(store.words.words.is_empty());
        assert!(store.snippets.is_empty());
        assert!(store.app_styles.is_empty());
        drop(locks);
        let again = Store::load_from(path.clone());
        assert!(again.words.words.is_empty());
        assert!(again.snippets.is_empty());
        assert!(again.app_styles.is_empty());
        for name in ["words", "snippets", "styles"] {
            std::fs::remove_file(path.join(format!("{name}.json"))).unwrap();
            std::fs::remove_file(path.join(format!("{name}.json.tmp"))).unwrap();
        }
        std::fs::remove_dir(path).unwrap();
    }

    #[test]
    fn failed_history_deletion_keeps_live_and_saved_entries_until_retry() {
        let (mut store, path) = temp_store();
        let entry = store.record("saved dictation", None, 1.0, today(), now_ms()).unwrap();
        let before = std::fs::read(path.join("history.json")).unwrap();
        std::fs::create_dir(path.join("history.json.tmp")).unwrap();
        assert!(store.delete(&entry.id).is_err());
        assert_eq!(store.history.len(), 1);
        assert_eq!(store.history[0].id, entry.id);
        assert_eq!(std::fs::read(path.join("history.json")).unwrap(), before);
        std::fs::remove_dir(path.join("history.json.tmp")).unwrap();
        store.delete(&entry.id).unwrap();
        assert!(store.history.is_empty());
        assert!(Store::load_from(path.clone()).history.is_empty());
        assert_eq!(store.totals(None).0, 2);
        for name in ["history.json", "stats.json"] { std::fs::remove_file(path.join(name)).unwrap(); }
        std::fs::remove_dir(path).unwrap();
    }

    #[test]
    fn failed_history_clear_keeps_the_last_dictation_and_statistics() {
        let (mut store, path) = temp_store();
        store.record("saved dictation", None, 1.0, today(), now_ms()).unwrap();
        store.last_unkept = Some("memory dictation".into());
        std::fs::create_dir(path.join("history.json.tmp")).unwrap();
        assert!(store.clear_everything().is_err());
        assert_eq!(store.history.len(), 1);
        assert_eq!(store.last_unkept.as_deref(), Some("memory dictation"));
        assert_eq!(store.totals(None).0, 2);
        let again = Store::load_from(path.clone());
        assert_eq!(again.history.len(), 1);
        assert_eq!(again.totals(None).0, 2);
        std::fs::remove_dir(path.join("history.json.tmp")).unwrap();
        store.clear_history().unwrap();
        assert!(store.history.is_empty());
        assert!(store.last_unkept.is_none());
        assert_eq!(store.totals(None).0, 2);
        for name in ["history.json", "stats.json"] { std::fs::remove_file(path.join(name)).unwrap(); }
        std::fs::remove_dir(path).unwrap();
    }

    #[test]
    fn a_failed_statistics_erase_keeps_live_and_saved_counts_and_can_be_retried() {
        let (mut store, path) = temp_store();
        store.record("saved dictation", None, 1.0, today(), now_ms()).unwrap();
        std::fs::create_dir(path.join("stats.json.tmp")).unwrap();
        assert!(store.clear_everything().unwrap_err().contains("History erased; could not erase statistics"));
        // History is already durably erased; the statistics remain until their write succeeds.
        assert!(store.history.is_empty());
        assert_eq!(store.totals(None).0, 2);
        let again = Store::load_from(path.clone());
        assert!(again.history.is_empty());
        assert_eq!(again.totals(None).0, 2);
        std::fs::remove_dir(path.join("stats.json.tmp")).unwrap();
        store.clear_everything().unwrap();
        assert_eq!(store.totals(None).0, 0);
        assert_eq!(Store::load_from(path.clone()).totals(None).0, 0);
        for name in ["history.json", "stats.json"] { std::fs::remove_file(path.join(name)).unwrap(); }
        std::fs::remove_dir(path).unwrap();
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn locked_history_and_statistics_files_report_failed_replacements() {
        use std::os::windows::fs::OpenOptionsExt;
        let (mut store, path) = temp_store();
        let entry = store.record("saved dictation", None, 1.0, today(), now_ms()).unwrap();
        let history_lock = std::fs::OpenOptions::new().read(true).share_mode(0).open(path.join("history.json")).unwrap();
        assert!(store.delete(&entry.id).is_err());
        assert!(store.clear_everything().is_err());
        assert_eq!(store.history.len(), 1);
        assert_eq!(store.totals(None).0, 2);
        drop(history_lock);
        assert_eq!(Store::load_from(path.clone()).history.len(), 1);

        let stats_lock = std::fs::OpenOptions::new().read(true).share_mode(0).open(path.join("stats.json")).unwrap();
        assert!(store.clear_everything().unwrap_err().contains("History erased; could not erase statistics"));
        assert!(store.history.is_empty());
        assert_eq!(store.totals(None).0, 2);
        drop(stats_lock);
        assert_eq!(Store::load_from(path.clone()).totals(None).0, 2);
        store.clear_everything().unwrap();
        let again = Store::load_from(path.clone());
        assert!(again.history.is_empty());
        assert_eq!(again.totals(None).0, 0);
        for name in ["history.json", "stats.json"] { std::fs::remove_file(path.join(name)).unwrap(); }
        std::fs::remove_dir(path).unwrap();
    }

    #[test]
    fn a_dictation_counts_and_is_kept_for_the_chosen_days() {
        let (mut s, dir) = temp_store();
        let day = Day { year: 2026, month: 10, day: 14 };
        let now = 1_800_000_000_000;
        s.record("bonjour à tous", Some("slack"), 2.0, day, now).unwrap();
        s.record("?", None, 1.0, day, now);
        assert_eq!(s.history.len(), 1);
        assert_eq!(s.stats.days["2026-10-14"].words, 3);
        assert_eq!(s.stats.apps["slack"], 3);
        assert_eq!(s.streak(day), 1);
        assert_eq!(s.totals(None), (3, 2.0, 1));
        // Older than 30 days: gone from the history, still in the numbers.
        s.prune(now + 31 * 86_400_000);
        assert!(s.history.is_empty());
        assert_eq!(s.totals(Some(day)).0, 3);
        // Not kept: the last one still waits for "paste again".
        s.prefs.keep_days = 0;
        assert!(s.record("encore un mot", None, 1.0, day, now).is_none());
        assert_eq!(s.last_text().as_deref(), Some("encore un mot"));
        // Saved on disk and read back.
        let again = Store::load_from(dir.clone());
        assert_eq!(again.stats.days["2026-10-14"].dictations, 2);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn styles_follow_the_app_or_the_default() {
        let (mut s, dir) = temp_store();
        assert_eq!(s.style_for(Some("outlook")), Style::Polished);
        assert_eq!(s.style_for(Some("code")), Style::Verbatim);
        assert_eq!(s.style_for(Some("notepad")), Style::Natural);
        s.prefs.default_style = Style::Polished;
        assert_eq!(s.style_for(None), Style::Polished);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn prefs_read_from_an_older_file_keep_their_defaults() {
        let p: Prefs = serde_json::from_str(r#"{"enabled":true,"key":"right_alt"}"#).unwrap();
        assert!(p.enabled);
        assert_eq!(p.key, FlowKey::RightAlt);
        assert_eq!(p.keep_days, 30);
        assert!(p.open_at_launch);
    }
}
