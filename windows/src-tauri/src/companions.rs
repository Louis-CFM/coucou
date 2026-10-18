//! A single non-activating habitat, with an input region only over each pet.
//! No cursor poll, application inspection, automatic media actions or permissions.
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

pub const LABEL: &str = "companions";

#[derive(Clone, Default, Serialize)]
pub struct Surface {
    width: f64,
    height: f64,
    top: f64,
    band: Option<Band>,
}

#[derive(Clone, Default, Serialize)]
pub struct Band { height: f64, lanes: Vec<(f64, f64)> }

#[derive(Default)]
struct Habitat {
    enabled: AtomicBool,
    surface: Mutex<Surface>,
    anchor: Mutex<Option<(f64, f64)>>,
}

pub fn setup(app: &AppHandle) {
    app.manage(Habitat::default());
    #[cfg(target_os = "linux")]
    { native::create(app); native::watch_bar(app); }
}

pub fn enabled(app: &AppHandle) -> bool { app.try_state::<Habitat>().is_some_and(|h| h.enabled.load(Ordering::Relaxed)) }

/// Relative to the island's display. The popup follows the pet explicitly
/// clicked by the user; pets wandering elsewhere never move an open popup.
pub fn center(app: &AppHandle) -> Option<(f64, f64)> {
    let habitat = app.try_state::<Habitat>()?;
    if !habitat.enabled.load(Ordering::Relaxed) { return None; }
    let anchor = *habitat.anchor.lock().unwrap();
    anchor
}

#[tauri::command]
pub async fn companions_configure(app: AppHandle, enabled: bool, count: usize) -> Option<Surface> {
    #[cfg(target_os = "linux")]
    { native::configure(&app, enabled, count.min(64)).await }
    #[cfg(not(target_os = "linux"))]
    { let _ = (app, enabled, count); None }
}

/// Sanitize even the private webview's coordinates before calling GTK.
fn clip_rects(rects: Vec<(f64, f64, f64, f64)>, surface: Surface) -> Vec<(f64, f64, f64, f64)> {
    rects.into_iter().take(1024).filter_map(|(x, y, w, h)| {
        if ![x, y, w, h].iter().all(|v| v.is_finite()) || w <= 0.0 || h <= 0.0 { return None; }
        let left = x.max(0.0);
        let top = y.max(0.0);
        let right = (x + w).min(surface.width);
        let bottom = (y + h).min(surface.height);
        (right > left && bottom > top).then_some((left, top, right - left, bottom - top))
    }).collect()
}

#[tauri::command]
pub fn companions_input(app: AppHandle, rects: Vec<(f64, f64, f64, f64)>) {
    let habitat = app.state::<Habitat>();
    let rects = if habitat.enabled.load(Ordering::Relaxed) {
        clip_rects(rects, habitat.surface.lock().unwrap().clone())
    } else { Vec::new() };
    #[cfg(target_os = "linux")]
    if let Some(win) = app.get_webview_window(LABEL) {
        let _ = app.run_on_main_thread(move || crate::platform::set_companions_input(&win, rects));
    }
    #[cfg(not(target_os = "linux"))]
    let _ = rects;
}

/// Reposition an already open card when the bar's occupied areas change.
/// This never opens a card or changes its integration/view.
#[tauri::command]
pub fn companions_anchor(app: AppHandle, x: f64, y: f64) {
    let habitat = app.state::<Habitat>();
    if !habitat.enabled.load(Ordering::Relaxed) || !x.is_finite() || !y.is_finite() { return; }
    let surface = habitat.surface.lock().unwrap().clone();
    if x < 0.0 || x > surface.width || y < 0.0 || y > surface.height { return; }
    *habitat.anchor.lock().unwrap() = Some((x,y+surface.top));
    crate::reposition(app.clone(), app.state::<crate::Shared>());
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct OpenPet { pill_id: String, view: Option<String> }

#[tauri::command]
pub fn companions_open(app: AppHandle, pill_id: String, x: f64, y: f64, view: Option<String>) {
    let habitat = app.state::<Habitat>();
    if !habitat.enabled.load(Ordering::Relaxed) || !x.is_finite() || !y.is_finite() { return; }
    let surface = habitat.surface.lock().unwrap().clone();
    if x < 0.0 || x > surface.width || y < 0.0 || y > surface.height { return; }
    *habitat.anchor.lock().unwrap() = Some((x, y + surface.top));
    // Wake the receiving webview before routing the click, including recovery
    // from a version that hid it instead of mapping a transparent strip.
    crate::set_collapsed(app.clone(), app.state::<crate::Shared>(), false);
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "companions-open", OpenPet { pill_id, view: view.filter(|v| v.len() <= 32) });
}

