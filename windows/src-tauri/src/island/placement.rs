// The island placed by hand (Windows): where it is, how the cursor carries it, what is kept of it.
//
// The anchor is the window's top-centre point (physical pixels of the virtual desktop). The spot is
// saved in LOGICAL pixels from the corner of its display.
//
// Never hold the `drag` lock or the `settings` lock across a window or monitor call: Tauri's getters
// go through the main thread, which may be waiting for that very lock.

use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Mutex;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, Monitor, PhysicalPosition, PhysicalSize, State};

use super::{
    apply_geometry, describe, parse_key, refresh_click_through, target_monitor, window, DisplayId, PollGate,
    PANEL_H, PANEL_W, WINDOW_LABEL,
};
use crate::desktop::logic::{display_near, Display, Rect};
use crate::platform;
use crate::settings::{self, IslandSpot};
use crate::Shared;

const HALF_W: f64 = 320.0; // half of EXPANDED_W (src/core/layout.ts): keep in sync
const FULL_H: f64 = PANEL_H; // height kept inside the work area, below the anchor
const DOCK_SNAP: f64 = 24.0;
const CENTER_SNAP: f64 = 24.0;
const MIN_MOVE: f64 = 8.0; // = WINDOW_DRAG_THRESHOLD (src/island/window-drag.ts): keep in sync
pub(super) const REST_W: f64 = 72.0; // = the floating #wake-strip (style.css): keep in sync
pub(super) const REST_H: f64 = 14.0;
pub(super) const TICK_MS: u64 = 8;
/// Physical px kept short of the limit where `on` stops holding the window (`butt`). `majority`
/// already judges the rounded window: this is a margin for what it cannot see, such as a real size
/// 1 px off the wanted one (`carry` tolerates that). Measured along the butt's segment, it moves the
/// anchor only slightly away from the limit when that segment runs along it.
const BUTT_MARGIN: f64 = 2.0;

#[derive(Clone)]
struct Screen {
    id: DisplayId,
    /// Frame, work area and scale, in PHYSICAL pixels (like desktop::logic).
    disp: Display,
}

/// What the drag keeps from one tick to the next to place the window.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Track {
    /// The display whose DPI the window has (or is about to get): carried_anchor's hysteresis.
    on: usize,
    /// The window's real scale, the one Windows gave it, read at the start of the tick.
    real: f64,
    /// The previous tick's anchor, consistent with `on`: the butt is searched between it and the target.
    last: (f64, f64),
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Placed {
    screen: usize,
    cx: f64,
    top: f64,
    docked: bool,
}

/// Where the island is (physical anchor), and on which monitor.
pub(super) struct Resolved {
    pub(super) cx: f64,
    pub(super) top: f64,
    pub(super) docked: bool,
    pub(super) monitor: Monitor,
}

fn overlap(a: &Rect, b: &Rect) -> f64 {
    let w = (a.x + a.w).min(b.x + b.w) - a.x.max(b.x);
    let h = (a.y + a.h).min(b.y + b.h) - a.y.max(b.y);
    if w > 0.0 && h > 0.0 {
        w * h
    } else {
        0.0
    }
}

/// The panel window `carry` places for this anchor at this scale, to the pixel (rounded size, origin
/// rounded by window_origin): the rectangle Windows judges.
fn placed(anchor: (f64, f64), scale: f64) -> Rect {
    let (w, h) = ((PANEL_W * scale).round(), (PANEL_H * scale).round());
    let (x, y) = window_origin(anchor, w);
    Rect { x: x as f64, y: y as f64, w, h }
}

/// The display holding the largest share of the panel window (720×320 logical at `scale`) placed for
/// `anchor`: the one whose DPI Windows gives the window (MonitorFromRect, which tao follows in
/// WM_DPICHANGED). Judged on the rounded window rather than the exact rectangle: near a border,
/// rounding alone can change the display, and the DPI would flip on every tick.
///
/// None: the window touches no display, or two displays with different scales hold the same share.
/// How Windows breaks that tie is unknown, so the window's DPI would be unpredictable.
fn majority(anchor: (f64, f64), scale: f64, screens: &[Screen]) -> Option<usize> {
    let r = placed(anchor, scale);
    let mut best: Option<(usize, f64)> = None;
    let mut tied = false;
    for (i, s) in screens.iter().enumerate() {
        let a = overlap(&r, &s.disp.frame);
        match best {
            _ if a <= 0.0 => {}
            Some((_, b)) if a < b => {}
            // Whole-pixel areas: equality is exact.
            Some((j, b)) if a == b => tied |= screens[j].disp.scale != s.disp.scale,
            _ => {
                best = Some((i, a));
                tied = false;
            }
        }
    }
    best.filter(|_| !tied).map(|(i, _)| i)
}

/// The display that contains `p`, or else the nearest one (desktop::logic::display_near).
fn index_near(p: (f64, f64), screens: &[Screen]) -> Option<usize> {
    let disps: Vec<Display> = screens.iter().map(|s| s.disp).collect();
    let near = display_near(p, &disps)?;
    disps.iter().position(|d| *d == near)
}

