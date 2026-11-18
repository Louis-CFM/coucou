// The pill of Flow dictation: a small see-through capsule at the bottom of the
// screen (or on its left or right edge) while dictation is on. It opens into
// Mochi and nine dots while you speak, into a toolbar under the pointer, and
// shows a call being recorded and short messages. Port of FlowPill.swift.
//
// Its window is borderless, transparent, always on top, never takes the
// keyboard, and lets clicks through except where the pill and its bubble are:
// a cursor poll on Windows (like the island), the input region on Linux.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use super::store::Edge;
use crate::platform::{self, DesktopMode};

pub const LABEL: &str = "pill";

/// Window size (logical) along the bottom, and on the sides.
const BOTTOM: (f64, f64) = (520.0, 170.0);
const SIDE: (f64, f64) = (480.0, 320.0);
/// Off-screen spot on Windows while hidden: the webview keeps running, ready.
const PARKED: (i32, i32) = (-32000, -32000);

/// What the pill shows, sent whole to the page on every change.
#[derive(Debug, Clone, Serialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct PillState {
    /// "idle", "listening", "thinking", "locked", "copied", "failed", "pastedAgain".
    pub phase: String,
    pub edge: String,
    /// The dictation key, as the page writes it ("right_ctrl"…).
    pub key: String,
    /// When the call being recorded started (ms since 1970), or none.
    pub note_started_at: Option<u64>,
    pub announcement: Option<Announcement>,
    /// Dictation is on (the resting pill shows).
    pub enabled: bool,
    /// « OK Coucou » is talking with you.
    pub voice: Option<crate::voice::VoiceView>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Announcement {
    pub id: u64,
    /// "mic", "lock", "clipboard", "download", "check", "error".
    pub icon: String,
    pub tint: String,
    pub text: String,
    /// The button's label, if there is one.
    pub action: Option<String>,
    /// What the button does: "openSettings", "openNotes".
    pub action_id: Option<String>,
}

pub struct Pill {
    mode: DesktopMode,
    state: Mutex<PillState>,
    /// Where the page says the pill and its bubble are (window-logical rects).
    hot: Mutex<Vec<(f64, f64, f64, f64)>>,
    shown: AtomicBool,
    /// The pointer is on the pill or its bubble: a message waits for it to leave.
    pub hovered: AtomicBool,
    #[cfg(target_os = "linux")]
    pointer_watch: AtomicBool,
    /// Parks the Windows cursor poll while the pill is hidden.
    poll: (Mutex<bool>, Condvar),
    announce_seq: std::sync::atomic::AtomicU64,
}

impl Pill {
    pub fn state(&self) -> PillState {
        self.state.lock().unwrap().clone()
    }
}

fn page_url(app: &AppHandle) -> WebviewUrl {
    #[cfg(dev)]
    if let Some(mut base) = app.config().build.dev_url.clone() {
        base.set_path("/pill.html");
        return WebviewUrl::External(base);
    }
    let _ = app;
    WebviewUrl::App("pill.html".into())
}

