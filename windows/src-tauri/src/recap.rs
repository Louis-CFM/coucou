// Weekly recap history — port of RecapStore.swift.
//
// Every hook event the relay forwards also passes through here. A "turn" runs
// from a prompt (or the first tool call) to Stop, and only its counts and two
// names are kept: the agent's pill ID and the project folder's last path
// component. Never a command, a file path, file contents or a prompt.
//
// The history lives in recap.json under platform::local_dir()
// (%LOCALAPPDATA%\Nova on Windows, ~/.local/share/nova on Linux), keeps a
// 12-week rolling window and a hard cap on its length, and is written whole to
// a temporary file then renamed over the old one, so a crash never leaves half
// a file. Nothing in it ever leaves the machine.
//
// Aggregation (weeks, top agent, busiest day…) happens in the island
// (src/recap/summary.ts): it needs the user's time zone, which JavaScript has
// and plain Rust does not.

use std::collections::{HashMap, HashSet};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager, State};

use crate::island::WINDOW_LABEL;
use crate::platform;

/// 12 weeks, like the Mac.
pub const WINDOW_SECS: i64 = 12 * 7 * 86_400;
/// A turn with no event for two hours is closed at its last event (agent
/// crashed, or never sent Stop) — RecapStore.pruneStale.
const STALE_SECS: i64 = 2 * 3600;
/// Hard caps, whatever the window holds: about 2 MB of JSON at most.
const MAX_TURNS: usize = 10_000;
const MAX_DECISIONS: usize = 10_000;
const MAX_DRAFTS: usize = 256;
const MAX_REQUESTS: usize = 64;
const MAX_NAME_CHARS: usize = 64;
/// A recap.json larger than this was not written by us: set it aside.
const MAX_FILE_BYTES: u64 = 16 << 20;
/// A 1080 × 1920 PNG is ~1 MB; anything far larger is not our image.
const MAX_PNG_BYTES: usize = 24 << 20;

/// Same limits as DiffEngine.swift: beyond them, lines are counted, not diffed.
const DIFF_MAX_BYTES: usize = 200 * 1024;
const DIFF_MAX_LINES: usize = 4000;
const DIFF_MAX_CELLS: usize = 1_000_000;

/// Tool names that run a shell command, across the agents the relay serves.
const COMMAND_TOOLS: &[&str] = &[
    "Bash",
    "PowerShell",
    "Execute",
    "mcp__ide__executeCode",
    "run_shell_command",
    "shell",
    "local_shell",
    "exec_command",
    // Antigravity, and Copilot CLI's toolName, after the relay's normaliser.
    "run_command",
    "bash",
];

// ── Persisted model ───────────────────────────────────────────────────────────

/// One finished turn. Times are Unix seconds.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Turn {
    pub agent: String,
    pub project: String,
    pub start: i64,
    pub end: i64,
    pub files_changed: u32,
    pub lines_added: u32,
    pub lines_removed: u32,
    pub commands_run: u32,
    pub questions: u32,
}

/// A click on Allow or Deny in the island.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Decision {
    pub agent: String,
    pub date: i64,
    /// "allow" or "deny".
    pub decision: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    /// "Keep a history of my coding sessions" — on by default, like the Mac.
    pub enabled: bool,
    /// Leave the project name out of the shared image.
    pub hide_projects: bool,
    /// Monday (YYYY-MM-DD) of the week the recap was last shown on its own.
    pub last_shown_week: String,
}

impl Default for Prefs {
    fn default() -> Self {
        Self { enabled: true, hide_projects: false, last_shown_week: String::new() }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct History {
    schema_version: u32,
    turns: Vec<Turn>,
    decisions: Vec<Decision>,
    prefs: Prefs,
}

impl Default for History {
    fn default() -> Self {
        Self { schema_version: 1, turns: Vec::new(), decisions: Vec::new(), prefs: Prefs::default() }
    }
}

/// What the island reads: the part of the history it asked for.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryView {
    pub turns: Vec<Turn>,
    pub decisions: Vec<Decision>,
    pub prefs: Prefs,
}

/// A turn in progress, in memory only. The paths are only there to count
/// distinct files and are never written anywhere.
#[derive(Debug)]
struct Draft {
    agent: String,
    project: String,
    start: i64,
    last_event: i64,
    paths: HashSet<String>,
    lines_added: u32,
    lines_removed: u32,
    commands_run: u32,
    questions: u32,
}

impl Draft {
    fn into_turn(self, end: i64) -> Turn {
        Turn {
            agent: self.agent,
            project: self.project,
            start: self.start,
            end: end.max(self.start),
            files_changed: self.paths.len().min(u32::MAX as usize) as u32,
            lines_added: self.lines_added,
            lines_removed: self.lines_removed,
            commands_run: self.commands_run,
            questions: self.questions,
        }
    }
}

// ── Store ─────────────────────────────────────────────────────────────────────

pub struct Recap {
    path: PathBuf,
    history: History,
    drafts: HashMap<String, Draft>,
    /// Permission request ID → agent, until the island answers it.
    requests: HashMap<String, String>,
    /// The last image saved, so "Show in folder" never takes a path from the page.
    last_saved: Option<PathBuf>,
}

impl Recap {
    /// Reads `path`. A file that cannot be used is renamed aside, never lost.
    pub fn load(path: PathBuf, now: i64) -> Self {
        let history = read_history(&path);
        let mut recap = Self {
            path,
            history,
            drafts: HashMap::new(),
            requests: HashMap::new(),
            last_saved: None,
        };
        recap.prune(now);
        recap
    }

