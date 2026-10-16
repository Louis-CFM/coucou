// Coucou for Windows — app wiring and the commands the island calls.

mod agent_hooks;
mod agents;
mod chat;
mod claude;
mod codex_plan;
mod config_file;
mod desktop;
mod editor;
mod files;
mod flow;
mod github;
mod gitlab;
mod gitlab_dash;
mod gitlab_panel;
mod hooks;
mod i18n;
mod identity;
mod integrations;
mod island;
mod jetbrains;
mod local_chat;
mod log;
mod net;
mod notes;
mod openai_compat;
mod phone_link;
mod pipe;
mod platform;
#[cfg(target_os = "linux")]
mod portal;
mod recap;
mod secrets;
mod session_window;
mod settings;
mod shortcuts;
mod sounds;
mod speech;
mod spotify;
mod tray;
mod voice;
#[cfg(windows)]
mod webview_drop;
mod wsl;

use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::{ManagerExt, MacosLauncher};

use chat::{Chat, ChatContext, ChatReply, ModelInfo};
use files::DroppedFile;
use hooks::{HookPreview, HookStatus};
use island::{PollGate, ScreenInfo};
use pipe::Pending;
use settings::Settings;

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
    /// False where the OS has no global cursor (Wayland): the page then reports
    /// the cursor from its own mouse events.
    cursor_poll: bool,
}

#[tauri::command]
fn boot(app: AppHandle, shared: State<Shared>) -> BootInfo {
    let mut settings = shared.settings.lock().unwrap().clone();
    // The real state of ~/.claude/settings.json wins over whatever we stored.
    let hooks_status = hooks::status();
    settings.hooks_installed = hooks_status.installed;
    settings.plan_relay_installed = hooks_status.plan_relay_installed;
    let screen = island::screen_info(&app, &settings.screen);
    BootInfo {
        settings,
        screen,
        version: env!("CARGO_PKG_VERSION").to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
        cursor_poll: platform::CURSOR_POLL,
    }
}

#[tauri::command]
fn save_settings(app: AppHandle, shared: State<Shared>, settings: Settings) {
    let (screen_changed, autostart_changed, shortcuts_changed) = {
        let mut current = shared.settings.lock().unwrap();
        let screen_changed = current.screen != settings.screen;
        let autostart_changed = current.autostart != settings.autostart;
        let shortcuts_changed = current.shortcuts != settings.shortcuts;
        // Where Mochi sits on the desktop is desktop.rs's to say, not a webview's.
        let mut settings = settings.clone();
        settings.desktop_mochi = current.desktop_mochi.clone();
        // Same for the phone link: only its own commands turn it on or off.
        settings.phone_link = current.phone_link;
        settings.phone_chat = current.phone_chat;
        settings.phone_details = current.phone_details;
        settings.phone_answers = current.phone_answers;
        settings.phone_diffs = current.phone_diffs;
        settings.phone_usage = current.phone_usage;
        settings.phone_services = current.phone_services.clone();
        settings.phone_relay = current.phone_relay;
        settings.phone_relay_url = current.phone_relay_url.clone();
        settings.phone_chat_models = current.phone_chat_models.clone();
        *current = settings;
        (screen_changed, autostart_changed, shortcuts_changed)
    };
    let settings = shared.settings.lock().unwrap().clone();
    if let Err(err) = settings::save(&settings) {
        log::line(format!("could not save settings: {err}"));
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
        island::apply_geometry(&app, &settings.screen, collapsed);
        gitlab_panel::screen_changed(&app);
    }
    integrations::settings_saved(&app, &settings.active_integrations);
    spotify::sync(&app, &settings.active_integrations);
    if shortcuts_changed {
        shortcuts::apply(&app, &settings.shortcuts);
    }
    if i18n::set_picked(&settings.language) {
        language_changed(&app);
    }
    // Keep the other window in step (island ⇄ settings window).
    let _ = app.emit("settings-changed", settings);
}

/// The island reports the system's languages at launch, for "System" in
/// Settings → Language (WebView2 and WebKitGTK know them best).
#[tauri::command]
fn set_system_languages(app: AppHandle, languages: Vec<String>) {
    if i18n::set_system(languages) {
        language_changed(&app);
    }
}

/// What Rust labels itself follows the new language: the tray menu and the
/// settings window's title. The webviews switch on their own.
fn language_changed(app: &AppHandle) {
    tray::retitle(app);
    if let Some(window) = app.get_webview_window(HUB_LABEL) {
        let _ = window.set_title("Coucou");
    }
}

