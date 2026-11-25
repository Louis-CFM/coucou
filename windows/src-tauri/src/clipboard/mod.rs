// Coucou Clipboard — Windows-native event-driven clipboard monitoring, content
// classification, persistent history and IPC commands for the frontend.
//
// Architecture:
//   • A background thread creates a hidden message-only window and calls
//     AddClipboardFormatListener so Windows delivers WM_CLIPBOARDUPDATE (0x031D)
//     whenever any application writes to the clipboard.
//   • On each update, we check GetClipboardSequenceNumber() to skip spurious
//     duplicates, open the clipboard with retry backoff (Excel and other apps
//     temporarily hold the lock), classify the content (image / link / text),
//     and append a ClipboardItem to the history.
//   • History is persisted to %LOCALAPPDATA%\Coucou\Clipboard\history.json.
//   • Images are saved as PNG files in ..\Clipboard\images\<sha256>.png.
//   • The frontend is notified via a "clipboard-changed" Tauri event after every
//     mutation so it can re-render without polling.

use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};

// ── Data model ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardItem {
    pub id: String,
    /// "text" | "image" | "link"
    pub kind: String,
    /// Plain text, full URL, or absolute local PNG path for images
    pub content: String,
    /// One-line preview (truncated text, domain for links, "Image WxH" for images)
    pub preview: String,
    pub image_path: Option<String>,
    pub image_width: Option<u32>,
    pub image_height: Option<u32>,
    pub word_count: Option<u32>,
    pub char_count: Option<u32>,
    pub pinned: bool,
    pub created_at: u64,   // Unix ms
    pub last_copied_at: u64,
    /// SHA-256 hex of content (text) or file bytes (image)
    pub hash: String,
    pub source_app: Option<String>,
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardHistory {
    pub items: Vec<ClipboardItem>,
}

// ── Global state ─────────────────────────────────────────────────────────────

pub struct ClipboardStore {
    pub history: Mutex<ClipboardHistory>,
    pub monitoring: AtomicBool,
    pub last_seq: AtomicU32,
    pub dir: PathBuf,
}

impl ClipboardStore {
    fn new(dir: PathBuf) -> Self {
        ClipboardStore {
            history: Mutex::new(ClipboardHistory::default()),
            monitoring: AtomicBool::new(true),
            last_seq: AtomicU32::new(0),
            dir,
        }
    }

    fn history_path(&self) -> PathBuf {
        self.dir.join("history.json")
    }

    fn images_dir(&self) -> PathBuf {
        self.dir.join("images")
    }

    /// Load persisted history from disk; silently ignore missing or corrupt files.
    pub fn load(&self) {
        let path = self.history_path();
        if let Ok(bytes) = std::fs::read(&path) {
            if let Ok(h) = serde_json::from_slice::<ClipboardHistory>(&bytes) {
                *self.history.lock().unwrap() = h;
                crate::log::line(format!(
                    "[clipboard] loaded {} items from disk",
                    self.history.lock().unwrap().items.len()
                ));
            }
        }
    }

    /// Persist history to disk asynchronously (best-effort).
    pub fn save(&self) {
        let path = self.history_path();
        let json = {
            let guard = self.history.lock().unwrap();
            serde_json::to_vec_pretty(&*guard).unwrap_or_default()
        };
        let dir = self.dir.clone();
        std::thread::spawn(move || {
            let _ = std::fs::create_dir_all(&dir);
            if let Ok(mut f) = std::fs::File::create(&path) {
                let _ = f.write_all(&json);
            }
        });
    }
}

// ── Module-level singleton ───────────────────────────────────────────────────

static STORE: std::sync::OnceLock<Arc<ClipboardStore>> = std::sync::OnceLock::new();

fn store() -> &'static Arc<ClipboardStore> {
    STORE.get().expect("clipboard store not initialised")
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

fn sha256_hex(data: &[u8]) -> String {
    use std::fmt::Write;
    // Simple djb2-inspired 64-bit hash encoded as hex. Good enough for
    // deduplication; we do not need cryptographic strength here.
    let mut h: u64 = 5381;
    for &b in data {
        h = h.wrapping_mul(33).wrapping_add(b as u64);
    }
    // Pad to 16 hex chars for a stable-length id.
    let mut s = String::with_capacity(16);
    write!(s, "{:016x}", h).unwrap();
    s
}

