use tauri::{AppHandle, Manager};

#[tauri::command]
pub fn toggle_main_window(app: AppHandle) -> Result<bool, String> {
    if let Some(window) = app.get_webview_window("main_window") {
        let is_visible = window.is_visible().map_err(|e| e.to_string())?;
        if is_visible {
            window.hide().map_err(|e| e.to_string())?;
            Ok(false)
        } else {
            window.show().map_err(|e| e.to_string())?;
            window.set_focus().map_err(|e| e.to_string())?;
            Ok(true)
        }
    } else {
        Err("Janela principal não encontrada".to_string())
    }
}

#[tauri::command]
pub fn get_app_version() -> String {
    "1.0.0".to_string()
}