/// Creates the pill's window, hidden. Before the island, for WebView2's sake
/// (see create_settings_window in lib.rs).
pub fn setup(app: &AppHandle) {
    let mut mode = platform::desktop_mode();
    if mode == DesktopMode::Off {
        crate::log::line("flow pill: no way to place it on this desktop");
    } else {
        let park = cfg!(windows);
        let mut builder = WebviewWindowBuilder::new(app, LABEL, page_url(app))
            .additional_browser_args(crate::BROWSER_ARGS)
            .title("Coucou")
            .inner_size(BOTTOM.0, BOTTOM.1)
            .resizable(cfg!(target_os = "linux"))
            .decorations(false)
            .transparent(true)
            .shadow(false)
            .always_on_top(true)
            .skip_taskbar(true)
            .visible_on_all_workspaces(true)
            .focused(false)
            .maximizable(false)
            .minimizable(false)
            .closable(false)
            .disable_drag_drop_handler()
            .focusable(false)
            .visible(park);
        if park {
            builder = builder.position(PARKED.0 as f64, PARKED.1 as f64);
        }
        match builder.build() {
            Ok(win) => {
                // Windows: prepare_pill_window also makes the idle window
                // click-through. Not here for every system: on Linux the
                // window is not realized yet, and tao unwraps its GdkWindow.
                if !platform::prepare_pill_window(&win, mode) {
                    let _ = win.destroy();
                    mode = DesktopMode::Off;
                } else if park {
                    let _ = win.set_position(PhysicalPosition::new(PARKED.0, PARKED.1));
                }
            }
            Err(err) => {
                crate::log::line(format!("flow pill window failed: {err}"));
                mode = DesktopMode::Off;
            }
        }
    }
    let pill = Arc::new(Pill {
        mode,
        state: Mutex::new(PillState { phase: "idle".into(), edge: "bottom".into(), ..Default::default() }),
        hot: Mutex::new(Vec::new()),
        shown: AtomicBool::new(false),
        hovered: AtomicBool::new(false),
        #[cfg(target_os = "linux")]
        pointer_watch: AtomicBool::new(false),
        poll: (Mutex::new(false), Condvar::new()),
        announce_seq: std::sync::atomic::AtomicU64::new(1),
    });
    app.manage(pill.clone());
    show(app, &pill, false);
    if mode == DesktopMode::Poll {
        spawn_poll(app.clone(), pill);
    }
}

/// A dictation is under way: the microphone is Flow's.
pub fn dictating(app: &AppHandle) -> bool {
    get(app).is_some_and(|p| matches!(p.state.lock().unwrap().phase.as_str(), "listening" | "locked" | "thinking"))
}

pub fn get(app: &AppHandle) -> Option<Arc<Pill>> {
    app.try_state::<Arc<Pill>>().map(|s| s.inner().clone())
}

/// WebKitGTK can miss pointerleave when the window's input region changes.
/// Check GTK's pointer focus while hovered, as the island does, and park the
/// timer as soon as the page folds the toolbar or the pill is hidden.
#[cfg(target_os = "linux")]
pub fn watch_pointer_leave(app: &AppHandle) {
    use gtk::prelude::*;

    let Some(pill) = get(app) else { return };
    if pill.pointer_watch.swap(true, Ordering::Relaxed) {
        return;
    }
    let app_for_watch = app.clone();
    let watched = pill.clone();
    if app.run_on_main_thread(move || {
        let Some(win) = window(&app_for_watch) else {
            watched.pointer_watch.store(false, Ordering::Relaxed);
            return;
        };
        let Ok(gw) = win.gtk_window() else {
            watched.pointer_watch.store(false, Ordering::Relaxed);
            return;
        };
        gtk::glib::timeout_add_local(Duration::from_millis(100), move || {
            if !watched.shown.load(Ordering::Relaxed)
                || !watched.hovered.load(Ordering::Relaxed)
                || !gw.is_visible()
            {
                watched.pointer_watch.store(false, Ordering::Relaxed);
                return gtk::glib::ControlFlow::Break;
            }
            if let (Some(ours), Some(pointer)) = (
                gw.window(),
                gtk::gdk::Display::default().and_then(|d| d.default_seat()).and_then(|s| s.pointer()),
            ) {
                let (under, _, _) = pointer.window_at_position();
                if !under.is_some_and(|w| w.toplevel() == ours.toplevel()) {
                    let _ = win.emit("pill-pointer", false);
                }
            }
            gtk::glib::ControlFlow::Continue
        });
    }).is_err() {
        pill.pointer_watch.store(false, Ordering::Relaxed);
    }
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(LABEL)
}

fn size_for(edge: &str) -> (f64, f64) {
    if edge == "left" || edge == "right" {
        SIDE
    } else {
        BOTTOM
    }
}

pub fn edge_name(edge: Edge) -> &'static str {
    match edge {
        Edge::Bottom => "bottom",
        Edge::BottomLeft => "bottom-left",
        Edge::BottomRight => "bottom-right",
        Edge::Left => "left",
        Edge::Right => "right",
    }
}

