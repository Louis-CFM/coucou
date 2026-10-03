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

use crate::platform::{self, cursor_physical, left_button_down};
// The popup check below still needs the raw Win32 calls: it asks whether the window
// under the pointer is one of our own native select menus, which is a Win32-only
// question. Everything else that used to live here moved into `platform`.
#[cfg(windows)]
use windows::Win32::Foundation::POINT;
#[cfg(windows)]
use windows::Win32::UI::WindowsAndMessaging::{GetAncestor, WindowFromPoint, GA_ROOT, GA_ROOTOWNER};

/// Logical size of the full window — the largest island view, like the macOS panel.
pub const PANEL_W: f64 = 720.0;
pub const PANEL_H: f64 = 320.0;
/// Fully reduced resting bar (PR #22's no-notch `hidden` state): a short stub
/// with Mochi parked in the middle. This is what the window shrinks to when the
/// island is hidden, so it must equal `NO_NOTCH_W`/`NO_NOTCH_H` in
/// `src/core/layout.ts`.
pub const HIDDEN_W: f64 = 80.0;
pub const HIDDEN_H: f64 = 24.0;
/// Logical width of the resting (compact) island — what the front end paints as
/// `COMPACT_W` in `src/core/layout.ts`. Rust needs it to centre the island inside
/// the wider window, so the two must stay equal.
pub const COMPACT_W: f64 = 240.0;
/// Logical width of the open panel — `EXPANDED_W` in `src/core/layout.ts`.
pub const EXPANDED_W: f64 = 640.0;

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

fn outside_press(rect: IslandRect, x: f64, y: f64, down: bool, was_down: bool) -> bool {
    down && !was_down && rect.w > 0.0 && rect.h > 0.0
        && !(x >= rect.x && x <= rect.x + rect.w && y >= rect.y && y <= rect.y + rect.h)
}

/// How close a press may land to the island and still count as "near" it, on both
/// sides so left and right are identical by construction.
const NEAR_RADIUS: f64 = 56.0;

/// Whether a press landed within `NEAR_RADIUS` of the island's painted rect.
///
/// Decided here rather than in the front end, which has to rebuild the same rect and
/// guess the coordinate space. Getting that wrong made the near gesture — the
/// double-click wake — fail intermittently, and the two constants drifting apart
/// would silently change which clicks count as near.
fn near_press(rect: IslandRect, x: f64, y: f64) -> bool {
    let dx = (rect.x - x).max(0.0).max(x - (rect.x + rect.w));
    let dy = (rect.y - y).max(0.0).max(y - (rect.y + rect.h));
    dx <= NEAR_RADIUS && dy <= NEAR_RADIUS
}

/// Wakes / parks the cursor poll thread so a hidden island costs literally nothing.
pub struct PollGate {
    active: Mutex<bool>,
    cv: Condvar,
    pub collapsed: AtomicBool,
    pub rect: Mutex<IslandRect>,
    /// Mirrors the window flag so we only call into the OS when it changes.
    ignoring: AtomicBool,
}

