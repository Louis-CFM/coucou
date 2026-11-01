// The wheel: drop files on the notch's Tools zone and a ring of choices opens in
// the middle of the screen (Tangerine's wheel): Convert, Tools, Actions.
// Everything runs on this computer; the results go next to the originals.

pub mod actions;
pub mod documents;
pub mod formats;
mod glass;
pub mod image_ops;
pub mod media;
pub mod pdf;

use std::path::PathBuf;
use std::sync::Mutex;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "wheel";
/// The wheel's window, in logical pixels: the disc, and the ring switcher under it
/// (src/wheel/wheel.css keeps the same numbers).
const WIDTH: f64 = 272.0;
const HEIGHT: f64 = 300.0;
/// The disc's centre and radius in the window.
const CX: f64 = 136.0;
const CY: f64 = 132.0;
const DISC: f64 = 130.0;
/// The ring switcher: left, top, right, bottom, corner radius.
const BAR: (f64, f64, f64, f64, f64) = (26.0, 270.0, 246.0, 296.0, 26.0);
/// Where the hidden wheel waits: off the screen. A hidden WebView2 still sets
/// the cursor for its page where its rectangle is (claude_account.rs).
const AWAY: (i32, i32) = (-32000, -32000);

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
    /// What is on the screen where the wheel opens, taken just before: the
    /// page blurs it behind the disc, its liquid glass. In memory only.
    backdrop: Option<String>,
}

fn files() -> Vec<PathBuf> {
    FILES.lock().unwrap().clone()
}

fn window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    if let Some(w) = app.get_webview_window(LABEL) {
        return Some(w);
    }
    let win = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("wheel.html".into()))
        .title("Coucou")
        .inner_size(WIDTH, HEIGHT)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible(false)
        .focused(true)
        .build()
        .ok()?;
    let _ = win.set_position(PhysicalPosition::new(AWAY.0, AWAY.1));
    Some(win)
}

/// The window takes the wheel's shape — its disc and the ring switcher — so the
/// glass is only there and the corners let clicks through to what is under them.
#[cfg(windows)]
fn shape(win: &tauri::WebviewWindow) {
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Gdi::{CombineRgn, CreateEllipticRgn, CreateRoundRectRgn, DeleteObject, SetWindowRgn, RGN_OR};
    let Ok(raw) = win.hwnd() else { return };
    let hwnd = HWND(raw.0 as *mut _);
    let s = win.scale_factor().unwrap_or(1.0);
    let px = |v: f64| (v * s).round() as i32;
    unsafe {
        let disc = CreateEllipticRgn(px(CX - DISC), px(CY - DISC), px(CX + DISC) + 1, px(CY + DISC) + 1);
        let bar = CreateRoundRectRgn(px(BAR.0), px(BAR.1), px(BAR.2) + 1, px(BAR.3) + 1, px(BAR.4), px(BAR.4));
        let _ = CombineRgn(Some(disc), Some(disc), Some(bar), RGN_OR);
        let _ = DeleteObject(bar.into());
        // The window owns the region from here.
        SetWindowRgn(hwnd, Some(disc), true);
    }
}

#[cfg(not(windows))]
fn shape(_win: &tauri::WebviewWindow) {}

/// The window placed so the disc is in the middle of the screen the pointer is
/// on (clear of the notch, whose window would take the clicks above it); where
/// it went, in physical pixels.
fn place_in_middle(win: &tauri::WebviewWindow) -> (i32, i32) {
    let scale = win.scale_factor().unwrap_or(1.0);
    let monitor = crate::platform::cursor_physical()
        .and_then(|(x, y)| win.monitor_from_point(x, y).ok().flatten())
        .or_else(|| win.primary_monitor().ok().flatten());
    let Some(m) = monitor else {
        let _ = win.center();
        return win.outer_position().map(|p| (p.x, p.y)).unwrap_or((0, 0));
    };
    let (mx, my) = (m.position().x as f64, m.position().y as f64);
    let (mw, mh) = (m.size().width as f64, m.size().height as f64);
    let x = mx + mw / 2.0 - CX * scale;
    let y = my + mh / 2.0 - CY * scale;
    let (x, y) = (x.round() as i32, y.round() as i32);
    let _ = win.set_position(PhysicalPosition::new(x, y));
    (x, y)
}

/// Files dropped on the Tools zone: the wheel opens in the middle of the screen.
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
    let win = window(&app).ok_or("no wheel window")?;
    if win.is_visible().unwrap_or(false) {
        // Opened again while it shows: out of the way first, or its glass would
        // be a picture of the wheel itself. Moved, not hidden: hidden, its page
        // would lose focus and close it just after it opens again.
        let _ = win.set_position(PhysicalPosition::new(AWAY.0, AWAY.1));
        tokio::time::sleep(std::time::Duration::from_millis(120)).await;
    }
    let (x, y) = place_in_middle(&win);
    // Again each time: the region is in pixels, and the screen's scale may differ.
    shape(&win);
    let scale = win.scale_factor().unwrap_or(1.0);
    let (w, h) = ((WIDTH * scale).round() as i32, (HEIGHT * scale).round() as i32);
    let backdrop = tauri::async_runtime::spawn_blocking(move || glass::behind(x, y, w, h)).await.ok().flatten();
    let opened = Opened { files: infos, rings, backdrop };
    *OPENED.lock().unwrap() = Some(opened.clone());
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
        let _ = w.set_position(PhysicalPosition::new(AWAY.0, AWAY.1));
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
pub async fn wheel_run(app: AppHandle, ring: String, id: String, option: Option<String>) -> Result<RunResult, String> {
    let paths = files();
    if paths.is_empty() {
        return Err("no file".into());
    }
    let result = tauri::async_runtime::spawn_blocking(move || {
        let progress = progress_to(&app, LABEL);
        run(&paths, &ring, &id, option.as_deref(), &progress)
    })
    .await
    .map_err(|e| e.to_string())?;
    match &result {
        Ok(r) => crate::log::line(format!("wheel: done, {} result(s)", r.outputs.len())),
        Err(e) => crate::log::line(format!("wheel: failed: {e}")),
    }
    result
}