/// Changes what the pill shows, and shows or hides it.
pub fn update(app: &AppHandle, change: impl FnOnce(&mut PillState)) {
    let Some(pill) = get(app) else { return };
    let (state, edge_changed) = {
        let mut s = pill.state.lock().unwrap();
        let edge_before = s.edge.clone();
        change(&mut s);
        (s.clone(), s.edge != edge_before)
    };
    let _ = app.emit_to(LABEL, "pill-state", &state);
    let visible = state.enabled || state.note_started_at.is_some() || state.announcement.is_some() || state.voice.is_some() || state.phase != "idle";
    let was = pill.shown.swap(visible, Ordering::Relaxed);
    if visible && (!was || edge_changed) {
        place(app, &pill, &state.edge, state.phase == "listening");
    }
    if visible != was {
        show(app, &pill, visible);
    }
}

fn show(app: &AppHandle, pill: &Pill, visible: bool) {
    let Some(win) = window(app) else { return };
    match pill.mode {
        DesktopMode::Poll => {
            if !visible {
                let _ = win.set_position(PhysicalPosition::new(PARKED.0, PARKED.1));
                let _ = win.set_ignore_cursor_events(true);
            }
            let (lock, cv) = &pill.poll;
            *lock.lock().unwrap() = visible;
            cv.notify_all();
        }
        DesktopMode::Window | DesktopMode::Layer => {
            let w = win.clone();
            let _ = app.run_on_main_thread(move || {
                if visible {
                    let _ = w.show();
                    let _ = w.set_always_on_top(true);
                } else {
                    let _ = w.hide();
                }
            });
        }
        DesktopMode::Off => {}
    }
    let _ = app.emit_to(LABEL, "pill-visible", visible);
}

/// The display to sit on: the one under the cursor when you speak, else the
/// primary one.
fn monitor(app: &AppHandle, on_cursor: bool) -> Option<tauri::Monitor> {
    if on_cursor {
        if let Some((cx, cy)) = platform::cursor_physical() {
            if let Ok(list) = app.available_monitors() {
                if let Some(m) = list.into_iter().find(|m| {
                    let (p, s) = (m.position(), m.size());
                    cx >= p.x as f64 && cx < (p.x + s.width as i32) as f64 && cy >= p.y as f64 && cy < (p.y + s.height as i32) as f64
                }) {
                    return Some(m);
                }
            }
        }
    }
    app.primary_monitor().ok().flatten()
}

fn place(app: &AppHandle, pill: &Pill, edge: &str, on_cursor: bool) {
    let Some(win) = window(app) else { return };
    let (lw, lh) = size_for(edge);
    match pill.mode {
        DesktopMode::Poll | DesktopMode::Window => {
            let Some(m) = monitor(app, on_cursor) else { return };
            let scale = m.scale_factor();
            let wa = m.work_area();
            let (pw, ph) = ((lw * scale).round() as i32, (lh * scale).round() as i32);
            let (ax, ay, aw, ah) = (wa.position.x, wa.position.y, wa.size.width as i32, wa.size.height as i32);
            let gap = (4.0 * scale).round() as i32;
            let (x, y) = match edge {
                "left" => (ax + gap, ay + (ah - ph) / 2),
                "right" => (ax + aw - pw - gap, ay + (ah - ph) / 2),
                "bottom-left" => (ax + gap, ay + ah - ph - gap),
                "bottom-right" => (ax + aw - pw - gap, ay + ah - ph - gap),
                _ => (ax + (aw - pw) / 2, ay + ah - ph - gap),
            };
            #[cfg(target_os = "linux")]
            let _ = win.set_resizable(true);
            let _ = win.set_size(PhysicalSize::new(pw as u32, ph as u32));
            let _ = win.set_position(PhysicalPosition::new(x, y));
        }
        DesktopMode::Layer => {
            let edge = edge.to_string();
            let w = win.clone();
            let _ = app.run_on_main_thread(move || {
                platform::set_pill_edge(&w, &edge);
                let _ = w.set_size(tauri::LogicalSize::new(lw, lh));
            });
        }
        DesktopMode::Off => {}
    }
}

