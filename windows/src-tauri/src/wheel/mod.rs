// The wheel: drop files on the notch's Tools zone and a ring of choices opens on
// the screen around the pointer (Tangerine's wheel): Convert, Tools, Actions.
// Everything runs on this computer; the results go next to the originals.

pub mod actions;
pub mod formats;
pub mod image_ops;
pub mod pdf;

use std::path::PathBuf;
use std::sync::Mutex;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "wheel";
/// The wheel's window, in logical pixels (square).
const SIZE: f64 = 500.0;

/// The files on the wheel now.
static FILES: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());
/// What the wheel was last opened with: its page, made just now, may not have
/// been listening yet and asks (wheel_current).
static OPENED: Mutex<Option<Opened>> = Mutex::new(None);

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct FileInfo {
    path: String,
    name: String,
    size: u64,
    is_dir: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Opened {
    files: Vec<FileInfo>,
    rings: formats::Rings,
}

fn files() -> Vec<PathBuf> {
    FILES.lock().unwrap().clone()
}

fn window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    if let Some(w) = app.get_webview_window(LABEL) {
        return Some(w);
    }
    WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("wheel.html".into()))
        .title("Coucou")
        .inner_size(SIZE, SIZE)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .focused(true)
        .build()
        .ok()
}

/// The window's top-left so that it is centred on the pointer, inside its screen.
fn place_at_pointer(win: &tauri::WebviewWindow) {
    let Some((cx, cy)) = crate::platform::cursor_physical() else {
        let _ = win.center();
        return;
    };
    let scale = win.scale_factor().unwrap_or(1.0);
    let side = SIZE * scale;
    let (mut x, mut y) = (cx - side / 2.0, cy - side / 2.0);
    if let Ok(Some(m)) = win.monitor_from_point(cx, cy) {
        let (mx, my) = (m.position().x as f64, m.position().y as f64);
        let (mw, mh) = (m.size().width as f64, m.size().height as f64);
        x = x.clamp(mx, (mx + mw - side).max(mx));
        y = y.clamp(my, (my + mh - side).max(my));
    }
    let _ = win.set_position(PhysicalPosition::new(x.round() as i32, y.round() as i32));
}

/// Files dropped on the Tools zone: the wheel opens around the pointer.
#[tauri::command]
pub async fn wheel_open(app: AppHandle, paths: Vec<String>) -> Result<(), String> {
    let list: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).filter(|p| p.exists()).collect();
    if list.is_empty() {
        return Err("nothing to open".into());
    }
    let refs: Vec<&std::path::Path> = list.iter().map(|p| p.as_path()).collect();
    let rings = formats::rings(&refs);
    let infos = list
        .iter()
        .map(|p| FileInfo {
            path: p.display().to_string(),
            name: p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
            size: std::fs::metadata(p).map(|m| m.len()).unwrap_or(0),
            is_dir: p.is_dir(),
        })
        .collect();
    *FILES.lock().unwrap() = list;
    let opened = Opened { files: infos, rings };
    *OPENED.lock().unwrap() = Some(opened.clone());
    let win = window(&app).ok_or("no wheel window")?;
    place_at_pointer(&win);
    let _ = win.emit_to(LABEL, "wheel-open", opened);
    let _ = win.show();
    let _ = win.set_focus();
    crate::log::line("wheel: opened".to_string());
    Ok(())
}

/// What is on the wheel, for its page's first load.
#[tauri::command]
pub fn wheel_current() -> Option<Opened> {
    OPENED.lock().unwrap().clone()
}

#[tauri::command]
pub fn wheel_close(app: AppHandle) {
    if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.hide();
    }
}

