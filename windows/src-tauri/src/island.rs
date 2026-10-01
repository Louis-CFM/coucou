// Island window: placement on the chosen display, the two window sizes
// (full panel / invisible wake strip), click-through and the cursor poll.
//
// There is no notch on a PC, so the island is a black shape drawn at the top
// centre of the main display inside a borderless, transparent, always-on-top
// window that never takes focus.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewWindow};

use windows::Win32::Foundation::{HWND, POINT};
use windows::core::BOOL;
use windows::Win32::Foundation::LPARAM;
use windows::Win32::System::Ole::RevokeDragDrop;
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
use windows::Win32::UI::WindowsAndMessaging::{EnumChildWindows, GetClassNameW};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetWindowLongPtrW, SetWindowLongPtrW, GWL_EXSTYLE, WS_EX_NOACTIVATE,
    WS_EX_TOOLWINDOW,
};

/// Logical size of the full window — the largest island view, like the macOS panel.
pub const PANEL_W: f64 = 720.0;
pub const PANEL_H: f64 = 320.0;
/// Logical size of the invisible strip that wakes the island when it is hidden.
pub const STRIP_W: f64 = 240.0;
pub const STRIP_H: f64 = 6.0;

pub const WINDOW_LABEL: &str = "island";

/// Margin around the island that still counts as "on the island", in logical px.
/// Wider than the macOS 6 pt because a click must never be swallowed.
const HIT_MARGIN: f64 = 14.0;

#[derive(Serialize, Clone)]
pub struct CursorPayload {
    pub x: f64,
    pub y: f64,
    /// True while the left mouse button is held. Lets the island tell a click
    /// on Mochi apart from the start of a drag-out (window attach).
    pub down: bool,
}

#[derive(Serialize, Clone)]
pub struct ScreenInfo {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub scale: f64,
}

/// The island shape in window-logical coordinates, pushed by the front end.
/// The poll thread owns the click-through decision so it lands in the same 16 ms
/// tick as the cursor read — an IPC round trip here loses clicks.
#[derive(Clone, Copy, Default)]
pub struct IslandRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// Wakes / parks the cursor poll thread. Full speed (60 Hz + cursor events)
/// while visible; when collapsed the thread drops to a 5 Hz watch that only
/// keeps the wake strip droppable — a hidden island must cost ~nothing, but a
/// file drag arriving at the strip has to find a live drop target instead of
/// the "prohibited" cursor.
pub struct PollGate {
    active: Mutex<bool>,
    slow: AtomicBool,
    cv: Condvar,
    pub collapsed: AtomicBool,
    pub rect: Mutex<IslandRect>,
    /// Mirrors the window flag so we only call into Win32 when it changes.
    ignoring: AtomicBool,
}

impl PollGate {
    pub fn new() -> Self {
        Self {
            active: Mutex::new(false),
            slow: AtomicBool::new(false),
            cv: Condvar::new(),
            collapsed: AtomicBool::new(true),
            rect: Mutex::new(IslandRect::default()),
            ignoring: AtomicBool::new(false),
        }
    }

    pub fn set_rect(&self, rect: IslandRect) {
        *self.rect.lock().unwrap() = rect;
    }

    /// Forces the next poll tick to re-apply the flag (after a window resize).
    pub fn forget_ignore_state(&self) {
        self.ignoring.store(false, Ordering::Relaxed);
    }

    /// Expanded island → full poll; collapsed → slow strip watch.
    pub fn set_collapsed(&self, collapsed: bool) {
        {
            let mut guard = self.active.lock().unwrap();
            *guard = !collapsed;
        }
        self.slow.store(collapsed, Ordering::Relaxed);
        self.cv.notify_all();
    }

    fn wait_until_enabled(&self) {
        let guard = self.active.lock().unwrap();
        let mut guard = guard;
        while !*guard && !self.slow.load(Ordering::Relaxed) {
            guard = self.cv.wait(guard).unwrap();
        }
    }

    fn is_active(&self) -> bool {
        *self.active.lock().unwrap()
    }

    fn is_enabled(&self) -> bool {
        *self.active.lock().unwrap() || self.slow.load(Ordering::Relaxed)
    }
}

pub fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(WINDOW_LABEL)
}

fn cursor_physical() -> Option<(f64, f64)> {
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p).ok()? };
    Some((p.x as f64, p.y as f64))
}

