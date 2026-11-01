// Screen capture for Claude — port of ScreenCapture.swift (Mac 0.5.0).
//
// Ctrl+Alt+X: capture a part of the screen (a bug in a page, an error, a
// mock-up), Mochi swallows it, and the island offers what to do with it: paste
// it into the prompt you were typing in, copy it, annotate it, or ask Claude
// about it in the island's chat. With Flow on, holding the dictation key while
// the capture waits on the island pastes the image, then your words.
//
// The selection is Windows' own (the Snipping Tool's overlay, `ms-screenclip:`,
// as the Mac uses `screencapture -i`): drag a zone, or Esc to cancel. It puts
// the image on the clipboard, where Coucou picks it up. The image stays on the
// computer (in the temporary folder); it only goes to Claude when you paste it
// there or ask Claude about it.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

/// How long the overlay is given before Coucou stops waiting for a capture.
const SELECTION_TIMEOUT: Duration = Duration::from_secs(120);
/// A capture older than this no longer goes with a dictation.
const DICTATION_WINDOW: Duration = Duration::from_secs(180);
const KEEP: usize = 20;
pub const ANNOTATE_LABEL: &str = "annotate";

struct Captured {
    path: PathBuf,
    taken: Instant,
    /// The window in front when the capture was taken: the image goes back there.
    target: isize,
    /// Its program ("windowsterminal"), to know which keys paste an image.
    target_app: Option<String>,
    /// The island shows the capture card (set by the page).
    on_island: bool,
}

static CAPTURED: Mutex<Option<Captured>> = Mutex::new(None);
/// Bumped by every new selection, so a forgotten one stops waiting.
static SELECTION: AtomicU64 = AtomicU64::new(0);

/// What the island is told when a capture lands.
#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Ready {
    pub path: String,
    /// The image as a data URL, for the card's thumbnail.
    pub data_url: String,
}

fn folder() -> PathBuf {
    std::env::temp_dir().join("CoucouCaptures")
}

fn stamp() -> String {
    let t = crate::platform::local_time();
    format!("{:04}-{:02}-{:02} at {:02}.{:02}.{:02}", t.year, t.month, t.day, t.hour, t.minute, t.second)
}

/// The terminals where Claude Code takes an image with Alt+V (Ctrl+V pastes text there).
pub fn is_terminal(app: &str) -> bool {
    matches!(
        app,
        "windowsterminal" | "wt" | "openconsole" | "conhost" | "cmd" | "powershell" | "pwsh" | "wezterm-gui"
            | "alacritty" | "mintty" | "hyper" | "tabby" | "warp" | "kitty"
    )
}

// ── Capturing ─────────────────────────────────────────────────────────────────

/// Ctrl+Alt+X or the tray: the island folds, Windows' selection opens, and the
/// image lands on the island when the zone is drawn. Esc: nothing happens.
pub fn begin(app: &AppHandle) {
    if !cfg!(windows) {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, "capture-unavailable", ());
        return;
    }
    let generation = SELECTION.fetch_add(1, Ordering::SeqCst) + 1;
    // The island must not be in the picture (it plays the tick).
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "capture-begin", ());
    let target = os::foreground_window();
    let target_app = crate::flow::os::foreground_app().map(|(id, _)| id);
    let before = os::clipboard_sequence();
    let app = app.clone();
    std::thread::spawn(move || {
        // Let the island fold before the screen is frozen for the selection.
        std::thread::sleep(Duration::from_millis(220));
        crate::platform::open_url("ms-screenclip:");
        crate::log::line("capture: selection started".to_string());
        let started = Instant::now();
        while started.elapsed() < SELECTION_TIMEOUT {
            if SELECTION.load(Ordering::SeqCst) != generation {
                return;
            }
            std::thread::sleep(Duration::from_millis(150));
            if os::clipboard_sequence() == before {
                continue;
            }
            // Something new on the clipboard: an image is the capture; anything
            // else (text copied meanwhile) is not, and the wait goes on.
            let Some(png) = os::clipboard_png() else { continue };
            match save(&png) {
                Ok(path) => land(&app, path, &png, target, target_app),
                Err(err) => crate::log::line(format!("capture: not saved: {err}")),
            }
            return;
        }
        crate::log::line("capture: selection ended without an image".to_string());
    });
}