    /// One hook event, as the relay delivered it.
    pub fn observe(&mut self, payload: &Value, now: i64) {
        if !self.history.prefs.enabled {
            return;
        }
        self.close_stale(now);
        let event = text(payload, "hook_event_name");
        let agent = agent_id(payload);
        let key = session_key(payload, &agent);

        match event {
            "UserPromptSubmit" => {
                self.draft(&key, &agent, payload, now);
            }
            "PreToolUse" => {
                let tool = text(payload, "tool_name");
                let draft = self.draft(&key, &agent, payload, now);
                if COMMAND_TOOLS.contains(&tool) {
                    draft.commands_run = draft.commands_run.saturating_add(1);
                }
                if tool == "AskUserQuestion" {
                    draft.questions = draft.questions.saturating_add(1);
                }
            }
            "PostToolUse" => {
                let tool = text(payload, "tool_name");
                let input = payload.get("tool_input").unwrap_or(&Value::Null);
                let change = file_change(tool, input);
                let draft = self.draft(&key, &agent, payload, now);
                if let Some((path, added, removed)) = change {
                    draft.paths.insert(path);
                    draft.lines_added = draft.lines_added.saturating_add(added);
                    draft.lines_removed = draft.lines_removed.saturating_add(removed);
                }
            }
            // Unlike the Mac, SessionEnd closes the turn instead of dropping it:
            // a session quit mid-turn still worked.
            "Stop" | "StopFailure" | "Interrupt" | "SessionEnd" => {
                if let Some(draft) = self.drafts.remove(&key) {
                    self.history.turns.push(draft.into_turn(now));
                    self.prune(now);
                    self.save();
                }
            }
            _ => {}
        }
    }

    /// The draft for `key`, created on the first event of a turn.
    fn draft(&mut self, key: &str, agent: &str, payload: &Value, now: i64) -> &mut Draft {
        if !self.drafts.contains_key(key) && self.drafts.len() >= MAX_DRAFTS {
            self.close_oldest_draft();
        }
        let draft = self.drafts.entry(key.to_string()).or_insert_with(|| Draft {
            agent: agent.to_string(),
            project: project_name(text(payload, "cwd")),
            start: now,
            last_event: now,
            paths: HashSet::new(),
            lines_added: 0,
            lines_removed: 0,
            commands_run: 0,
            questions: 0,
        });
        draft.last_event = now;
        draft
    }

    fn close_oldest_draft(&mut self) {
        let Some(key) = self
            .drafts
            .iter()
            .min_by_key(|(_, d)| d.last_event)
            .map(|(k, _)| k.clone())
        else {
            return;
        };
        if let Some(draft) = self.drafts.remove(&key) {
            let end = draft.last_event;
            self.history.turns.push(draft.into_turn(end));
        }
    }

    /// RecapStore.pruneStale: turns silent for two hours count up to their
    /// last event instead of being lost.
    fn close_stale(&mut self, now: i64) {
        let stale: Vec<String> = self
            .drafts
            .iter()
            .filter(|(_, d)| d.last_event < now - STALE_SECS)
            .map(|(k, _)| k.clone())
            .collect();
        if stale.is_empty() {
            return;
        }
        for key in stale {
            if let Some(draft) = self.drafts.remove(&key) {
                let end = draft.last_event;
                self.history.turns.push(draft.into_turn(end));
            }
        }
        self.prune(now);
        self.save();
    }

    /// A permission request reached the island: remember whose it is.
    pub fn note_request(&mut self, request_id: &str, payload: &Value) {
        if self.requests.len() >= MAX_REQUESTS {
            self.requests.clear();
        }
        self.requests.insert(request_id.to_string(), agent_id(payload));
    }

    /// The request was handed back to the terminal: nothing to record.
    pub fn forget_request(&mut self, request_id: &str) {
        self.requests.remove(request_id);
    }