/// Hidden island → shrink the window to the invisible wake strip and park the
/// cursor poll; anything else → full panel and 60 Hz polling.
#[tauri::command]
fn set_collapsed(app: AppHandle, shared: State<Shared>, collapsed: bool) {
    let pref = shared.settings.lock().unwrap().screen.clone();
    shared.gate.collapsed.store(collapsed, Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
    // The wake strip must always take the mouse, and a resize invalidates the flag.
    island::refresh_click_through(&app, &shared.gate);
    shared.gate.set_active(!collapsed);
    platform::set_pointer_watch(!collapsed);
}

/// The front end pushes the island shape; Rust decides click-through from it.
#[tauri::command]
fn set_island_rect(app: AppHandle, shared: State<Shared>, x: f64, y: f64, width: f64, height: f64) {
    shared.gate.set_rect(island::IslandRect { x, y, w: width, h: height });
    // Without the cursor poll the input region is the click-through: it follows the island.
    if !platform::CURSOR_POLL {
        island::refresh_click_through(&app, &shared.gate);
    }
}

#[tauri::command]
fn focus_window(app: AppHandle, focused: bool) {
    let Some(win) = island::window(&app) else { return };
    platform::set_activating(&win, focused);
    if focused {
        let _ = win.set_focus();
    }
}

#[tauri::command]
fn reposition(app: AppHandle, shared: State<Shared>) {
    let pref = shared.settings.lock().unwrap().screen.clone();
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    island::apply_geometry(&app, &pref, collapsed);
    gitlab_panel::screen_changed(&app);
}

/// The panel is laid out in CSS px against the window's own scale. If the webview
/// reports a different devicePixelRatio (it ends up bigger than the window and gets
/// cut), correct its zoom so one CSS px is one logical px again.
#[tauri::command]
fn fit_zoom(app: AppHandle, dpr: f64) -> bool {
    let Some(win) = island::window(&app) else { return false };
    let scale = win.scale_factor().unwrap_or(1.0);
    static ZOOM: std::sync::Mutex<f64> = std::sync::Mutex::new(1.0);
    let mut zoom = ZOOM.lock().unwrap();
    if let Some(new_zoom) = island::calculate_zoom_correction(*zoom, scale, dpr) {
        *zoom = new_zoom;
        log::line(format!("webview dpr {dpr} != window scale {scale} — setting zoom {new_zoom:.3}"));
        let _ = win.set_zoom(new_zoom);
        true
    } else {
        false
    }
}


/// The displays the island can be pinned to, for Settings.
#[tauri::command]
fn list_monitors(app: AppHandle) -> Vec<island::MonitorChoice> {
    island::monitor_choices(&app)
}

#[tauri::command]
fn open_url(url: String) {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return;
    }
    platform::open_url(&url);
}

/// The editor to open things in: the one a caller names (the VS Code pill's own
/// button), else the one picked in Settings.
fn chosen_editor(named: Option<&str>) -> editor::Editor {
    match named {
        Some(id) => editor::Editor::from_id(id),
        None => editor::Editor::from_id(&settings::load().editor),
    }
}

/// Runs the editor's launcher on a target; false when there is none to run.
fn launch_editor(ed: editor::Editor, opening: Option<&EditorTarget>, line: Option<u32>) -> bool {
    let Some(exe) = ed.launcher() else { return false };
    let mut cmd = Command::new(exe);
    if let Some(opening) = opening {
        cmd.args(ed.args(&opening.local, &opening.args, line));
    }
    platform::no_console(&mut cmd).spawn().is_ok()
}

/// "Open terminal" opens the working folder in the editor picked in Settings
/// (VS Code unless it was changed) when its launcher is found, and falls back
/// to the file manager otherwise.
#[tauri::command]
fn open_in_editor(path: Option<String>, editor: Option<String>) -> bool {
    open_folder_in(chosen_editor(editor.as_deref()), path)
}

fn open_folder_in(ed: editor::Editor, path: Option<String>) -> bool {
    // No shell anywhere near this. The path is a project folder chosen by
    // whoever is using Claude Code, and a shell would happily read `&`, `^`, `%`
    // or `$` in a folder name as syntax. Finding the launcher ourselves and
    // handing the path over as a separate argument keeps it a path.
    let path = path.filter(|p| !p.is_empty());
    // It arrives in a hook payload: only an existing folder, given by its full
    // path, goes any further. `code` would read `--something` as an option, and
    // xdg-open would launch a file with whatever handles its type.
    let opening = match path.as_deref() {
        Some(p) => match editor_target(p, true) {
            Some(opening) => Some(opening),
            None => return false,
        },
        None => None,
    };
    if launch_editor(ed, opening.as_ref(), None) {
        return true;
    }
    if let Some(opening) = &opening {
        platform::reveal_folder(&opening.local.to_string_lossy());
    }
    false
}

