// Coucou for Windows — app wiring and the commands the island calls.

mod agent_hooks;
mod cdp;
mod chat_memory;
mod claude;
mod cli;
mod deeplink;
mod files;
mod focus;
mod hermes_clarify;
mod hooks;
mod hotkeys;
#[allow(dead_code)]
mod hindsight;
mod integrations;
mod island;
mod launch;
mod log;
mod memory_export;
mod pipe;
mod placement;
mod platform;
mod quick;
mod robot;
mod router;
mod secrets;
mod settings;
mod setup;
mod tab;
mod tools;
mod tray;
mod voice;

use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri::webview::{PermissionKind, PermissionResponse};
use tauri_plugin_autostart::{ManagerExt, MacosLauncher};

use chat_memory::{discover_remote_records, finish_forget, plan_forget_with_discovery, ArtifactSummary, ChatMemoryState, CompletedTurn, ContextKind, DiscoveryFailure, DiscoveryStop, MemoryPolicy, PrepareForgetSummary, RemoteArtifactRecord, RetainedArtifact, RetentionCandidate, TurnSafety, register_completed_if_current};
use claude::{Chat, ChatContext, ChatReply};
use files::DroppedFile;
use hooks::{HookPreview, HookStatus};
use hindsight::{ConfirmedMemoryRetirement, ConfirmedMemoryScope, MemoryBrowseRequest, MemoryManager, MemoryRecord, MemoryUpdate, SafeMemoryDetail};
use island::{PollGate, ScreenInfo};
use memory_export::{MemoryExport, MemoryExportFormat};
use pipe::Pending;
use settings::Settings;

/// Keeps spawned helpers from flashing a console window.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct Shared {
    pub settings: Mutex<Settings>,
    pub gate: Arc<PollGate>,
    pub memory_list_generation: Arc<AtomicU64>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
struct MemoryWindowRequest { query: Option<String>, document_ids: Vec<String> }
#[derive(Default)]
struct MemoryWindowState {
    ready: std::sync::atomic::AtomicBool,
    pending: Mutex<Option<MemoryWindowRequest>>,
}