    /// A click on Allow or Deny.
    pub fn record_decision(&mut self, request_id: &str, decision: &str, now: i64) {
        let agent = self
            .requests
            .remove(request_id)
            .unwrap_or_else(|| "integration_claude".to_string());
        if !self.history.prefs.enabled {
            return;
        }
        let word = match decision {
            "allow" | "always" => "allow",
            "deny" => "deny",
            _ => return,
        };
        self.history.decisions.push(Decision { agent, date: now, decision: word.to_string() });
        self.prune(now);
        self.save();
    }

    /// Everything from `since` on (Unix seconds).
    pub fn view(&self, since: i64) -> HistoryView {
        HistoryView {
            turns: self.history.turns.iter().filter(|t| t.start >= since).cloned().collect(),
            decisions: self.history.decisions.iter().filter(|d| d.date >= since).cloned().collect(),
            prefs: self.history.prefs.clone(),
        }
    }

    pub fn prefs(&self) -> &Prefs {
        &self.history.prefs
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.history.prefs.enabled = enabled;
        if !enabled {
            self.drafts.clear();
            self.requests.clear();
        }
        self.save();
    }

    pub fn set_hide_projects(&mut self, hide: bool) {
        self.history.prefs.hide_projects = hide;
        self.save();
    }

    /// `week` is the Monday the recap was shown for, as YYYY-MM-DD.
    pub fn mark_shown(&mut self, week: &str) {
        if !is_week_key(week) {
            return;
        }
        self.history.prefs.last_shown_week = week.to_string();
        self.save();
    }

    /// Settings → General → Clear history. The preferences stay.
    pub fn clear(&mut self) {
        self.history.turns.clear();
        self.history.decisions.clear();
        self.drafts.clear();
        self.save();
    }

    /// 12-week window, then the hard caps (oldest first out).
    fn prune(&mut self, now: i64) {
        let cutoff = now - WINDOW_SECS;
        self.history.turns.retain(|t| t.start >= cutoff);
        self.history.decisions.retain(|d| d.date >= cutoff);
        if self.history.turns.len() > MAX_TURNS {
            self.history.turns.sort_by_key(|t| t.start);
            let excess = self.history.turns.len() - MAX_TURNS;
            self.history.turns.drain(..excess);
        }
        if self.history.decisions.len() > MAX_DECISIONS {
            self.history.decisions.sort_by_key(|d| d.date);
            let excess = self.history.decisions.len() - MAX_DECISIONS;
            self.history.decisions.drain(..excess);
        }
    }

