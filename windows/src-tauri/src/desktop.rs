//! Desktop Mochi — the free-floating window Mochi lives in.
//!
//! On macOS this is an NSPanel that flies out from the notch and can be dragged
//! anywhere on the desktop. Windows gets the same thing as a second Tauri
//! webview: transparent, undecorated, always on top, skipped in the taskbar.
//!
//! The rules that decide *where* it goes and *when* it sleeps are not here. They
//! are in `src/mochi/desktop.ts`, ported from DesktopMochiLogic.swift and unit
//! tested there. This file is the part that cannot be tested without a desktop:
//! creating the window, putting it where the rules said, and letting the
//! frontend drag it.
//!
//! Panel size is 120px, matching the macOS build. Every constant used to decide
//! behaviour — the sleep timeout, the mouse distance, the clamp margin — lives
//! in the TypeScript module so both platforms agree.

use std::sync::Mutex;

use tauri::{AppHandle, LogicalSize, Manager, PhysicalPosition, WebviewUrl, WebviewWindow};

use crate::settings;

pub const WINDOW_LABEL: &str = "mochi";
pub const DEFAULT_PANEL_SIZE: f64 = 120.0;
const MIN_PANEL_SIZE: f64 = 72.0;
const MAX_PANEL_SIZE: f64 = 240.0;
const CLAMP_MARGIN: f64 = 24.0;
/// Body radius as a fraction of the panel, mirroring DESKTOP_BODY_RADIUS_FRACTION.
const BODY_RADIUS_FRACTION: f64 = 0.24;
/// Ensures the hit-test thread is started exactly once, however often the pet
/// is shown or hidden.
static HIT_TEST_STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[derive(Clone, serde::Serialize)]
struct CursorOffset {
    dx: f64,
    dy: f64,
}

#[derive(Clone, serde::Serialize, PartialEq)]
pub struct PetSnapshot {
    state: String,
    body_color: Option<String>,
    focused_id: Option<String>,
    music_playing: bool,
    permission_pending: bool,
}

static PET_SNAPSHOT: Mutex<Option<PetSnapshot>> = Mutex::new(None);

/// A work area in physical pixels, y increasing downward — the shape the
/// TypeScript clamp rules expect.
#[derive(Clone, Copy, Debug)]
pub struct WorkArea {
    pub left: f64,
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
}

impl WorkArea {
    fn from_monitor(m: &tauri::Monitor) -> Self {
        let wa = m.work_area();
        Self {
            left: wa.position.x as f64,
            top: wa.position.y as f64,
            right: wa.position.x as f64 + wa.size.width as f64,
            bottom: wa.position.y as f64 + wa.size.height as f64,
        }
    }

    fn full_monitor(m: &tauri::Monitor) -> Self {
        let pos = m.position();
        let size = m.size();
        Self {
            left: pos.x as f64,
            top: pos.y as f64,
            right: pos.x as f64 + size.width as f64,
            bottom: pos.y as f64 + size.height as f64,
        }
    }
}

/// The mirror of `clampOrigin` in src/mochi/desktop.ts.
///
/// Duplicated rather than called through because that module is TypeScript in a
/// webview and this runs before the webview exists. The two must agree; the
/// TypeScript side is covered by `npm run test:mochi`, and this mirror is the
/// one place they can drift, so it keeps the same expression and the same
/// guard.
fn clamp_origin(x: f64, y: f64, area: WorkArea, panel: f64, margin: f64) -> (f64, f64) {
    let (min_x, max_x) = (area.left + margin, area.right - panel - margin);
    let (min_y, max_y) = (area.top + margin, area.bottom - panel - margin);
    // A work area narrower than panel + both margins inverts the range; take the
    // lower bound instead of the upper one, which would park the panel offscreen.
    let cx = if max_x < min_x {
        min_x
    } else {
        (x.max(min_x)).min(max_x)
    };
    let cy = if max_y < min_y {
        min_y
    } else {
        (y.max(min_y)).min(max_y)
    };
    (cx, cy)
}

