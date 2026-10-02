// Dragging Mochi out of the island (roam.rs) needs Win32 screen capture and
// key state; other platforms keep the same commands, which do nothing yet.

use tauri::{AppHandle, Emitter};

pub fn create_window(_app: &AppHandle, _url: tauri::WebviewUrl, _browser_args: &str) {}

/// Hands Mochi straight back to the island, as if dropped there.
#[tauri::command]
pub fn roam_start(app: AppHandle, _look: Option<serde_json::Value>) {
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "roam-end", None::<String>);
}

#[tauri::command]
pub async fn roam_capture(_app: AppHandle) -> Result<String, String> {
    Err("not supported on this platform".into())
}

#[tauri::command]
pub fn roam_end(_app: AppHandle, _path: Option<String>) {}
