// Coucou for Windows — app wiring and the commands the island calls.

mod claude;
mod files;
mod hooks;
mod integrations;
mod island;
mod log;
mod opencode;
mod opencode_chat;
mod opencode_server;
mod pipe;
mod secrets;
mod settings;
mod tray;
mod win_user;

use std::os::windows::process::CommandExt;
use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::{ManagerExt, MacosLauncher};

use claude::{Chat, ChatContext, ChatReply};
use files::DroppedFile;
use hooks::{HookPreview, HookStatus};
use island::{PollGate, ScreenInfo};
use opencode::{OpencodePreview, OpencodeStatus};
use pipe::Pending;
use settings::Settings;

/// Keeps spawned helpers from flashing a console window.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub struct Shared {
    pub settings: Mutex<Settings>,
    pub gate: Arc<PollGate>,
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
    // Launch is always centred (see `setup`), so report that rather than the
    // saved resting place — the front end derives the island's offset from this
    // value and must match where the window actually is.
    settings.notch_position = 0.5;
    let screen = island::screen_info(&app, &settings.screen);
    BootInfo {
        settings,
        screen,
        version: env!("CARGO_PKG_VERSION").to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
    }
}

#[tauri::command]
fn save_settings(app: AppHandle, shared: State<Shared>, settings: Settings) {
    let (screen_changed, autostart_changed, server_changed) = {
        let mut current = shared.settings.lock().unwrap();
        let screen_changed = current.screen != settings.screen;
        let autostart_changed = current.autostart != settings.autostart;
        let server_changed = current.chat_via_server != settings.chat_via_server;
        *current = settings.clone();
        (screen_changed, autostart_changed, server_changed)
    };
    if let Err(err) = settings::save(&settings) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    // The setting means "keep a server open for as long as the app is", so
    // flipping it takes effect now rather than at the next launch. After the
    // save, so the file already agrees with what we are about to do.
    if server_changed {
        if settings.chat_via_server {
            let bin = settings.opencode_bin.clone();
            opencode_server::ensure_ready(&bin);
        } else {
            opencode_server::stop_managed_port();
        }
    }
    if autostart_changed {
        let manager = app.autolaunch();
        let result = if settings.autostart { manager.enable() } else { manager.disable() };
        if let Err(err) = result {
            eprintln!("[coucou] autostart: {err}");
        }
    }
    if screen_changed {
        let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
        island::apply_geometry(&app, &settings.screen, collapsed, settings.notch_position);
    }
    // Keep the other window in step (island ⇄ settings window).
    let _ = app.emit("settings-changed", settings);
}

/// Hidden island → shrink the window to the invisible wake strip and park the
/// cursor poll; anything else → full panel and 60 Hz polling.
#[tauri::command]
fn set_collapsed(app: AppHandle, shared: State<Shared>, collapsed: bool) {
    let (pref, position) = {
        let current = shared.settings.lock().unwrap();
        (current.screen.clone(), current.notch_position)
    };
    shared.gate.collapsed.store(collapsed, Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed, position);
    // The reduced stub must always take the mouse, and a resize invalidates the flag.
    island::set_ignore_cursor(&app, false);
    shared.gate.forget_ignore_state();
    // The poll keeps running while reduced. It used to be parked, because the
    // resting state was an invisible strip with nothing to see; the stub is a
    // real, visible island now, and parking the poll left the click-through flag
    // frozen, so a stub that drifted under the cursor could not be woken again.
    // The window is only 80x24 here, so polling it stays cheap.
    shared.gate.set_active(true);
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

#[tauri::command]
fn reposition(app: AppHandle, shared: State<Shared>) {
    let (pref, position) = {
        let current = shared.settings.lock().unwrap();
        (current.screen.clone(), current.notch_position)
    };
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed, position);
}

/// Marks the start and end of a sideways drag.
///
/// Only matters for the "display under the cursor" preference: while dragging, the
/// island holds the display it started on instead of following the pointer across
/// the boundary mid-drag, which would fight the drag.
#[tauri::command]
fn set_dragging(dragging: bool) {
    island::set_dragging(dragging);
}