impl MemoryWindowState {
    fn request(&self, query: Option<String>, document_ids: Vec<String>) -> Option<MemoryWindowRequest> {
        let mut seen = std::collections::HashSet::new();
        let document_ids: Vec<_> = document_ids.into_iter().filter(|value| !value.trim().is_empty() && seen.insert(value.clone())).collect();
        let request = MemoryWindowRequest { query: if document_ids.is_empty() { query.filter(|value| !value.trim().is_empty()) } else { None }, document_ids };
        if request.query.is_none() && request.document_ids.is_empty() { return None; }
        if self.ready.load(Ordering::SeqCst) { Some(request) } else { *self.pending.lock().unwrap() = Some(request); None }
    }
    fn ready(&self) -> Option<MemoryWindowRequest> {
        self.ready.store(true, Ordering::SeqCst);
        self.pending.lock().unwrap().take()
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BootInfo {
    settings: Settings,
    screen: ScreenInfo,
    version: String,
    hook_path: String,
}

#[tauri::command]
fn boot(app: AppHandle, shared: State<Shared>) -> BootInfo {
    let mut settings = shared.settings.lock().unwrap().clone();
    // The real state of ~/.claude/settings.json wins over whatever we stored.
    settings.hooks_installed = hooks::status().installed;
    let screen = island::screen_info(&app, &settings.screen);
    BootInfo {
        settings,
        screen,
        version: env!("CARGO_PKG_VERSION").to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
    }
}

#[derive(Debug)]
struct SettingsChanges {
    screen_changed: bool,
    autostart_changed: bool,
    hotkeys_changed: bool,
    lock_changed: bool,
}

fn commit_settings_with(
    current: &mut Settings,
    mut candidate: Settings,
    persist: impl FnOnce(&Settings) -> Result<(), String>,
) -> Result<(Settings, SettingsChanges), String> {
    candidate.sanitize();
    candidate.island_position = current.island_position;
    candidate.setup_offered |= current.setup_offered;
    let changes = SettingsChanges {
        screen_changed: current.screen != candidate.screen,
        autostart_changed: current.autostart != candidate.autostart,
        hotkeys_changed: current.hotkeys != candidate.hotkeys,
        lock_changed: current.island_locked != candidate.island_locked,
    };
    persist(&candidate)?;
    *current = candidate.clone();
    Ok((candidate, changes))
}

#[tauri::command]
fn save_settings(app: AppHandle, shared: State<Shared>, settings: Settings) -> Result<(), String> {
    let (settings, changes) = {
        let mut current = shared.settings.lock().unwrap();
        commit_settings_with(&mut current, settings, |candidate| {
            settings::save(candidate).map_err(|error| format!("Could not save settings: {error}"))
        })?
    };
    if changes.lock_changed {
        tray::sync_lock(&app, settings.island_locked);
    }
    if changes.autostart_changed {
        let manager = app.autolaunch();
        let result = if settings.autostart { manager.enable() } else { manager.disable() };
        if let Err(err) = result {
            eprintln!("[coucou] autostart: {err}");
        }
    }
    if changes.screen_changed {
        place_island(&app, &shared);
    }
    if changes.hotkeys_changed {
        let report = hotkeys::apply(&app, &settings.hotkeys);
        let _ = app.emit("hotkeys-status", report);
    }
    // Keep the other window in step (island ⇄ settings window).
    let _ = app.emit("settings-changed", settings);
    Ok(())
}

/// Hidden island → shrink the window to the invisible wake strip and park the
/// cursor poll; anything else → full panel and 60 Hz polling.
#[tauri::command]
fn set_collapsed(app: AppHandle, shared: State<Shared>, collapsed: bool) {
    shared.gate.collapsed.store(collapsed, Ordering::Relaxed);
    place_island(&app, &shared);
    if !collapsed {
        // Coming back for an alert: the window must actually be on screen,
        // even if something minimised or hid it while it was a wake strip.
        if let Some(win) = island::window(&app) {
            if !win.is_visible().unwrap_or(true) {
                log::line("island window was not visible — showing it");
                let _ = win.show();
            }
        }
    }
    // The wake strip must always take the mouse, and a resize invalidates the flag.
    island::set_ignore_cursor(&app, false);
    shared.gate.forget_ignore_state();
    shared.gate.set_active(!collapsed);
}

/// The front end pushes the island shape; Rust decides click-through from it.
#[tauri::command]
fn set_island_rect(shared: State<Shared>, x: f64, y: f64, width: f64, height: f64) {
    shared.gate.set_rect(island::IslandRect { x, y, w: width, h: height });
}

#[tauri::command]
fn focus_window(app: AppHandle, focused: bool) {
    let Some(win) = island::window(&app) else { return };
    island::set_activating(&win, focused);
    if focused {
        let _ = win.set_focus();
    }
}

/// Puts the island window where it belongs: the saved spot (re-clamped to
/// the displays that exist now) or the default top centre.
fn place_island(app: &AppHandle, shared: &Shared) {
    let (pref, saved) = {
        let s = shared.settings.lock().unwrap();
        (s.screen.clone(), s.island_position)
    };
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    island::apply_geometry(app, &pref, saved, collapsed);
}

#[tauri::command]
fn reposition(app: AppHandle, shared: State<Shared>) {
    place_island(&app, &shared);
}

/// Island drag (unlocked only): Windows moves the window itself, then the
/// spot is saved as the island's top centre.
#[tauri::command]
fn island_start_drag(app: AppHandle, shared: State<Shared>) -> Result<(), String> {
    if shared.settings.lock().unwrap().island_locked {
        return Err("The island is locked.".into());
    }
    let Some(win) = island::window(&app) else { return Ok(()) };
    island::set_ignore_cursor(&app, false);
    shared.gate.forget_ignore_state();
    win.start_dragging().map_err(|e| e.to_string())?;
    // Windows runs the move loop; the cursor poll sees the button come up.
    shared.gate.moving.store(true, Ordering::Relaxed);
    Ok(())
}

/// End of a drag (called by the cursor poll on mouse-up): saves where the
/// island landed and snaps it inside the work area.
pub fn island_dragged(app: &AppHandle) {
    let shared = app.state::<Shared>();
    if shared.gate.collapsed.load(Ordering::Relaxed) {
        return;
    }
    let Some(anchor) = island::anchor_after_drag(app) else { return };
    log::line(format!("island moved to ({}, {})", anchor.x, anchor.y));
    update_island(app, &shared, |s| s.island_position = Some(anchor));
}

/// Lock or unlock the island (header button, tray, Settings).
#[tauri::command]
fn island_set_locked(app: AppHandle, shared: State<Shared>, locked: bool) {
    set_island_locked(&app, &shared, locked);
}

/// Back to the default top centre of the chosen display.
#[tauri::command]
fn island_reset_position(app: AppHandle, shared: State<Shared>) {
    reset_island_position(&app, &shared);
}

pub fn set_island_locked(app: &AppHandle, shared: &Shared, locked: bool) {
    update_island(app, shared, |s| s.island_locked = locked);
    tray::sync_lock(app, locked);
}

pub fn reset_island_position(app: &AppHandle, shared: &Shared) {
    update_island(app, shared, |s| s.island_position = None);
}

fn update_island(app: &AppHandle, shared: &Shared, change: impl FnOnce(&mut Settings)) {
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        change(&mut current);
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    place_island(app, shared);
    let _ = app.emit("settings-changed", updated);
}

#[tauri::command]
fn open_url(url: String) {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return;
    }
    let _ = Command::new("rundll32.exe")
        .args(["url.dll,FileProtocolHandler", &url])
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
}

/// "Open terminal" opens the working folder in VS Code when `code` is on PATH,
/// and falls back to Explorer otherwise.
#[tauri::command]
fn open_in_vscode(path: Option<String>) -> bool {
    // No `cmd /C` anywhere near this. The path is a project folder chosen by
    // whoever is using Claude Code, and cmd would happily read `&`, `^` and `%`
    // in a folder name as syntax. Finding the launcher ourselves and handing the
    // path over as a separate argument keeps it a path.
    if let Some(code) = find_on_path("code") {
        let mut cmd = Command::new(code);
        if let Some(p) = path.as_deref().filter(|p| !p.is_empty()) {
            cmd.arg(p);
        }
        if cmd.creation_flags(CREATE_NO_WINDOW).spawn().is_ok() {
            return true;
        }
    }
    if let Some(p) = path.as_deref().filter(|p| !p.is_empty()) {
        let _ = Command::new("explorer").arg(p).spawn();
    }
    false
}

/// Brings back the window the agent session started from. The relay reported
/// it as (hwnd, pid); a closed or recycled handle falls back to opening `cwd`
/// in VS Code — but only for Claude Code (`agent` absent or "claude"). A Codex,
/// Kimi or Hermes session may live in a desktop app or a terminal; opening an
/// editor there would look like the click did the wrong thing, so nothing opens.
/// `console_pid`, when the window is Windows Terminal, picks the session's tab
/// afterwards on a background thread (see `tab`). When the window belongs to
/// the Claude, Codex or Hermes desktop app, `session_id` is opened in it.
#[tauri::command]
fn focus_origin(
    hwnd: Option<i64>,
    pid: Option<u32>,
    cwd: Option<String>,
    agent: Option<String>,
    console_pid: Option<u32>,
    session_id: Option<String>,
) -> bool {
    if let (Some(hwnd), Some(pid)) = (hwnd, pid) {
        if focus::focus(hwnd, pid) {
            if let Some(console_pid) = console_pid { tab::select_in_background(hwnd, console_pid); }
            if let Some(session_id) = session_id.filter(|value| !value.trim().is_empty()) { open_desktop_session(pid, session_id); }
            return true;
        }
    }
    if agent.as_deref().is_none_or(|a| a == "claude") { open_in_vscode(cwd); }
    false
}

fn open_desktop_session(pid: u32, session_id: String) {
    let Some(app) = tab::image_path(pid).as_deref().and_then(deeplink::app_of) else { return };
    let _ = std::thread::Builder::new().name("coucou-deeplink".into()).spawn(move || {
        let url = deeplink::url_for(app, &session_id, deeplink::claude_local_id);
        let outcome = match url.as_deref() {
            Some(url) => launch::open_protocol_url(url).map(|_| "opened").unwrap_or_else(|error| { log::line(format!("desktop session link failed: {error}")); "failed" }),
            None => "no link",
        };
        log::line(format!("desktop session {app:?} {outcome}"));
    });
}

/// Our own `where`: walks %PATH% against %PATHEXT%, no shell involved.
/// Rust quotes arguments correctly for `.cmd`/`.bat` targets since 1.77, so
/// spawning `code.cmd` directly is safe.
fn find_on_path(stem: &str) -> Option<std::path::PathBuf> {
    find_in(stem, &std::env::var_os("PATH")?)
}

/// `find_on_path` over an explicit PATH value.
pub(crate) fn find_in(stem: &str, dirs: &std::ffi::OsStr) -> Option<std::path::PathBuf> {
    let exts = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
    for dir in std::env::split_paths(dirs) {
        for ext in exts.split(';').filter(|e| !e.is_empty()) {
            let candidate = dir.join(format!("{stem}{}", ext.to_lowercase()));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    quit(&app);
}

pub(crate) fn quit(app: &AppHandle) {
    robot::stop(app);
    app.exit(0);
}

/// Tray → Pause. Paused means paused: the pollers stop talking to the network,
/// not just the island stopping showing things.
#[tauri::command]
fn set_paused(paused: bool) {
    integrations::set_paused(paused);
}

// ── Claude Code hooks ─────────────────────────────────────────────────────────

#[tauri::command]
fn hooks_status() -> HookStatus {
    hooks::status()
}

/// Returns the diff the user has to look at before anything is written.
#[tauri::command]
fn hooks_preview(install: bool) -> Result<HookPreview, String> {
    hooks::preview(install)
}

/// Only ever called from an explicit click in the settings window.
#[tauri::command]
fn hooks_apply(
    app: AppHandle,
    shared: State<Shared>,
    install: bool,
    fingerprint: String,
) -> Result<String, String> {
    // The fingerprint comes from the preview the user actually looked at, so a
    // settings.json that changed in between is refused rather than overwritten.
    let backup = hooks::write(install, &fingerprint)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.hooks_installed = install;
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

async fn off_main<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|err| format!("Background task failed: {err}"))?
}

#[tauri::command]
async fn agent_hooks_status(agent: String) -> Result<agent_hooks::AgentHookStatus, String> {
    off_main(move || agent_hooks::status(&agent)).await
}

#[tauri::command]
async fn agent_hooks_preview(agent: String, install: bool) -> Result<agent_hooks::AgentHookPreview, String> {
    off_main(move || agent_hooks::preview(&agent, install)).await
}

#[tauri::command]
async fn agent_hooks_apply(agent: String, install: bool, fingerprint: String) -> Result<String, String> {
    off_main(move || agent_hooks::apply(&agent, install, &fingerprint)).await
}

#[tauri::command]
async fn hermes_clarify_pending(session_id: String) -> Result<hermes_clarify::PendingReport, String> {
    hermes_clarify::pending(&session_id).await
}

#[tauri::command]
async fn hermes_clarify_answer(pid: u32, kind: String, id: String, answers: Vec<Vec<String>>) -> Result<hermes_clarify::Answered, String> {
    hermes_clarify::answer(pid, &kind, &id, &answers).await
}

// ── One-step agent setup ──────────────────────────────────────────────────────

/// Which agents are on this machine and whether each is already hooked up.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DetectedAgent {
    #[serde(flatten)]
    detection: setup::Detection,
    configured: bool,
}

#[tauri::command]
async fn agents_detect() -> Result<Vec<DetectedAgent>, String> {
    off_main(|| {
        let profile = agent_hooks::Profile::from_env();
        Ok(setup::detect_all(&profile)
            .into_iter()
            .map(|d| {
                let configured = d.found && setup::configured(&d.agent, &profile).unwrap_or(false);
                DetectedAgent { detection: d, configured }
            })
            .collect())
    })
    .await
}

/// "Set up all my agents" — only ever from a click in Settings.
#[tauri::command]
async fn agents_setup_all(app: AppHandle, shared: State<'_, Shared>) -> Result<setup::SetupReport, String> {
    let resource = app.path().resolve("coucou-hook.exe", tauri::path::BaseDirectory::Resource).ok();
    let report = off_main(move || {
        let profile = agent_hooks::Profile::from_env();
        let report = setup::setup_all_detected(&profile, &hooks::relay_candidates(resource), false);
        let _ = setup::write_report(&profile, &setup::report_text(&report, &setup::local_stamp()));
        Ok(report)
    })
    .await?;
    log::line(format!("setup all agents: {}", if report.ok { "ok" } else { "errors" }));
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.setup_offered = true;
        current.hooks_installed = hooks::status().installed;
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(report)
}

/// The first-launch offer was seen (accepted or dismissed): never offer again.
#[tauri::command]
fn agents_setup_dismiss(app: AppHandle, shared: State<Shared>) {
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.setup_offered = true;
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
}

/// First launch: if agents are here and not hooked up, say so on the island.
/// Nothing is installed until the user clicks the button in Settings.
fn offer_setup(app: AppHandle) {
    std::thread::spawn(move || {
        let names = setup::unconfigured_detected(&agent_hooks::Profile::from_env());
        if names.is_empty() {
            let shared = app.state::<Shared>();
            let mut current = shared.settings.lock().unwrap();
            current.setup_offered = true;
            let _ = settings::save(&current);
            return;
        }
        log::line(format!("setup offer: {}", names.join(", ")));
        // Give the island a moment to finish its greeting first.
        std::thread::sleep(std::time::Duration::from_secs(4));
        let _ = app.emit_to(island::WINDOW_LABEL, "setup-offer", names);
    });
}

/// The island's "Set them up" button: Settings opens with the button marked.
#[tauri::command]
fn open_settings_for_setup(app: AppHandle) {
    let _ = app.emit_to("settings", "setup-highlight", ());
    show_settings_window(&app);
}

#[tauri::command]
fn approval_decision(app: AppHandle, request_id: String, decision: String) {
    pipe::answer(&app, &request_id, &decision);
}

/// Submit on a Claude question card: picked labels, one list per question.
#[tauri::command]
fn approval_answers(app: AppHandle, request_id: String, answers: Vec<Vec<String>>) {
    pipe::answer_questions(&app, &request_id, &answers);
}

/// The island has the card on screen, so the long wait for a human may begin.
/// Until this arrives the relay only waits a few hundred milliseconds, which is
/// what stops a paused or unresponsive island from freezing Claude Code.
#[tauri::command]
fn approval_ack(app: AppHandle, request_id: String) {
    pipe::acknowledge(&app, &request_id);
}

/// Nobody can act on this request — the island is paused, or another card is
/// already up. Claude Code falls back to asking in the terminal immediately.
#[tauri::command]
fn approval_decline(app: AppHandle, request_id: String) {
    pipe::decline(&app, &request_id);
}

// ── New task ──────────────────────────────────────────────────────────────────

/// Starts an agent task. Also the function the chat's task tool calls, so
/// both share validation, logging, the typing gate and the remembered folder.
pub async fn start_task(app: &AppHandle, request: launch::LaunchRequest) -> Result<launch::LaunchOutcome, String> {
    let (validated, outcome) = off_main(move || launch::execute(&request)).await?;
    let shared = app.state::<Shared>();
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.remember_task(
            validated.agent.id(),
            validated.target.id(),
            &validated.folder.to_string_lossy(),
        );
        if let Err(err) = settings::save(&current) {
            eprintln!("[coucou] could not save settings: {err}");
        }
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(outcome)
}

#[tauri::command]
async fn launch_task(
    app: AppHandle,
    agent: String,
    target: String,
    folder: String,
    prompt: String,
) -> Result<launch::LaunchOutcome, String> {
    start_task(&app, launch::LaunchRequest { agent, target, folder, prompt }).await
}

// ── Chat, files and secrets ───────────────────────────────────────────────────

/// Runs the chat's tools for real: start_task goes through `start_task`, the
/// same path as the "+ Task" form; list_sessions reads the island's snapshot.
struct AppTools {
    app: AppHandle,
    sessions: Vec<tools::SessionInfo>,
}

impl tools::ToolRunner for AppTools {
    fn defaults(&self) -> tools::ToolDefaults {
        let s = self.app.state::<Shared>();
        let s = s.settings.lock().unwrap();
        tools::ToolDefaults::from_settings(&s)
    }