/// Sends how far along the work is (0..=1) to a window, at most once a percent.
fn progress_to(app: &AppHandle, label: &'static str) -> impl Fn(f64) {
    let app = app.clone();
    let last = std::sync::atomic::AtomicI32::new(-1);
    move |p: f64| {
        let pct = (p * 100.0).round() as i32;
        if last.swap(pct, std::sync::atomic::Ordering::Relaxed) != pct {
            let _ = app.emit_to(label, "wheel-progress", p);
        }
    }
}

fn run(paths: &[PathBuf], ring: &str, id: &str, option: Option<&str>, progress: &dyn Fn(f64)) -> Result<RunResult, String> {
    let kind = formats::kind_of(&paths[0]);
    let media = matches!(kind, formats::Kind::Video | formats::Kind::Audio);
    // Video and sound need FFmpeg: the wheel offers to get it.
    if media && ring != "actions" && !media::ready() {
        return Err("needs-ffmpeg".into());
    }
    if matches!(kind, formats::Kind::Document | formats::Kind::Pdf) {
        match (ring, id) {
            ("convert", target) => return Ok(done(paths, documents::convert(paths, target, progress)?)),
            ("tools", "metadata") => return Ok(done(paths, documents::remove_metadata(paths, progress)?)),
            _ => {}
        }
    }
    if media {
        match (ring, id) {
            ("convert", target) => return Ok(done(paths, media::convert(paths, target, progress)?)),
            ("tools", "compress") => return Ok(done(paths, media::compress(paths, option.unwrap_or("balanced"), progress)?)),
            ("tools", "mute") => return Ok(done(paths, media::mute(paths, progress)?)),
            _ => {}
        }
    }
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
    /// The image, as large as the editor works with (trimming: a video's first frame, or "").
    image: String,
    /// Trimming: the file's length in seconds.
    duration: Option<f64>,
}

/// The editor for the wheel's file: its window opens on `tool`.
#[tauri::command]
pub async fn wheel_editor(app: AppHandle, tool: String) -> Result<(), String> {
    let path = files().into_iter().next().ok_or("no file")?;
    if tool == "trim" && !media::ready() {
        return Err("needs-ffmpeg".into());
    }
    *EDITING.lock().unwrap() = Some((path, tool));
    if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.hide();
        let _ = w.set_position(PhysicalPosition::new(AWAY.0, AWAY.1));
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

/// What the editor works on (asked once its page is up). For trimming, the
/// length and the first frame (none for a sound) instead of a full image.
#[tauri::command]
pub async fn wheel_editing() -> Option<Editing> {
    let (path, tool) = EDITING.lock().unwrap().clone()?;
    let p = path.clone();
    let trimming = tool == "trim";
    let (image, duration) = tauri::async_runtime::spawn_blocking(move || {
        if trimming {
            let length = media::duration(&p);
            let picture = if media::has_video(&p) { media::frame(&p, 0.0, 1280) } else { None };
            Some((picture.unwrap_or_default(), length))
        } else {
            image_ops::preview(&p, 6000).map(|i| (i, None))
        }
    })
    .await
    .ok()
    .flatten()?;
    Some(Editing {
        path: path.display().to_string(),
        name: path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        tool,
        image,
        duration,
    })
}

/// A frame of the video being trimmed, at `at` seconds.
#[tauri::command]
pub async fn wheel_frame(at: f64) -> Option<String> {
    let (path, _) = EDITING.lock().unwrap().clone()?;
    tauri::async_runtime::spawn_blocking(move || media::frame(&path, at, 1280)).await.ok().flatten()
}

/// The trim editor's Save: from `start` to `end` seconds, next to the original.
#[tauri::command]
pub async fn wheel_trim(app: AppHandle, start: f64, end: f64) -> Result<String, String> {
    let (path, _) = EDITING.lock().unwrap().clone().ok_or("nothing to trim")?;
    tauri::async_runtime::spawn_blocking(move || {
        let progress = progress_to(&app, EDITOR_LABEL);
        media::trim(&path, start, end, &progress)
    })
    .await
    .map_err(|e| e.to_string())?
    .map(|p| p.display().to_string())
}

/// FFmpeg, fetched once (about 110 MB): the wheel shows how far along it is.
#[tauri::command]
pub async fn wheel_ffmpeg_install(app: AppHandle) -> Result<(), String> {
    let progress = progress_to(&app, LABEL);
    media::install(progress).await
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