fn primary_area(app: &AppHandle) -> WorkArea {
    app.primary_monitor()
        .ok()
        .flatten()
        .map(|m| WorkArea::from_monitor(&m))
        .unwrap_or(WorkArea {
            left: 0.0,
            top: 0.0,
            right: 1920.0,
            bottom: 1080.0,
        })
}

fn primary_full_area(app: &AppHandle) -> WorkArea {
    app.primary_monitor()
        .ok()
        .flatten()
        .map(|m| WorkArea::full_monitor(&m))
        .unwrap_or(WorkArea {
            left: 0.0,
            top: 0.0,
            right: 1920.0,
            bottom: 1080.0,
        })
}

/// Which display a point sits on, or the primary one.
fn monitor_for_point(app: &AppHandle, x: f64, y: f64) -> Option<tauri::Monitor> {
    let monitors = app.available_monitors().ok()?;
    monitors
        .into_iter()
        .find(|m| {
            // Select by the full physical monitor rectangle so points over the
            // taskbar remain associated with the correct secondary monitor.
            let pos = m.position();
            let size = m.size();
            let left = pos.x as f64;
            let top = pos.y as f64;
            x >= left && x < left + size.width as f64 && y >= top && y < top + size.height as f64
        })
        .or_else(|| app.primary_monitor().ok().flatten())
}

pub fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window(WINDOW_LABEL)
}