/// The first image, small, for the wheel's middle.
#[tauri::command]
pub async fn wheel_preview(path: String, max: Option<u32>) -> Option<String> {
    let path = PathBuf::from(path);
    if formats::kind_of(&path) != formats::Kind::Image {
        return None;
    }
    tauri::async_runtime::spawn_blocking(move || image_ops::preview(&path, max.unwrap_or(240))).await.ok().flatten()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RunResult {
    /// What was made (or where the files went).
    outputs: Vec<String>,
    /// The files' sizes before and after, for "2.2 MB → 640 KB".
    before: u64,
    after: u64,
    /// True when the user cancelled (a folder picker closed).
    cancelled: bool,
}

fn size_of(paths: &[PathBuf]) -> u64 {
    paths.iter().filter_map(|p| std::fs::metadata(p).ok()).map(|m| m.len()).sum()
}

fn done(inputs: &[PathBuf], outputs: Vec<PathBuf>) -> RunResult {
    RunResult {
        before: size_of(inputs),
        after: size_of(&outputs),
        outputs: outputs.iter().map(|p| p.display().to_string()).collect(),
        cancelled: false,
    }
}

/// One choice on the wheel: `ring` is "convert", "tools" or "actions", `id` the choice
/// ("webp", "compress", "copyPath"…), `option` its setting (compress: "high", "balanced", "small").
#[tauri::command]
pub async fn wheel_run(ring: String, id: String, option: Option<String>) -> Result<RunResult, String> {
    let paths = files();
    if paths.is_empty() {
        return Err("no file".into());
    }
    let result = tauri::async_runtime::spawn_blocking(move || run(&paths, &ring, &id, option.as_deref()))
        .await
        .map_err(|e| e.to_string())?;
    match &result {
        Ok(r) => crate::log::line(format!("wheel: done, {} result(s)", r.outputs.len())),
        Err(e) => crate::log::line(format!("wheel: failed: {e}")),
    }
    result
}

fn run(paths: &[PathBuf], ring: &str, id: &str, option: Option<&str>) -> Result<RunResult, String> {
    match (ring, id) {
        ("convert", target) if formats::IMAGE_TARGETS.contains(&target) => Ok(done(paths, image_ops::convert(paths, target)?)),
        ("tools", "compress") => Ok(done(paths, image_ops::compress(paths, option.unwrap_or("balanced"))?)),
        ("tools", "metadata") => Ok(done(paths, image_ops::remove_metadata(paths)?)),
        ("tools", "mergePdf") => Ok(done(paths, image_ops::merge_pdf(paths)?)),
        ("actions", "copy") => actions::copy(paths).map(|_| done(paths, Vec::new())),
        ("actions", "copyPath") => actions::copy_path(paths).map(|_| done(paths, Vec::new())),
        ("actions", "move") => match actions::move_to(paths)? {
            Some(moved) => {
                // The wheel now holds them where they went.
                *FILES.lock().unwrap() = moved.clone();
                Ok(done(&moved, moved.clone()))
            }
            None => Ok(RunResult { outputs: Vec::new(), before: 0, after: 0, cancelled: true }),
        },
        ("actions", "terminal") => actions::terminal(&paths[0]).map(|_| done(paths, Vec::new())),
        ("actions", "reveal") => actions::reveal(&paths[0]).map(|_| done(paths, Vec::new())),
        _ => Err(format!("{ring}/{id} isn't available for this file yet")),
    }
}

/// What the editor window made, saved next to the original.
#[tauri::command]
pub async fn wheel_save_edit(path: String, suffix: String, data_url: String) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || image_ops::save_edit(std::path::Path::new(&path), &suffix, &data_url))
        .await
        .map_err(|e| e.to_string())?
        .map(|p| p.display().to_string())
}

/// A result, selected in Explorer.
#[tauri::command]
pub fn wheel_reveal(path: String) -> Result<(), String> {
    actions::reveal(std::path::Path::new(&path))
}

// ── The editor window (crop, edit, annotate, redact, background) ─────────────

pub const EDITOR_LABEL: &str = "editor";
/// The image being edited, and with which tool.
static EDITING: Mutex<Option<(PathBuf, String)>> = Mutex::new(None);

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Editing {
    path: String,
    name: String,
    tool: String,
    /// The image, as large as the editor works with.
    image: String,
}

/// The editor for the wheel's image: its window opens on `tool`.
#[tauri::command]
pub async fn wheel_editor(app: AppHandle, tool: String) -> Result<(), String> {
    let path = files().into_iter().next().ok_or("no image")?;
    *EDITING.lock().unwrap() = Some((path, tool));
    if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.hide();
    }
    if let Some(w) = app.get_webview_window(EDITOR_LABEL) {
        let _ = w.close();
    }
    WebviewWindowBuilder::new(&app, EDITOR_LABEL, WebviewUrl::App("editor.html".into()))
        .title("Coucou")
        .inner_size(1120.0, 780.0)
        .min_inner_size(640.0, 460.0)
        .center()
        .always_on_top(true)
        .focused(true)
        .background_color(tauri::window::Color(14, 15, 17, 255))
        .build()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// What the editor works on (asked once its page is up).
#[tauri::command]
pub async fn wheel_editing() -> Option<Editing> {
    let (path, tool) = EDITING.lock().unwrap().clone()?;
    let p = path.clone();
    let image = tauri::async_runtime::spawn_blocking(move || image_ops::preview(&p, 6000)).await.ok().flatten()?;
    Some(Editing {
        path: path.display().to_string(),
        name: path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        tool,
        image,
    })
}

/// The editor is done: its image (a PNG data URL) saved next to the original, or
/// nothing (cancelled). The path saved, for "Show in Explorer".
#[tauri::command]
pub async fn wheel_editor_done(app: AppHandle, data_url: Option<String>) -> Result<Option<String>, String> {
    let editing = EDITING.lock().unwrap().clone();
    let result = match (editing, data_url) {
        (Some((path, tool)), Some(data)) => {
            let suffix = match tool.as_str() {
                "crop" => "cropped",
                "edit" => "edited",
                "annotate" => "annotated",
                "redact" => "redacted",
                _ => "background",
            }
            .to_string();
            let saved = tauri::async_runtime::spawn_blocking(move || image_ops::save_edit(&path, &suffix, &data))
                .await
                .map_err(|e| e.to_string())??;
            crate::log::line("wheel: editor saved".to_string());
            Some(saved.display().to_string())
        }
        _ => {
            if let Some(w) = app.get_webview_window(EDITOR_LABEL) {
                let _ = w.close();
            }
            None
        }
    };
    Ok(result)
}

/// The editor's window closes.
#[tauri::command]
pub fn wheel_editor_close(app: AppHandle) {
    if let Some(w) = app.get_webview_window(EDITOR_LABEL) {
        let _ = w.close();
    }
}