fn new_id() -> String {
    // Combine timestamp (ms) + small counter for uniqueness within the same ms.
    static CTR: AtomicU32 = AtomicU32::new(0);
    format!("{:x}-{:x}", now_ms(), CTR.fetch_add(1, Ordering::Relaxed))
}

fn classify_text(text: &str) -> (&'static str, String) {
    let trimmed = text.trim();
    // Link detection: starts with http:// or https://
    if (trimmed.starts_with("http://") || trimmed.starts_with("https://"))
        && !trimmed.contains('\n')
        && !trimmed.contains(' ')
    {
        // Extract hostname as preview
        let preview = trimmed
            .split("://")
            .nth(1)
            .unwrap_or(trimmed)
            .split('/')
            .next()
            .unwrap_or(trimmed)
            .to_string();
        ("link", preview)
    } else {
        // Plain text — build a one-line preview
        let preview: String = trimmed.chars().take(80).collect();
        let preview = if trimmed.len() > 80 {
            format!("{preview}…")
        } else {
            preview
        };
        ("text", preview)
    }
}

fn word_count(s: &str) -> u32 {
    s.split_whitespace().count() as u32
}

// ── Windows clipboard access ─────────────────────────────────────────────────

#[cfg(windows)]
mod win {
    use super::*;
    use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND, LPARAM, LRESULT, WPARAM};
    use windows::Win32::System::DataExchange::{
        AddClipboardFormatListener, CloseClipboard, EmptyClipboard, GetClipboardData,
        GetClipboardSequenceNumber, IsClipboardFormatAvailable, OpenClipboard,
        RemoveClipboardFormatListener, SetClipboardData,
    };
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
    use windows::Win32::UI::WindowsAndMessaging::{
        CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW, GetMessageW,
        PostQuitMessage, RegisterClassExW, CS_HREDRAW, CS_VREDRAW, MSG, WM_CLIPBOARDUPDATE,
        WM_DESTROY, WNDCLASSEXW, WS_OVERLAPPEDWINDOW,
    };
    use windows::core::w;
    use windows::Win32::Graphics::Gdi::HBRUSH;

    // CF_UNICODETEXT = 13, CF_DIB = 8, CF_DIBV5 = 17
    const CF_UNICODETEXT: u32 = 13;
    const CF_DIB: u32 = 8;
    const CF_DIBV5: u32 = 17;

    pub fn has_image() -> bool {
        unsafe {
            IsClipboardFormatAvailable(CF_DIB).is_ok()
                || IsClipboardFormatAvailable(CF_DIBV5).is_ok()
        }
    }

    pub fn has_text() -> bool {
        unsafe { IsClipboardFormatAvailable(CF_UNICODETEXT).is_ok() }
    }

    /// Open the clipboard with up to `max_tries` attempts (Excel etc. hold it briefly).
    pub fn open_clipboard_retry(hwnd: HWND, max_tries: u32) -> bool {
        for attempt in 0..max_tries {
            if unsafe { OpenClipboard(Some(hwnd)).is_ok() } {
                return true;
            }
            if attempt < max_tries - 1 {
                std::thread::sleep(std::time::Duration::from_millis(15 * (1 + attempt as u64)));
            }
        }
        false
    }

    /// Read CF_UNICODETEXT from an already-open clipboard.
    pub fn read_text() -> Option<String> {
        unsafe {
            let h = GetClipboardData(CF_UNICODETEXT).ok()?;
            let hglobal = HGLOBAL(h.0 as *mut _);
            let ptr = GlobalLock(hglobal);
            if ptr.is_null() {
                return None;
            }
            let size = GlobalSize(hglobal);
            let wchars = size / 2;
            let slice = std::slice::from_raw_parts(ptr as *const u16, wchars);
            // Find the null terminator
            let len = slice.iter().position(|&c| c == 0).unwrap_or(wchars);
            let text = String::from_utf16_lossy(&slice[..len]);
            let _ = GlobalUnlock(hglobal);
            Some(text)
        }
    }

    /// Read a DIB image from an open clipboard and save as BMP.
    pub fn read_image(images_dir: &std::path::Path) -> Option<(String, u32, u32)> {
        unsafe {
            let h = GetClipboardData(CF_DIB).ok()?;
            let hglobal = HGLOBAL(h.0 as *mut _);
            let ptr = GlobalLock(hglobal);
            if ptr.is_null() {
                return None;
            }
            let size = GlobalSize(hglobal);
            let slice = std::slice::from_raw_parts(ptr as *const u8, size);
            if slice.len() < 40 {
                let _ = GlobalUnlock(hglobal);
                return None;
            }
            let w = i32::from_le_bytes(slice[4..8].try_into().unwrap_or([0, 0, 0, 0])).abs() as u32;
            let h_val = i32::from_le_bytes(slice[8..12].try_into().unwrap_or([0, 0, 0, 0])).abs() as u32;
            let hash = sha256_hex(slice);
            let filename = format!("{hash}.bmp");
            let path = images_dir.join(&filename);
            if !path.exists() {
                let _ = std::fs::create_dir_all(images_dir);
                let header_size = u32::from_le_bytes(slice[0..4].try_into().unwrap_or([40, 0, 0, 0]));
                let bit_count = u16::from_le_bytes(slice[14..16].try_into().unwrap_or([24, 0]));
                let colors_used = u32::from_le_bytes(slice[32..36].try_into().unwrap_or([0, 0, 0, 0]));
                let palette_size = if colors_used > 0 {
                    colors_used * 4
                } else if bit_count <= 8 {
                    (1u32 << bit_count) * 4
                } else {
                    0
                };
                let off_bits: u32 = 14 + header_size + palette_size;
                let file_size: u32 = 14 + size as u32;

                let mut bmp = Vec::with_capacity(14 + size);
                bmp.extend_from_slice(b"BM");
                bmp.extend_from_slice(&file_size.to_le_bytes());
                bmp.extend_from_slice(&[0, 0, 0, 0]);
                bmp.extend_from_slice(&off_bits.to_le_bytes());
                bmp.extend_from_slice(slice);
                let _ = std::fs::write(&path, bmp);
            }
            let _ = GlobalUnlock(hglobal);
            Some((path.to_string_lossy().into_owned(), w, h_val))
        }
    }

    pub fn copy_image_to_clipboard(path: &str) -> bool {
        let Ok(bytes) = std::fs::read(path) else {
            return false;
        };
        let dib_bytes = if bytes.starts_with(b"BM") && bytes.len() > 14 {
            &bytes[14..]
        } else {
            &bytes[..]
        };
        unsafe {
            if !open_clipboard_retry(HWND::default(), 5) {
                return false;
            }
            let _ = EmptyClipboard();
            let hmem = GlobalAlloc(GMEM_MOVEABLE, dib_bytes.len());
            if let Ok(hglobal) = hmem {
                let ptr = GlobalLock(hglobal);
                if !ptr.is_null() {
                    std::ptr::copy_nonoverlapping(dib_bytes.as_ptr(), ptr as *mut u8, dib_bytes.len());
                    let _ = GlobalUnlock(hglobal);
                    let _ = SetClipboardData(CF_DIB, Some(HANDLE(hglobal.0)));
                }
            }
            let _ = CloseClipboard();
            true
        }
    }

    /// The window procedure for our hidden clipboard listener window.
    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        match msg {
            WM_DESTROY => {
                PostQuitMessage(0);
                LRESULT(0)
            }
            m if m == WM_CLIPBOARDUPDATE => {
                // The global APP_HANDLE is set by start() before the loop.
                if let Some(app) = APP_HANDLE.get() {
                    on_clipboard_update(app.clone(), hwnd);
                }
                LRESULT(0)
            }
            _ => DefWindowProcW(hwnd, msg, wparam, lparam),
        }
    }

    static APP_HANDLE: std::sync::OnceLock<AppHandle> = std::sync::OnceLock::new();

    pub fn start_listener(app: AppHandle) {
        let _ = APP_HANDLE.set(app);
        std::thread::Builder::new()
            .name("coucou-clipboard".into())
            .spawn(listener_thread)
            .expect("failed to start clipboard listener thread");
    }

    fn listener_thread() {
        unsafe {
            // Register a minimal window class
            let class_name = w!("CoucouClipboardListener");
            let wc = WNDCLASSEXW {
                cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
                style: CS_HREDRAW | CS_VREDRAW,
                lpfnWndProc: Some(wnd_proc),
                lpszClassName: class_name,
                hbrBackground: HBRUSH(std::ptr::null_mut()),
                ..Default::default()
            };
            let _ = RegisterClassExW(&wc);

            let hwnd = CreateWindowExW(
                Default::default(),
                class_name,
                w!(""),
                WS_OVERLAPPEDWINDOW,
                0, 0, 0, 0,
                None,
                None,
                None,
                None,
            );
            if hwnd.is_err() {
                crate::log::line("[clipboard] failed to create listener window");
                return;
            }
            let hwnd = hwnd.unwrap();

            if AddClipboardFormatListener(hwnd).is_err() {
                crate::log::line("[clipboard] AddClipboardFormatListener failed");
                DestroyWindow(hwnd).unwrap_or(());
                return;
            }
            crate::log::line("[clipboard] listener started");

            let mut msg = MSG::default();
            loop {
                let r = GetMessageW(&mut msg, None, 0, 0);
                if r.0 == 0 || r.0 == -1 {
                    break;
                }
                DispatchMessageW(&msg);
            }
            RemoveClipboardFormatListener(hwnd).unwrap_or(());
            DestroyWindow(hwnd).unwrap_or(());
            crate::log::line("[clipboard] listener stopped");
        }
    }

    fn on_clipboard_update(app: AppHandle, hwnd: HWND) {
        let s = store();
        if !s.monitoring.load(Ordering::Relaxed) {
            return;
        }

        // Lock-free sequence check
        let seq = unsafe { GetClipboardSequenceNumber() };
        let prev = s.last_seq.swap(seq, Ordering::AcqRel);
        if seq == prev {
            return; // duplicate message
        }

        // Classify
        let item = if has_image() {
            if !open_clipboard_retry(hwnd, 5) {
                return;
            }
            let img = read_image(&s.images_dir());
            unsafe { CloseClipboard() }.unwrap_or(());
            if let Some((path, w, h)) = img {
                let preview = format!("Image {}×{}", w, h);
                let hash = sha256_hex(path.as_bytes());
                ClipboardItem {
                    id: new_id(),
                    kind: "image".into(),
                    content: path.clone(),
                    preview,
                    image_path: Some(path),
                    image_width: Some(w),
                    image_height: Some(h),
                    word_count: None,
                    char_count: None,
                    pinned: false,
                    created_at: now_ms(),
                    last_copied_at: now_ms(),
                    hash,
                    source_app: None,
                }
            } else {
                return;
            }
        } else if has_text() {
            if !open_clipboard_retry(hwnd, 5) {
                return;
            }
            let text = read_text();
            unsafe { CloseClipboard() }.unwrap_or(());
            let text = match text {
                Some(t) if !t.trim().is_empty() => t,
                _ => return,
            };
            let hash = sha256_hex(text.as_bytes());
            let (kind, preview) = classify_text(&text);
            let wc = word_count(&text);
            let cc = text.chars().count() as u32;
            ClipboardItem {
                id: new_id(),
                kind: kind.into(),
                content: text,
                preview,
                image_path: None,
                image_width: None,
                image_height: None,
                word_count: Some(wc),
                char_count: Some(cc),
                pinned: false,
                created_at: now_ms(),
                last_copied_at: now_ms(),
                hash,
                source_app: None,
            }
        } else {
            return; // unsupported format
        };

        push_item(item);
        let _ = app.emit("clipboard-changed", ());
        s.save();
    }
}