/// Creates the panel if it does not exist yet, hidden.
pub fn ensure_window(app: &AppHandle) -> Option<WebviewWindow> {
    if let Some(w) = window(app) {
        return Some(w);
    }
    match tauri::WebviewWindowBuilder::new(
        app,
        WINDOW_LABEL,
        WebviewUrl::App("mochi.html".into()),
    )
    .additional_browser_args(
        "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection --autoplay-policy=no-user-gesture-required",
    )
    .title("Coucou Mochi")
    .inner_size(DEFAULT_PANEL_SIZE, DEFAULT_PANEL_SIZE)
    .min_inner_size(MIN_PANEL_SIZE, MIN_PANEL_SIZE)
    .resizable(false)
    .decorations(false)
    .transparent(true)
    .background_color(tauri::webview::Color(0, 0, 0, 0))
    .shadow(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .visible(false)
    .build()
    {
        Ok(w) => Some(w),
        Err(e) => {
            crate::log::line(format!("mochi window build failed: {e}"));
            None
        }
    }
}

/// Puts the panel where the rules say, clamped to the display it belongs to.
///
/// Saved Mochi positions and monitor bounds use physical pixels. The webview
/// itself is sized in logical pixels, so scale the panel only for clamping,
/// then pass the physical origin directly to Tauri. First launch uses the work
/// area; saved positions are allowed over the taskbar.
pub fn place(app: &AppHandle) {
    let Some(win) = ensure_window(app) else {
        return;
    };
    let saved_settings = settings::load();
    let saved = saved_settings.desktop_mochi_pos;
    let panel_size = saved_settings
        .desktop_mochi_size
        .clamp(MIN_PANEL_SIZE, MAX_PANEL_SIZE);
    let target_monitor = saved
        .and_then(|(x, y)| monitor_for_point(app, x, y))
        .or_else(|| app.primary_monitor().ok().flatten());
    let scale = target_monitor
        .as_ref()
        .map(|m| m.scale_factor())
        .unwrap_or_else(|| win.scale_factor().unwrap_or(1.0));
    let panel = panel_size * scale;
    let (x, y) = match (saved, target_monitor.as_ref()) {
        // Saved positions may be on top of the taskbar, so clamp to the full
        // monitor rather than the reduced work area.
        (Some((x, y)), Some(monitor)) => {
            clamp_origin(x, y, WorkArea::full_monitor(monitor), panel, 0.0)
        }
        (Some((x, y)), None) => clamp_origin(x, y, primary_full_area(app), panel, 0.0),
        // First launch stays in the work area, above the taskbar and inset a bit.
        (None, _) => {
            let area = target_monitor
                .as_ref()
                .map(WorkArea::from_monitor)
                .unwrap_or_else(|| primary_area(app));
            let margin = CLAMP_MARGIN * scale;
            clamp_origin(
                area.right - panel - margin,
                area.bottom - panel - margin,
                area,
                panel,
                margin,
            )
        }
    };
    let _ = win.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
    let _ = win.set_size(LogicalSize::new(panel_size, panel_size));
}

/// Moves the panel to an absolute position and returns its clamped origin.
///
/// Always clamped to the full monitor, so Mochi can overlap the taskbar but
/// cannot be dragged off-screen. The final position is persisted once by
/// `desktop_mochi_drag_end`, not on every mousemove.
fn move_to(app: &AppHandle, x: f64, y: f64) -> Option<(f64, f64)> {
    let Some(win) = window(app) else {
        return None;
    };
    let target_monitor = monitor_for_point(app, x, y);
    let area = target_monitor
        .as_ref()
        .map(WorkArea::full_monitor)
        .unwrap_or_else(|| primary_full_area(app));
    let scale = target_monitor
        .as_ref()
        .map(|m| m.scale_factor())
        .unwrap_or_else(|| win.scale_factor().unwrap_or(1.0));
    let panel_size = settings::load()
        .desktop_mochi_size
        .clamp(MIN_PANEL_SIZE, MAX_PANEL_SIZE);
    let panel = panel_size * scale;
    // Zero margin on drag lets the pet overlap the taskbar, while still keeping
    // the entire panel on-screen so it can always be recovered.
    let (cx, cy) = clamp_origin(x, y, area, panel, 0.0);
    let _ = win.set_position(PhysicalPosition::new(cx.round() as i32, cy.round() as i32));
    // Windows can place the taskbar above an always-on-top window in the
    // topmost z-order. Reassert topmost while dragging so the taskbar does not
    // visually cover Mochi as it moves into the taskbar area.
    let _ = win.set_always_on_top(true);

    Some((cx, cy))
}

#[tauri::command]
pub fn desktop_mochi_show(app: AppHandle) -> bool {
    place(&app);
    let Some(win) = window(&app) else {
        return false;
    };
    // Non-activating: showing Mochi must never steal focus from a terminal.
    crate::platform::make_non_activating(&win);
    let _ = win.show();
    if !HIT_TEST_STARTED.swap(true, std::sync::atomic::Ordering::Relaxed) {
        spawn_hit_test(app);
    }
    true
}

#[tauri::command]
pub fn desktop_mochi_hide(app: AppHandle) {
    if let Some(win) = window(&app) {
        let _ = win.hide();
    }
}

/// Global-cursor drag tracking lives in Rust so a click-through WebView or the
/// taskbar cannot interrupt the drag when the pointer leaves Mochi's window.
#[derive(Clone, Copy)]
struct DragTracking {
    window_x: f64,
    window_y: f64,
    cursor_x: f64,
    cursor_y: f64,
}

static DRAG_TRACKING: Mutex<Option<DragTracking>> = Mutex::new(None);

#[tauri::command]
pub fn desktop_mochi_drag_start(app: AppHandle) {
    let Some(win) = window(&app) else {
        return;
    };
    let (Some((cursor_x, cursor_y)), Ok(pos)) =
        (crate::platform::cursor_physical(), win.outer_position())
    else {
        return;
    };
    *DRAG_TRACKING.lock().unwrap() = Some(DragTracking {
        window_x: pos.x as f64,
        window_y: pos.y as f64,
        cursor_x,
        cursor_y,
    });
}

fn persist_drag_position(app: &AppHandle) {
    let Some(win) = window(app) else {
        return;
    };
    let (Some(position), Ok(size)) = (win.outer_position().ok(), win.outer_size()) else {
        return;
    };
    if let Some(monitor) = monitor_for_point(app, position.x as f64, position.y as f64) {
        let bounds = WorkArea::full_monitor(&monitor);
        let work = monitor.work_area();
        crate::log::line(format!(
            "mochi: drag end pos={},{} window={}x{} monitor={}x{}@{},{} scale={} work={}x{}@{},{}",
            position.x,
            position.y,
            size.width,
            size.height,
            monitor.size().width,
            monitor.size().height,
            bounds.left,
            bounds.top,
            monitor.scale_factor(),
            work.size.width,
            work.size.height,
            work.position.x,
            work.position.y,
        ));
    }
    let mut s = settings::load();
    s.desktop_mochi_pos = Some((position.x as f64, position.y as f64));
    if let Err(err) = settings::save(&s) {
        crate::log::line(format!("could not save Desktop Mochi position: {err}"));
    }
}

/// Saves the final physical position once, when the drag ends. Avoid writing
/// settings.json on every cursor poll.
#[tauri::command]
pub fn desktop_mochi_drag_end(app: AppHandle) {
    *DRAG_TRACKING.lock().unwrap() = None;
    persist_drag_position(&app);
}

/// Decides click-through from the cursor position, polled here rather than from
/// the webview.
///
/// This cannot be done in the frontend, and the mistake is easy to repeat: a
/// click-through window receives no `mousemove`, so a webview that toggles
/// `set_ignore_cursor_events` on hover switches itself off and can never switch
/// itself back on. The pet then sits on the desktop looking normal and cannot
/// be clicked or dragged at all. The island polls the cursor in Rust for
/// exactly this reason; this is the same approach, with the panel's circular
/// body as the hit region instead of the island's rectangle.
pub fn spawn_hit_test(app: AppHandle) {
    std::thread::spawn(move || {
        // Starts click-through so the panel cannot eat clicks before the first
        // poll lands.
        let _ = window(&app).map(|w| w.set_ignore_cursor_events(true));
        let mut last: Option<bool> = None;
        loop {
            let Some(win) = window(&app) else {
                std::thread::sleep(std::time::Duration::from_millis(100));
                continue;
            };
            if !win.is_visible().unwrap_or(false) {
                last = None;
                std::thread::sleep(std::time::Duration::from_millis(40));
                continue;
            }

            let drag = *DRAG_TRACKING.lock().unwrap();
            if let Some(drag) = drag {
                if crate::platform::left_button_down() {
                    if let Some((cursor_x, cursor_y)) = crate::platform::cursor_physical() {
                        let _ = move_to(
                            &app,
                            drag.window_x + cursor_x - drag.cursor_x,
                            drag.window_y + cursor_y - drag.cursor_y,
                        );
                    }
                } else {
                    let was_dragging = DRAG_TRACKING.lock().unwrap().take().is_some();
                    if was_dragging {
                        persist_drag_position(&app);
                    }
                }
            }

            let offset = cursor_offset(&app);
            let over = offset.map(|(dx, dy)| {
                let panel_size = settings::load()
                    .desktop_mochi_size
                    .clamp(MIN_PANEL_SIZE, MAX_PANEL_SIZE);
                let radius = panel_size * BODY_RADIUS_FRACTION;
                dx * dx + dy * dy <= radius * radius
            });
            match over {
                Some(over) if Some(over) != last => {
                    let _ = win.set_ignore_cursor_events(!over);
                    last = Some(over);
                }
                _ => {}
            }
            std::thread::sleep(std::time::Duration::from_millis(16));
        }
    });
}

/// Cursor offset from the Mochi's centre in panel-logical pixels. Rust owns this
/// global cursor read because click-through webviews receive no mousemove events.
fn cursor_offset(app: &AppHandle) -> Option<(f64, f64)> {
    let win = window(app)?;
    let (cx, cy) = crate::platform::cursor_physical()?;
    let pos = win.inner_position().ok()?;
    let size = win.inner_size().ok()?;
    let scale = win.scale_factor().ok()?;
    if size.width == 0 || size.height == 0 || scale <= 0.0 {
        return None;
    }
    let dx = (cx - (pos.x as f64 + size.width as f64 / 2.0)) / scale;
    let dy = (cy - (pos.y as f64 + size.height as f64 / 2.0)) / scale;
    Some((dx, dy))
}

/// Writes a line to coucou.log.
///
/// The pet is a transparent window whose contents cannot be verified by screen
/// capture, and a frontend that silently fails to draw looks identical to one
/// that drew nothing. Having the webview report in lets the app state be
/// checked directly instead of inferred from pixels.
/// Keeps the floating Mochi in step with the island's currently focused pill.
#[tauri::command]
pub fn desktop_mochi_sync(
    state: String,
    body_color: Option<String>,
    focused_id: Option<String>,
    music_playing: bool,
    permission_pending: bool,
) {
    let snapshot = PetSnapshot {
        state,
        body_color,
        focused_id,
        music_playing,
        permission_pending,
    };
    let changed = {
        let mut current = PET_SNAPSHOT.lock().unwrap();
        let changed = current.as_ref() != Some(&snapshot);
        *current = Some(snapshot.clone());
        changed
    };
    if changed {
        crate::log::line(format!(
            "mochi: island sync id={} state={} color={}",
            snapshot.focused_id.as_deref().unwrap_or("none"),
            snapshot.state,
            snapshot.body_color.as_deref().unwrap_or("gradient")
        ));
    }
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PetRuntime {
    snapshot: Option<PetSnapshot>,
    cursor: Option<CursorOffset>,
    visible: bool,
    dragging: bool,
}

/// One direct native poll supplies both focused-pill state and global cursor
/// position. This avoids relying on WebView event delivery for either behavior.
#[tauri::command]
pub fn desktop_mochi_runtime(app: AppHandle) -> PetRuntime {
    let win = window(&app);
    let visible = win
        .as_ref()
        .and_then(|w| w.is_visible().ok())
        .unwrap_or(false);
    PetRuntime {
        snapshot: PET_SNAPSHOT.lock().unwrap().clone(),
        cursor: if visible {
            cursor_offset(&app).map(|(dx, dy)| CursorOffset { dx, dy })
        } else {
            None
        },
        visible,
        dragging: DRAG_TRACKING.lock().unwrap().is_some(),
    }
}

#[tauri::command]
pub fn desktop_mochi_probe(msg: String) {
    crate::log::line(format!("mochi: {msg}"));
}

#[cfg(test)]
mod tests {
    use super::{clamp_origin, WorkArea};

    #[test]
    fn clamp_uses_physical_panel_and_margin_on_scaled_monitor() {
        // 150% display: 120 logical px -> 180 physical px; 24 logical px ->
        // 36 physical px. The work area is already reported in physical px.
        let area = WorkArea {
            left: 1920.0,
            top: 0.0,
            right: 3840.0,
            bottom: 1020.0,
        };
        let panel = 120.0 * 1.5;
        let margin = 24.0 * 1.5;
        assert_eq!(
            clamp_origin(99_999.0, 99_999.0, area, panel, margin),
            (3624.0, 804.0)
        );
    }

    #[test]
    fn full_monitor_clamp_allows_mochi_over_the_taskbar() {
        let monitor = WorkArea {
            left: 0.0,
            top: 0.0,
            right: 1920.0,
            bottom: 1080.0,
        };
        assert_eq!(
            clamp_origin(500.0, 1_500.0, monitor, 120.0, 0.0),
            (500.0, 960.0)
        );
    }

    #[test]
    fn clamp_keeps_negative_virtual_screen_coordinates_physical() {
        let area = WorkArea {
            left: -1920.0,
            top: 0.0,
            right: 0.0,
            bottom: 1080.0,
        };
        assert_eq!(
            clamp_origin(-99_999.0, -99_999.0, area, 120.0, 24.0),
            (-1896.0, 24.0)
        );
    }
}
