// Island window: placement (top centre of the chosen display, or wherever the
// user dragged it — see placement.rs), the two window sizes (full panel /
// invisible wake strip), click-through and the cursor poll.
//
// There is no notch on a PC, so the island is a black shape drawn inside a
// borderless, transparent, always-on-top window that never takes focus.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, WebviewWindow};

use crate::placement::{self, Anchor, Display, Rect};

use crate::platform::{self, cursor_physical, left_button_down};

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

/// Wakes / parks the cursor poll thread so a hidden island costs literally nothing.
pub struct PollGate {
    active: Mutex<bool>,
    cv: Condvar,
    pub collapsed: AtomicBool,
    pub rect: Mutex<IslandRect>,
    /// Mirrors the window flag so we only call into Win32 when it changes.
    ignoring: AtomicBool,
    /// An island drag is under way; the poll saves the spot on mouse-up.
    pub moving: AtomicBool,
}

impl PollGate {
    pub fn new() -> Self {
        Self {
            active: Mutex::new(false),
            cv: Condvar::new(),
            collapsed: AtomicBool::new(true),
            rect: Mutex::new(IslandRect::default()),
            ignoring: AtomicBool::new(false),
            moving: AtomicBool::new(false),
        }
    }

    pub fn set_rect(&self, rect: IslandRect) {
        *self.rect.lock().unwrap() = rect;
    }

    /// Forces the next poll tick to re-apply the flag (after a window resize).
    pub fn forget_ignore_state(&self) {
        self.ignoring.store(false, Ordering::Relaxed);
    }

    pub fn set_active(&self, on: bool) {
        let mut guard = self.active.lock().unwrap();
        *guard = on;
        self.cv.notify_all();
    }

    fn wait_until_active(&self) {
        let mut guard = self.active.lock().unwrap();
        while !*guard {
            guard = self.cv.wait(guard).unwrap();
        }
    }

    fn is_active(&self) -> bool {
        *self.active.lock().unwrap()
    }
}

pub fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(WINDOW_LABEL)
}

pub fn unblock_webview_drops(app: &AppHandle) { platform::unblock_webview_drops(app) }

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

fn display_of(m: &Monitor) -> Display {
    let p = m.position();
    let s = m.size();
    let wa = m.work_area();
    Display {
        bounds: Rect { x: p.x, y: p.y, w: s.width as i32, h: s.height as i32 },
        work: Rect { x: wa.position.x, y: wa.position.y, w: wa.size.width as i32, h: wa.size.height as i32 },
    }
}

fn physical(logical: f64, scale: f64) -> i32 {
    (logical * scale).round().max(1.0) as i32
}

/// Where the island goes right now: the user's saved spot (brought back onto
/// a display that exists), or the top centre of the display `pref` picks.
/// Returns the anchor and the monitor it is on.
fn resolve_anchor(app: &AppHandle, pref: &str, saved: Option<Anchor>) -> Option<(Anchor, Monitor)> {
    let monitors = app.available_monitors().ok()?;
    if let Some(saved) = saved {
        let displays: Vec<Display> = monitors.iter().map(display_of).collect();
        if let Some(i) = placement::display_for(&displays, saved.x, saved.y) {
            let m = &monitors[i];
            let scale = m.scale_factor();
            let anchor = placement::clamp_anchor(
                saved,
                physical(PANEL_W, scale),
                physical(PANEL_H, scale),
                &[displays[i]],
            )?;
            return Some((anchor, m.clone()));
        }
    }
    let m = target_monitor(app, pref)?;
    Some((placement::default_anchor(&display_of(&m)), m))
}

/// Places and sizes the window. `collapsed` picks the wake strip instead of
/// the panel; both hang from the same anchor, so the wake strip is exactly
/// where the island was.
pub fn apply_geometry(app: &AppHandle, pref: &str, saved: Option<Anchor>, collapsed: bool) {
    let Some(win) = window(app) else { return };
    let Some((anchor, m)) = resolve_anchor(app, pref, saved) else { return };

    let scale = m.scale_factor();
    let (lw, lh) = if collapsed { (STRIP_W, STRIP_H) } else { (PANEL_W, PANEL_H) };
    let pw = physical(lw, scale);
    let ph = physical(lh, scale);
    let (x, y) = placement::window_origin(anchor, pw, ph, display_of(&m).work);

    #[cfg(target_os = "linux")]
    let _ = win.set_resizable(true);
    let _ = win.set_size(PhysicalSize::new(pw as u32, ph as u32));
    let _ = win.set_position(PhysicalPosition::new(x, y));
    // Moving across displays can rescale the window: re-assert the physical size.
    let _ = win.set_size(PhysicalSize::new(pw as u32, ph as u32));
    let _ = win.set_always_on_top(true);
    #[cfg(target_os = "linux")]
    let _ = win.set_resizable(false);
    // Flat top against a screen edge (notch), rounded all round elsewhere.
    let _ = app.emit_to(WINDOW_LABEL, "island-placed", y == m.position().y);
}

