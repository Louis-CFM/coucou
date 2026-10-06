// Coucou for Windows — app wiring and the commands the island calls.

mod claude;
mod desktop;
mod files;
mod hooks;
mod integrations;
mod island;
mod log;
#[cfg(windows)]
mod media;
mod pi;
mod pipe;
mod platform;
mod secrets;
mod settings;
mod tray;

use std::process::Command;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

use claude::{Chat, ChatContext, ChatReply};
use files::DroppedFile;
use hooks::{HookPreview, HookStatus};
use island::{PollGate, ScreenInfo};
use pi::Pi;
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
fn desktop_mochi_set_enabled(app: AppHandle, shared: State<Shared>, enabled: bool) {
    let mut settings = shared.settings.lock().unwrap().clone();
    settings.desktop_mochi = enabled;
    save_settings(app, shared, settings);
}

#[tauri::command]
fn boot(app: AppHandle, shared: State<Shared>) -> BootInfo {
    let mut settings = shared.settings.lock().unwrap().clone();
    // The real state of ~/.claude/settings.json wins over whatever we stored.
    settings.hooks_installed = hooks::status(&settings.active_agent).installed;
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
    let (screen_changed, autostart_changed, mochi_changed, mochi_size_changed) = {
        let mut current = shared.settings.lock().unwrap();
        let screen_changed = current.screen != settings.screen;
        let autostart_changed = current.autostart != settings.autostart;
        let mochi_changed = current.desktop_mochi != settings.desktop_mochi;
        let mochi_size_changed = current.desktop_mochi_size != settings.desktop_mochi_size;
        *current = settings.clone();
        (
            screen_changed,
            autostart_changed,
            mochi_changed,
            mochi_size_changed,
        )
    };
    if let Err(err) = settings::save(&settings) {
        eprintln!("[coucou] could not save settings: {err}");
    }
    if mochi_size_changed {
        // place() reads the persisted size and keeps the saved position clamped
        // on the current monitor after the panel grows or shrinks.
        desktop::place(&app);
    }
    // Shown or hidden from here rather than from the settings UI, so every save
    // path lands in the same place and cannot forget to do it.
    if mochi_changed {
        crate::log::line(format!(
            "mochi: settings desktop_mochi={}",
            settings.desktop_mochi
        ));
        if settings.desktop_mochi {
            let shown = desktop::desktop_mochi_show(app.clone());
            crate::log::line(format!("mochi: show command returned {shown}"));
        } else {
            desktop::desktop_mochi_hide(app.clone());
            crate::log::line("mochi: hidden by settings".to_string());
        }
    }
    if autostart_changed {
        let manager = app.autolaunch();
        let result = if settings.autostart {
            manager.enable()
        } else {
            manager.disable()
        };
        if let Err(err) = result {
            eprintln!("[coucou] autostart: {err}");
        }
    }
    if screen_changed {
        let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
        island::apply_geometry(&app, &settings.screen, collapsed);
    }
    // Keep the other window in step (island ⇄ settings window).
    let _ = app.emit("settings-changed", settings);
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
}

/// The front end pushes the island shape; Rust decides click-through from it.
#[tauri::command]
fn set_island_rect(app: AppHandle, shared: State<Shared>, x: f64, y: f64, width: f64, height: f64) {
    shared.gate.set_rect(island::IslandRect {
        x,
        y,
        w: width,
        h: height,
    });
    // Without the cursor poll the input region is the click-through: it follows the island.
    if !platform::CURSOR_POLL {
        island::refresh_click_through(&app, &shared.gate);
    }
}

#[tauri::command]
fn focus_window(app: AppHandle, focused: bool) {
    let Some(win) = island::window(&app) else {
        return;
    };
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
}

#[tauri::command]
fn open_url(url: String) {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return;
    }
    platform::open_url(&url);
}

/// Brings the agent's own terminal window forward.
///
/// This is what the island's "open terminal" button wants: the session the agent
/// is already running in, not a new editor window pointed at the same folder. It
/// returns false when there is no terminal window to bring forward, so the caller
/// can fall back to VS Code rather than doing nothing at all.
#[tauri::command]
fn focus_agent_terminal(path: Option<String>) -> bool {
    platform::focus_terminal(path.as_deref())
}