fn save(png: &[u8]) -> std::io::Result<PathBuf> {
    let dir = folder();
    std::fs::create_dir_all(&dir)?;
    let path = dir.join(format!("Capture {}.png", stamp()));
    std::fs::write(&path, png)?;
    prune(&dir, &path);
    Ok(path)
}

/// Keeps the last 20 captures.
fn prune(dir: &Path, keep: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .flatten()
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    for (_, old) in files.into_iter().skip(KEEP) {
        if old != keep {
            let _ = std::fs::remove_file(old);
        }
    }
}

/// The capture lands on the island: Mochi swallows it.
fn land(app: &AppHandle, path: PathBuf, png: &[u8], target: isize, target_app: Option<String>) {
    let data_url = format!("data:image/png;base64,{}", crate::claude::base64_for(png));
    crate::files::allow_dropped([path.to_string_lossy().to_string()]);
    *CAPTURED.lock().unwrap() =
        Some(Captured { path: path.clone(), taken: Instant::now(), target, target_app, on_island: false });
    crate::log::line("capture: image on the island".to_string());
    let _ = app.emit_to(
        crate::island::WINDOW_LABEL,
        "capture-ready",
        Ready { path: path.to_string_lossy().to_string(), data_url },
    );
}

fn current() -> Option<(PathBuf, isize, Option<String>)> {
    CAPTURED.lock().unwrap().as_ref().map(|c| (c.path.clone(), c.target, c.target_app.clone()))
}

// ── The island's buttons ──────────────────────────────────────────────────────

#[tauri::command]
pub fn capture_begin(app: AppHandle) {
    begin(&app);
}

/// Into the prompt of the app you were in (Ctrl+V, or Alt+V in a terminal,
/// where Claude Code takes images). False when only copied: the page says so.
#[tauri::command]
pub async fn capture_paste() -> bool {
    let Some((path, target, target_app)) = current() else { return false };
    tauri::async_runtime::spawn_blocking(move || {
        let Ok(png) = std::fs::read(&path) else { return false };
        if !os::set_clipboard_png(&png, true) {
            return false;
        }
        os::focus(target);
        std::thread::sleep(Duration::from_millis(250));
        let terminal = target_app.as_deref().is_some_and(is_terminal);
        let pasted = os::send_paste_image(terminal);
        dismiss_inner();
        pasted
    })
    .await
    .unwrap_or(false)
}

#[tauri::command]
pub async fn capture_copy() -> bool {
    let Some((path, _, _)) = current() else { return false };
    tauri::async_runtime::spawn_blocking(move || {
        let ok = std::fs::read(&path).is_ok_and(|png| os::set_clipboard_png(&png, false));
        dismiss_inner();
        ok
    })
    .await
    .unwrap_or(false)
}

/// The card shows the capture (or not): a dictation may take it only then.
#[tauri::command]
pub fn capture_on_island(on: bool) {
    if let Some(c) = CAPTURED.lock().unwrap().as_mut() {
        c.on_island = on;
    }
}

#[tauri::command]
pub fn capture_dismiss() {
    dismiss_inner();
}

fn dismiss_inner() {
    *CAPTURED.lock().unwrap() = None;
}

// ── Annotating ────────────────────────────────────────────────────────────────

/// Opens the annotation window over the capture (arrows, boxes, pen).
#[tauri::command]
pub fn capture_annotate(app: AppHandle) -> Result<(), String> {
    if current().is_none() {
        return Err("no capture".into());
    }
    if let Some(win) = app.get_webview_window(ANNOTATE_LABEL) {
        let _ = win.close();
    }
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "capture-begin", ());
    tauri::WebviewWindowBuilder::new(&app, ANNOTATE_LABEL, tauri::WebviewUrl::App("annotate.html".into()))
        .title(crate::i18n::t("Annotate"))
        .inner_size(1100.0, 760.0)
        .min_inner_size(520.0, 360.0)
        .center()
        .always_on_top(true)
        .focused(true)
        .background_color(tauri::window::Color(0, 0, 0, 255))
        .build()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// The annotation window asks for the image it draws over.