/// Moves the resting island sideways without waiting for the settings window to
/// save. Called live while the compact island is dragged, then once more to
/// persist the final resting place.
#[tauri::command]
fn set_notch_position(app: AppHandle, shared: State<Shared>, position: f64) {
    let position = if position.is_finite() { position.clamp(0.0, 1.0) } else { 0.5 };
    let (pref, saved) = {
        let mut current = shared.settings.lock().unwrap();
        current.notch_position = position;
        (current.screen.clone(), current.clone())
    };
    if let Err(err) = settings::save(&saved) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed, position);
    let _ = app.emit("settings-changed", saved);
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

/// Our own `where`: walks %PATH% against %PATHEXT%, no shell involved.
/// Rust quotes arguments correctly for `.cmd`/`.bat` targets since 1.77, so
/// spawning `code.cmd` directly is safe.
pub(crate) fn find_on_path(stem: &str) -> Option<std::path::PathBuf> {
    let exts = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
    let dirs = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&dirs) {
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
    // Coucou may have started an opencode server of its own; do not leave it
    // running once the app is gone.
    opencode_server::shutdown();
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

// ── opencode plugin ─────────────────────────────────────────────────────────

#[tauri::command]
fn opencode_status() -> OpencodeStatus {
    opencode::status()
}

/// Returns the diff the user has to look at before anything is written.
#[tauri::command]
fn opencode_preview(install: bool) -> Result<OpencodePreview, String> {
    opencode::preview(install)
}

/// Only ever called from an explicit click in the settings window.
#[tauri::command]
fn opencode_apply(install: bool, fingerprint: String) -> Result<String, String> {
    opencode::write(install, &fingerprint)
}

#[tauri::command]
fn approval_decision(app: AppHandle, request_id: String, decision: String) {
    pipe::answer(&app, &request_id, &decision);
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

// ── Chat, files and secrets ───────────────────────────────────────────────────

/// One chat turn. The API key and any file bytes stay on the Rust side.
///
/// Normally this follows Settings → Chat exactly. The exception is a Claude
/// choice with no key stored: there is nothing to answer with, and the user's
/// own opencode is right there, so the turn goes there instead of stopping on
/// "API key missing". With neither available the original message stands, since
/// it names the fix.
#[tauri::command]
async fn chat_send(
    shared: State<'_, Shared>,
    chat: State<'_, Chat>,
    ochat: State<'_, opencode_chat::OpencodeChat>,
    query: String,
    context: Option<ChatContext>,
    session: Option<String>,
) -> Result<ChatReply, String> {
    let (provider, model, bin, omodel) = {
        let s = shared.settings.lock().unwrap();
        (
            s.chat_provider.clone(),
            s.model.clone(),
            s.opencode_bin.clone(),
            s.opencode_model.clone(),
        )
    };
    let use_opencode = provider == "opencode"
        || (!secrets::present("anthropic-api-key")
            && opencode_chat::resolve_bin(&bin).is_some());
    if use_opencode {
        opencode_chat::send(&ochat, &bin, &omodel, query, context, session).await
    } else {
        claude::send(&chat, &model, query, context).await
    }
}

/// The `/`-menu commands of the running opencode, for the chat command popup.
/// Empty when no opencode is up — the island then hides the menu.
#[tauri::command]
fn opencode_commands() -> Vec<opencode_server::CommandInfo> {
    opencode_server::commands()
}

/// Live sessions of the running opencode, newest first, for the session picker.
#[tauri::command]
fn opencode_sessions() -> Vec<opencode_server::SessionInfo> {
    opencode_server::sessions()
}

/// Deletes a session. The island confirms with the user before calling this.
#[tauri::command]
fn opencode_delete_session(id: String) -> Result<(), String> {
    if id.trim().is_empty() {
        return Err("no session given".to_string());
    }
    opencode_server::delete_session(&id)
}

/// The messages of a picked session, so the chat opens on the conversation
/// instead of an empty window.
#[tauri::command]
fn opencode_session_messages(id: String) -> Vec<opencode_server::HistoryMessage> {
    opencode_server::session_messages(&id)
}

/// Base URL of the opencode server Coucou is talking to, or null when none.
#[tauri::command]
fn opencode_server_url() -> Option<String> {
    opencode_server::discover(false)
}

#[tauri::command]
fn chat_reset(chat: State<Chat>, ochat: State<opencode_chat::OpencodeChat>) {
    chat.reset();
    ochat.reset();
}

/// What the Settings → Chat section shows: resolved binary, key presence.
#[tauri::command]
fn chat_status(shared: State<Shared>) -> opencode_chat::ChatStatus {
    let s = shared.settings.lock().unwrap();
    opencode_chat::ChatStatus {
        bin_configured: s.opencode_bin.clone(),
        bin_resolved: opencode_chat::resolve_bin(&s.opencode_bin)
            .map(|p| p.to_string_lossy().to_string()),
        claude_key_present: secrets::present("anthropic-api-key"),
    }
}

/// Copies a dropped file into the inbox and reports its name back.
#[tauri::command]
fn ingest_file(path: String) -> Result<DroppedFile, String> {
    files::ingest(&path)
}

/// The island may only ask whether a key exists — never read it.
#[tauri::command]
fn debug_log(line: String) {
    crate::log::line(&format!("[island] {line}"));
}

#[tauri::command]
fn secret_present(key: String) -> bool {
    secrets::present(&key)
}

#[tauri::command]
fn secret_set(key: String, value: String) -> Result<(), String> {
    secrets::set(&key, &value)
}

#[tauri::command]
fn secret_clear(key: String) -> Result<(), String> {
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

/// WebView2 allows exactly one browser environment per app, and its options are
/// fixed by whichever webview is created first. Every window must therefore ask
/// for the *same* arguments as the island (see `additionalBrowserArgs` in
/// tauri.conf.json) — a mismatch makes the second window come up blank, with no
/// error anywhere.
const BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required";

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

#[tauri::command]
fn open_settings_window(app: AppHandle) {
    show_settings_window(&app);
}

pub fn run() {
    let loaded = settings::load();
    let gate = Arc::new(PollGate::new());
    // "Keep a server open for as long as the app is" starts here rather than on
    // the first message, off the main thread so binding the port never delays
    // the window. Off means no server of our own, and any one an earlier run
    // leaked on our port is cleared out.
    if loaded.chat_via_server {
        let bin = loaded.opencode_bin.clone();
        opencode_server::ensure_ready(&bin);
    } else {
        opencode_server::stop_managed_port();
    }

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let _ = app.emit_to(island::WINDOW_LABEL, "tray", "open".to_string());
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .manage(Shared {
            settings: Mutex::new(loaded.clone()),
            gate: gate.clone(),
        })
        .manage(Pending::default())
        .manage(Chat::default())
        .manage(opencode_chat::OpencodeChat::default())
        .invoke_handler(tauri::generate_handler![
            boot,
            save_settings,
            set_collapsed,
            set_island_rect,
            focus_window,
            reposition,
            set_notch_position,
            set_dragging,
            open_url,
            open_in_vscode,
            quit_app,
            hooks_status,
            hooks_preview,
            hooks_apply,
            opencode_status,
            opencode_preview,
            opencode_apply,
            approval_decision,
            approval_ack,
            approval_decline,
            log_line,
chat_send,
            chat_reset,
        chat_status,
        opencode_commands,
        opencode_sessions,
    opencode_delete_session,
    opencode_session_messages,
        opencode_server_url,
            ingest_file,
            secret_present,
            debug_log,
            secret_set,
            secret_clear,
            refresh_integration,
            open_n8n,
            open_settings_window,
            set_paused,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            tray::build(&handle)?;
            // Before the island: see create_settings_window.
            create_settings_window(&handle);

            if let Some(win) = island::window(&handle) {
island::make_non_activating(&win);
                // Always open centred, whatever resting place was saved last time.
                // The saved position is where the user parks the bar, not where the
                // app should appear — surprising as that would be on launch — so the
                // value is kept in settings and applied only once the bar is dragged.
                let mut loaded = loaded;
                loaded.notch_position = 0.5;
                island::apply_geometry(&handle, &loaded.screen, false, loaded.notch_position);
                let _ = win.show();
            }
            gate.collapsed.store(false, Ordering::Relaxed);
            gate.set_active(true);
            island::spawn_cursor_poll(handle.clone(), gate.clone());

            log::line(format!("--- Coucou {} started ---", env!("CARGO_PKG_VERSION")));
            hooks::ensure_hook_exe(&handle);
            opencode::ensure_plugin();
            pipe::start(handle.clone());
            integrations::start(handle.clone());
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Coucou");
}
