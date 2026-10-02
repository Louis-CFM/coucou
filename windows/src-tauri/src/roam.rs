// Roaming Mochi. Dragged out of the island, Mochi lives in its own window: a
// transparent, click-through overlay over the whole monitor. It follows the
// cursor while the button is held, lands where it is dropped, scans the screen,
// takes a screenshot, then flies back to the island, which opens the prompt with
// the screenshot attached.
//
// The overlay never takes a click: the cursor is polled here and sent to it, the
// same way the island's own cursor tracking works.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewWindowBuilder};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC, GetDIBits,
    ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, CAPTUREBLT, DIB_RGB_COLORS,
    SRCCOPY,
};
use windows::Win32::Graphics::Imaging::{
    CLSID_WICImagingFactory, GUID_ContainerFormatPng, GUID_WICPixelFormat32bppBGRA,
    IWICBitmapSource, IWICImagingFactory, WICBitmapEncoderNoCache,
    WICBitmapInterpolationModeHighQualityCubic,
};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
};
use windows::core::{Interface, HSTRING};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_ESCAPE, VK_RBUTTON};

use crate::{island, log};

pub const LABEL: &str = "roam";

/// Screenshots are scaled down to this long edge: the Claude API resizes
/// anything bigger anyway, so larger images only cost upload time.
const MAX_EDGE: u32 = 1568;

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
        Ok(win) => {
            crate::platform::make_non_activating(&win);
            crate::platform::set_memory_low(&win, true);
            crate::platform::set_click_through(&win, true);
        }
        Err(err) => log::line(format!("roam window failed: {err}")),
    }
}

/// Mochi has been dragged out of the island: cover the monitor under the cursor
/// and stream the cursor to the overlay until the button is released.
#[tauri::command]
pub fn roam_start(app: AppHandle, look: Option<serde_json::Value>) {
    if ACTIVE.swap(true, Ordering::SeqCst) {
        return;
    }
    let Some(win) = app.get_webview_window(LABEL) else {
        ACTIVE.store(false, Ordering::SeqCst);
        return;
    };
    let (cx, cy) = crate::platform::cursor_physical().unwrap_or((0.0, 0.0));
    let monitor = app
        .available_monitors()
        .ok()
        .and_then(|ms| {
            ms.into_iter().find(|m| {
                let p = m.position();
                let s = m.size();
                cx >= p.x as f64
                    && cx < (p.x + s.width as i32) as f64
                    && cy >= p.y as f64
                    && cy < (p.y + s.height as i32) as f64
            })
        })
        .or_else(|| app.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else {
        ACTIVE.store(false, Ordering::SeqCst);
        return;
    };
    let origin = *monitor.position();
    let size = *monitor.size();
    let scale = monitor.scale_factor();

    let _ = win.set_position(PhysicalPosition::new(origin.x, origin.y));
    let _ = win.set_size(PhysicalSize::new(size.width, size.height));
    crate::platform::set_click_through(&win, true);
    crate::platform::set_memory_low(&win, false);
    let _ = win.show();
    let _ = win.set_always_on_top(true);

    let to_local = move |(x, y): (f64, f64)| Point {
        x: (x - origin.x as f64) / scale,
        y: (y - origin.y as f64) / scale,
    };
    // `look` is the island Mochi's state and colour, so the one on the screen is
    // the same Mochi, not a fresh white one.
    let start = to_local((cx, cy));
    let _ = app.emit_to(
        LABEL,
        "roam-begin",
        serde_json::json!({ "x": start.x, "y": start.y, "look": look }),
    );

    // ~120 Hz, and only when the cursor actually moved: every event runs script
    // in the overlay, so idle repeats only waste its frame time, while a feed
    // faster than the display keeps the dangling Mochi from stepping. The thread
    // lives as long as the roam, watching for Esc / right-click to cancel it.
    std::thread::spawn(move || {
        let mut last = (f64::NAN, f64::NAN);
        let mut carried = true;
        while ACTIVE.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(8));
            if key_down(VK_ESCAPE.0) || key_down(VK_RBUTTON.0) {
                let _ = app.emit_to(LABEL, "roam-cancel", ());
                break;
            }
            if !carried {
                continue;
            }
            let Some(cursor) = crate::platform::cursor_physical() else { continue };
            if !crate::platform::left_button_down() {
                let _ = app.emit_to(LABEL, "roam-drop", to_local(cursor));
                carried = false;
            } else if cursor != last {
                let _ = app.emit_to(LABEL, "roam-cursor", to_local(cursor));
                last = cursor;
            }
        }
    });
}

fn key_down(vk: u16) -> bool {
    unsafe { (GetAsyncKeyState(vk as i32) as u16 & 0x8000) != 0 }
}