#[tauri::command]
pub fn capture_image() -> Option<String> {
    let (path, _, _) = current()?;
    let png = std::fs::read(path).ok()?;
    Some(format!("data:image/png;base64,{}", crate::claude::base64_for(&png)))
}

/// Done (with the marks drawn into the image) or cancelled (None): the window
/// closes and the capture is back on the island.
#[tauri::command]
pub fn capture_annotated(app: AppHandle, data_url: Option<String>) {
    if let Some(win) = app.get_webview_window(ANNOTATE_LABEL) {
        let _ = win.close();
    }
    let Some((path, target, target_app)) = current() else { return };
    let png = data_url
        .as_deref()
        .and_then(|d| d.strip_prefix("data:image/png;base64,"))
        .and_then(crate::recap::decode_base64);
    let (path, png) = match png {
        Some(png) => {
            let stem = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "Capture".into());
            let annotated = path.with_file_name(format!("{stem} annotated.png"));
            if let Err(err) = std::fs::write(&annotated, &png) {
                crate::log::line(format!("capture: annotated image not saved: {err}"));
                return;
            }
            (annotated, png)
        }
        None => match std::fs::read(&path) {
            Ok(png) => (path, png),
            Err(_) => return,
        },
    };
    os::focus(target);
    land(&app, path, &png, target, target_app);
}

// ── With Flow ─────────────────────────────────────────────────────────────────

/// A capture on the island, fresh and not used yet, goes in before the words of
/// a dictation: pasted where you type. True when pasted (the words follow).
pub fn paste_for_dictation(app: &AppHandle, front_app: Option<&str>) -> bool {
    let path = {
        let guard = CAPTURED.lock().unwrap();
        match guard.as_ref() {
            Some(c) if c.on_island && c.taken.elapsed() < DICTATION_WINDOW => c.path.clone(),
            _ => return false,
        }
    };
    let Ok(png) = std::fs::read(&path) else { return false };
    if !os::set_clipboard_png(&png, true) {
        return false;
    }
    std::thread::sleep(Duration::from_millis(40));
    let pasted = os::send_paste_image(front_app.is_some_and(is_terminal));
    dismiss_inner();
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "capture-used", ());
    // The app reads the image before the words arrive.
    std::thread::sleep(Duration::from_millis(450));
    pasted
}

/// The image on the clipboard, as PNG (the notch's Clipboard keeps a copy).
pub(crate) fn clipboard_image() -> Option<Vec<u8>> {
    os::clipboard_png()
}

/// An image back on the clipboard, for good (clipboard.rs).
pub(crate) fn set_clipboard_image(png: &[u8]) -> bool {
    os::set_clipboard_png(png, false)
}

/// Ctrl+V in the app in front.
pub(crate) fn send_ctrl_v() -> bool {
    os::send_paste_image(false)
}

// ── Windows: clipboard images, keys, windows ──────────────────────────────────

