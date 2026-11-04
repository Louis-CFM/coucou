// The Mail section's settings, the journal of what Coucou sorted, what it sent for the chat,
// and the messages the automatic sorting already looked at. Small JSON files in
// %APPDATA%\Coucou\mail, on this computer only (MailTriageStore.swift on the Mac).

use std::path::PathBuf;

use serde::{de::DeserializeOwned, Deserialize, Serialize};

use super::triage::{Action, Reason, Settings};

/// One thing Coucou did to a message: shown in the Mail section, with its Undo.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct JournalEntry {
    pub id: String,
    pub date: i64,
    pub account: String,
    pub store_id: String,
    /// The message's EntryID after the action (a moved message gets a new one).
    pub entry_id: String,
    pub sender: String,
    pub subject: String,
    pub action: Action,
    pub reason: Reason,
    #[serde(default)]
    pub undone: bool,
}

/// A mail Coucou sent for the chat (a plan the user ran).
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SentEntry {
    pub id: String,
    pub date: i64,
    pub to: Vec<String>,
    pub subject: String,
    pub attachments: Vec<String>,
}

#[derive(Default)]
pub struct Store {
    pub settings: Settings,
    pub journal: Vec<JournalEntry>,
    pub sent: Vec<SentEntry>,
    seen: Vec<String>,
    seen_set: std::collections::HashSet<String>,
    dir: Option<PathBuf>,
}

const KEEP: usize = 500;
const SEEN: usize = 4000;

impl Store {
    pub fn load(dir: PathBuf) -> Store {
        let seen: Vec<String> = read(&dir, "seen.json").unwrap_or_default();
        Store {
            settings: read(&dir, "settings.json").unwrap_or_default(),
            journal: read(&dir, "journal.json").unwrap_or_default(),
            sent: read(&dir, "sent.json").unwrap_or_default(),
            seen_set: seen.iter().cloned().collect(),
            seen,
            dir: Some(dir),
        }
    }

    pub fn set_settings(&mut self, mut s: Settings, now: i64) {
        // Only what arrives from now on: Coucou never goes through the old messages.
        if s.auto_sort && !self.settings.auto_sort {
            s.auto_sort_since = Some(now);
        }
        self.settings = s;
        self.write("settings.json", &self.settings);
    }

    pub fn add_banned(&mut self, word: &str) {
        let w = word.trim();
        if w.is_empty() || self.settings.banned.iter().any(|b| super::triage::normalize(b) == super::triage::normalize(w)) {
            return;
        }
        self.settings.banned.push(w.to_string());
        self.write("settings.json", &self.settings);
    }

    pub fn add_vip(&mut self, entry: &str) {
        let e = entry.trim();
        if e.is_empty() || self.settings.vip.iter().any(|v| super::triage::normalize(v) == super::triage::normalize(e)) {
            return;
        }
        self.settings.vip.push(e.to_string());
        self.write("settings.json", &self.settings);
    }

    pub fn is_seen(&self, id: &str) -> bool {
        self.seen_set.contains(id)
    }

    pub fn mark_seen(&mut self, ids: &[String]) {
        let fresh: Vec<String> = ids.iter().filter(|i| !self.seen_set.contains(*i)).cloned().collect();
        if fresh.is_empty() {
            return;
        }
        for id in &fresh {
            self.seen_set.insert(id.clone());
        }
        self.seen.extend(fresh);
        if self.seen.len() > SEEN {
            let drop = self.seen.len() - SEEN;
            self.seen.drain(..drop);
            self.seen_set = self.seen.iter().cloned().collect();
        }
        self.write("seen.json", &self.seen);
    }

    pub fn record(&mut self, entry: JournalEntry) {
        self.journal.insert(0, entry);
        self.journal.truncate(KEEP);
        self.write("journal.json", &self.journal);
    }

    pub fn mark_undone(&mut self, id: &str) {
        if let Some(e) = self.journal.iter_mut().find(|e| e.id == id) {
            e.undone = true;
            self.write("journal.json", &self.journal);
        }
    }

    pub fn clear_journal(&mut self) {
        self.journal.clear();
        self.write("journal.json", &self.journal);
    }

    pub fn record_sent(&mut self, entry: SentEntry) {
        self.sent.insert(0, entry);
        self.sent.truncate(KEEP);
        self.write("sent.json", &self.sent);
    }

    fn write<T: Serialize>(&self, name: &str, value: &T) {
        let Some(dir) = &self.dir else { return };
        let result = std::fs::create_dir_all(dir)
            .and_then(|_| serde_json::to_vec_pretty(value).map_err(std::io::Error::other))
            .and_then(|bytes| {
                let tmp = dir.join(format!("{name}.tmp"));
                std::fs::write(&tmp, bytes)?;
                std::fs::rename(&tmp, dir.join(name))
            });
        if let Err(e) = result {
            crate::log::line(format!("[mail] could not save {name}: {e}"));
        }
    }
}

fn read<T: DeserializeOwned>(dir: &std::path::Path, name: &str) -> Option<T> {
    serde_json::from_slice(&std::fs::read(dir.join(name)).ok()?).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turning_sorting_on_starts_from_now_and_files_survive() {
        let dir = std::env::temp_dir().join(format!("coucou-mail-store-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let mut s = Store::load(dir.clone());
        s.set_settings(Settings { auto_sort: true, ..Default::default() }, 1234);
        assert_eq!(s.settings.auto_sort_since, Some(1234));
        s.set_settings(Settings { auto_sort: true, auto_sort_since: Some(1234), banned: vec!["promo".into()], ..Default::default() }, 9999);
        assert_eq!(s.settings.auto_sort_since, Some(1234), "already on: the start stays");
        s.add_banned("PROMO");
        assert_eq!(s.settings.banned.len(), 1, "no duplicate, whatever the case");
        s.mark_seen(&["a".into(), "b".into()]);
        s.record(JournalEntry { id: "j".into(), date: 1, account: "a".into(), store_id: "s".into(), entry_id: "e".into(),
            sender: "x".into(), subject: "y".into(), action: Action::Junk, reason: Reason::Manual, undone: false });
        let again = Store::load(dir.clone());
        assert!(again.is_seen("a") && !again.is_seen("c"));
        assert_eq!(again.journal.len(), 1);
        assert_eq!(again.settings.banned, vec!["promo"]);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