/// Captures the monitor the overlay covers (the overlay has already hidden
/// Mochi for this frame) and returns the path of the PNG.
#[tauri::command]
pub async fn roam_capture(app: AppHandle) -> Result<String, String> {
    let win = app.get_webview_window(LABEL).ok_or("no roam window")?;
    let pos = win.outer_position().map_err(|e| e.to_string())?;
    let size = win.outer_size().map_err(|e| e.to_string())?;
    tauri::async_runtime::spawn_blocking(move || {
        let path = std::env::temp_dir().join("coucou-screenshot.png");
        capture(pos.x, pos.y, size.width as i32, size.height as i32, &path)?;
        Ok(path.to_string_lossy().into_owned())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Mochi is back in the island: hide the overlay and hand the screenshot over.
#[tauri::command]
pub fn roam_end(app: AppHandle, path: Option<String>) {
    if let Some(win) = app.get_webview_window(LABEL) {
        let _ = win.hide();
        crate::platform::set_memory_low(&win, true);
    }
    ACTIVE.store(false, Ordering::SeqCst);
    let _ = app.emit_to(island::WINDOW_LABEL, "roam-end", path);
}

fn capture(x: i32, y: i32, w: i32, h: i32, path: &PathBuf) -> Result<(), String> {
    if w <= 0 || h <= 0 {
        return Err("empty capture area".into());
    }
    let mut pixels = vec![0u8; (w * h * 4) as usize];
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, bitmap.into());
        let copied = BitBlt(mem, 0, 0, w, h, Some(screen), x, y, SRCCOPY | CAPTUREBLT);
        let mut info = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: w,
                biHeight: -h, // top-down rows
                biPlanes: 1,
                biBitCount: 32,
                biCompression: BI_RGB.0,
                ..Default::default()
            },
            ..Default::default()
        };
        let rows = GetDIBits(
            mem,
            bitmap,
            0,
            h as u32,
            Some(pixels.as_mut_ptr().cast()),
            &mut info,
            DIB_RGB_COLORS,
        );
        SelectObject(mem, old);
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
        copied.map_err(|e| format!("screen capture failed: {e}"))?;
        if rows == 0 {
            return Err("screen capture returned no pixels".into());
        }
    }
    // GDI leaves the alpha byte at 0; PNG would read that as fully transparent.
    for px in pixels.chunks_exact_mut(4) {
        px[3] = 255;
    }
    encode_png(&pixels, w as u32, h as u32, path).map_err(|e| format!("PNG encoding failed: {e}"))
}

/// BGRA pixels → PNG on disk, scaled down to `MAX_EDGE`, with the Windows
/// Imaging Component (no image crate needed).
fn encode_png(pixels: &[u8], w: u32, h: u32, path: &PathBuf) -> windows::core::Result<()> {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let factory: IWICImagingFactory =
            CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER)?;
        let bitmap =
            factory.CreateBitmapFromMemory(w, h, &GUID_WICPixelFormat32bppBGRA, w * 4, pixels)?;

        let fit = (MAX_EDGE as f64 / w.max(h) as f64).min(1.0);
        let (nw, nh) = (((w as f64) * fit).round() as u32, ((h as f64) * fit).round() as u32);
        let source: IWICBitmapSource = if fit < 1.0 {
            let scaler = factory.CreateBitmapScaler()?;
            scaler.Initialize(&bitmap, nw, nh, WICBitmapInterpolationModeHighQualityCubic)?;
            scaler.cast()?
        } else {
            bitmap.cast()?
        };

        let stream = factory.CreateStream()?;
        stream.InitializeFromFilename(&HSTRING::from(path.as_os_str()), 0x4000_0000)?; // GENERIC_WRITE
        let encoder = factory.CreateEncoder(&GUID_ContainerFormatPng, std::ptr::null())?;
        encoder.Initialize(&stream, WICBitmapEncoderNoCache)?;
        let mut frame = None;
        encoder.CreateNewFrame(&mut frame, std::ptr::null_mut())?;
        let frame = frame.ok_or_else(windows::core::Error::empty)?;
        frame.Initialize(None)?;
        frame.SetSize(nw, nh)?;
        let mut format = GUID_WICPixelFormat32bppBGRA;
        frame.SetPixelFormat(&mut format)?;
        frame.WriteSource(&source, std::ptr::null())?;
        frame.Commit()?;
        encoder.Commit()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    /// Captures a real strip of the screen: the PNG must be valid, and anything
    /// wider than MAX_EDGE must come out scaled down to it.
    #[test]
    fn capture_writes_a_scaled_png() {
        let path = std::env::temp_dir().join("coucou-capture-test.png");
        super::capture(0, 0, 2000, 120, &path).unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let _ = std::fs::remove_file(&path);
        assert_eq!(&bytes[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        let width = u32::from_be_bytes(bytes[16..20].try_into().unwrap());
        let height = u32::from_be_bytes(bytes[20..24].try_into().unwrap());
        assert_eq!(width, super::MAX_EDGE);
        assert_eq!(height, (120.0 * super::MAX_EDGE as f64 / 2000.0).round() as u32);
    }
}