/// The page tells where the pill and its bubble are, in window-logical pixels.
pub fn set_hot(app: &AppHandle, rects: Vec<(f64, f64, f64, f64)>) {
    let Some(pill) = get(app) else { return };
    *pill.hot.lock().unwrap() = rects.clone();
    if pill.mode != DesktopMode::Poll {
        if let Some(win) = window(app) {
            let _ = app.run_on_main_thread(move || platform::set_pill_input(&win, rects));
        }
    }
}

/// Windows: ~30 times a second while the pill shows, the window takes the
/// mouse only over the pill and its bubble.
fn spawn_poll(app: AppHandle, pill: Arc<Pill>) {
    std::thread::spawn(move || {
        let mut ignoring: Option<bool> = Some(true);
        loop {
            {
                let (lock, cv) = &pill.poll;
                let mut on = lock.lock().unwrap();
                while !*on {
                    if ignoring != Some(true) {
                        ignoring = Some(true);
                        if let Some(win) = window(&app) {
                            let _ = win.set_ignore_cursor_events(true);
                        }
                    }
                    on = cv.wait(on).unwrap();
                }
            }
            std::thread::sleep(Duration::from_millis(33));
            let Some(win) = window(&app) else { continue };
            let (Ok(origin), Some((cx, cy))) = (win.outer_position(), platform::cursor_physical()) else { continue };
            let scale = win.scale_factor().unwrap_or(1.0);
            let (x, y) = ((cx - origin.x as f64) / scale, (cy - origin.y as f64) / scale);
            let over = pill.hot.lock().unwrap().iter().any(|&(rx, ry, rw, rh)| x >= rx && x <= rx + rw && y >= ry && y <= ry + rh);
            if ignoring != Some(!over) {
                ignoring = Some(!over);
                let _ = win.set_ignore_cursor_events(!over);
                let _ = win.emit("pill-pointer", over);
            }
        }
    });
}

/// A message next to the pill, with a button to act; it goes away by itself
/// after a while unless the pointer is on it (the page keeps it then).
pub fn announce(app: &AppHandle, icon: &str, tint: &str, text: String, action: Option<(String, &str)>, seconds: u64) {
    let Some(pill) = get(app) else { return };
    let id = pill.announce_seq.fetch_add(1, Ordering::Relaxed);
    let (label, action_id) = match action {
        Some((label, id)) => (Some(label), Some(id.to_string())),
        None => (None, None),
    };
    let a = Announcement { id, icon: icon.into(), tint: tint.into(), text, action: label, action_id };
    update(app, |s| s.announcement = Some(a));
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(seconds));
        while get(&app).is_some_and(|p| p.hovered.load(Ordering::Relaxed)) {
            std::thread::sleep(Duration::from_secs(1));
        }
        dismiss(&app, id);
    });
}

/// Takes a message away (its ✕, its button, or its time ran out). The page
/// asks again later while the pointer rests on it.
pub fn dismiss(app: &AppHandle, id: u64) {
    update(app, |s| {
        if s.announcement.as_ref().is_some_and(|a| a.id == id) {
            s.announcement = None;
        }
    });
}

/// Back to rest after a short message.
pub fn rest_after(app: &AppHandle, phase: &str, ms: u64) {
    let app = app.clone();
    let phase = phase.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(ms));
        update(&app, |s| {
            if s.phase == phase {
                s.phase = "idle".into();
            }
        });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn edge_names_and_sizes_match_expected() {
        assert_eq!(edge_name(Edge::Bottom), "bottom");
        assert_eq!(edge_name(Edge::BottomLeft), "bottom-left");
        assert_eq!(edge_name(Edge::BottomRight), "bottom-right");
        assert_eq!(edge_name(Edge::Left), "left");
        assert_eq!(edge_name(Edge::Right), "right");

        assert_eq!(size_for("bottom"), BOTTOM);
        assert_eq!(size_for("bottom-left"), BOTTOM);
        assert_eq!(size_for("bottom-right"), BOTTOM);
        assert_eq!(size_for("left"), SIDE);
        assert_eq!(size_for("right"), SIDE);
    }
}