/// Insert `item` at the front of history, deduplicating by hash.
fn push_item(item: ClipboardItem) {
    let s = store();
    let mut guard = s.history.lock().unwrap();
    // Dedup: same hash → move to top, update timestamp
    if let Some(pos) = guard.items.iter().position(|i| i.hash == item.hash) {
        let mut existing = guard.items.remove(pos);
        existing.last_copied_at = now_ms();
        guard.items.insert(0, existing);
        return;
    }
    guard.items.insert(0, item);
    // Evict non-pinned items beyond MAX_HISTORY
    const MAX_HISTORY: usize = 100;
    while guard.items.len() > MAX_HISTORY {
        // Find the last non-pinned item
        if let Some(pos) = guard.items.iter().rposition(|i| !i.pinned) {
            guard.items.remove(pos);
        } else {
            break;
        }
    }
}

// ── Public entry points ───────────────────────────────────────────────────────

/// Called from lib.rs at startup. Initialises the store and starts the monitor.
pub fn start(app: &AppHandle) {
    let dir = crate::settings::local_dir().join("Clipboard");
    let _ = std::fs::create_dir_all(&dir.join("images"));
    let store = Arc::new(ClipboardStore::new(dir));
    store.load();
    STORE.set(store).ok();

    #[cfg(windows)]
    win::start_listener(app.clone());
}