impl PollGate {
    pub fn new() -> Self {
        Self {
            active: Mutex::new(false),
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

fn monitor_contains(m: &Monitor, x: f64, y: f64) -> bool {
    let p = m.position();
    let s = m.size();
    x >= p.x as f64
        && x < (p.x + s.width as i32) as f64
        && y >= p.y as f64
        && y < (p.y + s.height as i32) as f64
}

/// The display the island is currently painted on, if it is on one at all.
fn current_monitor(app: &AppHandle, monitors: &[Monitor]) -> Option<Monitor> {
    let win = window(app)?;
    let (pos, size) = (win.outer_position().ok()?, win.outer_size().ok()?);
    // Test the island's own centre: the window is deliberately wider than
    // the bar and overhangs the edge, so its left edge is not a reliable
    // indicator of which display it belongs to.
    let cx = pos.x as i64 + size.width as i64 / 2;
    let cy = pos.y as i64 + size.height as i64 / 2;
    monitors
        .iter()
        .find(|m| monitor_contains(m, cx as f64, cy as f64))
        .cloned()
}

/// The first non-primary display, in the order the OS reports them.
fn secondary_monitor(app: &AppHandle, monitors: &[Monitor]) -> Option<Monitor> {
    let primary = app.primary_monitor().ok().flatten();
    monitors
        .iter()
        .find(|m| primary.as_ref().map(|p| p.name() != m.name()).unwrap_or(true))
        .cloned()
}

/// True while the island is being dragged sideways. The display under the pointer
/// is held steady for the duration, so the bar cannot hop displays mid-drag.
static DRAGGING: AtomicBool = AtomicBool::new(false);

/// Keeps the "holding still" line to one per drag rather than one per placement
/// call, which the drag loop makes far too often to be readable.
static DRAG_LOGGED: AtomicBool = AtomicBool::new(false);

/// Records that a drag has begun or ended. The front end owns that, since it is
/// what starts the drag.
pub fn set_dragging(dragging: bool) {
    DRAGGING.store(dragging, Ordering::Relaxed);
    if !dragging {
        DRAG_LOGGED.store(false, Ordering::Relaxed);
    }
}

/// The display the island lives on.
///
/// All three preferences are resolved from the setting on every placement, so
/// changing the picker takes effect immediately and the island tracks the pointer
/// when that is what was chosen. Keeping a placed island on whatever display it
/// happened to land on made every preference a one-shot that only worked before
/// first placement.
///
/// The one exception is a drag, where the current display is held for the duration;
/// see the "cursor" branch below.
fn target_monitor(app: &AppHandle, pref: &str) -> Option<Monitor> {
    let monitors = app.available_monitors().ok()?;
    if pref == "primary" {
        return app
            .primary_monitor()
            .ok()
            .flatten()
            .or_else(|| current_monitor(app, &monitors))
            .or_else(|| monitors.into_iter().next());
    }
    if pref == "secondary" {
        // A machine with only one monitor has no secondary, so it falls back to the
        // primary rather than leaving the island nowhere to draw.
        return secondary_monitor(app, &monitors)
            .or_else(|| app.primary_monitor().ok().flatten())
            .or_else(|| monitors.into_iter().next());
    }
    if pref == "cursor" {
        // The pointer is read on every placement, so moving the mouse to another
        // display moves the island with it. The one exception is a drag: a bar being
        // dragged sideways takes the pointer with it, so resolving from the pointer
        // mid-drag would hop the island onto the neighbouring display and fight the
        // drag. Holding the current display for the duration keeps the drag on the
        // screen it started on.
        if DRAGGING.load(Ordering::Relaxed) {
            if let Some(m) = current_monitor(app, &monitors) {
                if !DRAG_LOGGED.swap(true, Ordering::Relaxed) {
                    crate::log::line(format!(
                        "[monitor] cursor: holding {:?} for the drag",
                        m.name()
                    ));
                }
                return Some(m);
            }
        }
        if let Some((cx, cy)) = cursor_physical() {
            if let Some(m) = monitors.iter().find(|m| monitor_contains(m, cx, cy)) {
                crate::log::line(format!(
                    "[monitor] cursor: placing on {:?} from the pointer at {},{}",
                    m.name(),
                    cx,
                    cy
                ));
                return Some(m.clone());
            }
            crate::log::line(format!(
                "[monitor] cursor: pointer {},{} is on no known monitor",
                cx, cy
            ));
        } else {
            crate::log::line("[monitor] cursor: GetCursorPos failed");
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

/// Horizontal resting place of the painted island on the target display, in
/// physical pixels from the monitor's left edge.
///
/// `position` is normalised 0..=1. The window is wider than the bar drawn inside
/// it, so the bar's *centre* is what lands on the chosen spot and the window is
/// centred on that point. On Windows the overhang is invisible because the
/// surface is transparent and click-through outside the island rect, so it is
/// safe to let it hang off the display edge.
///
/// The front end offsets the island inside the window by
/// `(window_w - island_w) * position` (see `Island.islandOffsetX`), so a bar
/// resting at an edge opens inward rather than expanding off-screen.
fn island_left(mp: i32, screen_w: u32, window_w: u32, scale: f64, position: f64) -> i32 {
    let _ = scale;
    // Clamped so a saved fraction outside 0..1 (or a NaN from bad JSON) cannot
    // push the island off-screen.
    let position = if position.is_finite() { position.clamp(0.0, 1.0) } else { 0.5 };
    // The whole window slides across the display with the resting position: 0
    // puts it flush left, 1 flush right, 0.5 centred. The front end offsets the
    // island inside the window by `(window_w - island_w) * position`, so the
    // island's on-screen span is `position * (screen_w - island_w)` regardless of
    // the window width. That keeps every island size on-screen at every position,
    // and a bar at an edge opens inward instead of off-screen.
    let span = (screen_w as i32 - window_w as i32).max(0);
    mp + (span as f64 * position).round() as i32
}

/// Places and sizes the window. `collapsed` picks the wake strip instead of the panel.
pub fn apply_geometry(app: &AppHandle, pref: &str, collapsed: bool, position: f64) {
    let Some(win) = window(app) else { return };
    let Some(m) = target_monitor(app, pref) else { return };

    let scale = m.scale_factor();
    let mp = *m.position();
    let ms = *m.size();

    // Hidden shrinks to the fully reduced 80pt stub rather than the old invisible
    // wake strip, so the resting island stays visible and draggable.
    let (lw, lh) = if collapsed { (HIDDEN_W, HIDDEN_H) } else { (PANEL_W, PANEL_H) };
    let pw = (lw * scale).round().max(1.0) as u32;
    let ph = (lh * scale).round().max(1.0) as u32;
let x = island_left(mp.x, ms.width, pw, scale, position);
    let y = mp.y;

    // GTK never sizes a non-resizable window below its natural size (200 px
    // here), so on Linux the 6 px wake strip would stay a 200 px block. tao
    // re-applies the config's `resizable: false` after the first configure, so
    // this is asked every time, just before the resize. Undecorated, the window
    // still offers the user nothing to resize it by. (Found by @YossiYad, #44.)
    #[cfg(target_os = "linux")]
    let _ = win.set_resizable(true);
    let _ = win.set_size(PhysicalSize::new(pw, ph));
    let _ = win.set_position(PhysicalPosition::new(x, y));
    // Moving across displays can rescale the window: re-assert the physical size.
    let _ = win.set_size(PhysicalSize::new(pw, ph));
    let _ = win.set_always_on_top(true);
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
/// visible. Parked on a condvar the rest of the time.
pub fn spawn_cursor_poll(app: AppHandle, gate: Arc<PollGate>) {
    std::thread::spawn(move || {
        // Remembered across wakes so a display change while hidden is noticed the
        // moment the island comes back.
        let mut last_screen: Option<(i32, i32, u32, u32, u64)> = None;
        // Without a cursor to read (Linux) the loop only watches the display
        // layout, and twice a second is plenty for that: waking at 60 Hz just to
        // find no cursor costs CPU for nothing.
        let (period, screen_every) = if platform::CURSOR_POLL { (16, 30) } else { (500, 1) };
        loop {
            gate.wait_until_active();
            let mut was_down = left_button_down();
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
                // Sample button edges before the stationary-cursor fast path. A click
                // outside must dismiss even when the pointer has stopped moving.
                let down = left_button_down();
                let pressed = down && !was_down;
                let r = *gate.rect.lock().unwrap();
                if outside_press(r, x, y, down, was_down) {
                    // Native select popups belong to our window even when their
                    // menu extends beyond the island's painted bounds.
                    let own_popup = win.hwnd().is_ok_and(|hwnd| unsafe {
                        let hit = WindowFromPoint(POINT { x: cx as i32, y: cy as i32 });
                        GetAncestor(hit, GA_ROOT).0 != hwnd.0 as *mut _
                            && GetAncestor(hit, GA_ROOTOWNER).0 == hwnd.0 as *mut _
                    });
                    // The gesture travels with the event: whether the press was near the island or
                    // anywhere else decides which of the two reduced-state clicks it
                    // is, and the front end's own cursor is only refreshed when the
                    // pointer moves, so it used to judge a click after the mouse had
                    // been still against a stale position. That made a desktop click
                    // wake the island at random, and only dragging kept it honest.
                    if !own_popup {
                        // A map, not a tuple: Tauri serialises a tuple as a JSON
                        // array, and the front end destructured this as an object,
                        // so `near` arrived `undefined` on every native click and the
                        // native classification did nothing at all.
                        let _ = win.emit(
                            "outside-click",
                            serde_json::json!({ "near": near_press(r, x, y) }),
                        );
                    }
                }
                was_down = down;
                if pressed {
                    let handle = app.clone();
                    let _ = app.run_on_main_thread(move || platform::unblock_webview_drops(&handle));
                }
                // The island slides sideways while a bar is dragged, so the cursor
                // can end up outside the painted rect mid-gesture. Keep the mouse
                // captured for as long as the button is held anywhere over the
                // panel: a click-through window stops delivering mousemove, and the
                // drag would end the moment the cursor outran the bar.
                let captured = down
                    && x >= 0.0
                    && x <= size.0
                    && y >= 0.0
                    && y <= size.1;

                if !captured && (x - last.0).abs() < 1.0 && (y - last.1).abs() < 1.0 {
                    continue;
                }
                last = (x, y);

                // Click-through: the window only takes the mouse over the island
                // shape. A small entry margin means the flag is already off by the
                // time a moving cursor reaches a button.
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
// While reduced the window is only 80x24, so it always takes the mouse. Relying on
                // the poll's own hit test alone is what #28 is about: this setter goes
                // through the event-loop queue, so a collapse on the main thread and the
                // last poll tick can land in either order and leave the window
                // click-through with nothing left to click on. While collapsed the answer
                // does not depend on ordering at all.
                let accept = on_island
                    || captured
                    || gate.collapsed.load(Ordering::Relaxed);
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
///
/// With the cursor poll (Windows) the window takes the mouse again and the next
/// tick decides from the cursor. Without it (Linux) the input region is set to
/// the island itself, or to the whole wake strip while collapsed.
pub fn refresh_click_through(app: &AppHandle, gate: &PollGate) {
    if platform::CURSOR_POLL {
        set_ignore_cursor(app, false);
        gate.forget_ignore_state();
        return;
    }
    let Some(win) = window(app) else { return };
    let region = if gate.collapsed.load(Ordering::Relaxed) {
        // The wake strip itself, never "the whole window": if the window ever
        // fails to shrink to the strip, the rest of it must not swallow clicks
        // meant for whatever sits under the top of the screen.
        Some((0.0, 0.0, STRIP_W, STRIP_H))
    } else {
        let r = *gate.rect.lock().unwrap();
        if r.w <= 0.0 {
            // Nothing drawn yet: nothing takes the mouse.
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outside_click_is_a_press_edge_outside_the_painted_rect() {
        let rect = IslandRect { x: 50.0, y: 10.0, w: 300.0, h: 150.0 };
        assert!(outside_press(rect, 400.0, 50.0, true, false));
        assert!(!outside_press(rect, 400.0, 50.0, true, true));
        assert!(!outside_press(rect, 400.0, 50.0, false, true));
        assert!(!outside_press(rect, 150.0, 50.0, true, false));
        assert!(!outside_press(rect, 350.0, 160.0, true, false));
        assert!(!outside_press(IslandRect::default(), 400.0, 50.0, true, false));
    }

    // Geometry is pure maths, so it can be checked without a display.
    const SCREEN: u32 = 1920;

    /// On-screen left edge of the island, combining the Rust window placement
    /// with the front end's in-window offset (`Island.islandOffsetX`).
    fn island_x(window_w: u32, island_w: f64, position: f64) -> i32 {
        let window_x = island_left(0, SCREEN, window_w, 1.0, position);
        let offset = ((window_w as f64 - island_w) * clamp(position)).round() as i32;
        window_x + offset
    }

    fn clamp(p: f64) -> f64 {
        if p.is_finite() {
            p.clamp(0.0, 1.0)
        } else {
            0.5
        }
    }

    #[test]
    fn presets_pin_the_bar_to_each_edge() {
        for island_w in [HIDDEN_W, COMPACT_W, EXPANDED_W] {
            let w = island_w as i32;
            assert_eq!(island_x(PANEL_W as u32, island_w, 0.0), 0, "flush left at {island_w}");
            assert_eq!(
                island_x(PANEL_W as u32, island_w, 1.0),
                SCREEN as i32 - w,
                "flush right at {island_w}"
            );
            assert_eq!(
                island_x(PANEL_W as u32, island_w, 0.5),
                (SCREEN as i32 - w) / 2,
                "centred at {island_w}"
            );
        }
    }

    #[test]
    fn bar_stays_on_the_display_at_every_position() {
        for window_w in [PANEL_W as u32, HIDDEN_W as u32] {
            for island_w in [HIDDEN_W, COMPACT_W, EXPANDED_W] {
                for step in 0..=100 {
                    let left = island_x(window_w, island_w, step as f64 / 100.0);
                    let w = island_w as i32;
                    assert!(
                        left >= 0 && left + w <= SCREEN as i32,
                        "position {step}, window {window_w}, island {island_w}: left {left} is off-screen"
                    );
                }
            }
        }
    }

    #[test]
    fn bad_saved_values_cannot_move_the_bar_off_screen() {
        for bad in [f64::NAN, -3.0, 7.0] {
            for island_w in [HIDDEN_W, COMPACT_W, EXPANDED_W] {
                let left = island_x(PANEL_W as u32, island_w, bad);
                assert!(
                    left >= 0 && left + island_w as i32 <= SCREEN as i32,
                    "value {bad} escaped the display at width {island_w}"
                );
            }
        }
    }
}