/// Brings forward the PhpStorm window a session runs in, found by the IDE port
/// its Claude Code was given (jetbrains.rs). False when it has none, or no open
/// window answers to it.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
fn raise_session_project(session_id: Option<&str>, cwd: Option<&str>) -> bool {
    let Some(port) = session_id.and_then(session_window::ide_port) else { return false };
    let projects = jetbrains::open_projects(&jetbrains::lock_dir());
    let Some(found) = jetbrains::for_port(&projects, port, cwd.map(std::path::Path::new)) else { return false };
    let done = platform::focus_editor_window("phpstorm", &found.name(), Some(found.project.pid));
    log::line(format!("terminal: IDE port {port} is PhpStorm pid {} on {:?}: {}", found.project.pid, found.name(), if done { "raised" } else { "no window" }));
    done
}

/// Which editors can be launched on this machine, by the id Settings stores.
#[tauri::command]
fn editors_status() -> std::collections::HashMap<String, bool> {
    [("vscode", editor::Editor::VsCode), ("phpstorm", editor::Editor::PhpStorm)]
        .into_iter()
        .map(|(id, ed)| (id.to_string(), ed.launcher().is_some()))
        .collect()
}

/// Where a path from a hook payload is, and what VS Code's `code` is given for it.
struct EditorTarget {
    /// The path as this machine reaches it: the one that was given, or for a
    /// session in WSL its place on the distro's network share.
    local: std::path::PathBuf,
    /// The arguments for VS Code's `code`.
    args: Vec<std::ffi::OsString>,
}

/// The target for `path`, if it may go to the editor: an existing folder (or,
/// with `folder` false, an existing regular file) given by its full path. On
/// Windows a path that starts with `/` is a session in WSL's: it is looked for in
/// the running distros and handed over as the distro sees it when VS Code can
/// open it there (wsl.rs).
fn editor_target(path: &str, folder: bool) -> Option<EditorTarget> {
    let exists = |p: &std::path::Path| if folder { p.is_dir() } else { p.is_file() };
    #[cfg(windows)]
    if path.starts_with('/') {
        let (distro, unc) = wsl::resolve_linux_path(path)?;
        if !exists(&unc) {
            return None;
        }
        let args = wsl::editor_args(&distro, path, &unc, wsl::remote_wsl_installed());
        return Some(EditorTarget { local: unc, args });
    }
    let p = std::path::Path::new(path);
    (p.is_absolute() && exists(p)).then(|| EditorTarget { local: p.to_path_buf(), args: vec![p.as_os_str().to_owned()] })
}

/// "Open terminal": brings forward the terminal or editor window the session
/// runs in, when it was found (see session_window.rs); otherwise opens the
/// folder in the editor picked in Settings, as before.
#[tauri::command]
fn open_session(session_id: Option<String>, path: Option<String>) -> bool {
    let owners = session_id.as_deref().and_then(session_window::lookup);
    #[cfg(target_os = "linux")]
    let cwd = path.clone();
    // PhpStorm has the project open, not the sub-folder a `cd` left the session
    // in: it is the project that is looked for, and opened if it is not open.
    let path = if chosen_editor(None) == editor::Editor::PhpStorm {
        path.map(|p| session_window::project_root(&p))
    } else {
        path
    };
    // Nothing remembered (the app started after the session did, or the window
    // was never found): on Linux the editor's own window for the folder is still
    // looked for, below. Elsewhere the editor opens.
    #[cfg(not(target_os = "linux"))]
    let Some(owners) = owners else {
        return open_folder_in(chosen_editor(None), path);
    };
    let folder = path.as_deref().map(session_window::folder_name).unwrap_or_default().to_string();
    #[cfg(windows)]
    {
        // The tab, when the session's terminal has tabs; else the window of the
        // process. UI Automation can take a while, so never on the UI thread a
        // sync command runs on: the editor still opens when nothing could be
        // brought forward.
        let tab = session_id.as_deref().and_then(session_window::tab_of);
        std::thread::spawn(move || {
            let by_tab = tab.as_ref().is_some_and(platform::focus_session_tab);
            let brought = by_tab || platform::focus_session_window(&owners, &folder);
            log::line(format!(
                "terminal: open session {} — window of {} folder {folder:?}, tab {}: {}",
                session_id.as_deref().map(|s| &s[..s.len().min(8)]).unwrap_or(""),
                platform::describe_processes(&owners),
                match (&tab, by_tab) {
                    (None, _) => "unknown",
                    (Some(_), true) => "selected",
                    (Some(_), false) => "not found",
                },
                if brought { "brought forward" } else { "not brought forward, the editor opens" },
            ));
            if !brought {
                open_folder_in(chosen_editor(None), path);
            }
        });
        true
    }
    // Linux asks the display server, KWin or the terminal, which can take a
    // moment: never on the UI thread a sync command runs on. The editor still
    // opens when none of them could bring the window forward.
    #[cfg(target_os = "linux")]
    {
        std::thread::spawn(move || {
            let ed = chosen_editor(None);
            // PhpStorm: the window of the IDE the session's Claude Code is connected
            // to, whatever folder the session has drifted into.
            let by_ide = ed == editor::Editor::PhpStorm && raise_session_project(session_id.as_deref(), cwd.as_deref());
            let by_owners = !by_ide && owners.as_deref().is_some_and(|o| platform::focus_session_window(o, &folder));
            // The editor already has the project open: its window is the one.
            let brought = by_ide
                || by_owners
                || ed.window_class().is_some_and(|class| platform::focus_editor_window(class, &folder, None));
            log::line(format!(
                "terminal: open session — owners {owners:?} folder {folder:?}: {}",
                if brought { "window brought forward" } else { "not brought forward, the editor opens" },
            ));
            if !brought {
                open_folder_in(ed, path);
            }
        });
        true
    }
}