/// The anchor during the drag, and the display that will give the window its DPI.
///
/// The grabbed point (`grab`, logical, relative to the anchor) is drawn at anchor + grab × the
/// window's scale, and Windows gives the window the scale of the display holding the largest share of
/// it. So we look for a display i whose scale puts the window mostly on i itself. `on` (the previous
/// tick's) is kept as long as it stays consistent: no flip-flopping between two scales.
///
/// We only move on to i when Windows is really going to switch: the window placed there AT ITS
/// CURRENT SIZE (scale `real`) must already be mostly on i. Otherwise `on` would run ahead of the real
/// DPI, the island would be drawn beside the cursor, and a drop would keep a display that does not
/// hold it.
///
/// No consistent display (towards a smaller scale, over a gap, or where the two displays do not cover
/// the window over the same height): the island butts against the limit of `on` (`butt`), then jumps
/// in one go once another display takes it, with the grabbed point back under the cursor.
fn carried_anchor(cursor: (f64, f64), grab: (f64, f64), screens: &[Screen], track: Track) -> Option<((f64, f64), usize)> {
    if screens.is_empty() {
        return None;
    }
    let on = track.on.min(screens.len() - 1);
    let at = |i: usize| {
        let s = screens[i].disp.scale;
        (cursor.0 - grab.0 * s, cursor.1 - grab.1 * s)
    };
    let holds = |i: usize| majority(at(i), screens[i].disp.scale, screens) == Some(i);
    if holds(on) {
        return Some((at(on), on));
    }
    let takes = |i: usize| holds(i) && majority(at(i), track.real, screens) == Some(i);
    let under = index_near(cursor, screens);
    if let Some(i) = under.into_iter().chain(0..screens.len()).find(|&i| takes(i)) {
        return Some((at(i), i));
    }
    Some((butt(at(on), on, screens, track.last), on))
}

/// The anchor closest to `target` where `on`, at its own scale, still holds the window. That limit is
/// the edge of `on`'s frame only when the neighbouring displays cover the window over the same height
/// (at the bottom of DISPLAY1, the portrait DISPLAY2 covers all of it), so it is found by bisection on
/// the segment from `last`, which is consistent, to `target`, then backed off by BUTT_MARGIN.
fn butt(target: (f64, f64), on: usize, screens: &[Screen], last: (f64, f64)) -> (f64, f64) {
    let scale = screens[on].disp.scale;
    let holds = |a: (f64, f64)| majority(a, scale, screens) == Some(on);
    let (dx, dy) = (target.0 - last.0, target.1 - last.1);
    let len = dx.hypot(dy);
    if !holds(last) || len <= 0.0 {
        // Nothing consistent to start from (the window began off every display): `on`'s frame.
        let f = screens[on].disp.frame;
        return (target.0.max(f.x + 1.0).min(f.x + f.w - 1.0), target.1.max(f.y).min(f.y + f.h - 1.0));
    }
    let point = |t: f64| (last.0 + dx * t, last.1 + dy * t);
    let (mut inside, mut outside) = (0.0, 1.0);
    for _ in 0..32 {
        let mid = (inside + outside) / 2.0;
        if holds(point(mid)) {
            inside = mid;
        } else {
            outside = mid;
        }
    }
    let edge = point(inside);
    let back = (edge.0 - dx / len * BUTT_MARGIN, edge.1 - dy / len * BUTT_MARGIN);
    if holds(back) {
        back
    } else {
        edge
    }
}

/// Keeps the island (640 × 320 logical below the anchor) inside `d`'s work area. No f64::clamp (it
/// panics if min > max): a display narrower than the island (1080 px from about 169 %) centres it.
fn fit(d: &Display, cx: f64, top: f64, docked: bool) -> (f64, f64) {
    let half = HALF_W * d.scale;
    let (lo, hi) = (d.work.x + half, d.work.x + d.work.w - half);
    let cx = if lo > hi { d.work.x + d.work.w / 2.0 } else { cx.max(lo).min(hi) };
    let top = if docked {
        d.frame.y // the exact edge, like the default spot (mp.y in apply_geometry)
    } else {
        let (lo, hi) = (d.work.y, d.work.y + d.work.h - FULL_H * d.scale);
        if lo > hi {
            lo
        } else {
            top.max(lo).min(hi)
        }
    };
    (cx, top)
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

/// The spot of a drop, on the display holding the window, and whether it snapped to the top centre.
fn settle(cursor: (f64, f64), grab: (f64, f64), screens: &[Screen], track: Track) -> Option<(IslandSpot, bool)> {
    let (anchor, i) = carried_anchor(cursor, grab, screens, track)?;
    let d = &screens[i].disp;
    let docked = anchor.1 - d.frame.y <= DOCK_SNAP * d.scale;
    let (mut cx, top) = fit(d, anchor.0, anchor.1, docked);
    let mid = d.frame.x + d.frame.w / 2.0;
    let centred = docked && (cx - mid).abs() <= CENTER_SNAP * d.scale;
    if centred {
        cx = fit(d, mid, top, true).0;
    }
    let spot = IslandSpot {
        display: screens[i].id.key(),
        x: round1((cx - d.frame.x) / d.scale),
        y: if docked { 0.0 } else { round1((top - d.frame.y) / d.scale) },
        docked,
    };
    Some((spot, centred))
}

/// Docked again at the top centre of the "Island lives on" display (`home`, its key): that is the
/// default spot, there is nothing to keep, and the island goes back to anchored mode.
fn worth_keeping(spot: IslandSpot, centred: bool, home: Option<&str>) -> Option<IslandSpot> {
    if centred && spot.docked && home == Some(spot.display.as_str()) {
        None
    } else {
        Some(spot)
    }
}

/// The display a spot is on. Not pick_display's order: on Windows the name is \\.\DISPLAYn, a number
/// Windows may hand out again, so the name alone only counts as a last resort.
fn spot_display(key: &str, ids: &[DisplayId]) -> Option<usize> {
    let k = parse_key(key)?;
    let at = |d: &DisplayId| d.x == k.x && d.y == k.y;
    let named = |d: &DisplayId| k.name == Some(d.name.as_str());
    let sized = |d: &DisplayId| k.size == Some((d.w, d.h));
    ids.iter()
        .position(|d| at(d) && named(d))
        .or_else(|| ids.iter().position(|d| named(d) && sized(d)))
        .or_else(|| ids.iter().position(|d| at(d) && sized(d)))
        .or_else(|| ids.iter().position(at))
        .or_else(|| {
            let mut same = ids.iter().enumerate().filter(|(_, d)| named(d));
            match (same.next(), same.next()) {
                (Some((i, _)), None) => Some(i),
                _ => None,
            }
        })
}

/// None: an unusable spot (not finite) or an unplugged display.
fn resolve(spot: &IslandSpot, screens: &[Screen]) -> Option<Placed> {
    if !(spot.x.is_finite() && spot.y.is_finite()) {
        return None;
    }
    let ids: Vec<DisplayId> = screens.iter().map(|s| s.id.clone()).collect();
    let screen = spot_display(&spot.display, &ids)?;
    let d = &screens[screen].disp;
    let (cx, top) = fit(d, d.frame.x + spot.x * d.scale, d.frame.y + spot.y * d.scale, spot.docked);
    Some(Placed { screen, cx, top, docked: spot.docked })
}

/// Top-left corner of the window `width_px` wide that has this anchor.
pub(super) fn window_origin(anchor: (f64, f64), width_px: f64) -> (i32, i32) {
    ((anchor.0 - width_px / 2.0).round() as i32, anchor.1.round() as i32)
}

fn moved_enough(from: (f64, f64), to: (f64, f64), scale: f64) -> bool {
    (to.0 - from.0).hypot(to.1 - from.1) >= MIN_MOVE * scale
}

// ── State ─────────────────────────────────────────────────────────────────────

#[derive(Serialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Anchored,
    Docked,
    Floating,
}

