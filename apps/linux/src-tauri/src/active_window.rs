use crate::display::detect_session;
use crate::display::SessionType;
use serde::Serialize;
use std::process::Command;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveWindowInfo {
    pub app: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub available: bool,
    pub backend: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[tauri::command]
pub fn get_active_window() -> ActiveWindowInfo {
    match detect_session() {
        SessionType::X11 => get_active_window_x11(),
        SessionType::Wayland => try_wayland_gnome().unwrap_or_else(|| ActiveWindowInfo {
            app: String::new(),
            title: String::new(),
            url: None,
            available: false,
            backend: "wayland".into(),
            reason: Some(
                "Active window title unavailable on Wayland without GNOME Shell eval".into(),
            ),
        }),
        SessionType::Unknown => ActiveWindowInfo {
            app: String::new(),
            title: String::new(),
            url: None,
            available: false,
            backend: "unknown".into(),
            reason: Some("Could not detect X11 or Wayland session".into()),
        },
    }
}

fn get_active_window_x11() -> ActiveWindowInfo {
    if let Some(title) = run_stdout(&["xdotool", "getactivewindow", "getwindowname"]) {
        let app = run_stdout(&["xdotool", "getactivewindow", "getwindowpid"])
            .and_then(|pid| {
                std::fs::read_link(format!("/proc/{pid}/exe"))
                    .ok()
                    .map(|p| p.to_string_lossy().into_owned())
            })
            .unwrap_or_default();
        return ActiveWindowInfo {
            app,
            title,
            url: None,
            available: true,
            backend: "x11-xdotool".into(),
            reason: None,
        };
    }

    if let Some(title) = xprop_active_title() {
        return ActiveWindowInfo {
            app: String::new(),
            title,
            url: None,
            available: true,
            backend: "x11-xprop".into(),
            reason: None,
        };
    }

    ActiveWindowInfo {
        app: String::new(),
        title: String::new(),
        url: None,
        available: false,
        backend: "x11".into(),
        reason: Some("xdotool/xprop not available or no active window".into()),
    }
}

fn run_stdout(args: &[&str]) -> Option<String> {
    let output = Command::new(args[0]).args(&args[1..]).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn xprop_active_title() -> Option<String> {
    let id = run_stdout(&["xprop", "-root", "_NET_ACTIVE_WINDOW"])?;
    let hex = id.split_whitespace().last()?.trim_start_matches("0x");
    let win = u32::from_str_radix(hex, 16).ok()?;
    let name = run_stdout(&["xprop", "-id", &format!("0x{win:x}"), "WM_NAME"])?;
    name.split('=').nth(1).map(|s| s.trim().trim_matches('"').to_string())
}

fn try_wayland_gnome() -> Option<ActiveWindowInfo> {
    let script = r#"global.display.focus_window ? global.display.focus_window.get_title() : ''"#;
    let out = Command::new("gdbus")
        .args([
            "call",
            "--session",
            "--dest",
            "org.gnome.Shell",
            "--object-path",
            "/org/gnome/Shell",
            "--method",
            "org.gnome.Shell.Eval",
            script,
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let title = text
        .split('\'')
        .nth(3)
        .unwrap_or("")
        .trim()
        .to_string();
    if title.is_empty() {
        return None;
    }
    Some(ActiveWindowInfo {
        app: String::new(),
        title,
        url: None,
        available: true,
        backend: "wayland-gnome-shell".into(),
        reason: None,
    })
}