    fn sessions(&self) -> Vec<tools::SessionInfo> {
        self.sessions.clone()
    }

    async fn start(&mut self, request: launch::LaunchRequest) -> Result<launch::LaunchOutcome, String> {
        log::line(format!("chat start_task agent={} target={}", request.agent, request.target));
        start_task(&self.app, request).await
    }

    fn robot(&mut self, task: String) -> Result<String, String> {
        log::line("chat robot_task");
        robot::start(&self.app, &task).map(|s| s.message)
    }
}

// ── Robot (background agent in the hidden browser) ───────────────────────────

#[tauri::command]
fn robot_status(robot: State<robot::Robot>) -> robot::RobotStatus {
    robot.status()
}

#[tauri::command]
fn robot_start(app: AppHandle, task: String) -> Result<robot::RobotStatus, String> {
    robot::start(&app, &task)
}

#[tauri::command]
fn robot_stop(app: AppHandle) -> robot::RobotStatus {
    robot::stop(&app)
}

/// Allow / Deny on the island's robot card.
#[tauri::command]
fn robot_approve(app: AppHandle, id: String, allow: bool) -> bool {
    robot::approve(&app, &id, allow)
}

/// JPEG `data:` URL of the hidden browser's active page; `None` when no page
/// is open. Read-only.
#[tauri::command]
async fn robot_preview() -> Result<Option<String>, String> {
    off_main(cdp::screenshot).await
}

/// One chat turn, through whichever provider Settings selects. The API key and
/// any file bytes stay on the Rust side. `sessions` is the island's current
/// session list (agent, project name, status) for the list_sessions tool.
#[tauri::command]
async fn chat_send(
    app: AppHandle,
    shared: State<'_, Shared>,
    chat: State<'_, Chat>,
    memory: State<'_, ChatMemoryState>,
    query: String,
    context: Option<ChatContext>,
    sessions: Option<Vec<tools::SessionInfo>>,
) -> Result<ChatReply, String> {
    let turn_id = format!("{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
    let timestamp = time::OffsetDateTime::now_utc().format(&time::format_description::well_known::Rfc3339).map_err(|_| "Unable to create turn timestamp".to_string())?;
    let generation = chat.generation();
    let private_at_start = memory.private_chat();
    let (provider, model, base, hindsight) = {
        let s = shared.settings.lock().unwrap();
        (s.chat_provider.clone(), s.model.clone(), s.router_base_url.clone(), s.hindsight.clone())
    };
    let enabled_at_start = hindsight.enabled;
    let (memory_context, recall_status) = if memory.private_chat() {
        (None, None)
    } else {
        let current = shared.settings.lock().unwrap().hindsight.clone();
        chat_memory::recall_context(&current, memory.private_chat(), &query).await
    };
    let mut runner = AppTools { app: app.clone(), sessions: tools::sanitize_sessions(sessions.unwrap_or_default()) };
    let provider_call = async {
        if provider == "router" {
            router::send(&chat, &base, &model, query.clone(), context.clone(), memory_context, &mut runner).await
        } else {
            claude::send(&chat, &model, query.clone(), context.clone(), memory_context, &mut runner).await
        }
    };
    let completed = CompletedTurn::new(&turn_id, &timestamp, &provider, &model, &hindsight.base_url, &hindsight.tenant, &hindsight.bank, &query, "");
    let safety = TurnSafety { has_file_or_attachment: matches!(context, Some(ChatContext::File { .. })), ..TurnSafety::default() };
    coordinate_chat_send(
        &chat,
        &memory,
        generation,
        turn_id,
        recall_status,
        completed,
        safety,
        enabled_at_start,
        private_at_start,
        provider_call,
        || {
            let current = shared.settings.lock().unwrap().hindsight.enabled;
            (current, memory.private_chat())
        },
        |turn, candidate| {
            let app = app.clone();
            let captured = hindsight.clone();
            tauri::async_runtime::spawn(async move {
                let _ = app.emit("chat-memory-status", serde_json::json!({ "turnId": turn, "status": "saving" }));
                let current = app.state::<Shared>().settings.lock().unwrap().hindsight.clone();
                let private = app.state::<ChatMemoryState>().private_chat();
                let namespace_matches = current.base_url == captured.base_url && current.tenant == captured.tenant && current.bank == captured.bank;
                let document_id = candidate.provenance.document_id.clone();
                let kind = candidate.provenance.retention_kind;
                let source = candidate.provenance.context_kind;
                let retained = namespace_matches && MemoryPolicy::new(&current, private).should_retain(kind)
                    && chat_memory::retain_candidate(current.clone(), private, candidate, true).await.is_ok();
                if retained {
                    let registry = &app.state::<ChatMemoryState>().completed;
                    let artifact = RetainedArtifact::pending(&document_id, kind, source, &captured.base_url, &captured.tenant, &captured.bank, generation);
                    if registry.add_artifact_if_current(&turn, generation, &captured.tenant, &captured.bank, artifact) {
                        discover_artifact(app.clone(), turn.clone(), document_id, captured.clone(), generation);
                    }
                }
                let _ = app.emit("chat-memory-status", serde_json::json!({ "turnId": turn, "status": if retained { "saved" } else { "notSaved" } }));
            });
        },
    ).await
}

#[allow(clippy::too_many_arguments)]
async fn coordinate_chat_send<F, S, R>(
    chat: &Chat,
    memory: &ChatMemoryState,
    generation: u64,
    turn_id: String,
    recall_status: Option<String>,
    mut completed: CompletedTurn,
    mut safety: TurnSafety,
    enabled_at_start: bool,
    private_at_start: bool,
    provider_call: F,
    current_memory_state: S,
    retain: R,
) -> Result<ChatReply, String>
where
    F: std::future::Future<Output = Result<ChatReply, String>>,
    S: FnOnce() -> (bool, bool),
    R: FnOnce(String, RetentionCandidate),
{
    let mut reply = provider_call.await?;
    if generation != chat.generation() {
        if reply.actions.is_empty() {
            return Err(claude::CLEARED.into());
        }
        reply.memory_status = None;
        reply.turn_id = None;
        return Ok(reply);
    }
    reply.turn_id = Some(turn_id.clone());
    reply.memory_status = recall_status;
    completed.assistant_text = reply.text.clone();
    safety = TurnSafety::classify(
        &completed.user_text,
        &completed.assistant_text,
        safety.completed,
        safety.has_file_or_attachment,
        !reply.actions.is_empty(),
        safety.cancelled,
    );
    let (enabled_at_end, private_at_end) = current_memory_state();
    let registered = register_completed_if_current(
        &memory.completed,
        generation,
        chat.generation(),
        completed.clone(),
        safety,
        enabled_at_start,
        private_at_start,
        enabled_at_end,
        private_at_end,
    );
    if registered {
        let provenance = completed.provenance(hindsight::RetentionKind::Inferred, ContextKind::Chat);
        if let Some(candidate) = RetentionCandidate::for_completed_turn(&provenance, &completed.user_text, &reply.text, safety) {
            retain(turn_id, candidate);
        }
    }
    Ok(reply)
}

/// Model ids offered by the configured 9router, cached for five minutes.
/// `base_url` lets Settings test a URL before saving it.
#[tauri::command]
async fn router_models(
    shared: State<'_, Shared>,
    refresh: Option<bool>,
    base_url: Option<String>,
) -> Result<Vec<String>, String> {
    let base = base_url
        .filter(|b| !b.trim().is_empty())
        .unwrap_or_else(|| shared.settings.lock().unwrap().router_base_url.clone());
    router::models(&base, refresh.unwrap_or(false)).await
}

/// Settings validates the base URL with the same rules chat_send applies.
#[tauri::command]
fn router_normalize_url(url: String) -> Result<String, String> {
    router::normalize_base_url(&url)
}

fn chat_reset_state(chat: &Chat, memory: &ChatMemoryState) {
    chat.reset();
    memory.completed.clear();
}

#[tauri::command]
fn chat_reset(chat: State<Chat>, memory: State<ChatMemoryState>) {
    chat_reset_state(&chat, &memory);
}

#[tauri::command]
fn chat_private(memory: State<ChatMemoryState>, enabled: bool) {
    memory.set_private_chat(enabled);
}

fn discover_artifact(app: AppHandle, turn_id: String, document_id: String, captured: hindsight::HindsightSettings, generation: u64) {
    tauri::async_runtime::spawn(async move {
        let Ok(client) = hindsight::HindsightClient::new(captured.clone()) else { return; };
        let result = discover_remote_records(4, || {
            let app = app.clone(); let client = client.clone(); let captured = captured.clone(); let turn_id = turn_id.clone(); let document_id = document_id.clone();
            async move {
                let current = app.state::<Shared>().settings.lock().unwrap().hindsight.clone();
                if current.base_url != captured.base_url || current.tenant != captured.tenant || current.bank != captured.bank { return Err(DiscoveryStop::Abort); }
                let Some(turn) = app.state::<ChatMemoryState>().completed.get(&turn_id) else { return Err(DiscoveryStop::Abort); };
                if !turn.artifacts.iter().any(|artifact| artifact.document_id == document_id && artifact.generation == generation) { return Err(DiscoveryStop::Abort); }
                client.list_memories_by_document(&document_id, 25, 0).await.map(|page| page.items.into_iter().map(|item| RemoteArtifactRecord { id: item.id, timestamp: item.updated_at.or(item.created_at) }).collect()).map_err(|_| DiscoveryStop::Failed)
            }
        }, |attempt| async move { tokio::time::sleep(std::time::Duration::from_millis(100 * (attempt as u64 + 1))).await }).await;
        if let Ok(records) = result { app.state::<ChatMemoryState>().completed.update_artifact_ids_if_current(&turn_id, &document_id, generation, &captured.tenant, &captured.bank, records.ids, records.timestamps); }
    });
}

async fn retain_explicit_artifact(app: &AppHandle, memory: &ChatMemoryState, settings: hindsight::HindsightSettings, turn_id: &str, candidate: RetentionCandidate) -> Result<ArtifactSummary, String> {
    let generation = candidate.provenance.local_turn_id.parse::<u64>().ok().unwrap_or(0).wrapping_add(1);
    let document_id = candidate.provenance.document_id.clone();
    let kind = candidate.provenance.retention_kind;
    let source = candidate.provenance.context_kind;
    chat_memory::retain_candidate(settings.clone(), memory.private_chat(), candidate, false).await.map_err(|error| error.to_string())?;
    let artifact = RetainedArtifact::pending(&document_id, kind, source, &settings.base_url, &settings.tenant, &settings.bank, generation);
    if !memory.completed.add_artifact_if_current(turn_id, generation, &settings.tenant, &settings.bank, artifact) { return Err("Completed turn changed before retention completed.".into()); }
    discover_artifact(app.clone(), turn_id.into(), document_id, settings, generation);
    memory.completed.artifact_summary(turn_id).ok_or_else(|| "Completed turn is unavailable.".into())
}

#[tauri::command]
async fn remember_turn(app: AppHandle, shared: State<'_, Shared>, memory: State<'_, ChatMemoryState>, turn_id: String) -> Result<ArtifactSummary, String> {
    let settings = shared.settings.lock().unwrap().hindsight.clone();
    if !MemoryPolicy::new(&settings, memory.private_chat()).should_retain(hindsight::RetentionKind::Explicit) { return Err("Memory is disabled for this session.".into()); }
    let candidate = memory.completed.explicit_turn_in_namespace(&turn_id, &settings.base_url, &settings.tenant, &settings.bank)?;
    retain_explicit_artifact(&app, &memory, settings, &turn_id, candidate).await
}

#[tauri::command]
async fn remember_selection(app: AppHandle, shared: State<'_, Shared>, memory: State<'_, ChatMemoryState>, turn_id: String, text: String, start: usize, end: usize) -> Result<ArtifactSummary, String> {
    let settings = shared.settings.lock().unwrap().hindsight.clone();
    if !MemoryPolicy::new(&settings, memory.private_chat()).should_retain(hindsight::RetentionKind::Explicit) { return Err("Memory is disabled for this session.".into()); }
    let candidate = memory.completed.selection_in_namespace(&turn_id, &text, start, end, &settings.base_url, &settings.tenant, &settings.bank)?;
    retain_explicit_artifact(&app, &memory, settings, &turn_id, candidate).await
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ForgetTurnResult { requested: usize, retired: Vec<String>, failed: Vec<hindsight::BulkMutationFailure>, document_ids: Vec<String>, discovery_failures: Vec<DiscoveryFailure>, fallback: Option<String> }

#[tauri::command]
fn prepare_forget_turn(shared: State<'_, Shared>, memory: State<'_, ChatMemoryState>, turn_id: String) -> Result<PrepareForgetSummary, String> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    memory.completed.prepare_forget(&turn_id, &config.base_url, &config.tenant, &config.bank)
}

#[tauri::command]
async fn forget_turn(shared: State<'_, Shared>, memory: State<'_, ChatMemoryState>, confirmation: PrepareForgetSummary) -> Result<ForgetTurnResult, String> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    let turn_id = confirmation.turn_id.clone();
    let artifacts = memory.completed.validate_forget(&confirmation, &config.base_url, &config.tenant, &config.bank)?;
    let client = hindsight::HindsightClient::new(config.clone()).map_err(|error| error.to_string())?;
    let mut final_ids = Vec::new(); let mut discovery_failures = Vec::new();
    for artifact in &artifacts {
        match client.list_all_memories_by_document(&artifact.document_id, 25).await {
            Ok(records) => final_ids.extend(records.into_iter().map(|item| item.id)),
            Err(error) => discovery_failures.push(DiscoveryFailure::new(&artifact.document_id, format!("{:?}", error.kind), error.message)),
        }
    }
    let plan = plan_forget_with_discovery(&artifacts, final_ids, discovery_failures);
    if plan.ids.is_empty() {
        if !plan.discovery_failures.is_empty() { return Err("Could not discover retained memories for this turn; no retirement was attempted.".into()); }
        return Ok(ForgetTurnResult { requested: 0, retired: vec![], failed: vec![], document_ids: plan.document_ids, discovery_failures: vec![], fallback: plan.fallback.map(|value| match value { chat_memory::ForgetFallback::Document => "document".into(), chat_memory::ForgetFallback::Text => "text".into() }) });
    }
    let mut retired = Vec::new(); let mut failed = Vec::new();
    for chunk in plan.ids.chunks(4) {
        let mut tasks = Vec::new();
        for id in chunk { let client = client.clone(); let id = id.clone(); tasks.push(tokio::spawn(async move { let result = client.retire_memory(&id).await; (id, result) })); }
        for task in tasks { let (id, result) = task.await.map_err(|_| "Forget operation was cancelled".to_string())?; match result { Ok(_) => retired.push(id), Err(error) => failed.push(hindsight::BulkMutationFailure { id, kind: error.kind, message: error.message }) } }
    }
    memory.completed.mark_artifacts_retired(&turn_id, &config.tenant, &config.bank, &retired);
    let outcome = finish_forget(&plan, retired, failed.iter().map(|failure| failure.id.clone()).collect());
    Ok(ForgetTurnResult { requested: plan.ids.len(), retired: outcome.succeeded, failed, document_ids: outcome.document_ids, discovery_failures: outcome.discovery_failures, fallback: outcome.fallback.map(|value| match value { chat_memory::ForgetFallback::Document => "document".into(), chat_memory::ForgetFallback::Text => "text".into() }) })
}

#[tauri::command(rename = "hindsightTestConnection")]
async fn hindsight_test_connection(shared: State<'_, Shared>) -> Result<(), String> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    hindsight::HindsightClient::new(config)
        .map_err(|error| error.to_string())?
        .test_connection().await.map_err(|error| error.to_string())
}

fn memory_manager(shared: &Shared) -> Result<MemoryManager, String> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    hindsight::HindsightClient::new(config)
        .map(|client| MemoryManager::with_list_generation(client, shared.memory_list_generation.clone()))
        .map_err(|error| error.to_string())
}