/// Lets dropped files reach the app again.
///
/// wry installs its drop target by walking the webview's child windows **once**,
/// when the webview is created. WebView2 creates render widgets later —
/// possibly nested several levels deep — and registers its own targets on
/// them; being the innermost windows, those win, and since the page has no
/// HTML5 drop handler it refuses everything — the "no drop" cursor, with
/// nothing reaching Tauri. Revoking every Chromium render widget in the whole
/// subtree makes OLE fall through to the target wry registered on the parent
/// widget, which is the one that feeds Tauri's drag events.
///
/// WebView2 may re-register its targets later (it owns those child windows),
/// which is exactly the "first drop works, later drops refuse" failure mode:
/// the revoke is refreshed throughout a drag, not trusted once. Cheap and
/// idempotent.
pub fn unblock_webview_drops(app: &AppHandle) {
    for label in [WINDOW_LABEL, "settings"] {
        let Some(win) = app.get_webview_window(label) else { continue };
        let Some(hwnd) = hwnd_of(&win) else { continue };
        let mut ctx = UnblockCtx::default();
        unsafe {
            let _ = EnumChildWindows(
                Some(hwnd),
                Some(walk_children),
                LPARAM(&mut ctx as *mut UnblockCtx as isize),
            );
        }
        if ctx.total > 0 {
            let mut classes = ctx.classes.clone();
            classes.sort();
            classes.dedup();
            let shown = classes.iter().take(8).cloned().collect::<Vec<_>>().join(",");
            crate::log::line(format!(
                "unblock {label}: descendants={} render_widgets={} revoked={} failed={} classes=[{shown}]",
                ctx.total, ctx.matched, ctx.revoked, ctx.failed,
            ));
        }
    }
}

#[derive(Default)]
struct UnblockCtx {
    total: u32,
    matched: u32,
    revoked: u32,
    failed: u32,
    classes: Vec<String>,
}

unsafe extern "system" fn walk_children(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let ctx = unsafe { &mut *(lparam.0 as *mut UnblockCtx) };
    let mut name = [0u16; 64];
    let len = unsafe { GetClassNameW(hwnd, &mut name) };
    if len > 0 {
        let class = String::from_utf16_lossy(&name[..len as usize]);
        ctx.total += 1;
        if ctx.classes.len() < 16 {
            ctx.classes.push(class.clone());
        }
        // Any Chromium render widget eats drops; class names gain suffixes
        // across WebView2 releases, so match by prefix — at ANY depth, not
        // just direct children.
        if class.starts_with("Chrome_RenderWidgetHostHWND") {
            ctx.matched += 1;
            if unsafe { RevokeDragDrop(hwnd) }.is_ok() {
                ctx.revoked += 1;
            } else {
                ctx.failed += 1;
            }
        }
    }
    // Recurse: the render widget is usually a grandchild, not a direct child.
    unsafe {
        let _ = EnumChildWindows(Some(hwnd), Some(walk_children), lparam);
    }
    true.into()
}

/// True while the left mouse button is held — the only signal we get that a
/// drag might be in flight before it reaches the window.
fn left_button_down() -> bool {
    unsafe { (GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000) != 0 }
}

fn monitor_contains(m: &Monitor, x: f64, y: f64) -> bool {
    let p = m.position();
    let s = m.size();
    x >= p.x as f64
        && x < (p.x + s.width as i32) as f64
        && y >= p.y as f64
        && y < (p.y + s.height as i32) as f64
}

/// The display the island lives on: the primary one, or the one under the cursor.
fn target_monitor(app: &AppHandle, pref: &str) -> Option<Monitor> {
    let monitors = app.available_monitors().ok()?;
    if pref == "cursor" {
        if let Some((cx, cy)) = cursor_physical() {
            if let Some(m) = monitors.iter().find(|m| monitor_contains(m, cx, cy)) {
                return Some(m.clone());
            }
        }
    }
    app.primary_monitor()
        .ok()
        .flatten()
        .or_else(|| monitors.into_iter().next())
}

pub fn screen_info(app: &AppHandle, pref: &str) -> ScreenInfo {
    match target_monitor(app, pref) {
        Some(m) => {
            let scale = m.scale_factor();
            let p = m.position();
            let s = m.size();
            ScreenInfo {
                x: p.x as f64 / scale,
                y: p.y as f64 / scale,
                width: s.width as f64 / scale,
                height: s.height as f64 / scale,
                scale,
            }
        }
        None => ScreenInfo { x: 0.0, y: 0.0, width: 1920.0, height: 1080.0, scale: 1.0 },
    }
}