impl Mode {
    fn from_u8(v: u8) -> Mode {
        match v {
            1 => Mode::Docked,
            2 => Mode::Floating,
            _ => Mode::Anchored,
        }
    }
}

/// JSON: {"capable":true,"mode":"floating"}
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlacementInfo {
    pub capable: bool,
    pub mode: Mode,
}

#[derive(Default)]
pub struct Free {
    /// True from the start of the drag until `land` (main thread), the release included.
    dragging: AtomicBool,
    /// Some during the drag; None from the release on, while `dragging` is still true.
    drag: Mutex<Option<Drag>>,
    /// The last mode announced to the pages (Mode as u8); 0 = Anchored at start.
    announced: AtomicU8,
    /// The spot was just cleared outside a drag: the next screen key change the poll sees (island.rs)
    /// comes from that, not from the display layout.
    rekey: AtomicBool,
}

impl Free {
    pub fn dragging(&self) -> bool {
        self.dragging.load(Ordering::SeqCst)
    }

    pub(super) fn take_rekey(&self) -> bool {
        self.rekey.swap(false, Ordering::Relaxed)
    }
}

struct Drag {
    /// The press point minus the anchor, in the window's logical pixels at the start.
    grab: (f64, f64),
    /// The displays at the start (a single available_monitors call).
    screens: Vec<Screen>,
    /// The press point, physical: let go less than MIN_MOVE from it, the drag is cancelled.
    press: (f64, f64),
    start_scale: f64,
    track: Track,
    /// Changes of the window's real DPI, logged once on release (`finish`).
    rescales: u32,
}

/// The same reading as desktop.rs (displays). None: no display.
fn screens(app: &AppHandle) -> Option<(Vec<Monitor>, Vec<Screen>)> {
    let monitors = app.available_monitors().ok()?;
    if monitors.is_empty() {
        return None;
    }
    let list = monitors
        .iter()
        .map(|m| {
            let (p, s, wa) = (m.position(), m.size(), m.work_area());
            Screen {
                id: describe(m),
                disp: Display {
                    frame: Rect { x: p.x as f64, y: p.y as f64, w: s.width as f64, h: s.height as f64 },
                    work: Rect {
                        x: wa.position.x as f64,
                        y: wa.position.y as f64,
                        w: wa.size.width as f64,
                        h: wa.size.height as f64,
                    },
                    scale: m.scale_factor(),
                },
            }
        })
        .collect();
    Some((monitors, list))
}

pub(super) fn resolved(app: &AppHandle) -> Option<Resolved> {
    if !platform::FREE_ISLAND {
        return None;
    }
    // No spot: stop here, before any monitor query (anchored mode, unchanged).
    let spot = app.try_state::<Shared>()?.settings.lock().unwrap().island_spot.clone()?;
    let (monitors, list) = screens(app)?;
    let p = resolve(&spot, &list)?;
    Some(Resolved { cx: p.cx, top: p.top, docked: p.docked, monitor: monitors[p.screen].clone() })
}

pub(super) fn dragging(app: &AppHandle) -> bool {
    app.try_state::<Shared>().map(|s| s.gate.free.dragging()).unwrap_or(false)
}

/// Tells the pages (island and Settings) the mode, only when it changes.
pub(super) fn announce(app: &AppHandle, free: Option<&Resolved>) {
    let mode = match free {
        None => Mode::Anchored,
        Some(f) if f.docked => Mode::Docked,
        Some(_) => Mode::Floating,
    };
    let Some(shared) = app.try_state::<Shared>() else { return };
    if shared.gate.free.announced.swap(mode as u8, Ordering::Relaxed) != mode as u8 {
        let _ = app.emit("island-placed", PlacementInfo { capable: platform::FREE_ISLAND, mode });
    }
}