async fn bulk_retire_with_snapshot(
    config: hindsight::HindsightSettings,
    scope: ConfirmedMemoryScope,
    list_generation: Arc<AtomicU64>,
    create_client: impl FnOnce(hindsight::HindsightSettings) -> Result<hindsight::HindsightClient, hindsight::MemoryError>,
) -> Result<hindsight::BulkMutationResult, hindsight::MemoryError> {
    scope.validate(&config.base_url, &config.tenant, &config.bank)?;
    MemoryManager::with_list_generation(create_client(config)?, list_generation)
        .bulk_retire(scope.request)
        .await
}

#[tauri::command(rename = "memoryList")]
async fn memory_list(shared: State<'_, Shared>, request: MemoryBrowseRequest) -> Result<hindsight::MemoryPage, hindsight::MemoryError> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    let manager = hindsight::HindsightClient::new(config).map(|client| MemoryManager::with_list_generation(client, shared.memory_list_generation.clone()))?;
    manager.list(request).await
}

#[tauri::command(rename = "memoryGet")]
async fn memory_get(shared: State<'_, Shared>, id: String) -> Result<MemoryRecord, String> {
    memory_manager(&shared)?.get(&id).await.map_err(|error| error.to_string())
}

#[tauri::command(rename = "memorySafeDetail")]
async fn memory_safe_detail(shared: State<'_, Shared>, id: String) -> Result<SafeMemoryDetail, String> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    let record = memory_manager(&shared)?.get(&id).await.map_err(|error| error.to_string())?;
    Ok(SafeMemoryDetail::from_record(&record, &config.tenant, &config.bank, 16_384))
}

