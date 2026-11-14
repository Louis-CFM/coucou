// Smart Notch Monitor (#smart-notch):
// Full on the desktop; tucked away over maximized apps.
// Detects whether the active foreground window on the active display is maximized, fullscreen, or desktop.
// Emits "smart-notch-state" to the webview:
// { isMaximized: bool, isDesktop: bool, app: Option<String> }

use serde::{Deserialize, Serialize};
use std::time::Duration;
use tauri::{AppHandle, Emitter};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SmartNotchState {
    pub is_maximized: bool,
    pub is_desktop: bool,
    pub app: Option<String>,
}

#[cfg(windows)]
pub fn detect_window_state() -> SmartNotchState {
    use ::windows::Win32::Foundation::RECT;
    use ::windows::Win32::Graphics::Gdi::{
        GetMonitorInfoW, MonitorFromWindow, MONITORINFO, MONITOR_DEFAULTTONEAREST,
    };
    use ::windows::Win32::UI::WindowsAndMessaging::{
        GetClassNameW, GetDesktopWindow, GetForegroundWindow, GetShellWindow, GetWindowRect,
        GetWindowThreadProcessId, IsZoomed,
    };

    let hwnd = unsafe { GetForegroundWindow() };
    if hwnd.0.is_null() {
        return SmartNotchState {
            is_maximized: false,
            is_desktop: true,
            app: None,
        };
    }

    // Don't update state if Coucou itself (island/settings/hub) is the foreground window:
    let mut pid = 0u32;
    unsafe {
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
    }
    if pid == std::process::id() {
        return SmartNotchState {
            is_maximized: false,
            is_desktop: false,
            app: Some("coucou".into()),
        };
    }

    let shell_hwnd = unsafe { GetShellWindow() };
    let desktop_hwnd = unsafe { GetDesktopWindow() };
    if hwnd == shell_hwnd || hwnd == desktop_hwnd {
        return SmartNotchState {
            is_maximized: false,
            is_desktop: true,
            app: Some("desktop".into()),
        };
    }

    let mut class_buf = [0u16; 256];
    let class_len = unsafe { GetClassNameW(hwnd, &mut class_buf) } as usize;
    let class_name = String::from_utf16_lossy(&class_buf[..class_len]);
    if class_name == "Progman" || class_name == "WorkerW" {
        return SmartNotchState {
            is_maximized: false,
            is_desktop: true,
            app: Some("desktop".into()),
        };
    }

    let is_zoomed = unsafe { IsZoomed(hwnd).as_bool() };
    let mut is_fullscreen = false;

    let mut rect = RECT::default();
    if unsafe { GetWindowRect(hwnd, &mut rect).is_ok() } {
        let hmon = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) };
        let mut mi = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if unsafe { GetMonitorInfoW(hmon, &mut mi).as_bool() } {
            let mon_w = mi.rcMonitor.right - mi.rcMonitor.left;
            let mon_h = mi.rcMonitor.bottom - mi.rcMonitor.top;
            let win_w = rect.right - rect.left;
            let win_h = rect.bottom - rect.top;
            if win_w >= mon_w && win_h >= (mon_h - 40) && rect.top <= mi.rcMonitor.top {
                is_fullscreen = true;
            }
        }
    }

    SmartNotchState {
        is_maximized: is_zoomed || is_fullscreen,
        is_desktop: false,
        app: crate::flow::os::foreground_app().map(|(id, _)| id),
    }
}

#[cfg(not(windows))]
pub fn detect_window_state() -> SmartNotchState {
    SmartNotchState {
        is_maximized: false,
        is_desktop: true,
        app: None,
    }
}

#[tauri::command]
pub fn get_foreground_window_state() -> SmartNotchState {
    detect_window_state()
}

pub fn start(app: &AppHandle) {
    let handle = app.clone();
    std::thread::Builder::new()
        .name("coucou-smart-notch".into())
        .spawn(move || {
            run_smart_notch_loop(handle);
        })
        .ok();
}

fn run_smart_notch_loop(app: AppHandle) {
    let mut last_state = detect_window_state();
    let _ = app.emit("smart-notch-state", &last_state);

    loop {
        std::thread::sleep(Duration::from_millis(250));
        let current = detect_window_state();
        // Ignore Coucou internal focus changes:
        if current.app.as_deref() == Some("coucou") {
            continue;
        }
        if current != last_state {
            last_state = current.clone();
            let _ = app.emit("smart-notch-state", &current);
        }
    }
}
