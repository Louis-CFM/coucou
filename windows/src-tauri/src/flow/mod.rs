// Flow dictation: hold a key anywhere, speak, let go, and the words are pasted
// where you type. Port of FlowDictation.swift for Windows and Linux.
//
// One thread owns the dictation: the key's events come in from the OS listener
// (os_windows.rs / os_linux.rs) and the pill's buttons, KeyLogic turns them
// into start / lock / finish / cancel, the microphone is opened on the first
// press, and when you let go the words go to Parakeet on this computer, then
// through the dictionary, the snippets and (if turned on) Claude's clean-up,
// and are pasted. The thread sleeps on its channel while nothing happens.

pub mod cleanup;
pub mod logic;
pub mod paste;
pub mod pill;
pub mod store;
pub mod text;

#[cfg(windows)]
#[path = "os_windows.rs"]
pub mod os;
#[cfg(target_os = "linux")]
#[path = "os_linux.rs"]
pub mod os;
#[cfg(target_os = "linux")]
pub mod wayland;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};

use crate::i18n::t;
use crate::speech::{self, audio};
use logic::{Action, KeyLogic};
use store::{AppStyle, Entry, Prefs, Store, Words};
use text::Snippet;

/// What reaches the dictation thread.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyEvent {
    Down,
    Up,
    /// Another key while the dictation key is held: a shortcut.
    Other,
    Escape,
    /// The pill's microphone: hands-free straight away.
    HandsFree,
    /// The pill's ✓: paste now.
    Finish,
    /// The pill's ✕.
    Cancel,
    Quit,
}

pub struct Flow {
    pub store: Mutex<Store>,
    running: Mutex<Option<Running>>,
}

struct Running {
    tx: Sender<(KeyEvent, Instant)>,
    /// The OS's key listener (or, on Wayland, the portal's shortcut); dropping it stops it.
    _listener: Option<Box<dyn std::any::Any + Send>>,
}

impl Flow {
    fn send(&self, event: KeyEvent) {
        if let Some(r) = self.running.lock().unwrap().as_ref() {
            let _ = r.tx.send((event, Instant::now()));
        }
    }
}

pub fn get(app: &AppHandle) -> Option<Arc<Flow>> {
    app.try_state::<Arc<Flow>>().map(|s| s.inner().clone())
}