#[tauri::command(rename = "memoryUpdate")]
async fn memory_update(shared: State<'_, Shared>, id: String, opened: MemoryRecord, update: MemoryUpdate, overwrite: bool) -> Result<hindsight::MemoryUpdateResult, String> {
    memory_manager(&shared)?.update(&id, &opened, update, overwrite).await.map_err(|error| error.to_string())
}

#[tauri::command(rename = "memoryRetire")]
async fn memory_retire(shared: State<'_, Shared>, confirmation: ConfirmedMemoryRetirement) -> Result<hindsight::MemoryMutationResult, String> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    memory_manager(&shared)?.retire_confirmed(confirmation, &config.base_url, &config.tenant, &config.bank).await.map_err(|error| error.to_string())
}

#[tauri::command(rename = "memoryRestore")]
async fn memory_restore(shared: State<'_, Shared>, id: String) -> Result<hindsight::MemoryMutationResult, String> {
    memory_manager(&shared)?.restore(&id).await.map_err(|error| error.to_string())
}

#[tauri::command(rename = "memoryBulkRetire")]
async fn memory_bulk_retire(shared: State<'_, Shared>, scope: ConfirmedMemoryScope) -> Result<hindsight::BulkMutationResult, String> {
    let config = shared.settings.lock().unwrap().hindsight.clone();
    bulk_retire_with_snapshot(config, scope, shared.memory_list_generation.clone(), hindsight::HindsightClient::new)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command(rename = "memoryExport")]
fn memory_export(records: Vec<MemoryRecord>, format: MemoryExportFormat) -> Result<MemoryExport, String> {
    let token = secrets::get(hindsight::SECRET_KEY).unwrap_or_default();
    memory_export::format_memory_export_with_token(&records, format, &token)
}