    fn save(&self) {
        if let Err(err) = write_history(&self.path, &self.history) {
            note(format!("could not save the weekly recap history: {err}"));
        }
    }
}

// ── Reading and writing recap.json ────────────────────────────────────────────

fn read_history(path: &Path) -> History {
    let too_big = std::fs::metadata(path).is_ok_and(|m| m.len() > MAX_FILE_BYTES);
    let bytes = if too_big {
        None
    } else {
        match std::fs::read(path) {
            Ok(bytes) => Some(bytes),
            Err(err) if err.kind() == ErrorKind::NotFound => return History::default(),
            Err(err) => {
                note(format!("can't read {}: {err}", path.display()));
                // Unreadable is not corrupt: leave it, and start over in memory.
                // The first save will replace it, which only costs old counts.
                return History::default();
            }
        }
    };
    if let Some(history) = bytes.and_then(|b| serde_json::from_slice::<History>(&b).ok()) {
        return history;
    }
    // Keep the file as recap.json.corrupt-YYYYMMDD-HHMMSS, like the Mac.
    let t = platform::local_time();
    let aside = path.with_extension(format!(
        "json.corrupt-{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second
    ));
    match std::fs::rename(path, &aside) {
        Ok(()) => note(format!("{} was not usable — kept as {}", path.display(), aside.display())),
        Err(err) => note(format!("{} was not usable and could not be set aside: {err}", path.display())),
    }
    History::default()
}

/// Whole file to a temporary sibling, flushed, then renamed over the old one.
fn write_history(path: &Path, history: &History) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        platform::ensure_private_dir(dir)?;
    }
    let json = serde_json::to_vec(history)
        .map_err(|e| std::io::Error::new(ErrorKind::InvalidData, e))?;
    let temp = path.with_extension(format!("json.nova-{}", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let written = options
        .open(&temp)
        .and_then(|mut file| {
            file.write_all(&json)?;
            file.sync_all()
        })
        .and_then(|()| std::fs::rename(&temp, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

/// One line in nova.log. Tests must never write to the real one.
fn note(message: String) {
    #[cfg(not(test))]
    crate::log::line(message);
    #[cfg(test)]
    eprintln!("{message}");
}

// ── Reading a hook payload ────────────────────────────────────────────────────

fn text<'a>(payload: &'a Value, key: &str) -> &'a str {
    payload.get(key).and_then(Value::as_str).unwrap_or_default()
}

/// Same routing as hooks.ts, so a turn counts for the pill it showed on: a
/// valid `nova_agent` → `agent_<name>` (every agent the relay normalises,
/// Claude Desktop included); otherwise Claude Code's own pill — Cursor's when
/// it runs in Cursor's terminal, VS Code's else. "claude" is reserved.
fn agent_id(payload: &Value) -> String {
    let raw = text(payload, "nova_agent");
    let valid = !raw.is_empty()
        && raw.len() <= 24
        && raw != "claude"
        && raw.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
    if valid {
        format!("agent_{raw}")
    } else if text(payload, "term_editor") == "cursor" {
        "agent_cursor".to_string()
    } else {
        "integration_claude".to_string()
    }
}

/// Concurrent sessions are tracked apart; one without an ID is keyed by its
/// agent and folder, as HookServer.swift does.
fn session_key(payload: &Value, agent: &str) -> String {
    let id = text(payload, "session_id");
    if id.is_empty() || id == "unknown" {
        format!("{agent}+{}", text(payload, "cwd"))
    } else {
        id.to_string()
    }
}

/// The working folder's last component — the only part of a path ever kept.
fn project_name(cwd: &str) -> String {
    let trimmed = cwd.trim_end_matches(['/', '\\']);
    let last = trimmed.rsplit(['/', '\\']).next().unwrap_or_default();
    clean_name(last)
}

fn clean_name(raw: &str) -> String {
    raw.chars().filter(|c| !c.is_control()).take(MAX_NAME_CHARS).collect()
}

/// The file an Edit, MultiEdit or Write touched, with lines added and removed.
fn file_change(tool: &str, input: &Value) -> Option<(String, u32, u32)> {
    let path = input.get("file_path").and_then(Value::as_str)?;
    let (added, removed) = match tool {
        "Edit" => {
            let old = input.get("old_string").and_then(Value::as_str)?;
            let new = input.get("new_string").and_then(Value::as_str)?;
            line_diff(old, new)
        }
        "MultiEdit" => {
            let edits = input.get("edits").and_then(Value::as_array)?;
            edits.iter().fold((0u32, 0u32), |(a, r), edit| {
                let old = edit.get("old_string").and_then(Value::as_str).unwrap_or_default();
                let new = edit.get("new_string").and_then(Value::as_str).unwrap_or_default();
                let (da, dr) = line_diff(old, new);
                (a.saturating_add(da), r.saturating_add(dr))
            })
        }
        "Write" => {
            let content = input.get("content").and_then(Value::as_str)?;
            (count(split_lines(content).len()), 0)
        }
        _ => return None,
    };
    (added > 0 || removed > 0).then(|| (path.to_string(), added, removed))
}

fn count(n: usize) -> u32 {
    n.min(u32::MAX as usize) as u32
}

/// DiffEngine.splitLines: CRLF → LF, no trailing empty line.
fn split_lines(text: &str) -> Vec<&str> {
    if text.is_empty() {
        return Vec::new();
    }
    let mut lines: Vec<&str> = text.split('\n').map(|l| l.strip_suffix('\r').unwrap_or(l)).collect();
    if lines.last() == Some(&"") {
        lines.pop();
    }
    lines
}

/// Lines added and removed between `old` and `new`, from their longest common
/// subsequence — the counts DiffEngine.fromEdit gives. Past its size limits
/// every old line counts as removed and every new one as added.
pub fn line_diff(old: &str, new: &str) -> (u32, u32) {
    let a = split_lines(old);
    let b = split_lines(new);
    let fallback = (count(b.len()), count(a.len()));
    if old.len() + new.len() > DIFF_MAX_BYTES
        || a.len() + b.len() > DIFF_MAX_LINES
        || a.len().saturating_mul(b.len()) > DIFF_MAX_CELLS
    {
        return fallback;
    }
    let mut prev = vec![0usize; b.len() + 1];
    let mut row = vec![0usize; b.len() + 1];
    for x in &a {
        for (j, y) in b.iter().enumerate() {
            row[j + 1] = if x == y { prev[j] + 1 } else { prev[j + 1].max(row[j]) };
        }
        std::mem::swap(&mut prev, &mut row);
    }
    let lcs = prev[b.len()];
    (count(b.len() - lcs), count(a.len() - lcs))
}

fn is_week_key(week: &str) -> bool {
    week.len() == 10
        && week.bytes().enumerate().all(|(i, b)| if i == 4 || i == 7 { b == b'-' } else { b.is_ascii_digit() })
}

// ── Saving the shared image ───────────────────────────────────────────────────

/// Standard base64, with or without a `data:…;base64,` prefix.
fn decode_base64(data: &str) -> Option<Vec<u8>> {
    let body = match data.split_once(',') {
        Some((head, rest)) if head.starts_with("data:") => rest,
        _ => data,
    };
    let mut out = Vec::with_capacity(body.len() / 4 * 3);
    let mut acc = 0u32;
    let mut bits = 0u32;
    let mut padding = false;
    for b in body.bytes() {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => {
                padding = true;
                continue;
            }
            b'\r' | b'\n' => continue,
            _ => return None,
        };
        if padding {
            return None;
        }
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

const PNG_SIGNATURE: &[u8] = &[0x89, b'P', b'N', b'G', b'\r', b'\n', 0x1A, b'\n'];

/// Writes `bytes` as `<stem>.png` in `dir`, or `<stem> (2).png`… when that name
/// is taken. An existing file is never replaced.
fn write_unique(dir: &Path, stem: &str, bytes: &[u8]) -> std::io::Result<PathBuf> {
    for n in 1..1000 {
        let name = if n == 1 { format!("{stem}.png") } else { format!("{stem} ({n}).png") };
        let path = dir.join(name);
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut file) => {
                let written = file.write_all(bytes).and_then(|()| file.sync_all());
                drop(file);
                if let Err(err) = written {
                    let _ = std::fs::remove_file(&path);
                    return Err(err);
                }
                return Ok(path);
            }
            Err(err) if err.kind() == ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }
    Err(std::io::Error::new(ErrorKind::AlreadyExists, "too many recap images with this name"))
}

/// The PNG the page rendered, checked and written to the first pictures folder
/// that exists.
fn save_png(dirs: &[PathBuf], data: &str, week: &str) -> Result<PathBuf, String> {
    if data.len() > MAX_PNG_BYTES / 3 * 4 + 64 {
        return Err(crate::i18n::t("The image is too large."));
    }
    let bytes = decode_base64(data).ok_or_else(|| crate::i18n::t("The image could not be read."))?;
    if !bytes.starts_with(PNG_SIGNATURE) {
        return Err(crate::i18n::t("The image could not be read."));
    }
    let dir = dirs
        .iter()
        .find(|d| d.is_dir())
        .ok_or_else(|| crate::i18n::t("No Pictures or Downloads folder to save into."))?;
    let stem = if is_week_key(week) {
        format!("Nova weekly recap {week}")
    } else {
        "Nova weekly recap".to_string()
    };
    write_unique(dir, &stem, &bytes)
        .map_err(|err| crate::i18n::tf("Could not save the image: {error}", &[("error", &err.to_string())]))
}

// ── Tauri glue ────────────────────────────────────────────────────────────────

pub struct Store(Mutex<Recap>);

impl Store {
    fn lock(&self) -> MutexGuard<'_, Recap> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

fn now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn load() -> Store {
    Store(Mutex::new(Recap::load(platform::local_dir().join("recap.json"), now())))
}

/// Called by the relay server for every hook event. An agent starting work is
/// also one of the moments the Monday recap may show up.
pub fn observe(app: &AppHandle, payload: &Value) {
    if let Some(store) = app.try_state::<Store>() {
        store.lock().observe(payload, now());
    }
    if matches!(text(payload, "hook_event_name"), "SessionStart" | "UserPromptSubmit") {
        let _ = app.emit_to(WINDOW_LABEL, "recap-check", ());
    }
}

pub fn note_request(app: &AppHandle, request_id: &str, payload: &Value) {
    if let Some(store) = app.try_state::<Store>() {
        store.lock().note_request(request_id, payload);
    }
}

pub fn forget_request(app: &AppHandle, request_id: &str) {
    if let Some(store) = app.try_state::<Store>() {
        store.lock().forget_request(request_id);
    }
}

pub fn record_decision(app: &AppHandle, request_id: &str, decision: &str) {
    if let Some(store) = app.try_state::<Store>() {
        store.lock().record_decision(request_id, decision, now());
    }
}

#[tauri::command]
pub fn recap_history(store: State<Store>, since: i64) -> HistoryView {
    store.lock().view(since)
}

#[tauri::command]
pub fn recap_prefs(store: State<Store>) -> Prefs {
    store.lock().prefs().clone()
}

#[tauri::command]
pub fn recap_set_enabled(store: State<Store>, enabled: bool) {
    store.lock().set_enabled(enabled);
}

#[tauri::command]
pub fn recap_set_hide_projects(store: State<Store>, hide: bool) {
    store.lock().set_hide_projects(hide);
}

#[tauri::command]
pub fn recap_mark_shown(store: State<Store>, week: String) {
    store.lock().mark_shown(&week);
}

#[tauri::command]
pub fn recap_clear(store: State<Store>) {
    store.lock().clear();
}

/// `data` is the canvas's PNG as a data URL. Returns where it was written.
#[tauri::command]
pub fn recap_save_png(store: State<Store>, data: String, week: String) -> Result<String, String> {
    let path = save_png(&platform::picture_dirs(), &data, &week)?;
    let shown = path.to_string_lossy().to_string();
    store.lock().last_saved = Some(path);
    Ok(shown)
}

/// Opens the folder of the image saved last — never a path from the page.
#[tauri::command]
pub fn recap_reveal_saved(store: State<Store>) {
    let dir = store.lock().last_saved.as_ref().and_then(|p| p.parent().map(Path::to_path_buf));
    if let Some(dir) = dir {
        platform::reveal_folder(&dir.to_string_lossy());
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const HOUR: i64 = 3600;
    /// Monday 5 October 2026, 00:00 UTC — the exact zone does not matter here.
    const T0: i64 = 1_791_158_400;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nova-recap-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn event(name: &str, session: &str, extra: Value) -> Value {
        let mut v = json!({ "hook_event_name": name, "session_id": session, "cwd": "/home/me/code/nova" });
        if let (Some(obj), Value::Object(more)) = (v.as_object_mut(), extra) {
            obj.extend(more);
        }
        v
    }

    fn on_disk(path: &Path) -> Value {
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn a_turn_is_counted_from_prompt_to_stop() {
        let dir = scratch("turn");
        let file = dir.join("recap.json");
        let mut r = Recap::load(file.clone(), T0);
        r.observe(&event("UserPromptSubmit", "s1", json!({ "prompt": "secret plan" })), T0);
        r.observe(&event("PreToolUse", "s1", json!({ "tool_name": "Bash", "tool_input": { "command": "rm -rf /tmp/x" } })), T0 + 10);
        r.observe(&event("PreToolUse", "s1", json!({ "tool_name": "Read" })), T0 + 20);
        r.observe(&event("PreToolUse", "s1", json!({ "tool_name": "AskUserQuestion" })), T0 + 25);
        r.observe(&event("PostToolUse", "s1", json!({ "tool_name": "Edit", "tool_input": {
            "file_path": "/home/me/code/nova/a.rs", "old_string": "a\nb\nc", "new_string": "a\nB\nc\nd" } })), T0 + 30);
        r.observe(&event("PostToolUse", "s1", json!({ "tool_name": "Write", "tool_input": {
            "file_path": "/home/me/code/nova/b.rs", "content": "one\ntwo\nthree\n" } })), T0 + 40);
        r.observe(&event("PostToolUse", "s1", json!({ "tool_name": "Edit", "tool_input": {
            "file_path": "/home/me/code/nova/a.rs", "old_string": "x", "new_string": "y" } })), T0 + 50);
        r.observe(&event("Stop", "s1", json!({})), T0 + HOUR);

        let view = r.view(0);
        assert_eq!(view.turns, vec![Turn {
            agent: "integration_claude".into(),
            project: "nova".into(),
            start: T0,
            end: T0 + HOUR,
            files_changed: 2,
            lines_added: 2 + 3 + 1,
            lines_removed: 1 + 1,
            commands_run: 1,
            questions: 1,
        }]);

        // Only counts and names reach the disk.
        let written = std::fs::read_to_string(&file).unwrap();
        for secret in ["secret plan", "rm -rf", "a.rs", "/home/me", "one\\ntwo"] {
            assert!(!written.contains(secret), "{secret} must not be stored");
        }
        assert_eq!(on_disk(&file)["turns"][0]["project"], "nova");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn concurrent_sessions_and_agents_are_kept_apart() {
        let dir = scratch("sessions");
        let mut r = Recap::load(dir.join("recap.json"), T0);
        r.observe(&event("UserPromptSubmit", "a", json!({})), T0);
        r.observe(&event("UserPromptSubmit", "b", json!({ "nova_agent": "gemini", "cwd": "C:\\Users\\me\\side-project\\" })), T0 + 60);
        r.observe(&event("PreToolUse", "b", json!({ "nova_agent": "gemini", "tool_name": "run_shell_command" })), T0 + 70);
        r.observe(&event("Stop", "a", json!({})), T0 + 120);
        r.observe(&event("Stop", "b", json!({ "nova_agent": "gemini" })), T0 + 180);
        let turns = r.view(0).turns;
        assert_eq!(turns.len(), 2);
        assert_eq!((turns[0].agent.as_str(), turns[0].commands_run), ("integration_claude", 0));
        assert_eq!(turns[1].agent, "agent_gemini");
        assert_eq!(turns[1].project, "side-project");
        assert_eq!(turns[1].commands_run, 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn invalid_or_reserved_agent_tags_fall_back_to_claude_code() {
        for tag in ["claude", "Gemini", "has space", "a-very-long-agent-name-over-24"] {
            assert_eq!(agent_id(&json!({ "nova_agent": tag })), "integration_claude", "{tag}");
        }
        assert_eq!(agent_id(&json!({ "nova_agent": "codex" })), "agent_codex");
    }

    #[test]
    fn a_turn_counts_for_the_pill_it_showed_on() {
        // Claude Code in Cursor's terminal is the Cursor pill, as in hooks.ts.
        assert_eq!(agent_id(&json!({ "term_editor": "cursor" })), "agent_cursor");
        // An explicit agent wins over the terminal it runs in.
        assert_eq!(agent_id(&json!({ "nova_agent": "claude-desktop", "term_editor": "cursor" })), "agent_claude-desktop");
        assert_eq!(agent_id(&json!({ "nova_agent": "copilot" })), "agent_copilot");
        assert_eq!(agent_id(&json!({})), "integration_claude");
    }

    #[test]
    fn a_turn_silent_for_two_hours_ends_at_its_last_event() {
        let dir = scratch("stale");
        let mut r = Recap::load(dir.join("recap.json"), T0);
        r.observe(&event("UserPromptSubmit", "s1", json!({})), T0);
        r.observe(&event("PreToolUse", "s1", json!({ "tool_name": "Bash" })), T0 + 600);
        // Next event, from another session, three hours later.
        r.observe(&event("UserPromptSubmit", "s2", json!({})), T0 + 3 * HOUR);
        let turns = r.view(0).turns;
        assert_eq!(turns.len(), 1);
        assert_eq!((turns[0].start, turns[0].end), (T0, T0 + 600));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn decisions_are_recorded_with_the_agent_that_asked() {
        let dir = scratch("decisions");
        let mut r = Recap::load(dir.join("recap.json"), T0);
        r.note_request("r1", &json!({ "nova_agent": "codex" }));
        r.record_decision("r1", "always", T0);
        r.record_decision("unknown", "deny", T0 + 1);
        r.record_decision("r3", "maybe", T0 + 2);
        r.note_request("r4", &json!({}));
        r.forget_request("r4");
        let d = r.view(0).decisions;
        assert_eq!(d.len(), 2);
        assert_eq!((d[0].agent.as_str(), d[0].decision.as_str()), ("agent_codex", "allow"));
        assert_eq!((d[1].agent.as_str(), d[1].decision.as_str()), ("integration_claude", "deny"));
        assert!(r.requests.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn twelve_weeks_are_kept_and_older_entries_pruned() {
        let dir = scratch("prune");
        let file = dir.join("recap.json");
        let mut r = Recap::load(file.clone(), T0);
        let old = T0 - WINDOW_SECS - 1;
        let edge = T0 - WINDOW_SECS;
        for start in [old, edge, T0 - HOUR] {
            r.history.turns.push(Turn {
                agent: "integration_claude".into(), project: "p".into(), start, end: start + 60,
                files_changed: 0, lines_added: 0, lines_removed: 0, commands_run: 0, questions: 0,
            });
        }
        r.history.decisions.push(Decision { agent: "integration_claude".into(), date: old, decision: "allow".into() });
        r.prune(T0);
        r.save();
        assert_eq!(r.view(0).turns.iter().map(|t| t.start).collect::<Vec<_>>(), [edge, T0 - HOUR]);
        assert!(r.view(0).decisions.is_empty());
        // Loading later prunes again.
        let later = Recap::load(file, T0 + 2 * HOUR);
        assert_eq!(later.view(0).turns.len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_history_never_grows_past_its_cap() {
        let dir = scratch("cap");
        let mut r = Recap::load(dir.join("recap.json"), T0);
        for i in 0..(MAX_TURNS as i64 + 5) {
            r.history.turns.push(Turn {
                agent: "a".into(), project: "p".into(), start: T0 - i, end: T0,
                files_changed: 0, lines_added: 0, lines_removed: 0, commands_run: 0, questions: 0,
            });
        }
        r.prune(T0);
        assert_eq!(r.history.turns.len(), MAX_TURNS);
        // The oldest went.
        assert_eq!(r.history.turns.first().unwrap().start, T0 - MAX_TURNS as i64 + 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn names_are_cut_short_and_cleaned() {
        let long = "x".repeat(200);
        assert_eq!(project_name(&format!("/a/{long}")).chars().count(), MAX_NAME_CHARS);
        assert_eq!(project_name("/a/b\u{7}c/"), "bc");
        assert_eq!(project_name(""), "");
        assert_eq!(project_name("C:\\work\\korus"), "korus");
    }

    #[test]
    fn line_counts_match_the_diff_engine() {
        assert_eq!(line_diff("a\nb\nc", "a\nb\nc"), (0, 0));
        assert_eq!(line_diff("a\nb\nc", "a\nx\nc"), (1, 1));
        assert_eq!(line_diff("", "a\nb\n"), (2, 0));
        assert_eq!(line_diff("a\r\nb\r\n", "a\nb\nc\n"), (1, 0));
        // Too big to diff: everything counts.
        let big_old = "l\n".repeat(3000);
        let big_new = "l\n".repeat(1500);
        assert_eq!(line_diff(&big_old, &big_new), (1500, 3000));
        assert_eq!(file_change("Read", &json!({ "file_path": "/x" })), None);
        assert_eq!(file_change("Edit", &json!({ "file_path": "/x", "old_string": "a", "new_string": "a" })), None);
        let multi = json!({ "file_path": "/x", "edits": [
            { "old_string": "a", "new_string": "b" }, { "old_string": "", "new_string": "c\nd" } ] });
        assert_eq!(file_change("MultiEdit", &multi), Some(("/x".into(), 3, 1)));
    }

    #[test]
    fn a_disabled_history_records_nothing_and_clear_keeps_the_prefs() {
        let dir = scratch("disabled");
        let file = dir.join("recap.json");
        let mut r = Recap::load(file.clone(), T0);
        r.observe(&event("UserPromptSubmit", "s", json!({})), T0);
        r.observe(&event("Stop", "s", json!({})), T0 + 60);
        r.set_hide_projects(true);
        r.mark_shown("2026-10-05");
        r.mark_shown("not a week");
        r.clear();
        assert!(r.view(0).turns.is_empty());
        let reloaded = Recap::load(file.clone(), T0);
        assert_eq!(reloaded.prefs(), &Prefs { enabled: true, hide_projects: true, last_shown_week: "2026-10-05".into() });

        r.set_enabled(false);
        r.observe(&event("UserPromptSubmit", "s", json!({})), T0);
        r.observe(&event("Stop", "s", json!({})), T0 + 60);
        r.note_request("r", &json!({}));
        r.record_decision("r", "allow", T0);
        assert!(r.view(0).turns.is_empty() && r.view(0).decisions.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_corrupt_file_is_set_aside_and_writes_leave_nothing_behind() {
        let dir = scratch("corrupt");
        let file = dir.join("recap.json");
        std::fs::write(&file, b"{ not json").unwrap();
        let mut r = Recap::load(file.clone(), T0);
        assert!(r.view(0).turns.is_empty());
        let names = |d: &Path| -> Vec<String> {
            let mut n: Vec<String> = std::fs::read_dir(d).unwrap()
                .map(|e| e.unwrap().file_name().to_string_lossy().to_string()).collect();
            n.sort();
            n
        };
        let aside = names(&dir);
        assert_eq!(aside.len(), 1);
        assert!(aside[0].starts_with("recap.json.corrupt-"), "{aside:?}");
        assert_eq!(std::fs::read(dir.join(&aside[0])).unwrap(), b"{ not json");

        r.observe(&event("UserPromptSubmit", "s", json!({})), T0);
        r.observe(&event("Stop", "s", json!({})), T0 + 60);
        let mut expected = vec!["recap.json".to_string(), aside[0].clone()];
        expected.sort();
        assert_eq!(names(&dir), expected);
        assert_eq!(on_disk(&file)["schemaVersion"], 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn base64_round_trips_and_rejects_junk() {
        assert_eq!(decode_base64("data:image/png;base64,aGVsbG8=").unwrap(), b"hello");
        assert_eq!(decode_base64("aGk=").unwrap(), b"hi");
        assert_eq!(decode_base64("YWJj").unwrap(), b"abc");
        assert!(decode_base64("a$b").is_none());
        assert!(decode_base64("aGk=aGk=").is_none());
    }

    #[test]
    fn a_saved_image_never_replaces_an_existing_file() {
        let dir = scratch("png");
        let missing = dir.join("missing");
        let png = "data:image/png;base64,iVBORw0KGgo=";
        let first = save_png(&[missing.clone(), dir.clone()], png, "2026-10-05").unwrap();
        let second = save_png(&[dir.clone()], png, "2026-10-05").unwrap();
        assert_eq!(first, dir.join("Nova weekly recap 2026-10-05.png"));
        assert_eq!(second, dir.join("Nova weekly recap 2026-10-05 (2).png"));
        // The week is a date or nothing: no path tricks through it.
        let third = save_png(&[dir.clone()], png, "../../x").unwrap();
        assert_eq!(third, dir.join("Nova weekly recap.png"));
        // Not a PNG: refused.
        assert!(save_png(&[dir.clone()], "data:image/png;base64,aGVsbG8=", "").is_err());
        assert!(save_png(&[missing], png, "").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