/// A program's name as people know it: "outlook" → "Outlook".
pub fn display_name(stem: &str) -> String {
    let id = stem.to_lowercase();
    if let Some(s) = store::default_app_styles().into_iter().find(|s| s.id == id) {
        return s.name;
    }
    let mut chars = stem.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Parts of the desktop itself, never a place to dictate into.
pub fn is_shell(id: &str) -> bool {
    matches!(
        id,
        "explorer" | "applicationframehost" | "textinputhost" | "shellexperiencehost" | "searchhost"
            | "startmenuexperiencehost" | "lockapp" | "coucou" | "gnome-shell" | "plasmashell" | "xfdesktop"
    )
}

fn is_terminal(id: &str) -> bool {
    #[cfg(target_os = "linux")]
    {
        os::is_terminal(id)
    }
    #[cfg(windows)]
    {
        // Windows Terminal, conhost and the rest paste with Ctrl+V.
        let _ = id;
        false
    }
}

// ── Setup, on and off ─────────────────────────────────────────────────────────

pub fn setup(app: &AppHandle) {
    let flow = Arc::new(Flow { store: Mutex::new(Store::load()), running: Mutex::new(None) });
    app.manage(flow.clone());
    pill::setup(app);
    let prefs = flow.store.lock().unwrap().prefs.clone();
    pill::update(app, |s| {
        s.edge = pill::edge_name(prefs.edge).into();
        s.key = key_id(prefs.key);
    });
    if prefs.enabled {
        enable(app, &flow);
    }
    crate::voice::sync(app);
}

/// The key as the pages write it ("right_ctrl"…), or "wayland" where the
/// desktop holds the shortcut.
fn key_id(key: logic::FlowKey) -> String {
    if os::keys_supported() == Err("wayland") {
        return "wayland".into();
    }
    serde_json::to_value(key).ok().and_then(|v| v.as_str().map(String::from)).unwrap_or_default()
}

fn enable(app: &AppHandle, flow: &Arc<Flow>) {
    let mut running = flow.running.lock().unwrap();
    if running.is_some() {
        return;
    }
    let prefs = flow.store.lock().unwrap().prefs.clone();
    let (tx, rx) = mpsc::channel::<(KeyEvent, Instant)>();
    let listener: Option<Box<dyn std::any::Any + Send>> = match os::keys_supported() {
        Ok(()) => match os::listen(prefs.key, tx.clone()) {
            Ok(l) => Some(Box::new(l)),
            Err(err) => {
                crate::log::line(format!("flow: the key can't be watched: {err}"));
                None
            }
        },
        #[cfg(target_os = "linux")]
        Err("wayland") => wayland::listen(tx.clone()).map(|h| Box::new(h) as Box<dyn std::any::Any + Send>),
        Err(why) => {
            crate::log::line(format!("flow: no key on this desktop ({why}); the pill's buttons still work"));
            None
        }
    };
    let app2 = app.clone();
    let flow2 = flow.clone();
    std::thread::Builder::new()
        .name("coucou-flow".into())
        .spawn(move || run(app2, flow2, rx))
        .ok();
    *running = Some(Running { tx, _listener: listener });
    drop(running);
    speech::preload();
    pill::update(app, |s| s.enabled = true);
    crate::log::line(format!("flow dictation on ({})", prefs.key.label()));
}

fn disable(app: &AppHandle, flow: &Arc<Flow>) {
    let running = flow.running.lock().unwrap().take();
    if let Some(r) = running {
        let _ = r.tx.send((KeyEvent::Quit, Instant::now()));
    }
    pill::update(app, |s| {
        s.enabled = false;
        s.phase = "idle".into();
    });
    if !crate::notes::is_recording(app) && !crate::voice::is_listening() {
        speech::unload();
    }
}

// ── The dictation thread ──────────────────────────────────────────────────────

struct Listening {
    capture: audio::Capture,
    take: Arc<Mutex<audio::Take>>,
    started: Instant,
    app: Option<(String, String)>,
}

fn run(app: AppHandle, flow: Arc<Flow>, rx: mpsc::Receiver<(KeyEvent, Instant)>) {
    let epoch = Instant::now();
    let secs = |at: Instant| at.saturating_duration_since(epoch).as_secs_f64();
    let mut logic = KeyLogic::default();
    let mut listening: Option<Listening> = None;
    let busy = Arc::new(AtomicBool::new(false));
    loop {
        let active = listening.is_some() || logic.is_active();
        let received = if active {
            match rx.recv_timeout(Duration::from_millis(33)) {
                Ok(m) => Some(m),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => break,
            }
        } else {
            match rx.recv() {
                Ok(m) => Some(m),
                Err(_) => break,
            }
        };
        let action = match received {
            Some((KeyEvent::Quit, _)) => {
                drop(listening.take());
                break;
            }
            Some((KeyEvent::Down, at)) => logic.key_down(secs(at)),
            Some((KeyEvent::Up, at)) => logic.key_up(secs(at)),
            Some((KeyEvent::Other, _)) => logic.other_key(),
            Some((KeyEvent::Escape, _)) => logic.escape(),
            Some((KeyEvent::HandsFree, _)) => {
                if logic.is_active() {
                    Action::None
                } else {
                    logic.lock();
                    if listening.is_none() {
                        listening = begin(&app, &flow);
                        if listening.is_none() {
                            logic.reset();
                        }
                    }
                    if listening.is_some() {
                        pill::update(&app, |s| s.phase = "locked".into());
                    }
                    Action::None
                }
            }
            Some((KeyEvent::Finish, _)) => {
                if logic.is_active() || listening.is_some() {
                    logic.reset();
                    Action::Finish
                } else {
                    Action::None
                }
            }
            Some((KeyEvent::Cancel, _)) => {
                logic.reset();
                Action::Cancel
            }
            None => logic.tick(secs(Instant::now())),
        };
        match action {
            Action::None => {}
            Action::Start => {
                listening = begin(&app, &flow);
                if listening.is_none() {
                    logic.reset();
                }
            }
            Action::Restart => {
                drop(listening.take());
                listening = begin(&app, &flow);
                if listening.is_none() {
                    logic.reset();
                }
            }
            Action::Lock => pill::update(&app, |s| s.phase = "locked".into()),
            Action::Cancel => {
                drop(listening.take());
                pill::update(&app, |s| s.phase = "idle".into());
            }
            Action::Finish => {
                if let Some(l) = listening.take() {
                    finish(&app, &flow, l, busy.clone());
                } else {
                    pill::update(&app, |s| s.phase = "idle".into());
                }
            }
        }
        // The pill's dots, about 30 times a second while you speak.
        if let Some(l) = &listening {
            let levels = l.take.lock().unwrap().meter.levels;
            let _ = app.emit_to(pill::LABEL, "pill-bands", levels);
        }
    }
    pill::update(&app, |s| s.phase = "idle".into());
}

/// Opens the microphone. None (and the pill says why) when it can't.
fn begin(app: &AppHandle, flow: &Arc<Flow>) -> Option<Listening> {
    if !speech::is_ready() {
        pill::announce(
            app,
            "download",
            "#3B9EFF",
            t("Download the voice model first, in Coucou → Settings → Recognition."),
            Some((t("Open Settings"), "openSettings")),
            10,
        );
        return None;
    }
    let mic = flow.store.lock().unwrap().prefs.mic.clone();
    let take = Arc::new(Mutex::new(audio::Take::default()));
    let sink_take = take.clone();
    let source = audio::Source::Mic(if mic.is_empty() { None } else { Some(mic) });
    let capture = audio::Capture::start(source, move |samples| {
        let mut t = sink_take.lock().unwrap();
        // Ten minutes at most: a dictation left open by mistake stops growing.
        if t.samples.len() < 16_000 * 600 {
            t.samples.extend_from_slice(samples);
        }
        t.peak = samples.iter().fold(t.peak, |m, &s| m.max(s.abs()));
        t.meter.feed(samples);
    });
    match capture {
        Ok(capture) => {
            let app_front = os::foreground_app().filter(|(id, _)| !is_shell(id));
            pill::update(app, |s| s.phase = "listening".into());
            Some(Listening { capture, take, started: Instant::now(), app: app_front })
        }
        Err(err) => {
            crate::log::line(format!("flow: microphone: {err}"));
            pill::update(app, |s| s.phase = "failed".into());
            pill::rest_after(app, "failed", 1800);
            pill::announce(
                app,
                "mic",
                "#FF6B6B",
                t("Coucou can't hear you: the microphone is not allowed or not available."),
                None,
                8,
            );
            None
        }
    }
}

/// Stops listening and turns what was said into pasted text, on a worker
/// thread so the key works again at once.
fn finish(app: &AppHandle, flow: &Arc<Flow>, mut l: Listening, busy: Arc<AtomicBool>) {
    l.capture.stop();
    let seconds = l.started.elapsed().as_secs_f64();
    let (samples, peak) = {
        let mut t = l.take.lock().unwrap();
        (std::mem::take(&mut t.samples), t.peak)
    };
    // Too short or silent: nothing to send to the model.
    if samples.len() < 16_000 / 4 || peak < 0.004 {
        pill::update(app, |s| s.phase = "idle".into());
        return;
    }
    pill::update(app, |s| s.phase = "thinking".into());
    let app = app.clone();
    let flow = flow.clone();
    let front = l.app.clone();
    std::thread::spawn(move || {
        busy.store(true, Ordering::Relaxed);
        let result = process(&app, &flow, &samples, front.as_ref(), seconds);
        busy.store(false, Ordering::Relaxed);
        if let Err(err) = result {
            crate::log::line(format!("flow: {err}"));
            pill::update(&app, |s| s.phase = "idle".into());
        }
    });
}

fn process(app: &AppHandle, flow: &Arc<Flow>, samples: &[f32], front: Option<&(String, String)>, seconds: f64) -> Result<(), String> {
    let started = Instant::now();
    let transcript = speech::transcribe(samples).ok_or("the voice model is not loaded")?;
    let raw = transcript.text.trim().to_string();
    if raw.is_empty() {
        pill::update(app, |s| s.phase = "idle".into());
        return Ok(());
    }
    let (prepared, style, cleanup, words, key) = {
        let store = flow.store.lock().unwrap();
        let app_id = front.map(|(id, _)| id.as_str());
        (store.prepare(&raw), store.style_for(app_id), store.prefs.cleanup, store.words.words.clone(), store.prefs.key)
    };
    let mut written = prepared.text.clone();
    if cleanup && style != store::Style::Verbatim && cleanup::has_key() {
        let app_name = front.map(|(_, n)| n.clone());
        let cleaned = tauri::async_runtime::block_on(cleanup::clean(&prepared.text, style, app_name.as_deref(), &words));
        if text::keeps_marks(&cleaned, &prepared.snippets) {
            written = cleaned;
        }
    }
    let final_text = text::finish(&written, &prepared.snippets);
    crate::log::line(format!("flow: {} words in {:?}", text::word_count(&final_text), started.elapsed()));

    os::wait_key_released(key);
    let terminal = front.is_some_and(|(id, _)| is_terminal(id));
    let outcome = paste::paste(&final_text, terminal);
    let entry = {
        let mut store = flow.store.lock().unwrap();
        store.record(&final_text, front.map(|(_, n)| n.as_str()), seconds, store::today(), store::now_ms())
    };
    let _ = app.emit_to(crate::HUB_LABEL, "flow-history", entry);
    match outcome {
        paste::Outcome::Pasted => pill::update(app, |s| s.phase = "idle".into()),
        paste::Outcome::Copied => {
            pill::update(app, |s| s.phase = "copied".into());
            pill::rest_after(app, "copied", 1800);
            pill::announce(
                app,
                "clipboard",
                "#F7B32B",
                t("Your words are copied: click where you want them and press Ctrl+V."),
                None,
                8,
            );
        }
        paste::Outcome::Failed => {
            pill::update(app, |s| s.phase = "idle".into());
            return Err("the clipboard refused the text".into());
        }
    }
    Ok(())
}

/// "Paste again": the last dictation, in the app in front now.
fn paste_again(app: &AppHandle, flow: &Arc<Flow>) {
    let Some(text) = flow.store.lock().unwrap().last_text() else { return };
    let front = os::foreground_app();
    let terminal = front.as_ref().is_some_and(|(id, _)| is_terminal(id));
    if paste::paste(&text, terminal) == paste::Outcome::Pasted {
        pill::update(app, |s| s.phase = "pastedAgain".into());
        pill::rest_after(app, "pastedAgain", 1600);
    }
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FlowStatus {
    prefs: Prefs,
    models: speech::ModelsStatus,
    /// "ok", or why the key can't be watched here ("wayland", "no-display").
    keys: String,
    has_claude_key: bool,
    mics: Vec<audio::InputDevice>,
    platform: &'static str,
    /// Coucou started with the computer.
    autostarted: bool,
    /// The user's first name, for "Hello Louis".
    user_name: Option<String>,
}

#[tauri::command]
pub fn flow_status(flow: State<Arc<Flow>>) -> FlowStatus {
    FlowStatus {
        prefs: flow.store.lock().unwrap().prefs.clone(),
        models: speech::status(),
        keys: match os::keys_supported() {
            Ok(()) => "ok".into(),
            Err(why) => why.into(),
        },
        has_claude_key: cleanup::has_key(),
        mics: audio::input_devices(),
        platform: if cfg!(windows) { "windows" } else { "linux" },
        autostarted: crate::launched_at_login(),
        user_name: crate::platform::user_full_name()
            .and_then(|n| n.split_whitespace().next().map(String::from))
            .filter(|n| !n.is_empty()),
    }
}

#[tauri::command]
pub fn flow_set_prefs(app: AppHandle, flow: State<Arc<Flow>>, prefs: Prefs) {
    let flow = flow.inner().clone();
    let before = {
        let mut store = flow.store.lock().unwrap();
        let before = store.prefs.clone();
        store.prefs = prefs.clone();
        store.save_prefs();
        if before.keep_days != prefs.keep_days {
            store.prune(store::now_ms());
        }
        before
    };
    pill::update(&app, |s| {
        s.edge = pill::edge_name(prefs.edge).into();
        s.key = key_id(prefs.key);
    });
    let restart = before.key != prefs.key;
    if before.enabled && (!prefs.enabled || restart) {
        disable(&app, &flow);
    }
    if prefs.enabled && (!before.enabled || restart) {
        enable(&app, &flow);
    }
    if before.voice != prefs.voice || before.mic != prefs.mic {
        if before.mic != prefs.mic {
            crate::voice::restart(&app);
        } else {
            crate::voice::sync(&app);
        }
    }
    let _ = app.emit("flow-prefs", &prefs);
}

#[tauri::command]
pub fn flow_history(flow: State<Arc<Flow>>) -> Vec<Entry> {
    flow.store.lock().unwrap().history.clone()
}

#[tauri::command]
pub fn flow_delete(flow: State<Arc<Flow>>, id: String) {
    flow.store.lock().unwrap().delete(&id);
}

#[tauri::command]
pub fn flow_clear(flow: State<Arc<Flow>>, everything: bool) {
    let mut store = flow.store.lock().unwrap();
    if everything {
        store.clear_everything();
    } else {
        store.clear_history();
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Totals {
    words: u64,
    seconds: f64,
    dictations: u64,
    words_per_minute: u64,
    minutes_saved: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StatsView {
    week: Totals,
    month: Totals,
    all: Totals,
    /// The words of the last 30 days, oldest first: ("2026-10-14", words).
    daily: Vec<(String, u64)>,
    apps: std::collections::BTreeMap<String, u64>,
    streak: u32,
}

#[tauri::command]
pub fn flow_stats(flow: State<Arc<Flow>>) -> StatsView {
    let store = flow.store.lock().unwrap();
    let today = store::today();
    let totals = |from: Option<text::Day>| {
        let (words, seconds, dictations) = store.totals(from);
        Totals {
            words,
            seconds,
            dictations,
            words_per_minute: text::words_per_minute(words, seconds),
            minutes_saved: text::minutes_saved(words, seconds),
        }
    };
    let daily = (0..30)
        .rev()
        .map(|back| {
            let key = today.minus(back).key();
            let words = store.stats.days.get(&key).map(|d| d.words).unwrap_or(0);
            (key, words)
        })
        .collect();
    StatsView {
        week: totals(Some(today.minus(6))),
        month: totals(Some(today.minus(29))),
        all: totals(None),
        daily,
        apps: store.stats.apps.clone(),
        streak: store.streak(today),
    }
}

#[tauri::command]
pub fn flow_words(flow: State<Arc<Flow>>) -> Words {
    flow.store.lock().unwrap().words.clone()
}

#[tauri::command]
pub fn flow_set_words(flow: State<Arc<Flow>>, words: Words) {
    let mut store = flow.store.lock().unwrap();
    store.words = words;
    store.save_words();
}

#[tauri::command]
pub fn flow_snippets(flow: State<Arc<Flow>>) -> Vec<Snippet> {
    flow.store.lock().unwrap().snippets.clone()
}

#[tauri::command]
pub fn flow_set_snippets(flow: State<Arc<Flow>>, snippets: Vec<Snippet>) {
    let mut store = flow.store.lock().unwrap();
    store.snippets = snippets;
    store.save_snippets();
}

#[tauri::command]
pub fn flow_styles(flow: State<Arc<Flow>>) -> Vec<AppStyle> {
    flow.store.lock().unwrap().app_styles.clone()
}

#[tauri::command]
pub fn flow_set_styles(flow: State<Arc<Flow>>, styles: Vec<AppStyle>) {
    let mut store = flow.store.lock().unwrap();
    store.app_styles = styles;
    store.save_styles();
}

#[derive(Serialize, Deserialize)]
pub struct RunningApp {
    id: String,
    name: String,
}

#[tauri::command]
pub async fn flow_running_apps() -> Vec<RunningApp> {
    tauri::async_runtime::spawn_blocking(|| os::running_apps().into_iter().map(|(id, name)| RunningApp { id, name }).collect())
        .await
        .unwrap_or_default()
}

#[tauri::command]
pub fn flow_copy(text: String) -> bool {
    paste::copy(&text)
}

#[tauri::command]
pub fn flow_paste_again(app: AppHandle, flow: State<Arc<Flow>>) {
    let flow = flow.inner().clone();
    std::thread::spawn(move || paste_again(&app, &flow));
}

#[tauri::command]
pub fn flow_models_download(app: AppHandle) {
    speech::download(app);
}

#[tauri::command]
pub fn flow_models_remove(app: AppHandle) {
    speech::remove(&app);
}

// ── The pill's page ───────────────────────────────────────────────────────────

#[tauri::command]
pub fn pill_state(app: AppHandle) -> Option<pill::PillState> {
    pill::get(&app).map(|p| p.state())
}

#[tauri::command]
pub fn pill_hot(app: AppHandle, rects: Vec<(f64, f64, f64, f64)>) {
    pill::set_hot(&app, rects);
}

#[tauri::command]
pub fn pill_hover(app: AppHandle, inside: bool) {
    if let Some(p) = pill::get(&app) {
        p.hovered.store(inside, Ordering::Relaxed);
    }
}

#[tauri::command]
pub fn pill_action(app: AppHandle, flow: State<Arc<Flow>>, action: String, id: Option<u64>) {
    let flow = flow.inner().clone();
    match action.as_str() {
        "dictate" => {
            if flow.running.lock().unwrap().is_none() {
                // Dictation off: the pill only shows for a call or a message.
                return;
            }
            flow.send(KeyEvent::HandsFree);
        }
        "finish" => flow.send(KeyEvent::Finish),
        "cancel" => flow.send(KeyEvent::Cancel),
        "note" => crate::notes::toggle(&app),
        "stopNote" => crate::notes::stop(&app),
        "hub" => crate::show_hub(&app, None),
        "announcement" | "dismiss" => {
            let state = pill::get(&app).map(|p| p.state());
            let current = state.and_then(|s| s.announcement).filter(|a| Some(a.id) == id);
            if let Some(a) = current {
                pill::dismiss(&app, a.id);
                if action == "announcement" {
                    match a.action_id.as_deref() {
                        Some("openSettings") => crate::show_hub(&app, Some("settings")),
                        Some("openNotes") => crate::show_hub(&app, Some("notes")),
                        _ => {}
                    }
                }
            }
        }
        _ => {}
    }
}