#[cfg(target_os = "linux")]
mod native {
    use super::*;
    use gtk::gio;
    use gtk::gio::prelude::*;
    use std::cell::RefCell;
    thread_local! { static BAR_WATCH: RefCell<Option<gio::FileMonitor>> = const { RefCell::new(None) }; }

    fn bar_path() -> Option<std::path::PathBuf> {
        Some(std::path::PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR")?).join("coucou-bar-space.json"))
    }
    pub fn watch_bar(app: &AppHandle) {
        let Some(path) = bar_path() else { return };
        let Ok(monitor) = gio::File::for_path(path.parent().unwrap()).monitor_directory(gio::FileMonitorFlags::NONE, gio::Cancellable::NONE) else { return };
        let app = app.clone();
        monitor.connect_changed(move |_, file, other, event| {
            let matches = |f: &gio::File| f.basename().is_some_and(|n| n == std::path::Path::new("coucou-bar-space.json"));
            if !matches(file) && !other.is_some_and(matches) { return; }
            if matches!(event, gio::FileMonitorEvent::ChangesDoneHint | gio::FileMonitorEvent::Created | gio::FileMonitorEvent::Deleted | gio::FileMonitorEvent::MovedIn | gio::FileMonitorEvent::Renamed) {
                let _ = app.emit_to(crate::island::WINDOW_LABEL, "companions-layout-changed", ());
            }
        });
        BAR_WATCH.with(|slot| *slot.borrow_mut() = Some(monitor));
    }
    fn bar_band(screen: &island::ScreenInfo) -> Option<Band> {
        use std::io::Read;
        let mut bytes = Vec::new();
        std::fs::File::open(bar_path()?).ok()?.take(65537).read_to_end(&mut bytes).ok()?;
        if bytes.len() > 65536 { return None; }
        let value: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
        if value["version"] != 1 { return None; }
        let bar = value["bars"].as_array()?.iter().find(|b|
            b["x"].as_f64().is_some_and(|v| (v - screen.x).abs() < 2.0) &&
            b["y"].as_f64().is_some_and(|v| (v - screen.y).abs() < 2.0) &&
            b["width"].as_f64().is_some_and(|v| (v - screen.width).abs() < 2.0))?;
        let height = bar["bandHeight"].as_f64()?;
        if !(24.0..=80.0).contains(&height) { return None; }
        let mut occupied = Vec::new();
        for r in bar["occupied"].as_array()?.iter().take(64) {
            let x = r["x"].as_f64()?; let w = r["w"].as_f64()?;
            if !x.is_finite() || !w.is_finite() || w < 0.0 { return None; }
            if w > 0.0 { occupied.push(((x - 10.0).max(0.0), (x + w + 10.0).min(screen.width))); }
        }
        occupied.sort_by(|a,b| a.0.total_cmp(&b.0));
        let mut start = 8.0_f64;
        let mut lanes = Vec::new();
        for (left, right) in occupied {
            if left - start >= 48.0 { lanes.push((start, left)); }
            start = start.max(right);
        }
        if screen.width - 8.0 - start >= 48.0 { lanes.push((start, screen.width - 8.0)); }
        Some(Band { height, lanes })
    }
    use crate::{island, platform, Shared};
    use tauri::{LogicalSize, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

    pub fn create(app: &AppHandle) {
        let mode = platform::desktop_mode();
        if mode == platform::DesktopMode::Off { return; }
        #[allow(unused_mut)]
        let mut url = WebviewUrl::App("companions.html".into());
        #[cfg(dev)]
        if let Some(mut base) = app.config().build.dev_url.clone() {
            base.set_path("/companions.html");
            url = WebviewUrl::External(base);
        }
        match WebviewWindowBuilder::new(app, LABEL, url)
            .additional_browser_args(crate::BROWSER_ARGS)
            .title("Coucou companions").inner_size(640.0, 240.0)
            .resizable(true).decorations(false).transparent(true).shadow(false)
            .always_on_top(true).skip_taskbar(true).visible_on_all_workspaces(true)
            .focusable(false).focused(false).visible(false)
            .maximizable(false).minimizable(false).closable(false).disable_drag_drop_handler().build() {
            Ok(win) => {
                if !platform::prepare_companions_window(&win, mode) { let _ = win.destroy(); }
            }
            Err(error) => crate::log::line(format!("companions window: {error}")),
        }
    }

    pub async fn configure(app: &AppHandle, enabled: bool, count: usize) -> Option<Surface> {
        let win = app.get_webview_window(LABEL)?;
        let habitat = app.state::<Habitat>();
        if !enabled {
            habitat.enabled.store(false, Ordering::Relaxed);
            crate::flow::pill::update(app, |_| {});
            *habitat.anchor.lock().unwrap() = None;
            let win2 = win.clone();
            let _ = app.run_on_main_thread(move || platform::set_companions_input(&win2, Vec::new()));
            let _ = win.hide();
            return Some(habitat.surface.lock().unwrap().clone());
        }
        let (pref, clearance, bar_mode) = {
            let shared = app.state::<Shared>();
            let settings = shared.settings.lock().unwrap();
            (settings.screen.clone(), settings.companion_top_clearance, settings.companion_bar_mode)
        };
        let screen = island::screen_info(app, &pref);
        let band = bar_mode.then(|| bar_band(&screen).unwrap_or(Band { height: 40.0, lanes: Vec::new() }));
        let top = if bar_mode { 0.0 } else if clearance.is_finite() { clearance.clamp(0.0, 240.0) } else { 64.0 };
        let width = screen.width.max(80.0);
        let columns = ((width - 16.0) / 76.0).floor().max(1.0) as usize;
        let rows = count.max(1).div_ceil(columns);
        let surface = Surface {
            width,
            // Room for a context menu, without making any of it an input area.
            height: if bar_mode { 320.0 } else { (rows as f64 * 76.0 + 180.0).min(screen.height - top).max(88.0) }, top, band,
        };
        *habitat.surface.lock().unwrap() = surface.clone();
        let mode = app.state::<std::sync::Arc<crate::desktop::Desktop>>().mode;
        if mode == platform::DesktopMode::Layer {
            let island = island::window(app)?;
            let win2 = win.clone();
            let (tx, rx) = tokio::sync::oneshot::channel();
            let _ = app.run_on_main_thread(move || {
                let ok = platform::layer_display(&island, &win2).is_some();
                platform::set_layer_margins(&win2, 0.0, top);
                let _ = tx.send(ok);
            });
            if !rx.await.unwrap_or(false) { return None; }
        } else {
            let _ = win.set_position(PhysicalPosition::new(
                (screen.x * screen.scale).round() as i32,
                ((screen.y + top) * screen.scale).round() as i32,
            ));
        }
        if win.set_size(LogicalSize::new(surface.width, surface.height)).is_err() { return None; }
        habitat.enabled.store(true, Ordering::Relaxed);
        crate::flow::pill::update(app, |_| {});
        if win.show().is_err() { habitat.enabled.store(false, Ordering::Relaxed); return None; }
        Some(surface)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn input_cannot_escape_the_habitat() {
        let surface = Surface { width: 200.0, height: 100.0, top: 64.0, band: None };
        assert_eq!(clip_rects(vec![(-10.0, -5.0, 30.0, 20.0), (190.0, 90.0, 80.0, 80.0)], surface.clone()),
            vec![(0.0, 0.0, 20.0, 15.0), (190.0, 90.0, 10.0, 10.0)]);
        assert!(clip_rects(vec![(f64::NAN, 0.0, 10.0, 10.0), (0.0, 0.0, -1.0, 4.0), (250.0, 0.0, 5.0, 5.0)], surface).is_empty());
    }
}