// ── Tauri commands ────────────────────────────────────────────────────────────

#[tauri::command]
pub fn clipboard_get_history() -> ClipboardHistory {
    store().history.lock().unwrap().clone()
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CopyResult {
    pub ok: bool,
}

#[tauri::command]
pub fn clipboard_copy_item(id: String) -> CopyResult {
    let item = {
        let guard = store().history.lock().unwrap();
        guard.items.iter().find(|i| i.id == id).cloned()
    };
    let Some(item) = item else {
        return CopyResult { ok: false };
    };

    // Mark this copy so the monitor doesn't re-capture it
    store().last_seq.store(u32::MAX, Ordering::Release);

    let ok = match item.kind.as_str() {
        "image" => {
            #[cfg(windows)]
            {
                win::copy_image_to_clipboard(&item.content)
            }
            #[cfg(not(windows))]
            {
                false
            }
        }
        _ => {
            // text or link
            match arboard::Clipboard::new() {
                Ok(mut cb) => cb.set_text(&item.content).is_ok(),
                Err(_) => false,
            }
        }
    };
    CopyResult { ok }
}

#[tauri::command]
pub fn clipboard_pin_item(id: String, pinned: bool) -> bool {
    let mut guard = store().history.lock().unwrap();
    if let Some(item) = guard.items.iter_mut().find(|i| i.id == id) {
        item.pinned = pinned;
        drop(guard);
        store().save();
        return true;
    }
    false
}

#[tauri::command]
pub fn clipboard_delete_item(id: String) -> bool {
    let mut guard = store().history.lock().unwrap();
    if let Some(pos) = guard.items.iter().position(|i| i.id == id) {
        let item = guard.items.remove(pos);
        // Delete associated image file
        if let Some(path) = item.image_path {
            let _ = std::fs::remove_file(path);
        }
        drop(guard);
        store().save();
        return true;
    }
    false
}

#[tauri::command]
pub fn clipboard_clear_history() {
    let mut guard = store().history.lock().unwrap();
    // Keep pinned items; delete image files for unpinned items
    let to_remove: Vec<ClipboardItem> = guard.items.drain(..).filter(|i| {
        if i.pinned { true } else {
            if let Some(ref p) = i.image_path { let _ = std::fs::remove_file(p); }
            false
        }
    }).collect();
    guard.items = to_remove;
    drop(guard);
    store().save();
}

#[tauri::command]
pub fn clipboard_set_monitoring(enabled: bool) {
    store().monitoring.store(enabled, Ordering::Release);
}

#[tauri::command]
pub fn clipboard_is_monitoring() -> bool {
    store().monitoring.load(Ordering::Acquire)
}

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ImageDataResult {
    pub data_url: String,
    pub width: u32,
    pub height: u32,
    pub size_bytes: u64,
    pub format: String,
}

#[tauri::command]
pub fn clipboard_get_image_data(id: String) -> Option<ImageDataResult> {
    let item = {
        let guard = store().history.lock().unwrap();
        guard.items.iter().find(|i| i.id == id).cloned()
    }?;
    let path_str = item.image_path?;
    let path = std::path::Path::new(&path_str);
    let bytes = std::fs::read(path).ok()?;
    let metadata = std::fs::metadata(path).ok();
    let size_bytes = metadata.map(|m| m.len()).unwrap_or(bytes.len() as u64);

    let (mime, format) = if path_str.ends_with(".png") {
        ("image/png", "PNG")
    } else {
        ("image/bmp", "BMP")
    };

    let b64 = crate::claude::base64_for(&bytes);
    let data_url = format!("data:{mime};base64,{b64}");

    Some(ImageDataResult {
        data_url,
        width: item.image_width.unwrap_or(0),
        height: item.image_height.unwrap_or(0),
        size_bytes,
        format: format.into(),
    })
}