/// One disk write, never during the drag; the lock is released before writing.
fn persist(shared: &Shared) {
    let snapshot = shared.settings.lock().unwrap().clone();
    if let Err(err) = settings::save(&snapshot) {
        crate::log::line(format!("could not save the island's spot: {err}"));
    }
}

/// Keeps the spot of a drop, or forgets it when it is the default one.
fn keep(app: &AppHandle, spot: IslandSpot, centred: bool) {
    let Some(shared) = app.try_state::<Shared>() else { return };
    let pref = shared.settings.lock().unwrap().screen.clone();
    let home = target_monitor(app, &pref).map(|m| describe(&m).key());
    let next = worth_keeping(spot, centred, home.as_deref());
    {
        let mut s = shared.settings.lock().unwrap();
        if s.island_spot == next {
            return;
        }
        s.island_spot = next;
    }
    persist(&shared);
}

// ── The drag ──────────────────────────────────────────────────────────────────

/// One tick of a drag, on the poll thread (island.rs, spawn_cursor_poll).
pub(super) fn carry(app: &AppHandle, gate: &PollGate) {
    let Some(win) = window(app) else { return finish(app, gate, None) };
    let cursor = platform::cursor_physical();
    let (Some(cursor), true) = (cursor, platform::primary_button_down()) else { return finish(app, gate, cursor) };
    // Read before taking the `drag` lock: these are window calls.
    let (Ok(size), Ok(scale)) = (win.outer_size(), win.scale_factor()) else { return };
    let anchor = {
        let mut slot = gate.free.drag.lock().unwrap();
        // Released: `land` finishes on the main thread, nothing left for this tick to do.
        let Some(drag) = slot.as_mut() else { return };
        if scale != drag.track.real {
            drag.rescales += 1;
        }
        drag.track.real = scale;
        let Some((anchor, on)) = carried_anchor(cursor, drag.grab, &drag.screens, drag.track) else { return };
        drag.track.on = on;
        drag.track.last = anchor;
        anchor
    };
    // tao keeps the LOGICAL size when the DPI changes, unless "Show window contents while dragging" is
    // turned off: then it keeps the physical size (WM_DPICHANGED).
    let want = ((PANEL_W * scale).round() as u32, (PANEL_H * scale).round() as u32);
    let width = if size.width.abs_diff(want.0) > 1 || size.height.abs_diff(want.1) > 1 {
        let _ = win.set_size(PhysicalSize::new(want.0, want.1));
        want.0
    } else {
        size.width
    };
    let origin = window_origin(anchor, width as f64);
    // Compared with the real position: on Windows 10, tao moves the window itself when its DPI changes.
    match win.outer_position() {
        Ok(p) if (p.x, p.y) == origin => {}
        _ => {
            let _ = win.set_position(PhysicalPosition::new(origin.0, origin.1));
        }
    }
}

/// Released (or the cursor or window lost: `cursor == None` cancels). Works out and keeps the spot on
/// this thread, then hands the geometry over to the main thread.
fn finish(app: &AppHandle, gate: &PollGate, cursor: Option<(f64, f64)>) {
    let Some(drag) = gate.free.drag.lock().unwrap().take() else { return };
    // The DPI Windows really gave the window, in one line per drag rather than one per tick: that is
    // where manual testing spots flip-flops (more than one change per crossing). The last change may
    // have come after the last tick.
    let end = window(app).and_then(|w| w.scale_factor().ok()).unwrap_or(drag.track.real);
    let rescales = drag.rescales + u32::from(end != drag.track.real);
    if rescales > 0 {
        crate::log::line(format!("island drag: scale {} → {end}, {rescales} change(s)", drag.start_scale));
    }
    if let Some(cursor) = cursor.filter(|c| moved_enough(drag.press, *c, drag.start_scale)) {
        if let Some((spot, centred)) = settle(cursor, drag.grab, &drag.screens, drag.track) {
            keep(app, spot, centred);
        }
    }
    let handle = app.clone();
    if app.run_on_main_thread(move || land(&handle)).is_err() {
        gate.free.dragging.store(false, Ordering::SeqCst);
    }
}

/// The end of a drag, on the main thread, where set_collapsed, reposition, save_settings and
/// island_reset_position (synchronous commands) also run: none of them can slip in between. `dragging`
/// stayed true until now, so a collapse asked for meanwhile (set_collapsed returns early) applies here.
fn land(app: &AppHandle) {
    let Some(shared) = app.try_state::<Shared>() else { return };
    let gate = &shared.gate;
    gate.free.dragging.store(false, Ordering::SeqCst);
    let pref = shared.settings.lock().unwrap().screen.clone();
    let collapsed = gate.collapsed.load(Ordering::Relaxed);
    apply_geometry(app, &pref, collapsed); // reads the spot just kept: a single placement path
    refresh_click_through(app, gate); // + forget_ignore_state: the next tick decides again
    gate.set_active(!collapsed);
    platform::set_pointer_watch(!collapsed);
    let _ = app.emit_to(WINDOW_LABEL, "island-drag-end", ());
}

// ── Commands (synchronous, like set_collapsed) ────────────────────────────────

#[tauri::command]
pub fn island_placement(shared: State<Shared>) -> PlacementInfo {
    PlacementInfo {
        capable: platform::FREE_ISLAND,
        mode: Mode::from_u8(shared.gate.free.announced.load(Ordering::Relaxed)),
    }
}