#[cfg(windows)]
mod os {
    use clipboard_win::{formats, raw, register_format, Clipboard};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_CONTROL,
        VK_MENU,
    };
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, IsIconic, SetForegroundWindow, ShowWindow, SW_RESTORE};

    pub fn clipboard_sequence() -> u32 {
        clipboard_win::seq_num().map(|n| n.get()).unwrap_or(0)
    }

    pub fn foreground_window() -> isize {
        unsafe { GetForegroundWindow().0 as isize }
    }

    pub fn focus(raw: isize) {
        if raw == 0 {
            return;
        }
        let hwnd = HWND(raw as *mut _);
        unsafe {
            if IsIconic(hwnd).as_bool() {
                let _ = ShowWindow(hwnd, SW_RESTORE);
            }
            let _ = SetForegroundWindow(hwnd);
        }
    }

    /// The image on the clipboard as PNG: the "PNG" format the Snipping Tool
    /// writes, else the bitmap (CF_DIB) turned into a PNG.
    pub fn clipboard_png() -> Option<Vec<u8>> {
        let _clip = Clipboard::new_attempts(10).ok()?;
        if let Some(png) = register_format("PNG") {
            let mut out = Vec::new();
            if raw::get_vec(png.get(), &mut out).is_ok() && out.starts_with(b"\x89PNG") {
                return Some(out);
            }
        }
        let mut dib = Vec::new();
        raw::get_vec(formats::CF_DIB, &mut dib).ok()?;
        super::dib_to_png(&dib)
    }

    /// Puts the image on the clipboard as PNG and as a bitmap (what terminals and
    /// most apps read). `transient` keeps it out of the clipboard history.
    pub fn set_clipboard_png(png: &[u8], transient: bool) -> bool {
        let Some(dib) = super::png_to_dib(png) else { return false };
        let Ok(_clip) = Clipboard::new_attempts(10) else { return false };
        if raw::empty().is_err() {
            return false;
        }
        let mut ok = raw::set_without_clear(formats::CF_DIB, &dib).is_ok();
        if let Some(f) = register_format("PNG") {
            ok &= raw::set_without_clear(f.get(), png).is_ok();
        }
        if transient {
            for name in ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
                if let Some(f) = register_format(name) {
                    let value: &[u8] = if name.starts_with("Exclude") { &[] } else { &[0, 0, 0, 0] };
                    let _ = raw::set_without_clear(f.get(), value);
                }
            }
        }
        ok
    }

    fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: vk,
                    wScan: 0,
                    dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) },
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        }
    }

    /// Ctrl+V, or Alt+V in a terminal (Claude Code's image paste on Windows).
    pub fn send_paste_image(terminal: bool) -> bool {
        let modifier = if terminal { VK_MENU } else { VK_CONTROL };
        let v = VIRTUAL_KEY(0x56);
        let inputs = [key(modifier, false), key(v, false), key(v, true), key(modifier, true)];
        let sent = unsafe { SendInput(&inputs, std::mem::size_of::<INPUT>() as i32) };
        sent as usize == inputs.len()
    }
}

#[cfg(not(windows))]
mod os {
    pub fn clipboard_sequence() -> u32 {
        0
    }
    pub fn foreground_window() -> isize {
        0
    }
    pub fn focus(_raw: isize) {}
    pub fn clipboard_png() -> Option<Vec<u8>> {
        None
    }
    pub fn set_clipboard_png(_png: &[u8], _transient: bool) -> bool {
        false
    }
    pub fn send_paste_image(_terminal: bool) -> bool {
        false
    }
}

// ── PNG ⇄ bitmap ──────────────────────────────────────────────────────────────

/// A clipboard bitmap (BITMAPINFOHEADER + pixels, 24 or 32 bits) as a PNG.
pub fn dib_to_png(dib: &[u8]) -> Option<Vec<u8>> {
    let u32_at = |o: usize| dib.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    let i32_at = |o: usize| u32_at(o).map(|v| v as i32);
    let header = u32_at(0)? as usize;
    let width = i32_at(4)?;
    let height = i32_at(8)?;
    let bits = dib.get(14..16).map(|b| u16::from_le_bytes([b[0], b[1]]))?;
    let compression = u32_at(16)?;
    if width <= 0 || height == 0 || !(bits == 24 || bits == 32) || !(compression == 0 || compression == 3) {
        return None;
    }
    // BI_BITFIELDS with a plain header: three colour masks follow it.
    let masks = if compression == 3 && header == 40 { 12 } else { 0 };
    let start = header + masks;
    let (w, h) = (width as usize, height.unsigned_abs() as usize);
    let stride = (w * bits as usize / 8).div_ceil(4) * 4;
    let pixels = dib.get(start..start + stride * h)?;
    let mut rgba = vec![0u8; w * h * 4];
    let mut any_alpha = false;
    for y in 0..h {
        // Bottom-up unless the height is negative.
        let src_row = if height > 0 { h - 1 - y } else { y };
        let row = &pixels[src_row * stride..src_row * stride + stride];
        for x in 0..w {
            let px = &row[x * bits as usize / 8..];
            let o = (y * w + x) * 4;
            rgba[o] = px[2];
            rgba[o + 1] = px[1];
            rgba[o + 2] = px[0];
            rgba[o + 3] = if bits == 32 { px[3] } else { 255 };
            any_alpha |= bits == 32 && px[3] != 0;
        }
    }
    // Many apps leave the alpha byte at 0: the image is then opaque.
    if bits == 32 && !any_alpha {
        for a in rgba.iter_mut().skip(3).step_by(4) {
            *a = 255;
        }
    }
    encode_png(w as u32, h as u32, &rgba)
}