#[tauri::command(rename = "memorySaveExport")]
fn memory_save_export(app: AppHandle, exported: MemoryExport) -> Result<bool, String> {
    use tauri_plugin_dialog::DialogExt;
    let Some(path) = app.dialog().file().set_file_name(&exported.filename).blocking_save_file() else { return Ok(false) };
    std::fs::write(path.as_path().ok_or("The selected export destination is not a local file")?, exported.content)
        .map_err(|error| format!("Could not save memory export: {error}"))?;
    Ok(true)
}

/// Copies a dropped file into the inbox and reports its name back.
#[tauri::command]
fn ingest_file(path: String) -> Result<DroppedFile, String> {
    files::ingest(&path)
}

/// The island may only ask whether a key exists — never read it.
#[tauri::command]
fn secret_present(key: String) -> bool {
    secrets::present(&key)
}

#[tauri::command]
fn secret_set(key: String, value: String) -> Result<(), String> {
    if key == router::SECRET_KEY { router::forget_models(); }
    let result = secrets::set(&key, &value);
    if result.is_ok() && key == hindsight::SECRET_KEY { hindsight::clear_automatic_auth_suppression(); }
    result
}

#[tauri::command]
fn secret_clear(key: String) -> Result<(), String> {
    if key == router::SECRET_KEY {
        router::forget_models();
    }
    secrets::clear(&key)
}

/// Opens the configured n8n instance — the URL lives in the Credential Manager.
#[tauri::command]
fn open_n8n() {
    if let Some(url) = secrets::get("n8n-url") {
        open_url(url);
    }
}

/// Refresh buttons in the integration cards.
#[tauri::command]
async fn refresh_integration(app: AppHandle, id: String) {
    integrations::poll_once(app, &id).await;
}

/// Lets the island write to the same log as the Rust side.
#[tauri::command]
fn log_line(message: String) {
    log::line(format!("ui  {message}"));
}

// ── Settings window ───────────────────────────────────────────────────────────

/// Which of the saved shortcuts failed to register, and why.
#[tauri::command]
fn hotkeys_status(app: AppHandle) -> Vec<hotkeys::HotkeyStatus> {
    hotkeys::status(&app)
}

/// Settings checks a recorded combination with the same rules Rust applies.
#[tauri::command]
fn hotkey_normalize(combo: String) -> Result<String, String> {
    hotkeys::normalize(&combo)
}

/// `true` while the Settings window records a combination: Coucou's own
/// shortcuts step aside so the keys reach the page. `false` puts them back.
#[tauri::command]
fn hotkeys_suspend(app: AppHandle, shared: State<Shared>, on: bool) -> Vec<hotkeys::HotkeyStatus> {
    if on {
        hotkeys::suspend(&app);
        Vec::new()
    } else {
        let saved = shared.settings.lock().unwrap().hotkeys.clone();
        hotkeys::apply(&app, &saved)
    }
}

#[tauri::command]
fn quick_hide(app: AppHandle, label: String) {
    if quick::is_quick(&label) { quick::hide(&app, &label); }
}

#[tauri::command]
fn quick_show(app: AppHandle, label: String) {
    if quick::is_quick(&label) { quick::show(&app, &label, "command"); }
}

/// The chat log changed in one window; the others redraw the same history.
/// The Rust conversation itself is already shared (one `Chat` state).
#[tauri::command]
fn chat_history_changed(app: AppHandle, history: serde_json::Value, from: String) {
    let _ = app.emit("chat-history", serde_json::json!({ "history": history, "from": from }));
}

/// Whether Windows' privacy switches let desktop apps use the microphone.
#[tauri::command]
fn microphone_status() -> voice::MicStatus {
    voice::mic_status()
}

#[tauri::command]
fn open_microphone_settings() {
    let _ = Command::new("explorer.exe").arg("ms-settings:privacy-microphone").spawn();
}

/// Raw recording in the request body, its MIME type in `x-audio-type`.
#[tauri::command]
async fn voice_transcribe(shared: State<'_, Shared>, request: tauri::ipc::Request<'_>) -> Result<String, String> {
    let tauri::ipc::InvokeBody::Raw(audio) = request.body() else {
        return Err("Expected the recording as raw bytes.".into());
    };
    let mime = request
        .headers()
        .get("x-audio-type")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("audio/webm")
        .to_string();
    let (base, model) = {
        let s = shared.settings.lock().unwrap();
        (s.router_base_url.clone(), s.stt_model.clone())
    };
    let bytes = audio.len();
    let result = voice::transcribe(&base, &model, &mime, audio.clone()).await;
    match &result {
        Ok(text) => log::line(format!("voice ok ({bytes} bytes, {} chars)", text.chars().count())),
        Err(err) => log::line(format!("voice failed ({bytes} bytes): {err}")),
    }
    result
}

/// WebView2 allows exactly one browser environment per app, and its options are
/// fixed by whichever webview is created first. Every window must therefore ask
/// for the *same* arguments as the island (see `additionalBrowserArgs` in
/// tauri.conf.json) — a mismatch makes the second window come up blank, with no
/// error anywhere.
pub(crate) const BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required";

/// In a dev build the pages are served by Vite, so the second window needs the
/// absolute dev URL; a bundled build resolves it inside the app bundle.
fn settings_page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/settings.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("settings.html".into())
}

/// The settings window is created hidden at launch and only ever shown and
/// hidden afterwards. A WebView2 window created later — on the main thread or
/// not — silently comes up blank in this app, so the window that works is the
/// one that exists before the island's webview does.
fn create_settings_window(app: &AppHandle) {
    let url = settings_page_url(app);
    match WebviewWindowBuilder::new(app, "settings", url)
        .additional_browser_args(BROWSER_ARGS)
        .title("Settings — Coucou")
        .inner_size(560.0, 680.0)
        .min_inner_size(460.0, 480.0)
        .resizable(true)
        .visible(false)
        .center()
        .build()
    {
        Ok(win) => {
            // Closing it must only hide it, or it could never be reopened.
            let hidden = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = hidden.hide();
                }
            });
        }
        Err(err) => log::line(format!("settings window failed: {err}")),
    }
}

pub fn show_settings_window(app: &AppHandle) {
    let Some(win) = app.get_webview_window("settings") else {
        log::line("settings window missing");
        return;
    };
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
}

fn memory_page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/memory.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("memory.html".into())
}

fn create_memory_window(app: &AppHandle) {
    match WebviewWindowBuilder::new(app, "memory", memory_page_url(app))
        .additional_browser_args(BROWSER_ARGS)
        .title("Memory Manager — Coucou")
        .inner_size(1040.0, 760.0)
        .min_inner_size(680.0, 520.0)
        .resizable(true)
        .visible(false)
        .center()
        .build()
    {
        Ok(win) => {
            let hidden = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = hidden.hide();
                }
            });
        }
        Err(error) => log::line(format!("memory window failed: {error}")),
    }
}

fn emit_memory_query(app: &AppHandle, request: MemoryWindowRequest) {
    let _ = app.emit_to("memory", "memory-search", request);
}

pub fn show_memory_window(app: &AppHandle, query: Option<String>, document_ids: Vec<String>) {
    let Some(win) = app.get_webview_window("memory") else { log::line("memory window missing"); return };
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
    if let Some(request) = app.state::<MemoryWindowState>().request(query, document_ids) { emit_memory_query(app, request); }
}

#[tauri::command]
fn open_settings_window(app: AppHandle) { show_settings_window(&app); }

#[tauri::command]
fn open_memory_window(app: AppHandle, query: Option<String>, document_ids: Option<Vec<String>>) { show_memory_window(&app, query, document_ids.unwrap_or_default()); }

#[tauri::command]
fn memory_window_ready(app: AppHandle, state: State<MemoryWindowState>) {
    if let Some(request) = state.ready() { emit_memory_query(&app, request); }
}

