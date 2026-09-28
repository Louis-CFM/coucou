//! Desktop automation helpers (open apps/URLs, keys, media, screenshot).
//! Used by Coucou "desktop control" (Shift+M) — not a sandbox escape hatch for
//! Claude Code hooks; actions are only invoked from explicit user requests.

use serde::Serialize;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DesktopActionResult {
    pub ok: bool,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<String>,
}

fn session_type() -> String {
    std::env::var("XDG_SESSION_TYPE")
        .unwrap_or_else(|_| "unknown".into())
        .to_lowercase()
}

fn which(bin: &str) -> bool {
    Command::new("sh")
        .args(["-c", &format!("command -v {bin} >/dev/null 2>&1")])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_capture(cmd: &str, args: &[&str]) -> Result<Vec<u8>, String> {
    let out = Command::new(cmd)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("failed to spawn {cmd}: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(format!("{cmd} failed: {err}"));
    }
    Ok(out.stdout)
}

fn run_status(cmd: &str, args: &[&str]) -> Result<(), String> {
    let status = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .status()
        .map_err(|e| format!("failed to spawn {cmd}: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{cmd} exited with {status}"))
    }
}

#[tauri::command]
pub fn desktop_open(target: String) -> DesktopActionResult {
    let t = target.trim();
    if t.is_empty() {
        return DesktopActionResult {
            ok: false,
            message: "empty target".into(),
            data: None,
        };
    }
    // Prefer portal-friendly openers.
    let try_cmds: &[(&str, Vec<&str>)] = if t.contains("://") || t.starts_with('/') {
        &[
            ("xdg-open", vec![t]),
            ("gio", vec!["open", t]),
        ]
    } else {
        // App id / binary name
        &[
            ("gtk-launch", vec![t]),
            ("xdg-open", vec![t]),
        ]
    };

    for (cmd, args) in try_cmds {
        if !which(cmd) {
            continue;
        }
        match run_status(cmd, args) {
            Ok(()) => {
                return DesktopActionResult {
                    ok: true,
                    message: format!("opened {t}"),
                    data: None,
                };
            }
            Err(_) => continue,
        }
    }

    // Last resort: spawn detached if it looks like a binary
    if which(t) {
        let _ = Command::new(t).spawn();
        return DesktopActionResult {
            ok: true,
            message: format!("launched {t}"),
            data: None,
        };
    }

    DesktopActionResult {
        ok: false,
        message: format!("could not open {t}"),
        data: None,
    }
}

#[tauri::command]
pub fn desktop_type_text(text: String) -> DesktopActionResult {
    let text = text.replace('\0', "");
    if text.is_empty() {
        return DesktopActionResult {
            ok: false,
            message: "empty text".into(),
            data: None,
        };
    }

    if session_type() == "wayland" && which("wtype") {
        return match run_status("wtype", &[&text]) {
            Ok(()) => DesktopActionResult {
                ok: true,
                message: "typed".into(),
                data: None,
            },
            Err(e) => DesktopActionResult {
                ok: false,
                message: e,
                data: None,
            },
        };
    }

    if which("xdotool") {
        return match run_status("xdotool", &["type", "--clearmodifiers", "--", &text]) {
            Ok(()) => DesktopActionResult {
                ok: true,
                message: "typed".into(),
                data: None,
            },
            Err(e) => DesktopActionResult {
                ok: false,
                message: e,
                data: None,
            },
        };
    }

    DesktopActionResult {
        ok: false,
        message: "no typer available (install xdotool or wtype)".into(),
        data: None,
    }
}

#[tauri::command]
pub fn desktop_key(keys: String) -> DesktopActionResult {
    let keys = keys.trim();
    if keys.is_empty() {
        return DesktopActionResult {
            ok: false,
            message: "empty keys".into(),
            data: None,
        };
    }

    // Accept "Return", "ctrl+l", "ctrl+shift+t", etc.
    if which("xdotool") {
        return match run_status("xdotool", &["key", "--clearmodifiers", keys]) {
            Ok(()) => DesktopActionResult {
                ok: true,
                message: format!("key {keys}"),
                data: None,
            },
            Err(e) => DesktopActionResult {
                ok: false,
                message: e,
                data: None,
            },
        };
    }

    if which("wtype") {
        // Best-effort mapping for common keys
        let mapped = match keys.to_lowercase().as_str() {
            "return" | "enter" => "Return",
            "escape" | "esc" => "Escape",
            "tab" => "Tab",
            "space" => "space",
            "backspace" => "BackSpace",
            other => other,
        };
        return match run_status("wtype", &["-k", mapped]) {
            Ok(()) => DesktopActionResult {
                ok: true,
                message: format!("key {keys}"),
                data: None,
            },
            Err(e) => DesktopActionResult {
                ok: false,
                message: e,
                data: None,
            },
        };
    }

    DesktopActionResult {
        ok: false,
        message: "no key tool (install xdotool)".into(),
        data: None,
    }
}