/// The page saw the pointer leave the dead zone. `x`, `y`: the press point, in the window's client
/// coordinates (CSS px = logical).
#[tauri::command]
pub fn island_drag_begin(app: AppHandle, shared: State<Shared>, x: f64, y: f64) -> bool {
    let free = &shared.gate.free;
    if !platform::FREE_ISLAND || free.dragging() || shared.gate.collapsed.load(Ordering::Relaxed) {
        return false;
    }
    // The button already released when the IPC arrives: the island would stick to the cursor until the
    // next click.
    if !(x.is_finite() && y.is_finite()) || !platform::primary_button_down() {
        return false;
    }
    let Some(win) = window(&app) else { return false };
    let (Ok(pos), Ok(size), Ok(scale)) = (win.outer_position(), win.outer_size(), win.scale_factor()) else {
        return false;
    };
    let Some((_, list)) = screens(&app) else { return false };
    let anchor = (pos.x as f64 + size.width as f64 / 2.0, pos.y as f64);
    let press = (pos.x as f64 + x * scale, pos.y as f64 + y * scale);
    let Some(on) = majority(anchor, scale, &list).or_else(|| index_near(anchor, &list)) else { return false };
    *free.drag.lock().unwrap() = Some(Drag {
        grab: ((press.0 - anchor.0) / scale, (press.1 - anchor.1) / scale),
        screens: list,
        press,
        start_scale: scale,
        track: Track { on, real: scale, last: anchor },
        rescales: 0,
    });
    free.dragging.store(true, Ordering::SeqCst); // after Drag: the poll finds it filled in
    true
}