/// Places and sizes the window. `collapsed` picks the wake strip instead of the panel.
pub fn apply_geometry(app: &AppHandle, pref: &str, collapsed: bool) {
    let Some(win) = window(app) else { return };
    let Some(m) = target_monitor(app, pref) else { return };

    let scale = m.scale_factor();
    let mp = *m.position();
    let ms = *m.size();

    let (lw, lh) = if collapsed { (STRIP_W, STRIP_H) } else { (PANEL_W, PANEL_H) };
    let pw = (lw * scale).round().max(1.0) as u32;
    let ph = (lh * scale).round().max(1.0) as u32;
    let x = mp.x + (ms.width as i32 - pw as i32) / 2;
    let y = mp.y;

    let _ = win.set_size(PhysicalSize::new(pw, ph));
    let _ = win.set_position(PhysicalPosition::new(x, y));
    // Moving across displays can rescale the window: re-assert the physical size.
    let _ = win.set_size(PhysicalSize::new(pw, ph));
    let _ = win.set_always_on_top(true);
}

fn hwnd_of(win: &WebviewWindow) -> Option<HWND> {
    let raw = win.hwnd().ok()?.0 as isize;
    if raw == 0 {
        return None;
    }
    Some(HWND(raw as *mut _))
}

/// WS_EX_NOACTIVATE keeps clicks from stealing focus; WS_EX_TOOLWINDOW keeps the
/// island out of Alt-Tab.
pub fn make_non_activating(win: &WebviewWindow) {
    let Some(hwnd) = hwnd_of(win) else { return };
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let want = ex | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize;
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
    }
}

/// Temporarily allow activation so a text field inside the island can be typed in.
pub fn set_activating(win: &WebviewWindow, activating: bool) {
    let Some(hwnd) = hwnd_of(win) else { return };
    unsafe {
        let ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
        let want = if activating {
            ex & !(WS_EX_NOACTIVATE.0 as isize)
        } else {
            ex | WS_EX_NOACTIVATE.0 as isize
        };
        SetWindowLongPtrW(hwnd, GWL_EXSTYLE, want);
    }
}

/// Position, size and scale of the monitor the island lives on. Any change here
/// means the island has to be placed again.
fn current_screen_key(app: &AppHandle) -> Option<(i32, i32, u32, u32, u64)> {
    let pref = app
        .try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().screen.clone())
        .unwrap_or_else(|| "primary".into());
    let m = target_monitor(app, &pref)?;
    let p = m.position();
    let size = m.size();
    Some((p.x, p.y, size.width, size.height, m.scale_factor().to_bits()))
}