#[tauri::command]
pub fn desktop_media(action: String) -> DesktopActionResult {
    let a = action.trim().to_lowercase();
    let playerctl_cmd = match a.as_str() {
        "play" | "pause" | "playpause" | "toggle" => Some("play-pause"),
        "next" => Some("next"),
        "previous" | "prev" => Some("previous"),
        "stop" => Some("stop"),
        _ => None,
    };

    if let Some(sub) = playerctl_cmd {
        if which("playerctl") {
            return match run_status("playerctl", &[sub]) {
                Ok(()) => DesktopActionResult {
                    ok: true,
                    message: format!("media {a}"),
                    data: None,
                },
                Err(e) => DesktopActionResult {
                    ok: false,
                    message: e,
                    data: None,
                },
            };
        }
    }

    // XF86 media keys via xdotool
    if which("xdotool") {
        let key = match a.as_str() {
            "play" | "pause" | "playpause" | "toggle" => "XF86AudioPlay",
            "next" => "XF86AudioNext",
            "previous" | "prev" => "XF86AudioPrev",
            "stop" => "XF86AudioStop",
            _ => {
                return DesktopActionResult {
                    ok: false,
                    message: format!("unknown media action: {a}"),
                    data: None,
                };
            }
        };
        return match run_status("xdotool", &["key", key]) {
            Ok(()) => DesktopActionResult {
                ok: true,
                message: format!("media {a}"),
                data: None,
            },
            Err(e) => DesktopActionResult {
                ok: false,
                message: e,
                data: None,
            },
        };
    }

    DesktopActionResult {
        ok: false,
        message: "install playerctl or xdotool for media control".into(),
        data: None,
    }
}

#[tauri::command]
pub fn desktop_screenshot() -> DesktopActionResult {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let path = std::env::temp_dir().join(format!("coucou-shot-{stamp}.png"));
    let path_str = path.to_string_lossy().to_string();

    let mut err_msgs = Vec::new();

    if session_type() == "wayland" && which("grim") {
        match run_status("grim", &[&path_str]) {
            Ok(()) => {}
            Err(e) => err_msgs.push(e),
        }
    }

    if !path.exists() && which("import") {
        // ImageMagick: full screen
        match run_status("import", &["-window", "root", &path_str]) {
            Ok(()) => {}
            Err(e) => err_msgs.push(e),
        }
    }

    if !path.exists() && which("gnome-screenshot") {
        match run_status("gnome-screenshot", &["-f", &path_str]) {
            Ok(()) => {}
            Err(e) => err_msgs.push(e),
        }
    }

    if !path.exists() && which("scrot") {
        match run_status("scrot", &[&path_str]) {
            Ok(()) => {}
            Err(e) => err_msgs.push(e),
        }
    }

    if !path.exists() {
        return DesktopActionResult {
            ok: false,
            message: format!(
                "screenshot failed (install grim / imagemagick / scrot). {}",
                err_msgs.join("; ")
            ),
            data: None,
        };
    }

    match std::fs::read(&path) {
        Ok(bytes) => {
            let _ = std::fs::remove_file(&path);
            let b64 = base64_encode(&bytes);
            DesktopActionResult {
                ok: true,
                message: "screenshot".into(),
                data: Some(format!("data:image/png;base64,{b64}")),
            }
        }
        Err(e) => DesktopActionResult {
            ok: false,
            message: format!("read shot: {e}"),
            data: None,
        },
    }
}

fn base64_encode(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(data)
}

#[tauri::command]
pub fn desktop_session_hint() -> DesktopActionResult {
    let st = session_type();
    let tools = [
        ("xdg-open", which("xdg-open")),
        ("xdotool", which("xdotool")),
        ("wtype", which("wtype")),
        ("playerctl", which("playerctl")),
        ("grim", which("grim")),
        ("import", which("import")),
    ]
    .into_iter()
    .filter(|(_, ok)| *ok)
    .map(|(n, _)| n)
    .collect::<Vec<_>>()
    .join(",");

    DesktopActionResult {
        ok: true,
        message: st,
        data: Some(tools),
    }
}
