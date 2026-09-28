use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DisplayInfo {
    pub width: u32,
    pub height: u32,
    pub scale: f64,
    pub x: i32,
    pub y: i32,
}

#[derive(Serialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum SessionType {
    Wayland,
    X11,
    Unknown,
}

#[derive(Serialize)]
pub struct SessionInfo {
    pub session: SessionType,
}

pub fn detect_session() -> SessionType {
    if std::env::var("WAYLAND_DISPLAY").is_ok() {
        return SessionType::Wayland;
    }
    if std::env::var("DISPLAY").is_ok() {
        return SessionType::X11;
    }
    match std::env::var("XDG_SESSION_TYPE")
        .unwrap_or_default()
        .to_lowercase()
        .as_str()
    {
        "wayland" => SessionType::Wayland,
        "x11" => SessionType::X11,
        _ => SessionType::Unknown,
    }
}

#[tauri::command]
pub fn get_display_info(window: tauri::WebviewWindow) -> Result<DisplayInfo, String> {
    let monitor = window
        .current_monitor()
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "no current monitor".to_string())?;
    let size = monitor.size();
    let pos = monitor.position();
    Ok(DisplayInfo {
        width: size.width,
        height: size.height,
        scale: monitor.scale_factor(),
        x: pos.x,
        y: pos.y,
    })
}

#[tauri::command]
pub fn get_session_info() -> SessionInfo {
    SessionInfo {
        session: detect_session(),
    }
}