/// Emits `cursor` (window-logical coordinates) at ~60 Hz while the island is
/// visible. Collapsed, it drops to a 5 Hz strip watch (no events, just the
/// drop target + click-through flag) so a file drag can land on the hidden
/// island instead of meeting the "prohibited" cursor.
pub fn spawn_cursor_poll(app: AppHandle, gate: Arc<PollGate>) {
    std::thread::spawn(move || {
        let mut was_down = false;
        // Last unblock while a button is held inside the window: WebView2 may
        // re-register its inner drop target mid-drag, so the revoke is
        // refreshed instead of trusted once.
        let mut last_unblock = std::time::Instant::now()
            .checked_sub(std::time::Duration::from_secs(10))
            .unwrap_or_else(std::time::Instant::now);
        // Remembered across wakes so a display change while hidden is noticed the
        // moment the island comes back.
        let mut last_screen: Option<(i32, i32, u32, u32, u64)> = None;
        loop {
            gate.wait_until_enabled();
            let mut last = (f64::MIN, f64::MIN);
            let mut ticks: u32 = 0;
            while gate.is_enabled() {
                let slow = !gate.is_active();
                std::thread::sleep(Duration::from_millis(if slow { 200 } else { 16 }));

                // Monitors get plugged in, unplugged, rearranged and rescaled, and
                // an island pinned to coordinates that no longer exist is an island
                // nobody can reach. Checked about twice a second — the cursor poll
                // is already running, so this costs one monitor query.
                ticks = ticks.wrapping_add(1);
                if ticks % 30 == 0 {
                    let now = current_screen_key(&app);
                    if now.is_some() && now != last_screen {
                        let first = last_screen.is_none();
                        last_screen = now;
                        if !first {
                            crate::log::line("display layout changed — repositioning".to_string());
                            let _ = app.emit_to(WINDOW_LABEL, "screen-changed", ());
                        }
                    }
                }

                let Some(win) = window(&app) else { continue };
                let Ok(origin) = win.outer_position() else { continue };
                let scale = win.scale_factor().unwrap_or(1.0);
                let Some((cx, cy)) = cursor_physical() else { continue };
                let x = (cx - origin.x as f64) / scale;
                let y = (cy - origin.y as f64) / scale;
                let size = match win.inner_size() {
                    Ok(s) => (s.width as f64 / scale, s.height as f64 / scale),
                    Err(_) => (PANEL_W, PANEL_H),
                };

                let down = left_button_down();
                // Button released anywhere (usually outside our window, at the
                // end of a Mochi drag-out): the page never sees a DOM mouseup
                // out there, so the release is delivered as an event even when
                // the cursor itself did not move.
                if was_down && !down {
                    let _ = win.emit("mouse-up", CursorPayload { x, y, down });
                }

                if slow {
                    // Strip watch: the collapsed window is a 240×6 target that
                    // must take the mouse and own its drop target, or file
                    // drags die on it with the "prohibited" cursor. No cursor
                    // events down here — the DOM wake strip handles hover.
                    let in_window =
                        x >= 0.0 && x <= size.0 && y >= 0.0 && y <= size.1;
                    if down && in_window {
                        if gate.ignoring.load(Ordering::Relaxed) {
                            gate.ignoring.store(false, Ordering::Relaxed);
                            let _ = win.set_ignore_cursor_events(false);
                        }
                        if last_unblock.elapsed() >= std::time::Duration::from_secs(2) {
                            last_unblock = std::time::Instant::now();
                            let handle = app.clone();
                            let _ = app.run_on_main_thread(move || {
                                unblock_webview_drops(&handle)
                            });
                        }
                    }
                    was_down = down;
                    continue;
                }

                if (x - last.0).abs() < 1.0 && (y - last.1).abs() < 1.0 {
                    was_down = down;
                    continue;
                }
                last = (x, y);

                // Click-through: the window only takes the mouse over the island
                // shape. A small entry margin means the flag is already off by the
                // time a moving cursor reaches a button.
                let r = *gate.rect.lock().unwrap();
                let on_island = r.w > 0.0
                    && x >= r.x - HIT_MARGIN
                    && x <= r.x + r.w + HIT_MARGIN
                    && y >= r.y - HIT_MARGIN
                    && y <= r.y + r.h + HIT_MARGIN;

                // A file being dragged has to be able to find us. WS_EX_TRANSPARENT
                // — what click-through is on Windows — hides the window from
                // WindowFromPoint, so OLE finds no drop target and shows the "no
                // drop" cursor. macOS has no such problem: AppKit delivers drags to
                // registered destinations whatever ignoresMouseEvents says. So while
                // a button is held anywhere over the panel, the whole panel takes
                // the mouse, which also makes the drop zone as forgiving as the Mac's.
                // A press may be the start of a drag: make sure the drop target is
                // ours before the file arrives. (`down` was read above, before
                // the movement check, so a press without movement still lands.)
                // While the button stays held inside the window a file drag may
                // be in flight: refresh the revoke every ~500 ms in case
                // WebView2 re-registered its inner target since the edge.
                let in_window = x >= 0.0 && x <= size.0 && y >= 0.0 && y <= size.1;
                if down && in_window
                    && (!was_down
                        || last_unblock.elapsed() >= std::time::Duration::from_millis(500))
                {
                    last_unblock = std::time::Instant::now();
                    let handle = app.clone();
                    let _ = app.run_on_main_thread(move || unblock_webview_drops(&handle));
                }
                was_down = down;

                let dragging = down && in_window;

                let accept = on_island || dragging;
                if gate.ignoring.load(Ordering::Relaxed) == accept {
                    gate.ignoring.store(!accept, Ordering::Relaxed);
                    if down {
                        crate::log::line(format!(
                            "drop target take (on_island={on_island} dragging={dragging})"
                        ));
                    }
                    let _ = win.set_ignore_cursor_events(!accept);
                }

                let _ = win.emit("cursor", CursorPayload { x, y, down });
            }
        }
    });
}

pub fn set_ignore_cursor(app: &AppHandle, ignore: bool) {
    if let Some(win) = window(app) {
        let _ = win.set_ignore_cursor_events(ignore);
    }
}
