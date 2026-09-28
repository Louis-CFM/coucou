use tauri::{PhysicalPosition, WebviewWindow};

#[tauri::command]
pub fn position_island(window: WebviewWindow, panel_w: u32, panel_h: u32) -> Result<(), String> {
    let monitor = window
        .current_monitor()
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "no current monitor".to_string())?;
    let size = monitor.size();
    let pos = monitor.position();
    let x = pos.x + (size.width as i32 - panel_w as i32) / 2;
    let y = pos.y;
    window
        .set_position(PhysicalPosition::new(x, y))
        .map_err(|e| e.to_string())?;
    let _ = panel_h;
    Ok(())
}

#[tauri::command]
pub fn set_click_through(window: WebviewWindow, enabled: bool) -> Result<(), String> {
    window
        .set_ignore_cursor_events(enabled)
        .map_err(|e| e.to_string())
}
