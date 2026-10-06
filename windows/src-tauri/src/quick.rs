// The small windows the global hotkeys open: quick chat, quick task, robot.
// Both are created hidden at launch (see create_settings_window in lib.rs for
// why a later WebView2 window comes up blank) and are only shown and hidden
// afterwards. Position and size are remembered by tauri-plugin-window-state.

use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_window_state::{AppHandleExt, StateFlags};

pub const CHAT: &str = "quick-chat";
pub const TASK: &str = "quick-task";
pub const ROBOT: &str = "quick-robot";

pub fn is_quick(label: &str) -> bool {
    [CHAT, TASK, ROBOT].contains(&label)
}

/// What the window-state plugin keeps for the quick windows. VISIBLE is left
/// out on purpose: they always start hidden.
pub const STATE_FLAGS: StateFlags = StateFlags::POSITION.union(StateFlags::SIZE);

fn page_url(app: &AppHandle, page: &str) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path(&format!("/{page}"));
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App(page.into())
}

fn create(app: &AppHandle, label: &str, page: &str, title: &str, size: (f64, f64), min: (f64, f64)) {
    let built = WebviewWindowBuilder::new(app, label, page_url(app, page))
        .additional_browser_args(crate::BROWSER_ARGS)
        .title(title)
        .inner_size(size.0, size.1)
        .min_inner_size(min.0, min.1)
        .decorations(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(true)
        .maximizable(false)
        .minimizable(false)
        .visible(false)
        .center()
        .build();
    match built {
        Ok(win) => {
            let hidden = win.clone();
            win.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    api.prevent_close();
                    let _ = hidden.hide();
                }
            });
        }
        Err(err) => crate::log::line(format!("{label} window failed: {err}")),
    }
}

/// Before the island, like the settings window.
pub fn create_windows(app: &AppHandle) {
    create(app, CHAT, "quick-chat.html", "Chat — Coucou", (420.0, 520.0), (320.0, 300.0));
    create(app, TASK, "quick-task.html", "New task — Coucou", (520.0, 340.0), (420.0, 300.0));
    create(app, ROBOT, "quick-robot.html", "Robot — Coucou", (640.0, 360.0), (480.0, 300.0));
}

pub fn show(app: &AppHandle, label: &str, reason: &str) {
    let Some(win) = app.get_webview_window(label) else {
        crate::log::line(format!("{label} window missing"));
        return;
    };
    let _ = win.unminimize();
    let _ = win.show();
    let _ = win.set_focus();
    let _ = app.emit_to(label, "quick-shown", reason.to_string());
}

pub fn hide(app: &AppHandle, label: &str) {
    if let Some(win) = app.get_webview_window(label) {
        let _ = win.hide();
    }
    // Saved on every hide too, so a crash or a forced update keeps the spot.
    if let Err(err) = app.save_window_state(STATE_FLAGS) {
        crate::log::line(format!("window state: {err}"));
    }
}

/// Hotkey: shown → hide; hidden → show and focus.
pub fn toggle(app: &AppHandle, label: &str) {
    let visible = app
        .get_webview_window(label)
        .and_then(|w| w.is_visible().ok())
        .unwrap_or(false);
    if visible {
        hide(app, label);
    } else {
        show(app, label, "hotkey");
    }
}

/// Voice hotkey: brings up the quick chat and tells it to start (or, when it
/// is already recording, stop and send).
pub fn voice(app: &AppHandle) {
    let visible = app
        .get_webview_window(CHAT)
        .and_then(|w| w.is_visible().ok())
        .unwrap_or(false);
    if !visible {
        show(app, CHAT, "voice");
    }
    let _ = app.emit_to(CHAT, "quick-voice", ());
}