/// After a drag: the anchor the window now stands for, brought back inside
/// the work area of the display it was dropped on. None when the window is
/// not the full panel (nothing to save).
pub fn anchor_after_drag(app: &AppHandle) -> Option<Anchor> {
    let win = window(app)?;
    let pos = win.outer_position().ok()?;
    let size = win.outer_size().ok()?;
    let monitors = app.available_monitors().ok()?;
    let displays: Vec<Display> = monitors.iter().map(display_of).collect();
    let dropped = placement::anchor_of(pos.x, pos.y, size.width as i32);
    let i = placement::display_for(&displays, dropped.x, dropped.y)?;
    placement::clamp_anchor(dropped, size.width as i32, size.height as i32, &[displays[i]])
}

pub fn make_non_activating(win: &WebviewWindow) { platform::make_non_activating(win) }

pub fn set_activating(win: &WebviewWindow, activating: bool) { platform::set_activating(win, activating) }

/// Every display's position, size, work area and scale. Any change here means
/// the island has to be placed again (a saved spot is re-clamped, not reset).
fn current_screen_key(app: &AppHandle) -> Option<u64> {
    use std::hash::{Hash, Hasher};
    let monitors = app.available_monitors().ok()?;
    if monitors.is_empty() {
        return None;
    }
    let mut h = std::collections::hash_map::DefaultHasher::new();
    for m in &monitors {
        let d = display_of(m);
        (d.bounds.x, d.bounds.y, d.bounds.w, d.bounds.h, d.work.x, d.work.y, d.work.w, d.work.h).hash(&mut h);
        m.scale_factor().to_bits().hash(&mut h);
    }
    if let Some(s) = app.try_state::<crate::Shared>() {
        s.settings.lock().unwrap().screen.hash(&mut h);
    }
    Some(h.finish())
}

/// Emits `cursor` (window-logical coordinates) at ~60 Hz while the island is
/// visible. Parked on a condvar the rest of the time.
pub fn spawn_cursor_poll(app: AppHandle, gate: Arc<PollGate>) {
    std::thread::spawn(move || {
        let mut was_down = false;
        // Remembered across wakes so a display change while hidden is noticed the
        // moment the island comes back.
        let mut last_screen: Option<u64> = None;
        // Without a cursor to read (Linux) the loop only watches the display
        // layout, and twice a second is plenty for that.
        let (period, screen_every) = if platform::CURSOR_POLL { (16, 30) } else { (500, 1) };
        loop {
            gate.wait_until_active();
            let mut last = (f64::MIN, f64::MIN);
            let mut ticks: u32 = 0;
            while gate.is_active() {
                std::thread::sleep(Duration::from_millis(period));

                // Monitors get plugged in, unplugged, rearranged and rescaled, and
                // an island pinned to coordinates that no longer exist is an island
                // nobody can reach. Checked about twice a second — the cursor poll
                // is already running, so this costs one monitor query.
                ticks = ticks.wrapping_add(1);
                if ticks % screen_every == 0 {
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
                // The end of an island drag (unlocked): the window moved under a
                // held button; once it is released the new spot is saved.
                if gate.moving.load(Ordering::Relaxed) && !down {
                    gate.moving.store(false, Ordering::Relaxed);
                    let handle = app.clone();
                    let _ = app.run_on_main_thread(move || crate::island_dragged(&handle));
                }
                if (x - last.0).abs() < 1.0 && (y - last.1).abs() < 1.0 {
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
                // ours before the file arrives.
                if down && !was_down {
                    let handle = app.clone();
                    let _ = app.run_on_main_thread(move || unblock_webview_drops(&handle));
                }
                was_down = down;

                let dragging = down
                    && x >= 0.0
                    && x <= size.0
                    && y >= 0.0
                    && y <= size.1;

                let accept = on_island || dragging;
                if gate.ignoring.load(Ordering::Relaxed) == accept {
                    gate.ignoring.store(!accept, Ordering::Relaxed);
                    let _ = win.set_ignore_cursor_events(!accept);
                }

                let _ = win.emit("cursor", CursorPayload { x, y });
            }
        }
    });
}

/// Re-applies click-through after the window or the island changed shape.
/// Windows lets the cursor poll decide; Linux gives the compositor an input region.
pub fn refresh_click_through(app: &AppHandle, gate: &PollGate) {
    if platform::CURSOR_POLL {
        set_ignore_cursor(app, false);
        gate.forget_ignore_state();
        return;
    }
    let Some(win) = window(app) else { return };
    let region = if gate.collapsed.load(Ordering::Relaxed) {
        Some((0.0, 0.0, STRIP_W, STRIP_H))
    } else {
        let r = *gate.rect.lock().unwrap();
        if r.w <= 0.0 {
            Some((0.0, 0.0, 0.0, 0.0))
        } else {
            let x0 = (r.x - HIT_MARGIN).max(0.0);
            let y0 = (r.y - HIT_MARGIN).max(0.0);
            let x1 = r.x + r.w + HIT_MARGIN;
            let y1 = r.y + r.h + HIT_MARGIN;
            Some((x0, y0, x1 - x0, y1 - y0))
        }
    };
    platform::set_input_region(&win, region);
}

pub fn set_ignore_cursor(app: &AppHandle, ignore: bool) {
    if let Some(win) = window(app) {
        let _ = win.set_ignore_cursor_events(ignore);
    }
}