/// `Some(exit code)` when the command line asked for the agent setup or
/// removal without the app; `None` to start Coucou normally.
pub fn run_cli<I: IntoIterator<Item = String>>(args: I) -> Option<i32> {
    cli::parse(args).map(cli::run)
}

pub fn run() {
    let loaded = settings::load();
    let gate = Arc::new(PollGate::new());

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let _ = app.emit_to(island::WINDOW_LABEL, "tray", "open".to_string());
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_dialog::init())
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| hotkeys::on_shortcut(app, shortcut, event))
                .build(),
        )
        .plugin(
            tauri_plugin_window_state::Builder::new()
                .with_state_flags(quick::STATE_FLAGS)
                .with_denylist(&[island::WINDOW_LABEL, "settings"])
                .build(),
        )
        // Every Coucou page is our own: the mic is granted to it without a
        // WebView2 prompt (which the click-through island could not show).
        // Windows' privacy switch still applies on top of this.
        .on_permission_request(|_, kind| match kind {
            PermissionKind::Microphone => PermissionResponse::Allow,
            _ => PermissionResponse::Default,
        })
        .manage(Shared {
            settings: Mutex::new(loaded.clone()),
            gate: gate.clone(),
            memory_list_generation: Arc::new(AtomicU64::new(0)),
        })
        .manage(Pending::default())
        .manage(Chat::default())
        .manage(ChatMemoryState::default())
        .manage(MemoryWindowState::default())
        .manage(hotkeys::HotkeyState::default())
        .manage(robot::Robot::default())
        .invoke_handler(tauri::generate_handler![
            boot,
            save_settings,
            set_collapsed,
            set_island_rect,
            focus_window,
            reposition,
            open_url,
            open_in_vscode,
            focus_origin,
            quit_app,
            hooks_status,
            hooks_preview,
            hooks_apply,
            agent_hooks_status,
            agent_hooks_preview,
            agent_hooks_apply,
            hermes_clarify_pending,
            hermes_clarify_answer,
            agents_detect,
            agents_setup_all,
            agents_setup_dismiss,
            open_settings_for_setup,
            approval_decision,
            approval_answers,
            approval_ack,
            approval_decline,
            launch_task,
            log_line,
            chat_send,
            chat_reset,
            chat_private,
            remember_turn,
            remember_selection,
            prepare_forget_turn,
            forget_turn,
            hindsight_test_connection,
            memory_list,
            memory_get,
            memory_safe_detail,
            memory_update,
            memory_retire,
            memory_restore,
            memory_bulk_retire,
            memory_export,
            memory_save_export,
            router_models,
            router_normalize_url,
            ingest_file,
            secret_present,
            secret_set,
            secret_clear,
            refresh_integration,
            open_n8n,
            open_settings_window,
            open_memory_window,
            memory_window_ready,
            set_paused,
            hotkeys_status,
            hotkey_normalize,
            hotkeys_suspend,
            quick_hide,
            quick_show,
            chat_history_changed,
            microphone_status,
            open_microphone_settings,
            voice_transcribe,
            island_start_drag,
            island_set_locked,
            island_reset_position,
            robot_status,
            robot_start,
            robot_stop,
            robot_preview,
            robot_approve,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            tray::build(&handle, loaded.island_locked)?;
            // Before the island: all secondary WebView2 windows must share its lifecycle and browser arguments.
            create_settings_window(&handle);
            create_memory_window(&handle);
            quick::create_windows(&handle);
            hotkeys::apply(&handle, &loaded.hotkeys);

            if let Some(win) = island::window(&handle) {
                island::make_non_activating(&win);
                island::apply_geometry(&handle, &loaded.screen, loaded.island_position, false);
                let _ = win.show();
            }
            gate.collapsed.store(false, Ordering::Relaxed);
            gate.set_active(true);
            island::spawn_cursor_poll(handle.clone(), gate.clone());

            log::line(format!("--- Coucou {} started ---", env!("CARGO_PKG_VERSION")));
            hooks::ensure_hook_exe(&handle);
            pipe::start(handle.clone());
            integrations::start(handle.clone());
            if !loaded.setup_offered {
                offer_setup(handle.clone());
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Coucou");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn turn_timestamp_is_rfc3339_utc() {
        let value = time::OffsetDateTime::now_utc().format(&time::format_description::well_known::Rfc3339).unwrap();
        assert!(value.ends_with('Z'));
        assert!(time::OffsetDateTime::parse(&value, &time::format_description::well_known::Rfc3339).is_ok());
    }

    #[test]
    fn memory_command_contract_uses_exact_camel_case_names() {
        let source = include_str!("lib.rs");
        for name in ["memoryList", "memoryGet", "memorySafeDetail", "memoryUpdate", "memoryRetire", "memoryRestore", "memoryBulkRetire", "memoryExport", "memorySaveExport", "hindsightTestConnection"] {
            assert!(source.contains(&format!("#[tauri::command(rename = \"{name}\")]")), "missing exact command {name}");
        }
        for handler in ["memory_list", "memory_get", "memory_safe_detail", "memory_update", "memory_retire", "memory_restore", "memory_bulk_retire", "memory_export", "memory_save_export", "hindsight_test_connection"] {
            assert!(source.contains(&format!("            {handler},")), "missing handler registration {handler}");
        }
    }

    #[test]
    fn settings_commit_failure_keeps_memory_unchanged() {
        let mut current = Settings::default();
        current.screen = "primary".into();
        let mut candidate = current.clone();
        candidate.screen = "cursor".into();
        let persistence_calls = AtomicUsize::new(0);

        let error = commit_settings_with(&mut current, candidate, |_| {
            persistence_calls.fetch_add(1, Ordering::SeqCst);
            Err("disk full".into())
        }).unwrap_err();

        assert!(error.contains("disk full"));
        assert_eq!(persistence_calls.load(Ordering::SeqCst), 1);
        assert_eq!(current.screen, "primary");
    }

    #[test]
    fn settings_commit_persists_before_one_in_memory_update() {
        let mut current = Settings::default();
        current.screen = "primary".into();
        current.setup_offered = true;
        let original_position = current.island_position;
        let mut candidate = current.clone();
        candidate.screen = "cursor".into();
        candidate.setup_offered = false;
        let persistence_calls = AtomicUsize::new(0);

        let (committed, changes) = commit_settings_with(&mut current, candidate, |persisted| {
            persistence_calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(persisted.screen, "cursor");
            assert!(persisted.setup_offered);
            assert_eq!(persisted.island_position, original_position);
            Ok(())
        }).unwrap();

        assert_eq!(persistence_calls.load(Ordering::SeqCst), 1);
        assert_eq!(current.screen, "cursor");
        assert_eq!(committed.screen, "cursor");
        assert!(changes.screen_changed);
        assert!(!changes.autostart_changed);
    }

    #[tokio::test]
    async fn confirmed_bulk_uses_one_config_snapshot_for_validation_and_request_path() {
        use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::TcpListener};

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let request = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0_u8; 2048];
            loop {
                let count = stream.read(&mut buffer).await.unwrap();
                bytes.extend_from_slice(&buffer[..count]);
                if count == 0 || bytes.windows(4).any(|window| window == b"\r\n\r\n") { break; }
            }
            let body = r#"{"items":[],"total":0,"limit":25,"offset":0}"#;
            let response = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            stream.write_all(response.as_bytes()).await.unwrap();
            String::from_utf8(bytes).unwrap()
        });
        let mut current = Settings::default();
        current.hindsight.base_url = format!("http://{address}/hindsight");
        current.hindsight.allow_development_http = true;
        current.hindsight.tenant = "tenant-a".into();
        current.hindsight.bank = "bank-before".into();
        let snapshot = current.hindsight.clone();
        let scope = ConfirmedMemoryScope::new(
            MemoryBrowseRequest { filter: hindsight::MemoryFilter::default(), limit: 25, offset: 0 },
            snapshot.base_url.clone(), snapshot.tenant.clone(), snapshot.bank.clone(),
        ).unwrap();
        current.hindsight.bank = "bank-after".into();

        let result = bulk_retire_with_snapshot(snapshot, scope, Arc::new(AtomicU64::new(0)), |config| {
            assert_eq!(config.bank, "bank-before");
            hindsight::HindsightClient::with_token(config, "secret".into())
        }).await.unwrap();

        assert_eq!(result.requested, 0);
        assert!(request.await.unwrap().starts_with("GET /hindsight/v1/tenant-a/banks/bank-before/memories/list?"));
    }

    #[tokio::test]
    async fn invalid_confirmed_bulk_scope_fails_before_client_construction() {
        let config = Settings::default().hindsight;
        let mut scope = ConfirmedMemoryScope::new(
            MemoryBrowseRequest { filter: hindsight::MemoryFilter::default(), limit: 25, offset: 0 },
            config.base_url.clone(), config.tenant.clone(), config.bank.clone(),
        ).unwrap();
        scope.request.limit = 50;
        let constructions = AtomicUsize::new(0);

        let error = bulk_retire_with_snapshot(config, scope, Arc::new(AtomicU64::new(0)), |_| {
            constructions.fetch_add(1, Ordering::SeqCst);
            panic!("invalid scope constructed a client")
        }).await.unwrap_err();

        assert!(error.to_string().contains("fingerprint"));
        assert_eq!(constructions.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn baseline_handlers_and_quick_robot_registration_survive_memory_merge() {
        let source = include_str!("lib.rs");
        for handler in ["hermes_clarify_pending", "hermes_clarify_answer"] {
            assert!(source.contains(&format!("            {handler},")), "missing baseline handler {handler}");
        }
        assert!(source.contains("mod hermes_clarify;"));
        let quick = include_str!("quick.rs");
        assert!(quick.contains("pub const ROBOT: &str = \"quick-robot\""));
        assert!(quick.contains("create(app, ROBOT, \"quick-robot.html\""));
        assert!(quick.contains("pub fn is_quick"));
    }

    #[test]
    fn memory_query_requested_before_webview_ready_is_replayed_once() {
        let state = MemoryWindowState::default();
        assert_eq!(state.request(Some("duplicate tea".into()), vec!["doc-b".into(), "doc-a".into(), "doc-b".into()]), None);
        assert_eq!(state.ready(), Some(MemoryWindowRequest { query: None, document_ids: vec!["doc-b".into(), "doc-a".into()] }));
        assert_eq!(state.ready(), None);
        assert_eq!(state.request(Some("new query".into()), vec![]), Some(MemoryWindowRequest { query: Some("new query".into()), document_ids: vec![] }));
    }

    #[test]
    fn memory_window_is_hidden_and_created_before_the_island() {
        let source = include_str!("lib.rs");
        let create = source.find("fn create_memory_window").expect("memory window factory");
        let body = &source[create..source.find("pub fn show_memory_window").expect("memory window show helper")];
        assert!(body.contains(".visible(false)"));
        assert!(body.contains(".resizable(true)"));
        assert!(body.contains("additional_browser_args(BROWSER_ARGS)"));
        let setup = source.find(".setup(move |app|").unwrap();
        let create_memory = source[setup..].find("create_memory_window(&handle)").expect("startup memory window");
        let island = source[setup..].find("island::window(&handle)").expect("island setup");
        assert!(create_memory < island, "memory WebView must exist before the island WebView lifecycle is used");
    }

    #[test]
    fn secret_safe_hindsight_commands_never_serialize_the_token() {
        let source = include_str!("lib.rs");
        let start = source.find("fn hindsight_test_connection").expect("connection test command");
        let end = source[start..].find("fn memory_manager").map(|offset| start + offset).expect("manager helper");
        let command = &source[start..end];
        assert!(!command.contains("token:"));
        assert!(!command.contains("secrets::get"));
        assert!(command.contains("HindsightClient::new"));
    }

    #[test]
    fn reset_while_provider_succeeds_has_no_memory_side_effects_and_returns_cleared() {
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
        runtime.block_on(async {
            let chat = Chat::default();
            let memory = ChatMemoryState::default();
            let generation = chat.generation();
            let (started_tx, started_rx) = tokio::sync::oneshot::channel();
            let (release_tx, release_rx) = tokio::sync::oneshot::channel();
            let retain_calls = AtomicUsize::new(0);
            let events = Mutex::new(Vec::<String>::new());
            let provider = async move {
                let _ = started_tx.send(());
                let _ = release_rx.await;
                Ok(ChatReply {
                    text: "late success".into(),
                    actions: vec![],
                    memory_status: None,
                    turn_id: None,
                })
            };
            let turn_id = "reset-turn".to_string();
            let completed = CompletedTurn::new(
                &turn_id,
                "stamp",
                "anthropic",
                "model",
                "https://example.test/hindsight",
                "default",
                "hieu",
                "remember tea",
                "late success",
            );

            let send = coordinate_chat_send(
                &chat,
                &memory,
                generation,
                turn_id.clone(),
                None,
                completed,
                TurnSafety::default(),
                true,
                false,
                provider,
                || (true, false),
                |_, _| {
                    retain_calls.fetch_add(1, Ordering::SeqCst);
                    events.lock().unwrap().extend(["saving".into(), "saved".into()]);
                },
            );
            let reset = async {
                started_rx.await.unwrap();
                chat_reset_state(&chat, &memory);
                release_tx.send(()).unwrap();
            };
            let (result, ()) = tokio::join!(send, reset);

            assert_eq!(chat.generation(), generation + 1);
            assert!(chat.snapshot().is_empty());
            assert_eq!(result.unwrap_err(), claude::CLEARED);
            assert!(memory.completed.get(&turn_id).is_none());
            assert_eq!(retain_calls.load(Ordering::SeqCst), 0);
            assert!(events.lock().unwrap().is_empty());
        });
    }

    #[test]
    fn reset_after_completed_action_preserves_reply_without_memory_side_effects() {
        let runtime = tokio::runtime::Builder::new_current_thread().build().unwrap();
        runtime.block_on(async {
            let chat = Chat::default();
            let memory = ChatMemoryState::default();
            let generation = chat.generation();
            let (started_tx, started_rx) = tokio::sync::oneshot::channel();
            let (release_tx, release_rx) = tokio::sync::oneshot::channel();
            let retain_calls = AtomicUsize::new(0);
            let state_checks = AtomicUsize::new(0);
            let provider = async move {
                let _ = started_tx.send(());
                let _ = release_rx.await;
                Ok(ChatReply {
                    text: "Task started".into(),
                    actions: vec![tools::ChatAction {
                        kind: "started",
                        agent: "claude".into(),
                        target: "cli".into(),
                        folder: "project".into(),
                        message: "Started Claude".into(),
                    }],
                    memory_status: None,
                    turn_id: None,
                })
            };
            let turn_id = "action-reset-turn".to_string();
            let completed = CompletedTurn::new(
                &turn_id, "stamp", "anthropic", "model", "https://example.test/hindsight", "default", "hieu",
                "start a task", "Task started",
            );

            let send = coordinate_chat_send(
                &chat, &memory, generation, turn_id.clone(), Some("recalled".into()),
                completed, TurnSafety::default(), true, false, provider,
                || {
                    state_checks.fetch_add(1, Ordering::SeqCst);
                    (true, false)
                },
                |_, _| { retain_calls.fetch_add(1, Ordering::SeqCst); },
            );
            let reset = async {
                started_rx.await.unwrap();
                chat_reset_state(&chat, &memory);
                release_tx.send(()).unwrap();
            };
            let (result, ()) = tokio::join!(send, reset);
            let reply = result.expect("completed action must survive generation reset");

            assert_eq!(reply.actions.len(), 1);
            assert_eq!(reply.actions[0].kind, "started");
            assert_eq!(reply.text, "Task started");
            assert_eq!(reply.turn_id, None);
            assert_eq!(reply.memory_status, None);
            assert!(memory.completed.get(&turn_id).is_none());
            assert_eq!(state_checks.load(Ordering::SeqCst), 0);
            assert_eq!(retain_calls.load(Ordering::SeqCst), 0);
        });
    }
}