#[tauri::command]
pub fn island_reset_position(app: AppHandle, shared: State<Shared>) {
    if shared.gate.free.dragging() {
        return;
    }
    // A spot that places the island changes the poll's screen key as it goes away. Read before taking
    // the `settings` lock (a monitor query).
    let placed = resolved(&app).is_some();
    {
        let mut s = shared.settings.lock().unwrap();
        if s.island_spot.take().is_none() {
            return;
        }
        // Under the lock: the poll cannot see the cleared spot without also seeing this flag.
        shared.gate.free.rekey.store(placed, Ordering::Relaxed);
    }
    persist(&shared);
    let pref = shared.settings.lock().unwrap().screen.clone();
    let collapsed = shared.gate.collapsed.load(Ordering::Relaxed);
    apply_geometry(&app, &pref, collapsed); // announces "anchored" to the pages
    refresh_click_through(&app, &shared.gate);
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn screen(name: &str, (x, y, w, h): (f64, f64, f64, f64), bottom_bar: f64, scale: f64) -> Screen {
        Screen {
            id: DisplayId {
                name: name.into(),
                x: (x / scale).round() as i32,
                y: (y / scale).round() as i32,
                w: (w / scale).round() as i32,
                h: (h / scale).round() as i32,
            },
            disp: Display { frame: Rect { x, y, w, h }, work: Rect { x, y, w, h: h - bottom_bar }, scale },
        }
    }
    fn d1(s: f64) -> Screen {
        screen("DISPLAY1", (0.0, 0.0, 2560.0, 1440.0), 48.0, s)
    }
    fn d2(s: f64) -> Screen {
        screen("DISPLAY2", (-1080.0, 0.0, 1080.0, 1920.0), 0.0, s)
    }
    fn both() -> Vec<Screen> {
        vec![d1(1.0), d2(1.0)]
    }
    const GRAB: (f64, f64) = (0.0, 20.0);
    const D2_KEY: &str = "at:-1080,0|DISPLAY2|1080x1920";

    /// Steady state on display `on`: the window has its DPI. The last anchor (the display's top centre,
    /// consistent) only matters to the butt.
    fn steady(screens: &[Screen], on: usize) -> Track {
        let f = screens[on].disp.frame;
        Track { on, real: screens[on].disp.scale, last: (f.x + f.w / 2.0, f.y + 100.0) }
    }

    /// A drop with the tests' defaults: two displays at 100 %, grabbed 20 px below the anchor, on D2.
    fn drop_at(cursor: (f64, f64)) -> (IslandSpot, bool) {
        let screens = both();
        settle(cursor, GRAB, &screens, steady(&screens, 1)).unwrap()
    }

    fn spot(display: &str, x: f64, y: f64, docked: bool) -> IslandSpot {
        IslandSpot { display: display.into(), x, y, docked }
    }

    fn close(a: (f64, f64), b: (f64, f64)) -> bool {
        (a.0 - b.0).abs() < 1e-9 && (a.1 - b.1).abs() < 1e-9
    }

    #[test]
    fn the_fixture_keys_match_what_settings_json_holds() {
        assert_eq!(d2(1.0).id.key(), D2_KEY);
        assert_eq!(d2(1.5).id.key(), "at:-720,0|DISPLAY2|720x1280");
    }

    #[test]
    fn a_drop_in_the_middle_of_a_display_floats_there() {
        let (s, centred) = drop_at((-540.0, 300.0));
        assert_eq!(s.display, D2_KEY);
        assert_eq!((s.x, s.y), (540.0, 280.0));
        assert!(!s.docked);
        assert!(!centred);
    }

    #[test]
    fn a_drop_near_the_top_edge_sticks_to_it() {
        let (s, centred) = drop_at((-400.0, 44.0));
        assert!(s.docked);
        assert_eq!((s.x, s.y), (680.0, 0.0));
        assert!(!centred);

        let (s, _) = drop_at((-400.0, 45.0));
        assert!(!s.docked);
        assert_eq!(s.y, 25.0);

        // 24 logical px at 150 %: 36 physical px.
        let screens = [d1(1.0), d2(1.5)];
        let (s, _) = settle((-540.0, 56.0), GRAB, &screens, steady(&screens, 1)).unwrap();
        assert!(s.docked);
    }

    #[test]
    fn a_drop_at_the_top_centre_snaps_to_it_and_forgets_the_spot_on_its_home_display() {
        let (s, centred) = drop_at((-530.0, 40.0));
        assert!(centred);
        assert_eq!(s.x, 540.0);

        let (s, centred) = drop_at((-500.0, 40.0));
        assert_eq!(s.x, 580.0);
        assert!(!centred);

        let centre = spot(D2_KEY, 540.0, 0.0, true);
        assert_eq!(worth_keeping(centre.clone(), true, Some(D2_KEY)), None);
        let d1_key = d1(1.0).id.key();
        assert_eq!(worth_keeping(centre.clone(), true, Some(&d1_key)), Some(centre.clone()));
        assert_eq!(worth_keeping(centre.clone(), false, Some(D2_KEY)), Some(centre));
    }

    #[test]
    fn the_whole_island_stays_above_the_bottom_of_the_work_area() {
        let (s, _) = drop_at((-540.0, 1900.0));
        assert_eq!(s.y, 1600.0);

        let screens = both();
        let (s, _) = settle((1000.0, 1400.0), GRAB, &screens, steady(&screens, 0)).unwrap();
        assert_eq!(s.display, d1(1.0).id.key());
        assert_eq!(s.y, 1072.0); // work area 1392 − 320
    }

    #[test]
    fn the_whole_island_stays_inside_the_sides_and_the_larger_share_wins() {
        let (s, _) = drop_at((-1070.0, 300.0));
        assert_eq!(s.x, 320.0);

        // 365 px on D2 against 355 on D1.
        let (s, _) = drop_at((-5.0, 300.0));
        assert_eq!(s.display, D2_KEY);
        assert_eq!(s.x, 760.0);
    }

    #[test]
    fn a_display_narrower_than_the_island_centres_it_without_panicking() {
        let screens = [d1(1.0), d2(1.75)];
        let (s, _) = settle((-540.0, 300.0), GRAB, &screens, steady(&screens, 1)).unwrap();
        assert_eq!((s.x, s.y), (308.6, 151.4));
        let p = resolve(&s, &screens).unwrap();
        assert_eq!(p.cx, -540.0);
    }

    #[test]
    fn a_drop_over_nothing_lands_on_the_display_it_came_from() {
        let screens = both();
        // The cursor goes down below DISPLAY1, over a gap: the island butts against the display's bottom.
        let from = Track { last: (900.0, 1000.0), ..steady(&screens, 0) };
        let ((x, y), on) = carried_anchor((900.0, 1700.0), GRAB, &screens, from).unwrap();
        assert_eq!((x, on), (900.0, 0));
        // Bottom of DISPLAY1: the rounded window keeps a row of pixels on it while y < 1439.5; minus the margin.
        assert!((y - (1439.5 - BUTT_MARGIN)).abs() < 1e-3, "{y}");
        let (s, _) = settle((900.0, 1700.0), GRAB, &screens, from).unwrap();
        assert_eq!(s.display, d1(1.0).id.key());
        assert_eq!((s.x, s.y), (900.0, 1072.0));
    }

    #[test]
    fn the_spot_follows_its_display_when_the_layout_changes() {
        let moved = [d1(1.0), screen("DISPLAY2", (2560.0, 0.0, 1080.0, 1920.0), 0.0, 1.0)];
        let p = resolve(&spot(D2_KEY, 540.0, 280.0, false), &moved).unwrap();
        assert_eq!(p.screen, 1);
        assert_eq!((p.cx, p.top), (3100.0, 280.0));
    }

    #[test]
    fn the_spot_is_kept_in_logical_pixels_when_the_scale_changes() {
        let screens = [d1(1.0), d2(1.5)];
        let p = resolve(&spot(D2_KEY, 380.0, 280.0, false), &screens).unwrap();
        assert_eq!((p.cx, p.top), (-510.0, 420.0));
        let p = resolve(&spot(D2_KEY, 540.0, 280.0, false), &screens).unwrap();
        assert_eq!(p.cx, -480.0); // right edge of the work area minus half the island
    }

    #[test]
    fn an_unplugged_display_or_a_nonsense_spot_resolves_to_nothing() {
        let s = spot(D2_KEY, 540.0, 280.0, false);
        assert_eq!(resolve(&s, &[d1(1.0)]), None);
        assert!(resolve(&s, &both()).is_some());
        assert_eq!(resolve(&spot(D2_KEY, f64::NAN, 280.0, false), &both()), None);
        assert_eq!(resolve(&spot(D2_KEY, 540.0, f64::INFINITY, false), &both()), None);
    }

    #[test]
    fn a_renumbered_display_keeps_the_spot_on_the_right_screen() {
        let ids = [
            DisplayId { name: "DISPLAY2".into(), x: 0, y: 0, w: 2560, h: 1440 },
            DisplayId { name: "DISPLAY1".into(), x: -1080, y: 0, w: 1080, h: 1920 },
        ];
        assert_eq!(spot_display(D2_KEY, &ids), Some(1));
    }

    #[test]
    fn at_equal_scales_the_grabbed_point_stays_under_the_cursor_across_displays() {
        let screens = both();
        assert_eq!(
            carried_anchor((100.0, 50.0), (300.0, 20.0), &screens, steady(&screens, 0)),
            Some(((-200.0, 30.0), 1))
        );
    }

    #[test]
    fn the_display_the_window_is_on_is_kept_while_it_still_holds_it() {
        let screens = [d1(1.0), d2(1.5)];
        let grab = (200.0, 20.0);
        let (on_d1, on_d2) = (steady(&screens, 0), steady(&screens, 1));
        assert_eq!(carried_anchor((250.0, 100.0), grab, &screens, on_d1), Some(((50.0, 80.0), 0)));
        assert_eq!(carried_anchor((250.0, 100.0), grab, &screens, on_d2), Some(((-50.0, 70.0), 1)));
        assert_eq!(carried_anchor((199.0, 100.0), grab, &screens, on_d1), Some(((-101.0, 70.0), 1)));
        assert_eq!(carried_anchor((301.0, 100.0), grab, &screens, on_d2), Some(((101.0, 80.0), 0)));
    }

    #[test]
    fn towards_a_smaller_scale_the_island_waits_at_the_edge_then_jumps_once() {
        let screens = [d1(1.5), d2(1.0)];
        let grab = (200.0, 20.0);
        // Coming from the right: on the previous tick, the cursor was at (350,100) and the anchor at (50,70).
        let from = Track { on: 0, real: 1.5, last: (50.0, 70.0) };
        // The window butts against x = 0, minus the margin. Below x = 0.5, the rounded window (1080 px)
        // is first tied between the two displays, then mostly on DISPLAY2.
        let ((x, y), on) = carried_anchor((250.0, 100.0), grab, &screens, from).unwrap();
        assert_eq!((y, on), (70.0, 0));
        assert!((x - (0.5 + BUTT_MARGIN)).abs() < 1e-6, "{x}");
        assert_eq!(carried_anchor((150.0, 100.0), grab, &screens, from), Some(((-50.0, 80.0), 1)));
        assert_eq!(carried_anchor((350.0, 100.0), grab, &screens, from), Some(((50.0, 70.0), 0)));
    }

    #[test]
    fn the_majority_is_that_of_the_rounded_window_and_never_a_tie_between_scales() {
        let screens = [d1(1.5), d2(1.0)];
        // Exact rectangle: 259,108 px² on DISPLAY1 against 258,480. The window placed at (-539, 962),
        // 1080×480: 258,598 against 258,720, and Windows gives it DISPLAY2's DPI.
        assert_eq!(majority((1.5, 961.5), 1.5, &screens), Some(1));
        // 540 px on each side, at 150 % and at 100 %: how Windows breaks the tie is not documented.
        assert_eq!(majority((0.0, 70.0), 1.5, &screens), None);
        // At the same scale, the DPI does not depend on the tie-break.
        assert_eq!(majority((0.0, 70.0), 1.0, &both()), Some(0));
    }

    /// What a drag shows, tick by tick.
    struct Sweep {
        /// Changes of the display kept (`on`).
        switches: u32,
        /// Changes of the window's real DPI (WM_DPICHANGED).
        rescales: u32,
        /// Ticks that ended with a real DPI other than `on`'s scale.
        mismatched: u32,
        /// DPI changes with the cursor at rest, after the first tick: the window would flip forever.
        restless: u32,
        end: usize,
    }

    impl Sweep {
        fn check(&self, what: &str) {
            assert!(self.switches <= 1, "{what}: {} display switches", self.switches);
            assert!(self.rescales <= 1, "{what}: {} DPI changes", self.rescales);
            assert_eq!(self.mismatched, 0, "{what}: real DPI ≠ the scale of the display kept");
            assert_eq!(self.restless, 0, "{what}: the DPI changes with the cursor at rest");
        }
    }

    /// The DPI Windows gives the window `carry` just placed: at the size of its real scale, around the
    /// anchor, to the pixel, it takes the scale of the display holding the largest share of that
    /// rectangle (tao resizes it, the next tick places it again). Two displays with different scales
    /// tied: which one Windows picks is unknown, so the window must never be there.
    fn dpi_from_windows(anchor: (f64, f64), real: f64, screens: &[Screen]) -> f64 {
        let (w, h) = ((PANEL_W * real).round(), (PANEL_H * real).round());
        let (x, y) = window_origin(anchor, w);
        let rect = Rect { x: x as f64, y: y as f64, w, h };
        let areas: Vec<f64> = screens.iter().map(|s| overlap(&rect, &s.disp.frame)).collect();
        let best = areas.iter().copied().fold(0.0, f64::max);
        assert!(best > 0.0, "anchor {anchor:?}: the window is off every display");
        let mut scales = (0..screens.len()).filter(|&i| areas[i] == best).map(|i| screens[i].disp.scale);
        let first = scales.next().unwrap();
        assert!(scales.all(|s| s == first), "anchor {anchor:?}: tie between two scales");
        first
    }

    /// A drag along `path`, with what Windows does to the window on every tick. The cursor rests three
    /// ticks at each step: only the first one may change the DPI.
    fn sweep(screens: &[Screen], grab: (f64, f64), path: &[(f64, f64)], start: usize) -> Sweep {
        let scale = screens[start].disp.scale;
        let first = (path[0].0 - grab.0 * scale, path[0].1 - grab.1 * scale);
        assert_eq!(majority(first, scale, screens), Some(start), "inconsistent start at {:?}, grabbed at {grab:?}", path[0]);
        let mut track = Track { on: start, real: scale, last: first };
        let mut out = Sweep { switches: 0, rescales: 0, mismatched: 0, restless: 0, end: start };
        for &cursor in path {
            for tick in 0..3 {
                let (anchor, on) = carried_anchor(cursor, grab, screens, track).unwrap();
                let s = screens[on].disp.scale;
                // Always consistent: at `on`'s scale, the window is mostly on `on`.
                assert_eq!(majority(anchor, s, screens), Some(on), "cursor {cursor:?}: anchor {anchor:?}");
                // Unless it butts, the grabbed point is exactly under the cursor.
                let exact = (cursor.0 - grab.0 * s, cursor.1 - grab.1 * s);
                if majority(exact, s, screens) == Some(on) {
                    assert!(close(anchor, exact), "cursor {cursor:?}: {anchor:?} instead of {exact:?}");
                }
                if on != track.on {
                    out.switches += 1;
                }
                let real = dpi_from_windows(anchor, track.real, screens);
                if real != track.real {
                    out.rescales += 1;
                    if tick > 0 {
                        out.restless += 1;
                    }
                }
                if real != s {
                    out.mismatched += 1;
                }
                track = Track { on, real, last: anchor };
            }
        }
        out.end = track.on;
        out
    }

    #[test]
    fn a_sweep_across_the_border_switches_scale_once_and_never_back() {
        // The default grab, grabs far from the axis, where the scales weigh in, and grabs whose anchor
        // falls between two pixels at 125 % or 150 %: the window's rounding then decides the display.
        let grabs = [
            GRAB,
            (200.0, 20.0),
            (-200.0, 20.0),
            (1.0, 21.0),
            (201.0, 21.0),
            (-133.0, 13.0),
            (37.0, 9.0),
            (250.0, 15.0),
        ];
        for (s1, s2) in [(1.0, 1.0), (1.0, 1.5), (1.5, 1.0), (1.25, 1.0), (1.25, 2.0)] {
            let screens = [d1(s1), d2(s2)];
            for grab in grabs {
                // y = 100: both displays cover the window over the same height. 1100 and 1300: at the
                // bottom of DISPLAY1 (1440 px), while the portrait DISPLAY2 (1920 px) covers all of it.
                for y in [100.0, 1100.0, 1300.0] {
                    for (xs, start) in [((-900..=900).rev().collect::<Vec<i32>>(), 0), ((-900..=900).collect(), 1)] {
                        let path: Vec<(f64, f64)> = xs.iter().map(|&x| (x as f64, y)).collect();
                        let r = sweep(&screens, grab, &path, start);
                        let what = format!("{s1}/{s2} grabbed at {grab:?}, y {y}, from {start}");
                        r.check(&what);
                        // A window 320 logical px high may stay on DISPLAY2 all along at the bottom of
                        // DISPLAY1; at y = 100, the crossing has to happen.
                        if y == 100.0 {
                            assert_eq!(r.end, 1 - start, "{what}: no crossing");
                        }
                    }
                }
                // Diagonally towards the bottom of DISPLAY1, then upwards: the butt looks for its limit on
                // a segment almost parallel to the edge, where backing off along the segment barely moves
                // away from it.
                for (from, step, start) in [
                    ((-800.0, 720.0), (1.0, 0.7), 1),
                    ((800.0, 720.0), (-1.0, 0.7), 0),
                    ((-800.0, 1380.0), (1.0, -0.7), 1),
                    ((800.0, 1380.0), (-1.0, -0.7), 0),
                ] {
                    let path: Vec<(f64, f64)> =
                        (0..=1000).map(|k| (from.0 + step.0 * k as f64, from.1 + step.1 * k as f64)).collect();
                    let r = sweep(&screens, grab, &path, start);
                    r.check(&format!("{s1}/{s2} grabbed at {grab:?}, diagonally from {from:?}"));
                }
            }
        }
    }

    #[test]
    fn the_window_is_placed_around_its_anchor() {
        assert_eq!(window_origin((-540.4, 280.6), 1080.0), (-1080, 281));
    }

    #[test]
    fn a_drop_closer_than_eight_logical_pixels_to_the_press_is_no_move() {
        assert!(!moved_enough((0.0, 0.0), (7.9, 0.0), 1.0));
        assert!(moved_enough((0.0, 0.0), (8.0, 0.0), 1.0));
        assert!(!moved_enough((0.0, 0.0), (11.9, 0.0), 1.5));
        assert!(moved_enough((0.0, 0.0), (12.0, 0.0), 1.5));
    }

    #[test]
    fn a_spot_settled_then_resolved_comes_back_to_the_same_place() {
        for s2 in [1.0, 1.25, 1.5, 1.75, 2.0] {
            let screens = [d1(1.0), d2(s2)];
            let (anchor, i) = carried_anchor((-540.0, 300.0), GRAB, &screens, steady(&screens, 1)).unwrap();
            let d = &screens[i].disp;
            let docked = anchor.1 - d.frame.y <= DOCK_SNAP * d.scale;
            let (cx, top) = fit(d, anchor.0, anchor.1, docked);
            let (s, _) = settle((-540.0, 300.0), GRAB, &screens, steady(&screens, 1)).unwrap();
            let p = resolve(&s, &screens).unwrap();
            assert_eq!(p.screen, i, "{s2}");
            assert!((p.cx - cx).abs() <= 0.1 * s2, "{s2}: {} against {cx}", p.cx);
            assert!((p.top - top).abs() <= 0.1 * s2, "{s2}: {} against {top}", p.top);
        }
    }

    #[test]
    fn the_pages_read_the_mode_in_lower_case() {
        let info = PlacementInfo { capable: true, mode: Mode::Floating };
        assert_eq!(serde_json::to_value(info).unwrap(), json!({ "capable": true, "mode": "floating" }));
        assert_eq!(Mode::from_u8(0), Mode::Anchored);
        assert_eq!(Mode::from_u8(1), Mode::Docked);
        assert_eq!(Mode::from_u8(2), Mode::Floating);
        assert_eq!(Mode::from_u8(255), Mode::Anchored);
        for mode in [Mode::Anchored, Mode::Docked, Mode::Floating] {
            assert_eq!(Mode::from_u8(mode as u8), mode);
        }
    }
}