/// The Claude Desktop pill's target: the Claude app (Windows only — it has no
/// Linux build).
#[tauri::command]
fn open_claude_desktop() -> bool {
    platform::open_claude_desktop()
}

/// The diff card's ↗: opens the edited file in the editor picked in Settings
/// when its launcher is found (PhpStorm on the first changed line, found from
/// the hint), otherwise
/// shows its folder. The file itself is never opened by its type — xdg-open or
/// Explorer would run a script that Claude just wrote.
#[tauri::command]
fn open_file_in_editor(path: String, hint: Option<editor::LineHint>, session_id: Option<String>) -> bool {
    // A relative path, a folder or a path `code` could read as an option goes no
    // further; one from a session in WSL is turned into its place on the distro.
    let Some(file) = editor_target(&path, false) else { return false };
    let ed = chosen_editor(None);
    if ed == editor::Editor::PhpStorm {
        // The window of the open project that holds the file, in whichever PhpStorm
        // it is open: the session's own when it holds it. The launcher then opens
        // the file in that window, which is in front.
        let projects = jetbrains::open_projects(&jetbrains::lock_dir());
        let own = session_id.as_deref().and_then(session_window::ide_port);
        if let Some(found) = jetbrains::for_file(&projects, &file.local, own) {
            platform::focus_editor_window("phpstorm", &found.name(), Some(found.project.pid));
        }
    }
    // Only PhpStorm is asked for a line, so only then is the file read.
    let line = hint.filter(|_| ed == editor::Editor::PhpStorm).and_then(|h| h.locate_in(&file.local));
    if launch_editor(ed, Some(&file), line) {
        return true;
    }
    if let Some(folder) = file.local.parent().filter(|d| d.is_dir()) {
        platform::reveal_folder(&folder.to_string_lossy());
    }
    false
}

#[tauri::command]
fn quit_app(app: AppHandle) {
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

/// Pill ID → whether that agent's hooks reach Coucou. Read-only.
#[tauri::command]
async fn agent_hooks_status() -> std::collections::HashMap<String, bool> {
    // WSL's hooks are looked for too (wsl.exe and a few files over the share).
    tauri::async_runtime::spawn_blocking(agent_hooks::status).await.unwrap_or_default()
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
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

// ── Claude Code in WSL ───────────────────────────────────────────────────────

/// The WSL distros, and for each running one the users who have a ~/.claude.
/// Asks `wsl.exe` and reads a few directories, so off the main thread.
#[tauri::command]
async fn wsl_hooks_list() -> Vec<wsl::WslDistro> {
    tauri::async_runtime::spawn_blocking(wsl::list).await.unwrap_or_default()
}

/// The diff the user has to look at before anything is written to a distro.
#[tauri::command]
async fn wsl_hooks_preview(distro: String, user: String, install: bool) -> Result<HookPreview, String> {
    tauri::async_runtime::spawn_blocking(move || hooks::wsl_preview(&distro, &user, install))
        .await
        .map_err(|e| e.to_string())?
}

/// The plan usage gauge's status line in a distro: the diff to look at first.
#[tauri::command]
async fn wsl_status_line_preview(distro: String, user: String, install: bool) -> Result<HookPreview, String> {
    tauri::async_runtime::spawn_blocking(move || hooks::wsl_status_line_preview(&distro, &user, install))
        .await
        .map_err(|e| e.to_string())?
}

/// Only ever called from an explicit click, and only for the diff that was shown.
#[tauri::command]
async fn wsl_status_line_apply(distro: String, user: String, install: bool, fingerprint: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || hooks::wsl_status_line_write(&distro, &user, install, &fingerprint))
        .await
        .map_err(|e| e.to_string())?
}

/// Only ever called from an explicit click, and only for the diff that was shown.
#[tauri::command]
async fn wsl_hooks_apply(distro: String, user: String, install: bool, fingerprint: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || hooks::wsl_write(&distro, &user, install, &fingerprint))
        .await
        .map_err(|e| e.to_string())?
}