/// A PNG as a clipboard bitmap: BITMAPINFOHEADER, 32 bits, bottom-up.
pub fn png_to_dib(png: &[u8]) -> Option<Vec<u8>> {
    let (w, h, rgba) = decode_png(png)?;
    let (w, h) = (w as usize, h as usize);
    let mut dib = Vec::with_capacity(40 + w * h * 4);
    dib.extend_from_slice(&40u32.to_le_bytes());
    dib.extend_from_slice(&(w as i32).to_le_bytes());
    dib.extend_from_slice(&(h as i32).to_le_bytes());
    dib.extend_from_slice(&1u16.to_le_bytes()); // planes
    dib.extend_from_slice(&32u16.to_le_bytes()); // bits
    dib.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    dib.extend_from_slice(&((w * h * 4) as u32).to_le_bytes());
    dib.extend_from_slice(&[0u8; 16]); // resolution, palette
    for y in (0..h).rev() {
        for x in 0..w {
            let o = (y * w + x) * 4;
            dib.extend_from_slice(&[rgba[o + 2], rgba[o + 1], rgba[o], rgba[o + 3]]);
        }
    }
    Some(dib)
}

fn encode_png(w: u32, h: u32, rgba: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(rgba).ok()?;
    }
    Some(out)
}

/// Any PNG as 8-bit RGBA.
fn decode_png(png: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let mut dec = png::Decoder::new(std::io::Cursor::new(png));
    dec.set_transformations(png::Transformations::normalize_to_color8() | png::Transformations::ALPHA);
    let mut reader = dec.read_info().ok()?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    let (w, h) = (info.width, info.height);
    let data = &buf[..info.buffer_size()];
    let rgba = match info.color_type {
        png::ColorType::Rgba => data.to_vec(),
        png::ColorType::GrayscaleAlpha => data.chunks(2).flat_map(|p| [p[0], p[0], p[0], p[1]]).collect(),
        _ => return None,
    };
    Some((w, h, rgba))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_image_goes_to_the_clipboard_and_back_unchanged() {
        // 3×2: red, green, blue / white, half-transparent black, yellow.
        let rgba: Vec<u8> = vec![
            255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, //
            255, 255, 255, 255, 0, 0, 0, 128, 255, 255, 0, 255,
        ];
        let png = encode_png(3, 2, &rgba).unwrap();
        let dib = png_to_dib(&png).unwrap();
        assert_eq!(dib.len(), 40 + 3 * 2 * 4);
        let back = dib_to_png(&dib).unwrap();
        assert_eq!(decode_png(&back).unwrap(), (3, 2, rgba));
    }

    #[test]
    fn a_24_bit_bitmap_with_padded_rows_is_read() {
        // 1×2, 24 bits: each row is padded to 4 bytes. Bottom-up: blue row first.
        let mut dib = Vec::new();
        dib.extend_from_slice(&40u32.to_le_bytes());
        dib.extend_from_slice(&1i32.to_le_bytes());
        dib.extend_from_slice(&2i32.to_le_bytes());
        dib.extend_from_slice(&1u16.to_le_bytes());
        dib.extend_from_slice(&24u16.to_le_bytes());
        dib.extend_from_slice(&[0u8; 24]);
        dib.extend_from_slice(&[255, 0, 0, 0]); // bottom: blue (BGR)
        dib.extend_from_slice(&[0, 0, 255, 0]); // top: red
        let (w, h, rgba) = decode_png(&dib_to_png(&dib).unwrap()).unwrap();
        assert_eq!((w, h), (1, 2));
        assert_eq!(rgba, vec![255, 0, 0, 255, 0, 0, 255, 255]);
    }

    #[test]
    fn terminals_take_images_with_alt_v() {
        assert!(is_terminal("windowsterminal"));
        assert!(is_terminal("pwsh"));
        assert!(!is_terminal("code"));
        assert!(!is_terminal("chrome"));
    }
}
