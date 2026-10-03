// Roaming Mochi on Linux. Same overlay page and events as Windows (roam.rs),
// fed differently, because Wayland gives an app no global cursor, keys or
// screen:
//   * the overlay is a transparent layer-shell surface covering the whole
//     monitor, above everything; clicks pass through it (empty input region)
//     but it takes the keyboard while Mochi roams, so Esc cancels;
//   * while the button is still held from pressing Mochi, the compositor keeps
//     sending the pointer to the island (an implicit grab), so the island page
//     forwards it here (`roam_pointer`) until the release drops Mochi;
//   * the screenshot comes from the desktop's own tool: spectacle on KDE,
//     gnome-screenshot on GNOME, grim on wlroots compositors (Sway, Hyprland,
//     COSMIC…), and import / scrot on X11.

use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, WebviewWindowBuilder};

use crate::shot::{crop_png, Area};
use crate::{island, log, platform};

pub const LABEL: &str = "roam";

static ACTIVE: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Serialize)]
struct Point {
    x: f64,
    y: f64,
}

/// Created hidden at launch next to the settings window (see
/// `create_settings_window` for why windows can't be created later).
pub fn create_window(app: &AppHandle, url: tauri::WebviewUrl, browser_args: &str) {
    match WebviewWindowBuilder::new(app, LABEL, url)
        .additional_browser_args(browser_args)
        .title("Coucou Mochi")
        .transparent(true)
        .decorations(false)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .focused(false)
        .visible(false)
        .build()
    {
        Ok(win) => platform::make_roam_overlay(&win),
        Err(err) => log::line(format!("roam window failed: {err}")),
    }
}

/// Where the island window's top-left corner is on its monitor, in logical
/// pixels: the island page's coordinates plus this are the overlay's.
fn island_origin(app: &AppHandle) -> (f64, f64) {
    let Some(win) = island::window(app) else { return (0.0, 0.0) };
    let scale = win.scale_factor().unwrap_or(1.0);
    let monitor = win.current_monitor().ok().flatten();
    if platform::island_is_layer_surface() {
        // Anchored to the top edge and centred by the compositor.
        let iw = win.inner_size().map(|s| s.width as f64 / scale).unwrap_or(0.0);
        let mw = monitor.map(|m| m.size().width as f64 / m.scale_factor()).unwrap_or(iw);
        ((mw - iw) / 2.0, 0.0)
    } else {
        // A regular window: exact on X11; Wayland only reports 0,0.
        let p = win.outer_position().map(|p| (p.x as f64, p.y as f64)).unwrap_or((0.0, 0.0));
        let m = monitor.map(|m| (m.position().x as f64, m.position().y as f64)).unwrap_or((0.0, 0.0));
        ((p.0 - m.0) / scale, (p.1 - m.1) / scale)
    }
}

/// Mochi has been dragged out of the island: show the overlay over the
/// island's monitor and hand it Mochi. The island then feeds the pointer.
#[tauri::command]
pub fn roam_start(app: AppHandle, look: Option<serde_json::Value>) {
    if ACTIVE.swap(true, Ordering::SeqCst) {
        return;
    }
    let (Some(win), Some(isl)) = (app.get_webview_window(LABEL), island::window(&app)) else {
        ACTIVE.store(false, Ordering::SeqCst);
        let _ = app.emit_to(island::WINDOW_LABEL, "roam-end", None::<String>);
        return;
    };
    platform::show_roam_overlay(&win, &isl);
    // Mochi leaves from just under the island; the next pointer event moves it.
    let (ox, oy) = island_origin(&app);
    let scale = isl.scale_factor().unwrap_or(1.0);
    let iw = isl.inner_size().map(|s| s.width as f64 / scale).unwrap_or(0.0);
    let _ = app.emit_to(
        LABEL,
        "roam-begin",
        serde_json::json!({ "x": ox + iw / 2.0, "y": oy + 30.0, "look": look }),
    );
}