// ── Other agents' hooks and plugins ──────────────────────────────────────────

#[tauri::command]
fn agent_hooks_list() -> Vec<agents::AgentStatus> {
    agents::list()
}

/// The diff the user has to look at before anything is written.
#[tauri::command]
fn agent_hooks_preview(agent: String, install: bool) -> Result<config_file::Plan, String> {
    agents::preview(&agent, install)
}

/// Only ever called from an explicit click in the settings window, with the
/// fingerprint of the preview the user looked at.
#[tauri::command]
fn agent_hooks_apply(agent: String, install: bool, fingerprint: String) -> Result<String, String> {
    let backups = agents::apply(&agent, install, &fingerprint)?;
    let done = if install { "installed" } else { "removed" };
    log::line(format!("agent hooks {done} for {agent}"));
    Ok(backups)
}

// ── Plan usage ────────────────────────────────────────────────────────────────

/// The diff of putting the plan usage relay into (or taking it out of) the
/// status line, before anything is written.
#[tauri::command]
fn status_line_preview(install: bool) -> Result<HookPreview, String> {
    hooks::status_line_preview(install)
}

/// Only ever called from an explicit click in the settings window.
#[tauri::command]
fn status_line_apply(
    app: AppHandle,
    shared: State<Shared>,
    install: bool,
    fingerprint: String,
) -> Result<String, String> {
    let backup = hooks::status_line_write(install, &fingerprint)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.plan_relay_installed = install;
        // As on the Mac: taking the relay out turns the pill off with it.
        if !install {
            current.show_plan_in_notch = false;
        }
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

/// Codex plan usage, asked of the Codex CLI (`codex app-server`) when its pill
/// shows. Off the main thread: it can take a few seconds.
#[tauri::command]
async fn codex_plan_usage() -> Option<serde_json::Value> {
    tauri::async_runtime::spawn_blocking(codex_plan::read).await.ok().flatten()
}

#[tauri::command]
fn approval_decision(app: AppHandle, request_id: String, decision: String) {
    recap::record_decision(&app, &request_id, &decision);
    pipe::answer(&app, &request_id, &decision);
}

/// An option picked on the island for a question Claude Code asked.
#[tauri::command]
fn approval_answer(
    app: AppHandle,
    request_id: String,
    answers: std::collections::HashMap<String, serde_json::Value>,
) {
    // An answered question is not an Allow / Deny: nothing for the recap.
    recap::forget_request(&app, &request_id);
    pipe::answer_question(&app, &request_id, &answers);
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
    recap::forget_request(&app, &request_id);
    pipe::decline(&app, &request_id);
}

// ── Chat, files and secrets ───────────────────────────────────────────────────

/// One chat turn with the provider picked in the chat view. API keys and any
/// file bytes stay on the Rust side.
#[tauri::command]
async fn chat_send(
    app: AppHandle,
    shared: State<'_, Shared>,
    chat: State<'_, Chat>,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let settings = shared.settings.lock().unwrap().clone();
    chat::send(&app, &chat, &settings, query, context).await
}

/// The models a provider offers, for the picker in the chat view. Only asked
/// once the user picked that provider, and only with its key or address.
#[tauri::command]
async fn chat_models(shared: State<'_, Shared>, provider: String) -> Result<Vec<ModelInfo>, String> {
    let settings = shared.settings.lock().unwrap().clone();
    chat::models(&settings, &provider).await
}

/// Settings → Local models → Connect: does the server answer, and with which models?
#[tauri::command]
async fn local_connect(provider: String, url: String) -> Result<local_chat::Connected, String> {
    local_chat::connect(&provider, &url).await
}

/// Stores the custom server's key for the address typed next to it; it is only
/// ever sent to that address.
#[tauri::command]
fn local_set_key(url: String, key: String) -> Result<(), String> {
    local_chat::set_custom_key(&url, &key)
}

#[tauri::command]
fn chat_reset(chat: State<Chat>) {
    chat.reset();
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
fn secret_set(app: AppHandle, key: String, value: String) -> Result<(), String> {
    // Bound to its server's address: only local_set_key may store it.
    if key == local_chat::CUSTOM_KEY {
        return Err("use local_set_key".into());
    }
    let watched = matches!(key.as_str(), "github-token" | "gitlab-token" | "gitlab-url");
    let before = watched.then(|| secrets::get(&key));
    secrets::set(&key, &value)?;
    if key == claude::KEY {
        voice::sync(&app);
    }
    if let Some(before) = before {
        if secrets::get(&key) != before {
            credentials_changed(&app, &key);
        }
    }
    Ok(())
}

#[tauri::command]
fn secret_clear(app: AppHandle, key: String) -> Result<(), String> {
    let had = matches!(key.as_str(), "github-token" | "gitlab-token" | "gitlab-url") && secrets::present(&key);
    secrets::clear(&key)?;
    if key == claude::KEY {
        voice::sync(&app);
    }
    if had {
        credentials_changed(&app, &key);
    }
    Ok(())
}

/// A GitHub or GitLab credential changed: that integration forgets what the
/// old one fetched and starts again.
fn credentials_changed(app: &AppHandle, key: &str) {
    if key == "github-token" {
        integrations::github_token_changed(app);
    } else {
        integrations::gitlab_credentials_changed(app);
    }
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

/// The GitHub card was opened: refetch its `section` ("pulse" or "activity")
/// if it is stale. The pollers still decline while the pill is off or paused.
#[tauri::command]
fn github_refresh(section: String) {
    integrations::github_refresh_if_stale(&section);
}

/// The GitLab card was opened: same as `github_refresh`.
#[tauri::command]
fn gitlab_refresh(section: String) {
    integrations::gitlab_refresh_if_stale(&section);
}

/// Lets the island write to the same log as the Rust side.
#[tauri::command]
fn log_line(message: String) {
    log::line(format!("ui  {message}"));
}

// ── Global shortcuts ──────────────────────────────────────────────────────────

/// How each global shortcut went: registered, taken by another app, and so on.
#[tauri::command]
fn shortcuts_status(app: AppHandle) -> shortcuts::Report {
    shortcuts::status(&app)
}

/// Settings is recording a new combination: let go of ours meanwhile, so the
/// keys reach the recorder instead of running an action. `false` takes them back.
#[tauri::command]
fn shortcuts_suspend(app: AppHandle, shared: State<Shared>, suspended: bool) {
    if suspended {
        shortcuts::suspend(&app);
    } else {
        let stored = shared.settings.lock().unwrap().shortcuts.clone();
        shortcuts::apply(&app, &stored);
    }
}

// ── Settings window ───────────────────────────────────────────────────────────

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

/// The Coucou window (Flow dictation, the Notetaker and every setting of the
/// island), labelled "settings" since it grew out of the settings window.
pub const HUB_LABEL: &str = "settings";

/// The Coucou window is created hidden at launch and only ever shown and
/// hidden afterwards. A WebView2 window created later — on the main thread or
/// not — silently comes up blank in this app, so the window that works is the
/// one that exists before the island's webview does.
fn create_settings_window(app: &AppHandle) {
    let url = settings_page_url(app);
    match WebviewWindowBuilder::new(app, HUB_LABEL, url)
        .additional_browser_args(BROWSER_ARGS)
        .title("Coucou")
        .inner_size(1100.0, 720.0)
        .min_inner_size(820.0, 560.0)
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
        Err(err) => log::line(format!("Coucou window failed: {err}")),
    }
}

pub fn show_settings_window(app: &AppHandle) {
    show_hub(app, Some("general"));
}

/// Shows the Coucou window, on `page` when given ("dictation", "notes",
/// "settings", "general", "shortcuts"…).
pub fn show_hub(app: &AppHandle, page: Option<&str>) {
    let Some(win) = app.get_webview_window(HUB_LABEL) else {
        log::line("Coucou window missing");
        return;
    };
    if let Some(page) = page {
        let _ = win.emit("hub-page", page.to_string());
    }
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
}

/// The argument the login item starts Coucou with.
const AUTOSTART_ARG: &str = "--autostart";

/// Coucou started with the computer, not opened by the user: the window stays hidden.
pub fn launched_at_login() -> bool {
    std::env::args().any(|a| a == AUTOSTART_ARG)
}

#[tauri::command]
fn open_settings_window(app: AppHandle, page: Option<String>) {
    show_hub(&app, Some(page.as_deref().unwrap_or("general")));
}

pub fn run() {
    platform::prepare_environment();
    let loaded = settings::load();
    i18n::set_picked(&loaded.language);
    let gate = Arc::new(PollGate::new());

    let mut builder = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            // `coucou --shortcut <action>`: what a desktop's own keyboard
            // settings run where we can't listen for keys ourselves (Wayland).
            match shortcuts::from_args(&argv) {
                Some(action) => shortcuts::dispatch(app, action),
                // Opening Coucou again (its shortcut, the Start menu) shows its window.
                None => show_hub(app, None),
            }
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, Some(vec![AUTOSTART_ARG])));
    // Where no global shortcut can work, the plugin isn't even started.
    if platform::global_shortcuts_blocked().is_none() {
        builder = builder.plugin(shortcuts::plugin());
    }

    builder
        .manage(Shared {
            settings: Mutex::new(loaded.clone()),
            gate: gate.clone(),
        })
        .manage(Pending::default())
        .manage(Chat::default())
        .manage(shortcuts::Registry::default())
        .manage(recap::load())
        .invoke_handler(tauri::generate_handler![
            boot,
            save_settings,
            set_system_languages,
            set_collapsed,
            set_island_rect,
            focus_window,
            reposition,
            fit_zoom,
            list_monitors,
            open_url,
            open_in_editor,
            editors_status,
            open_session,
            open_claude_desktop,
            open_file_in_editor,
            quit_app,
            hooks_status,
            agent_hooks_status,
            hooks_preview,
            hooks_apply,
            wsl_hooks_list,
            wsl_hooks_preview,
            wsl_hooks_apply,
            wsl_status_line_preview,
            wsl_status_line_apply,
            agent_hooks_list,
            agent_hooks_preview,
            agent_hooks_apply,
            status_line_preview,
            status_line_apply,
            codex_plan_usage,
            approval_decision,
            approval_answer,
            approval_ack,
            approval_decline,
            log_line,
            chat_send,
            chat_models,
            local_connect,
            local_set_key,
            chat_reset,
            ingest_file,
            secret_present,
            secret_set,
            secret_clear,
            refresh_integration,
            github_refresh,
            gitlab_refresh,
            gitlab_panel::gitlab_panel_toggle,
            gitlab_panel::gitlab_panel_close,
            gitlab_panel::gitlab_panel_is_open,
            gitlab_panel::gitlab_panel_is_expanded,
            gitlab_panel::gitlab_panel_mode,
            gitlab_panel::gitlab_panel_resize,
            gitlab_panel::gitlab_dashboard,
            gitlab_panel::gitlab_reply,
            gitlab_panel::gitlab_resolve,
            gitlab_panel::gitlab_snippet,
            open_n8n,
            open_settings_window,
            set_paused,
            shortcuts_status,
            shortcuts_suspend,
            phone_link::phone_link_status,
            phone_link::phone_link_set_enabled,
            phone_link::phone_link_pairing,
            phone_link::phone_link_new_pairing,
            phone_link::phone_link_publish,
            phone_link::phone_link_publish_question,
            phone_link::phone_link_publish_prefs,
            phone_link::phone_answers_status,
            phone_link::phone_answers_set_enabled,
            phone_link::phone_diffs_status,
            phone_link::phone_diffs_set_enabled,
            phone_link::phone_link_send_diff,
            phone_link::phone_usage_status,
            phone_link::phone_usage_set_enabled,
            phone_link::phone_relay_status,
            phone_link::phone_relay_set,
            phone_link::phone_relay_set_access,
            phone_link::phone_link_publish_usage,
            phone_link::phone_services_status,
            phone_link::phone_services_set,
            phone_link::phone_link_publish_services,
            phone_link::phone_details_status,
            phone_link::phone_details_set_enabled,
            phone_link::phone_chat_status,
            phone_link::phone_chat_set_enabled,
            phone_link::phone_chat_set_models,
            recap::recap_history,
            recap::recap_prefs,
            recap::recap_set_enabled,
            recap::recap_set_hide_projects,
            recap::recap_mark_shown,
            recap::recap_clear,
            recap::recap_save_png,
            recap::recap_reveal_saved,
            desktop::desktop_mochi_info,
            desktop::desktop_mochi_pick_up,
            desktop::desktop_mochi_carry,
            desktop::desktop_mochi_carry_end,
            desktop::desktop_mochi_drag_begin,
            desktop::desktop_mochi_drag_move,
            desktop::desktop_mochi_drag_end,
            desktop::desktop_mochi_fly_out,
            desktop::desktop_mochi_fly_home,
            desktop::desktop_mochi_set_asleep,
            sounds::custom_sounds,
            sounds::custom_sound,
            sounds::set_custom_sound,
            sounds::remove_custom_sound,
            sounds::reveal_sounds_folder,
            sounds::reload_sounds,
            spotify::spotify_refresh,
            spotify::spotify_control,
            spotify::spotify_open,
            spotify::spotify_installed,
            flow::flow_status,
            flow::flow_set_prefs,
            flow::flow_history,
            flow::flow_delete,
            flow::flow_clear,
            flow::flow_stats,
            flow::flow_words,
            flow::flow_set_words,
            flow::flow_snippets,
            flow::flow_set_snippets,
            flow::flow_styles,
            flow::flow_set_styles,
            flow::flow_running_apps,
            flow::flow_copy,
            flow::flow_paste_again,
            flow::flow_models_download,
            flow::flow_models_remove,
            flow::pill_state,
            flow::pill_hot,
            flow::pill_hover,
            flow::pill_action,
            notes::notes_state,
            notes::notes_start,
            notes::notes_stop,
            notes::notes_rename,
            notes::notes_rename_speaker,
            notes::notes_toggle_todo,
            notes::notes_delete,
            notes::notes_summarize,
            notes::notes_retry,
            notes::notes_markdown,
            notes::notes_export,
            voice::voice_done,
            voice::voice_say_native,
        ])
        .setup(move |app| {
            let handle = app.handle().clone();
            app.manage(phone_link::PhoneLink::new(handle.clone()));
            tray::build(&handle)?;
            // Before the island: see create_settings_window.
            create_settings_window(&handle);
            // Same rule for Mochi's desktop window and the dictation pill.
            desktop::setup(&handle);
            flow::setup(&handle);
            gitlab_panel::setup(&handle);
            notes::setup(&handle);

            if let Some(win) = island::window(&handle) {
                // Where Tauri takes the drop itself (Linux), its paths are the
                // ones ingest_file may copy (files.rs).
                win.on_window_event(|event| {
                    if let tauri::WindowEvent::DragDrop(tauri::DragDropEvent::Drop { paths, .. }) = event {
                        files::allow_dropped(paths.iter().map(|p| p.to_string_lossy().to_string()));
                    }
                });
                platform::make_non_activating(&win);
                #[cfg(windows)]
                webview_drop::install(&handle);
                island::apply_geometry(&handle, &loaded.screen, false);
                let _ = win.show();
            }
            gate.collapsed.store(false, Ordering::Relaxed);
            // Nothing drawn yet, so nothing takes the mouse until the page
            // reports the island's shape.
            if !platform::CURSOR_POLL {
                island::refresh_click_through(&handle, &gate);
            }
            gate.set_active(true);
            island::spawn_cursor_poll(handle.clone(), gate.clone());

            log::line(format!("--- Coucou {} started ---", env!("CARGO_PKG_VERSION")));
            hooks::ensure_hook_exe(&handle);
            pipe::start(handle.clone());
            phone_link::start_if_enabled(&handle);
            integrations::start(handle.clone());
            gitlab_panel::start(handle.clone());
            spotify::sync(&handle, &loaded.active_integrations);
            shortcuts::apply(&handle, &loaded.shortcuts);
            if loaded.autostart {
                // Login items written before 0.5 start Coucou without --autostart:
                // writing it again adds it, so the window stays hidden at login.
                let _ = handle.autolaunch().enable();
            }
            let open_window = flow::get(&handle).map(|f| f.store.lock().unwrap().prefs.open_at_launch).unwrap_or(true);
            if open_window && !launched_at_login() {
                show_hub(&handle, None);
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building Coucou")
        .run(|app, event| {
            // Withdraw the phone link's announcement on the local network before the process ends.
            if let tauri::RunEvent::Exit = event {
                phone_link::stop_on_exit(app);
                notes::shutdown(app);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::editor_target;

    #[test]
    fn only_an_existing_file_by_its_full_path_reaches_the_editor() {
        let dir = std::env::temp_dir().join(format!("coucou-diff-file-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("edited.ts");
        std::fs::write(&file, "x").unwrap();

        assert!(editor_target(&file.to_string_lossy(), false).is_some());
        // A folder, a missing file, a relative path or an option never pass.
        assert!(editor_target(&dir.to_string_lossy(), false).is_none());
        assert!(editor_target(&dir.join("missing.ts").to_string_lossy(), false).is_none());
        assert!(editor_target("edited.ts", false).is_none());
        assert!(editor_target("--help", false).is_none());
        assert!(editor_target("", false).is_none());

        // The same rule for a folder ("Open terminal"'s fallback): an existing one.
        assert!(editor_target(&dir.to_string_lossy(), true).is_some());
        assert!(editor_target(&file.to_string_lossy(), true).is_none());
        assert!(editor_target(&dir.join("missing").to_string_lossy(), true).is_none());
        assert!(editor_target("--help", true).is_none());

        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Needs a running WSL distro that has the folder and the file below.
    /// Resolves them as "Open terminal" and the diff's ↗ would, without opening
    /// anything. `cargo test -- --ignored`.
    #[cfg(windows)]
    #[test]
    #[ignore = "needs a running WSL distro"]
    fn a_real_wsl_folder_and_file_reach_the_editor() {
        let folder = editor_target("/home/seguineaud/projets/coucou", true).expect("the folder is found");
        println!("folder: {:?}\nargs: {:?}", folder.local, folder.args);
        let file = editor_target("/home/seguineaud/projets/coucou/CHANGELOG.md", false).expect("the file is found");
        println!("file: {:?}\nargs: {:?}", file.local, file.args);
        println!("Remote - WSL installed: {}", crate::wsl::remote_wsl_installed());
        // A file is not a folder, and the other way round; a path nowhere is nothing.
        assert!(editor_target("/home/seguineaud/projets/coucou/CHANGELOG.md", true).is_none());
        assert!(editor_target("/home/seguineaud/projets/coucou", false).is_none());
        assert!(editor_target("/home/seguineaud/nowhere", true).is_none());
    }
}
