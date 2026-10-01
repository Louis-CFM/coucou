// Window attach for the Mochi drag-out: captures the window under the cursor
// into the inbox and reports it back, mirroring WindowContextCapture on macOS.
//
// Flow: user drags Mochi out of the island (> 7pt) → a ghost follows the
// cursor → on release the front end calls `attach_window` → we read the cursor
// position ourselves (the release usually happens outside our window, so
// client coordinates would be meaningless), find the window below it, capture
// it with PrintWindow (BitBlt fallback), and save a PNG next to dropped files.
// The front end then offers it as prompt context like any other file.
//
// Permissions: none beyond what a screenshot tool needs. A minimized window or
// our own island under the cursor is a clean error, never a capture.

use serde::Serialize;
use tauri::AppHandle;
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject, GetDC,
    GetDIBits, ReleaseDC, SelectObject, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS,
    HDC, PW_RENDERFULLCONTENT, PrintWindow, SRCCOPY,
};
use windows::Win32::System::ProcessStatus::GetModuleBaseNameW;
use windows::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetWindowRect, GetWindowTextW, GetWindowThreadProcessId, IsIconic,
    WindowFromPoint,
};

use crate::files;
use crate::island;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AttachedWindow {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub app_name: String,
    pub title: String,
}

fn our_hwnd(app: &AppHandle) -> Option<HWND> {
    island::window(app)
        .ok()
        .flatten()
        .and_then(|w| w.hwnd().ok())
        .map(|raw| HWND(raw.0 as *mut _))
}

fn window_text(hwnd: HWND) -> String {
    let mut buf = [0u16; 512];
    let len = unsafe { GetWindowTextW(hwnd, &mut buf) };
    String::from_utf16_lossy(&buf[..len as usize]).trim().to_string()
}

fn process_name(pid: u32) -> String {
    unsafe {
        let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return String::new();
        };
        let mut buf = [0u16; 260];
        let len = GetModuleBaseNameW(handle, None, &mut buf);
        let _ = windows::Win32::Foundation::CloseHandle(handle);
        String::from_utf16_lossy(&buf[..len as usize])
    }
}

/// Captures `hwnd` (rect in physical screen pixels) into an RGBA buffer.
/// PrintWindow first so occluded windows still render; plain BitBlt fallback.
fn capture(hwnd: HWND, rect: RECT) -> Result<(u32, u32, Vec<u8>), String> {
    let w = rect.right - rect.left;
    let h = rect.bottom - rect.top;
    if w < 8 || h < 8 || w > 8192 || h > 8192 {
        return Err("window has no usable size (minimized?)".into());
    }
    unsafe {
        let screen_dc: HDC = GetDC(None);
        if screen_dc.is_invalid() {
            return Err("cannot access the screen".into());
        }
        let mem_dc = CreateCompatibleDC(screen_dc);
        let bmp = CreateCompatibleBitmap(screen_dc, w, h);
        if mem_dc.is_invalid() || bmp.is_invalid() {
            ReleaseDC(None, screen_dc);
            return Err("cannot create capture buffer".into());
        }
        let old = SelectObject(mem_dc, bmp);

        // PrintWindow renders even covered windows; some (Electron, browsers)
        // need the full-content flag, others only answer the classic one.
        let mut ok = PrintWindow(hwnd, mem_dc, PW_RENDERFULLCONTENT).as_bool();
        if !ok {
            ok = PrintWindow(hwnd, mem_dc, Default::default()).as_bool();
        }
        if !ok {
            // Last resort: copy what is actually on screen at that rect.
            ok = BitBlt(mem_dc, 0, 0, w, h, screen_dc, rect.left, rect.top, SRCCOPY).is_ok();
        }
        SelectObject(mem_dc, old);

        let result = if ok {
            let mut info = BITMAPINFO {
                bmiHeader: BITMAPINFOHEADER {
                    biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                    biWidth: w,
                    biHeight: -h, // top-down: no row flip needed
                    biPlanes: 1,
                    biBitCount: 32,
                    biCompression: BI_RGB.0,
                    biSizeImage: 0,
                    ..Default::default()
                },
                ..Default::default()
            };
            let mut pixels = vec![0u8; (w * h * 4) as usize];
            let lines = GetDIBits(
                mem_dc,
                bmp,
                0,
                h as u32,
                Some(pixels.as_mut_ptr() as *mut _),
                &mut info,
                DIB_RGB_COLORS,
            );
            if lines == 0 {
                Err("could not read captured pixels".into())
            } else {
                // BGRA → RGBA for the PNG encoder.
                for px in pixels.chunks_exact_mut(4) {
                    px.swap(0, 2);
                }
                Ok((w as u32, h as u32, pixels))
            }
        } else {
            Err("window refused capture (try a normal resizable window)".into())
        };

        let _ = DeleteObject(bmp);
        let _ = DeleteDC(mem_dc);
        ReleaseDC(None, screen_dc);
        result
    }
}

pub fn attach(app: &AppHandle) -> Result<AttachedWindow, String> {
    let mut point = windows::Win32::Foundation::POINT::default();
    unsafe {
        GetCursorPos(&mut point).map_err(|_| "cannot read cursor position".to_string())?;
    }
    let target = unsafe { WindowFromPoint(point) };
    if target.0.is_null() {
        return Err("no window under the cursor".into());
    }
    if Some(target) == our_hwnd(app) {
        return Err("drop Mochi on another app's window, not on the island".into());
    }
    if unsafe { IsIconic(target) }.as_bool() {
        return Err("that window is minimized".into());
    }
    let mut rect = RECT::default();
    unsafe {
        GetWindowRect(target, &mut rect).map_err(|_| "cannot read window bounds".to_string())?;
    }

    let title = window_text(target);
    let mut pid = 0u32;
    unsafe {
        GetWindowThreadProcessId(target, Some(&mut pid));
    }
    let app_name = process_name(pid)
        .trim_end_matches(".exe")
        .trim_end_matches(".EXE")
        .to_string();

    let (w, h, pixels) = capture(target, rect)?;
    let img = image::RgbaImage::from_raw(w, h, pixels)
        .ok_or_else(|| "captured image is corrupt".to_string())?;

    // Downscale wide captures like ScreenCaptureKit does (1568px max) so the
    // chat payload stays small; thumbnail preserves aspect.
    let (w2, h2) = if w > 1568 {
        let h2 = (h as f32 * 1568.0 / w as f32).round() as u32;
        (1568, h2.max(1))
    } else {
        (w, h)
    };
    let img = image::imageops::resize(&img, w2, h2, image::imageops::FilterType::Triangle);

    let dir = files::inbox_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let base = if app_name.is_empty() { "window".to_string() } else { app_name.clone() };
    let dest = dir.join(format!("{base}-{stamp}.png"));
    img.save(&dest).map_err(|e| format!("cannot save capture: {e}"))?;
    let size = std::fs::metadata(&dest).map(|m| m.len()).unwrap_or(0);

    Ok(AttachedWindow {
        name: dest
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| "window.png".into()),
        path: dest.to_string_lossy().to_string(),
        size,
        app_name,
        title,
    })
}