/// The island's pointer while Mochi is carried, in the island page's own
/// coordinates: `phase` is "move", "drop" (button released) or "cancel"
/// (right button).
#[tauri::command]
pub fn roam_pointer(app: AppHandle, x: f64, y: f64, phase: String) {
    if !ACTIVE.load(Ordering::SeqCst) {
        return;
    }
    let (ox, oy) = island_origin(&app);
    let at = Point { x: ox + x, y: oy + y };
    let _ = match phase.as_str() {
        "move" => app.emit_to(LABEL, "roam-cursor", at),
        "drop" => app.emit_to(LABEL, "roam-drop", at),
        _ => app.emit_to(LABEL, "roam-cancel", ()),
    };
}

/// Captures the screen, or only `area` of it (the overlay has already hidden
/// Mochi for this frame), and returns the path of the PNG. The tools only take
/// the whole screen, so an area is cut out of that afterwards.
// ponytail: assumes the tool captured just this monitor (spectacle -m does);
// on multi-monitor GNOME/grim the crop lands off, pass grim -g if that matters.
#[tauri::command]
pub async fn roam_capture(_app: AppHandle, area: Option<Area>) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let path = std::env::temp_dir().join("coucou-screenshot.png");
        capture(&path)?;
        if let Some(area) = area {
            crop_png(&path, area)?;
        }
        Ok(path.to_string_lossy().into_owned())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Mochi is back in the island: hide the overlay and hand the screenshot over.
#[tauri::command]
pub fn roam_end(app: AppHandle, path: Option<String>) {
    if let Some(win) = app.get_webview_window(LABEL) {
        platform::hide_roam_overlay(&win);
    }
    ACTIVE.store(false, Ordering::SeqCst);
    let _ = app.emit_to(island::WINDOW_LABEL, "roam-end", path);
}

/// The desktop's screenshot tool, best match first; the first that writes a
/// file wins.
fn capture(path: &Path) -> Result<(), String> {
    let owned = path.to_string_lossy().into_owned();
    let out = owned.as_str();
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_lowercase();
    let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some();
    let x11 = std::env::var_os("DISPLAY").is_some();

    let spectacle = ("spectacle", vec!["-b", "-n", "-m", "-o", out]);
    let gnome = ("gnome-screenshot", vec!["-f", out]);
    let grim = ("grim", vec![out]);
    let mut tries = Vec::new();
    if desktop.contains("kde") {
        tries.push(spectacle.clone());
    }
    if desktop.contains("gnome") {
        tries.push(gnome.clone());
    }
    if wayland {
        tries.push(grim);
    }
    tries.push(spectacle);
    tries.push(gnome);
    if x11 {
        tries.push(("import", vec!["-window", "root", out]));
        tries.push(("scrot", vec!["-o", out]));
    }

    let mut tried = Vec::new();
    for (tool, args) in tries {
        if tried.contains(&tool) || platform::find_on_path(tool).is_none() {
            continue;
        }
        tried.push(tool);
        let _ = std::fs::remove_file(path);
        match Command::new(tool).args(&args).status() {
            Ok(status) if status.success() && wait_for_file(path) => {
                log::line(format!("roam screenshot by {tool}"));
                return Ok(());
            }
            Ok(status) => log::line(format!("roam screenshot: {tool} failed ({status})")),
            Err(err) => log::line(format!("roam screenshot: {tool} didn't run ({err})")),
        }
    }
    Err(if tried.is_empty() {
        "no screenshot tool found: install grim (Sway, Hyprland, COSMIC), spectacle (KDE) or gnome-screenshot (GNOME)"
            .into()
    } else {
        format!("the screenshot failed (tried {})", tried.join(", "))
    })
}

/// Some tools return before the file is fully written.
fn wait_for_file(path: &Path) -> bool {
    let until = Instant::now() + Duration::from_secs(3);
    while Instant::now() < until {
        if std::fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false) {
            std::thread::sleep(Duration::from_millis(80));
            return true;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    false
}