/// "Open terminal" opens the working folder in VS Code when `code` is on PATH,
/// and falls back to the file manager otherwise.
#[tauri::command]
fn open_in_vscode(path: Option<String>) -> bool {
    // No shell anywhere near this. The path is a project folder chosen by
    // whoever is using Claude Code, and a shell would happily read `&`, `^`, `%`
    // or `$` in a folder name as syntax. Finding the launcher ourselves and
    // handing the path over as a separate argument keeps it a path.
    let path = path.filter(|p| !p.is_empty());
    // It arrives in a hook payload: only an existing folder, given by its full
    // path, goes any further. `code` would read `--something` as an option, and
    // xdg-open would launch a file with whatever handles its type.
    if let Some(p) = path.as_deref() {
        let p = std::path::Path::new(p);
        if !(p.is_absolute() && p.is_dir()) {
            return false;
        }
    }
    if let Some(code) = platform::find_on_path("code") {
        let mut cmd = Command::new(code);
        if let Some(p) = path.as_deref() {
            cmd.arg(p);
        }
        if platform::no_console(&mut cmd).spawn().is_ok() {
            return true;
        }
    }
    if let Some(p) = path.as_deref() {
        platform::reveal_folder(p);
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

// ── Agent hooks ───────────────────────────────────────────────────────────────

/// Every agent whose hooks this build can install. `hooks_installed` is the OR
/// of all of them, so the in-island badge stays green as long as one agent is
/// wired up rather than going red when a second one is added.
const AGENTS: [&str; 5] = ["claudeCode", "pi", "copilot", "antigravity", "codex"];

// ── Music pill (Windows Global Media Control) ───────────────────────────────

#[cfg(windows)]
#[tauri::command]
fn media_state() -> Option<media::MediaState> {
    media::probe().ok().flatten()
}

#[cfg(windows)]
#[tauri::command]
fn media_command(cmd: media::MediaCommand) -> Result<bool, String> {
    media::command(cmd)
}

#[tauri::command]
fn hooks_status(shared: State<Shared>, agent: Option<String>) -> HookStatus {
    let agent = agent.unwrap_or_else(|| shared.settings.lock().unwrap().active_agent.clone());
    hooks::status(&agent)
}

/// Returns the diff the user has to look at before anything is written.
#[tauri::command]
fn hooks_preview(
    shared: State<Shared>,
    agent: Option<String>,
    install: bool,
) -> Result<HookPreview, String> {
    let agent = agent.unwrap_or_else(|| shared.settings.lock().unwrap().active_agent.clone());
    hooks::preview(&agent, install)
}

/// Only ever called from an explicit click in the settings window.
#[tauri::command]
fn hooks_apply(
    app: AppHandle,
    shared: State<Shared>,
    agent: Option<String>,
    install: bool,
    fingerprint: String,
) -> Result<String, String> {
    let agent = agent.unwrap_or_else(|| shared.settings.lock().unwrap().active_agent.clone());
    // The fingerprint comes from the preview the user actually looked at, so a
    // settings file that changed in between is refused rather than overwritten.
    let backup = hooks::write(&agent, install, &fingerprint)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.active_agent = agent;
        current.hooks_installed = install || AGENTS.iter().any(|a| hooks::status(a).installed);
        let _ = settings::save(&current);
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(backup)
}

#[tauri::command]
fn approval_decision(app: AppHandle, request_id: String, decision: String, note: Option<String>) {
    pipe::answer(&app, &request_id, &decision, note.as_deref());
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
/// `chat_provider` picks the backend. It is deliberately not a model: Pi is a
/// whole agent with its own tools and sessions, so it gets its own path rather
/// than a name on the Claude model list.
#[tauri::command]
async fn chat_send(
    shared: State<'_, Shared>,
    chat: State<'_, Chat>,
    pi: State<'_, Pi>,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let (provider, model) = {
        let settings = shared.settings.lock().unwrap();
        (settings.chat_provider.clone(), settings.model.clone())
    };

    if provider == "pi" {
        // No fallback to Claude here, on purpose. Quietly answering from a
        // different provider than the one that was chosen would be worse than
        // saying why it could not be done: the user would have no way of telling
        // which model they were actually talking to.
        let first = chat.is_empty();
        let context = context.as_ref().map(context_line);
        return pi
            .send(query, context.as_deref(), first)
            .await
            .map(|reply| ChatReply { text: reply.text });
    }

    claude::send(&chat, &model, query, context).await
}

/// Renders chat context as the leading line Pi reads alongside a first message.
fn context_line(context: &ChatContext) -> String {
    match context {
        ChatContext::File { name, .. } => format!("Context — File: {name}"),
        ChatContext::Window {
            app_name,
            title,
            url,
        } => match url {
            Some(url) => format!("Context — App: {app_name}, Window: {title}, URL: {url}"),
            None => format!("Context — App: {app_name}, Window: {title}"),
        },
    }
}

/// Clears the conversation on both backends.
///
/// The `Result` is required by Tauri rather than chosen: an async command that
/// holds references must return one. Nothing here can actually fail — dropping a
/// process that was never started is not an error.
#[tauri::command]
async fn chat_reset(chat: State<'_, Chat>, pi: State<'_, Pi>) -> Result<(), String> {
    chat.reset();
    // Pi holds the conversation inside its own process, so clearing it has to
    // take that process down as well — otherwise the next turn would carry the
    // old history into a chat the user believes is empty.
    pi.reset().await;
    Ok(())
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
        // The island is always-on-top and sits top-centre, which is exactly
        // where a centred settings window opens. Without this it comes up behind
        // the notch with its title bar unreachable, so the only way to drag it
        // clear is to resize it first. Matching the island's z-order is the fix;
        // the two windows only ever overlap while settings is in front.
        .always_on_top(true)
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
    platform::prepare_environment();
    let loaded = settings::load();
    let gate = Arc::new(PollGate::new());

    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            let _ = app.emit_to(island::WINDOW_LABEL, "tray", "open".to_string());
        }))
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(Shared {
            settings: Mutex::new(loaded.clone()),
            gate: gate.clone(),
        })
        .manage(Pending::default())
        .manage(Chat::default())
        .manage(Pi::new())
        .invoke_handler(tauri::generate_handler![
            boot,
            save_settings,
            set_collapsed,
            set_island_rect,
            focus_window,
            reposition,
            open_url,
            focus_agent_terminal,
            open_in_vscode,
            quit_app,
            hooks_status,
            #[cfg(windows)]
            media_state,
            #[cfg(windows)]
            media_command,
            desktop::desktop_mochi_show,
            desktop::desktop_mochi_hide,
            desktop_mochi_set_enabled,
            desktop::desktop_mochi_drag_start,
            desktop::desktop_mochi_drag_end,
            desktop::desktop_mochi_sync,
            desktop::desktop_mochi_runtime,
            desktop::desktop_mochi_probe,
            hooks_preview,
            hooks_apply,
            approval_decision,
            approval_ack,
            approval_decline,
            log_line,
            chat_send,
            chat_reset,
            ingest_file,
            secret_present,
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
            create_settings_window(&handle);

            // Created here, on the main thread and during setup, hidden - then
            // only shown later. Both halves matter: a WebView2 window built on
            // a background thread comes up blank, and one shown during setup
            // comes up blank too. This is the same shape as the settings
            // window, which is why that one works.
            let mochi_enabled = settings::load().desktop_mochi;
            let mochi = desktop::ensure_window(&handle);
            if mochi_enabled && mochi.is_some() {
                let deferred = handle.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(std::time::Duration::from_millis(1200));
                    desktop::desktop_mochi_show(deferred);
                });
            }

            if let Some(win) = island::window(&handle) {
                platform::make_non_activating(&win);
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

            log::line(format!(
                "--- Coucou {} started ---",
                env!("CARGO_PKG_VERSION")
            ));
            hooks::ensure_hook_exe(&handle);
            pipe::start(handle.clone());
            integrations::start(handle.clone());
            // Windows only: drives the music pill from Global Media Control.
            #[cfg(windows)]
            media::watch(move |state| {
                use tauri::Emitter;
                let _ = handle.emit("media-changed", state);
            });
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Coucou");
}
